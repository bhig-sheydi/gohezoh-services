begin;
do $$
declare v_rider uuid:=gen_random_uuid();v_partner uuid:=gen_random_uuid();
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_rider,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'rider-'||v_rider||'@example.test','',now(),'{}','{"account_kind":"company_rider","full_name":"Test Rider"}',now(),now());
  if exists(select 1 from public.user_roles where user_id=v_rider) then
    raise exception 'Internal rider signup created an unintended customer or staff role';
  end if;
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
    values(v_partner,'Rider Test Company','Test Manager','+2348010000988','active');
  insert into public.user_roles(user_id,role) values(v_rider,'rider');
  insert into public.partner_users(partner_id,user_id,membership_role) values(v_partner,v_rider,'rider');
  insert into public.rider_credentials(user_id,partner_id,rider_name,auth_secret_seed,link_hash,password_salt,password_hash,password_fingerprint)
    values(v_rider,v_partner,'Test Rider','test-seed-'||v_rider,'test-link-'||v_rider,'salt','hash','test-password-'||v_rider);
  perform set_config('request.jwt.claim.sub',v_rider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_rider,'role','authenticated')::text,true);
  if public.is_partner_user(v_partner) then raise exception 'Rider gained company partner powers'; end if;
  if public.rider_session_active() then raise exception 'Rider access worked without a valid session'; end if;
  begin
    perform public.list_my_partner_team();
    raise exception 'Rider could read the company owner workspace';
  exception when insufficient_privilege then null; end;
  begin
    perform public.list_my_rider_jobs();
    raise exception 'Rider could read jobs without a valid session';
  exception when insufficient_privilege then null; end;
  if public.rider_actor_session_active(v_rider,gen_random_uuid()) then
    raise exception 'Unknown rider session was accepted';
  end if;
end $$;
rollback;
