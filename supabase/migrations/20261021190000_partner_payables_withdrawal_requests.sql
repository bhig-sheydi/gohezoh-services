-- A company may reserve its earned delivery fee for a Finance-reviewed payout.
-- The customer payment is the merchant receipt; this is not a stored-value wallet.
create table public.partner_withdrawals (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.logistics_partners(id) on delete restrict,
  requested_by uuid not null references auth.users(id) on delete restrict,
  amount_ngn numeric(14,2) not null check (amount_ngn > 0),
  idempotency_key uuid not null,
  created_at timestamptz not null default now(),
  unique (partner_id, idempotency_key)
);

alter table public.partner_settlements
  add column withdrawal_id uuid references public.partner_withdrawals(id) on delete restrict;
create index partner_settlements_withdrawal_idx on public.partner_settlements(withdrawal_id)
  where withdrawal_id is not null;
create index jobs_partner_payables_idx on public.jobs(partner_id, status, created_at, id)
  where partner_id is not null;

alter table public.partner_withdrawals enable row level security;
revoke all on public.partner_withdrawals from public, anon, authenticated;
grant select on public.partner_withdrawals to authenticated;
create policy partner_withdrawals_read on public.partner_withdrawals for select to authenticated
  using (
    exists (select 1 from public.partner_users pu where pu.partner_id=partner_withdrawals.partner_id
      and pu.user_id=auth.uid() and pu.membership_role='manager')
    or public.has_role(auth.uid(),'finance') or public.has_role(auth.uid(),'management')
    or public.has_role(auth.uid(),'admin')
  );

-- Returned amounts are authored from the settled customer receipt and immutable
-- job financials, never from a browser-provided bid or a mutable balance cell.
create function public.get_my_partner_payables()
returns table(partner_id uuid,currency text,available_ngn numeric,pending_delivery_ngn numeric,
  withdrawal_pending_ngn numeric,total_paid_ngn numeric)
language sql stable security definer set search_path=pg_catalog,public as $$
  with mine as (
    select p.id from public.logistics_partners p
    join public.partner_users pu on pu.partner_id=p.id
    where pu.user_id=auth.uid() and pu.membership_role='manager' and p.status='active'
  ), fees as (
    select j.id job_id,j.partner_id,j.status, f.partner_cost,
      coalesce((select sum(cp.amount) from public.customer_payments cp
        where cp.job_id=j.id and cp.status='received' and cp.currency='NGN'),0) received,
      f.customer_revenue
    from public.jobs j join mine m on m.id=j.partner_id
    join public.job_financials f on f.job_id=j.id and f.currency='NGN'
    where j.status<>'cancelled'
  ), commitments as (
    select s.job_id,
      coalesce(sum(s.amount) filter (where s.status<>'cancelled'),0) committed,
      coalesce(sum(s.amount) filter (where s.status in ('pending','approved') and s.withdrawal_id is not null),0) withdrawal_pending,
      coalesce(sum(s.amount) filter (where s.status='paid'),0) paid
    from public.partner_settlements s join fees f on f.job_id=s.job_id
    group by s.job_id
  )
  select m.id,'NGN'::text,
    coalesce(sum(greatest(f.partner_cost-coalesce(c.committed,0),0)) filter
      (where f.status in ('delivered','closed') and f.received>=f.customer_revenue),0)::numeric,
    coalesce(sum(f.partner_cost) filter
      (where f.status not in ('delivered','closed') and f.received>=f.customer_revenue),0)::numeric,
    coalesce(sum(c.withdrawal_pending),0)::numeric,
    coalesce(sum(c.paid),0)::numeric
  from mine m left join fees f on f.partner_id=m.id
  left join commitments c on c.job_id=f.job_id
  group by m.id;
$$;
revoke all on function public.get_my_partner_payables() from public,anon;
grant execute on function public.get_my_partner_payables() to authenticated;

