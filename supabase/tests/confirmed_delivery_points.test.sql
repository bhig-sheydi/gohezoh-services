begin;
do $$
declare
  v_user uuid:=gen_random_uuid();v_customer uuid:=gen_random_uuid();v_service uuid;
  v_request uuid:=gen_random_uuid();v_order uuid:=gen_random_uuid();v_job uuid:=gen_random_uuid();
  v_invalid boolean:=false;
begin
  select id into v_service from public.services where code='SRV-0001';
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values(v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',v_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.customers(id,company_name,contact_person,phone,created_by)
    values(v_customer,'Pin test','Pin Customer','08000000001',v_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_user);
  insert into public.customer_parcel_destinations(user_id,slot,label,address,city,state,latitude,longitude,location_source)
    values(v_user,1,'Work','1 Test Road','Lagos','Lagos',6.45,3.4,'map');
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,
    pickup_latitude,pickup_longitude,pickup_location_source,pickup_captured_at,sender_name,sender_phone,
    delivery_address,delivery_city,delivery_latitude,delivery_longitude,delivery_location_source,delivery_captured_at,
    recipient_name,recipient_phone)
  values(v_request,v_customer,v_service,v_user,'1 Pickup Road','Lagos',6.45,3.4,'map',now(),'Sender','08000000002',
    '2 Delivery Road','Lagos',6.47,3.42,'map',now(),'Recipient','08000000003');
  insert into public.orders(id,service_request_id,customer_id,service_id,status,confirmed_by)
    values(v_order,v_request,v_customer,v_service,'confirmed',v_user);
  insert into public.jobs(id,order_id,customer_id,service_id,status,pickup_address,pickup_city,sender_name,sender_phone,
    delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_job,v_order,v_customer,v_service,'order_confirmed','1 Pickup Road','Lagos','Sender','08000000002',
      '2 Delivery Road','Lagos','Recipient','08000000003');
  if not exists(select 1 from public.jobs where id=v_job and delivery_latitude=6.47 and delivery_longitude=3.42) then
    raise exception 'Confirmed delivery point was not copied to the job'; end if;
  begin
    insert into public.service_requests(customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,
      delivery_address,delivery_city,delivery_latitude,recipient_name,recipient_phone)
    values(v_customer,v_service,v_user,'1 Pickup Road','Lagos','Sender','08000000002',
      '2 Delivery Road','Lagos',6.47,'Recipient','08000000003');
  exception when check_violation then v_invalid:=true; end;
  if not v_invalid then raise exception 'Incomplete delivery point was accepted'; end if;
end $$;
rollback;
