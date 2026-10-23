-- A phone foreground service has a short-lived, position-only credential.
-- It never receives the rider's Supabase refresh token or a service-role key.
create table public.rider_tracking_grants (
  token_hash bytea primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null,
  issued_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  constraint rider_tracking_grants_expiry check (expires_at>issued_at)
);
create index rider_tracking_grants_user on public.rider_tracking_grants(user_id);
alter table public.rider_tracking_grants enable row level security;
revoke all on public.rider_tracking_grants from public,anon,authenticated;

create function public.issue_rider_tracking_token() returns text
language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_token text; v_session uuid;
begin
  if not public.rider_session_active() then
    raise insufficient_privilege using message='Active rider access required';
  end if;
  v_session:=(auth.jwt()->>'session_id')::uuid;
  perform 1 from public.rider_credentials where user_id=auth.uid() for update;
  delete from public.rider_tracking_grants where user_id=auth.uid();
  v_token:=encode(extensions.gen_random_bytes(32),'hex');
  insert into public.rider_tracking_grants(token_hash,user_id,session_id,expires_at)
  values(extensions.digest(v_token,'sha256'),auth.uid(),v_session,clock_timestamp()+interval '16 hours');
  return v_token;
end $$;
revoke all on function public.issue_rider_tracking_token() from public,anon;
grant execute on function public.issue_rider_tracking_token() to authenticated;

create function public.report_native_rider_position(p_token text,p_latitude double precision,
  p_longitude double precision,p_accuracy_metres double precision,p_captured_at timestamptz)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_rider uuid;v_partner uuid;v_previous public.rider_presence%rowtype;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise insufficient_privilege using message='Phone tracking access ended';
  end if;
  select g.user_id,c.partner_id into v_rider,v_partner
    from public.rider_tracking_grants g
    join public.rider_credentials c on c.user_id=g.user_id and c.revoked_at is null and c.password_revoked_at is null
    join public.company_riders r on r.id=c.roster_id and r.status='approved'
    join public.logistics_partners p on p.id=c.partner_id and p.status='active'
    join public.partner_users pu on pu.user_id=g.user_id and pu.partner_id=c.partner_id and pu.membership_role='rider'
    join auth.sessions s on s.id=g.session_id and s.user_id=g.user_id
    where g.token_hash=extensions.digest(p_token,'sha256') and g.revoked_at is null
      and g.expires_at>clock_timestamp() for update of g;
  if v_rider is null then raise insufficient_privilege using message='Phone tracking access ended'; end if;
  if p_latitude is null or p_latitude not between -90 and 90
    or p_longitude is null or p_longitude not between -180 and 180
    or p_accuracy_metres is null or p_accuracy_metres not between 0 and 100
    or p_captured_at is null or p_captured_at<clock_timestamp()-interval '60 seconds'
    or p_captured_at>clock_timestamp()+interval '5 seconds' then
    raise check_violation using message='A fresh GPS reading accurate to 100 metres or better is required';
  end if;
  perform 1 from public.rider_credentials where user_id=v_rider for update;
  select * into v_previous from public.rider_presence where user_id=v_rider;
  if found and (v_previous.received_at>clock_timestamp()-interval '15 seconds'
    or v_previous.captured_at>=p_captured_at) then return false; end if;
  insert into public.rider_presence(user_id,partner_id,position,accuracy_metres,captured_at)
  values(v_rider,v_partner,extensions.st_setsrid(extensions.st_makepoint(p_longitude,p_latitude),4326)::extensions.geography,
    p_accuracy_metres,p_captured_at)
  on conflict(user_id) do update set partner_id=excluded.partner_id,position=excluded.position,
    accuracy_metres=excluded.accuracy_metres,captured_at=excluded.captured_at,received_at=clock_timestamp();
  return true;
end $$;
revoke all on function public.report_native_rider_position(text,double precision,double precision,double precision,timestamptz) from public;
grant execute on function public.report_native_rider_position(text,double precision,double precision,double precision,timestamptz) to anon,authenticated;

create function public.revoke_rider_tracking_token(p_token text) returns void
language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_rider uuid;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return; end if;
  update public.rider_tracking_grants set revoked_at=clock_timestamp()
    where token_hash=extensions.digest(p_token,'sha256') and revoked_at is null returning user_id into v_rider;
  if v_rider is not null then delete from public.rider_presence where user_id=v_rider; end if;
end $$;
revoke all on function public.revoke_rider_tracking_token(text) from public;
grant execute on function public.revoke_rider_tracking_token(text) to anon,authenticated;
