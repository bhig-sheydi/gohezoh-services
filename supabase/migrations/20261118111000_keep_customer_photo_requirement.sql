-- The retired item-copy trigger also checked for a photo. Keep that safety rule
-- in the existing photo ownership trigger without writing catalogue rows.
create or replace function public.check_service_request_parcel_photo()
returns trigger language plpgsql set search_path=pg_catalog,public,storage,auth as $$
begin
  if auth.uid() = new.created_by and public.has_role(auth.uid(),'customer')
    and new.parcel_photo_path is null then
    raise check_violation using message='Add a photo of the goods before requesting delivery';
  end if;
  if new.parcel_photo_path is not null and (
    split_part(new.parcel_photo_path,'/',1)<>new.created_by::text or
    not exists (select 1 from storage.objects o where o.bucket_id='customer-saved-parcels'
      and o.name=new.parcel_photo_path and o.owner_id=new.created_by::text)
  ) then raise check_violation using message='Parcel photo must be uploaded by the request owner'; end if;
  return new;
end $$;
