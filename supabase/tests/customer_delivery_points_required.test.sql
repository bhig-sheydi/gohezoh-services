begin;
create temporary table coordinate_test_user(id uuid);
grant select on coordinate_test_user to authenticated;

do $$
declare v_user uuid:=gen_random_uuid();
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values(v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',v_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into coordinate_test_user values(v_user);
end $$;

select set_config('request.jwt.claim.sub',(select id::text from coordinate_test_user),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select id from coordinate_test_user),'role','authenticated')::text,true);
set local role authenticated;

do $$
declare v_user uuid:=(select id from coordinate_test_user);
begin
  begin
    insert into public.customer_parcel_destinations(user_id,slot,label,address,city,state)
      values(v_user,1,'Work','Typed address','Lagos','Lagos');
    raise exception 'Unpinned saved address was accepted';
  exception when insufficient_privilege then null; end;

  insert into public.customer_parcel_destinations(user_id,slot,label,address,city,state,latitude,longitude,location_source)
    values(v_user,1,'Work','Mapped address','Lagos','Lagos',6.45,3.4,'search');
  if not exists(select 1 from public.customer_parcel_destinations where user_id=v_user and slot=1 and latitude=6.45 and longitude=3.4) then
    raise exception 'Mapped saved address was not stored';
  end if;
end $$;
rollback;
