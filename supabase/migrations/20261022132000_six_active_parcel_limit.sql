-- Count every assigned, unfinished parcel, including one already in transit.
create function public.rider_has_parcel_slot(p_rider uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select p_rider is not null and (
    select count(*) from public.jobs j where j.assigned_rider_id=p_rider
      and j.status in ('partner_assigned','pickup_scheduled','picked_up','in_transit','out_for_delivery','exception')
  )<6;
$$;
revoke all on function public.rider_has_parcel_slot(uuid) from public,anon,authenticated;

-- Apply the same limit before an invitation, while bidding, and immediately
-- before assignment. Existing jobs stay assigned and tracked at the limit.
do $$
declare v_name text; v_rider text; v_definition text; v_revised text;
begin
  for v_name,v_rider in select * from (values
    ('public.nearby_dispatch_companies(uuid,uuid)','rp.user_id'),
    ('public.route_planner_candidates(uuid)','rp.user_id'),
    ('public.company_can_bid_nearby(uuid,uuid)','i.rider_id'),
    ('public.finalize_live_route_match(uuid)','p.rider_id'),
    ('public.assign_selected_pickup_rider_on_acceptance()','rp.user_id'),
    ('public.upsert_dispatch_route_proposal(uuid,uuid,uuid,text,text,double precision,jsonb,timestamptz)','p_rider'),
    ('public.try_dispatch_match(uuid)','rp.user_id'),
    ('public.set_rider_load_state(text)','rp.user_id')
  ) as x(name,rider) loop
    select pg_get_functiondef(v_name::regprocedure) into v_definition;
    v_revised:=regexp_replace(v_definition,
      '(rc\.load_state[[:space:]]*<>[[:space:]]*''full'')',
      '\1 and public.rider_has_parcel_slot('||v_rider||')', 'g');
    if v_revised=v_definition then raise exception 'Rider slot guard missing in %',v_name; end if;
    execute v_revised;
  end loop;
end $$;

create or replace function public.guard_rider_active_pickup_limit()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_partner_accepted boolean; v_new_assignment boolean; v_load_state text;
begin
  select exists(select 1 from public.partner_assignments pa
    where pa.job_id=new.id and pa.partner_id=new.partner_id and pa.status='accepted') into v_partner_accepted;
  if new.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery')
    and v_partner_accepted and new.assigned_rider_id is null then
    raise check_violation using message='Assign a partner-company rider before scheduling or progressing this pickup';
  end if;
  if tg_op='UPDATE' and new.status='exception'
    and old.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery')
    and v_partner_accepted and new.assigned_rider_id is null then
    raise check_violation using message='Keep the assigned rider on an active delivery exception until it is resolved';
  end if;
  if new.assigned_rider_id is null then return new; end if;
  if new.partner_id is null or not exists(select 1 from public.partner_users pu
    where pu.partner_id=new.partner_id and pu.user_id=new.assigned_rider_id
      and pu.membership_role='rider') then
    raise check_violation using message='Choose a rider who belongs to the assigned partner company';
  end if;
  perform 1 from auth.users u where u.id=new.assigned_rider_id for update;
  v_new_assignment:=tg_op='INSERT';
  if tg_op='UPDATE' then v_new_assignment:=new.assigned_rider_id is distinct from old.assigned_rider_id; end if;
  if v_new_assignment then
    select rc.load_state into v_load_state from public.rider_credentials rc
      where rc.user_id=new.assigned_rider_id for update;
    if v_load_state='full' then
      raise check_violation using message='This rider marked their box Full. Choose another rider.';
    end if;
    if not public.rider_has_parcel_slot(new.assigned_rider_id) then
      raise check_violation using message='This rider already has six active parcels. Choose another rider.';
    end if;
  end if;
  return new;
end $$;
