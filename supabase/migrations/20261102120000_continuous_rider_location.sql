-- One recent fix per rider. Dispatch presence remains on-duty only; this table
-- also accepts off-duty fixes from the rider's visible Android location service.
create table public.rider_location_latest (
  user_id uuid primary key references auth.users(id) on delete cascade,
  partner_id uuid not null references public.logistics_partners(id),
  position extensions.geography(Point,4326) not null,
  accuracy_metres double precision not null check(accuracy_metres between 0 and 100),
  captured_at timestamptz not null,
  received_at timestamptz not null default clock_timestamp(),
  previous_position extensions.geography(Point,4326),
  previous_accuracy_metres double precision,
  previous_captured_at timestamptz,
  on_duty boolean not null default true
);
create index rider_location_latest_partner on public.rider_location_latest(partner_id,received_at);
alter table public.rider_location_latest enable row level security;
revoke all on public.rider_location_latest from public,anon,authenticated;

create function public.save_rider_location_latest(p_user_id uuid,p_partner_id uuid,
  p_position extensions.geography,p_accuracy double precision,p_captured timestamptz,p_on_duty boolean)
returns void language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_previous public.rider_location_latest%rowtype;
begin
  select * into v_previous from public.rider_location_latest where user_id=p_user_id for update;
  if found and v_previous.captured_at>=p_captured then return; end if;
  insert into public.rider_location_latest(user_id,partner_id,position,accuracy_metres,captured_at,
    previous_position,previous_accuracy_metres,previous_captured_at,on_duty)
  values(p_user_id,p_partner_id,p_position,p_accuracy,p_captured,
    case when v_previous.captured_at>clock_timestamp()-interval '3 minutes' then v_previous.position end,
    case when v_previous.captured_at>clock_timestamp()-interval '3 minutes' then v_previous.accuracy_metres end,
    case when v_previous.captured_at>clock_timestamp()-interval '3 minutes' then v_previous.captured_at end,p_on_duty)
  on conflict(user_id) do update set partner_id=excluded.partner_id,position=excluded.position,
    accuracy_metres=excluded.accuracy_metres,captured_at=excluded.captured_at,
    received_at=clock_timestamp(),previous_position=excluded.previous_position,
    previous_accuracy_metres=excluded.previous_accuracy_metres,
    previous_captured_at=excluded.previous_captured_at,on_duty=excluded.on_duty;
end $$;
revoke all on function public.save_rider_location_latest(uuid,uuid,extensions.geography,double precision,timestamptz,boolean) from public,anon,authenticated;

create function public.copy_on_duty_rider_location() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
begin
  perform public.save_rider_location_latest(new.user_id,new.partner_id,new.position,new.accuracy_metres,new.captured_at,true);
  return new;
end $$;
create trigger copy_on_duty_rider_location after insert or update of position,captured_at on public.rider_presence
for each row execute function public.copy_on_duty_rider_location();
insert into public.rider_location_latest(user_id,partner_id,position,accuracy_metres,captured_at,received_at,
  previous_position,previous_accuracy_metres,previous_captured_at,on_duty)
select user_id,partner_id,position,accuracy_metres,captured_at,received_at,
  previous_position,previous_accuracy_metres,previous_captured_at,true from public.rider_presence
on conflict(user_id) do nothing;

-- The native token is position-only, bound to the rider's current session and
-- company. Reopening the app renews it; revoking access invalidates it.
create or replace function public.issue_rider_tracking_token() returns text
language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_token text;v_session uuid;
begin
  if not public.rider_session_active() then raise insufficient_privilege using message='Active rider access required'; end if;
  v_session:=(auth.jwt()->>'session_id')::uuid;
  perform pg_catalog.pg_advisory_xact_lock(726318,pg_catalog.hashtext(auth.uid()::text));
  delete from public.rider_tracking_grants where user_id=auth.uid();
  v_token:=encode(extensions.gen_random_bytes(32),'hex');
  insert into public.rider_tracking_grants(token_hash,user_id,session_id,expires_at)
  values(extensions.digest(v_token,'sha256'),auth.uid(),v_session,clock_timestamp()+interval '7 days');
  return v_token;
end $$;

create function public.native_rider_token_identity(p_token text)
returns table(rider_id uuid,partner_id uuid) language sql security definer set search_path=pg_catalog,public,auth,extensions as $$
  select g.user_id,c.partner_id from public.rider_tracking_grants g
  join public.rider_credentials c on c.user_id=g.user_id and c.revoked_at is null and c.password_revoked_at is null
  join public.company_riders r on r.id=c.roster_id and r.status='approved'
  join public.logistics_partners p on p.id=c.partner_id and p.status='active'
  join public.partner_users pu on pu.user_id=g.user_id and pu.partner_id=c.partner_id and pu.membership_role='rider'
  join auth.sessions s on s.id=g.session_id and s.user_id=g.user_id
  where p_token ~ '^[0-9a-f]{64}$' and g.token_hash=extensions.digest(p_token,'sha256')
    and g.revoked_at is null and g.expires_at>clock_timestamp() and public.has_role(g.user_id,'rider');
