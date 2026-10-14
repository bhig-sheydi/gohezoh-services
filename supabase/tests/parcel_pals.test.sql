begin;
create temporary table parcel_pal_fixture (
  first_user uuid, second_user uuid, first_code text, second_code text, second_customer uuid
);
grant select on parcel_pal_fixture to authenticated;

do $$
declare
  v_first uuid:=gen_random_uuid();
  v_second uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_first_code text;
  v_second_code text;
  v_search jsonb;
  v_contacts jsonb;
begin
  insert into auth.users(id,instance_id,aud,role,email,phone,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_first,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','parcel-pal-first-'||v_first||'@example.test','08000000001','',now(),'{}',jsonb_build_object('full_name','First User','phone','08000000001'),now(),now()),
    (v_second,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','parcel-pal-second-'||v_second||'@example.test','08012345678','',now(),'{}',jsonb_build_object('full_name','Protected Name','phone','08012345678'),now(),now());
  update public.profiles set avatar_path=v_first::text||'/avatar.png' where user_id=v_first;
  select code into v_first_code from public.parcel_pal_codes where user_id=v_first;
  select code into v_second_code from public.parcel_pal_codes where user_id=v_second;
  if v_first_code !~ '^[0-9]{6}$' or v_second_code !~ '^[0-9]{6}$' then raise exception 'Signup did not assign six-digit Parcel Pal numbers'; end if;
  if v_first_code=v_second_code then raise exception 'Parcel Pal numbers must be unique'; end if;
  insert into public.customers(id,company_name,customer_type,contact_person,email,phone,address,city,state,created_by)
    values(v_customer,'Protected Customer','individual','Protected Name','protected-customer@example.test','08012345678','12 Private Road','Lagos','Lagos',v_second);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_second);

  perform set_config('request.jwt.claim.sub',v_first::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_first,'role','authenticated')::text,true);
  if public.get_my_parcel_pal_code() is distinct from v_first_code then raise exception 'A user must retain the same Parcel Pal number'; end if;
  v_search:=public.search_parcel_pals(v_second_code);
  if v_search->>'found'<>'true' or v_search->>'status'<>'none' then raise exception 'Expected a privacy-safe Parcel Pal search result'; end if;
  if v_search ? 'full_name' or v_search ? 'phone' or v_search ? 'address' or v_search ? 'user_id' then raise exception 'Search exposed private user information'; end if;
  perform public.send_parcel_pal_request(v_second_code);
  v_contacts:=public.list_my_parcel_pals();
  if jsonb_array_length(v_contacts)<>0 then raise exception 'Unaccepted request exposed contact details'; end if;

  perform set_config('request.jwt.claim.sub',v_second::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_second,'role','authenticated')::text,true);
  if jsonb_array_length(public.list_my_parcel_pals())<>0 then raise exception 'Incoming request exposed contact details before acceptance'; end if;
  if not exists(select 1 from public.parcel_pal_connections where requested_by=v_first and status='pending') then raise exception 'Request was not stored as pending'; end if;
  if not exists(select 1 from jsonb_array_elements(public.list_parcel_pal_requests()) r where r->>'code'=v_first_code and r->>'direction'='received' and r->>'full_name'='First User' and r->>'avatar_path'=v_first::text||'/avatar.png') then raise exception 'Incoming request did not identify its sender'; end if;
  if public.can_read_parcel_pal_photo_path(v_first::text||'/avatar.png') is distinct from true then raise exception 'Incoming requester photo is not readable by the recipient'; end if;
  if public.can_read_parcel_pal_photo_path(gen_random_uuid()::text||'/avatar.png') is distinct from false then raise exception 'Incoming requester photo policy exposed an unrelated profile'; end if;
  if public.respond_to_parcel_pal_request(v_first_code,true)<>'accepted' then raise exception 'Recipient could not accept the request'; end if;
  v_contacts:=public.list_my_parcel_pals();
  if not exists(select 1 from jsonb_array_elements(v_contacts) c where c->>'code'=v_first_code) then raise exception 'Accepted Parcel Pal was not listed'; end if;

  -- A customer account that gains a partner role must lose the customer-only Parcel Pal ID and photo path.
  insert into public.user_roles(user_id,role) values(v_second,'partner') on conflict do nothing;
  if exists(select 1 from public.parcel_pal_codes where user_id=v_second) then raise exception 'Non-customer role retained a Parcel Pal number'; end if;
  if (select avatar_path from public.profiles where user_id=v_second) is not null then raise exception 'Non-customer role retained a Parcel Pal photo'; end if;
  begin
    perform public.get_my_parcel_pal_code();
    raise exception 'Non-customer role could generate a Parcel Pal number';
  exception when insufficient_privilege then null; end;

  insert into parcel_pal_fixture values(v_first,v_second,v_first_code,v_second_code,v_customer);
end $$;

select set_config('request.jwt.claim.sub',(select first_user::text from parcel_pal_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select first_user from parcel_pal_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare v_second uuid; v_code text;
begin
  select second_user,second_code into v_second,v_code from parcel_pal_fixture;
  if (select count(*) from public.profiles where user_id=v_second)<>0 then raise exception 'Direct profile access bypassed Parcel Pal acceptance'; end if;
  if (select count(*) from public.customers where id=(select second_customer from parcel_pal_fixture))<>0 then raise exception 'Direct address access bypassed customer privacy'; end if;
  begin
    perform 1 from public.parcel_pal_codes where user_id=v_second;
    raise exception 'Users can enumerate private Parcel Pal code records';
  exception when insufficient_privilege then null; end;
  if not exists(select 1 from jsonb_array_elements(public.list_my_parcel_pals()) c where c->>'code'=v_code and c->>'full_name'='Protected Name' and c->>'phone'='08012345678' and c->>'address'='12 Private Road') then raise exception 'Accepted connection did not expose the approved contact details'; end if;
end $$;
reset role;
rollback;\n