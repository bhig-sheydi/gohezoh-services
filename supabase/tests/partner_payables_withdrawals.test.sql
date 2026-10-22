begin;
do $$
declare
  v_manager uuid := gen_random_uuid(); v_other uuid := gen_random_uuid();
  v_customer_user uuid := gen_random_uuid(); v_customer uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid(); v_service uuid; v_request uuid := gen_random_uuid();
  v_order uuid := gen_random_uuid(); v_job uuid := gen_random_uuid();
  v_request_pending uuid := gen_random_uuid(); v_order_pending uuid := gen_random_uuid();
  v_job_pending uuid := gen_random_uuid(); v_request_old uuid := gen_random_uuid();
  v_order_old uuid := gen_random_uuid(); v_job_old uuid := gen_random_uuid();
  v_request_unpaid uuid := gen_random_uuid(); v_order_unpaid uuid := gen_random_uuid();
  v_job_unpaid uuid := gen_random_uuid(); v_key uuid := gen_random_uuid();
  v_first jsonb; v_retry jsonb; v_claim jsonb; v_second jsonb;
  v_available numeric; v_pending numeric; v_i integer;
begin
  select id into v_service from public.services where code='SRV-0001';
  if v_service is null then raise exception 'Missing local delivery service'; end if;
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_manager,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'payout-manager-'||v_manager::text||'@example.test','',now(),'{}','{}',now(),now()),
    (v_other,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'payout-other-'||v_other::text||'@example.test','',now(),'{}','{}',now(),now()),
    (v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'payout-customer-'||v_customer_user::text||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.customers(id,company_name,customer_type,contact_person,email,phone,created_by)
    values(v_customer,'Payout fixture','business','Customer','payout@example.test','+2348000000001',v_customer_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_customer_user);
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
    values(v_partner,'Payout fixture partner','Manager','+2348000000002','active');
  insert into public.partner_users(partner_id,user_id,membership_role) values(v_partner,v_manager,'manager');
  insert into public.user_roles(user_id,role) values(v_other,'management');
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,
    sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
  values(v_request,v_customer,v_service,v_customer_user,'Pickup','Lagos','Sender','+2348000000003',
    'Dropoff','Lagos','Recipient','+2348000000004'),
    (v_request_pending,v_customer,v_service,v_customer_user,'Pickup','Lagos','Sender','+2348000000003',
    'Dropoff','Lagos','Recipient','+2348000000004'),
    (v_request_old,v_customer,v_service,v_customer_user,'Pickup','Lagos','Sender','+2348000000003',
    'Dropoff','Lagos','Recipient','+2348000000004'),
    (v_request_unpaid,v_customer,v_service,v_customer_user,'Pickup','Lagos','Sender','+2348000000003',
    'Dropoff','Lagos','Recipient','+2348000000004');
  insert into public.orders(id,service_request_id,customer_id,service_id,status,customer_price,confirmed_at)
  values(v_order,v_request,v_customer,v_service,'confirmed',10000,now()),
    (v_order_pending,v_request_pending,v_customer,v_service,'confirmed',10000,now()),
    (v_order_old,v_request_old,v_customer,v_service,'confirmed',10000,now()),
    (v_order_unpaid,v_request_unpaid,v_customer,v_service,'confirmed',10000,now());
  insert into public.jobs(id,order_id,customer_id,service_id,partner_id,status,pickup_address,pickup_city,
    sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
  values(v_job,v_order,v_customer,v_service,v_partner,'delivered','Pickup','Lagos','Sender',
    '+2348000000003','Dropoff','Lagos','Recipient','+2348000000004'),
    (v_job_pending,v_order_pending,v_customer,v_service,v_partner,'in_transit','Pickup','Lagos','Sender',
    '+2348000000003','Dropoff','Lagos','Recipient','+2348000000004'),
    (v_job_old,v_order_old,v_customer,v_service,v_partner,'delivered','Pickup','Lagos','Sender',
    '+2348000000003','Dropoff','Lagos','Recipient','+2348000000004'),
    (v_job_unpaid,v_order_unpaid,v_customer,v_service,v_partner,'delivered','Pickup','Lagos','Sender',
    '+2348000000003','Dropoff','Lagos','Recipient','+2348000000004');
  insert into public.job_financials(job_id,customer_revenue,partner_cost,other_direct_cost,currency)
    values(v_job,10000,7500,0,'NGN'),(v_job_pending,10000,7500,0,'NGN'),
      (v_job_old,10000,8000,0,'NGN'),(v_job_unpaid,10000,7500,0,'NGN');
  insert into public.customer_payments(job_id,amount,currency,method,reference,recorded_by)
    values(v_job,10000,'NGN','online','payout-paid-'||v_job::text,null),
      (v_job_pending,10000,'NGN','online','payout-pending-'||v_job_pending::text,null),
      (v_job_old,10000,'NGN','online','payout-old-'||v_job_old::text,null),
      (v_job_unpaid,5000,'NGN','online','payout-unpaid-'||v_job_unpaid::text,null);
  insert into public.partner_settlements(job_id,partner_id,amount,currency,request_reference,created_by)
    values(v_job_old,v_partner,3000,'NGN','prior-finance-'||v_job_old::text,v_other);
  perform set_config('request.jwt.claims',jsonb_build_object('role','service_role')::text,true);
  for v_i in 1..5 loop
    perform public.authorize_partner_bank_resolve(v_partner,v_manager);
  end loop;
  begin
    perform public.authorize_partner_bank_resolve(v_partner,v_manager);
    raise exception 'Bank resolve rate limit was bypassed';
  exception when check_violation then null; end;
  perform public.save_verified_partner_payout_account(v_partner,v_manager,'044','Verified Bank',
    '1234567890','Payout Fixture Partner');
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  select available_ngn,pending_delivery_ngn into v_available,v_pending
    from public.get_my_partner_payables() where partner_id=v_partner;
  if v_available<>12500 or v_pending<>7500 then
    raise exception 'Wrong payable summary: available %, pending %',v_available,v_pending;
  end if;
  v_first:=public.request_partner_withdrawal(v_partner,10000,v_key);
  v_retry:=public.request_partner_withdrawal(v_partner,10000,v_key);
  if v_first->>'withdrawal_id'<>v_retry->>'withdrawal_id'
     or (select count(*) from public.partner_settlements where withdrawal_id=(v_first->>'withdrawal_id')::uuid)<>2 then
    raise exception 'Withdrawal idempotency failed'; end if;
  if (select available_ngn from public.get_my_partner_payables() where partner_id=v_partner)<>2500 then
    raise exception 'Withdrawal did not reserve the company fee'; end if;
  begin
    perform public.request_partner_withdrawal(v_partner,3000,gen_random_uuid());
    raise exception 'Overdraw was accepted';
  exception when check_violation then null; end;
  begin
    perform public.request_partner_withdrawal(v_partner,4000,v_key);
    raise exception 'Idempotency key reused with a different amount';
  exception when check_violation then null; end;
  perform set_config('request.jwt.claim.sub',v_other::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_other,'role','authenticated')::text,true);
  begin
    perform public.update_partner_settlement_status(
      (select id from public.partner_settlements where withdrawal_id=(v_first->>'withdrawal_id')::uuid limit 1),
      'approved');
    raise exception 'Management bypassed automatic payout guard';
  exception when insufficient_privilege then null; end;
  begin
    perform public.request_partner_withdrawal(v_partner,1,gen_random_uuid());
    raise exception 'Unrelated user could withdraw';
  exception when insufficient_privilege then null; end;
  if exists(select 1 from public.get_my_partner_payables() where partner_id=v_partner) then
    raise exception 'Unrelated user could read payables'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('role','service_role')::text,true);
  perform public.save_verified_partner_payout_account(v_partner,v_manager,'044','Verified Bank',
    '0987654321','Payout Fixture Partner');
  v_claim:=public.claim_partner_withdrawal_transfer((v_first->>'withdrawal_id')::uuid);
  if v_claim->>'status'<>'initiating' or v_claim->>'account_number'<>'1234567890' then
    raise exception 'Claim omitted the verified account snapshot'; end if;
  if (public.claim_partner_withdrawal_transfer((v_first->>'withdrawal_id')::uuid))->>'status'<>'initiating' then
    raise exception 'Duplicate claim did not stay in reconciliation state'; end if;
  perform public.record_partner_withdrawal_transfer_attempt((v_first->>'withdrawal_id')::uuid,12345,
    'queued',v_claim->>'reference'||'_FLW1');
  begin
    perform public.finish_partner_withdrawal_transfer((v_first->>'withdrawal_id')::uuid,12345,
      v_claim->>'reference',v_claim->>'reference'||'_FLW1','SUCCESSFUL',10001,'NGN','044','1234567890');
    raise exception 'Mismatched amount was marked paid';
  exception when check_violation then null; end;
  perform public.finish_partner_withdrawal_transfer((v_first->>'withdrawal_id')::uuid,12345,
    v_claim->>'reference',v_claim->>'reference'||'_FLW1','SUCCESSFUL',10000,'NGN','044','1234567890');
  if (select count(*) from public.partner_settlements
    where withdrawal_id=(v_first->>'withdrawal_id')::uuid and status='paid')<>2 then
    raise exception 'Provider-verified transfer did not settle reserved jobs'; end if;
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  v_second:=public.request_partner_withdrawal(v_partner,2500,gen_random_uuid());
  perform set_config('request.jwt.claims',jsonb_build_object('role','service_role')::text,true);
  v_claim:=public.claim_partner_withdrawal_transfer((v_second->>'withdrawal_id')::uuid);
  perform public.finish_partner_withdrawal_transfer((v_second->>'withdrawal_id')::uuid,12346,
    v_claim->>'reference',v_claim->>'reference'||'_FLW1','FAILED',2500,'NGN','044','0987654321');
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  if (select available_ngn from public.get_my_partner_payables() where partner_id=v_partner)<>2500 then
    raise exception 'Provider-confirmed failed transfer did not release reservation'; end if;
  v_second:=public.request_partner_withdrawal(v_partner,2500,gen_random_uuid());
  perform set_config('request.jwt.claims',jsonb_build_object('role','service_role')::text,true);
  perform public.claim_partner_withdrawal_transfer((v_second->>'withdrawal_id')::uuid);
  perform public.record_partner_withdrawal_transfer_attempt((v_second->>'withdrawal_id')::uuid,
    null,'unknown',null);
  if (public.claim_partner_withdrawal_transfer((v_second->>'withdrawal_id')::uuid))->>'status'<>'unknown' then
    raise exception 'Unknown provider result could be claimed again'; end if;
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  if (select available_ngn from public.get_my_partner_payables() where partner_id=v_partner)<>0 then
    raise exception 'Unknown provider result released funds prematurely'; end if;
end $$;
rollback;
