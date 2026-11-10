-- FCM ride alerts use the existing Firebase credential and worker secret, but a separate queue.
create table public.ride_push_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  fcm_token text not null unique check (length(fcm_token) between 30 and 4096),
  kind text not null check (kind in ('customer','company','rider')),
  session_id uuid not null,
  last_seen_at timestamptz not null default now(),
  unique(user_id,device_id)
);
create table public.ride_push_deliveries (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null default gen_random_uuid(),
  device_id uuid not null references public.ride_push_devices(id) on delete cascade,
  event_type text not null check (event_type in ('company_invitation','rider_assignment','customer_match')),
  source_id uuid not null,
  status text not null default 'pending' check (status in ('pending','sending','sent','dead')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  expires_at timestamptz not null,
  leased_until timestamptz,
  sent_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  unique(device_id,event_type,source_id)
);
create index ride_push_due_idx on public.ride_push_deliveries(next_attempt_at)
  where status in ('pending','sending');
alter table public.ride_push_devices enable row level security;
alter table public.ride_push_deliveries enable row level security;
revoke all on public.ride_push_devices,public.ride_push_deliveries from public,anon,authenticated;

create function public.register_ride_push_device(p_device_id uuid,p_token text,p_kind text)
returns void language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_session uuid;v_token text:=btrim(p_token);
begin
  if auth.uid() is null or p_device_id is null or length(v_token) not between 30 and 4096
    or p_kind not in ('customer','company','rider') then
    raise check_violation using message='Invalid ride alert registration';
  end if;
  v_session:=(auth.jwt()->>'session_id')::uuid;
  if v_session is null or not exists(select 1 from auth.sessions where id=v_session and user_id=auth.uid()) then
    raise insufficient_privilege using message='An active session is required';
  end if;
  if p_kind='customer' and not exists(select 1 from public.customer_users where user_id=auth.uid()) then
    raise insufficient_privilege using message='Customer access is required';
  elsif p_kind='rider' and not public.rider_session_active() then
    raise insufficient_privilege using message='Rider access is required';
  elsif p_kind='company' and not exists(
    select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
      where pu.user_id=auth.uid() and pu.membership_role='manager' and p.status='active'
    union all
    select 1 from public.company_operations_staff s join public.logistics_partners p on p.id=s.partner_id
      where s.user_id=auth.uid() and s.revoked_at is null and s.password_revoked_at is null
        and s.can_bid and p.status='active'
  ) then raise insufficient_privilege using message='Company bidding access is required';
  end if;
  delete from public.ride_push_devices where user_id=auth.uid() and device_id=p_device_id;
  insert into public.ride_push_devices(user_id,device_id,fcm_token,kind,session_id)
    values(auth.uid(),p_device_id,v_token,p_kind,v_session)
  on conflict(fcm_token) do update set user_id=excluded.user_id,device_id=excluded.device_id,
    kind=excluded.kind,session_id=excluded.session_id,last_seen_at=now();
end $$;
revoke all on function public.register_ride_push_device(uuid,text,text) from public,anon,authenticated;
grant execute on function public.register_ride_push_device(uuid,text,text) to authenticated;

create function public.unregister_ride_push_device(p_device_id uuid) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  delete from public.ride_push_devices where user_id=auth.uid() and device_id=p_device_id;
end $$;
revoke all on function public.unregister_ride_push_device(uuid) from public,anon,authenticated;
grant execute on function public.unregister_ride_push_device(uuid) to authenticated;

create function public.enqueue_company_ride_push() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  -- Invitations may be queued; do not ring before the actual response window.
  insert into public.ride_push_deliveries(device_id,event_type,source_id,next_attempt_at,expires_at)
  select d.id,'company_invitation',new.request_id,greatest(now(),new.starts_at),new.deadline_at
  from public.ride_push_devices d
  where d.kind='company' and d.last_seen_at>now()-interval '30 days'
    and (exists(select 1 from public.partner_users pu where pu.user_id=d.user_id
      and pu.partner_id=new.partner_id and pu.membership_role='manager')
      or exists(select 1 from public.company_operations_staff s where s.user_id=d.user_id
        and s.partner_id=new.partner_id and s.can_bid and s.revoked_at is null and s.password_revoked_at is null))
    and new.deadline_at>now()
  on conflict(device_id,event_type,source_id) do update
    set next_attempt_at=excluded.next_attempt_at,expires_at=excluded.expires_at,
      status=case when public.ride_push_deliveries.status='dead' then 'pending'
        else public.ride_push_deliveries.status end;
  return new;
end $$;
revoke all on function public.enqueue_company_ride_push() from public,anon,authenticated;
create trigger company_ride_push after insert or update of starts_at,deadline_at
  on public.company_bid_invitations for each row execute function public.enqueue_company_ride_push();

create function public.enqueue_customer_match_push() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.status<>'valid' then return new; end if;
  insert into public.ride_push_deliveries(device_id,event_type,source_id,expires_at)
  select d.id,'customer_match',new.request_id,now()+interval '24 hours'
  from public.ride_push_devices d join public.customer_users cu on cu.user_id=d.user_id
    join public.service_requests r on r.customer_id=cu.customer_id and r.id=new.request_id
  where d.kind='customer' and d.last_seen_at>now()-interval '30 days'
    and not exists(select 1 from public.customer_delivery_quotes q where q.request_id=new.request_id)
  on conflict(device_id,event_type,source_id) do nothing;
  return new;
end $$;
revoke all on function public.enqueue_customer_match_push() from public,anon,authenticated;
create trigger customer_match_push after insert on public.partner_quotes
  for each row execute function public.enqueue_customer_match_push();

create function public.enqueue_rider_assignment_push() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.assigned_rider_id is null or new.status in ('delivered','closed','cancelled')
    or (tg_op='UPDATE' and new.assigned_rider_id is not distinct from old.assigned_rider_id) then return new; end if;
  insert into public.ride_push_deliveries(device_id,event_type,source_id,expires_at)
  select d.id,'rider_assignment',new.id,now()+interval '24 hours'
  from public.ride_push_devices d where d.user_id=new.assigned_rider_id and d.kind='rider'
    and d.last_seen_at>now()-interval '30 days'
  on conflict(device_id,event_type,source_id) do nothing;
  return new;
end $$;
revoke all on function public.enqueue_rider_assignment_push() from public,anon,authenticated;
create trigger rider_assignment_push after insert or update of assigned_rider_id on public.jobs
  for each row execute function public.enqueue_rider_assignment_push();

create function public.claim_ride_push_deliveries(p_limit integer default 30)
returns table(delivery_id uuid,event_id uuid,device_token text,event_type text,source_id uuid,expires_at timestamptz,user_id uuid)
language plpgsql security definer set search_path=pg_catalog,public,auth as $$
begin
  if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_limit not between 1 and 100 then raise check_violation; end if;
  update public.ride_push_deliveries x set status='dead' where x.status in ('pending','sending') and x.expires_at<=now();
  return query with due as (
    select x.id from public.ride_push_deliveries x join public.ride_push_devices d on d.id=x.device_id
      join auth.sessions sess on sess.id=d.session_id and sess.user_id=d.user_id
    where (x.status='pending' and x.next_attempt_at<=now() or x.status='sending' and x.leased_until<now())
      and x.expires_at>now() and d.last_seen_at>now()-interval '30 days'
      and (x.event_type<>'company_invitation' or exists(
        select 1 from public.company_bid_invitations i where i.request_id=x.source_id
          and i.starts_at<=now() and i.deadline_at>now()
          and (exists(select 1 from public.partner_users pu where pu.partner_id=i.partner_id
            and pu.user_id=d.user_id and pu.membership_role='manager')
            or exists(select 1 from public.company_operations_staff s where s.partner_id=i.partner_id
              and s.user_id=d.user_id and s.can_bid and s.revoked_at is null and s.password_revoked_at is null))))
      and (x.event_type<>'rider_assignment' or exists(select 1 from public.jobs j
        join public.rider_credentials rc on rc.user_id=j.assigned_rider_id and rc.revoked_at is null
          and rc.password_revoked_at is null
        where j.id=x.source_id and j.assigned_rider_id=d.user_id and j.status not in ('delivered','closed','cancelled')))
      and (x.event_type<>'customer_match' or exists(select 1 from public.service_requests r
        join public.customer_users cu on cu.customer_id=r.customer_id and cu.user_id=d.user_id
        join public.partner_quotes q on q.request_id=r.id and q.status='valid'
        where r.id=x.source_id))
    order by x.next_attempt_at,x.created_at limit p_limit for update of x skip locked
  ), claimed as (
    update public.ride_push_deliveries x set status='sending',attempts=x.attempts+1,
      leased_until=now()+interval '2 minutes' from due where x.id=due.id
    returning x.id,x.event_id,x.device_id,x.event_type,x.source_id,x.expires_at
  ) select c.id,c.event_id,d.fcm_token,c.event_type,c.source_id,c.expires_at,d.user_id
    from claimed c join public.ride_push_devices d on d.id=c.device_id;
end $$;
revoke all on function public.claim_ride_push_deliveries(integer) from public,anon,authenticated;
grant execute on function public.claim_ride_push_deliveries(integer) to service_role;

create function public.finish_ride_push_delivery(p_delivery_id uuid,p_sent boolean,p_error_code text default null,p_invalid_token boolean default false)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_device uuid;
begin
  if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
  select device_id into v_device from public.ride_push_deliveries where id=p_delivery_id and status='sending' for update;
  if v_device is null then return; end if;
  update public.ride_push_deliveries set status=case when p_sent then 'sent'
    when p_invalid_token or attempts>=4 or expires_at<=now() then 'dead' else 'pending' end,
    next_attempt_at=now()+make_interval(secs=>least(180,15*(2^least(attempts,4))::integer)),
    leased_until=null,sent_at=case when p_sent then now() else sent_at end,
    last_error_code=case when p_sent then null else left(coalesce(p_error_code,'send_failed'),80) end
    where id=p_delivery_id;
  if p_invalid_token then delete from public.ride_push_devices where id=v_device; end if;
end $$;
revoke all on function public.finish_ride_push_delivery(uuid,boolean,text,boolean) from public,anon,authenticated;
grant execute on function public.finish_ride_push_delivery(uuid,boolean,text,boolean) to service_role;

create function public.invoke_due_ride_push() returns void
language plpgsql security definer set search_path=pg_catalog,public,net,vault as $$
declare v_secret text;
begin
  if not exists(select 1 from public.ride_push_deliveries where
    status='pending' and next_attempt_at<=now() and expires_at>now()
    or status='sending' and leased_until<now() and expires_at>now()) then return; end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets
    where name='admin_spike_push_secret' order by created_at desc limit 1;
  if v_secret is null then raise exception 'Push worker secret is not configured'; end if;
  perform net.http_post(url:='https://yejiqfocqmdxjeajoexd.supabase.co/functions/v1/ride-event-push',
    headers:=jsonb_build_object('Content-Type','application/json','x-admin-spike-secret',v_secret),
    body:='{}'::jsonb,timeout_milliseconds:=10000);
end $$;
revoke all on function public.invoke_due_ride_push() from public,anon,authenticated;
select cron.schedule('kwik-parsel-ride-event-push','15 seconds','select public.invoke_due_ride_push()');

create function public.prune_ride_push() returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  delete from public.ride_push_devices where last_seen_at<now()-interval '30 days';
  delete from public.ride_push_deliveries where status in ('sent','dead') and created_at<now()-interval '7 days';
end $$;
revoke all on function public.prune_ride_push() from public,anon,authenticated;
select cron.schedule('kwik-parsel-prune-ride-push','35 3 * * *','select public.prune_ride_push()');
