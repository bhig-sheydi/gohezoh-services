begin;
do $$
declare v_admin uuid;v_outsider uuid:=gen_random_uuid();v_warehouse uuid;v_site uuid;v_result jsonb;
begin
  select id into v_admin from auth.users where lower(email)='admin@gohezohservices.org' limit 1;
  if v_admin is null then
    v_admin:=gen_random_uuid();
    insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
      values(v_admin,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','admin@gohezohservices.org','',now(),'{}','{}',now(),now());
  end if;
  insert into public.user_roles(user_id,role) values(v_admin,'admin') on conflict do nothing;
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values(v_outsider,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','proximity-'||v_outsider||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.warehouses(name,code,address,city,is_active)
    values('Proximity Test Hub','PROXTEST','1 Test Street','Port Harcourt',true) returning id into v_warehouse;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  v_site:=public.configure_proximity_site('Test Hub','hub',null,v_warehouse,4.8156,7.0498,200);
  v_result:=public.verify_proximity(v_site,4.8156,7.0498,15,now());
  if v_result->>'status'<>'in_range' then raise exception 'Accurate nearby position was not in range';end if;
  v_result:=public.verify_proximity(v_site,4.9,7.1,15,now());
  if v_result->>'status'<>'out_of_range' then raise exception 'Distant position was not out of range';end if;
  v_result:=public.verify_proximity(v_site,4.8156,7.0498,250,now());
  if v_result->>'status'<>'uncertain' then raise exception 'Inaccurate position should be uncertain';end if;
  begin
    perform public.verify_proximity(v_site,4.8156,7.0498,15,now()-interval '5 minutes');
    raise exception 'Stale position accepted';
  exception when check_violation then null;end;
  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_outsider,'role','authenticated')::text,true);
  begin
    perform public.verify_proximity(v_site,4.8156,7.0498,15,now());
    raise exception 'Unrelated account checked private proximity site';
  exception when insufficient_privilege then null;end;
  begin
    perform public.configure_proximity_site('Evil Hub','hub',null,v_warehouse,4.8156,7.0498,200);
    raise exception 'Unrelated account configured a hub';
  exception when insufficient_privilege then null;end;
end $$;
rollback;
