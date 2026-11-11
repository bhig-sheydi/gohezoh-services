begin;
do $$
declare v_user uuid:=gen_random_uuid(); v_customer uuid:=gen_random_uuid(); v_service uuid;
  v_request uuid:=gen_random_uuid(); v_photo text; v_denied boolean:=false; v_price public.bike_route_prices%rowtype;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',v_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_user,'customer') on conflict do nothing;
  insert into public.customers(id,company_name,contact_person,phone,created_by)
  values(v_customer,'Bike price test','Test Customer','08000000001',v_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_user);
  select id into v_service from public.services where code='SRV-0001';
  if v_service is null then raise exception 'Local service missing'; end if;
  v_photo:=v_user||'/bike-price.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata)
  values('customer-saved-parcels',v_photo,v_user::text,'{"mimetype":"image/jpeg","size":100}');
  perform set_config('request.jwt.claim.sub',v_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_user,'role','authenticated')::text,true);
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,pickup_latitude,pickup_longitude,
    pickup_captured_at,pickup_location_source,sender_name,sender_phone,delivery_address,delivery_city,delivery_latitude,
    delivery_longitude,delivery_captured_at,delivery_location_source,recipient_name,recipient_phone,parcel_summary,parcel_items,parcel_photo_path)
  values(v_request,v_customer,v_service,v_user,'Pickup Road','Lagos',6.5,3.4,now(),'search','Sender','08000000002',
    'Delivery Road','Lagos',6.51,3.41,now(),'search','Recipient','08000000003','Two wigs',
    '[{"description":"Two wigs","catalog_code":"wig_short","quantity":2,"declared_value":30000,"length_cm":1,"width_cm":1,"height_cm":1,"weight_kg":0.001}]'::jsonb,v_photo);
  if (select (parcel_items->0->>'length_cm')::numeric from public.service_requests where id=v_request)<>25 then
    raise exception 'Client-supplied dimensions were trusted'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_user,'role','service_role')::text,true);
  perform public.record_bike_route_price(v_request,1000,600);
  select * into v_price from public.bike_route_prices where request_id=v_request;
  if v_price.space_surcharge_ngn<>250 or v_price.customer_price_ngn<1250 then
    raise exception 'Packed-space price was not added correctly: %',v_price.space_surcharge_ngn; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_user,'role','authenticated')::text,true);
  begin
    insert into public.service_requests(customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,
      delivery_address,delivery_city,recipient_name,recipient_phone,parcel_summary,parcel_items,parcel_photo_path)
    values(v_customer,v_service,v_user,'Pickup Road','Lagos','Sender','08000000002','Delivery Road','Lagos',
      'Recipient','08000000003','Too valuable',
      '[{"description":"Two phones","catalog_code":"phone","quantity":2,"declared_value":40000}]'::jsonb,v_photo);
  exception when check_violation then v_denied:=true; end;
  if not v_denied then raise exception 'NGN 70,000 shipment cap was bypassed'; end if;
  v_denied:=false;
  begin
    insert into public.service_requests(customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,
      delivery_address,delivery_city,recipient_name,recipient_phone,parcel_summary,parcel_items,parcel_photo_path)
    values(v_customer,v_service,v_user,'Pickup Road','Lagos','Sender','08000000002','Delivery Road','Lagos',
      'Recipient','08000000003','Too large',
      '[{"description":"Three long wigs","catalog_code":"wig_long","quantity":3,"declared_value":1000}]'::jsonb,v_photo);
  exception when check_violation then v_denied:=true; end;
  if not v_denied then raise exception 'Bike box capacity was bypassed'; end if;
end $$;
rollback;
