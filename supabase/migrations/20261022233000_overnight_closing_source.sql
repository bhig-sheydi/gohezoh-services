-- Show an overnight owner override as owner-set after midnight.
create or replace function public.my_company_dispatch_hours(p_partner uuid)
returns table(closes_at timestamptz,source text,online_riders integer,rough_extra_rides integer)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_close timestamptz;v_source text;v_online integer;v_slots integer;
begin
  if auth.uid() is null or not exists(select 1 from public.partner_users pu
    join public.logistics_partners lp on lp.id=pu.partner_id and lp.status='active'
    where pu.partner_id=p_partner and pu.user_id=auth.uid() and pu.membership_role='manager') then
    raise insufficient_privilege using message='Company owner access required'; end if;
  v_close:=public.company_dispatch_close_at(p_partner,now());
  if exists(select 1 from public.company_daily_dispatch_closing d
    where d.partner_id=p_partner and (d.work_date=(now() at time zone 'Africa/Lagos')::date
      or (d.work_date=(now() at time zone 'Africa/Lagos')::date-1 and d.closes_at>now()))) then
    v_source:='today';
  elsif v_close is not null then v_source:='registration';
  else v_source:='unset'; end if;
  select count(*)::integer,coalesce(sum(least(6-greatest(0,coalesce(j.active_jobs,0)),
    floor(greatest(0,extract(epoch from (v_close-now()))/60-20-
      greatest(0,coalesce(extract(epoch from (s.last_stop-now()))/60,0)))/45)::integer)),0)::integer
    into v_online,v_slots
    from public.rider_presence rp
    join public.rider_credentials rc on rc.user_id=rp.user_id and rc.partner_id=rp.partner_id
      and rc.revoked_at is null and rc.password_revoked_at is null and rc.load_state<>'full'
    join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
    left join lateral (select count(*)::integer as active_jobs from public.jobs j
      where j.assigned_rider_id=rp.user_id and j.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery','exception')) j on true
    left join lateral (select max(eta_at) as last_stop from public.rider_route_stops
      where rider_id=rp.user_id) s on true
    where rp.partner_id=p_partner and rp.received_at>now()-interval '2 minutes'
      and rp.captured_at>now()-interval '2 minutes' and rp.accuracy_metres<=100;
  return query select v_close,v_source,coalesce(v_online,0),case when v_close is null then null::integer else coalesce(v_slots,0) end;
end $$;
