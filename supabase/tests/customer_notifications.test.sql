begin;
create temporary table customer_notification_fixture (user_id uuid, other_user_id uuid, notification_id uuid);
grant select on customer_notification_fixture to authenticated;
do $$
declare
  v_customer_user uuid := gen_random_uuid();
  v_second_customer_user uuid := gen_random_uuid();
  v_other_user uuid := gen_random_uuid();
  v_operations_user uuid := gen_random_uuid();
  v_customer uuid := gen_random_uuid();
  v_service uuid;
  v_request uuid := gen_random_uuid();
  v_order uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid();
  v_pod_request uuid := gen_random_uuid();
  v_pod_order uuid := gen_random_uuid();
  v_pod_job uuid := gen_random_uuid();
  v_notification uuid;
  v_read_at timestamptz;
begin
  select id into v_service from public.services where code = 'SRV-0001';
  if v_service is null then raise exception 'Expected seeded Local Delivery service'; end if;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values
    (v_customer_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'notification-customer-'||v_customer_user::text||'@example.test', '', now(), '{}', '{}', now(), now()),
    (v_second_customer_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'notification-second-'||v_second_customer_user::text||'@example.test', '', now(), '{}', '{}', now(), now()),
    (v_other_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'notification-other-'||v_other_user::text||'@example.test', '', now(), '{}', '{}', now(), now()),
    (v_operations_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'notification-ops-'||v_operations_user::text||'@example.test', '', now(), '{}', '{}', now(), now());
  insert into public.user_roles(user_id, role) values (v_operations_user, 'operations');
  insert into public.customers(id, company_name, customer_type, contact_person, email, phone, created_by)
    values (v_customer, 'Notification test customer', 'business', 'Test Contact', 'notification@example.test', '+2348000000000', v_customer_user);
  insert into public.customer_users(customer_id, user_id) values (v_customer, v_customer_user), (v_customer, v_second_customer_user);

  insert into public.service_requests(id, customer_id, service_id, created_by, pickup_address, pickup_city, sender_name, sender_phone, delivery_address, delivery_city, recipient_name, recipient_phone)
    values (v_request, v_customer, v_service, v_customer_user, '1 Pickup Road', 'Lagos', 'Sender', '+2348000000001', '2 Delivery Road', 'Ibadan', 'Recipient', '+2348000000002');
  if (select count(*) from public.notifications where event_type='service_request_received' and payload->>'request_id'=v_request::text) <> 2 then
    raise exception 'New request notification should reach every customer account member';
  end if;

  insert into public.orders(id, service_request_id, customer_id, service_id, status, customer_price, confirmed_by, confirmed_at)
    values(v_order, v_request, v_customer, v_service, 'confirmed', 2500, v_operations_user, now());
  insert into public.jobs(id, order_id, customer_id, service_id, assigned_operations_user_id, status, pickup_address, pickup_city, sender_name, sender_phone, delivery_address, delivery_city, recipient_name, recipient_phone)
    values(v_job, v_order, v_customer, v_service, v_operations_user, 'order_confirmed', '1 Pickup Road', 'Lagos', 'Sender', '+2348000000001', '2 Delivery Road', 'Ibadan', 'Recipient', '+2348000000002');
  if not exists (select 1 from public.notifications where user_id=v_customer_user and event_type='job_order_confirmed' and job_id=v_job) then
    raise exception 'Order confirmation should create a customer job notification';
  end if;

  perform set_config('request.jwt.claim.sub', v_operations_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',v_operations_user,'role','authenticated')::text, true);
  update public.jobs set status='pickup_scheduled' where id=v_job;
  update public.jobs set status='pickup_scheduled' where id=v_job;
  if (select count(*) from public.notifications where event_type='job_status_pickup_scheduled' and job_id=v_job) <> 2 then
    raise exception 'A changed delivery status should notify once; unchanged status should not duplicate it';
  end if;
  update public.service_requests set status='under_review' where id=v_request;
  if not exists (select 1 from public.notifications where event_type='service_request_under_review' and payload->>'request_id'=v_request::text) then
    raise exception 'Under-review request should notify the customer';
  end if;

  insert into public.service_requests(id, customer_id, service_id, created_by, pickup_address, pickup_city, sender_name, sender_phone, delivery_address, delivery_city, recipient_name, recipient_phone)
    values (v_pod_request, v_customer, v_service, v_customer_user, '3 Pickup Road', 'Lagos', 'Sender', '+2348000000001', '4 Delivery Road', 'Abeokuta', 'Recipient', '+2348000000002');
  insert into public.orders(id, service_request_id, customer_id, service_id, status, customer_price, confirmed_by, confirmed_at)
    values(v_pod_order, v_pod_request, v_customer, v_service, 'confirmed', 2500, v_operations_user, now());
  insert into public.jobs(id, order_id, customer_id, service_id, assigned_operations_user_id, status, pickup_address, pickup_city, sender_name, sender_phone, delivery_address, delivery_city, recipient_name, recipient_phone)
    values(v_pod_job, v_pod_order, v_customer, v_service, v_operations_user, 'delivered', '3 Pickup Road', 'Lagos', 'Sender', '+2348000000001', '4 Delivery Road', 'Abeokuta', 'Recipient', '+2348000000002');
  insert into public.proof_of_delivery(job_id, storage_path, recorded_by, recipient_name)
    values(v_pod_job, v_pod_job::text||'/proof.jpg', v_operations_user, 'Recipient');
  if not exists (select 1 from public.notifications where event_type='proof_of_delivery_added' and job_id=v_pod_job) then
    raise exception 'New proof of delivery should notify the customer';
  end if;

  select id into v_notification from public.notifications where user_id=v_customer_user and event_type='service_request_received' and payload->>'request_id'=v_request::text limit 1;
  perform set_config('request.jwt.claim.sub', v_customer_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',v_customer_user,'role','authenticated')::text, true);
  v_read_at := public.mark_customer_notification_read(v_notification);
  if v_read_at is null or (select read_at from public.notifications where id=v_notification) is null then
    raise exception 'Customer should be able to mark their own notification as read';
  end if;

  perform set_config('request.jwt.claim.sub', v_other_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',v_other_user,'role','authenticated')::text, true);
  begin
    perform public.mark_customer_notification_read(v_notification);
    raise exception 'Unrelated account unexpectedly marked another customer notification as read';
  exception when no_data_found then null; end;

  if not exists(select 1 from pg_policies where schemaname='public' and tablename='notifications' and policyname='notifications_read_self') then
    raise exception 'Customer notification self-read policy is missing';
  end if;
  insert into customer_notification_fixture(user_id, other_user_id, notification_id)
  values (v_customer_user, v_other_user, v_notification);
  perform set_config('request.jwt.claim.sub', v_customer_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',v_customer_user,'role','authenticated')::text, true);
end;
$$;
set local role authenticated;
do $$
declare
  v_user uuid;
  v_other uuid;
  v_notification uuid;
begin
  select user_id, other_user_id, notification_id into v_user, v_other, v_notification
  from customer_notification_fixture;
  if not exists(select 1 from public.notifications where id=v_notification and user_id=v_user) then
    raise exception 'Customer cannot read their own notification';
  end if;
  if exists(select 1 from public.notifications where user_id=v_other) then
    raise exception 'Customer can read another account notifications';
  end if;
end;
$$;
reset role;
rollback;
