-- A rider with assigned work needs a fresh route as soon as GPS comes back,
-- even if they have not yet moved 500 metres from the last marker.
create or replace function public.enqueue_route_replan_on_material_movement() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_request uuid;v_marker public.route_replan_markers%rowtype;
begin
  select o.service_request_id into v_request from public.jobs j
  join public.orders o on o.id=j.order_id
  where j.assigned_rider_id=new.user_id
    and j.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery','exception')
  order by j.created_at,j.id limit 1;
  if v_request is null then return new; end if;
  insert into public.route_replan_markers(rider_id,position)
    values(new.user_id,new.position) on conflict(rider_id) do nothing;
  if tg_op='INSERT' then
    insert into public.route_planner_events(request_id,rider_id,event_kind,idempotency_key)
      values(v_request,new.user_id,'replan',
        'online:'||new.user_id::text||':'||txid_current()::text)
      on conflict(idempotency_key) do nothing;
    return new;
  end if;
  select * into v_marker from public.route_replan_markers where rider_id=new.user_id for update;
  if v_marker.enqueued_at>now()-interval '5 minutes'
    or extensions.st_distance(v_marker.position,new.position)<500 then return new; end if;
  update public.route_replan_markers set position=new.position,enqueued_at=now()
    where rider_id=new.user_id;
  insert into public.route_planner_events(request_id,rider_id,event_kind,idempotency_key)
    values(v_request,new.user_id,'replan',
      'movement:'||new.user_id::text||':'||floor(extract(epoch from now())/300)::bigint::text)
    on conflict(idempotency_key) do nothing;
  return new;
end $$;
