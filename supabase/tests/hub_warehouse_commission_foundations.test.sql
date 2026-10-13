begin;
do $$
declare
  v_ops uuid:=gen_random_uuid();v_user uuid:=gen_random_uuid();v_dispatcher uuid:=gen_random_uuid();v_rider uuid:=gen_random_uuid();v_customer uuid:=gen_random_uuid();
  v_service uuid;v_warehouse uuid:=gen_random_uuid();v_job uuid:=gen_random_uuid();
  v_request uuid:=gen_random_uuid();v_order uuid:=gen_random_uuid();v_inbound uuid:=gen_random_uuid();v_last uuid:=gen_random_uuid();
  v_corridor uuid;v_leg jsonb;
begin
  if not exists(select 1 from public.warehouse_fee_schedule where fee_code='standard_processing' and amount_ngn=1000 and effective_until is null) then raise exception 'Processing fee missing';end if;
  if not exists(select 1 from public.warehouse_fee_schedule where fee_code='standard_carton_month' and amount_ngn=2000 and carton_length_cm=40 and carton_width_cm=30 and carton_height_cm=30 and max_carton_weight_kg=15) then raise exception 'Carton fee missing';end if;
  if exists(select 1 from public.commission_plans) then raise exception 'Unapproved plans were seeded';end if;
  select id into v_service from public.services where code='SRV-0002';
  select c.id into v_corridor from public.coverage_corridors c join public.coverage_locations o on o.id=c.origin_id
    join public.coverage_locations d on d.id=c.destination_id
    where c.service_code='SRV-0001' and o.name='Port Harcourt' and d.name='Port Harcourt';
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_ops,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','hub-ops-'||v_ops||'@example.test','',now(),'{}','{}',now(),now()),
        (v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','hub-customer-'||v_user||'@example.test','',now(),'{}','{}',now(),now()),
        (v_dispatcher,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','hub-dispatcher-'||v_dispatcher||'@example.test','',now(),'{}','{}',now(),now()),
        (v_rider,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','hub-rider-'||v_rider||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_ops,'operations'),(v_user,'customer'),(v_dispatcher,'partner'),(v_rider,'partner') on conflict do nothing;
  insert into public.customers(id,company_name,contact_person,phone,created_by) values(v_customer,'Hub test customer','Hub contact','08000000011',v_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_user);
  insert into public.warehouses(id,name,code,address,city,is_active)
    values(v_warehouse,'Port Harcourt Hub','PH-TEST-'||upper(left(v_warehouse::text,8)),'1 Hub Road','Port Harcourt',true);
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
    values(v_inbound,'Inbound Test Partner','Contact','08000000015','active'),(v_last,'Last Mile Test Partner','Contact','08000000016','active');
  insert into public.partner_corridor_coverage(partner_id,corridor_id) values(v_last,v_corridor);
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_request,v_customer,v_service,v_user,'1 Pickup Road','Lagos','Sender','08000000012','2 Delivery Road','Port Harcourt','Recipient','08000000013');
  insert into public.orders(id,service_request_id,customer_id,service_id,status,confirmed_by)
    values(v_order,v_request,v_customer,v_service,'confirmed',v_ops);
  insert into public.jobs(id,order_id,customer_id,service_id,partner_id,assigned_operations_user_id,status,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_job,v_order,v_customer,v_service,v_inbound,v_ops,'out_for_delivery','1 Pickup Road','Lagos','Sender','08000000012','2 Delivery Road','Port Harcourt','Recipient','08000000013');
  insert into public.partner_assignments(job_id,partner_id,status,assigned_by) values(v_job,v_inbound,'accepted',v_ops);
  perform set_config('request.jwt.claim.sub',v_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_user,'role','authenticated')::text,true);
  begin
    perform public.record_port_harcourt_hub_receipt(v_job,v_warehouse,'SCAN-1','Intact');
    raise exception 'Customer recorded hub custody';
  exception when insufficient_privilege then null;end;
  perform set_config('request.jwt.claim.sub',v_ops::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_ops,'role','authenticated')::text,true);
  begin
    update public.jobs set status='delivered' where id=v_job;
    raise exception 'Delivery bypassed hub';
  exception when object_not_in_prerequisite_state then null;end;
  begin
    insert into public.otp_verifications(job_id,recipient_phone,code_hash,expires_at)
      values(v_job,'08000000013','premature-code',now()+interval '10 minutes');
    raise exception 'Recipient OTP was issued before hub handoff';
  exception when object_not_in_prerequisite_state then null;end;
  perform public.record_port_harcourt_hub_receipt(v_job,v_warehouse,'SCAN-1','Intact');
  update public.jobs set status='hub_received' where id=v_job;
  v_leg:=public.assign_port_harcourt_last_mile(v_job,v_last);
  if v_leg->>'leg_number' not like 'PHL-%' then raise exception 'Last-mile reference missing';end if;
  if (select count(*) from public.jobs where order_id=v_order)<>1 then raise exception 'Extra billed job created';end if;
  if not exists(select 1 from public.partner_assignments where job_id=v_job and partner_id=v_inbound and status='completed') then raise exception 'Inbound assignment not completed';end if;
  update public.partner_assignments set status='accepted',responded_at=now() where id=(v_leg->>'assignment_id')::uuid;
  insert into public.partner_users(partner_id,user_id,membership_role) values(v_last,v_dispatcher,'dispatcher'),(v_last,v_rider,'rider');
  perform set_config('request.jwt.claim.sub',v_dispatcher::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_dispatcher,'role','authenticated')::text,true);
  perform public.assign_job_to_rider(v_job,v_rider);
  perform set_config('request.jwt.claim.sub',v_ops::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_ops,'role','authenticated')::text,true);
  update public.jobs set status='pickup_scheduled' where id=v_job;
  update public.jobs set status='picked_up' where id=v_job;
  update public.jobs set status='in_transit' where id=v_job;
  update public.jobs set status='out_for_delivery' where id=v_job;
  begin
    update public.jobs set status='delivered' where id=v_job;
    raise exception 'Delivery bypassed recipient OTP';
  exception when object_not_in_prerequisite_state then null;end;
  insert into public.otp_verifications(job_id,recipient_phone,code_hash,expires_at,verified_at)
    values(v_job,'08000000013','test-hash',now()+interval '10 minutes',now());
  update public.jobs set status='delivered' where id=v_job;
  if (select status from public.jobs where id=v_job)<>'delivered' then raise exception 'Final OTP delivery failed';end if;
end $$;
rollback;
