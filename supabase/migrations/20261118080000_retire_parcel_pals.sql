-- Retire Parcel Pals and the Home/Work/Other address book. Delivery request
-- coordinates and completed-delivery place cache remain for fulfilment.
drop trigger if exists on_auth_user_parcel_pal_code on auth.users;
drop trigger if exists sync_customer_parcel_pal_code on public.user_roles;
drop trigger if exists customer_saved_place_share on public.customer_parcel_destinations;

create or replace function public.queue_customer_dispatch() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.pickup_latitude is not null and exists(select 1 from public.services where id=new.service_id and code='SRV-0001') then
    if not public.try_dispatch_match(new.id) then
      insert into public.dispatch_match_queue(request_id) values(new.id) on conflict do nothing;
      update public.service_requests set dispatch_match_status='waiting' where id=new.id;
    end if;
  end if;
  return new;
end $$;

drop policy if exists parcel_pal_profile_photos_read_related on storage.objects;
drop policy if exists parcel_pal_profile_photos_insert_own on storage.objects;
drop policy if exists parcel_pal_profile_photos_update_own on storage.objects;
drop policy if exists parcel_pal_profile_photos_delete_own on storage.objects;

drop function if exists public.list_my_parcel_pals();
drop function if exists public.list_parcel_pal_requests();
drop function if exists public.respond_to_parcel_pal_request(text,boolean);
drop function if exists public.send_parcel_pal_request(text);
drop function if exists public.search_parcel_pals(text);
drop function if exists public.get_my_parcel_pal_code();
drop function if exists public.set_my_parcel_pal_photo(text);
drop function if exists public.can_read_parcel_pal_photo_path(text);
drop function if exists public.check_parcel_pal_daily_limit(text);
drop function if exists public.assign_parcel_pal_code_on_signup();
drop function if exists public.sync_customer_parcel_pal_code();
drop function if exists public.ensure_parcel_pal_code(uuid);
drop function if exists public.sync_saved_shared_delivery_place();

-- Remove shared search entries sourced from the retired address book, without
-- touching entries sourced from real completed deliveries.
delete from public.shared_delivery_place_sources where source_kind='saved';
delete from public.shared_delivery_places p
where not exists (select 1 from public.shared_delivery_place_sources s where s.place_id=p.id);

drop table if exists public.parcel_pal_connections;
drop table if exists public.parcel_pal_daily_limits;
drop table if exists public.parcel_pal_codes;
drop table if exists public.customer_parcel_destinations;
alter table public.service_requests drop column if exists pickup_saved_slot;

-- The customer avatar was created solely for Parcel Pals. The private Storage
-- bucket stays inaccessible pending object deletion through the Storage API.
alter table public.profiles drop column if exists avatar_path;

-- Keep the customer-only helper: completed-delivery place caching still uses it.
