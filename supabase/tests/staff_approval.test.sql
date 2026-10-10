begin;
create temporary table staff_security_fixture(manager_id uuid);
grant select on staff_security_fixture to authenticated;
do $$
declare
  v_admin uuid;v_manager uuid:=gen_random_uuid();v_staff uuid:=gen_random_uuid();
  v_partner_user uuid:=gen_random_uuid();v_partner uuid:=gen_random_uuid();
  v_application uuid;v_partner_application uuid;v_document_path text;
begin
  select id into v_admin from auth.users where lower(email)='admin@gohezohservices.org' limit 1;
  if v_admin is null then
    v_admin:=gen_random_uuid();
    insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values(v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','admin@gohezohservices.org','',now(),'{}','{}',now(),now());
  end if;
  insert into public.user_roles(user_id,role) values(v_admin,'admin') on conflict do nothing;

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_manager,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','staff-manager-'||v_manager||'@example.test','',now(),'{}','{}',now(),now()),
    (v_staff,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','staff-applicant-'||v_staff||'@example.test','',now(),'{}','{"account_kind":"staff","requested_role":"warehouse","full_name":"Warehouse Applicant"}',now(),now()),
    (v_partner_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','staff-partner-'||v_partner_user||'@example.test','',now(),'{}','{"account_kind":"staff","requested_role":"partner","organization_name":"Test Partner"}',now(),now());
  insert into public.user_roles(user_id,role) values(v_manager,'management') on conflict do nothing;
  insert into staff_security_fixture(manager_id) values(v_manager);
  if exists(select 1 from public.user_roles where user_id=v_staff) then raise exception 'Staff applicant received access before review';end if;
  select id into v_application from public.staff_applications where user_id=v_staff and requested_role='warehouse';
  select id into v_partner_application from public.staff_applications where user_id=v_partner_user and requested_role='partner';
  if v_application is null or v_partner_application is null then raise exception 'Staff signup did not create pending requests';end if;
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
  values(v_partner,'Approval Test Partner','Contact','08000000000','active');

  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  begin
    perform public.review_staff_application(v_application,true);
    raise exception 'Management approved sensitive access';
  exception when insufficient_privilege then null;end;
  if public.partner_document_upload_allowed(v_partner_user::text||'/'||v_partner_application::text||'/test.pdf') then
    raise exception 'Unrelated staff could upload a partner document';
  end if;
  begin
    perform public.revoke_staff_access(v_admin,'warehouse');
    raise exception 'Management revoked access';
  exception when insufficient_privilege then null;end;
  if public.has_role(v_manager,'admin') then raise exception 'Management has Super Admin power';end if;

  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  perform public.review_staff_application(v_application,true);
  if not public.has_role(v_staff,'warehouse') then raise exception 'Approved staff role missing';end if;
  begin
    perform public.review_staff_application(v_partner_application,true,v_partner);
    raise exception 'Partner approved without verification document';
  exception when check_violation then null;end;
  v_document_path:=v_partner_user::text||'/'||v_partner_application::text||'/test.pdf';
  insert into storage.objects(bucket_id,name,owner_id,metadata)
    values('partner-verification',v_document_path,v_partner_user::text,'{"mimetype":"application/pdf","size":100}'::jsonb);
  perform set_config('request.jwt.claim.sub',v_partner_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_partner_user,'role','authenticated')::text,true);
  if not public.partner_document_upload_allowed(v_document_path) then raise exception 'Pending partner could not upload document';end if;
  begin
    perform public.submit_partner_document(v_application,'cac',v_document_path);
    raise exception 'Partner submitted document to another application';
  exception when insufficient_privilege then null;end;
  begin
    perform public.submit_partner_document(v_partner_application,'invalid',v_document_path);
    raise exception 'Invalid document type accepted';
  exception when check_violation then null;end;
  perform public.submit_partner_document(v_partner_application,'cac',v_document_path);
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  perform public.review_staff_application(v_partner_application,true,v_partner);
  perform set_config('request.jwt.claim.sub',v_partner_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_partner_user,'role','authenticated')::text,true);
  if not public.is_partner_user(v_partner) then raise exception 'Approved partner cannot access linked company';end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  perform public.revoke_staff_access(v_staff,'warehouse');
  perform public.revoke_staff_access(v_partner_user,'partner');
  if public.has_role(v_staff,'warehouse') or public.has_role(v_partner_user,'partner') then raise exception 'Revoked roles remain active';end if;
  perform set_config('request.jwt.claim.sub',v_partner_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_partner_user,'role','authenticated')::text,true);
  if public.is_partner_user(v_partner) then raise exception 'Revoked partner still has company access';end if;
  if not exists(select 1 from public.staff_applications where id=v_partner_application and status='revoked') then raise exception 'Revoked application status was not recorded';end if;
  perform public.request_staff_access('partner','Test Partner');
  if not exists(select 1 from public.staff_applications where id=v_partner_application and status='pending') then raise exception 'Revoked applicant could not request review again';end if;
  if exists(select 1 from public.staff_applications where id=v_partner_application and partner_document_path is not null) then raise exception 'Reapplication retained old verification document';end if;
end $$;

select set_config('request.jwt.claim.sub',(select manager_id::text from staff_security_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select manager_id from staff_security_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare v_manager uuid;
begin
  select manager_id into v_manager from staff_security_fixture;
  begin
    insert into public.user_roles(user_id,role) values(v_manager,'admin');
    raise exception 'Management inserted an Admin role directly';
  exception when insufficient_privilege then null;end;
end $$;
reset role;
rollback;
