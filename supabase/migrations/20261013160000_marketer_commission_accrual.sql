-- Marketer commissions are approved separately from BDO plans and accrue only
-- on completed, accepted-quote jobs with an effective signed plan.
create table public.marketer_commission_plans (
  id uuid primary key default gen_random_uuid(),
  marketer_user_id uuid not null references auth.users(id) on delete restrict,
  version integer not null check (version > 0),
  rate numeric(12,6) not null check (rate between 0 and 1),
  terms jsonb not null check (jsonb_typeof(terms) = 'object'),
  effective_from date not null,
  effective_until date,
  approved_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (marketer_user_id, version),
  check (effective_until is null or effective_until >= effective_from),
  check (nullif(btrim(terms->>'agreement_reference'), '') is not null),
  check (coalesce(jsonb_typeof(terms->'eligible_service_codes') = 'array', false))
);

create table public.marketer_commission_ledger (
  id uuid primary key default gen_random_uuid(),
  marketer_user_id uuid not null references auth.users(id) on delete restrict,
  bdo_id uuid not null references auth.users(id) on delete restrict,
  job_id uuid not null references public.jobs(id) on delete restrict,
  payment_id uuid references public.customer_payments(id) on delete restrict,
  plan_id uuid not null references public.marketer_commission_plans(id) on delete restrict,
  eligible_amount_ngn numeric(14,2) not null check (eligible_amount_ngn >= 0),
  calculated_amount_ngn numeric(14,2) not null,
  status text not null check (status in ('calculated','under_review','approved','paid','reversed','adjusted')),
  adjustment_of uuid references public.marketer_commission_ledger(id) on delete restrict,
  adjustment_reason text check (adjustment_reason is null or length(btrim(adjustment_reason)) between 10 and 500),
  payment_reference text,
  created_at timestamptz not null default now()
);
create index marketer_commission_ledger_user_idx on public.marketer_commission_ledger(marketer_user_id,created_at desc);
create unique index marketer_commission_payment_once_idx on public.marketer_commission_ledger(payment_id,plan_id)
  where payment_id is not null and adjustment_of is null;
create unique index marketer_commission_adjustment_once_idx on public.marketer_commission_ledger(adjustment_of)
  where adjustment_of is not null;
alter table public.marketer_commission_plans enable row level security;
alter table public.marketer_commission_ledger enable row level security;
revoke all on public.marketer_commission_plans,public.marketer_commission_ledger from public,anon,authenticated;
grant select on public.marketer_commission_plans,public.marketer_commission_ledger to authenticated;
create policy marketer_commission_plan_read on public.marketer_commission_plans for select to authenticated
  using (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')
    or (marketer_user_id=auth.uid() and public.has_role(auth.uid(),'marketer')));
create policy marketer_commission_ledger_read on public.marketer_commission_ledger for select to authenticated
  using (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')
    or (marketer_user_id=auth.uid() and public.has_role(auth.uid(),'marketer')));

