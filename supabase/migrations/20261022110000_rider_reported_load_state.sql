-- Rider-reported box space is separate from on-duty GPS presence. No box size is assumed.
alter table public.rider_credentials
  add column load_state text not null default 'available'
    check (load_state in ('available','almost_full','full')),
  add column load_state_changed_at timestamptz not null default now();

create function public.my_rider_load_state() returns text
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_state text;
begin
  if not public.rider_session_active() then raise insufficient_privilege using message='Rider access required'; end if;
  select load_state into v_state from public.rider_credentials where user_id=auth.uid();
  return v_state;
end $$;
revoke all on function public.my_rider_load_state() from public,anon;
grant execute on function public.my_rider_load_state() to authenticated;

create function public.set_rider_load_state(p_state text) returns text
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_partner uuid; v_old text; v_inv record; v_replacement record;
begin
  if not public.rider_session_active() then raise insufficient_privilege using message='Rider access required'; end if;
  if p_state is null or p_state not in ('available','almost_full','full') then
    raise check_violation using message='Choose Available, Almost full, or Full';
  end if;
  select partner_id,load_state into v_partner,v_old from public.rider_credentials
    where user_id=auth.uid() and revoked_at is null and password_revoked_at is null for update;
  if v_partner is null then raise insufficient_privilege using message='Active rider access required'; end if;
  if v_old=p_state then return v_old; end if;
  update public.rider_credentials set load_state=p_state,load_state_changed_at=clock_timestamp()
    where user_id=auth.uid();
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('rider',auth.uid(),'load_state_'||p_state,auth.uid(),array['load_state']);

  -- An open invitation tied to a newly full rider may use a different nearby rider
  -- of the same company. Without a replacement it becomes ineligible to bid.
  if p_state='full' then
    for v_inv in select i.request_id,r.pickup_latitude,r.pickup_longitude
      from public.company_bid_invitations i
      join public.delivery_quote_windows w on w.request_id=i.request_id and w.status='open' and w.deadline_at>now()
      join public.service_requests r on r.id=i.request_id
      where i.rider_id=auth.uid() and i.partner_id=v_partner and r.pickup_latitude is not null
    loop
      select rp.user_id,extensions.st_distance(rp.position,
        extensions.st_setsrid(extensions.st_makepoint(v_inv.pickup_longitude,v_inv.pickup_latitude),4326)::extensions.geography) as distance_metres
      into v_replacement
      from public.rider_presence rp
      join public.rider_credentials rc on rc.user_id=rp.user_id and rc.partner_id=v_partner
        and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
      join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
      join public.partner_users pu on pu.user_id=rp.user_id and pu.partner_id=v_partner and pu.membership_role='rider'
      where rp.partner_id=v_partner and rp.user_id<>auth.uid()
        and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
        and extensions.st_dwithin(rp.position,
          extensions.st_setsrid(extensions.st_makepoint(v_inv.pickup_longitude,v_inv.pickup_latitude),4326)::extensions.geography,5000)
        and (select count(*) from public.jobs j where j.assigned_rider_id=rp.user_id
          and j.status in ('pickup_scheduled','picked_up','exception'))<5
      order by (rc.load_state='almost_full'),distance_metres,rp.user_id limit 1;
      if found then
        update public.company_bid_invitations set rider_id=v_replacement.user_id,
          distance_metres=v_replacement.distance_metres
          where request_id=v_inv.request_id and partner_id=v_partner and rider_id=auth.uid();
      end if;
    end loop;
  end if;
  return p_state;
end $$;
revoke all on function public.set_rider_load_state(text) from public,anon;
grant execute on function public.set_rider_load_state(text) to authenticated;

create or replace function public.nearby_dispatch_companies(p_request uuid,p_corridor uuid)
returns table(partner_id uuid,rider_id uuid,distance_metres double precision)
language sql stable security definer set search_path=pg_catalog,public,extensions as $$
  select distinct on (rp.partner_id) rp.partner_id,rp.user_id,
    extensions.st_distance(rp.position,extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography)
  from public.service_requests r
  join public.rider_presence rp on extensions.st_dwithin(rp.position,
    extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography,5000)
  join public.logistics_partners p on p.id=rp.partner_id and p.status='active'
  join public.rider_credentials rc on rc.user_id=rp.user_id and rc.partner_id=rp.partner_id
    and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
  join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
  join public.partner_users pu on pu.user_id=rp.user_id and pu.partner_id=rp.partner_id and pu.membership_role='rider'
  where r.id=p_request and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
    and (select count(*) from public.jobs j where j.assigned_rider_id=rp.user_id
      and j.status in ('pickup_scheduled','picked_up','exception'))<5
  order by rp.partner_id,(rc.load_state='almost_full'),3,rp.user_id;
