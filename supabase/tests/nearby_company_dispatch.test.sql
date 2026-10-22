begin;
do $$
declare
  v_customer_user uuid:=gen_random_uuid(); v_manager uuid:=gen_random_uuid(); v_far_manager uuid:=gen_random_uuid(); v_operations uuid:=gen_random_uuid();
  v_rider uuid:=gen_random_uuid(); v_rider2 uuid:=gen_random_uuid(); v_far_rider uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid(); v_company uuid:=gen_random_uuid(); v_far_company uuid:=gen_random_uuid();
  v_service uuid; v_corridor uuid; v_request uuid:=gen_random_uuid(); v_request2 uuid:=gen_random_uuid(); v_path text; v_denied boolean:=false;
  v_id uuid; v_owner uuid; v_company_id uuid; v_session uuid:=gen_random_uuid(); v_job uuid; v_pickup_code text; v_pickup_result jsonb; v_attempt integer;
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
  insert into public.company_daily_dispatch_closing(partner_id,work_date,closes_at,updated_by) values
    (v_company,(now() at time zone 'Africa/Lagos')::date,now()+interval '6 hours',v_manager),
    (v_far_company,(now() at time zone 'Africa/Lagos')::date,now()+interval '6 hours',v_far_manager);
  if not public.company_dispatch_route_fits(v_company,30) then raise exception 'Feasible route was blocked before closing'; end if;
  update public.company_daily_dispatch_closing set closes_at=now()+interval '49 minutes' where partner_id=v_company;
  if public.company_dispatch_route_fits(v_company,30) then raise exception 'Closing time omitted the 20-minute buffer'; end if;
  update public.company_daily_dispatch_closing set closes_at=now()+interval '6 hours' where partner_id=v_company;
  insert into public.partner_users(partner_id,user_id,membership_role) values
    (v_company,v_manager,'manager'),(v_far_company,v_far_manager,'manager'),
    (v_company,v_rider,'rider'),(v_company,v_rider2,'rider'),(v_far_company,v_far_rider,'rider');
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  if public.set_my_company_closing_time(v_company,
    ((now()+interval '3 hours') at time zone 'Africa/Lagos')::time,
    ((now()+interval '3 hours') at time zone 'Africa/Lagos')::date>(now() at time zone 'Africa/Lagos')::date)
      <=now()+interval '2 hours' then raise exception 'Manager could not change daily closing'; end if;
  if not exists(select 1 from public.my_company_dispatch_hours(v_company) where source='today') then
    raise exception 'Manager cannot view updated closing time'; end if;
  perform set_config('request.jwt.claim.sub',v_far_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_far_manager,'role','authenticated')::text,true);
  v_denied:=false;
  begin perform public.set_my_company_closing_time(v_company,'18:00',false);
  exception when insufficient_privilege then v_denied:=true; end;
  if not v_denied then raise exception 'Another company changed closing time'; end if;
  update public.company_daily_dispatch_closing set closes_at=now()+interval '6 hours' where partner_id=v_company;
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
  if (select status from public.delivery_quote_windows where request_id=v_request)<>'matching' then
    raise exception 'Request must wait for route matching before bidding'; end if;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  perform public.upsert_dispatch_route_proposal(v_request,v_company,v_rider,'available','road-v2-live',20,
    '{"tier":1,"estimate_source":"road","total_route_minutes":30}'::jsonb,now()+interval '2 minutes');
  perform public.upsert_dispatch_route_proposal(v_request,v_far_company,v_far_rider,'available','road-v2-live',2,
    '{"tier":2,"estimate_source":"road","total_route_minutes":30}'::jsonb,now()+interval '2 minutes');
  if public.finalize_live_route_match(v_request)<>'tier_1' then
    raise exception 'A distant route displaced the nearby route'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
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
  if not exists(select 1 from public.list_partner_bid_route_addresses()
    where request_id=v_request and pickup_address='1 Lagos Road' and delivery_address='2 Lagos Road') then
    raise exception 'Invited company cannot see the saved route labels'; end if;
  if (select count(*) from public.list_company_bid_pickups() where request_id=v_request and pickup_address='1 Lagos Road')<>1 then
    raise exception 'Near company cannot see pickup location'; end if;
  if public.submit_partner_quote(v_request,2000,2,'Pickup and delivery','None',true,'None') is null then raise exception 'Near company could not bid'; end if;
  begin
  perform set_config('request.jwt.claim.sub',v_rider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated','session_id',v_session)::text,true);
  if public.set_rider_load_state('almost_full')<>'almost_full' then raise exception 'Rider could not mark almost full'; end if;
  if not exists(select 1 from public.rider_presence where user_id=v_rider) then raise exception 'Almost full stopped GPS presence'; end if;
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  if not exists(select 1 from public.list_company_bid_rider_loads()
    where request_id=v_request and rider_name='Fixture Rider' and load_state='almost_full') then
    raise exception 'Company did not receive almost-full bid warning'; end if;
  perform set_config('request.jwt.claim.sub',v_rider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated','session_id',v_session)::text,true);
  if public.set_rider_load_state('full')<>'full' then raise exception 'Rider could not mark full'; end if;
  if not exists(select 1 from public.rider_presence where user_id=v_rider) then raise exception 'Full rider lost GPS presence'; end if;
  if not exists(select 1 from public.company_bid_invitations
    where request_id=v_request and partner_id=v_company and rider_id=v_rider2) then
    raise exception 'Full rider invitation was not reassigned to available company rider'; end if;
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  if not exists(select 1 from public.list_partner_bid_screen() where request_id=v_request) then
    raise exception 'Company lost bid even though it has an available replacement rider'; end if;
    raise sqlstate 'P0004' using message='ROLLBACK_RIDER_LOAD_SUBTEST';
  exception when sqlstate 'P0004' then null; end;
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
  insert into public.delivery_quote_windows(request_id,corridor_id,status,published_at,deadline_at)
    values(v_request2,v_corridor,'matching',now(),now()+interval '2 minutes');
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  if public.finalize_live_route_match(v_request2)<>'no_rider' then raise exception 'Expected no-rider result'; end if;
  if (select dispatch_match_status from public.service_requests where id=v_request2)<>'waiting'
    or not exists(select 1 from public.dispatch_match_queue where request_id=v_request2) then
    raise exception 'No-rider result stopped the persistent search'; end if;
  update public.dispatch_match_queue set attempts=31,next_attempt_at=now()-interval '1 second' where request_id=v_request2;
  perform public.process_dispatch_matches();
  if not exists(select 1 from public.dispatch_match_queue where request_id=v_request2 and attempts=32) then
    raise exception 'Persistent search stopped after the former 30-attempt limit'; end if;
  perform set_config('request.jwt.claim.sub',v_rider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated','session_id',v_session)::text,true);
  perform public.report_rider_position(6.45,3.4,18,now());
  update public.dispatch_match_queue set next_attempt_at=now()-interval '1 second' where request_id=v_request2;
  perform public.process_dispatch_matches();
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  perform public.upsert_dispatch_route_proposal(v_request2,v_company,v_rider,'available','road-v2-live',20,
    '{"tier":1,"estimate_source":"road","total_route_minutes":30}'::jsonb,now()+interval '2 minutes');
  perform public.finalize_live_route_match(v_request2);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated','session_id',v_session)::text,true);
  if (select dispatch_match_status from public.service_requests where id=v_request2)<>'bidding'
    or (select count(*) from public.company_bid_invitations where request_id=v_request2)<>1 then
    raise exception 'Queued request did not route to the company after a rider returned'; end if;
  perform set_config('request.jwt.claim.sub',v_operations::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_operations,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  if exists(select 1 from public.service_requests where id=v_request2) then raise exception 'Operations can see automated pickup details'; end if;
  execute 'reset role';
  update public.delivery_quote_windows set published_at=now()-interval '2 minutes',deadline_at=now()-interval '1 minute'
    where request_id=v_request;
  update public.partner_quotes set submitted_at=now()-interval '90 seconds' where request_id=v_request;
  perform set_config('request.jwt.claim.sub',v_customer_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
  perform public.select_customer_partner_bid(v_request,(select id from public.partner_quotes where request_id=v_request limit 1));
  if (select amount_ngn from public.customer_payment_holds where request_id=v_request)<>2000
    or (select customer_price_ngn from public.customer_delivery_quotes where request_id=v_request)<>2000 then
    raise exception 'Selected local bid did not become the exact payment amount'; end if;
  if (select status from public.customer_payment_holds where request_id=v_request)<>'initializing' then
    raise exception 'Local payment hold was not created'; end if;
  perform set_config('request.jwt.claim.sub',v_rider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated','session_id',v_session)::text,true);
  if (select count(*) from public.list_my_selected_pickups() where request_id=v_request)<>1 then
    raise exception 'Selected company pickup was not routed to its invited rider'; end if;
  if not exists(select 1 from public.list_my_selected_pickups()
    where request_id=v_request and pickup_address='1 Lagos Road' and delivery_address='2 Lagos Road') then
    raise exception 'Selected rider cannot see the saved route labels'; end if;
  update public.customer_payment_holds set expires_at=now()-interval '1 second' where request_id=v_request;
  if exists(select 1 from public.list_my_selected_pickups() where request_id=v_request) then
    raise exception 'Expired payment hold still reserved the rider'; end if;
  update public.customer_payment_holds set expires_at=now()+interval '2 minutes',status='pending',
    account_number='1234567890',bank_name='Test Bank' where request_id=v_request;
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  if (public.settle_flutterwave_hold((select reference from public.customer_payment_holds where request_id=v_request),987654321,2000,'NGN')->>'status')<>'paid' then
    raise exception 'Verified local payment did not confirm the job'; end if;
  if not exists(select 1 from public.orders o join public.jobs j on j.order_id=o.id
      join public.job_financials f on f.job_id=j.id join public.customer_payments p on p.job_id=j.id
      where o.service_request_id=v_request and j.assigned_rider_id=v_rider and f.partner_cost=1500
        and p.amount=2000 and p.method='online') then
    raise exception 'Paid booking did not route the rider and record the 25 percent platform fee'; end if;
  if (select count(*) from public.orders where service_request_id=v_request)<>1 then raise exception 'Duplicate order'; end if;
  select j.id into v_job from public.jobs j join public.orders o on o.id=j.order_id where o.service_request_id=v_request;
  update public.rider_credentials set load_state='full' where user_id=v_rider2;
  v_denied:=false;
  begin update public.jobs set assigned_rider_id=v_rider2 where id=v_job;
  exception when check_violation then v_denied:=true; end;
  if not v_denied then raise exception 'Direct job assignment ignored rider Full state'; end if;
  -- Prove the pickup handoff while rolling this subtest back so tracking keeps its pre-pickup fixture.
  begin
    perform set_config('request.jwt.claim.sub',v_customer_user::text,true);
    perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
    select code into v_pickup_code from public.get_my_pickup_handoff_codes(array[v_job]);
    if v_pickup_code !~ '^[0-9]{8}$' then raise exception 'Customer pickup code missing'; end if;
    perform set_config('request.jwt.claim.sub',v_far_manager::text,true);
    perform set_config('request.jwt.claims',jsonb_build_object('sub',v_far_manager,'role','authenticated')::text,true);
    if exists(select 1 from public.get_my_pickup_handoff_codes(array[v_job])) then raise exception 'Another account saw pickup code'; end if;
    v_denied:=false;
    begin perform public.verify_pickup_handoff_code(v_job,v_pickup_code);
    exception when insufficient_privilege then v_denied:=true; end;
    if not v_denied then raise exception 'Another account verified pickup'; end if;
    perform set_config('request.jwt.claim.sub',v_rider::text,true);
    perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated','session_id',v_session)::text,true);
    v_denied:=false;
    begin perform public.rider_update_job_status(v_job,'in_transit');
    exception when object_not_in_prerequisite_state then v_denied:=true; end;
    if not v_denied then raise exception 'Manual rider pickup bypassed code'; end if;
    begin
      for v_attempt in 1..5 loop
        perform public.verify_pickup_handoff_code(v_job,case when v_pickup_code='00000000' then '00000001' else '00000000' end);
      end loop;
      v_denied:=false;
      begin perform public.verify_pickup_handoff_code(v_job,v_pickup_code);
      exception when insufficient_privilege then v_denied:=true; end;
      if not v_denied then raise exception 'Five bad attempts did not pause pickup verification'; end if;
      raise sqlstate 'P0003' using message='ROLLBACK_PICKUP_COOLDOWN_SUBTEST';
    exception when sqlstate 'P0003' then null; end;
    if (public.verify_pickup_handoff_code(v_job,case when v_pickup_code='00000000' then '00000001' else '00000000' end)->>'verified')::boolean then raise exception 'Incorrect pickup code worked'; end if;
    v_pickup_result:=public.verify_pickup_handoff_code(v_job,v_pickup_code);
    if (v_pickup_result->>'verified')::boolean is distinct from true
      or (select status from public.jobs where id=v_job)<>'in_transit' then raise exception 'Correct pickup code did not start transit: %, %',v_pickup_result,(select status from public.jobs where id=v_job); end if;
    if (public.issue_delivery_otp(v_job,v_rider)->>'code') !~ '^[0-9]{6}$' then raise exception 'Recipient code cannot be issued during transit'; end if;
    perform set_config('request.jwt.claim.sub',v_customer_user::text,true);
    perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
    if exists(select 1 from public.get_my_pickup_handoff_codes(array[v_job])) then raise exception 'Used pickup code still visible'; end if;
    raise sqlstate 'P0002' using message='ROLLBACK_PICKUP_SUBTEST';
  exception when sqlstate 'P0002' then null; end;
  -- A paying customer can track only the assigned rider's fresh GPS fix.
  update public.jobs set delivery_latitude=6.46,delivery_longitude=3.41
    where order_id=(select id from public.orders where service_request_id=v_request);
  update public.rider_presence set captured_at=now(),received_at=now(),
    previous_position=extensions.st_setsrid(extensions.st_makepoint(3.399,6.45),4326)::extensions.geography,
    previous_accuracy_metres=10,previous_captured_at=now()-interval '60 seconds'
    where user_id=v_rider;
  perform set_config('request.jwt.claim.sub',v_customer_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
  if (public.get_my_delivery_tracking((select id from public.jobs where order_id=(select id from public.orders where service_request_id=v_request)))->>'state')<>'live' then
    raise exception 'Paying customer cannot see current assigned rider'; end if;
  if (public.get_my_delivery_tracking((select id from public.jobs where order_id=(select id from public.orders where service_request_id=v_request)))->>'speed_kmh') is null
    or (public.get_my_delivery_tracking((select id from public.jobs where order_id=(select id from public.orders where service_request_id=v_request)))->>'eta_minutes') is null then
    raise exception 'Recent rider movement did not produce speed and ETA'; end if;
  if (public.get_my_delivery_tracking(v_job) ? 'latitude') or (public.get_my_delivery_tracking(v_job) ? 'longitude') then
    raise exception 'Ordinary tracking leaked precise coordinates'; end if;
  update public.rider_presence set captured_at=now()-interval '3 minutes' where user_id=v_rider;
  if (public.get_my_delivery_tracking((select id from public.jobs where order_id=(select id from public.orders where service_request_id=v_request)))->>'state')<>'offline' then
    raise exception 'Stale rider coordinates were exposed'; end if;
  if (public.claim_my_rider_location_check(v_job)->>'state')<>'offline' then
    raise exception 'Stale rider location used a check'; end if;
  update public.rider_presence set captured_at=now() where user_id=v_rider;
  if (public.claim_my_rider_location_check(v_job)->>'latitude') is null
    or (public.claim_my_rider_location_check(v_job)->>'longitude') is null then
    raise exception 'First two paid location checks failed'; end if;
  if (public.claim_my_rider_location_check(v_job)->>'state')<>'limited'
    or (public.get_my_delivery_tracking(v_job)->>'checks_remaining')::integer<>0 then
    raise exception 'Third location check was not blocked'; end if;
  update public.customer_rider_location_checks set checked_at=array[now()-interval '61 minutes',now()-interval '20 minutes']
    where user_id=v_customer_user;
  if (public.claim_my_rider_location_check(v_job)->>'state')<>'live' then
    raise exception 'Rolling one-hour limit did not release an expired check'; end if;
  perform set_config('request.jwt.claim.sub',v_far_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_far_manager,'role','authenticated')::text,true);
  v_denied:=false;
  begin perform public.get_my_delivery_tracking((select id from public.jobs where order_id=(select id from public.orders where service_request_id=v_request)));
  exception when insufficient_privilege then v_denied:=true; end;
  if not v_denied then raise exception 'Another account saw customer rider tracking'; end if;
  v_denied:=false;
  begin perform public.claim_my_rider_location_check(v_job);
  exception when insufficient_privilege then v_denied:=true; end;
  if not v_denied then raise exception 'Another account claimed the rider location'; end if;
  perform set_config('request.jwt.claim.sub',v_operations::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_operations,'role','authenticated')::text,true);
  update public.jobs set status='cancelled' where order_id=(select id from public.orders where service_request_id=v_request);
  perform set_config('request.jwt.claim.sub',v_customer_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
  if (public.get_my_delivery_tracking((select id from public.jobs where order_id=(select id from public.orders where service_request_id=v_request)))->>'state')<>'completed' then
    raise exception 'Completed delivery still exposes rider coordinates'; end if;
  perform set_config('request.jwt.claim.sub',v_rider2::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider2,'role','authenticated')::text,true);
  v_denied:=false;
  begin perform public.list_my_selected_pickups(); exception when insufficient_privilege then v_denied:=true; end;
  if not v_denied then raise exception 'Unbound rider could read selected pickup'; end if;
end $$;
rollback;
