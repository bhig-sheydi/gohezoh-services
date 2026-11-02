create table public.company_rider_location_request_cooldowns (
  rider_id uuid primary key references auth.users(id) on delete cascade,
  last_requested_at timestamptz not null
);
alter table public.company_rider_location_request_cooldowns enable row level security;
revoke all on public.company_rider_location_request_cooldowns from public,anon,authenticated;

create or replace function public.request_company_rider_location(p_partner_id uuid,p_roster_id uuid)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_rider uuid;v_last timestamptz;v_existing uuid;
begin
  if auth.uid() is null or not public.company_staff_allowed(p_partner_id,'riders') then
    raise insufficient_privilege using message='Company rider access required'; end if;
  select c.user_id into v_rider from public.rider_credentials c
    join public.company_riders r on r.id=c.roster_id and r.partner_id=p_partner_id and r.status='approved'
    where c.roster_id=p_roster_id and c.partner_id=p_partner_id and c.revoked_at is null and c.password_revoked_at is null;
  if v_rider is null then raise insufficient_privilege using message='Approved company rider required'; end if;
  perform pg_catalog.pg_advisory_xact_lock(726319,pg_catalog.hashtext(v_rider::text));
  select last_requested_at into v_last from public.company_rider_location_request_cooldowns where rider_id=v_rider;
  select request_id into v_existing from public.rider_location_requests where rider_id=v_rider and expires_at>clock_timestamp();
  if v_last>clock_timestamp()-interval '5 minutes' then
    if v_existing is not null then return v_existing; end if;
    raise check_violation using message='Wait five minutes before requesting this rider again';
  end if;
  insert into public.company_rider_location_request_cooldowns(rider_id,last_requested_at)
    values(v_rider,clock_timestamp()) on conflict(rider_id) do update set last_requested_at=excluded.last_requested_at;
  if v_existing is not null then return v_existing; end if;
  return public.queue_rider_location_request(v_rider);
end $$;
