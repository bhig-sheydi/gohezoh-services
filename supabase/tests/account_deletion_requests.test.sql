begin;
do $$
declare u uuid:=gen_random_uuid(); other_user uuid:=gen_random_uuid(); created timestamptz; denied boolean:=false;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',u||'@example.test','',now(),'{}','{}',now(),now());
  perform set_config('request.jwt.claim.sub',u::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
  created:=public.request_account_deletion();
  if created is null or not exists(select 1 from public.account_deletion_requests where user_id=u) then
    raise exception 'Account deletion request was not saved';
  end if;
  perform set_config('request.jwt.claim.sub',other_user::text,true);
  execute 'set local role authenticated';
  if exists(select 1 from public.account_deletion_requests where user_id=u) then
    raise exception 'Another user can read deletion request';
  end if;
  begin perform public.list_account_deletion_requests(); exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'Another user can list all deletion requests'; end if;
  execute 'reset role';
end $$;
rollback;
