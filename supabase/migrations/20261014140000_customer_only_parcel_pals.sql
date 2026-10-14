-- Parcel Pal numbers and profile photos are customer features only.

create or replace function public.is_customer_parcel_pal_user(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (select 1 from public.user_roles ur where ur.user_id=p_user_id and ur.role='customer')
    and not exists (select 1 from public.user_roles ur where ur.user_id=p_user_id and ur.role<>'customer');
$$;
revoke all on function public.is_customer_parcel_pal_user(uuid) from public,anon;
grant execute on function public.is_customer_parcel_pal_user(uuid) to authenticated;

create or replace function public.ensure_parcel_pal_code(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_code text;
  v_candidate text;
  v_attempt integer;
begin
  if p_user_id is null then raise exception 'A user account is required'; end if;
  if not public.is_customer_parcel_pal_user(p_user_id) then
    raise insufficient_privilege using message='Parcel Pal numbers are only available to customer accounts';
  end if;
  select code into v_code from public.parcel_pal_codes where user_id=p_user_id;
  if v_code is not null then return v_code; end if;

  for v_attempt in 1..100 loop
    v_candidate := lpad(floor(random()*1000000)::integer::text,6,'0');
    insert into public.parcel_pal_codes(code,user_id)
      values(v_candidate,p_user_id) on conflict do nothing returning code into v_code;
    if v_code is not null then return v_code; end if;
    select code into v_code from public.parcel_pal_codes where user_id=p_user_id;
    if v_code is not null then return v_code; end if;
  end loop;
  raise exception 'Could not allocate a unique Parcel Pal number; try again';
end;
$$;

create or replace function public.assign_parcel_pal_code_on_signup()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if public.is_customer_parcel_pal_user(new.id) then
    perform public.ensure_parcel_pal_code(new.id);
  end if;
  return new;
end;
$$;

create or replace function public.sync_customer_parcel_pal_code()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare v_user_id uuid;
begin
  if tg_op='DELETE' then v_user_id:=old.user_id; else v_user_id:=new.user_id; end if;
  if public.is_customer_parcel_pal_user(v_user_id) then
    perform public.ensure_parcel_pal_code(v_user_id);
  else
    delete from public.parcel_pal_codes where user_id=v_user_id;
    update public.profiles set avatar_path=null where user_id=v_user_id;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.sync_customer_parcel_pal_code() from public,anon,authenticated;
drop trigger if exists sync_customer_parcel_pal_code on public.user_roles;
create trigger sync_customer_parcel_pal_code
after insert or update or delete on public.user_roles
for each row execute function public.sync_customer_parcel_pal_code();

-- Existing staff/partner/BDO-only accounts do not retain customer Parcel Pal data.
do $$
declare v_user_id uuid;
begin
  for v_user_id in
    select c.user_id
    from public.parcel_pal_codes c
    where not public.is_customer_parcel_pal_user(c.user_id)
  loop
    delete from public.parcel_pal_codes where user_id=v_user_id;
    update public.profiles set avatar_path=null where user_id=v_user_id;
  end loop;
  for v_user_id in
    select p.user_id from public.profiles p
    where p.avatar_path is not null and not public.is_customer_parcel_pal_user(p.user_id)
  loop
    update public.profiles set avatar_path=null where user_id=v_user_id;
  end loop;
end;
$$;

create or replace function public.get_my_parcel_pal_code()
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
begin
  if auth.uid() is null then raise insufficient_privilege using message='Sign in to view your Parcel Pal number'; end if;
  return public.ensure_parcel_pal_code(auth.uid());
end;
$$;

create or replace function public.set_my_parcel_pal_photo(p_path text)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to update your profile photo'; end if;
  if not exists (select 1 from public.user_roles ur where ur.user_id=v_user and ur.role='customer') then
    raise insufficient_privilege using message='Parcel Pal profile photos are only available to customers';
  end if;
  if coalesce(p_path,'') !~ ('^'||v_user::text||'/[^/]+\.(jpg|jpeg|png|webp)$') then
    raise invalid_parameter_value using message='Choose a valid profile photo';
  end if;
  update public.profiles set avatar_path=p_path where user_id=v_user;
  if not found then raise no_data_found using message='Customer profile is not ready'; end if;
  return p_path;
end;
$$;

revoke all on function public.get_my_parcel_pal_code() from public,anon;
grant execute on function public.get_my_parcel_pal_code() to authenticated;
revoke all on function public.set_my_parcel_pal_photo(text) from public,anon;
grant execute on function public.set_my_parcel_pal_photo(text) to authenticated;

-- Keep direct Storage access limited to standalone customer accounts as well.
drop policy if exists parcel_pal_profile_photos_read_related on storage.objects;
create policy parcel_pal_profile_photos_read_related on storage.objects for select to authenticated
using (bucket_id='profile-photos' and public.is_customer_parcel_pal_user(auth.uid()) and public.can_read_parcel_pal_photo_path(name));
drop policy if exists parcel_pal_profile_photos_insert_own on storage.objects;
create policy parcel_pal_profile_photos_insert_own on storage.objects for insert to authenticated
with check (bucket_id='profile-photos' and public.is_customer_parcel_pal_user(auth.uid()) and (storage.foldername(name))[1]=auth.uid()::text and array_length(storage.foldername(name),1)=1);
drop policy if exists parcel_pal_profile_photos_update_own on storage.objects;
create policy parcel_pal_profile_photos_update_own on storage.objects for update to authenticated
using (bucket_id='profile-photos' and public.is_customer_parcel_pal_user(auth.uid()) and (storage.foldername(name))[1]=auth.uid()::text and array_length(storage.foldername(name),1)=1)
with check (bucket_id='profile-photos' and public.is_customer_parcel_pal_user(auth.uid()) and (storage.foldername(name))[1]=auth.uid()::text and array_length(storage.foldername(name),1)=1);
drop policy if exists parcel_pal_profile_photos_delete_own on storage.objects;
create policy parcel_pal_profile_photos_delete_own on storage.objects for delete to authenticated
using (bucket_id='profile-photos' and public.is_customer_parcel_pal_user(auth.uid()) and (storage.foldername(name))[1]=auth.uid()::text and array_length(storage.foldername(name),1)=1);

create or replace function public.check_parcel_pal_daily_limit(p_action text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare v_user uuid:=auth.uid(); v_limit integer; v_count integer;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to use Parcel Pals'; end if;
  if not public.is_customer_parcel_pal_user(v_user) then raise insufficient_privilege using message='Parcel Pals are only available to customer accounts'; end if;
  v_limit:=case p_action when 'search' then 60 when 'request' then 20 else null end;
  if v_limit is null then raise invalid_parameter_value using message='Invalid Parcel Pal action'; end if;
  insert into public.parcel_pal_daily_limits as limits(user_id,action,usage_date,use_count)
    values(v_user,p_action,(now() at time zone 'utc')::date,1)
    on conflict(user_id,action) do update
      set use_count=case when limits.usage_date=excluded.usage_date then limits.use_count+1 else 1 end,
          usage_date=excluded.usage_date returning use_count into v_count;
  if v_count>v_limit then raise sqlstate 'P4290' using message='Daily Parcel Pal limit reached. Try again tomorrow.'; end if;
end;
$$;

-- A searchable ID can resolve only to another standalone customer account.
create or replace function public.search_parcel_pals(p_code text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_user uuid:=auth.uid(); v_target uuid; v_a uuid; v_b uuid; v_status text; v_requester uuid;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to search Parcel Pals'; end if;
  if coalesce(p_code,'') !~ '^[0-9]{6}$' then raise invalid_parameter_value using message='Enter a six-digit Parcel Pal number'; end if;
  perform public.check_parcel_pal_daily_limit('search');
  select c.user_id into v_target from public.parcel_pal_codes c join auth.users u on u.id=c.user_id
  where c.code=p_code and c.user_id<>v_user and u.email_confirmed_at is not null and public.is_customer_parcel_pal_user(c.user_id);
  if v_target is null then return jsonb_build_object('found',false); end if;
  v_a:=least(v_user,v_target); v_b:=greatest(v_user,v_target);
  select status,requested_by into v_status,v_requester from public.parcel_pal_connections where user_a=v_a and user_b=v_b;
  return jsonb_build_object('found',true,'code',p_code,'status',coalesce(v_status,'none'),
    'direction',case when v_status is null then null when v_status='accepted' then 'connected' when v_requester=v_user then 'sent' else 'received' end);
end;
$$;

create or replace function public.send_parcel_pal_request(p_code text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_user uuid:=auth.uid(); v_target uuid; v_a uuid; v_b uuid; v_status text; v_requester uuid;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to request a Parcel Pal'; end if;
  if coalesce(p_code,'') !~ '^[0-9]{6}$' then raise invalid_parameter_value using message='Enter a six-digit Parcel Pal number'; end if;
  perform public.check_parcel_pal_daily_limit('request');
  select c.user_id into v_target from public.parcel_pal_codes c join auth.users u on u.id=c.user_id
  where c.code=p_code and c.user_id<>v_user and u.email_confirmed_at is not null and public.is_customer_parcel_pal_user(c.user_id);
  if v_target is null then return jsonb_build_object('status','not_found'); end if;
  v_a:=least(v_user,v_target); v_b:=greatest(v_user,v_target);
  insert into public.parcel_pal_connections(user_a,user_b,requested_by,status) values(v_a,v_b,v_user,'pending')
  on conflict(user_a,user_b) do update set requested_by=excluded.requested_by,status='pending',created_at=now(),updated_at=now(),responded_at=null
    where public.parcel_pal_connections.status in ('declined','cancelled');
  select status,requested_by into v_status,v_requester from public.parcel_pal_connections where user_a=v_a and user_b=v_b;
  return jsonb_build_object('status',case when v_status='accepted' then 'accepted' when v_status='pending' and v_requester=v_user then 'pending' when v_status='pending' then 'incoming_request' else v_status end);
end;
$$;

create or replace function public.respond_to_parcel_pal_request(p_code text,p_accept boolean)
returns text language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_user uuid:=auth.uid(); v_target uuid; v_a uuid; v_b uuid; v_status text;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to respond to a Parcel Pal request'; end if;
  if not public.is_customer_parcel_pal_user(v_user) then raise insufficient_privilege using message='Parcel Pals are only available to customer accounts'; end if;
  if coalesce(p_code,'') !~ '^[0-9]{6}$' then raise invalid_parameter_value using message='Enter a six-digit Parcel Pal number'; end if;
  select user_id into v_target from public.parcel_pal_codes where code=p_code and user_id<>v_user and public.is_customer_parcel_pal_user(user_id);
  if v_target is null then raise no_data_found using message='Parcel Pal request not found'; end if;
  v_a:=least(v_user,v_target); v_b:=greatest(v_user,v_target);
  update public.parcel_pal_connections set status=case when p_accept then 'accepted' else 'declined' end,updated_at=now(),responded_at=case when p_accept then now() else null end
  where user_a=v_a and user_b=v_b and status='pending' and requested_by<>v_user returning status into v_status;
  if v_status is null then raise insufficient_privilege using message='There is no incoming Parcel Pal request to respond to'; end if;
  return v_status;
end;
$$;

create or replace function public.list_parcel_pal_requests()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_user uuid:=auth.uid(); v_result jsonb;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to view Parcel Pal requests'; end if;
  if not public.is_customer_parcel_pal_user(v_user) then raise insufficient_privilege using message='Parcel Pals are only available to customer accounts'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('code',c.code,'status',x.status,
    'direction',case when x.requested_by=v_user then 'sent' else 'received' end,
    'full_name',case when x.requested_by<>v_user then p.full_name else null end,
    'avatar_path',case when x.requested_by<>v_user then p.avatar_path else null end,'created_at',x.created_at)
    order by x.created_at desc),'[]'::jsonb) into v_result
  from public.parcel_pal_connections x join public.parcel_pal_codes c on c.user_id=case when x.user_a=v_user then x.user_b else x.user_a end
  left join public.profiles p on p.user_id=x.requested_by
  where v_user in (x.user_a,x.user_b) and x.status='pending' and public.is_customer_parcel_pal_user(c.user_id);
  return v_result;
end;
$$;

create or replace function public.list_my_parcel_pals()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_user uuid:=auth.uid(); v_result jsonb;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to view Parcel Pals'; end if;
  if not public.is_customer_parcel_pal_user(v_user) then raise insufficient_privilege using message='Parcel Pals are only available to customer accounts'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('code',c.code,'full_name',p.full_name,'phone',p.phone,'avatar_path',p.avatar_path,
    'address',addr.address,'city',addr.city,'state',addr.state,'connected_at',x.responded_at)
    order by p.full_name nulls last,c.code),'[]'::jsonb) into v_result
  from public.parcel_pal_connections x join public.parcel_pal_codes c on c.user_id=case when x.user_a=v_user then x.user_b else x.user_a end
  left join public.profiles p on p.user_id=c.user_id
  left join lateral (select cu.address,cu.city,cu.state from public.customer_users m join public.customers cu on cu.id=m.customer_id where m.user_id=c.user_id order by cu.created_at desc limit 1) addr on true
  where v_user in (x.user_a,x.user_b) and x.status='accepted' and public.is_customer_parcel_pal_user(c.user_id);
  return v_result;
end;
$$;

revoke all on function public.check_parcel_pal_daily_limit(text) from public,anon,authenticated;
revoke all on function public.search_parcel_pals(text) from public,anon;
grant execute on function public.search_parcel_pals(text) to authenticated;
revoke all on function public.send_parcel_pal_request(text) from public,anon;
grant execute on function public.send_parcel_pal_request(text) to authenticated;
revoke all on function public.respond_to_parcel_pal_request(text,boolean) from public,anon;
grant execute on function public.respond_to_parcel_pal_request(text,boolean) to authenticated;
revoke all on function public.list_parcel_pal_requests() from public,anon;
grant execute on function public.list_parcel_pal_requests() to authenticated;
revoke all on function public.list_my_parcel_pals() from public,anon;
grant execute on function public.list_my_parcel_pals() to authenticated;\n