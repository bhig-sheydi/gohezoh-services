begin;
do $$
declare
  v_ops uuid:=gen_random_uuid();v_customer_user uuid:=gen_random_uuid();v_customer uuid:=gen_random_uuid();
  v_service uuid;v_request uuid:=gen_random_uuid();v_order uuid:=gen_random_uuid();v_job uuid:=gen_random_uuid();
  v_partner_a uuid:=gen_random_uuid();v_partner_b uuid:=gen_random_uuid();v_route uuid;v_wrong_route uuid;
begin
  select id into v_service from public.services where code='SRV-0001';
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_ops,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','route-ops-'||v_ops||'@example.test','',now(),'{}','{}',now(),now()),
    (v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','route-customer-'||v_customer_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_ops,'operations'),(v_customer_user,'customer') on conflict do nothing;
  insert into public.customers(id,company_name,customer_type,contact_person,email,phone,created_by)
  values(v_customer,'Route Test Customer','business','Route Contact','route-'||v_customer||'@example.test','+2348000000011',v_customer_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_customer_user);
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
  values(v_partner_a,'Route Partner A','Partner A','+2348000000012','active'),
        (v_partner_b,'Route Partner B','Partner B','+2348000000013','active');
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
  values(v_request,v_customer,v_service,v_customer_user,'1 Pickup Road','Lagos','Sender','+2348000000014','2 Delivery Road','Ibadan','Recipient','+2348000000015');
  insert into public.orders(id,service_request_id,customer_id,service_id,status,customer_price,confirmed_by,confirmed_at)
  values(v_order,v_request,v_customer,v_service,'confirmed',2500,v_ops,now());
  insert into public.jobs(id,order_id,customer_id,service_id,assigned_operations_user_id,status,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
  values(v_job,v_order,v_customer,v_service,v_ops,'order_confirmed','1 Pickup Road','Lagos','Sender','+2348000000014','2 Delivery Road','Ibadan','Recipient','+2348000000015');

  perform set_config('request.jwt.claim.sub',v_customer_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
  begin
    perform public.create_delivery_route('Unauthorized route','Lagos','Ibadan');
    raise exception 'Customer created a delivery route';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',v_ops::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_ops,'role','authenticated')::text,true);

  v_route:=(public.create_delivery_route('Lagos to Ibadan',' Lagos ','Ibadan',null,null,v_partner_a)->>'route_id')::uuid;
  v_wrong_route:=(public.create_delivery_route('Lagos to Abuja','Lagos','Abuja')->>'route_id')::uuid;
  begin
    perform public.assign_job_route(v_job,v_wrong_route);
    raise exception 'Route with wrong destination was assigned';
  exception when check_violation then null; end;
  perform public.assign_job_route(v_job,v_route);
  if (select route_id from public.jobs where id=v_job) is distinct from v_route then raise exception 'Job route was not saved'; end if;
  begin
    perform public.assign_job_to_partner(v_job,v_partner_b);
    raise exception 'Partner mismatched with route was assigned';
  exception when check_violation then null; end;
  if exists(select 1 from public.partner_assignments where job_id=v_job) then raise exception 'Rejected partner assignment left an assignment row'; end if;
  perform public.assign_job_to_partner(v_job,v_partner_a);
  begin
    update public.routes set destination_city='Abuja' where id=v_route;
    raise exception 'Assigned route was mutated';
  exception when object_not_in_prerequisite_state then null; end;
  if not exists(select 1 from public.audit_logs where entity_type='job' and entity_id=v_job and action='route_assigned') then raise exception 'Route assignment audit was missing'; end if;
end $$;
rollback;
