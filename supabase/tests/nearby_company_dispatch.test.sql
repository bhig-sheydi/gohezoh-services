begin;
do $$
declare
  v_customer_user uuid:=gen_random_uuid(); v_manager uuid:=gen_random_uuid(); v_far_manager uuid:=gen_random_uuid(); v_operations uuid:=gen_random_uuid();
  v_rider uuid:=gen_random_uuid(); v_rider2 uuid:=gen_random_uuid(); v_far_rider uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid(); v_company uuid:=gen_random_uuid(); v_far_company uuid:=gen_random_uuid();
  v_service uuid; v_corridor uuid; v_request uuid:=gen_random_uuid(); v_request2 uuid:=gen_random_uuid(); v_path text; v_denied boolean:=false;
  v_id uuid; v_owner uuid; v_company_id uuid; v_session uuid:=gen_random_uuid();
begin
  select id into v_service from public.services where code='SRV-0001';
  select c.id into v_corridor from public.coverage_corridors c join public.coverage_locations o on o.id=c.origin_id
    join public.coverage_locations d on d.id=c.destination_id where c.service_code='SRV-0001' and o.name='Lagos' and d.name='Lagos';
  if v_service is null or v_corridor is null then raise exception 'Local delivery fixture missing'; end if;
  foreach v_id in array array[v_customer_user,v_manager,v_far_manager,v_operations,v_rider,v_rider2,v_far_rider] loop
    insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values(v_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',v_id||'@example.test','',now(),'{}',
      (case when v_id in (v_rider,v_rider2,v_far_rider) then '{"account_kind":"company_rider"}' else '{}' end)::jsonb,now(),now());
  end loop;
  insert into public.user_roles(user_id,role) values(v_customer_user,'customer'),(v_manager,'partner'),(v_far_manager,'partner'),(v_operations,'operations'),
    (v_rider,'rider'),(v_rider2,'rider'),(v_far_rider,'rider') on conflict do nothing;
  insert into public.customers(id,company_name,contact_person,phone,created_by) values(v_customer,'Nearby fixture','Customer','08000000001',v_customer_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_customer_user);
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status) values
    (v_company,'Near Company','Manager','08000000002','active'),(v_far_company,'Far Company','Manager','08000000003','active');
  insert into public.partner_users(partner_id,user_id,membership_role) values
    (v_company,v_manager,'manager'),(v_far_company,v_far_manager,'manager'),
    (v_company,v_rider,'rider'),(v_company,v_rider2,'rider'),(v_far_company,v_far_rider,'rider');
  foreach v_id in array array[v_rider,v_rider2,v_far_rider] loop
    v_company_id:=case when v_id=v_far_rider then v_far_company else v_company end;
    insert into public.company_riders(partner_id,full_name,nin,licence_document_path,status)
    values(v_company_id,'Fixture Rider',lpad((floor(random()*99999999999))::bigint::text,11,'0'),v_id||'/licence.pdf','approved') returning id into v_owner;
    insert into public.rider_credentials(user_id,partner_id,roster_id,rider_name,auth_secret_seed,link_hash,password_salt,password_hash,password_fingerprint)
    values(v_id,v_company_id,v_owner,'Fixture Rider',v_id||'-seed',v_id||'-link','salt','hash',v_id||'-fingerprint');
  end loop;
  insert into auth.sessions(id,user_id,created_at,updated_at) values(v_session,v_rider,now(),now());
  perform set_config('request.jwt.claim.sub',v_rider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated','session_id',v_session)::text,true);
  v_denied:=false;
  begin perform public.report_rider_position(6.45,3.4,500,now()); exception when check_violation then v_denied:=true; end;
  if not v_denied then raise exception 'Inaccurate GPS was accepted'; end if;
  if not public.report_rider_position(6.45,3.4,18,now()) then raise exception 'First rider location was throttled'; end if;
  if public.report_rider_position(6.45,3.4,18,now()) then raise exception 'Second rider location was not throttled'; end if;
  perform public.stop_rider_availability();
  if exists(select 1 from public.rider_presence where user_id=v_rider) then raise exception 'Going offline left a rider online'; end if;
  if not public.report_rider_position(6.45,3.4,18,now()) then raise exception 'Rider could not return online'; end if;
  insert into public.rider_presence(user_id,partner_id,position,accuracy_metres,captured_at) values
    (v_rider2,v_company,extensions.st_setsrid(extensions.st_makepoint(3.401,6.45),4326)::extensions.geography,20,now()),
    (v_far_rider,v_far_company,extensions.st_setsrid(extensions.st_makepoint(3.9,6.9),4326)::extensions.geography,18,now());
  v_path:=v_customer_user||'/dispatch-test.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('customer-saved-parcels',v_path,v_customer_user::text,'{"mimetype":"image/jpeg","size":100}');
  perform set_config('request.jwt.claim.sub',v_customer_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,
    delivery_address,delivery_city,recipient_name,recipient_phone,parcel_summary,parcel_items,parcel_photo_path,
    pickup_latitude,pickup_longitude,pickup_accuracy_metres,pickup_captured_at,pickup_location_source)
  values(v_request,v_customer,v_service,v_customer_user,'1 Lagos Road','Lagos','Sender','08000000004',
    '2 Lagos Road','Lagos','Recipient','08000000005','Books',
    '[{"description":"Books","quantity":1,"weight_kg":1,"length_cm":10,"width_cm":10,"height_cm":10,"declared_value":1000,"price":500}]'::jsonb,v_path,
    6.45,3.4,18,now(),'browser');
  if (select count(*) from public.company_bid_invitations where request_id=v_request)<>1 then raise exception 'Expected one invitation to the near company only'; end if;
  if exists(select 1 from public.partner_corridor_coverage where partner_id in (v_company,v_far_company)) then
    raise exception 'Proximity fixture must not depend on manual route assignments'; end if;
  if not exists(select 1 from public.company_bid_invitations where request_id=v_request and partner_id=v_company and rider_id=v_rider) then
    raise exception 'Nearest rider did not source the company invitation'; end if;
  if (select dispatch_match_status from public.service_requests where id=v_request)<>'bidding' then raise exception 'Customer matching status is wrong'; end if;
  perform set_config('request.jwt.claim.sub',v_far_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_far_manager,'role','authenticated')::text,true);
  if exists(select 1 from public.list_partner_bid_screen() where request_id=v_request) then raise exception 'Far company saw a bid'; end if;
  if exists(select 1 from public.list_company_bid_pickups() where request_id=v_request) then raise exception 'Far company saw pickup coordinates'; end if;
  v_denied:=false;
  begin perform public.submit_partner_quote(v_request,2000,2,'Pickup and delivery','None',true,'None');
  exception when insufficient_privilege then v_denied:=true; end;
  if not v_denied then raise exception 'Far company bid succeeded'; end if;
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  if (select count(*) from public.list_partner_bid_screen() where request_id=v_request)<>1 then raise exception 'Near company did not see its bid'; end if;
  if (select count(*) from public.list_company_bid_pickups() where request_id=v_request and pickup_address='1 Lagos Road')<>1 then
    raise exception 'Near company cannot see pickup location'; end if;
  if public.submit_partner_quote(v_request,2000,2,'Pickup and delivery','None',true,'None') is null then raise exception 'Near company could not bid'; end if;
  update public.rider_presence set received_at=now()-interval '3 minutes',captured_at=now()-interval '3 minutes' where partner_id=v_company;
  if exists(select 1 from public.list_partner_bid_screen() where request_id=v_request) then raise exception 'Stale rider kept bid visible'; end if;
  v_denied:=false;
  begin perform public.submit_partner_quote(v_request,2500,2,'Pickup and delivery','None',true,'None');
  exception when insufficient_privilege then v_denied:=true; end;
  if not v_denied then raise exception 'Company bid with stale GPS'; end if;
  perform set_config('request.jwt.claim.sub',v_customer_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,
    delivery_address,delivery_city,recipient_name,recipient_phone,parcel_summary,parcel_items,parcel_photo_path,
    pickup_latitude,pickup_longitude,pickup_captured_at,pickup_location_source)
  values(v_request2,v_customer,v_service,v_customer_user,'1 Lagos Road','Lagos','Sender','08000000004',
    '2 Lagos Road','Lagos','Recipient','08000000005','Books',
    '[{"description":"Books","quantity":1,"weight_kg":1,"length_cm":10,"width_cm":10,"height_cm":10}]'::jsonb,v_path,
    6.45,3.4,now(),'search');
  if (select dispatch_match_status from public.service_requests where id=v_request2)<>'waiting' then raise exception 'Unmatched request was not queued'; end if;
  perform set_config('request.jwt.claim.sub',v_rider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated','session_id',v_session)::text,true);
  perform public.report_rider_position(6.45,3.4,18,now());
  perform public.process_dispatch_matches();
  if (select dispatch_match_status from public.service_requests where id=v_request2)<>'bidding'
    or (select count(*) from public.company_bid_invitations where request_id=v_request2)<>1 then
    raise exception 'Queued request did not route to the company after a rider returned'; end if;
  perform set_config('request.jwt.claim.sub',v_operations::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_operations,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  if exists(select 1 from public.service_requests where id=v_request2) then raise exception 'Operations can see automated pickup details'; end if;
  execute 'reset role';
end $$;
rollback;
