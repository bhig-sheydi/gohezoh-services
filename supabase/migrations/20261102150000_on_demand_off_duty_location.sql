-- One pending request per rider; no location trail or continuous off-duty writes.
create table public.rider_location_requests (
  rider_id uuid primary key references auth.users(id) on delete cascade,
  request_id uuid not null default extensions.gen_random_uuid(),
  requested_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null default clock_timestamp()+interval '10 minutes'
);
alter table public.rider_location_requests enable row level security;
revoke all on public.rider_location_requests from public,anon,authenticated;

create table public.customer_rider_location_requests (
  user_id uuid primary key references auth.users(id) on delete cascade,
  requested_at timestamptz[] not null default '{}'
);
alter table public.customer_rider_location_requests enable row level security;
revoke all on public.customer_rider_location_requests from public,anon,authenticated;

create function public.queue_rider_location_request(p_rider_id uuid)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_id uuid;
begin
  if p_rider_id is null then raise check_violation using message='Rider required'; end if;
  insert into public.rider_location_requests(rider_id) values(p_rider_id)
  on conflict(rider_id) do update set request_id=case
      when rider_location_requests.expires_at<clock_timestamp() then extensions.gen_random_uuid()
      else rider_location_requests.request_id end,
    requested_at=case when rider_location_requests.expires_at<clock_timestamp() then clock_timestamp()
      else rider_location_requests.requested_at end,
    expires_at=case when rider_location_requests.expires_at<clock_timestamp() then clock_timestamp()+interval '10 minutes'
      else rider_location_requests.expires_at end
  returning request_id into v_id;
  return v_id;
end $$;
revoke all on function public.queue_rider_location_request(uuid) from public,anon,authenticated;

create function public.request_company_rider_location(p_partner_id uuid,p_roster_id uuid)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_rider uuid;v_last timestamptz;
begin
  if auth.uid() is null or not public.company_staff_allowed(p_partner_id,'riders') then
    raise insufficient_privilege using message='Company rider access required'; end if;
  select c.user_id into v_rider from public.rider_credentials c
    join public.company_riders r on r.id=c.roster_id and r.partner_id=p_partner_id and r.status='approved'
    where c.roster_id=p_roster_id and c.partner_id=p_partner_id and c.revoked_at is null and c.password_revoked_at is null;
  if v_rider is null then raise insufficient_privilege using message='Approved company rider required'; end if;
  perform pg_catalog.pg_advisory_xact_lock(726319,pg_catalog.hashtext(v_rider::text));
  select requested_at into v_last from public.rider_location_requests where rider_id=v_rider;
  if v_last>clock_timestamp()-interval '5 minutes' then
    return (select request_id from public.rider_location_requests where rider_id=v_rider);
  end if;
  delete from public.rider_location_requests where rider_id=v_rider;
  return public.queue_rider_location_request(v_rider);
end $$;
revoke all on function public.request_company_rider_location(uuid,uuid) from public,anon;
grant execute on function public.request_company_rider_location(uuid,uuid) to authenticated;

create function public.request_customer_rider_location(p_job_id uuid)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_rider uuid;v_recent timestamptz[];v_now timestamptz:=clock_timestamp();
begin
  if auth.uid() is null then raise insufficient_privilege using message='Sign in required'; end if;
  select j.assigned_rider_id into v_rider from public.jobs j
    join public.orders o on o.id=j.order_id
    where j.id=p_job_id and public.is_customer_user(j.customer_id)
      and j.status not in ('delivered','closed','cancelled') and j.assigned_rider_id is not null
      and (exists(select 1 from public.customer_payment_holds h where h.request_id=o.service_request_id and h.status='paid')
        or exists(select 1 from public.customer_payments cp where cp.job_id=j.id and cp.status='received'));
  if v_rider is null then raise insufficient_privilege using message='Paid active delivery required'; end if;
  insert into public.customer_rider_location_requests(user_id) values(auth.uid()) on conflict do nothing;
  perform 1 from public.customer_rider_location_requests where user_id=auth.uid() for update;
  select coalesce(array_agg(t.at order by t.at),'{}'::timestamptz[]) into v_recent
    from public.customer_rider_location_requests c,unnest(c.requested_at) t(at)
    where c.user_id=auth.uid() and t.at>v_now-interval '1 hour';
  if cardinality(v_recent)>=2 then raise check_violation using message='Two location requests allowed per hour'; end if;
  update public.customer_rider_location_requests set requested_at=array_append(v_recent,v_now) where user_id=auth.uid();
  return public.queue_rider_location_request(v_rider);
end $$;
revoke all on function public.request_customer_rider_location(uuid) from public,anon;
grant execute on function public.request_customer_rider_location(uuid) to authenticated;

create function public.poll_native_rider_location_request(p_token text)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_rider uuid;
begin
  select rider_id into v_rider from public.native_rider_token_identity(p_token);
  if v_rider is null then raise insufficient_privilege using message='Phone tracking access ended'; end if;
  update public.rider_tracking_grants g set expires_at=clock_timestamp()+interval '7 days'
    where g.user_id=v_rider and g.token_hash=extensions.digest(p_token,'sha256')
      and g.revoked_at is null and g.expires_at>clock_timestamp()
      and g.expires_at<clock_timestamp()+interval '3 days';
  return (select request_id from public.rider_location_requests
    where rider_id=v_rider and expires_at>clock_timestamp());
end $$;
revoke all on function public.poll_native_rider_location_request(text) from public,authenticated;
grant execute on function public.poll_native_rider_location_request(text) to anon;

create function public.report_native_requested_position(p_token text,p_request_id uuid,
  p_latitude double precision,p_longitude double precision,p_accuracy_metres double precision,p_captured_at timestamptz)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_rider uuid;
begin
  select rider_id into v_rider from public.native_rider_token_identity(p_token);
  if v_rider is null then raise insufficient_privilege using message='Phone tracking access ended'; end if;
  perform 1 from public.rider_location_requests where rider_id=v_rider and request_id=p_request_id
    and expires_at>clock_timestamp() for update;
  if not found then raise check_violation using message='Location request expired'; end if;
  perform public.report_native_off_duty_position(p_token,p_latitude,p_longitude,p_accuracy_metres,p_captured_at);
  delete from public.rider_location_requests where rider_id=v_rider and request_id=p_request_id;
  return true;
end $$;
revoke all on function public.report_native_requested_position(text,uuid,double precision,double precision,double precision,timestamptz) from public,authenticated;
grant execute on function public.report_native_requested_position(text,uuid,double precision,double precision,double precision,timestamptz) to anon;
