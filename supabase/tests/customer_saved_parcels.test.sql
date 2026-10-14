begin;
create temporary table saved_parcel_fixture(user_id uuid primary key);
grant select on saved_parcel_fixture to authenticated;

do $$
declare v_user uuid:=gen_random_uuid();
begin
  insert into auth.users(id,instance_id,aud,role,email,phone,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','saved-parcel-'||v_user||'@example.test','08000000009','',now(),'{}','{}',now(),now());
  insert into saved_parcel_fixture values(v_user);
  perform set_config('request.jwt.claim.sub',v_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_user,'role','authenticated')::text,true);
  insert into public.customer_saved_parcels(user_id,item_name,description,declared_value,price,length_cm,width_cm,height_cm,weight_kg,photo_path)
  values(v_user,'Sample parcel','Goods inside',10000,8500,99,60,70.5,9.9,v_user::text||'/sample.jpg');
  begin
    insert into public.customer_saved_parcels(user_id,item_name,description,declared_value,price,length_cm,width_cm,height_cm,weight_kg,photo_path)
    values(v_user,'Oversized parcel','Too tall',10000,8500,99,60,70.6,9.9,v_user::text||'/large.jpg');
    raise exception 'Oversized parcel passed database bounds';
  exception when check_violation then null; end;
  if (select count(*) from public.customer_saved_parcels where user_id=v_user)<>1 then raise exception 'Customer could not read their saved parcel'; end if;
end $$;

select set_config('request.jwt.claim.sub',(select user_id::text from saved_parcel_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select user_id from saved_parcel_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
begin
  if (select count(*) from public.customer_saved_parcels)<>1 then raise exception 'Authenticated customer cannot access their saved parcel'; end if;
end $$;
reset role;

do $$
declare v_user uuid:=(select user_id from saved_parcel_fixture);
begin
  insert into public.user_roles(user_id,role) values(v_user,'partner') on conflict do nothing;
end $$;
set local role authenticated;
do $$
begin
  if (select count(*) from public.customer_saved_parcels)<>0 then raise exception 'A partner account can access customer saved parcels'; end if;
end $$;
reset role;
rollback;
