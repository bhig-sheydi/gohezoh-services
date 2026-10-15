-- The countdown is authoritative in the database; expired bids remain rejected.
alter table public.service_requests add column if not exists parcel_photo_path text;
alter table public.service_requests add constraint service_request_parcel_photo_path_format
  check (parcel_photo_path is null or parcel_photo_path ~ '^[0-9a-fA-F-]{36}/[^/]+[.](jpg|png|webp)$');

create or replace function public.check_service_request_parcel_photo()
returns trigger language plpgsql set search_path=pg_catalog,public,storage as $$
begin
  if new.parcel_photo_path is not null and (
    split_part(new.parcel_photo_path,'/',1)<>new.created_by::text or
    not exists (select 1 from storage.objects o where o.bucket_id='customer-saved-parcels'
      and o.name=new.parcel_photo_path and o.owner_id=new.created_by::text)
  ) then raise check_violation using message='Parcel photo must be uploaded by the request owner'; end if;
  return new;
end $$;
create trigger check_service_request_parcel_photo_before_write
before insert or update of parcel_photo_path on public.service_requests
for each row execute function public.check_service_request_parcel_photo();
revoke all on function public.check_service_request_parcel_photo() from public,anon,authenticated;

create or replace function public.publish_delivery_request(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_request public.service_requests%rowtype;v_code text;v_corridor uuid;v_deadline timestamptz;
begin
  if not (public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only Operations can publish delivery bids'; end if;
  select * into v_request from public.service_requests where id=p_request_id for update;
  if not found then raise no_data_found using message='Request not found'; end if;
  if v_request.status not in ('submitted','under_review') then raise object_not_in_prerequisite_state using message='Request cannot be published'; end if;
  select code into v_code from public.services where id=v_request.service_id;
  if v_code not in ('SRV-0001','SRV-0002') then raise check_violation using message='Only delivery requests can be published'; end if;
  select c.id into v_corridor from public.coverage_corridors c
  join public.coverage_locations o on o.id=c.origin_id join public.coverage_locations d on d.id=c.destination_id
  where c.service_code=v_code and c.is_enabled and o.is_enabled and d.is_enabled
    and lower(btrim(o.name))=lower(btrim(v_request.pickup_city)) and lower(btrim(d.name))=lower(btrim(v_request.delivery_city));
  if v_corridor is null then raise check_violation using message='Delivery corridor is not enabled'; end if;
  v_deadline:=now()+interval '1 minute';
  insert into public.delivery_quote_windows(request_id,corridor_id,published_at,deadline_at)
  values(p_request_id,v_corridor,now(),v_deadline)
  on conflict (request_id) do nothing;
  update public.service_requests set status='under_review' where id=p_request_id;
  select deadline_at into v_deadline from public.delivery_quote_windows where request_id=p_request_id;
  return jsonb_build_object('request_id',p_request_id,'deadline_at',v_deadline,'corridor_id',v_corridor);
end $$;

create or replace function public.list_partner_bid_screen()
returns table(request_id uuid,request_number text,pickup_city text,delivery_city text,
  parcel_summary text,parcel_items jsonb,photo_path text,deadline_at timestamptz,
  own_bid_amount_ngn numeric,own_bid_status text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.request_number,r.pickup_city,r.delivery_city,r.parcel_summary,r.parcel_items,
    coalesce(r.parcel_photo_path,(select sp.photo_path from public.customer_saved_parcels sp
      where sp.id::text=r.parcel_items->0->>'saved_parcel_id' and sp.user_id=r.created_by)),
    w.deadline_at,
    (select q.amount_ngn from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id order by q.version desc limit 1),
    (select q.status from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id order by q.version desc limit 1)
  from public.delivery_quote_windows w
  join public.service_requests r on r.id=w.request_id
  join public.partner_corridor_coverage pc on pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
  join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
  where public.is_partner_user(pc.partner_id) and w.status='open' and now()<w.deadline_at;
$$;
revoke all on function public.list_partner_bid_screen() from public,anon;
grant execute on function public.list_partner_bid_screen() to authenticated;

create or replace function public.can_read_bid_parcel_photo(p_path text)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select exists (
    select 1 from public.service_requests r
    join public.delivery_quote_windows w on w.request_id=r.id and w.status='open' and w.deadline_at>now()
    join public.partner_corridor_coverage pc on pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
    join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
    where (r.parcel_photo_path=p_path or exists (select 1 from public.customer_saved_parcels sp
      where sp.id::text=r.parcel_items->0->>'saved_parcel_id' and sp.user_id=r.created_by and sp.photo_path=p_path))
      and public.is_partner_user(pc.partner_id)
  );
$$;
revoke all on function public.can_read_bid_parcel_photo(text) from public,anon;
grant execute on function public.can_read_bid_parcel_photo(text) to authenticated;
create policy customer_saved_parcel_photos_partner_bid_read on storage.objects for select to authenticated
using (bucket_id='customer-saved-parcels' and public.can_read_bid_parcel_photo(name));
