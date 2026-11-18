begin;
do $$
declare v_user uuid:=gen_random_uuid();v_reference text;v_partner uuid;v_rider uuid;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    v_user||'@example.test','',now(),'{}',
    '{"account_kind":"independent_rider","full_name":"Test Independent Rider"}',now(),now());
  update public.profiles set full_name='Test Independent Rider' where user_id=v_user;
  perform set_config('request.jwt.claim.sub',v_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_user,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_reference:=public.begin_independent_rider_verification('+2348010000123');
  if v_reference not like 'KWP-RIDER-%' then raise exception 'Verification reference missing'; end if;
  if exists(select 1 from public.company_riders where independent_user_id=v_user) then
    raise exception 'Rider received access before KYC'; end if;
  begin
    perform public.register_independent_rider(gen_random_uuid(),'+2348010000123');
    raise exception 'Old self-approval RPC remains callable';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  perform public.finish_independent_rider_verification(v_reference,false,'Failed check');
  if exists(select 1 from public.company_riders where independent_user_id=v_user) then
    raise exception 'Failed KYC created rider'; end if;
  execute 'set local role authenticated';
  v_reference:=public.begin_independent_rider_verification('+2348010000123');
  execute 'reset role';
  perform public.finish_independent_rider_verification(v_reference,true,null);
  select r.id,r.partner_id into v_rider,v_partner from public.company_riders r
    where r.independent_user_id=v_user and r.status='approved';
  if v_rider is null or not exists(select 1 from public.logistics_partners p
    where p.id=v_partner and p.partner_type='independent_rider' and p.status='active') then
    raise exception 'Verified rider did not become their own partner'; end if;
  if public.company_dispatch_close_at(v_partner,now()) is null then
    raise exception 'Independent rider missing dispatch hours'; end if;
  perform public.finish_independent_rider_verification(v_reference,true,null);
  if (select count(*) from public.company_riders where independent_user_id=v_user)<>1 then
    raise exception 'Duplicate webhook created another rider'; end if;
end $$;
rollback;
