begin;
do $$
declare
  v_owner uuid:=gen_random_uuid(); v_staff uuid:=gen_random_uuid(); v_partner uuid:=gen_random_uuid(); v_staff_id uuid; v_session uuid:=gen_random_uuid();
  v_count integer; v_alerts integer;
begin
  perform set_config('request.jwt.claim.role','service_role',true);
  perform set_config('request.jwt.claims',jsonb_build_object('role','service_role')::text,true);
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_owner,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','staff-owner-'||v_owner||'@example.test','',now(),'{}','{}',now(),now()),
    (v_staff,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','staff-operator-'||v_staff||'@example.test','',now(),'{}','{"account_kind":"company_operator"}',now(),now());
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
  values(v_partner,'Staff security fixture','Owner','+2348000000901','active');
  insert into public.user_roles(user_id,role) values(v_owner,'partner'),(v_staff,'partner');
  insert into public.partner_users(partner_id,user_id,membership_role) values(v_partner,v_owner,'manager'),(v_partner,v_staff,'dispatcher');
  insert into public.company_operations_staff(partner_id,user_id,full_name,can_bid,can_manage_riders,can_withdraw)
  values(v_partner,v_staff,'Test Dispatcher',true,false,false) returning id into v_staff_id;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner,'role','authenticated')::text,true);
  if not public.company_staff_allowed(v_partner,'bid') or not public.company_staff_allowed(v_partner,'withdraw') then
    raise exception 'Owner must retain all company permissions'; end if;
  perform set_config('request.jwt.claim.sub',v_staff::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_staff,'role','authenticated')::text,true);
  if public.company_staff_allowed(v_partner,'bid') then
    raise exception 'Staff must not act without a bound live session'; end if;
  if public.is_partner_user(v_partner) then
    raise exception 'Staff must not inherit broad owner access'; end if;
  insert into auth.sessions(id,user_id,created_at,updated_at) values(v_session,v_staff,now()-interval '1 minute',now()-interval '1 minute');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_staff,'role','authenticated','session_id',v_session)::text,true);
  if not public.company_staff_allowed(v_partner,'bid') or public.company_staff_allowed(v_partner,'withdraw') then
    raise exception 'Bound staff session exceeded assigned permissions'; end if;
  delete from public.user_roles where user_id=v_staff and role='partner';
  if public.company_staff_allowed(v_partner,'bid') or exists(select 1 from public.my_company_operations_staff()) then
    raise exception 'Revoked partner role retained company staff access'; end if;
  insert into public.user_roles(user_id,role) values(v_staff,'partner');
  begin
    update public.company_operations_staff set can_withdraw=true where id=v_staff_id;
    raise exception 'Staff managed to grant themselves withdrawal access';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claim.role','service_role',true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_staff,'role','service_role')::text,true);
  insert into public.company_operations_staff_devices(staff_id,kind,public_key,label)
    values(v_staff_id,'phone','{"kty":"EC"}','Phone'),(v_staff_id,'desktop','{"kty":"EC"}','Laptop');
  begin
    insert into public.company_operations_staff_devices(staff_id,kind,public_key,label)
      values(v_staff_id,'phone','{"kty":"EC"}','Second phone');
    raise exception 'A second phone was accepted';
  exception when unique_violation then null;
  end;
  update public.company_operations_staff set session_not_before=now() where id=v_staff_id;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_staff,'role','authenticated','session_id',v_session)::text,true);
  if public.company_staff_allowed(v_partner,'bid') then
    raise exception 'Old session retained access after permissions changed'; end if;
  perform set_config('request.jwt.claim.role','service_role',true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_staff,'role','service_role')::text,true);
  if not public.company_staff_actor_permission(v_partner,v_staff,'bid') or public.company_staff_actor_permission(v_partner,v_staff,'withdraw') then
    raise exception 'Service-side staff permission check is incorrect'; end if;
  for v_count in 1..3 loop
    if public.record_company_staff_auth_failure(v_staff_id,false)<>v_count then
      raise exception 'Wrong failed-attempt count'; end if;
  end loop;
  if public.record_company_staff_auth_failure(v_staff_id,false)<>-1 then
    raise exception 'Fourth wrong password must start a temporary cooldown'; end if;
  if not exists(select 1 from public.company_operations_staff where id=v_staff_id
    and password_retry_after>now() and password_revoked_at is null) then
    raise exception 'Wrong passwords permanently revoked staff access'; end if;
  update public.company_operations_staff set password_retry_after=null,failed_attempts=0 where id=v_staff_id;
  for v_count in 1..4 loop
    if public.record_company_staff_auth_failure(v_staff_id,true)<>v_count then
      raise exception 'Wrong device-attempt count'; end if;
  end loop;
  if not exists(select 1 from public.company_operations_staff where id=v_staff_id and password_revoked_at is not null) then
    raise exception 'Fourth unauthorized device attempt did not revoke password'; end if;
  select count(*) into v_alerts from public.company_operations_staff_alerts where staff_id=v_staff_id;
  if v_alerts<>1 then raise exception 'Owner alert must be recorded once'; end if;
  if public.company_staff_actor_permission(v_partner,v_staff,'bid') then
    raise exception 'Revoked staff retained permission'; end if;
end $$;
rollback;
