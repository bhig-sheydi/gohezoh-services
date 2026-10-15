begin;
do $$
declare
  v_bdo uuid:=gen_random_uuid();v_admin uuid;v_partner_user uuid:=gen_random_uuid();
  v_prospect uuid;v_application uuid;v_token text;v_partner_id uuid;v_path text;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_bdo,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','bdo-partner-'||v_bdo||'@example.test','',now(),'{}',
    '{"account_kind":"staff","requested_role":"bdo","full_name":"Partner Recruiter"}',now(),now());
  insert into public.user_roles(user_id,role) values(v_bdo,'bdo') on conflict do nothing;
  perform set_config('request.jwt.claim.sub',v_bdo::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_bdo,'role','authenticated')::text,true);
  insert into public.partner_prospects(partner_name,contact_person,phone,email,city,state,service_type,assigned_bdo_id,created_by)
    values('Referred Courier','Partner Contact','08000000001',null,'Umuahia','Abia','courier',v_bdo,v_bdo) returning id into v_prospect;
  v_token:=public.create_partner_prospect_invite(v_prospect);
  if v_token is null then raise exception 'BDO partner signup link was not generated';end if;

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_partner_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','referred-partner-'||v_partner_user||'@example.test','',now(),'{}',
    jsonb_build_object('account_kind','staff','requested_role','partner','partner_prospect_invite',v_token,'full_name','Partner Contact'),now(),now());
  select id into v_application from public.staff_applications where user_id=v_partner_user and requested_role='partner' and status='pending';
  if v_application is null or not exists(select 1 from public.staff_applications sa join public.partner_prospects p on p.id=sa.partner_prospect_id
    where sa.id=v_application and sa.partner_prospect_id=v_prospect and sa.partner_prospect_invite_id is not null and p.assigned_bdo_id=v_bdo) then
    raise exception 'Partner application did not preserve BDO prospect attribution';
  end if;
  if public.has_role(v_partner_user,'partner') then raise exception 'Partner access was granted before document review';end if;

  v_path:=v_partner_user::text||'/'||v_application::text||'/cac.pdf';
  insert into storage.objects(bucket_id,name,owner_id,metadata)
    values('partner-verification',v_path,v_partner_user::text,'{"mimetype":"application/pdf","size":100}'::jsonb);
  perform set_config('request.jwt.claim.sub',v_partner_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_partner_user,'role','authenticated')::text,true);
  perform public.submit_partner_document(v_application,'cac',v_path);
  insert into storage.objects(bucket_id,name,owner_id,metadata) values
    ('partner-vehicles',v_path||'-vehicle',v_partner_user::text,'{"mimetype":"application/pdf","size":100}'),
    ('partner-vehicles',v_path||'-licence',v_partner_user::text,'{"mimetype":"application/pdf","size":100}');
  perform public.register_partner_vehicle(v_application,'van','REF-101','Referred Courier',v_path||'-vehicle','Referral Driver','12345678901',v_path||'-licence','08:00','18:00');

  select id into v_admin from auth.users where lower(email)='vevakporgodsanointed@gmail.com' limit 1;
  if v_admin is null then raise exception 'Promoted Super Admin fixture is required';end if;
  insert into public.user_roles(user_id,role) values(v_admin,'admin') on conflict do nothing;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  perform public.review_staff_application(v_application,true,null);
  select converted_partner_id into v_partner_id from public.partner_prospects where id=v_prospect;
  if v_partner_id is null or not exists(select 1 from public.logistics_partners where id=v_partner_id and status='active') then
    raise exception 'Super Admin approval did not activate the referred partner';
  end if;
  if not public.has_role(v_partner_user,'partner') or not exists(select 1 from public.partner_users where partner_id=v_partner_id and user_id=v_partner_user) then
    raise exception 'Approved referred partner was not linked to the company';
  end if;
  if not exists(select 1 from public.list_staff_applications() where id=v_application and partner_prospect_id=v_prospect and invited_partner_id=v_partner_id) then
    raise exception 'Super Admin review list did not retain the partner referral relationship';
  end if;
  if not exists(select 1 from public.notifications where user_id=v_bdo and event_type='bdo_partner_application_review'
    and payload->>'partner_prospect_id'=v_prospect::text and payload->>'application_status'='approved') then
    raise exception 'BDO did not receive an in-app partner application decision';
  end if;
  perform set_config('request.jwt.claim.sub',v_bdo::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_bdo,'role','authenticated')::text,true);
  if not exists(select 1 from public.list_my_partner_prospect_progress() where partner_prospect_id=v_prospect
    and application_status='approved' and email_confirmed and verification_document_submitted) then
    raise exception 'BDO cannot see partner registration, email, and verification progress';
  end if;
end $$;
rollback;
