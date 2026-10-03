begin;
do $$
declare
  v_operations_id uuid := gen_random_uuid();
  v_customer_user_id uuid := gen_random_uuid();
  v_customer_id uuid := gen_random_uuid();
  v_service_id uuid;
  v_request_id uuid := gen_random_uuid();
  v_order_id uuid := gen_random_uuid();
  v_job_id uuid := gen_random_uuid();
  v_history_count integer;
begin
  select id into v_service_id from public.services where code='SRV-0001';
  if v_service_id is null then raise exception 'Expected seeded Local Delivery service'; end if;
  insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_operations_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','ops-'||v_operations_id::text||'@example.test','',now(),'{}','{}',now(),now()),
    (v_customer_user_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','customer-'||v_customer_user_id::text||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_operations_id,'operations');
  insert into public.customers(id,company_name,customer_type,contact_person,email,phone,created_by)
  values(v_customer_id,'Job progress test','business','Test Contact','test-'||v_customer_id::text||'@example.test','+2348000000000',v_customer_user_id);
  insert into public.customer_users(customer_id,user_id) values(v_customer_id,v_customer_user_id);
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
  values(v_request_id,v_customer_id,v_service_id,v_customer_user_id,'1 Pickup Road','Lagos','Sender','+2348000000001','2 Delivery Road','Ibadan','Recipient','+2348000000002');
  insert into public.orders(id,service_request_id,customer_id,service_id,status,customer_price,confirmed_by,confirmed_at)
  values(v_order_id,v_request_id,v_customer_id,v_service_id,'confirmed',2500,v_operations_id,now());
  insert into public.jobs(id,order_id,customer_id,service_id,assigned_operations_user_id,status,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
  values(v_job_id,v_order_id,v_customer_id,v_service_id,v_operations_id,'order_confirmed','1 Pickup Road','Lagos','Sender','+2348000000001','2 Delivery Road','Ibadan','Recipient','+2348000000002');

  perform set_config('request.jwt.claim.sub',v_operations_id::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_operations_id,'role','authenticated')::text,true);
  perform public.update_job_status(v_job_id,'pickup_scheduled');
  perform public.update_job_status(v_job_id,'picked_up');
  if (select status::text from public.jobs where id=v_job_id)<>'picked_up' then raise exception 'Expected job to reach picked_up'; end if;
  select count(*) into v_history_count from public.job_status_history where job_id=v_job_id and new_status in ('pickup_scheduled','picked_up');
  if v_history_count<>2 then raise exception 'Expected status history to record both progress changes; found %',v_history_count; end if;

  begin
    perform public.update_job_status(v_job_id,'delivered');
    raise exception 'Invalid status jump unexpectedly succeeded';
  exception when sqlstate '55000' then null; end;

  perform set_config('request.jwt.claim.sub',v_customer_user_id::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user_id,'role','authenticated')::text,true);
  begin
    perform public.update_job_status(v_job_id,'in_transit');
    raise exception 'Customer unexpectedly updated job status';
  exception when sqlstate '42501' then null; end;
end;
$$;
rollback;
