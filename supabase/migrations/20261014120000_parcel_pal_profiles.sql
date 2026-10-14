-- Parcel Pal profiles: private user photos and requester identity on incoming requests.
alter table public.profiles add column if not exists avatar_path text;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('profile-photos','profile-photos',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set
  name=excluded.name,
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

create or replace function public.can_read_parcel_pal_photo_path(p_path text)
returns boolean
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_owner uuid;
begin
  if v_user is null or coalesce(p_path,'') !~ '^[0-9a-fA-F-]{36}/[^/]+$' then return false; end if;
  begin
    v_owner := split_part(p_path,'/',1)::uuid;
  exception when invalid_text_representation then
    return false;
  end;
  if v_owner = v_user then return true; end if;
  return exists (
    select 1 from public.parcel_pal_connections c
    where c.status='accepted'
      and v_user in (c.user_a,c.user_b)
      and v_owner=case when c.user_a=v_user then c.user_b else c.user_a end
  ) or exists (
    select 1 from public.parcel_pal_connections c
    where c.status='pending'
      and c.requested_by=v_owner
      and v_user in (c.user_a,c.user_b)
      and v_owner<>v_user
  );
end;
$$;
revoke all on function public.can_read_parcel_pal_photo_path(text) from public, anon;
grant execute on function public.can_read_parcel_pal_photo_path(text) to authenticated;

create policy parcel_pal_profile_photos_read_related
on storage.objects for select to authenticated
using (
  bucket_id='profile-photos'
  and public.can_read_parcel_pal_photo_path(name)
);

create policy parcel_pal_profile_photos_insert_own
on storage.objects for insert to authenticated
with check (
  bucket_id='profile-photos'
  and (storage.foldername(name))[1]=auth.uid()::text
  and array_length(storage.foldername(name),1)=1
);

create policy parcel_pal_profile_photos_update_own
on storage.objects for update to authenticated
using (
  bucket_id='profile-photos'
  and (storage.foldername(name))[1]=auth.uid()::text
  and array_length(storage.foldername(name),1)=1
)
with check (
  bucket_id='profile-photos'
  and (storage.foldername(name))[1]=auth.uid()::text
  and array_length(storage.foldername(name),1)=1
);

create policy parcel_pal_profile_photos_delete_own
on storage.objects for delete to authenticated
using (
  bucket_id='profile-photos'
  and (storage.foldername(name))[1]=auth.uid()::text
  and array_length(storage.foldername(name),1)=1
);

create or replace function public.set_my_parcel_pal_photo(p_path text)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to update your profile photo'; end if;
  if coalesce(p_path,'') !~ ('^'||v_user::text||'/[^/]+\.(jpg|jpeg|png|webp)$') then
    raise invalid_parameter_value using message='Choose a valid profile photo';
  end if;
  update public.profiles set avatar_path=p_path where user_id=v_user;
  if not found then raise no_data_found using message='Customer profile is not ready'; end if;
  return p_path;
end;
$$;
revoke all on function public.set_my_parcel_pal_photo(text) from public, anon;
grant execute on function public.set_my_parcel_pal_photo(text) to authenticated;

create or replace function public.list_parcel_pal_requests()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare v_user uuid := auth.uid(); v_result jsonb;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to view Parcel Pal requests'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'code',c.code,'status',x.status,
    'direction',case when x.requested_by=v_user then 'sent' else 'received' end,
    'full_name',case when x.requested_by<>v_user then p.full_name else null end,
    'avatar_path',case when x.requested_by<>v_user then p.avatar_path else null end,
    'created_at',x.created_at
  ) order by x.created_at desc),'[]'::jsonb) into v_result
  from public.parcel_pal_connections x
  join public.parcel_pal_codes c on c.user_id=case when x.user_a=v_user then x.user_b else x.user_a end
  left join public.profiles p on p.user_id=x.requested_by
  where v_user in (x.user_a,x.user_b) and x.status='pending';
  return v_result;
end;
$$;
revoke all on function public.list_parcel_pal_requests() from public, anon;
grant execute on function public.list_parcel_pal_requests() to authenticated;

create or replace function public.list_my_parcel_pals()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare v_user uuid := auth.uid(); v_result jsonb;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to view Parcel Pals'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'code',c.code,'full_name',p.full_name,'phone',p.phone,'avatar_path',p.avatar_path,
    'address',addr.address,'city',addr.city,'state',addr.state,
    'connected_at',x.responded_at
  ) order by p.full_name nulls last,c.code),'[]'::jsonb) into v_result
  from public.parcel_pal_connections x
  join public.parcel_pal_codes c on c.user_id=case when x.user_a=v_user then x.user_b else x.user_a end
  left join public.profiles p on p.user_id=c.user_id
  left join lateral (
    select cu.address,cu.city,cu.state from public.customer_users m
    join public.customers cu on cu.id=m.customer_id
    where m.user_id=c.user_id
    order by cu.created_at desc limit 1
  ) addr on true
  where v_user in (x.user_a,x.user_b) and x.status='accepted';
  return v_result;
end;
$$;
revoke all on function public.list_my_parcel_pals() from public, anon;
grant execute on function public.list_my_parcel_pals() to authenticated;