$$;
revoke all on function public.native_rider_token_identity(text) from public,anon,authenticated;

create function public.set_native_rider_duty(p_token text,p_on_duty boolean)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_rider uuid;
begin
  select rider_id into v_rider from public.native_rider_token_identity(p_token);
  if v_rider is null then raise insufficient_privilege using message='Phone tracking access ended'; end if;
  if not coalesce(p_on_duty,false) then
    perform 1 from public.rider_credentials where user_id=v_rider for update;
    delete from public.rider_presence where user_id=v_rider;
    update public.rider_location_latest set on_duty=false where user_id=v_rider;
  end if;
  return true;
end $$;
revoke all on function public.set_native_rider_duty(text,boolean) from public,authenticated;
grant execute on function public.set_native_rider_duty(text,boolean) to anon;

create function public.report_native_off_duty_position(p_token text,p_latitude double precision,
  p_longitude double precision,p_accuracy_metres double precision,p_captured_at timestamptz)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_rider uuid;v_partner uuid;
begin
  select rider_id,partner_id into v_rider,v_partner from public.native_rider_token_identity(p_token);
  if v_rider is null then raise insufficient_privilege using message='Phone tracking access ended'; end if;
  if p_latitude is null or p_latitude not between -90 and 90 or p_longitude is null or p_longitude not between -180 and 180
    or p_accuracy_metres is null or p_accuracy_metres not between 0 and 100
    or p_captured_at is null or p_captured_at<clock_timestamp()-interval '60 seconds'
    or p_captured_at>clock_timestamp()+interval '5 seconds' then
    raise check_violation using message='A fresh GPS reading accurate to 100 metres or better is required'; end if;
  perform 1 from public.rider_credentials where user_id=v_rider for update;
  if exists(select 1 from public.rider_presence where user_id=v_rider and received_at>clock_timestamp()-interval '2 minutes') then
    raise check_violation using message='Switch off duty before reporting an off-duty location';
  end if;
  perform public.save_rider_location_latest(v_rider,v_partner,
    extensions.st_setsrid(extensions.st_makepoint(p_longitude,p_latitude),4326)::extensions.geography,
    p_accuracy_metres,p_captured_at,false);
  return true;
end $$;
revoke all on function public.report_native_off_duty_position(text,double precision,double precision,double precision,timestamptz) from public,authenticated;
grant execute on function public.report_native_off_duty_position(text,double precision,double precision,double precision,timestamptz) to anon;

-- Reuse the existing customer authorization and rolling two-per-hour quota.
-- Only its location source changes; dispatch matching still reads rider_presence.
do $$ declare v_signature text;v_definition text; begin
  foreach v_signature in array array['public.get_my_delivery_tracking(uuid)',
    'public.claim_my_rider_location_check(uuid)'] loop
    v_definition:=pg_get_functiondef(v_signature::regprocedure);
    v_definition:=replace(v_definition,'public.rider_presence%rowtype','public.rider_location_latest%rowtype');
    v_definition:=replace(v_definition,'public.rider_presence rp','public.rider_location_latest rp');
    execute v_definition;
  end loop;
end $$;

create function public.list_company_rider_locations(p_partner_id uuid)
returns table(rider_id uuid,rider_name text,latitude double precision,longitude double precision,
  accuracy_metres double precision,captured_at timestamptz,on_duty boolean,is_fresh boolean)
language plpgsql stable security definer set search_path=pg_catalog,public,extensions as $$
begin
  if auth.uid() is null or not public.company_staff_allowed(p_partner_id,'riders') then
    raise insufficient_privilege using message='Company rider access required'; end if;
  return query select c.id,c.full_name,
    case when l.received_at>clock_timestamp()-interval '1 day' then extensions.st_y(l.position::extensions.geometry) end,
    case when l.received_at>clock_timestamp()-interval '1 day' then extensions.st_x(l.position::extensions.geometry) end,
    case when l.received_at>clock_timestamp()-interval '1 day' then l.accuracy_metres end,
    case when l.received_at>clock_timestamp()-interval '1 day' then l.captured_at end,
    coalesce(l.on_duty and rp.received_at>clock_timestamp()-interval '2 minutes',false),
    coalesce(l.received_at>clock_timestamp()-interval '2 minutes' and l.captured_at>clock_timestamp()-interval '2 minutes',false)
  from public.company_riders c
  left join public.rider_credentials rc on rc.roster_id=c.id and rc.revoked_at is null and rc.password_revoked_at is null
  left join public.rider_location_latest l on l.user_id=rc.user_id and l.partner_id=c.partner_id
  left join public.rider_presence rp on rp.user_id=rc.user_id
  where c.partner_id=p_partner_id and c.status='approved'
  order by c.full_name;
end $$;
revoke all on function public.list_company_rider_locations(uuid) from public,anon;
grant execute on function public.list_company_rider_locations(uuid) to authenticated;
