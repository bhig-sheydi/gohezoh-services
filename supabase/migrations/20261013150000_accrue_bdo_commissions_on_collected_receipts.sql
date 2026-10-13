-- Accrue direct-BDO commissions only for completed, accepted-quote delivery jobs
-- with an approved collected-revenue plan explicitly covering that service.
alter table public.commission_ledger
  add column adjustment_reason text check (adjustment_reason is null or length(btrim(adjustment_reason)) between 10 and 500);

create unique index commission_ledger_payment_plan_bdo_unique
  on public.commission_ledger(payment_id,bdo_id,plan_id)
  where payment_id is not null and adjustment_of is null;
create unique index commission_ledger_adjustment_once_idx
  on public.commission_ledger(adjustment_of) where adjustment_of is not null;

revoke all on public.commission_plans,public.commission_ledger from public,anon,authenticated;
grant select on public.commission_plans,public.commission_ledger to authenticated;

create or replace function public.accrue_bdo_commission_for_payment(p_payment_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_payment public.customer_payments%rowtype;
  v_bdo uuid;
  v_marketer uuid;
  v_partner uuid;
  v_job_status text;
  v_service_code text;
  v_customer_price numeric(14,2);
  v_plan public.commission_plans%rowtype;
begin
  select pay.* into v_payment
  from public.customer_payments pay
  where pay.id=p_payment_id and pay.status='received' and pay.currency='NGN';
  if not found then return; end if;

  select c.assigned_bdo_id,c.referred_by_marketer_id,j.partner_id,j.status::text,
    s.code,o.customer_price
  into v_bdo,v_marketer,v_partner,v_job_status,v_service_code,v_customer_price
  from public.jobs j
  join public.orders o on o.id=j.order_id
  join public.customers c on c.id=o.customer_id
  join public.services s on s.id=o.service_id
  join public.service_requests r on r.id=o.service_request_id
  join public.delivery_quote_windows w on w.request_id=r.id
  join public.customer_delivery_quotes q on q.request_id=r.id and q.status='accepted'
  where j.id=v_payment.job_id and j.status in ('delivered','closed');
  if not found or v_bdo is null or v_marketer is not null or not public.has_role(v_bdo,'bdo')
    or v_customer_price is null or v_payment.amount>v_customer_price then return; end if;

  select cp.* into v_plan
  from public.commission_plans cp
  where cp.bdo_id=v_bdo
    and cp.basis='collected_revenue'
    and cp.rate is not null and cp.rate between 0 and 1
    and cp.effective_from <= (v_payment.received_at at time zone 'Africa/Lagos')::date
    and (cp.effective_until is null or cp.effective_until >= (v_payment.received_at at time zone 'Africa/Lagos')::date)
    and jsonb_typeof(cp.terms->'eligible_service_codes')='array'
    and (cp.terms->'eligible_service_codes') ? v_service_code
  order by cp.effective_from desc,cp.version desc
  limit 1;
  if not found then return; end if;

  insert into public.commission_ledger(
    bdo_id,partner_id,job_id,payment_id,plan_id,eligible_amount_ngn,calculated_amount_ngn,
    status,payment_reference
  ) values (
    v_bdo,v_partner,v_payment.job_id,v_payment.id,v_plan.id,v_payment.amount,
    round(v_payment.amount*v_plan.rate,2),'calculated',v_payment.reference
  ) on conflict do nothing;
end $$;

create or replace function public.handle_customer_payment_commission()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_ledger public.commission_ledger%rowtype;
begin
  if tg_op='INSERT' then
    if new.status='received' then perform public.accrue_bdo_commission_for_payment(new.id); end if;
    return new;
  end if;

  if old.status='received' and new.status='reversed' then
    select * into v_ledger from public.commission_ledger
      where payment_id=new.id and adjustment_of is null for update;
    if found then
      update public.commission_ledger set status='reversed'
      where id=v_ledger.id and status in ('pending_eligibility','calculated','under_review','approved');
      insert into public.commission_ledger(
        bdo_id,partner_id,job_id,plan_id,eligible_amount_ngn,calculated_amount_ngn,status,
        adjustment_of,payment_reference,adjustment_reason
      ) values (
        v_ledger.bdo_id,v_ledger.partner_id,v_ledger.job_id,v_ledger.plan_id,0,
        -v_ledger.calculated_amount_ngn,'adjusted',v_ledger.id,v_ledger.payment_reference,
        coalesce(new.reversal_reason,'Receipt reversed')
      ) on conflict do nothing;
      insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
      values('commission_ledger',v_ledger.id,'receipt_reversed_commission_adjusted',auth.uid(),
        array['status','calculated_amount_ngn','adjustment_of','adjustment_reason']);
    end if;
  end if;
  return new;
end $$;

create trigger customer_payments_commission_accrual
after insert on public.customer_payments
for each row execute function public.handle_customer_payment_commission();
create trigger customer_payments_commission_reversal
after update of status on public.customer_payments
for each row execute function public.handle_customer_payment_commission();

create or replace function public.handle_job_completion_commissions()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_payment_id uuid;
begin
  if new.status in ('delivered','closed') and new.status is distinct from old.status then
    for v_payment_id in select id from public.customer_payments where job_id=new.id and status='received' order by received_at,id loop
      perform public.accrue_bdo_commission_for_payment(v_payment_id);
    end loop;
  end if;
  return new;
end $$;
create trigger jobs_accrue_commissions_on_completion
after update of status on public.jobs
for each row execute function public.handle_job_completion_commissions();

revoke all on function public.accrue_bdo_commission_for_payment(uuid),
  public.handle_customer_payment_commission(),public.handle_job_completion_commissions()
  from public,anon,authenticated;

comment on function public.accrue_bdo_commission_for_payment(uuid) is
  'Creates idempotent direct-BDO commission ledger entries from Finance-recorded NGN receipts on delivered accepted-quote jobs with an effective collected-revenue plan that covers the service. Marketer-attributed customers and unsupported bases are excluded.';
