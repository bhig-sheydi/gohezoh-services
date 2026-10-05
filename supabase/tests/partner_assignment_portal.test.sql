begin;
do $$
declare
  v_operations_id uuid := gen_random_uuid();
  v_partner_one_user_id uuid := gen_random_uuid();
  v_partner_two_user_id uuid := gen_random_uuid();
  v_customer_user_id uuid := gen_random_uuid();
  v_customer_id uuid := gen_random_uuid();
  v_service_id uuid;
  v_request_id uuid := gen_random_uuid();
  v_order_id uuid := gen_random_uuid();
  v_job_id uuid := gen_random_uuid();
  v_partner_one jsonb;
  v_partner_two jsonb;
  v_first_assignment_id uuid;
  v_second_assignment_id uuid;
  v_history_count integer;
  v_delivery_otp jsonb;
  v_wrong_delivery_code text;
  v_verification_result jsonb;
  v_attempt integer;
begin
  select id into v_service_id from public.services where code='SRV-0001';
  if v_service_id is null then raise exception 'Expected seeded Local Delivery service'; end if;
  insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_operations_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','ops-'||v_operations_id::text||'@example.test','',now(),'{}','{}',now(),now()),
    (v_partner_one_user_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','partner-one-'||v_partner_one_user_id::text||'@example.test','',now(),'{}','{}',now(),now()),
    (v_partner_two_user_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','partner-two-'||v_partner_two_user_id::text||'@example.test','',now(),'{}','{}',now(),now()),
    (v_customer_user_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','customer-'||v_customer_user_id::text||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_operations_id,'operations');
  insert into public.customers(id,company_name,customer_type,contact_person,email,phone,created_by)
  values(v_customer_id,'Partner assignment test','business','Test Contact','test-'||v_customer_id::text||'@example.test','+2348000000000',v_customer_user_id);
  insert into public.customer_users(customer_id,user_id) values(v_customer_id,v_customer_user_id);
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
  values(v_request_id,v_customer_id,v_service_id,v_customer_user_id,'1 Pickup Road','Lagos','Sender','+2348000000001','2 Delivery Road','Ibadan','Recipient','+2348000000002');
  insert into public.orders(id,service_request_id,customer_id,service_id,status,customer_price,confirmed_by,confirmed_at)
  values(v_order_id,v_request_id,v_customer_id,v_service_id,'confirmed',2500,v_operations_id,now());
  insert into public.jobs(id,order_id,customer_id,service_id,assigned_operations_user_id,status,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
  values(v_job_id,v_order_id,v_customer_id,v_service_id,v_operations_id,'order_confirmed','1 Pickup Road','Lagos','Sender','+2348000000001','2 Delivery Road','Ibadan','Recipient','+2348000000002');

  perform set_config('request.jwt.claim.sub',v_operations_id::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_operations_id,'role','authenticated')::text,true);
  v_partner_one := public.create_logistics_partner('Test Partner One','Partner One Contact','+2348000000010','partner-one@example.test','Lagos','Lagos',array['Lagos']);
  v_partner_two := public.create_logistics_partner('Test Partner Two','Partner Two Contact','+2348000000020','partner-two@example.test','Ibadan','Oyo',array['Ibadan']);
  -- Fixtures represent Partner access already approved by a Super Admin.
  insert into public.partner_users(partner_id,user_id) values
    ((v_partner_one->>'partner_id')::uuid,v_partner_one_user_id),
    ((v_partner_two->>'partner_id')::uuid,v_partner_two_user_id);
  insert into public.user_roles(user_id,role) values(v_partner_one_user_id,'partner'),(v_partner_two_user_id,'partner') on conflict do nothing;
  v_first_assignment_id := (public.assign_job_to_partner(v_job_id,(v_partner_one->>'partner_id')::uuid)->>'assignment_id')::uuid;
  begin
    perform public.assign_job_to_partner(v_job_id,(v_partner_two->>'partner_id')::uuid);
    raise exception 'Duplicate assignment unexpectedly succeeded';
  exception when sqlstate '55000' then null; end;

  perform set_config('request.jwt.claim.sub',v_partner_one_user_id::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_partner_one_user_id,'role','authenticated')::text,true);
  perform public.respond_to_partner_assignment(v_first_assignment_id,false,'Outside service area');
  if (select status::text from public.jobs where id=v_job_id)<>'order_confirmed' then raise exception 'Declining a job should return it to Order confirmed'; end if;
  if (select partner_id from public.jobs where id=v_job_id) is not null then raise exception 'Declined partner should be unlinked'; end if;
  if (select status::text from public.partner_assignments where id=v_first_assignment_id)<>'rejected' then raise exception 'Decline was not recorded'; end if;

  perform set_config('request.jwt.claim.sub',v_operations_id::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_operations_id,'role','authenticated')::text,true);
  v_second_assignment_id := (public.assign_job_to_partner(v_job_id,(v_partner_two->>'partner_id')::uuid)->>'assignment_id')::uuid;
  perform set_config('request.jwt.claim.sub',v_partner_one_user_id::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_partner_one_user_id,'role','authenticated')::text,true);
  begin
    perform public.respond_to_partner_assignment(v_second_assignment_id,true,null);
    raise exception 'An unrelated partner unexpectedly responded to the job';
  exception when sqlstate '42501' then null; end;

  perform set_config('request.jwt.claim.sub',v_partner_two_user_id::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_partner_two_user_id,'role','authenticated')::text,true);
  perform public.respond_to_partner_assignment(v_second_assignment_id,true,'Accepted for delivery');
  perform public.update_job_status(v_job_id,'picked_up');
  perform public.update_job_status(v_job_id,'in_transit');
  begin
    perform public.update_job_status(v_job_id,'delivered');
    raise exception 'Invalid partner status jump unexpectedly succeeded';
  exception when sqlstate '55000' then null; end;
  perform public.update_job_status(v_job_id,'exception');
  perform public.update_job_status(v_job_id,'pickup_scheduled');
  perform public.update_job_status(v_job_id,'picked_up');
  perform public.update_job_status(v_job_id,'in_transit');
  perform public.update_job_status(v_job_id,'out_for_delivery');
  begin
    perform public.update_job_status(v_job_id,'delivered');
    raise exception 'Partner unexpectedly marked delivery complete without a recipient code';
  exception when sqlstate '55000' then null; end;
  v_delivery_otp := public.issue_delivery_otp(v_job_id,v_partner_two_user_id);
  if (v_delivery_otp->>'code') !~ '^[0-9]{6}$' then raise exception 'Expected a six-digit delivery code'; end if;
  if exists (select 1 from public.otp_verifications where job_id=v_job_id and code_hash=v_delivery_otp->>'code') then raise exception 'Delivery code was stored in plaintext'; end if;
  if extensions.crypt(v_delivery_otp->>'code',(select code_hash from public.otp_verifications where job_id=v_job_id order by created_at desc limit 1)) <> (select code_hash from public.otp_verifications where job_id=v_job_id order by created_at desc limit 1) then raise exception 'Stored delivery code hash does not match the generated code'; end if;
  begin
    perform public.issue_delivery_otp(v_job_id,v_partner_two_user_id);
    raise exception 'Delivery code resend cooldown was bypassed';
  exception when sqlstate '55000' then null; end;
  v_wrong_delivery_code := case when v_delivery_otp->>'code'='999999' then '000000' else '999999' end;
  for v_attempt in 1..4 loop
    if (public.verify_delivery_otp(v_job_id,v_wrong_delivery_code)->>'verified')::boolean then raise exception 'Incorrect delivery code unexpectedly verified'; end if;
  end loop;
  if (select attempt_count from public.otp_verifications where job_id=v_job_id order by created_at desc limit 1)<>4 then raise exception 'Incorrect code attempts were not recorded'; end if;
  update public.otp_verifications set created_at=now()-interval '61 seconds' where job_id=v_job_id and verified_at is null;
  v_delivery_otp := public.issue_delivery_otp(v_job_id,v_partner_two_user_id);
  v_wrong_delivery_code := case when v_delivery_otp->>'code'='999999' then '000000' else '999999' end;
  if (public.verify_delivery_otp(v_job_id,v_wrong_delivery_code)->>'verified')::boolean then raise exception 'Incorrect delivery code unexpectedly verified'; end if;
  begin
    perform public.verify_delivery_otp(v_job_id,v_delivery_otp->>'code');
    raise exception 'Fifth OTP guess was allowed after resending';
  exception when sqlstate '42501' then null; end;
  update public.otp_verifications set attempt_count=0 where job_id=v_job_id;
  v_verification_result := public.verify_delivery_otp(v_job_id,v_delivery_otp->>'code');
  if (v_verification_result->>'verified')::boolean is distinct from true then raise exception 'Valid delivery code was not verified: %',v_verification_result; end if;
  if (select status::text from public.partner_assignments where id=v_second_assignment_id)<>'completed' then raise exception 'Delivery should complete partner assignment'; end if;
  if (select completed_at from public.partner_assignments where id=v_second_assignment_id) is null then raise exception 'Assignment completion timestamp missing'; end if;
  select count(*) into v_history_count from public.job_status_history where job_id=v_job_id;
  if v_history_count < 10 then raise exception 'Expected job history to include assignment, decline recovery, and delivery events; found %',v_history_count; end if;

  perform set_config('request.jwt.claim.sub',v_customer_user_id::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user_id,'role','authenticated')::text,true);
  begin
    perform public.update_job_status(v_job_id,'closed');
    raise exception 'Customer unexpectedly updated job status';
  exception when sqlstate '42501' then null; end;
  begin
    perform public.create_logistics_partner('Unauthorized','Customer','+2348000000000');
    raise exception 'Customer unexpectedly created a partner';
  exception when sqlstate '42501' then null; end;
end;
$$;
rollback;
