begin;
do $$
declare
  v_operations uuid := gen_random_uuid();
  v_management uuid := gen_random_uuid();
  v_admin uuid := gen_random_uuid();
  v_customer_user uuid := gen_random_uuid();
  v_customer uuid := gen_random_uuid();
  v_service uuid;
  v_request uuid := gen_random_uuid();
  v_order uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid();
  v_count integer;
begin
  select id into v_service from public.services where code = 'SRV-0001';
  if v_service is null then raise exception 'Expected seeded delivery service'; end if;

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_operations,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','exception-ops-'||v_operations||'@example.test','',now(),'{}','{}',now(),now()),
    (v_management,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','exception-management-'||v_management||'@example.test','',now(),'{}','{}',now(),now()),
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','exception-admin-'||v_admin||'@example.test','',now(),'{}','{}',now(),now()),
    (v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','exception-customer-'||v_customer_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values
    (v_operations,'operations'),(v_management,'management'),(v_admin,'admin');
  insert into public.customers(id,company_name,customer_type,contact_person,phone,created_by)
    values(v_customer,'Exception escalation test','business','Test Contact','08000000001',v_customer_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_customer_user);
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_request,v_customer,v_service,v_customer_user,'Pickup','Lagos','Sender','08000000002','Delivery','Ibadan','Recipient','08000000003');
  insert into public.orders(id,service_request_id,customer_id,service_id,confirmed_by,confirmed_at)
    values(v_order,v_request,v_customer,v_service,v_operations,now());
  insert into public.jobs(id,order_id,customer_id,service_id,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_job,v_order,v_customer,v_service,'Pickup','Lagos','Sender','08000000002','Delivery','Ibadan','Recipient','08000000003');

  perform set_config('request.jwt.claim.sub',v_operations::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_operations,'role','authenticated')::text,true);
  update public.jobs set status='exception',exception_details='Test exception' where id=v_job;
  select count(*) into v_count from public.notifications
    where job_id=v_job and event_type='job_exception_escalated' and channel='in_app'
      and user_id in (v_operations,v_management,v_admin);
  if v_count<>3 then raise exception 'Expected one in-app exception alert for each Operations, Management, and Admin user; got %',v_count; end if;
  if exists(select 1 from public.notifications where job_id=v_job and user_id=v_customer_user and event_type='job_exception_escalated') then
    raise exception 'Customer received an internal exception escalation';
  end if;

  update public.jobs set status='in_transit' where id=v_job;
  update public.jobs set status='exception' where id=v_job;
  select count(*) into v_count from public.notifications
    where job_id=v_job and event_type='job_exception_escalated' and user_id=v_operations;
  if v_count<>2 then raise exception 'A later, distinct exception was not escalated'; end if;
end;
$$;
rollback;
