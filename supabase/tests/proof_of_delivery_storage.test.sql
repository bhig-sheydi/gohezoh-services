begin;
do $$
declare
  v_customer_user uuid := gen_random_uuid();
  v_partner_user uuid := gen_random_uuid();
  v_other_user uuid := gen_random_uuid();
  v_operations_user uuid := gen_random_uuid();
  v_customer uuid := gen_random_uuid();
  v_service uuid;
  v_request uuid := gen_random_uuid();
  v_order uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
begin
  select id into v_service from public.services where code='SRV-0001';
  if v_service is null then raise exception 'Expected seeded Local Delivery service'; end if;
  insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','pod-customer-'||v_customer_user::text||'@example.test','',now(),'{}','{}',now(),now()),
    (v_partner_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','pod-partner-'||v_partner_user::text||'@example.test','',now(),'{}','{}',now(),now()),
    (v_other_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','pod-other-'||v_other_user::text||'@example.test','',now(),'{}','{}',now(),now()),
    (v_operations_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','pod-operations-'||v_operations_user::text||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_operations_user,'operations');
  insert into public.customers(id,company_name,customer_type,contact_person,email,phone,created_by)
    values(v_customer,'POD test customer','business','Test contact','pod-customer@example.test','+2348000000000',v_customer_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_customer_user);
  insert into public.logistics_partners(id,partner_name,contact_person,phone,email,base_city,base_state)
    values(v_partner,'POD test partner','Partner contact','+2348000000001','pod-partner@example.test','Lagos','Lagos');
  insert into public.partner_users(partner_id,user_id) values(v_partner,v_partner_user);
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_request,v_customer,v_service,v_customer_user,'1 Pickup Road','Lagos','Sender','+2348000000002','2 Delivery Road','Ibadan','Recipient','+2348000000003');
  insert into public.orders(id,service_request_id,customer_id,service_id,status,customer_price,confirmed_by,confirmed_at)
    values(v_order,v_request,v_customer,v_service,'confirmed',2500,v_operations_user,now());
  insert into public.jobs(id,order_id,customer_id,service_id,partner_id,assigned_operations_user_id,status,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_job,v_order,v_customer,v_service,v_partner,v_operations_user,'delivered','1 Pickup Road','Lagos','Sender','+2348000000002','2 Delivery Road','Ibadan','Recipient','+2348000000003');
  insert into public.partner_assignments(job_id,partner_id,status,assigned_by,responded_at,completed_at)
    values(v_job,v_partner,'completed',v_operations_user,now(),now());

  perform set_config('request.jwt.claim.sub',v_customer_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
  if not public.can_read_pod_job(v_job) then raise exception 'Customer must be able to read their delivery proof'; end if;
  if public.can_upload_pod_job(v_job) then raise exception 'Customer unexpectedly has proof upload access'; end if;

  perform set_config('request.jwt.claim.sub',v_partner_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_partner_user,'role','authenticated')::text,true);
  if not public.can_read_pod_job(v_job) or not public.can_upload_pod_job(v_job) then raise exception 'Completed assigned partner should read and upload delivery proof'; end if;
  if public.pod_job_id_from_path(v_job::text||'/proof.webp') is distinct from v_job then raise exception 'Storage object path did not resolve to its delivery job'; end if;
  if public.pod_job_id_from_path('invalid/proof.webp') is not null then raise exception 'Malformed storage path should not resolve to a job'; end if;

  perform set_config('request.jwt.claim.sub',v_other_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_other_user,'role','authenticated')::text,true);
  if public.can_read_pod_job(v_job) or public.can_upload_pod_job(v_job) then raise exception 'Unrelated account accessed delivery proof'; end if;

  perform set_config('request.jwt.claim.sub',v_operations_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_operations_user,'role','authenticated')::text,true);
  if not public.can_upload_pod_job(v_job) then raise exception 'Operations should be able to add delivery evidence'; end if;
  if not exists (select 1 from storage.buckets where id='proof-of-delivery' and public=false and file_size_limit=5242880) then raise exception 'Expected a private five-megabyte proof bucket'; end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='pod_objects_upload_after_delivery') then raise exception 'Storage upload RLS policy is missing'; end if;
end;
$$;
rollback;