create or replace function public.approve_marketer_commission_plan(
  p_marketer_user_id uuid,p_rate numeric,p_terms jsonb,p_effective_from date,p_reason text
) returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_id uuid; v_version integer;
begin
  if not (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Management approval required'; end if;
  if not public.has_role(p_marketer_user_id,'marketer') or p_rate is null or p_rate<0 or p_rate>1
    or p_effective_from is null or p_effective_from<current_date
    or p_terms is null or jsonb_typeof(p_terms)<>'object'
    or nullif(btrim(p_terms->>'agreement_reference'),'') is null
    or not coalesce(jsonb_typeof(p_terms->'eligible_service_codes')='array',false)
    or coalesce(jsonb_array_length(case when jsonb_typeof(p_terms->'eligible_service_codes')='array'
      then p_terms->'eligible_service_codes' else '[]'::jsonb end),0)=0
    or nullif(btrim(p_reason),'') is null
    or not exists(select 1 from public.bdo_marketers bm where bm.marketer_user_id=p_marketer_user_id and bm.active
      and public.has_role(bm.bdo_user_id,'bdo')) then
    raise check_violation using message='Active marketer, rate, signed agreement, eligible services, effective date and approval reason required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_marketer_user_id::text,1));
  if exists(select 1 from public.marketer_commission_plans where marketer_user_id=p_marketer_user_id and effective_from>=p_effective_from) then
    raise check_violation using message='New plan must start after the existing plan'; end if;
  update public.marketer_commission_plans set effective_until=p_effective_from-1
    where marketer_user_id=p_marketer_user_id and effective_until is null;
  select coalesce(max(version),0)+1 into v_version from public.marketer_commission_plans where marketer_user_id=p_marketer_user_id;
  insert into public.marketer_commission_plans(marketer_user_id,version,rate,terms,effective_from,approved_by)
    values(p_marketer_user_id,v_version,p_rate,p_terms,p_effective_from,auth.uid()) returning id into v_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('marketer_commission_plan',v_id,'approved:'||btrim(p_reason),auth.uid(),array['version','rate','terms','effective_from']);
  return v_id;
end $$;
revoke all on function public.approve_marketer_commission_plan(uuid,numeric,jsonb,date,text) from public,anon;
grant execute on function public.approve_marketer_commission_plan(uuid,numeric,jsonb,date,text) to authenticated;

create or replace function public.accrue_marketer_commission_for_payment(p_payment_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_pay public.customer_payments%rowtype; v_marketer uuid; v_bdo uuid; v_job uuid;
  v_service text; v_price numeric(14,2); v_plan public.marketer_commission_plans%rowtype;
begin
  select * into v_pay from public.customer_payments where id=p_payment_id and status='received' and currency='NGN';
  if not found then return; end if;
  select c.referred_by_marketer_id,c.assigned_bdo_id,j.id,s.code,o.customer_price
    into v_marketer,v_bdo,v_job,v_service,v_price
    from public.jobs j join public.orders o on o.id=j.order_id join public.customers c on c.id=o.customer_id
    join public.services s on s.id=o.service_id join public.service_requests r on r.id=o.service_request_id
    join public.delivery_quote_windows w on w.request_id=r.id
    join public.customer_delivery_quotes q on q.request_id=r.id and q.status='accepted'
    where j.id=v_pay.job_id and j.status in ('delivered','closed');
  if not found or v_marketer is null or v_bdo is null or v_price is null or v_pay.amount>v_price
    or not public.has_role(v_marketer,'marketer') or not public.has_role(v_bdo,'bdo')
    or not exists(select 1 from public.bdo_marketers bm where bm.marketer_user_id=v_marketer
      and bm.bdo_user_id=v_bdo and bm.active) then return; end if;
  select * into v_plan from public.marketer_commission_plans p
    where p.marketer_user_id=v_marketer and p.effective_from<=(v_pay.received_at at time zone 'Africa/Lagos')::date
      and (p.effective_until is null or p.effective_until>=(v_pay.received_at at time zone 'Africa/Lagos')::date)
      and p.terms->'eligible_service_codes' ? v_service
    order by p.effective_from desc,p.version desc limit 1;
  if not found then return; end if;
  insert into public.marketer_commission_ledger(marketer_user_id,bdo_id,job_id,payment_id,plan_id,
    eligible_amount_ngn,calculated_amount_ngn,status,payment_reference)
    values(v_marketer,v_bdo,v_job,v_pay.id,v_plan.id,v_pay.amount,round(v_pay.amount*v_plan.rate,2),'calculated',v_pay.reference)
    on conflict do nothing;
end $$;

create or replace function public.list_my_marketer_commissions()
returns table(id uuid,job_id uuid,eligible_amount_ngn numeric,calculated_amount_ngn numeric,status text,
  payment_reference text,created_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.has_role(auth.uid(),'marketer') or not exists(select 1 from public.bdo_marketers
    where marketer_user_id=auth.uid() and active) then raise insufficient_privilege using message='Active marketer access required'; end if;
  return query select l.id,l.job_id,l.eligible_amount_ngn,l.calculated_amount_ngn,l.status,l.payment_reference,l.created_at
    from public.marketer_commission_ledger l where l.marketer_user_id=auth.uid()
    order by l.created_at desc,l.id desc limit 500;
end $$;
revoke all on function public.list_my_marketer_commissions() from public,anon;
grant execute on function public.list_my_marketer_commissions() to authenticated;

-- Add marketer accrual and receipt reversal handling to the existing Finance trigger.
create or replace function public.handle_customer_payment_commission()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_ledger public.commission_ledger%rowtype; v_marketer_ledger public.marketer_commission_ledger%rowtype;
begin
  if tg_op='INSERT' then
    if new.status='received' then
      perform public.accrue_bdo_commission_for_payment(new.id);
      perform public.accrue_marketer_commission_for_payment(new.id);
    end if;
    return new;
  end if;
  if old.status='received' and new.status='reversed' then
    select * into v_ledger from public.commission_ledger where payment_id=new.id and adjustment_of is null for update;
    if found then
      update public.commission_ledger set status='reversed' where id=v_ledger.id and status in ('pending_eligibility','calculated','under_review','approved');
      insert into public.commission_ledger(bdo_id,partner_id,job_id,plan_id,eligible_amount_ngn,calculated_amount_ngn,status,
        adjustment_of,payment_reference,adjustment_reason)
        values(v_ledger.bdo_id,v_ledger.partner_id,v_ledger.job_id,v_ledger.plan_id,0,-v_ledger.calculated_amount_ngn,
          'adjusted',v_ledger.id,v_ledger.payment_reference,coalesce(new.reversal_reason,'Receipt reversed')) on conflict do nothing;
      insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
        values('commission_ledger',v_ledger.id,'receipt_reversed_commission_adjusted',auth.uid(),array['status','calculated_amount_ngn','adjustment_of','adjustment_reason']);
    end if;
    select * into v_marketer_ledger from public.marketer_commission_ledger where payment_id=new.id and adjustment_of is null for update;
    if found then
      update public.marketer_commission_ledger set status='reversed' where id=v_marketer_ledger.id and status in ('calculated','under_review','approved');
      insert into public.marketer_commission_ledger(marketer_user_id,bdo_id,job_id,plan_id,eligible_amount_ngn,
        calculated_amount_ngn,status,adjustment_of,payment_reference,adjustment_reason)
        values(v_marketer_ledger.marketer_user_id,v_marketer_ledger.bdo_id,v_marketer_ledger.job_id,v_marketer_ledger.plan_id,
          0,-v_marketer_ledger.calculated_amount_ngn,'adjusted',v_marketer_ledger.id,v_marketer_ledger.payment_reference,
          coalesce(new.reversal_reason,'Receipt reversed')) on conflict do nothing;
      insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
        values('marketer_commission_ledger',v_marketer_ledger.id,'receipt_reversed_commission_adjusted',auth.uid(),
          array['status','calculated_amount_ngn','adjustment_of','adjustment_reason']);
    end if;
  end if;
  return new;
end $$;

create or replace function public.handle_job_completion_commissions()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_payment_id uuid;
begin
  if new.status in ('delivered','closed') and new.status is distinct from old.status then
    for v_payment_id in select id from public.customer_payments where job_id=new.id and status='received' order by received_at,id loop
      perform public.accrue_bdo_commission_for_payment(v_payment_id);
      perform public.accrue_marketer_commission_for_payment(v_payment_id);
    end loop;
  end if;
  return new;
end $$;
revoke all on function public.accrue_marketer_commission_for_payment(uuid) from public,anon,authenticated;
revoke all on function public.handle_customer_payment_commission(),public.handle_job_completion_commissions() from public,anon,authenticated;
comment on table public.marketer_commission_ledger is 'Approved-plan marketer earnings from completed, accepted-quote NGN receipts; separate from BDO and payout calculations.';
