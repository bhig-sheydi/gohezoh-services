create policy independent_rider_photo_upload on storage.objects for insert to authenticated
with check(bucket_id='rider-evidence' and owner_id=auth.uid()::text
  and split_part(name,'/',1)='independent'
  and split_part(name,'/',2)=auth.uid()::text
  and split_part(name,'/',3)<>'' and split_part(name,'/',4)='');

create policy independent_rider_photo_read on storage.objects for select to authenticated
using(bucket_id='rider-evidence' and owner_id=auth.uid()::text
  and split_part(name,'/',1)='independent' and split_part(name,'/',2)=auth.uid()::text);

create function public.set_own_independent_rider_photo(p_photo_path text) returns void
language plpgsql security definer set search_path=pg_catalog,public,storage as $$
declare v_old text;
begin
  if not public.rider_session_active() or p_photo_path is null
    or split_part(p_photo_path,'/',1)<>'independent'
    or split_part(p_photo_path,'/',2)<>auth.uid()::text
    or p_photo_path !~* '[.](jpg|jpeg|png|webp)$' then
    raise insufficient_privilege using message='Your rider photo is required'; end if;
  if not exists(select 1 from storage.objects o where o.bucket_id='rider-evidence'
    and o.name=p_photo_path and o.owner_id=auth.uid()::text) then
    raise check_violation using message='Upload your photo first'; end if;
  select photo_path into v_old from public.company_riders
    where independent_user_id=auth.uid() and status='approved' for update;
  if not found then raise insufficient_privilege using message='Active independent rider required'; end if;
  update public.company_riders set photo_path=p_photo_path where independent_user_id=auth.uid();
  if v_old is not null and v_old<>p_photo_path and split_part(v_old,'/',1)='independent'
    and split_part(v_old,'/',2)=auth.uid()::text then
    delete from storage.objects where bucket_id='rider-evidence' and name=v_old
      and owner_id=auth.uid()::text;
  end if;
end $$;
revoke all on function public.set_own_independent_rider_photo(text) from public,anon;
grant execute on function public.set_own_independent_rider_photo(text) to authenticated;
