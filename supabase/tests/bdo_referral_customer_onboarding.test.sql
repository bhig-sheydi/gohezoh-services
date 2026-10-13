begin;
create temporary table referral_fixture (
  bdo_id uuid, other_bdo_id uuid, customer_user_id uuid, other_customer_user_id uuid,
  customer_id uuid, referral_code text
);
grant select on referral_fixture to authenticated;

do $$
declare
  v_bdo uuid := gen_random_uuid();
  v_other_bdo uuid := gen_random_uuid();
  v_customer_user uuid := gen_random_uuid();
  v_other_customer uuid := gen_random_uuid();
  v_customer uuid;
  v_retry uuid;
  v_code text;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_bdo,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','referral-bdo-'||v_bdo||'@example.test','',now(),'{}','{}',now(),now()),
    (v_other_bdo,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','referral-other-bdo-'||v_other_bdo||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_bdo,'bdo'),(v_other_bdo,'bdo') on conflict do nothing;

  perform set_config('request.jwt.claim.sub',v_bdo::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_bdo,'role','authenticated')::text,true);
  v_code := public.get_my_bdo_referral_code();
  if v_code !~ '^[A-Z0-9]{8,16}$' then raise exception 'BDO referral code has invalid format'; end if;
  if public.get_my_bdo_referral_code() is distinct from v_code then raise exception 'BDO referral code was not stable'; end if;

  perform set_config('request.jwt.claim.sub',v_other_bdo::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_other_bdo,'role','authenticated')::text,true);
  if public.get_my_bdo_referral_code() = v_code then raise exception 'Two BDOs received the same referral code'; end if;

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','referral-customer-'||v_customer_user||'@example.test','',now(),'{}',jsonb_build_object('account_kind','customer','referral_code',v_code,'full_name','Referred Customer','phone','08000000001'),now(),now()),
    (v_other_customer,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','referral-customer-'||v_other_customer||'@example.test','',now(),'{}',jsonb_build_object('account_kind','customer','referral_code','INVALID000000','full_name','Unattributed Customer','phone','08000000002'),now(),now());
  -- Changing signup metadata later must not redirect or introduce referral credit.
  update auth.users set raw_user_meta_data=jsonb_set(raw_user_meta_data,'{referral_code}',to_jsonb(public.get_my_bdo_referral_code())) where id=v_customer_user;
  update auth.users set raw_user_meta_data=jsonb_set(raw_user_meta_data,'{referral_code}',to_jsonb(v_code)) where id=v_other_customer;

  perform set_config('request.jwt.claim.sub',v_customer_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
  v_customer := public.ensure_customer_profile();
  v_retry := public.ensure_customer_profile();
  if v_customer is null or v_retry is distinct from v_customer then raise exception 'Customer onboarding retry created a duplicate profile'; end if;
  if not exists (
    select 1 from public.customers c
    join public.bdo_referral_codes rc on rc.id=c.referral_code_id
    where c.id=v_customer and c.assigned_bdo_id=v_bdo and rc.code=v_code
  ) then raise exception 'Customer referral was not linked to the referring BDO'; end if;
  if (select count(*) from public.customer_users where user_id=v_customer_user) <> 1 then raise exception 'Customer signup created duplicate user links'; end if;

  perform set_config('request.jwt.claim.sub',v_other_customer::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_other_customer,'role','authenticated')::text,true);
  v_retry := public.ensure_customer_profile();
  if not exists(select 1 from public.customers where id=v_retry and assigned_bdo_id is null and referral_code_id is null) then
    raise exception 'Invalid referral code received acquisition credit';
  end if;

  insert into referral_fixture values(v_bdo,v_other_bdo,v_customer_user,v_other_customer,v_customer,v_code);
end $$;

select set_config('request.jwt.claim.sub',(select customer_user_id::text from referral_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select customer_user_id from referral_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare v_customer uuid; v_other_bdo uuid;
begin
  select customer_id,other_bdo_id into v_customer,v_other_bdo from referral_fixture;
  begin
    update public.customers set assigned_bdo_id=v_other_bdo where id=v_customer;
    raise exception 'Customer changed their BDO attribution directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

rollback;
