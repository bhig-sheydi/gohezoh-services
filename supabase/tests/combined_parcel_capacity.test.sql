begin;
do $$
declare
  v_user uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_service uuid;
begin
  select id into v_service from public.services where code='SRV-0001';
  if v_service is null then raise exception 'Expected seeded parcel service'; end if;
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','capacity-'||v_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.customers(id,company_name,customer_type,contact_person,email,phone,created_by)
  values(v_customer,'Capacity test','business','Test Customer','capacity-profile-'||v_user||'@example.test','08000000001',v_user);

  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone,parcel_summary,parcel_items)
  values(gen_random_uuid(),v_customer,v_service,v_user,'1 Pickup Road','Lagos','Sender','08000000002','2 Delivery Road','Ibadan','Recipient','08000000003','Two items','[{"description":"Books","quantity":2,"weight_kg":4.9,"length_cm":50,"width_cm":30,"height_cm":30}]'::jsonb);

  begin
    insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone,parcel_summary,parcel_items)
    values(gen_random_uuid(),v_customer,v_service,v_user,'1 Pickup Road','Lagos','Sender','08000000002','2 Delivery Road','Ibadan','Recipient','08000000003','Too heavy','[{"description":"Books","quantity":2,"weight_kg":5,"length_cm":50,"width_cm":30,"height_cm":30}]'::jsonb);
    raise exception 'Shipment exceeding aggregate weight was accepted';
  exception when check_violation then null; end;

  begin
    insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone,parcel_summary,parcel_items)
    values(gen_random_uuid(),v_customer,v_service,v_user,'1 Pickup Road','Lagos','Sender','08000000002','2 Delivery Road','Ibadan','Recipient','08000000003','Too large','[{"description":"Boxes","quantity":2,"weight_kg":0.1,"length_cm":99,"width_cm":60,"height_cm":70.5}]'::jsonb);
    raise exception 'Shipment exceeding packed dimensions was accepted';
  exception when check_violation then null; end;
end $$;
rollback;
