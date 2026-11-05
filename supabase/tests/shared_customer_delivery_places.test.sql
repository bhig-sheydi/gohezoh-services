begin;

do $$
declare v_a uuid:=gen_random_uuid(); v_b uuid:=gen_random_uuid(); v_staff uuid:=gen_random_uuid();
        v_first uuid; v_second uuid; v_count integer; v_denied boolean; v_i integer;
        v_customer uuid:=gen_random_uuid(); v_service uuid; v_request uuid:=gen_random_uuid();
        v_order uuid:=gen_random_uuid(); v_job uuid:=gen_random_uuid();
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'shared-place-a-'||v_a||'@example.test','',now(),'{}','{}',now(),now()),
    (v_b,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'shared-place-b-'||v_b||'@example.test','',now(),'{}','{}',now(),now()),
    (v_staff,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'shared-place-staff-'||v_staff||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_a,'customer'),(v_b,'customer'),(v_staff,'management')
    on conflict do nothing;

  -- A Google/search result or a map pin that was not actually moved cannot
  -- become a reusable customer-contributed place.
  insert into public.customer_parcel_destinations
    (user_id,slot,label,address,city,state,latitude,longitude,location_source,
      shared_label,pin_moved_by_user)
  values(v_a,1,'Work','Private delivery address, not shared','Port Harcourt','Rivers',
      4.882269,7.009648,'search','Divine Benevolent Care',false);
  select count(*) into v_count from public.shared_delivery_places
    where normalized_label='divine benevolent care';
  if v_count<>0 then raise exception 'Provider search result was shared'; end if;
  update public.customer_parcel_destinations set location_source='map' where user_id=v_a and slot=1;
  select count(*) into v_count from public.shared_delivery_places
    where normalized_label='divine benevolent care';
  if v_count<>0 then raise exception 'Unmoved map pin was shared'; end if;

  update public.customer_parcel_destinations set pin_moved_by_user=true where user_id=v_a and slot=1;
  select id into v_first from public.shared_delivery_places where normalized_label='divine benevolent care';
  if v_first is null then raise exception 'Customer-moved pin was not shared'; end if;
  if (select label from public.shared_delivery_places where id=v_first)<>'Divine Benevolent Care' then
    raise exception 'Private address was exposed instead of typed label';
  end if;

  -- Independent matching contribution within 15m shares the canonical row.
  insert into public.customer_parcel_destinations
    (user_id,slot,label,address,city,state,latitude,longitude,location_source,
      location_accuracy_metres,shared_label)
  values(v_b,2,'Home','Second private address','Port Harcourt','Rivers',
      4.882310,7.009648,'native',8,'Divine Benevolent Care');
  select place_id into v_second from public.shared_delivery_place_sources
    where user_id=v_b and source_kind='saved' and source_key='2';
  if v_first<>v_second then raise exception 'Same named place within 15m was duplicated'; end if;

  perform set_config('request.jwt.claim.sub',v_b::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_b,'role','authenticated')::text,true);
  select count(*) into v_count from public.search_shared_delivery_places('divine','Port Harcourt');
  if v_count<>1 then raise exception 'Text lookup did not return the customer place'; end if;
  select count(*) into v_count from public.search_shared_delivery_places('', 'Port Harcourt',4.8823,7.009648);
  if v_count<>1 then raise exception '15m coordinate lookup missed the customer place'; end if;
  select count(*) into v_count from public.search_shared_delivery_places('', 'Port Harcourt',4.883,7.009648);
  if v_count<>0 then raise exception '15m coordinate lookup returned distant place'; end if;
  v_denied:=false;
  begin perform public.search_shared_delivery_places('abc%','Port Harcourt');
  exception when invalid_parameter_value then v_denied:=true; end;
  if not v_denied then raise exception 'Wildcard search was accepted'; end if;
  v_denied:=false;
  begin perform public.search_shared_delivery_places('divine','');
  exception when invalid_parameter_value then v_denied:=true; end;
  if not v_denied then raise exception 'City-wide search was accepted'; end if;
  select burst_count into v_count
    from public.shared_delivery_place_search_limits where user_id=v_b;
  if v_count is null or v_count<1 then raise exception 'Valid searches were not counted'; end if;
  for v_i in (v_count+1)..30 loop
    perform public.search_shared_delivery_places('divine','Port Harcourt');
  end loop;
  v_denied:=false;
  begin perform public.search_shared_delivery_places('divine','Port Harcourt');
  exception when program_limit_exceeded then v_denied:=true; end;
  if not v_denied then raise exception 'Five-minute search burst limit was not enforced'; end if;
  if (select burst_count from public.shared_delivery_place_search_limits
      where user_id=v_b)<>30 then raise exception 'Denied search grew burst counter'; end if;
  update public.shared_delivery_place_search_limits
    set burst_started_at=clock_timestamp()-interval '6 minutes' where user_id=v_b;
  perform public.search_shared_delivery_places('divine','Port Harcourt');
  if (select burst_count from public.shared_delivery_place_search_limits
      where user_id=v_b)<>1 then raise exception 'Expired five-minute burst did not reset'; end if;
  select hour_count into v_count from public.shared_delivery_place_search_limits where user_id=v_b;
  for v_i in (v_count+1)..120 loop
    if (select burst_count from public.shared_delivery_place_search_limits where user_id=v_b)=30 then
      update public.shared_delivery_place_search_limits
        set burst_started_at=clock_timestamp()-interval '6 minutes' where user_id=v_b;
    end if;
    perform public.search_shared_delivery_places('divine','Port Harcourt');
  end loop;
  update public.shared_delivery_place_search_limits
    set burst_started_at=clock_timestamp()-interval '6 minutes' where user_id=v_b;
  v_denied:=false;
  begin perform public.search_shared_delivery_places('divine','Port Harcourt');
  exception when program_limit_exceeded then v_denied:=true; end;
  if not v_denied then raise exception 'Hourly search limit was not enforced'; end if;
  if (select hour_count from public.shared_delivery_place_search_limits
      where user_id=v_b)<>120 then raise exception 'Denied search grew hourly counter'; end if;
  update public.shared_delivery_place_search_limits
    set hour_started_at=clock_timestamp()-interval '2 hours',
        burst_started_at=clock_timestamp()-interval '6 minutes' where user_id=v_b;
  perform public.search_shared_delivery_places('divine','Port Harcourt');
  if not exists(select 1 from public.shared_delivery_place_search_limits where user_id=v_b
                and hour_count=1 and burst_count=1) then
    raise exception 'Expired search windows did not reset';
  end if;

  -- Moving a saved address beyond 15m creates a new place while keeping the
  -- earlier contributor's place; deletion removes only that contributor.
  update public.customer_parcel_destinations set latitude=4.882600
    where user_id=v_b and slot=2;
  select place_id into v_second from public.shared_delivery_place_sources
    where user_id=v_b and source_kind='saved' and source_key='2';
  if v_first=v_second then raise exception 'Distant moved address reused old point'; end if;
  delete from public.customer_parcel_destinations where user_id=v_a and slot=1;
  if exists(select 1 from public.shared_delivery_places where id=v_first) then
    raise exception 'Unreferenced shared place survived removal';
  end if;
  if not exists(select 1 from public.shared_delivery_places where id=v_second) then
    raise exception 'Another customer place was removed';
  end if;

  insert into public.customer_parcel_destinations
    (user_id,slot,label,address,city,state,latitude,longitude,location_source,
      location_accuracy_metres,shared_label)
  values(v_a,3,'Other','Private recipient point','Port Harcourt','Rivers',
      4.881,7.010,'browser',7,'Call 08064241103');
  if exists(select 1 from public.shared_delivery_place_sources
            where user_id=v_a and source_kind='saved' and source_key='3') then
    raise exception 'Phone number in shared label was published';
  end if;
  update public.customer_parcel_destinations set shared_label='owner@example.com'
    where user_id=v_a and slot=3;
  if exists(select 1 from public.shared_delivery_place_sources
            where user_id=v_a and source_kind='saved' and source_key='3') then
    raise exception 'Email in shared label was published';
  end if;
  if not exists(select 1 from public.customer_parcel_destinations
                where user_id=v_a and slot=3 and shared_label='owner@example.com') then
    raise exception 'Private address save failed when shared label was rejected';
  end if;

  -- A paid completed job contributes the customer-typed GPS pickup, but not
  -- a Google/provider-selected dropoff. The delivered insert happens before
  -- payment; the later closed transition exercises the completed-job trigger.
  select id into v_service from public.services where code='SRV-0001';
  if v_service is null then raise exception 'Expected seeded parcel service'; end if;
  insert into public.customers(id,company_name,customer_type,contact_person,email,phone,
    city,state,status,created_by)
  values(v_customer,'Shared place test','individual','Test Customer',
    'place-'||v_a||'@example.test','08000000001','Port Harcourt','Rivers','active',v_a);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_a)
    on conflict do nothing;
  -- Insert the fixture as management so unrelated customer photo-upload
  -- validation does not require a Storage object in this database-only test.
  perform set_config('request.jwt.claim.sub',v_staff::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_staff,'role','authenticated')::text,true);
  insert into public.service_requests
    (id,customer_id,service_id,created_by,pickup_address,pickup_city,pickup_state,
      sender_name,sender_phone,delivery_address,delivery_city,delivery_state,
      recipient_name,recipient_phone,pickup_latitude,pickup_longitude,
      pickup_accuracy_metres,pickup_captured_at,pickup_location_source,
      delivery_latitude,delivery_longitude,delivery_captured_at,delivery_location_source,
      shared_pickup_label,shared_delivery_label)
  values(v_request,v_customer,v_service,v_a,'Private pickup address','Port Harcourt','Rivers',
    'Sender','08000000002','Provider dropoff address','Port Harcourt','Rivers',
    'Recipient','08000000003',4.886,7.012,8,now(),'browser',
    4.891,7.015,now(),'search','Customer Typed Pickup','Provider Supplied Destination');
  insert into public.orders(id,service_request_id,customer_id,service_id,customer_price)
  values(v_order,v_request,v_customer,v_service,1100);
  insert into public.jobs
    (id,order_id,customer_id,service_id,status,pickup_address,pickup_city,pickup_state,
      sender_name,sender_phone,delivery_address,delivery_city,delivery_state,
      recipient_name,recipient_phone)
  values(v_job,v_order,v_customer,v_service,'delivered','Private pickup address','Port Harcourt','Rivers',
    'Sender','08000000002','Provider dropoff address','Port Harcourt','Rivers','Recipient','08000000003');
  if exists(select 1 from public.shared_delivery_place_sources
            where user_id=v_a and source_kind='request_pickup' and source_key=v_request::text) then
    raise exception 'Unpaid delivered job contributed a shared point';
  end if;
  insert into public.customer_payments(job_id,amount,currency,method,status,recorded_by)
    values(v_job,1100,'NGN','online','received',v_staff);
  perform set_config('request.jwt.claim.sub',v_staff::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_staff,'role','authenticated')::text,true);
  update public.jobs set status='closed' where id=v_job;
  if not exists(select 1 from public.shared_delivery_place_sources s
                join public.shared_delivery_places p on p.id=s.place_id
                where s.user_id=v_a and s.source_kind='request_pickup'
                  and s.source_key=v_request::text and p.label='Customer Typed Pickup') then
    raise exception 'Paid completed GPS pickup was not shared';
  end if;
  if exists(select 1 from public.shared_delivery_place_sources
            where user_id=v_a and source_kind='request_dropoff' and source_key=v_request::text) then
    raise exception 'Provider-selected destination was shared';
  end if;

  -- The index has a per-customer cap; reaching it must not block a private
  -- saved-address edit or leave an out-of-date public location behind.
  for v_i in 1..19 loop
    update public.customer_parcel_destinations
      set shared_label='Unique Point '||v_i, latitude=4.883+v_i*0.0002
      where user_id=v_b and slot=2;
  end loop;
  update public.customer_parcel_destinations
    set shared_label='Unique Point 20', latitude=4.889
    where user_id=v_b and slot=2;
  if not exists(select 1 from public.customer_parcel_destinations
                where user_id=v_b and slot=2 and shared_label='Unique Point 20') then
    raise exception 'Daily index cap blocked private address edit';
  end if;
  if exists(select 1 from public.shared_delivery_place_sources
            where user_id=v_b and source_kind='saved' and source_key='2') then
    raise exception 'Daily index cap left an obsolete shared point';
  end if;

  perform set_config('request.jwt.claim.sub',v_staff::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_staff,'role','authenticated')::text,true);
  v_denied:=false;
  begin
    perform public.search_shared_delivery_places('divine','Port Harcourt');
  exception when insufficient_privilege then v_denied:=true; end;
  if not v_denied then raise exception 'Partner account searched customer locations'; end if;

  if has_table_privilege('authenticated','public.shared_delivery_places','SELECT')
    or has_table_privilege('authenticated','public.shared_delivery_place_sources','SELECT')
    or has_table_privilege('authenticated','public.shared_delivery_place_publish_limits','SELECT')
    or has_table_privilege('authenticated','public.shared_delivery_place_search_limits','SELECT')
    or has_function_privilege('authenticated',
      'public.upsert_shared_delivery_place(uuid,text,text,text,text,text,double precision,double precision)','EXECUTE') then
    raise exception 'Shared place storage or internal writer was directly exposed';
  end if;
end $$;

rollback;
