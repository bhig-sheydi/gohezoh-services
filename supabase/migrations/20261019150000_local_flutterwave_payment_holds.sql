-- Local dispatch: the selected company bid is the customer's price. The
-- company receives 80% of that price; the remaining 20% is the platform fee.
create table public.customer_payment_holds (
  request_id uuid primary key references public.service_requests(id) on delete restrict,
  bid_id uuid not null references public.partner_quotes(id),
  reference text not null unique,
  amount_ngn numeric(14,2) not null check(amount_ngn>=1000 and amount_ngn=trunc(amount_ngn)),
  status text not null default 'initializing' check(status in ('initializing','pending','paid','expired','review')),
  account_number text check(account_number is null or account_number ~ '^[0-9]{10}$'),
  bank_name text,
  provider_transaction_id bigint unique,
  expires_at timestamptz not null default now()+interval '2 minutes',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status='pending' and account_number is not null and bank_name is not null) or status<>'pending')
);
create index customer_payment_holds_pending_idx on public.customer_payment_holds(expires_at) where status in ('initializing','pending');
alter table public.customer_payment_holds enable row level security;
revoke all on public.customer_payment_holds from public,anon,authenticated;

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
    values(p_request_id,v_bid.id,round(v_bid.amount_ngn*0.8,2),v_bid.amount_ngn,
      v_bid.amount_ngn,'selected-bid-partner-net-80-v1','accepted',now()+interval '2 minutes',now());
    insert into public.customer_payment_holds(request_id,bid_id,reference,amount_ngn,expires_at)
    values(p_request_id,v_bid.id,'KP-'||replace(gen_random_uuid()::text,'-',''),v_bid.amount_ngn,now()+interval '2 minutes');
  else
    insert into public.customer_delivery_quotes(request_id,winning_bid_id,total_direct_cost_ngn,unrounded_price_ngn)
    values(p_request_id,v_bid.id,v_bid.amount_ngn,round(v_bid.amount_ngn/0.75,4));
  end if;
end $$;

create function public.get_my_flutterwave_hold(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_hold public.customer_payment_holds%rowtype;
begin
  if not exists(select 1 from public.service_requests r where r.id=p_request_id and public.is_customer_user(r.customer_id)) then
    raise insufficient_privilege using message='Only this customer can view the payment account'; end if;
  select * into v_hold from public.customer_payment_holds where request_id=p_request_id for update;
  if not found then return null; end if;
  if v_hold.status in ('initializing','pending') and now()>=v_hold.expires_at then
    update public.customer_payment_holds set status='expired',updated_at=now() where request_id=p_request_id;
    update public.customer_delivery_quotes set status='expired' where request_id=p_request_id and status='accepted';
    v_hold.status:='expired';
  end if;
  return jsonb_build_object('request_id',v_hold.request_id,'bid_id',v_hold.bid_id,'status',v_hold.status,'amount_ngn',v_hold.amount_ngn,
    'account_number',case when v_hold.status='pending' then v_hold.account_number else null end,
    'bank_name',case when v_hold.status='pending' then v_hold.bank_name else null end,
    'expires_at',v_hold.expires_at,'reference',v_hold.reference);
end $$;
revoke all on function public.get_my_flutterwave_hold(uuid) from public,anon;
grant execute on function public.get_my_flutterwave_hold(uuid) to authenticated;

create function public.list_my_flutterwave_holds()
returns table(request_id uuid,status text,amount_ngn numeric,account_number text,bank_name text,expires_at timestamptz,reference text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select h.request_id,case when h.status in ('initializing','pending') and now()>=h.expires_at then 'expired' else h.status end,
    h.amount_ngn,case when h.status='pending' and now()<h.expires_at then h.account_number else null end,
    case when h.status='pending' and now()<h.expires_at then h.bank_name else null end,h.expires_at,h.reference
  from public.customer_payment_holds h join public.service_requests r on r.id=h.request_id
  where public.is_customer_user(r.customer_id)
  order by h.created_at desc limit 100;
$$;
revoke all on function public.list_my_flutterwave_holds() from public,anon;
grant execute on function public.list_my_flutterwave_holds() to authenticated;

create function public.activate_flutterwave_hold(p_request_id uuid,p_reference text,p_account_number text,p_bank_name text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_hold public.customer_payment_holds%rowtype;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v_hold from public.customer_payment_holds where request_id=p_request_id for update;
  if not found or v_hold.reference<>p_reference or v_hold.status<>'initializing' or now()>=v_hold.expires_at then
    raise object_not_in_prerequisite_state using message='This payment hold is unavailable'; end if;
  if p_account_number !~ '^[0-9]{10}$' or nullif(btrim(p_bank_name),'') is null then
    raise check_violation using message='Invalid temporary account'; end if;
  update public.customer_payment_holds set status='pending',account_number=p_account_number,
    bank_name=btrim(p_bank_name),updated_at=now() where request_id=p_request_id;
end $$;
revoke all on function public.activate_flutterwave_hold(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.activate_flutterwave_hold(uuid,text,text,text) to service_role;

-- Called only after the Edge Function independently verifies the provider
-- transaction. A late confirmation is retained for reconciliation, not dispatch.
create function public.settle_flutterwave_hold(p_reference text,p_transaction_id bigint,p_amount_ngn numeric,p_currency text)
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
    values(v_job_id,v_hold.amount_ngn,round(v_hold.amount_ngn*0.8,2),0,'NGN');
  insert into public.customer_payments(job_id,amount,currency,method,reference,notes,recorded_by)
    values(v_job_id,v_hold.amount_ngn,'NGN','online',p_reference,'Verified Flutterwave temporary account',null);
  insert into public.partner_assignments(job_id,partner_id,status,responded_at,response_note)
    values(v_job_id,v_bid.partner_id,'accepted',now(),'Accepted through company bid');
  update public.service_requests set status='converted' where id=v_request.id;
  update public.customer_payment_holds set status='paid',provider_transaction_id=p_transaction_id,updated_at=now()
    where request_id=v_hold.request_id;
  return jsonb_build_object('status','paid','request_id',v_hold.request_id,'job_id',v_job_id);
end $$;
revoke all on function public.settle_flutterwave_hold(text,bigint,numeric,text) from public,anon,authenticated;
grant execute on function public.settle_flutterwave_hold(text,bigint,numeric,text) to service_role;

alter table public.customer_payments alter column recorded_by drop not null;
create or replace function public.list_my_selected_pickups()
returns table(request_id uuid,request_number text,pickup_city text,delivery_city text,parcel_summary text,company_name text,selected_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.rider_session_active() then raise insufficient_privilege using message='Rider access required'; end if;
  return query select r.id,r.request_number,r.pickup_city,r.delivery_city,r.parcel_summary,p.partner_name,cq.created_at
  from public.customer_payment_holds h
  join public.customer_delivery_quotes cq on cq.request_id=h.request_id and cq.status='accepted'
  join public.partner_quotes q on q.id=h.bid_id and q.status='selected'
  join public.company_bid_invitations i on i.request_id=h.request_id and i.partner_id=q.partner_id and i.rider_id=auth.uid()
  join public.service_requests r on r.id=h.request_id
  join public.logistics_partners p on p.id=q.partner_id and p.status='active'
  join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=q.partner_id
    and rc.revoked_at is null and rc.password_revoked_at is null
  join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
  where h.status in ('initializing','pending') and now()<h.expires_at and r.status not in ('rejected','cancelled')
  order by cq.created_at desc limit 50;
end $$;
