begin;
create temporary table parcel_tracking_fixture (operations_user uuid, customer_user uuid, customer_id uuid, request_id uuid, job_id uuid);
grant select on parcel_tracking_fixture to authenticated;
do $$
declare
  v_ops uuid:=gen_random_uuid(); v_customer_user uuid:=gen_random_uuid(); v_customer uuid:=gen_random_uuid();
  v_service uuid; v_request uuid:=gen_random_uuid(); v_job uuid; v_result jsonb;
begin
  select id into v_service from public.services where code='SRV-0003';
  if v_service is null then raise exception 'Expected seeded Warehousing service'; end if;
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values (v_ops,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','parcel-ops-'||v_ops||'@example.test','',now(),'{}','{}',now(),now()),
         (v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','parcel-customer-'||v_customer_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_ops,'operations');
  insert into public.customers(id,company_name,customer_type,contact_person,email,phone,created_by)
  values(v_customer,'Parcel tracking test','business','Test Contact','parcel-profile-'||v_customer||'@example.test','08000000001',v_customer_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_customer_user);
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone,parcel_summary,parcel_items)
  values(v_request,v_customer,v_service,v_customer_user,'1 Pickup Road','Lagos','Sender','08000000002','2 Delivery Road','Ibadan','Recipient','08000000003','Two separately identified parcels','[{"description":"Books","quantity":2},{"description":"Clothes","quantity":3}]'::jsonb);
  perform set_config('request.jwt.claim.sub',v_ops::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_ops,'role','authenticated')::text,true);
  perform public.process_service_request(v_request,'start_review');
  v_result:=public.process_service_request(v_request,'approve',2500,null);
  v_job:=(v_result->>'job_id')::uuid;
  if (select count(*) from public.job_parcels where job_id=v_job)<>2 then raise exception 'Expected one tracking ID per parcel row'; end if;
  if exists(select 1 from public.job_parcels where job_id=v_job and tracking_code !~ '^KWP-P-[0-9]{8,}$') then raise exception 'Generated parcel ID has an invalid format'; end if;
  if (select count(distinct tracking_code) from public.job_parcels where job_id=v_job)<>2 then raise exception 'Parcel tracking IDs must be unique'; end if;
  if not exists(select 1 from public.job_parcels where job_id=v_job and description='Books' and quantity=2 and tracking_code is not null) then raise exception 'Quantity greater than one lost its row-level tracking code or quantity'; end if;
  begin
    update public.job_parcels set tracking_code='KWP-P-99999999' where job_id=v_job and parcel_number=1;
    raise exception 'Tracking code update unexpectedly succeeded';
  exception when check_violation then null; end;
  insert into parcel_tracking_fixture values(v_ops,v_customer_user,v_customer,v_request,v_job);
end $$;

select set_config('request.jwt.claim.sub',(select customer_user::text from parcel_tracking_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select customer_user from parcel_tracking_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  if (select count(*) from public.job_parcels where job_id=(select job_id from parcel_tracking_fixture))<>2 then raise exception 'The parcel owner cannot view parcel IDs'; end if;
end $$;
reset role;
rollback;
