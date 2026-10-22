begin;
do $$
declare
  v_owner uuid:=gen_random_uuid(); v_other uuid:=gen_random_uuid(); v_manager uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid(); v_partner uuid:=gen_random_uuid(); v_service uuid; v_corridor uuid;
  v_request uuid:=gen_random_uuid(); v_order uuid:=gen_random_uuid(); v_job uuid:=gen_random_uuid();
  v_otp_request uuid:=gen_random_uuid(); v_otp_order uuid:=gen_random_uuid();
  v_otp_job uuid:=gen_random_uuid(); v_bid uuid; v_otp_bid uuid; v_failed boolean;
begin
  select id into v_service from public.services where code='SRV-0001';
  select id into v_corridor from public.coverage_corridors where service_code='SRV-0001' limit 1;
  if v_service is null or v_corridor is null then raise exception 'Local service and corridor fixtures required'; end if;
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_owner,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',v_owner||'@example.test','',now(),'{}','{}',now(),now()),
    (v_other,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',v_other||'@example.test','',now(),'{}','{}',now(),now()),
    (v_manager,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',v_manager||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.customers(id,company_name,contact_person,phone,created_by)
    values(v_customer,'Sender confirmation test','Sender','08000000001',v_owner);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_owner);
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
    values(v_partner,'Confirmation partner','Manager','08000000002','active');
  insert into public.user_roles(user_id,role) values(v_manager,'partner');
  insert into public.partner_users(partner_id,user_id,membership_role) values(v_partner,v_manager,'manager');
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_request,v_customer,v_service,v_owner,'Pickup','Lagos','Sender','08000000001','Destination','Lagos','Recipient','08000000003'),
      (v_otp_request,v_customer,v_service,v_owner,'Pickup','Lagos','Sender','08000000001','Destination','Lagos','Recipient','08000000003');
  insert into public.delivery_quote_windows(request_id,corridor_id,deadline_at,status)
    values(v_request,v_corridor,now()+interval '1 minute','quoted'),
      (v_otp_request,v_corridor,now()+interval '1 minute','quoted');
  insert into public.partner_quotes(request_id,partner_id,amount_ngn,eta_hours,availability_confirmed,inclusions,exclusions,surcharge_conditions,status)
    values(v_request,v_partner,2000,1,true,'Pickup','None','None','selected') returning id into v_bid;
  insert into public.partner_quotes(request_id,partner_id,amount_ngn,eta_hours,availability_confirmed,inclusions,exclusions,surcharge_conditions,status)
    values(v_otp_request,v_partner,2000,1,true,'Pickup','None','None','selected') returning id into v_otp_bid;
  insert into public.customer_payment_holds(request_id,bid_id,reference,amount_ngn,status)
    values(v_request,v_bid,'TEST-'||v_request,2000,'paid'),
      (v_otp_request,v_otp_bid,'TEST-'||v_otp_request,2000,'paid');
  insert into public.orders(id,service_request_id,customer_id,service_id,status,confirmed_by,confirmed_at)
    values(v_order,v_request,v_customer,v_service,'confirmed',v_owner,now()),
      (v_otp_order,v_otp_request,v_customer,v_service,'confirmed',v_owner,now());
  insert into public.jobs(id,order_id,customer_id,service_id,partner_id,status,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
    values
      (v_job,v_order,v_customer,v_service,v_partner,'in_transit','Pickup','Lagos','Sender','08000000001','Destination','Lagos','Recipient','08000000003'),
      (v_otp_job,v_otp_order,v_customer,v_service,v_partner,'in_transit','Pickup','Lagos','Sender','08000000001','Destination','Lagos','Recipient','08000000003');
  insert into public.partner_assignments(job_id,partner_id,status)
    values(v_job,v_partner,'accepted'),(v_otp_job,v_partner,'accepted');
  insert into public.sender_delivery_confirmations(job_id,requested_by,status)
    values(v_job,v_manager,'pending');

  perform set_config('request.jwt.claim.sub',v_other::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_other,'role','authenticated')::text,true);
  v_failed:=false;
  begin perform public.respond_sender_delivery_confirmation(v_job,true);
  exception when insufficient_privilege then v_failed:=true; end;
  if not v_failed then raise exception 'Unrelated user could approve delivery'; end if;
  if (select status from public.jobs where id=v_job)<>'in_transit' then raise exception 'Unauthorized approval changed job'; end if;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner,'role','authenticated')::text,true);
  v_failed:=false;
  begin perform public.request_sender_delivery_confirmation(v_job);
  exception when insufficient_privilege then v_failed:=true; end;
  if not v_failed then raise exception 'Customer could impersonate rider request'; end if;
  perform public.respond_sender_delivery_confirmation(v_job,false);
  if (select status from public.jobs where id=v_job)<>'in_transit' then raise exception 'No response marked delivered'; end if;
  update public.sender_delivery_confirmations set status='pending',responded_at=null,responded_by=null where job_id=v_job;
  perform public.respond_sender_delivery_confirmation(v_job,true);
  if (select status from public.jobs where id=v_job)<>'delivered' or
     (select status from public.partner_assignments where job_id=v_job)<>'completed' then
    raise exception 'Customer Yes did not atomically complete delivery'; end if;

  -- The original recipient OTP remains an independent completion path.
  insert into public.otp_verifications(job_id,recipient_phone,code_hash,expires_at)
    values(v_otp_job,'08000000003',extensions.crypt('123456',extensions.gen_salt('bf')),now()+interval '10 minutes');
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  if coalesce((public.verify_delivery_otp(v_otp_job,'123456')->>'verified')::boolean,false) is not true then
    raise exception 'Recipient OTP verification failed'; end if;
  if (select status from public.jobs where id=v_otp_job)<>'delivered' then
    raise exception 'Recipient OTP did not complete job'; end if;
end $$;
rollback;
