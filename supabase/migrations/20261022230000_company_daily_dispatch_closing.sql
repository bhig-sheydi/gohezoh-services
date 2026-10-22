-- Company owners can adjust today's dispatch closing time without changing their
-- registration evidence. Times are interpreted in Africa/Lagos.
create table public.company_daily_dispatch_closing (
  partner_id uuid not null references public.logistics_partners(id) on delete cascade,
  work_date date not null,
  closes_at timestamptz not null,
  updated_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  primary key(partner_id,work_date)
);
alter table public.company_daily_dispatch_closing enable row level security;
revoke all on public.company_daily_dispatch_closing from public,anon,authenticated;

create function public.company_dispatch_close_at(p_partner uuid,p_at timestamptz default now())
returns timestamptz language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_day date:=(p_at at time zone 'Africa/Lagos')::date;
  v_clock time:=(p_at at time zone 'Africa/Lagos')::time;
  v_close timestamptz;
begin
  -- An overnight override from yesterday remains in force after midnight.
  select d.closes_at into v_close from public.company_daily_dispatch_closing d
    where d.partner_id=p_partner and d.work_date in (v_day,v_day-1)
      and d.closes_at>p_at
    order by d.work_date desc limit 1;
  if v_close is not null then return v_close; end if;
  if exists(select 1 from public.company_daily_dispatch_closing d
    where d.partner_id=p_partner and d.work_date=v_day) then
    select d.closes_at into v_close from public.company_daily_dispatch_closing d
      where d.partner_id=p_partner and d.work_date=v_day;
    return v_close;
  end if;
  -- Registered vehicle hours supply the default. A legacy company without
  -- vehicle evidence must set its hours before this rule can be enforced.
  select max(case when v.closing_time>v.opening_time then
      (v_day+v.closing_time) at time zone 'Africa/Lagos'
    when v_clock<v.closing_time or v_clock<v.opening_time then
      (v_day+v.closing_time) at time zone 'Africa/Lagos'
    else ((v_day+1)+v.closing_time) at time zone 'Africa/Lagos' end)
    into v_close from public.partner_application_vehicles v where v.partner_id=p_partner;
  return v_close;
end $$;
revoke all on function public.company_dispatch_close_at(uuid,timestamptz) from public,anon,authenticated;
grant execute on function public.company_dispatch_close_at(uuid,timestamptz) to service_role;

create function public.set_my_company_closing_time(p_partner uuid,p_time time,p_next_day boolean default false)
returns timestamptz language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_day date:=(now() at time zone 'Africa/Lagos')::date;v_close timestamptz;
begin
  if auth.uid() is null or not exists(select 1 from public.partner_users pu
    join public.logistics_partners lp on lp.id=pu.partner_id and lp.status='active'
    where pu.partner_id=p_partner and pu.user_id=auth.uid() and pu.membership_role='manager') then
    raise insufficient_privilege using message='Company owner access required'; end if;
  if p_time is null then raise check_violation using message='Choose a closing time'; end if;
  v_close:=((v_day+case when p_next_day then 1 else 0 end)+p_time) at time zone 'Africa/Lagos';
  if v_close<=now() or v_close>now()+interval '30 hours' then
    raise check_violation using message='Choose a future closing time within 30 hours'; end if;
  insert into public.company_daily_dispatch_closing(partner_id,work_date,closes_at,updated_by)
    values(p_partner,v_day,v_close,auth.uid())
    on conflict(partner_id,work_date) do update set closes_at=excluded.closes_at,
      updated_by=excluded.updated_by,updated_at=now();
  return v_close;
end $$;
revoke all on function public.set_my_company_closing_time(uuid,time,boolean) from public,anon;
grant execute on function public.set_my_company_closing_time(uuid,time,boolean) to authenticated;

create function public.my_company_dispatch_hours(p_partner uuid)
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
    where d.partner_id=p_partner and d.work_date=(now() at time zone 'Africa/Lagos')::date) then
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
revoke all on function public.my_company_dispatch_hours(uuid) from public,anon;
grant execute on function public.my_company_dispatch_hours(uuid) to authenticated;

create function public.dispatch_company_closing_times(p_partners uuid[])
returns table(partner_id uuid,closes_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if auth.role()<>'service_role' then raise insufficient_privilege using message='Routing worker access required'; end if;
  return query select p.id,public.company_dispatch_close_at(p.id,now())
    from public.logistics_partners p where p.id=any(p_partners) and p.status='active';
end $$;
revoke all on function public.dispatch_company_closing_times(uuid[]) from public,anon,authenticated;
grant execute on function public.dispatch_company_closing_times(uuid[]) to service_role;

create function public.company_dispatch_route_fits(p_partner uuid,p_route_minutes double precision,
  p_at timestamptz default now()) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select p_route_minutes is not null and p_route_minutes between 0 and 1440
    and public.company_dispatch_close_at(p_partner,p_at) is not null
    and p_at + make_interval(secs=>ceil(p_route_minutes*60)::integer) + interval '20 minutes'
      <=public.company_dispatch_close_at(p_partner,p_at);
$$;
revoke all on function public.company_dispatch_route_fits(uuid,double precision,timestamptz) from public,anon,authenticated;
grant execute on function public.company_dispatch_route_fits(uuid,double precision,timestamptz) to service_role;
