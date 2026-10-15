begin;
do $$
declare
  v_admin uuid:=gen_random_uuid();v_customer_user uuid:=gen_random_uuid();v_partner_user uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();v_partner uuid:=gen_random_uuid();v_service uuid;v_request uuid:=gen_random_uuid();
  v_corridor uuid;v_bid uuid;v_job uuid;v_result jsonb;
begin
  select id into v_service from public.services where code='SRV-0002';
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','bids-admin-'||v_admin||'@example.test','',now(),'{}','{}',now(),now()),
    (v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','bids-customer-'||v_customer_user||'@example.test','',now(),'{}','{}',now(),now()),
    (v_partner_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','bids-partner-'||v_partner_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_admin,'management'),(v_customer_user,'customer'),(v_partner_user,'partner') on conflict do nothing;
  insert into public.customers(id,company_name,contact_person,phone,created_by)
  values(v_customer,'Bid Customer','Bid Customer','+2348010000001',v_customer_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_customer_user);
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
  values(v_partner,'Bid Partner','Bid Partner','+2348010000002','active');
  insert into public.partner_users(partner_id,user_id) values(v_partner,v_partner_user);
  select c.id into v_corridor from public.coverage_corridors c
    join public.coverage_locations o on o.id=c.origin_id
    join public.coverage_locations d on d.id=c.destination_id
    where o.name='Lagos' and d.name='Port Harcourt' and c.service_code='SRV-0002';
  if v_corridor is null then raise exception 'Seed corridor missing'; end if;
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
  values(v_request,v_customer,v_service,v_customer_user,'1 Lagos Road','Lagos','Sender','+2348010000003','2 Port Harcourt Road','Port Harcourt','Recipient','+2348010000004');
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  perform public.set_partner_corridor_coverage(v_partner,v_corridor,true);
  v_result:=public.publish_delivery_request(v_request);
  if (v_result->>'deadline_at')::timestamptz < now()+interval '59 seconds'
     or (v_result->>'deadline_at')::timestamptz > now()+interval '61 seconds' then
    raise exception 'Bid window is not one minute'; end if;
  v_result:=public.publish_delivery_request(v_request);
  if (select count(*) from public.delivery_quote_windows where request_id=v_request)<>1 then raise exception 'Publish retry created second window'; end if;
  begin
    perform public.process_service_request(v_request,'approve',10000);
    raise exception 'Operations bypassed customer quote acceptance';
  exception when check_violation then null; end;
  perform set_config('request.jwt.claim.sub',v_partner_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_partner_user,'role','authenticated')::text,true);
  if (select count(*) from public.list_partner_bid_screen() where request_id=v_request)<>1 then
    raise exception 'Eligible request missing from partner bid screen'; end if;
  v_bid:=public.submit_partner_quote(v_request,7500,24,'Pickup and delivery','No exclusions',true,'No surcharges');
  if v_bid is null then raise exception 'Eligible partner could not bid'; end if;
  begin
    perform public.close_delivery_quote_window(v_request);
    raise exception 'Early closing was allowed';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  update public.delivery_quote_windows
    set published_at=now()-interval '3 hours',deadline_at=now()-interval '1 second'
    where request_id=v_request;
  update public.partner_quotes set submitted_at=now()-interval '2 seconds' where id=v_bid;
  v_result:=public.close_delivery_quote_window(v_request);
  if v_result->>'status'<>'quoted' then raise exception 'Valid bid was not selected'; end if;
  if (select unrounded_price_ngn from public.customer_delivery_quotes where request_id=v_request)<>10000 then
    raise exception 'Cost / 0.75 pricing incorrect'; end if;
  if (select customer_price_ngn from public.customer_delivery_quotes where request_id=v_request) is not null then
    raise exception 'Unapproved rounded customer price was invented'; end if;
  if (select status from public.customer_delivery_quotes where request_id=v_request)<>'pending_price' then
    raise exception 'Unpriced customer quote was sent'; end if;
  begin
    perform public.set_delivery_quote_price(v_request,500,10667,'Attempt before policy',now()+interval '2 days');
    raise exception 'Price was finalized without approved rounding policy';
  exception when object_not_in_prerequisite_state then null; end;
  perform public.configure_delivery_pricing_policy(1,'Approved one-naira rounding for test');
  begin
    perform public.set_delivery_quote_price(v_request,500,5000,'Arbitrary price attempt',now()+interval '2 days');
    raise exception 'Arbitrary customer price bypassed formula';
  exception when check_violation then null; end;
  perform public.set_delivery_quote_price(v_request,500,10667,'Approved final price',now()+interval '2 days');
  if (select unrounded_price_ngn from public.customer_delivery_quotes where request_id=v_request)<>10666.6667 then
    raise exception 'Extra direct cost formula incorrect'; end if;
  perform set_config('request.jwt.claim.sub',v_customer_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
  perform public.accept_customer_delivery_quote(v_request);
  if (select status from public.customer_delivery_quotes where request_id=v_request)<>'accepted' then
    raise exception 'Customer acceptance was not saved'; end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  begin
    perform public.process_service_request(v_request,'approve',10666);
    raise exception 'Operations changed accepted customer price';
  exception when check_violation then null; end;
  v_result:=public.process_service_request(v_request,'approve',10667);
  v_job:=(v_result->>'job_id')::uuid;
  begin
    insert into public.partner_assignments(job_id,partner_id,status,assigned_by)
    values(v_job,v_partner,'assigned',v_admin);
    raise exception 'Partner was awarded before payment or credit';
  exception when check_violation then null; end;
  perform public.approve_delivery_credit(v_job,'Approved test credit terms');
  insert into public.partner_assignments(job_id,partner_id,status,assigned_by)
  values(v_job,v_partner,'assigned',v_admin);
end $$;
rollback;
