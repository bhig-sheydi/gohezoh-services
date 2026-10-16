begin;
do $$
declare
  v_ops uuid:=gen_random_uuid();
  v_manager uuid:=gen_random_uuid();
  v_rider uuid:=gen_random_uuid();
  v_other_rider uuid:=gen_random_uuid();
  v_customer_user uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_partner uuid:=gen_random_uuid();
  v_rider_roster uuid:=gen_random_uuid();
  v_service uuid;
  v_request uuid;
  v_order uuid;
  v_job uuid;
  v_jobs uuid[]:='{}';
  v_i integer;
begin
  select id into v_service from public.services where code='SRV-0001';
  if v_service is null then raise exception 'Expected seeded local delivery service'; end if;
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_ops,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','rider-limit-ops-'||v_ops||'@example.test','',now(),'{}','{}',now(),now()),
    (v_manager,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','rider-limit-manager-'||v_manager||'@example.test','',now(),'{}','{}',now(),now()),
    (v_rider,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','rider-limit-rider-'||v_rider||'@example.test','',now(),'{}','{}',now(),now()),
    (v_other_rider,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','rider-limit-other-'||v_other_rider||'@example.test','',now(),'{}','{}',now(),now()),
    (v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','rider-limit-customer-'||v_customer_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_ops,'operations'),(v_manager,'partner'),(v_rider,'partner'),(v_other_rider,'partner'),(v_customer_user,'customer') on conflict do nothing;
  insert into public.customers(id,company_name,customer_type,contact_person,email,phone,created_by)
  values(v_customer,'Rider capacity test','business','Test Contact','rider-customer-'||v_customer||'@example.test','+2348000000000',v_customer_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_customer_user);
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
  values(v_partner,'Rider capacity partner','Contact','+2348000000001','active');
  insert into public.partner_users(partner_id,user_id,membership_role) values(v_partner,v_manager,'manager'),(v_partner,v_rider,'rider'),(v_partner,v_other_rider,'rider');
  insert into public.company_riders(id,partner_id,full_name,nin,licence_document_path,status,reviewed_at)
    values(v_rider_roster,v_partner,'Capacity test rider','12345678903','test/capacity-licence.pdf','approved',now());
  insert into public.rider_credentials(user_id,partner_id,roster_id,rider_name,auth_secret_seed,link_hash,password_salt,password_hash,password_fingerprint)
    values(v_rider,v_partner,v_rider_roster,'Capacity test rider','capacity-seed-'||v_rider,'capacity-link-'||v_rider,'salt','hash','capacity-password-'||v_rider);

  for v_i in 1..6 loop
    v_request:=gen_random_uuid(); v_order:=gen_random_uuid(); v_job:=gen_random_uuid();
    insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_request,v_customer,v_service,v_customer_user,'1 Pickup Road','Lagos','Sender','+2348000000001','2 Delivery Road','Ibadan','Recipient','+2348000000002');
    insert into public.orders(id,service_request_id,customer_id,service_id,status,customer_price,confirmed_by,confirmed_at)
    values(v_order,v_request,v_customer,v_service,'confirmed',2500,v_ops,now());
    insert into public.jobs(id,order_id,customer_id,service_id,partner_id,assigned_operations_user_id,status,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_job,v_order,v_customer,v_service,v_partner,v_ops,'partner_assigned','1 Pickup Road','Lagos','Sender','+2348000000001','2 Delivery Road','Ibadan','Recipient','+2348000000002');
    insert into public.partner_assignments(job_id,partner_id,status,assigned_by,responded_at)
    values(v_job,v_partner,'accepted',v_ops,now());
    v_jobs:=array_append(v_jobs,v_job);
  end loop;

  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  for v_i in 1..6 loop
    perform public.assign_job_to_rider(v_jobs[v_i],v_rider);
  end loop;
  for v_i in 1..5 loop
    perform public.update_job_status(v_jobs[v_i],'pickup_scheduled');
  end loop;
  begin
    perform public.update_job_status(v_jobs[6],'pickup_scheduled');
    raise exception 'A sixth active pickup was unexpectedly allowed for one rider';
  exception when check_violation then null; end;
  if (select count(*) from public.jobs where assigned_rider_id=v_rider and status='pickup_scheduled')<>5 then
    raise exception 'The rider should have exactly five active pickups after the rejected sixth';
  end if;

  perform set_config('request.jwt.claim.sub',v_rider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated')::text,true);
  begin
    perform public.assign_job_to_rider(v_jobs[6],v_rider);
    raise exception 'A rider unexpectedly assigned work to themselves';
  exception when insufficient_privilege then null; end;
  begin
    perform * from public.list_partner_rider_jobs();
    raise exception 'A rider unexpectedly used the manager/dispatcher work list';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',v_other_rider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_other_rider,'role','authenticated')::text,true);
  begin
    perform public.update_job_status(v_jobs[1],'picked_up');
    raise exception 'A non-assigned rider unexpectedly updated another rider job';
  exception when insufficient_privilege then null; end;

  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  perform public.update_job_status(v_jobs[1],'picked_up');
  perform public.update_job_status(v_jobs[1],'in_transit');
  perform public.update_job_status(v_jobs[6],'pickup_scheduled');
  if (select count(*) from public.jobs where assigned_rider_id=v_rider and status in ('pickup_scheduled','picked_up','exception'))<>5 then
    raise exception 'Capacity should be released when the job leaves pickup_scheduled/picked_up for transit';
  end if;
end $$;
rollback;
