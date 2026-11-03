-- New Paystack bookings reserve the rider for the lifetime of the temporary account.
-- Existing Flutterwave holds retain their recorded expiry.
alter table public.customer_payment_holds add column provider text not null default 'flutterwave'
  check (provider in ('flutterwave','paystack'));
alter table public.customer_payment_holds add column provider_test_mode boolean;

create or replace function public.list_customer_bid_state(p_request_ids uuid[])
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
  with owned as (
    select r.id from public.service_requests r where r.id=any(p_request_ids) and public.is_customer_user(r.customer_id)
  )
  select pg_catalog.jsonb_build_object(
    'windows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(w)) from public.delivery_quote_windows w
      where w.request_id in (select id from owned)),'[]'::jsonb),
    'quotes',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(q)) from public.customer_delivery_quotes q
      where q.request_id in (select id from owned)),'[]'::jsonb),
    'holds',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(h) || pg_catalog.jsonb_build_object('provider',p.provider,'test_mode',p.provider_test_mode))
      from public.list_my_flutterwave_holds() h join public.customer_payment_holds p on p.request_id=h.request_id
      where h.request_id in (select id from owned)),'[]'::jsonb));
$$;

create or replace function public.activate_paystack_hold(
  p_request_id uuid,p_reference text,p_account_number text,p_bank_name text,p_provider_expires_at timestamptz,p_test_mode boolean)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_hold public.customer_payment_holds%rowtype;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v_hold from public.customer_payment_holds where request_id=p_request_id for update;
  if not found or v_hold.reference<>p_reference or v_hold.status<>'initializing' or now()>=v_hold.expires_at then
    raise object_not_in_prerequisite_state using message='This payment hold is unavailable'; end if;
  if p_account_number !~ '^[0-9]{10}$' or nullif(btrim(p_bank_name),'') is null
    or p_provider_expires_at <= now() or p_provider_expires_at > now()+interval '20 minutes' then
    raise check_violation using message='Invalid Paystack temporary account'; end if;
  update public.customer_payment_holds set status='pending',account_number=p_account_number,
    bank_name=btrim(p_bank_name),expires_at=p_provider_expires_at,provider_test_mode=p_test_mode,updated_at=now() where request_id=p_request_id;
  update public.customer_delivery_quotes set expires_at=p_provider_expires_at
    where request_id=p_request_id and status='accepted';
end $$;
revoke all on function public.activate_paystack_hold(uuid,text,text,text,timestamptz,boolean) from public,anon,authenticated;
grant execute on function public.activate_paystack_hold(uuid,text,text,text,timestamptz,boolean) to service_role;

create or replace function public.select_customer_partner_bid(p_request_id uuid,p_bid_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_window public.delivery_quote_windows%rowtype;v_bid public.partner_quotes%rowtype;v_service_code text;
begin
  select * into v_window from public.delivery_quote_windows where request_id=p_request_id for update;
  if not found or v_window.status not in ('open','awaiting_customer_selection') then
    raise object_not_in_prerequisite_state using message='Company selection is not available yet'; end if;
  if not exists(select 1 from public.service_requests r where r.id=p_request_id and public.is_customer_user(r.customer_id)) then
    raise insufficient_privilege using message='Only this customer can choose a company'; end if;
  select q.* into v_bid from public.partner_quotes q join public.logistics_partners p on p.id=q.partner_id and p.status='active'
  where q.id=p_bid_id and q.request_id=p_request_id and q.status='valid' and q.submitted_at<v_window.deadline_at for update of q;
  if not found then raise check_violation using message='Choose an available company offer'; end if;
  if now()<v_window.deadline_at and not exists(select 1 from public.bike_route_prices bp
    join public.company_bid_invitations i on i.request_id=bp.request_id and i.partner_id=v_bid.partner_id
    join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=i.partner_id
    join public.company_riders r on r.id=rc.roster_id
    join public.partner_application_vehicles v on v.id=r.source_vehicle_id and v.vehicle_type='motorcycle'
    where bp.request_id=p_request_id and bp.customer_price_ngn=v_bid.amount_ngn) then
    raise object_not_in_prerequisite_state using message='Company selection is not available yet'; end if;
  if exists(select 1 from public.customer_delivery_quotes where request_id=p_request_id) then
    raise object_not_in_prerequisite_state using message='A company has already been chosen'; end if;
  select s.code into v_service_code from public.service_requests r join public.services s on s.id=r.service_id where r.id=p_request_id;
  if v_service_code='SRV-0001' then
    if v_bid.amount_ngn<>trunc(v_bid.amount_ngn) then
      raise check_violation using message='This price must be a whole-naira amount'; end if;
    if not exists(select 1 from public.company_bid_invitations i where i.request_id=p_request_id and i.partner_id=v_bid.partner_id) then
      raise check_violation using message='This company no longer has a rider for this pickup'; end if;
  end if;
  update public.partner_quotes set status='selected' where id=v_bid.id;
  update public.delivery_quote_windows set status='quoted',closed_at=now() where request_id=p_request_id;
  if v_service_code='SRV-0001' then
    insert into public.customer_delivery_quotes(request_id,winning_bid_id,total_direct_cost_ngn,unrounded_price_ngn,
      customer_price_ngn,formula_version,status,expires_at,accepted_at)
    values(p_request_id,v_bid.id,round(v_bid.amount_ngn*0.75,2),v_bid.amount_ngn,
      v_bid.amount_ngn,'selected-bid-partner-net-75-v2','accepted',now()+interval '15 minutes',now());
    insert into public.customer_payment_holds(request_id,bid_id,reference,amount_ngn,expires_at,provider)
    values(p_request_id,v_bid.id,'KP-'||replace(gen_random_uuid()::text,'-',''),v_bid.amount_ngn,now()+interval '15 minutes','paystack');
  else
    insert into public.customer_delivery_quotes(request_id,winning_bid_id,total_direct_cost_ngn,unrounded_price_ngn)
    values(p_request_id,v_bid.id,v_bid.amount_ngn,round(v_bid.amount_ngn/0.75,4));
  end if;
end $$;

create or replace function public.settle_paystack_hold(p_reference text,p_transaction_id bigint,p_amount_ngn numeric,p_currency text)
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
    values(v_job_id,v_hold.amount_ngn,'NGN','online',p_reference,'Verified Paystack temporary account',null);
  insert into public.partner_assignments(job_id,partner_id,status,responded_at,response_note)
    values(v_job_id,v_bid.partner_id,'accepted',now(),'Accepted through company bid');
  update public.service_requests set status='converted' where id=v_request.id;
  update public.customer_payment_holds set status='paid',provider_transaction_id=p_transaction_id,updated_at=now()
    where request_id=v_hold.request_id;
  return jsonb_build_object('status','paid','request_id',v_hold.request_id,'job_id',v_job_id);
end $$;
revoke all on function public.settle_paystack_hold(text,bigint,numeric,text) from public,anon,authenticated;
grant execute on function public.settle_paystack_hold(text,bigint,numeric,text) to service_role;
