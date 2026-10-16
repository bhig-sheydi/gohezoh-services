-- Preserve the customer's chosen point separately from any provider address label.
alter table public.service_requests drop constraint pickup_fix_complete;
alter table public.service_requests add constraint pickup_fix_complete check (
  (pickup_latitude is null and pickup_longitude is null and pickup_accuracy_metres is null and pickup_captured_at is null and pickup_location_source is null)
  or (pickup_latitude is not null and pickup_latitude between -90 and 90 and pickup_longitude is not null and pickup_longitude between -180 and 180 and pickup_captured_at is not null and pickup_location_source is not null
    and ((pickup_location_source in ('browser','native') and pickup_accuracy_metres between 0 and 100)
      or (pickup_location_source in ('search','saved','map') and pickup_accuracy_metres is null))));
alter table public.customer_parcel_destinations drop constraint saved_address_coordinates;
alter table public.customer_parcel_destinations add constraint saved_address_coordinates check (
  (latitude is null and longitude is null and location_source is null and location_accuracy_metres is null)
  or (latitude is not null and latitude between -90 and 90 and longitude is not null and longitude between -180 and 180 and location_source is not null
    and ((location_source in ('browser','native') and location_accuracy_metres between 0 and 100)
      or (location_source in ('search','saved','map') and location_accuracy_metres is null))));

alter table public.service_requests add column delivery_latitude double precision,
  add column delivery_longitude double precision,add column delivery_accuracy_metres double precision,
  add column delivery_captured_at timestamptz,add column delivery_location_source text;
alter table public.service_requests add constraint delivery_fix_complete check (
  (delivery_latitude is null and delivery_longitude is null and delivery_accuracy_metres is null and delivery_captured_at is null and delivery_location_source is null)
  or (delivery_latitude is not null and delivery_latitude between -90 and 90 and delivery_longitude is not null and delivery_longitude between -180 and 180 and delivery_captured_at is not null and delivery_location_source is not null
    and ((delivery_location_source in ('browser','native') and delivery_accuracy_metres between 0 and 100)
      or (delivery_location_source in ('search','saved','map') and delivery_accuracy_metres is null))));

alter table public.jobs add column delivery_latitude double precision,add column delivery_longitude double precision;
create function public.copy_delivery_point_to_job() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  select r.delivery_latitude,r.delivery_longitude into new.delivery_latitude,new.delivery_longitude
  from public.orders o join public.service_requests r on r.id=o.service_request_id where o.id=new.order_id;
  return new;
end $$;
create trigger copy_delivery_point_to_job before insert on public.jobs
for each row execute function public.copy_delivery_point_to_job();
revoke all on function public.copy_delivery_point_to_job() from public,anon,authenticated;
update public.jobs j set delivery_latitude=r.delivery_latitude,delivery_longitude=r.delivery_longitude
from public.orders o join public.service_requests r on r.id=o.service_request_id
where j.order_id=o.id and r.delivery_latitude is not null;

-- Assigned riders can obtain the destination point without seeing other customers' requests.
create function public.list_my_rider_delivery_locations()
returns table(job_id uuid,latitude double precision,longitude double precision)
language sql stable security definer set search_path=pg_catalog,public as $$
  select j.id,j.delivery_latitude,j.delivery_longitude from public.jobs j
  join public.partner_assignments a on a.job_id=j.id and a.partner_id=j.partner_id and a.status in ('accepted','completed')
  where j.assigned_rider_id=auth.uid() and public.rider_session_active()
    and j.status not in ('delivered','closed','cancelled') and j.delivery_latitude is not null;
$$;
revoke all on function public.list_my_rider_delivery_locations() from public,anon;
grant execute on function public.list_my_rider_delivery_locations() to authenticated;

-- Only an invited manager gets a destination pin while the private bid window is open.
create function public.list_company_bid_delivery_locations()
returns table(request_id uuid,latitude double precision,longitude double precision)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.delivery_latitude,r.delivery_longitude
  from public.company_bid_invitations i join public.service_requests r on r.id=i.request_id
  join public.delivery_quote_windows w on w.request_id=r.id and w.status='open' and w.deadline_at>now()
  where r.delivery_latitude is not null and public.is_partner_user(i.partner_id)
    and public.company_can_bid_nearby(r.id,i.partner_id);
$$;
revoke all on function public.list_company_bid_delivery_locations() from public,anon;
grant execute on function public.list_company_bid_delivery_locations() to authenticated;