-- Lock the company and each funded job before reserving any fee. Existing
-- Finance-created settlements count against the same job, preventing double pay.
create function public.request_partner_withdrawal(
  p_partner_id uuid,p_amount_ngn numeric,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_actor uuid := auth.uid(); v_partner public.logistics_partners%rowtype;
  v_existing public.partner_withdrawals%rowtype; v_withdrawal uuid;
  v_job record; v_committed numeric; v_remaining numeric; v_take numeric;
  v_received numeric; v_reserved numeric := 0; v_count integer := 0;
begin
  if v_actor is null or p_partner_id is null or p_idempotency_key is null
     or p_amount_ngn is null or p_amount_ngn<=0 or p_amount_ngn<>round(p_amount_ngn,2) then
    raise check_violation using message='Enter a valid withdrawal amount';
  end if;
  select * into v_partner from public.logistics_partners where id=p_partner_id for update;
  if not found or v_partner.status<>'active' or not exists (
    select 1 from public.partner_users pu where pu.partner_id=p_partner_id
      and pu.user_id=v_actor and pu.membership_role='manager') then
    raise insufficient_privilege using message='An active company manager is required';
  end if;
  select * into v_existing from public.partner_withdrawals
    where partner_id=p_partner_id and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.amount_ngn<>p_amount_ngn then
      raise check_violation using message='This withdrawal key was used for a different amount';
    end if;
    return jsonb_build_object('withdrawal_id',v_existing.id,'status','pending',
      'amount_ngn',v_existing.amount_ngn);
  end if;

  -- No row is committed if the requested amount cannot be fully covered.
  insert into public.partner_withdrawals(partner_id,requested_by,amount_ngn,idempotency_key)
    values(p_partner_id,v_actor,p_amount_ngn,p_idempotency_key) returning id into v_withdrawal;
  v_remaining := p_amount_ngn;
  for v_job in
    select j.id, f.partner_cost, f.customer_revenue
    from public.jobs j join public.job_financials f on f.job_id=j.id
    where j.partner_id=p_partner_id and j.status in ('delivered','closed')
      and f.currency='NGN' and f.partner_cost>0
    order by j.created_at,j.id for update of j
  loop
    select coalesce(sum(cp.amount),0) into v_received from public.customer_payments cp
      where cp.job_id=v_job.id and cp.status='received' and cp.currency='NGN';
    if v_received < v_job.customer_revenue then continue; end if;
    select coalesce(sum(s.amount),0) into v_committed from public.partner_settlements s
      where s.job_id=v_job.id and s.status<>'cancelled';
    v_take := least(v_remaining,greatest(v_job.partner_cost-v_committed,0));
    if v_take<=0 then continue; end if;
    insert into public.partner_settlements(job_id,partner_id,amount,currency,
      request_reference,notes,created_by,withdrawal_id)
    values(v_job.id,p_partner_id,v_take,'NGN',
      'partner-withdrawal:'||v_withdrawal::text||':'||v_job.id::text,
      'Partner-requested payout; Finance must verify beneficiary and transfer manually',v_actor,v_withdrawal);
    v_reserved := v_reserved+v_take;
    v_remaining := v_remaining-v_take;
    v_count := v_count+1;
    exit when v_remaining=0;
  end loop;
  if v_remaining<>0 then
    raise check_violation using message='Withdrawal exceeds the available company earnings';
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('partner_withdrawal',v_withdrawal,'requested',v_actor,array['partner_id','amount_ngn','job_count']);
  return jsonb_build_object('withdrawal_id',v_withdrawal,'status','pending',
    'amount_ngn',v_reserved,'settlement_count',v_count);
end $$;
revoke all on function public.request_partner_withdrawal(uuid,numeric,uuid) from public,anon;
grant execute on function public.request_partner_withdrawal(uuid,numeric,uuid) to authenticated;

comment on table public.partner_withdrawals is
  'Partner payout requests. Each request reserves one or more Finance-visible settlements; no money is transferred by this table.';
-- Future local deliveries pay the company 75% and retain a 25% platform fee.
create or replace function public.settle_flutterwave_hold(p_reference text,p_transaction_id bigint,p_amount_ngn numeric,p_currency text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_hold public.customer_payment_holds%rowtype;v_request public.service_requests%rowtype;
  v_bid public.partner_quotes%rowtype;v_order_id uuid;v_job_id uuid;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v_hold from public.customer_payment_holds where reference=p_reference for update;
  if not found then raise no_data_found using message='Unknown payment reference'; end if;
  if v_hold.status='paid' and v_hold.provider_transaction_id=p_transaction_id then
    return jsonb_build_object('status','paid','request_id',v_hold.request_id); end if;
  if p_transaction_id is null or p_transaction_id<=0 or p_currency<>'NGN' or p_amount_ngn is distinct from v_hold.amount_ngn then
    raise check_violation using message='Verified payment does not match the booking'; end if;
  if v_hold.status<>'pending' or now()>=v_hold.expires_at then
    update public.customer_payment_holds set status='review',provider_transaction_id=p_transaction_id,updated_at=now()
      where request_id=v_hold.request_id and status<>'paid';
    update public.customer_delivery_quotes set status='expired' where request_id=v_hold.request_id and status='accepted';
    return jsonb_build_object('status','review','request_id',v_hold.request_id);
  end if;
  select * into v_request from public.service_requests where id=v_hold.request_id for update;
  select * into v_bid from public.partner_quotes where id=v_hold.bid_id;
  if v_request.status not in ('submitted','under_review') or v_bid.status<>'selected' then
    raise object_not_in_prerequisite_state using message='Booking is no longer available'; end if;
  insert into public.orders(service_request_id,customer_id,service_id,status,customer_price,confirmed_at)
    values(v_request.id,v_request.customer_id,v_request.service_id,'confirmed',v_hold.amount_ngn,now()) returning id into v_order_id;
  insert into public.jobs(order_id,customer_id,service_id,partner_id,status,pickup_address,pickup_city,pickup_state,
    sender_name,sender_phone,delivery_address,delivery_city,delivery_state,recipient_name,recipient_phone,preferred_pickup_at)
    values(v_order_id,v_request.customer_id,v_request.service_id,v_bid.partner_id,'partner_assigned',v_request.pickup_address,
      v_request.pickup_city,v_request.pickup_state,v_request.sender_name,v_request.sender_phone,v_request.delivery_address,
      v_request.delivery_city,v_request.delivery_state,v_request.recipient_name,v_request.recipient_phone,v_request.preferred_pickup_at)
    returning id into v_job_id;
  insert into public.job_financials(job_id,customer_revenue,partner_cost,other_direct_cost,currency)
    values(v_job_id,v_hold.amount_ngn,round(v_hold.amount_ngn*0.75,2),0,'NGN');
  insert into public.customer_payments(job_id,amount,currency,method,reference,notes,recorded_by)
    values(v_job_id,v_hold.amount_ngn,'NGN','online',p_reference,'Verified Flutterwave temporary account',null);
  insert into public.partner_assignments(job_id,partner_id,status,responded_at,response_note)
    values(v_job_id,v_bid.partner_id,'accepted',now(),'Accepted through company bid');
  update public.service_requests set status='converted' where id=v_request.id;
  update public.customer_payment_holds set status='paid',provider_transaction_id=p_transaction_id,updated_at=now()
    where request_id=v_hold.request_id;
  return jsonb_build_object('status','paid','request_id',v_hold.request_id,'job_id',v_job_id);
end $$;

create or replace function public.select_customer_partner_bid(p_request_id uuid,p_bid_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_window public.delivery_quote_windows%rowtype;v_bid public.partner_quotes%rowtype;v_service_code text;
begin
  select * into v_window from public.delivery_quote_windows where request_id=p_request_id for update;
  if not found or v_window.status not in ('open','awaiting_customer_selection') or now()<v_window.deadline_at then
    raise object_not_in_prerequisite_state using message='Company selection is not available yet'; end if;
  if not exists(select 1 from public.service_requests r where r.id=p_request_id and public.is_customer_user(r.customer_id)) then
    raise insufficient_privilege using message='Only this customer can choose a company'; end if;
  select q.* into v_bid from public.partner_quotes q join public.logistics_partners p on p.id=q.partner_id and p.status='active'
  where q.id=p_bid_id and q.request_id=p_request_id and q.status='valid' and q.submitted_at<v_window.deadline_at for update of q;
  if not found then raise check_violation using message='Choose an available company bid'; end if;
  if exists(select 1 from public.customer_delivery_quotes where request_id=p_request_id) then
    raise object_not_in_prerequisite_state using message='A company has already been chosen'; end if;
  select s.code into v_service_code from public.service_requests r join public.services s on s.id=r.service_id where r.id=p_request_id;
  if v_service_code='SRV-0001' then
    if v_bid.amount_ngn<>trunc(v_bid.amount_ngn) then
      raise check_violation using message='This bid must be a whole-naira amount to create a temporary bank account'; end if;
    if not exists(select 1 from public.company_bid_invitations i where i.request_id=p_request_id and i.partner_id=v_bid.partner_id) then
      raise check_violation using message='This company no longer has a rider for this pickup'; end if;
  end if;
  update public.partner_quotes set status='selected' where id=v_bid.id;
  update public.delivery_quote_windows set status='quoted',closed_at=now() where request_id=p_request_id;
  if v_service_code='SRV-0001' then
    insert into public.customer_delivery_quotes(request_id,winning_bid_id,total_direct_cost_ngn,unrounded_price_ngn,
      customer_price_ngn,formula_version,status,expires_at,accepted_at)
    values(p_request_id,v_bid.id,round(v_bid.amount_ngn*0.75,2),v_bid.amount_ngn,
      v_bid.amount_ngn,'selected-bid-partner-net-75-v2','accepted',now()+interval '2 minutes',now());
    insert into public.customer_payment_holds(request_id,bid_id,reference,amount_ngn,expires_at)
    values(p_request_id,v_bid.id,'KP-'||replace(gen_random_uuid()::text,'-',''),v_bid.amount_ngn,now()+interval '2 minutes');
  else
    insert into public.customer_delivery_quotes(request_id,winning_bid_id,total_direct_cost_ngn,unrounded_price_ngn)
    values(p_request_id,v_bid.id,v_bid.amount_ngn,round(v_bid.amount_ngn/0.75,4));
  end if;
end $$;

-- The dashboard's daily earnings must reflect paid, completed work, not only
-- settlements someone has already requested or Finance has approved.
create or replace function public.my_partner_company_welcome(p_day_start timestamptz,p_day_end timestamptz)
returns table(partner_id uuid,partner_name text,ceo_name text,logo_path text,earnings_ngn numeric)
language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
begin
  if auth.uid() is null or p_day_start is null or p_day_end is null or p_day_end<=p_day_start
     or p_day_end-p_day_start>interval '26 hours' then
    raise invalid_parameter_value using message='Invalid local day';
  end if;
  return query
  select p.id,p.partner_name,p.contact_person,p.logo_path,
    coalesce((select sum(f.partner_cost) from public.jobs j
      join public.job_financials f on f.job_id=j.id and f.currency='NGN'
      where j.partner_id=p.id and j.status in ('delivered','closed')
        and exists(select 1 from public.job_status_history h where h.job_id=j.id
          and h.new_status='delivered' and h.changed_at>=p_day_start and h.changed_at<p_day_end)
        and (select coalesce(sum(cp.amount),0) from public.customer_payments cp
          where cp.job_id=j.id and cp.status='received' and cp.currency='NGN')>=f.customer_revenue),0)::numeric
  from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
  where pu.user_id=auth.uid() and pu.membership_role='manager'
  order by p.partner_name;
end $$;
