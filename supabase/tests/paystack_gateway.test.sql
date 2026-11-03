begin;
do $$
declare v_request uuid;v_state jsonb;
begin
  if has_table_privilege('authenticated','public.customer_referral_withdrawals','SELECT')
    or has_table_privilege('authenticated','public.customer_referral_payout_accounts','UPDATE')
    or has_function_privilege('authenticated','public.finish_referral_transfer(uuid,bigint,text,text,numeric,text,text)','EXECUTE')
    or has_function_privilege('authenticated','public.settle_paystack_hold(text,bigint,numeric,text)','EXECUTE') then
    raise exception 'Client can bypass Paystack payout or settlement verification'; end if;
  if not has_function_privilege('authenticated','public.request_referral_withdrawal(numeric,uuid)','EXECUTE')
    or not has_function_privilege('authenticated','public.my_referral_payout_state()','EXECUTE') then
    raise exception 'Referral withdrawal RPCs are unavailable'; end if;
  if pg_get_functiondef('public.select_customer_partner_bid(uuid,uuid)'::regprocedure) not like '%15 minutes%'
    or pg_get_functiondef('public.select_customer_partner_bid(uuid,uuid)'::regprocedure) not like '%paystack%' then
    raise exception 'New bookings do not use a 15-minute Paystack hold'; end if;
  select id into v_request from public.service_requests limit 1;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  if v_request is not null then
    v_state:=public.list_customer_bid_state(array[v_request]);
    if jsonb_array_length(v_state->'holds')<>0 or jsonb_array_length(v_state->'quotes')<>0
      or jsonb_array_length(v_state->'windows')<>0 then
      raise exception 'Another customer can see payment or quote data'; end if;
  end if;
  begin
    perform public.request_referral_withdrawal(1000,gen_random_uuid());
    raise exception 'Non-member requested a referral withdrawal';
  exception when insufficient_privilege then null; end;
end $$;
rollback;
