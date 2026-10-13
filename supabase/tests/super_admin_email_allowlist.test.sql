begin;
do $$
declare
  v_correct uuid;
  v_promoted uuid;
  v_typo uuid := gen_random_uuid();
begin
  select id into v_correct from auth.users
  where lower(email) = 'info@gohezohservices.org' limit 1;
  if v_correct is null then
    v_correct := gen_random_uuid();
    insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values(v_correct,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','Info@gohezohservices.org','',now(),'{}','{}',now(),now());
  end if;
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_typo,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','Info@gohezoservices.org','',now(),'{}','{}',now(),now());
  select id into v_promoted from auth.users where lower(email)='vevakporgodsanointed@gmail.com' limit 1;
  if v_promoted is null then
    v_promoted := gen_random_uuid();
    insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values(v_promoted,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','vevakporgodsanointed@gmail.com','',now(),'{}','{}',now(),now());
  end if;
  insert into public.user_roles(user_id,role) values(v_correct,'admin'),(v_promoted,'admin'),(v_typo,'admin') on conflict do nothing;
  if not public.has_role(v_correct,'admin') then
    raise exception 'Correct second Super Admin address was denied';
  end if;
  if not public.has_role(v_promoted,'admin') then
    raise exception 'Promoted Super Admin account was denied';
  end if;
  if public.has_role(v_typo,'admin') then
    raise exception 'Misspelled domain was granted Super Admin access';
  end if;
end $$;
rollback;
