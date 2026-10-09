begin;
create temp table operations_fixture (name text primary key, id uuid not null);
do $$
declare
  v_operations_id uuid := gen_random_uuid();
  v_customer_user_id uuid := gen_random_uuid();
  v_customer_id uuid := gen_random_uuid();
  v_service_id uuid;
  v_convert_request_id uuid := gen_random_uuid();
  v_reject_request_id uuid := gen_random_uuid();
  v_result jsonb;
begin
  select id into v_service_id from public.services where code = 'SRV-0001';
  if v_service_id is null then raise exception 'Expected seeded Local Delivery service'; end if;
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values
    (v_operations_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ops-' || v_operations_id::text || '@example.test', '', now(), '{}', '{}', now(), now()),
    (v_customer_user_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'customer-' || v_customer_user_id::text || '@example.test', '', now(), '{}', '{}', now(), now());
  insert into public.user_roles(user_id, role) values (v_operations_id, 'operations');
  insert into public.customers(id, company_name, customer_type, contact_person, email, phone, created_by)
  values (v_customer_id, 'Operations workflow test', 'business', 'Test Contact', 'workflow-' || v_customer_id::text || '@example.test', '+2348000000000', v_customer_user_id);
  insert into public.customer_users(customer_id, user_id) values (v_customer_id, v_customer_user_id);
  insert into public.service_requests(id, customer_id, service_id, created_by, pickup_address, pickup_city, sender_name, sender_phone, delivery_address, delivery_city, recipient_name, recipient_phone, parcel_summary, parcel_items)
  values
    (v_convert_request_id, v_customer_id, v_service_id, v_customer_user_id, '12 Test Pickup Road', 'Lagos', 'Sender', '+2348000000001', '34 Test Delivery Road', 'Ibadan', 'Recipient', '+2348000000002', 'Two parcel types', '[{"description":"Books","quantity":2,"weight_kg":0.000001},{"description":"Clothes","quantity":3}]'::jsonb),
    (v_reject_request_id, v_customer_id, v_service_id, v_customer_user_id, '56 Test Pickup Road', 'Lagos', 'Sender', '+2348000000001', '78 Test Delivery Road', 'Abeokuta', 'Recipient', '+2348000000003', 'Rejected test parcel', null);
  insert into operations_fixture values ('operations_user',v_operations_id),('customer_user',v_customer_user_id),('customer',v_customer_id),('convert_request',v_convert_request_id),('reject_request',v_reject_request_id);
  perform set_config('request.jwt.claim.sub', v_operations_id::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',v_operations_id,'role','authenticated')::text, true);
  v_result := public.process_service_request(v_convert_request_id,'start_review');
  if v_result->>'status' <> 'under_review' then raise exception 'start_review result failed: %',v_result; end if;
  if (select status::text from public.service_requests where id=v_convert_request_id) <> 'under_review' then raise exception 'start_review status was not persisted'; end if;
  v_result := public.process_service_request(v_convert_request_id,'approve',2500,'Route and price confirmed');
  if v_result->>'status' <> 'converted' then raise exception 'approval result failed: %',v_result; end if;
  if (select status::text from public.service_requests where id=v_convert_request_id) <> 'converted' then raise exception 'request conversion was not persisted'; end if;
  if (select count(*) from public.orders where service_request_id=v_convert_request_id) <> 1 then raise exception 'approval should create one order'; end if;
  if (select customer_price from public.orders where service_request_id=v_convert_request_id) <> 2500 then raise exception 'order price not saved'; end if;
  if not exists (select 1 from public.orders o join public.service_requests r on r.id=o.service_request_id where r.id=v_convert_request_id and o.customer_id=r.customer_id and o.service_id=r.service_id) then raise exception 'order linkage mismatch'; end if;
  if (select count(*) from public.jobs j join public.orders o on o.id=j.order_id where o.service_request_id=v_convert_request_id) <> 1 then raise exception 'approval should create one linked job'; end if;
  if (select j.delivery_address from public.jobs j join public.orders o on o.id=j.order_id where o.service_request_id=v_convert_request_id) <> '34 Test Delivery Road' then raise exception 'job delivery details mismatch'; end if;
  if (select count(*) from public.job_parcels p join public.jobs j on j.id=p.job_id join public.orders o on o.id=j.order_id where o.service_request_id=v_convert_request_id) <> 2 then raise exception 'approval did not create both parcel rows'; end if;
  if not exists (select 1 from public.job_parcels p join public.jobs j on j.id=p.job_id join public.orders o on o.id=j.order_id where o.service_request_id=v_convert_request_id and p.parcel_number=1 and p.description='Books' and p.quantity=2 and p.weight_kg=0.000001) then raise exception 'structured parcel details were not preserved'; end if;
  begin
    perform public.process_service_request(v_convert_request_id,'approve',2500,null);
    raise exception 'duplicate approval unexpectedly succeeded';
  exception when sqlstate '55000' then null; end;
  v_result := public.process_service_request(v_reject_request_id,'reject',null,'Outside service area');
  if v_result->>'status' <> 'rejected' then raise exception 'reject result failed: %',v_result; end if;
  if (select operations_note from public.service_requests where id=v_reject_request_id) <> 'Outside service area' then raise exception 'rejection reason was not saved'; end if;
  perform set_config('request.jwt.claim.sub', v_customer_user_id::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',v_customer_user_id,'role','authenticated')::text, true);
  begin
    perform public.process_service_request(v_reject_request_id,'approve',2500,null);
    raise exception 'customer unexpectedly processed request';
  exception when sqlstate '42501' then null; end;
end;
$$;
rollback;
