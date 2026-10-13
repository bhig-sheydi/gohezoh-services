begin;
create temporary table marketer_fixture (
  bdo_id uuid, admin_id uuid, marketer_id uuid, customer_user_id uuid,
  application_id uuid, invite_token text, marketer_code text, customer_id uuid
);
grant select on marketer_fixture to authenticated;

do $$
declare
  v_bdo uuid:=gen_random_uuid();
  v_admin uuid:=gen_random_uuid();
  v_marketer uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_application uuid;
  v_token text;
  v_code text;
  v_customer_id uuid;
  v_referral_count bigint;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_bdo,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','marketer-bdo-'||v_bdo||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_bdo,'bdo') on conflict do nothing;
  perform set_config('request.jwt.claim.sub',v_bdo::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_bdo,'role','authenticated')::text,true);
  v_token:=public.create_bdo_marketer_invite('marketer-'||v_marketer||'@example.test');

  -- An invite is bound to the requested email, single-use, and not self-selected via metadata.
  begin
    insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values(gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated','attacker-'||v_marketer||'@example.test','',now(),'{}',
      jsonb_build_object('account_kind','staff','requested_role','marketer','marketer_invite',v_token),now(),now());
    raise exception 'Wrong-email marketer signup was accepted';
  exception when insufficient_privilege then null;
  end;

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_marketer,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','marketer-'||v_marketer||'@example.test','',now(),'{}',
    jsonb_build_object('account_kind','staff','requested_role','marketer','marketer_invite',v_token,'full_name','Market Maker'),now(),now());
  select id into v_application from public.staff_applications where user_id=v_marketer and requested_role='marketer' and status='pending';
  if v_application is null or not exists(select 1 from public.staff_applications where id=v_application and invited_by_bdo_id=v_bdo) then
    raise exception 'Valid marketer invitation did not create a pending application tied to its BDO';
  end if;
  if public.has_role(v_marketer,'marketer') then raise exception 'Marketer got access before Super Admin approval'; end if;

  select user_id into v_admin from public.user_roles where role='admin'
    and user_id in (select id from auth.users where lower(email) in ('admin@gohezohservices.org','info@gohezoservices.org','vevakporgodsanointed@gmail.com'))
    order by user_id limit 1;
  if v_admin is null then raise exception 'An allowlisted Super Admin fixture is required';end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  perform public.review_staff_application(v_application,true,null);
  if not public.has_role(v_marketer,'marketer') or not exists(select 1 from public.bdo_marketers where marketer_user_id=v_marketer and bdo_user_id=v_bdo and active) then
    raise exception 'Super Admin approval did not activate the marketer under the inviting BDO';
  end if;

  perform set_config('request.jwt.claim.sub',v_marketer::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_marketer,'role','authenticated')::text,true);
  v_code:=public.get_my_marketer_referral_code();
  if v_code !~ '^M[A-Z0-9]{11}$' or public.get_my_marketer_referral_code() is distinct from v_code then
    raise exception 'Marketer referral code is invalid or unstable';
  end if;

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_customer,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','marketer-customer-'||v_customer||'@example.test','',now(),'{}',
    jsonb_build_object('account_kind','customer','referral_code',v_code,'full_name','Referred Customer','phone','08000000003'),now(),now());
  update auth.users set raw_user_meta_data=jsonb_set(raw_user_meta_data,'{referral_code}',to_jsonb('INVALID123456'::text)) where id=v_customer;
  perform set_config('request.jwt.claim.sub',v_customer::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer,'role','authenticated')::text,true);
  v_customer_id:=public.ensure_customer_profile();
  if not exists(select 1 from public.customers where id=v_customer_id and referred_by_marketer_id=v_marketer and assigned_bdo_id=v_bdo and referral_code_id is null) then
    raise exception 'Customer signup did not preserve marketer-to-BDO attribution';
  end if;
  perform set_config('request.jwt.claim.sub',v_marketer::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_marketer,'role','authenticated')::text,true);
  v_referral_count:=public.get_my_marketer_referral_count();
  if v_referral_count<>1 then raise exception 'Marketer referral count is incorrect'; end if;
  perform set_config('request.jwt.claim.sub',v_bdo::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_bdo,'role','authenticated')::text,true);
  if not exists(select 1 from public.list_my_bdo_marketer_performance() where marketer_user_id=v_marketer and customer_count=1 and qualifying_transactions=0) then
    raise exception 'BDO downline performance did not report the attributed customer';
  end if;

  insert into marketer_fixture values(v_bdo,v_admin,v_marketer,v_customer,v_application,v_token,v_code,v_customer_id);
end $$;

select set_config('request.jwt.claim.sub',(select customer_user_id::text from marketer_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select customer_user_id from marketer_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare v_customer uuid;v_other_bdo uuid;
begin
  select customer_id,bdo_id into v_customer,v_other_bdo from marketer_fixture;
  begin
    update public.customers set referred_by_marketer_id=v_other_bdo where id=v_customer;
    raise exception 'Customer changed their marketer attribution directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
rollback;
