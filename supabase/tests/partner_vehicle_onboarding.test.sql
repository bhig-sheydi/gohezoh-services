begin;
do $$
declare
  u uuid:=gen_random_uuid(); other_user uuid:=gen_random_uuid(); a uuid; p uuid; v uuid; admin_id uuid;
  prefix text; papers text; licence text; doc text; denied boolean;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',u||'@example.test','',now(),'{}',
    '{"account_kind":"staff","requested_role":"partner","organization_name":"Fleet Test Company"}',now(),now());
  select id into a from public.staff_applications where user_id=u and requested_role='partner';
  prefix:=u||'/'||a||'/'; doc:=prefix||'company.pdf'; papers:=prefix||'vehicle.pdf'; licence:=prefix||'licence.pdf';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values
    ('partner-verification',doc,u::text,'{"mimetype":"application/pdf","size":100}'),
    ('partner-vehicles',papers,u::text,'{"mimetype":"application/pdf","size":100}'),
    ('partner-vehicles',licence,u::text,'{"mimetype":"application/pdf","size":100}');
  perform set_config('request.jwt.claim.sub',u::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
  perform public.submit_partner_document(a,'cac',doc);
  denied:=false;
  begin perform public.register_partner_vehicle(a,'motorcycle','TEST-101','Wrong Company',papers,'Test Driver','12345678901',licence,'08:00','18:00');
  exception when check_violation then denied:=true; end;
  if not denied then raise exception 'Wrong company accepted'; end if;
  denied:=false;
  begin perform public.register_partner_vehicle(a,'motorcycle','TEST-101','Fleet Test Company',papers,'Test Driver','123',licence,'08:00','18:00');
  exception when check_violation then denied:=true; end;
  if not denied then raise exception 'Invalid NIN accepted'; end if;
  denied:=false;
  begin perform public.register_partner_vehicle(a,'motorcycle','TEST-101','Fleet Test Company',papers,'Test Driver','12345678901',null,'08:00','18:00');
  exception when check_violation then denied:=true; end;
  if not denied then raise exception 'Missing licence accepted'; end if;

  select ur.user_id into admin_id from public.user_roles ur where ur.role='admin' and public.has_role(ur.user_id,'admin') limit 1;
  if admin_id is null then raise exception 'Super Admin fixture is required'; end if;
  insert into public.logistics_partners(partner_name,contact_person,phone,base_city,base_state,partner_type,status) values('Fleet Test Company','Test Contact','08000000000','Umuahia','Abia','logistics','active') returning id into p;
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  denied:=false;
  begin perform public.review_staff_application(a,true,p); exception when check_violation then denied:=true; end;
  if not denied or exists(select 1 from public.user_roles where user_id=u and role='partner') then raise exception 'Approval without vehicle granted access'; end if;

  perform set_config('request.jwt.claim.sub',u::text,true);
  v:=public.register_partner_vehicle(a,'motorcycle','TEST-101','Fleet Test Company',papers,'Test Driver','12345678901',licence,'20:00','06:00');
  if v is null then raise exception 'Valid registration failed'; end if;
  denied:=false;
  begin perform public.register_partner_vehicle(a,'motorcycle','TEST-101','Fleet Test Company',papers,'Test Driver','12345678901',licence,'08:00','18:00');
  exception when unique_violation then denied:=true; end;
  if not denied then raise exception 'Duplicate plate accepted'; end if;
  perform set_config('request.jwt.claim.sub',other_user::text,true);
  denied:=false;
  begin perform public.remove_pending_partner_vehicle(v); exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'Another user removed vehicle'; end if;
  execute 'set local role authenticated';
  if exists(select 1 from public.partner_application_vehicles where id=v) then raise exception 'Other user can read driver NIN'; end if;
  if exists(select 1 from storage.objects where bucket_id='partner-vehicles' and name=papers) then raise exception 'Other user can read vehicle papers'; end if;
  execute 'reset role';

  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  perform public.review_staff_application(a,true,null);
  select partner_id into p from public.partner_application_vehicles where id=v;
  if p is null or not exists(select 1 from public.logistics_partners where id=p and partner_name='Fleet Test Company') then raise exception 'Company approval still requires manual selection'; end if;
  if not exists(select 1 from public.partner_application_vehicles where id=v and partner_id=p) then raise exception 'Approved vehicle not linked to company'; end if;
  if public.company_dispatch_close_at(p,'2026-10-22 21:00:00+00'::timestamptz)
      <> '2026-10-23 05:00:00+00'::timestamptz then
    raise exception 'Overnight registered vehicle closing time was mapped to the wrong day'; end if;
  if not public.company_dispatch_route_fits(p,100,'2026-10-22 21:00:00+00'::timestamptz)
    or public.company_dispatch_route_fits(p,480,'2026-10-22 21:00:00+00'::timestamptz) then
    raise exception 'Overnight closing buffer did not gate the route'; end if;
  perform set_config('request.jwt.claim.sub',u::text,true);
  denied:=false;
  begin perform public.remove_pending_partner_vehicle(v); exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'Approved evidence can be deleted'; end if;
end $$;
rollback;
