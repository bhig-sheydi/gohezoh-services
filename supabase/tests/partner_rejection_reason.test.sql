begin;
do $$
declare u uuid:=gen_random_uuid(); a uuid; admin_id uuid; denied boolean;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',u||'@example.test','',now(),'{}',
    '{"account_kind":"staff","requested_role":"partner","organization_name":"Rejection Test"}',now(),now());
  select id into a from public.staff_applications where user_id=u and requested_role='partner';
  select user_id into admin_id from public.user_roles where role='admin' and public.has_role(user_id,'admin') limit 1;
  perform set_config('request.jwt.claim.sub',u::text,true);
  denied:=false;
  begin perform public.review_staff_application(a,false,null,'Owner self review'); exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'Applicant can review their own request'; end if;
  if has_function_privilege('authenticated','public.review_staff_application_internal(uuid,boolean,uuid)','execute') then raise exception 'Legacy review bypass exposed'; end if;
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  denied:=false;
  begin perform public.review_staff_application(a,false,null,' '); exception when check_violation then denied:=true; end;
  if not denied then raise exception 'Blank rejection reason accepted'; end if;
  perform public.review_staff_application(a,false,null,'Vehicle papers do not show the company name.');
  if not exists(select 1 from public.staff_applications where id=a and status='rejected' and rejection_reason='Vehicle papers do not show the company name.') then raise exception 'Rejection reason missing'; end if;
  if not exists(select 1 from public.notifications where user_id=u and event_type='application_rejected' and body='Vehicle papers do not show the company name.') then raise exception 'Applicant not notified'; end if;
  perform set_config('request.jwt.claim.sub',u::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  if not exists(select 1 from public.staff_applications where id=a and rejection_reason is not null) then raise exception 'Applicant cannot read rejection reason'; end if;
  execute 'reset role';
  perform public.request_staff_access('partner','Rejection Test');
  if exists(select 1 from public.staff_applications where id=a and rejection_reason is not null) then raise exception 'Reapplication retained stale rejection'; end if;
end $$;
rollback;
