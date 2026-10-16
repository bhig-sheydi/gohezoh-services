begin;
do $$
declare
  v_user uuid:=gen_random_uuid(); v_customer uuid:=gen_random_uuid(); v_service uuid;
  v_path text; v_request uuid:=gen_random_uuid(); v_saved uuid; v_denied boolean:=false;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',v_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_user,'customer') on conflict do nothing;
  insert into public.customers(id,company_name,contact_person,phone,created_by)
  values(v_customer,'Catalogue test','Test Customer','08000000001',v_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_user);
  select id into v_service from public.services limit 1;
  if v_service is null then raise exception 'A seeded service is required'; end if;
  v_path:=v_user||'/catalogue-test.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata)
  values('customer-saved-parcels',v_path,v_user::text,'{"mimetype":"image/jpeg","size":100}');
  perform set_config('request.jwt.claim.sub',v_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_user,'role','authenticated')::text,true);
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,pickup_latitude,pickup_longitude,pickup_captured_at,pickup_location_source,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone,parcel_summary,parcel_items,parcel_photo_path)
  values(v_request,v_customer,v_service,v_user,'1 Pickup Road','Lagos',6.5244,3.3792,now(),'search','Sender','08000000002','2 Delivery Road','Lagos','Recipient','08000000003','Books',
    '[{"description":"Books","quantity":1,"weight_kg":1.3,"length_cm":30,"width_cm":20,"height_cm":10,"declared_value":25000,"price":18000}]'::jsonb,v_path);
  if not exists(select 1 from public.customer_saved_parcels where user_id=v_user and photo_path=v_path and description='Books' and declared_value=25000) then
    raise exception 'Sent item was not added to the catalogue';
  end if;
  select id into v_saved from public.customer_saved_parcels where user_id=v_user and photo_path=v_path;
  insert into public.service_requests(customer_id,service_id,created_by,pickup_address,pickup_city,pickup_latitude,pickup_longitude,pickup_captured_at,pickup_location_source,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone,parcel_summary,parcel_items,parcel_photo_path)
  values(v_customer,v_service,v_user,'1 Pickup Road','Lagos',6.5244,3.3792,now(),'search','Sender','08000000002','2 Delivery Road','Lagos','Recipient','08000000003','Books again',
    jsonb_build_array(jsonb_build_object('description','Books again','quantity',1,'weight_kg',1.3,'length_cm',30,'width_cm',20,'height_cm',10,'saved_parcel_id',v_saved)),v_path);
  if (select count(*) from public.customer_saved_parcels where user_id=v_user)<>1 then
    raise exception 'Reusing a saved item created a duplicate catalogue entry';
  end if;
  begin
    insert into public.service_requests(customer_id,service_id,created_by,pickup_address,pickup_city,pickup_latitude,pickup_longitude,pickup_captured_at,pickup_location_source,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone,parcel_summary,parcel_items)
    values(v_customer,v_service,v_user,'1 Pickup Road','Lagos',6.5244,3.3792,now(),'search','Sender','08000000002','2 Delivery Road','Lagos','Recipient','08000000003','No image',
      '[{"description":"No image","quantity":1,"weight_kg":1,"length_cm":10,"width_cm":10,"height_cm":10}]'::jsonb);
  exception when check_violation then v_denied:=true;
  end;
  if not v_denied then raise exception 'Delivery without an image was accepted'; end if;
end $$;
rollback;
