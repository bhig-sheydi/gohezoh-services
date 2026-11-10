begin;
do $$
declare
  v_rider uuid:=gen_random_uuid();
  v_foreign uuid:=gen_random_uuid();
  v_other uuid:=gen_random_uuid();
  v_customer_user uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_partner uuid:=gen_random_uuid();
  v_roster uuid;
  v_foreign_roster uuid;
  v_session uuid:=gen_random_uuid();
  v_foreign_session uuid:=gen_random_uuid();
  v_service uuid;
  v_request uuid:=gen_random_uuid();
  v_order uuid:=gen_random_uuid();
  v_job uuid:=gen_random_uuid();
  v_snapshot jsonb;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_rider,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'snapshot-rider-'||v_rider||'@example.test','',now(),'{}','{"account_kind":"company_rider"}',now(),now()),
    (v_foreign,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'snapshot-foreign-'||v_foreign||'@example.test','',now(),'{}','{"account_kind":"company_rider"}',now(),now()),
    (v_other,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'snapshot-other-'||v_other||'@example.test','',now(),'{}','{}',now(),now()),
    (v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'snapshot-customer-'||v_customer_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
    values(v_partner,'Snapshot fixture','Owner','08000000191','active');
  insert into public.user_roles(user_id,role) values(v_rider,'rider'),(v_foreign,'rider');
  insert into public.partner_users(partner_id,user_id,membership_role)
    values(v_partner,v_rider,'rider'),(v_partner,v_foreign,'rider');
  insert into public.company_riders(partner_id,full_name,nin,licence_document_path,status)
    values(v_partner,'Snapshot Rider',lpad((floor(random()*99999999999))::bigint::text,11,'0'),
      v_rider||'/licence.pdf','approved') returning id into v_roster;
  insert into public.rider_credentials(user_id,partner_id,roster_id,rider_name,auth_secret_seed,
    link_hash,password_salt,password_hash,password_fingerprint)
    values(v_rider,v_partner,v_roster,'Snapshot Rider',v_rider||'-seed',v_rider||'-link',
      'salt','hash',v_rider||'-fingerprint');
  insert into public.company_riders(partner_id,full_name,nin,licence_document_path,status)
    values(v_partner,'Foreign Rider',lpad((floor(random()*99999999999))::bigint::text,11,'0'),
      v_foreign||'/licence.pdf','approved') returning id into v_foreign_roster;
  insert into public.rider_credentials(user_id,partner_id,roster_id,rider_name,auth_secret_seed,
    link_hash,password_salt,password_hash,password_fingerprint)
    values(v_foreign,v_partner,v_foreign_roster,'Foreign Rider',v_foreign||'-seed',v_foreign||'-link',
      'salt','hash',v_foreign||'-fingerprint');
  insert into auth.sessions(id,user_id,created_at,updated_at)
    values(v_session,v_rider,now(),now()),(v_foreign_session,v_foreign,now(),now());

  select id into v_service from public.services where code='SRV-0001';
  if v_service is null then raise exception 'Local delivery service fixture missing'; end if;
  insert into public.customers(id,company_name,contact_person,phone,created_by)
    values(v_customer,'Snapshot customer','Sender','08000000192',v_customer_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_customer_user);
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,
    sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_request,v_customer,v_service,v_customer_user,'1 Pickup Road','Lagos','Sender',
      '08000000192','2 Delivery Road','Lagos','Receiver','08000000193');
  insert into public.orders(id,service_request_id,customer_id,service_id,status,customer_price)
    values(v_order,v_request,v_customer,v_service,'confirmed',2500);
  insert into public.jobs(id,order_id,customer_id,service_id,partner_id,assigned_rider_id,status,
    pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,
    recipient_name,recipient_phone)
    values(v_job,v_order,v_customer,v_service,v_partner,v_rider,'partner_assigned',
      '1 Pickup Road','Lagos','Sender','08000000192','2 Delivery Road','Lagos',
      'Receiver','08000000193');
  insert into public.partner_assignments(job_id,partner_id,status)
    values(v_job,v_partner,'accepted');

  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_rider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated',
    'session_id',v_session)::text,true);
  v_snapshot:=public.my_rider_dashboard_snapshot();
  if v_snapshot->>'has_role' is distinct from 'true' or v_snapshot->>'session_active' is distinct from 'true'
    or jsonb_array_length(v_snapshot->'jobs')<>1
    or v_snapshot->'jobs'->0->>'job_id' is distinct from v_job::text
    or v_snapshot->'profile'->0->>'company_name' is distinct from 'Snapshot fixture'
    or jsonb_array_length(v_snapshot->'pickup_locations')<>1
    or v_snapshot->'pickup_locations'->0->>'job_id' is distinct from v_job::text
    or v_snapshot->'delivery_locations'<>'[]'::jsonb
    or v_snapshot->'selected_pickups'<>'[]'::jsonb
    or v_snapshot->'next_stop'<>'[]'::jsonb then
    raise exception 'Active rider snapshot has an unexpected shape: %',v_snapshot;
  end if;

  perform set_config('request.jwt.claim.sub',v_foreign::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_foreign,'role','authenticated',
    'session_id',v_foreign_session)::text,true);
  v_snapshot:=public.my_rider_dashboard_snapshot();
  if v_snapshot->>'session_active' is distinct from 'true'
    or v_snapshot->'jobs'<>'[]'::jsonb
    or v_snapshot->'profile'->0->>'rider_name' is distinct from 'Foreign Rider' then
    raise exception 'Another rider saw assigned job or wrong profile: %',v_snapshot;
  end if;

  insert into public.rider_assignment_responses(job_id,rider_id,partner_id) values(v_job,v_rider,v_partner);
  if not exists(select 1 from public.rider_assignment_responses r
    where r.job_id=v_job and r.rider_id=v_rider and r.accepted_at is null) then
    raise exception 'Assigned rider did not receive a response window';
  end if;
  perform set_config('request.jwt.claim.sub',v_rider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated',
    'session_id',v_session)::text,true);
  if not public.accept_rider_assignment(v_job) then raise exception 'Assigned rider could not accept'; end if;
  if not exists(select 1 from public.rider_assignment_responses r where r.job_id=v_job and r.accepted_at is not null) then
    raise exception 'Rider acceptance was not recorded';
  end if;
  -- A timed-out, unaccepted rider is removed; no unrelated company receives the paid job.
  update public.rider_assignment_responses set accepted_at=null,deadline_at=now()-interval '1 minute'
    where job_id=v_job;
  if public.accept_rider_assignment(v_job) then raise exception 'Expired ride was accepted'; end if;
  perform set_config('request.jwt.claim.role','service_role',true);
  if public.resolve_missed_rider_assignments()<>1 then raise exception 'Missed rider was not resolved'; end if;
  if exists(select 1 from public.jobs where id=v_job and assigned_rider_id is not null) then
    raise exception 'Unanswered ride remained assigned';
  end if;
  perform set_config('request.jwt.claim.role','authenticated',true);

  perform set_config('request.jwt.claim.sub',v_rider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated',
    'session_id',v_session)::text,true);
  delete from public.user_roles where user_id=v_rider and role='rider';
  v_snapshot:=public.my_rider_dashboard_snapshot();
  if v_snapshot->>'has_role' is distinct from 'false' or v_snapshot->'jobs'<>'[]'::jsonb then
    raise exception 'Role removal left assigned job visible: %',v_snapshot;
  end if;
  insert into public.user_roles(user_id,role) values(v_rider,'rider');
  delete from auth.sessions where id=v_session;
  v_snapshot:=public.my_rider_dashboard_snapshot();
  if v_snapshot->>'has_role' is distinct from 'true'
    or v_snapshot->>'session_active' is distinct from 'false'
    or v_snapshot->'jobs'<>'[]'::jsonb then
    raise exception 'Deleted auth session left assigned job visible: %',v_snapshot;
  end if;
  insert into auth.sessions(id,user_id,created_at,updated_at) values(v_session,v_rider,now(),now());

  update public.rider_credentials set revoked_at=now() where user_id=v_rider;
  v_snapshot:=public.my_rider_dashboard_snapshot();
  if v_snapshot->>'has_role'<>'true' or v_snapshot->>'session_active'<>'false'
    or v_snapshot->'profile'<>'[]'::jsonb or v_snapshot->'jobs'<>'[]'::jsonb then
    raise exception 'Revoked rider retained dashboard data: %',v_snapshot;
  end if;

  perform set_config('request.jwt.claim.sub',v_other::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_other,'role','authenticated')::text,true);
  v_snapshot:=public.my_rider_dashboard_snapshot();
  if v_snapshot->>'has_role'<>'false' or v_snapshot->>'session_active'<>'false'
    or v_snapshot->'jobs'<>'[]'::jsonb then
    raise exception 'A non-rider received rider data: %',v_snapshot;
  end if;

  perform set_config('request.jwt.claim.role','anon',true);
  perform set_config('request.jwt.claims','{"role":"anon"}',true);
  begin
    perform public.my_rider_dashboard_snapshot();
    raise exception 'Anonymous caller reached rider snapshot';
  exception when insufficient_privilege then null;
  end;
end $$;
rollback;
