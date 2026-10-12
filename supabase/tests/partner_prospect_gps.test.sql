begin;
do $$
declare
  v_user uuid := gen_random_uuid();
  v_valid uuid := gen_random_uuid();
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'gps-bdo-'||v_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_user,'bdo');
  insert into public.partner_prospects(partner_name,contact_person,phone,assigned_bdo_id,created_by,latitude,longitude,location_accuracy_metres,location_captured_at)
  values('GPS Prospect','GPS Contact','08000000000',v_user,v_user,5.5600,7.0600,15,now()) returning id into v_valid;
  if not exists(select 1 from public.partner_prospects where id=v_valid and latitude=5.5600 and longitude=7.0600) then
    raise exception 'Captured coordinates were not stored';
  end if;
  begin
    insert into public.partner_prospects(partner_name,contact_person,phone,assigned_bdo_id,created_by,latitude,longitude,location_accuracy_metres,location_captured_at)
    values('Invalid GPS Prospect','GPS Contact','08000000001',v_user,v_user,95,7.0600,15,now());
    raise exception 'Out-of-range GPS coordinate was accepted';
  exception when check_violation then null;
  end;
end $$;
rollback;
