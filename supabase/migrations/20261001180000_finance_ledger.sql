-- Finance-controlled job pricing, customer receipts, and partner settlements.

create sequence public.payment_number_seq start 1;
create sequence public.settlement_number_seq start 1;

create table public.customer_payments (
  id uuid primary key default gen_random_uuid(),
  payment_number text not null unique default ('PAY-' || lpad(nextval('public.payment_number_seq')::text, 5, '0')),
  job_id uuid not null references public.jobs(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  method text not null check (method in ('bank_transfer', 'cash', 'pos', 'online', 'other')),
  status text not null default 'received' check (status in ('received', 'reversed')),
  reference text,
  notes text,
  received_at timestamptz not null default now(),
  recorded_by uuid not null references auth.users(id) on delete restrict,
  reversed_by uuid references auth.users(id) on delete set null,
  reversed_at timestamptz,
  reversal_reason text,
  created_at timestamptz not null default now(),
  check (reference is null or length(btrim(reference)) between 1 and 120),
  check (notes is null or length(notes) <= 1000),
  check ((status='received' and reversed_by is null and reversed_at is null and reversal_reason is null)
      or (status='reversed' and reversed_by is not null and reversed_at is not null and length(btrim(reversal_reason)) between 10 and 500))
);

create table public.partner_settlements (
  id uuid primary key default gen_random_uuid(),
  settlement_number text not null unique default ('STL-' || lpad(nextval('public.settlement_number_seq')::text, 5, '0')),
  job_id uuid not null references public.jobs(id) on delete restrict,
  partner_id uuid not null references public.logistics_partners(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  status text not null default 'pending' check (status in ('pending', 'approved', 'paid', 'cancelled')),
  request_reference text not null,
  reference text,
  notes text,
  created_by uuid not null references auth.users(id) on delete restrict,
  approved_by uuid references auth.users(id) on delete set null,
  paid_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  approved_at timestamptz,
  paid_at timestamptz,
  check (reference is null or length(btrim(reference)) between 1 and 120),
  check (length(btrim(request_reference)) between 1 and 120),
  check (notes is null or length(notes) <= 1000)
);

create index customer_payments_job_received_idx on public.customer_payments(job_id, received_at desc);
create index partner_settlements_status_created_idx on public.partner_settlements(status, created_at desc);
create index partner_settlements_job_idx on public.partner_settlements(job_id);
create unique index customer_payments_reference_per_job_idx on public.customer_payments(job_id,reference) where reference is not null;
create unique index partner_settlements_reference_per_job_idx on public.partner_settlements(job_id,request_reference);
create unique index partner_settlements_transfer_reference_per_job_idx on public.partner_settlements(job_id,reference) where reference is not null;

create or replace function public.prevent_financial_order_edits_after_job()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if (new.customer_price is distinct from old.customer_price or new.currency is distinct from old.currency)
     and exists(select 1 from public.jobs j where j.order_id=old.id) then
    raise object_not_in_prerequisite_state using message='Order price and currency cannot change after a delivery job is created';
  end if;
  return new;
end $$;
create trigger orders_financial_values_immutable_after_job
before update of customer_price,currency on public.orders
for each row execute function public.prevent_financial_order_edits_after_job();
revoke all on function public.prevent_financial_order_edits_after_job() from public,anon,authenticated;

alter table public.customer_payments enable row level security;
alter table public.partner_settlements enable row level security;

revoke all on public.customer_payments, public.partner_settlements from anon, authenticated;
grant select on public.customer_payments, public.partner_settlements to authenticated;
revoke insert, update, delete on public.job_financials from authenticated;
grant select on public.job_financials to authenticated;

create policy customer_payments_read_finance on public.customer_payments
  for select to authenticated
  using (public.has_role(auth.uid(), 'finance') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));
create policy partner_settlements_read_finance on public.partner_settlements
  for select to authenticated
  using (public.has_role(auth.uid(), 'finance') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create or replace function public.save_job_financials(
  p_job_id uuid,
  p_partner_cost numeric,
  p_other_direct_cost numeric default 0
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_job public.jobs%rowtype;
  v_financials public.job_financials%rowtype;
  v_customer_revenue numeric;
  v_currency text;
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not (
    public.has_role(v_actor, 'finance') or public.has_role(v_actor, 'admin') or public.has_role(v_actor, 'management')
  ) then
    raise insufficient_privilege using message = 'Only Finance or management can save job financials';
  end if;
  if p_partner_cost is null or p_partner_cost < 0
     or p_other_direct_cost is null or p_other_direct_cost < 0 then
    raise check_violation using message = 'Enter non-negative financial amounts';
  end if;
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found then raise no_data_found using message = 'Job was not found'; end if;
  select customer_price,currency into v_customer_revenue,v_currency from public.orders where id=v_job.order_id;
  if v_customer_revenue is null then raise object_not_in_prerequisite_state using message = 'The confirmed order must have a customer price before finance can save costs'; end if;
  if coalesce((select sum(amount) from public.customer_payments where job_id = p_job_id and status='received'), 0) > v_customer_revenue then
    raise check_violation using message = 'Revenue cannot be lower than customer payments already received';
  end if;
  if coalesce((select sum(amount) from public.partner_settlements where job_id = p_job_id and status <> 'cancelled'), 0) > p_partner_cost then
    raise check_violation using message = 'Partner cost cannot be lower than active settlements';
  end if;
  insert into public.job_financials(job_id, customer_revenue, partner_cost, other_direct_cost, currency, updated_by)
  values (p_job_id, v_customer_revenue, p_partner_cost, p_other_direct_cost, v_currency, v_actor)
  on conflict (job_id) do update set
    customer_revenue = excluded.customer_revenue,
    partner_cost = excluded.partner_cost,
    other_direct_cost = excluded.other_direct_cost,
    currency = excluded.currency,
    updated_by = excluded.updated_by
  returning * into v_financials;
  insert into public.audit_logs(entity_type, entity_id, action, actor_id, changed_fields)
  values ('job_financials', p_job_id, 'upsert', v_actor, array['customer_revenue','partner_cost','other_direct_cost','currency']);
  return jsonb_build_object('job_id', v_financials.job_id, 'currency', v_financials.currency);
end;
$$;

create or replace function public.record_customer_payment(
  p_job_id uuid,
  p_amount numeric,
  p_method text,
  p_reference text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_actor uuid := auth.uid();
  v_job public.jobs%rowtype;
  v_currency text;
  v_revenue numeric;
  v_received numeric;
  v_payment public.customer_payments%rowtype;
begin
  if v_actor is null or not (
    public.has_role(v_actor, 'finance') or public.has_role(v_actor, 'admin') or public.has_role(v_actor, 'management')
  ) then
    raise insufficient_privilege using message = 'Only Finance or management can record customer payments';
  end if;
  if p_amount is null or p_amount <= 0 or p_method not in ('bank_transfer','cash','pos','online','other')
     or p_reference is null or length(btrim(p_reference)) not between 1 and 120
     or (p_notes is not null and length(p_notes) > 1000) then
    raise check_violation using message = 'Enter a positive payment, valid method, and reference or notes within the allowed length';
  end if;
  select * into v_job from public.jobs where id=p_job_id for update;
  if not found then raise no_data_found using message = 'Job was not found'; end if;
  select f.currency, f.customer_revenue into v_currency, v_revenue
  from public.job_financials f where f.job_id = p_job_id for update;
  if not found then raise object_not_in_prerequisite_state using message = 'Save the job financials before recording a payment'; end if;
  select coalesce(sum(amount),0) into v_received from public.customer_payments where job_id=p_job_id and status='received';
  if v_received + p_amount > v_revenue then raise check_violation using message = 'Payment exceeds the remaining customer balance'; end if;
  insert into public.customer_payments(job_id, amount, currency, method, reference, notes, recorded_by)
  values (p_job_id, p_amount, v_currency, p_method, nullif(btrim(p_reference), ''), nullif(btrim(p_notes), ''), v_actor)
  returning * into v_payment;
  insert into public.audit_logs(entity_type, entity_id, action, actor_id, changed_fields)
  values ('customer_payment', v_payment.id, 'recorded', v_actor, array['job_id','amount','currency','method','reference']);
  return jsonb_build_object('payment_id', v_payment.id, 'payment_number', v_payment.payment_number, 'status', 'received');
end;
$$;

create or replace function public.create_partner_settlement(
  p_job_id uuid,
  p_amount numeric,
  p_request_reference text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_actor uuid := auth.uid();
  v_job public.jobs%rowtype;
  v_currency text;
  v_partner_cost numeric;
  v_committed numeric;
  v_settlement public.partner_settlements%rowtype;
begin
  if v_actor is null or not (
    public.has_role(v_actor, 'finance') or public.has_role(v_actor, 'admin') or public.has_role(v_actor, 'management')
  ) then
    raise insufficient_privilege using message = 'Only Finance or management can create partner settlements';
  end if;
  if p_amount is null or p_amount <= 0
     or p_request_reference is null or length(btrim(p_request_reference)) not between 1 and 120
     or (p_notes is not null and length(p_notes) > 1000) then
    raise check_violation using message = 'Enter a positive settlement amount and valid reference or notes';
  end if;
  select * into v_job from public.jobs where id=p_job_id for update;
  if not found then raise no_data_found using message = 'Job was not found'; end if;
  if v_job.partner_id is null or v_job.status not in ('delivered','closed') then
    raise object_not_in_prerequisite_state using message = 'A settlement needs a delivered job with an assigned partner';
  end if;
  select currency, partner_cost into v_currency, v_partner_cost from public.job_financials where job_id=p_job_id for update;
  if not found then raise object_not_in_prerequisite_state using message = 'Save the job financials before creating a settlement'; end if;
  select coalesce(sum(amount),0) into v_committed from public.partner_settlements
  where job_id=p_job_id and status <> 'cancelled';
  if v_committed + p_amount > v_partner_cost then raise check_violation using message = 'Settlement exceeds the remaining approved partner cost'; end if;
  insert into public.partner_settlements(job_id, partner_id, amount, currency, request_reference, notes, created_by)
  values(p_job_id, v_job.partner_id, p_amount, v_currency, btrim(p_request_reference), nullif(btrim(p_notes), ''), v_actor)
  returning * into v_settlement;
  insert into public.audit_logs(entity_type, entity_id, action, actor_id, changed_fields)
  values ('partner_settlement', v_settlement.id, 'created', v_actor, array['job_id','partner_id','amount','currency']);
  return jsonb_build_object('settlement_id',v_settlement.id,'settlement_number',v_settlement.settlement_number,'status',v_settlement.status);
end;
$$;

create or replace function public.update_partner_settlement_status(
  p_settlement_id uuid,
  p_status text,
  p_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_actor uuid := auth.uid();
  v_settlement public.partner_settlements%rowtype;
begin
  if v_actor is null or not (
    public.has_role(v_actor, 'finance') or public.has_role(v_actor, 'admin') or public.has_role(v_actor, 'management')
  ) then
    raise insufficient_privilege using message = 'Only Finance or management can update partner settlements';
  end if;
  if p_status not in ('approved','paid','cancelled') then
    raise invalid_parameter_value using message = 'Choose approved, paid, or cancelled';
  end if;
  if p_reference is not null and length(btrim(p_reference)) not between 1 and 120 then
    raise check_violation using message = 'Settlement reference must be 1 to 120 characters';
  end if;
  select * into v_settlement from public.partner_settlements where id=p_settlement_id for update;
  if not found then raise no_data_found using message = 'Partner settlement was not found'; end if;
  if not ((v_settlement.status='pending' and p_status in ('approved','cancelled'))
       or (v_settlement.status='approved' and p_status in ('paid','cancelled'))) then
    raise object_not_in_prerequisite_state using message = 'That settlement transition is not allowed';
  end if;
  if p_status='approved' then
    if not (public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
      raise insufficient_privilege using message = 'Only management or admin can approve partner settlements';
    end if;
    if v_actor = v_settlement.created_by then
      raise insufficient_privilege using message = 'The settlement creator cannot approve the same settlement';
    end if;
  elsif p_status='paid' and v_actor = v_settlement.approved_by then
    raise insufficient_privilege using message = 'The settlement approver cannot record its payout';
  end if;
  if p_status='paid' and nullif(btrim(coalesce(p_reference, v_settlement.reference)), '') is null then
    raise check_violation using message = 'A transfer reference is required before marking a settlement paid';
  end if;
  update public.partner_settlements set
    status=p_status,
    reference=coalesce(nullif(btrim(p_reference),''),reference),
    approved_by=case when p_status='approved' then v_actor else approved_by end,
    approved_at=case when p_status='approved' then now() else approved_at end,
    paid_by=case when p_status='paid' then v_actor else paid_by end,
    paid_at=case when p_status='paid' then now() else paid_at end
  where id=p_settlement_id returning * into v_settlement;
  insert into public.audit_logs(entity_type, entity_id, action, actor_id, changed_fields)
  values ('partner_settlement', p_settlement_id, p_status, v_actor, array['status','reference']);
  return jsonb_build_object('settlement_id',v_settlement.id,'settlement_number',v_settlement.settlement_number,'status',v_settlement.status);
end;
$$;

revoke all on function public.save_job_financials(uuid,numeric,numeric) from public, anon, authenticated;
revoke all on function public.record_customer_payment(uuid,numeric,text,text,text) from public, anon, authenticated;
revoke all on function public.create_partner_settlement(uuid,numeric,text,text) from public, anon, authenticated;
revoke all on function public.update_partner_settlement_status(uuid,text,text) from public, anon, authenticated;
grant execute on function public.save_job_financials(uuid,numeric,numeric) to authenticated;
grant execute on function public.record_customer_payment(uuid,numeric,text,text,text) to authenticated;
grant execute on function public.create_partner_settlement(uuid,numeric,text,text) to authenticated;
grant execute on function public.update_partner_settlement_status(uuid,text,text) to authenticated;

comment on table public.customer_payments is 'Finance-recorded customer receipts. These rows record reconciliation; they do not charge a payment method.';
comment on table public.partner_settlements is 'Finance-controlled partner settlement requests and recorded payouts.';

create or replace function public.list_my_customer_payments()
returns table(payment_number text, job_id uuid, amount numeric, currency text, method text, received_at timestamptz, status text)
language sql stable security definer set search_path = pg_catalog, public
as $$
  select p.payment_number,p.job_id,p.amount,p.currency,p.method,p.received_at,p.status
  from public.customer_payments p join public.jobs j on j.id=p.job_id
  where public.is_customer_user(j.customer_id)
  order by p.received_at desc
$$;
revoke all on function public.list_my_customer_payments() from public, anon, authenticated;
grant execute on function public.list_my_customer_payments() to authenticated;

create or replace function public.reverse_customer_payment(p_payment_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public
as $$
declare v_actor uuid:=auth.uid(); v_payment public.customer_payments%rowtype; v_total numeric; v_revenue numeric;
begin
  if v_actor is null or not (public.has_role(v_actor,'finance') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    raise insufficient_privilege using message='Only Finance or management can reverse a customer receipt';
  end if;
  if p_reason is null or length(btrim(p_reason)) not between 10 and 500 then raise check_violation using message='Enter a reversal reason between 10 and 500 characters'; end if;
  select * into v_payment from public.customer_payments where id=p_payment_id for update;
  if not found then raise no_data_found using message='Customer receipt was not found'; end if;
  if v_payment.status<>'received' then raise object_not_in_prerequisite_state using message='Only a received payment can be reversed'; end if;
  update public.customer_payments set status='reversed',reversed_by=v_actor,reversed_at=now(),reversal_reason=btrim(p_reason) where id=p_payment_id returning * into v_payment;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields) values('customer_payment',p_payment_id,'reversed',v_actor,array['status','reversal_reason']);
  return jsonb_build_object('payment_id',p_payment_id,'status',v_payment.status);
end $$;
revoke all on function public.reverse_customer_payment(uuid,text) from public,anon,authenticated;
grant execute on function public.reverse_customer_payment(uuid,text) to authenticated;

create or replace function public.finance_dashboard_totals()
returns table(currency text,customer_revenue numeric,received numeric,outstanding numeric,partner_cost numeric,direct_cost numeric,gross_profit numeric,settlements_due numeric)
language plpgsql stable security definer set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null or not (public.has_role(auth.uid(),'finance') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')) then
    raise insufficient_privilege using message='Finance dashboard access is required';
  end if;
  return query with f as (
    select jf.currency,sum(jf.customer_revenue) revenue,sum(jf.partner_cost) partner,sum(jf.other_direct_cost) direct
    from public.job_financials jf group by jf.currency
  ), p as (
    select jf.currency,sum(cp.amount) received from public.customer_payments cp join public.job_financials jf on jf.job_id=cp.job_id where cp.status='received' group by jf.currency
  ), s as (
    select jf.currency,sum(ps.amount) due from public.partner_settlements ps join public.job_financials jf on jf.job_id=ps.job_id where ps.status in ('pending','approved') group by jf.currency
  )
  select f.currency,f.revenue,coalesce(p.received,0),greatest(f.revenue-coalesce(p.received,0),0),f.partner,f.direct,f.revenue-f.partner-f.direct,coalesce(s.due,0)
  from f left join p using(currency) left join s using(currency) order by f.currency;
end $$;
revoke all on function public.finance_dashboard_totals() from public,anon,authenticated;
grant execute on function public.finance_dashboard_totals() to authenticated;
