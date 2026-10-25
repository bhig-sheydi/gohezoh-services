-- Existing legacy rows remain readable, but customers cannot create or update
-- saved delivery addresses without a mapped point.
alter policy customer_parcel_destinations_owner on public.customer_parcel_destinations
  with check (
    user_id = auth.uid()
    and public.is_customer_parcel_pal_user(auth.uid())
    and latitude is not null and longitude is not null
  );

-- Fulfilment functions run as definer; direct customer submissions must carry
-- both pickup and drop-off points, including typed destinations.
alter policy requests_submit_customer on public.service_requests
  with check (
    created_by = auth.uid() and status = 'submitted'
    and public.is_customer_user(customer_id)
    and pickup_latitude is not null and pickup_longitude is not null
    and delivery_latitude is not null and delivery_longitude is not null
  );

-- Accepted Parcel Pals can select the saved point as well as the address label.
create or replace function public.list_my_parcel_pals()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_user uuid:=auth.uid(); v_result jsonb;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to view Parcel Pals'; end if;
  if not public.is_customer_parcel_pal_user(v_user) then raise insufficient_privilege using message='Parcel Pals are only available to customer accounts'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'code',c.code,'full_name',p.full_name,'phone',p.phone,'avatar_path',p.avatar_path,
    'address',addr.address,'city',addr.city,'state',addr.state,'destinations',coalesce(dest.items,'[]'::jsonb),
    'connected_at',x.responded_at
  ) order by p.full_name nulls last,c.code),'[]'::jsonb) into v_result
  from public.parcel_pal_connections x
  join public.parcel_pal_codes c on c.user_id=case when x.user_a=v_user then x.user_b else x.user_a end
  left join public.profiles p on p.user_id=c.user_id
  left join lateral (select cu.address,cu.city,cu.state from public.customer_users m join public.customers cu on cu.id=m.customer_id where m.user_id=c.user_id order by cu.created_at desc limit 1) addr on true
  left join lateral (select jsonb_agg(jsonb_build_object(
    'slot',d.slot,'label',d.label,'address',d.address,'city',d.city,'state',d.state,
    'secondary_phone',d.secondary_phone,'latitude',d.latitude,'longitude',d.longitude,
    'location_source',d.location_source,'location_accuracy_metres',d.location_accuracy_metres
  ) order by d.slot) as items from public.customer_parcel_destinations d where d.user_id=c.user_id) dest on true
  where v_user in (x.user_a,x.user_b) and x.status='accepted' and public.is_customer_parcel_pal_user(c.user_id);
  return v_result;
end;
$$;
revoke all on function public.list_my_parcel_pals() from public,anon;
grant execute on function public.list_my_parcel_pals() to authenticated;