$$;

create or replace function public.company_can_bid_nearby(p_request uuid,p_partner uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,public,extensions as $$
  select exists(select 1 from public.service_requests r join public.services s on s.id=r.service_id
    where r.id=p_request and (s.code<>'SRV-0001' or r.pickup_location_source is null or exists (
      select 1 from public.company_bid_invitations i
      join public.rider_presence rp on rp.user_id=i.rider_id and rp.partner_id=i.partner_id
      join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=i.partner_id
        and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
      join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
      join public.partner_users pu on pu.user_id=i.rider_id and pu.partner_id=i.partner_id and pu.membership_role='rider'
      where i.request_id=r.id and i.partner_id=p_partner
        and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
        and extensions.st_dwithin(rp.position,
          extensions.st_setsrid(extensions.st_makepoint(r.pickup_longitude,r.pickup_latitude),4326)::extensions.geography,5000)
        and (select count(*) from public.jobs j where j.assigned_rider_id=i.rider_id
          and j.status in ('pickup_scheduled','picked_up','exception'))<5)));
$$;

create function public.list_company_bid_rider_loads()
returns table(request_id uuid,rider_name text,load_state text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select i.request_id,rc.rider_name,rc.load_state
  from public.company_bid_invitations i
  join public.delivery_quote_windows w on w.request_id=i.request_id and w.status='open' and w.deadline_at>now()
  join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=i.partner_id
  where public.company_staff_allowed(i.partner_id,'bid')
    and public.company_can_bid_nearby(i.request_id,i.partner_id);
$$;
revoke all on function public.list_company_bid_rider_loads() from public,anon;
grant execute on function public.list_company_bid_rider_loads() to authenticated;

create or replace function public.assign_selected_pickup_rider_on_acceptance()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_rider uuid;
begin
  if new.status<>'accepted' or (tg_op='UPDATE' and old.status='accepted') then return new; end if;
  select i.rider_id into v_rider
  from public.jobs j
  join public.orders o on o.id=j.order_id
  join public.customer_delivery_quotes cq on cq.request_id=o.service_request_id and cq.status='accepted'
  join public.partner_quotes q on q.id=cq.winning_bid_id and q.partner_id=new.partner_id
  join public.company_bid_invitations i on i.request_id=o.service_request_id and i.partner_id=new.partner_id
  join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=new.partner_id
    and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
  join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
  join public.partner_users pu on pu.user_id=i.rider_id and pu.partner_id=new.partner_id and pu.membership_role='rider'
  where j.id=new.job_id and j.partner_id=new.partner_id and j.assigned_rider_id is null
    and j.status in ('partner_assigned','pickup_scheduled');
  if v_rider is not null then
    update public.jobs set assigned_rider_id=v_rider where id=new.job_id and assigned_rider_id is null;
  end if;
  return new;
exception when check_violation then
  return new;
end $$;

-- The ordinary assignment path must enforce Full too. Existing jobs may continue
-- changing status while the rider is Full; only a new rider assignment is blocked.
create or replace function public.guard_rider_active_pickup_limit()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_active_count integer; v_partner_accepted boolean; v_new_assignment boolean; v_load_state text;
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
  end if;
  if new.status in ('pickup_scheduled','picked_up','exception') then
    select count(*) into v_active_count from public.jobs j
      where j.assigned_rider_id=new.assigned_rider_id and j.id<>new.id
        and j.status in ('pickup_scheduled','picked_up','exception');
    if v_active_count>=5 then
      raise check_violation using message='This rider already has five active pickups. Assign another rider or wait until an active delivery is completed.';
    end if;
  end if;
  return new;
end $$;

comment on column public.rider_credentials.load_state is
  'Rider-reported box space. Almost full remains bid-eligible with a company warning; full blocks new local jobs while GPS tracking continues.';
