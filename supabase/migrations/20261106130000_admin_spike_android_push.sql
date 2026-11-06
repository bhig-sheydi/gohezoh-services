-- Push only newly detected incidents, and retry individual device deliveries.
-- Disabled until an Android Firebase app and server credential are installed.
create table public.admin_spike_push_config (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into public.admin_spike_push_config(singleton) values(true);
create table public.admin_spike_push_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  fcm_token text not null unique check (length(fcm_token) between 30 and 4096),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique(user_id,device_id)
);
create table public.admin_spike_push_deliveries (
  id uuid primary key default gen_random_uuid(),
  alert_id uuid not null references public.admin_traffic_alerts(id) on delete cascade,
  device_id uuid not null references public.admin_spike_push_devices(id) on delete cascade,
  severity text not null check (severity in ('warning','critical')),
  status text not null default 'pending' check (status in ('pending','sending','sent','dead')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  leased_until timestamptz,
  last_error_code text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  unique(alert_id,device_id,severity)
);
create index admin_spike_push_due_idx on public.admin_spike_push_deliveries(next_attempt_at)
  where status in ('pending','sending');
alter table public.admin_spike_push_config enable row level security;
alter table public.admin_spike_push_devices enable row level security;
alter table public.admin_spike_push_deliveries enable row level security;
revoke all on public.admin_spike_push_config,public.admin_spike_push_devices,
  public.admin_spike_push_deliveries from public,anon,authenticated;

create function public.admin_spike_push_configuration() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_enabled boolean;
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  select enabled into v_enabled from public.admin_spike_push_config where singleton;
  return jsonb_build_object('enabled',coalesce(v_enabled,false));
end $$;
revoke all on function public.admin_spike_push_configuration() from public,anon,authenticated;
grant execute on function public.admin_spike_push_configuration() to authenticated;

create function public.admin_register_spike_push_device(p_device_id uuid,p_token text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_token text:=btrim(p_token);
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  if p_device_id is null or v_token is null or length(v_token) not between 30 and 4096 then
    raise check_violation using message='Invalid phone notification registration';
  end if;
  delete from public.admin_spike_push_devices
    where user_id=auth.uid() and device_id=p_device_id and fcm_token<>v_token;
  insert into public.admin_spike_push_devices(user_id,device_id,fcm_token)
    values(auth.uid(),p_device_id,v_token)
  on conflict(fcm_token) do update set user_id=excluded.user_id,
    device_id=excluded.device_id,last_seen_at=now();
end $$;
revoke all on function public.admin_register_spike_push_device(uuid,text) from public,anon,authenticated;
grant execute on function public.admin_register_spike_push_device(uuid,text) to authenticated;

create function public.admin_unregister_spike_push_device(p_device_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  delete from public.admin_spike_push_devices
    where user_id=auth.uid() and device_id=p_device_id;
end $$;
revoke all on function public.admin_unregister_spike_push_device(uuid) from public,anon,authenticated;
grant execute on function public.admin_unregister_spike_push_device(uuid) to authenticated;

create function public.enqueue_admin_spike_push() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if tg_op='UPDATE' and (new.severity<>'critical' or old.severity='critical') then return new; end if;
  if not exists(select 1 from public.admin_spike_push_config where singleton and enabled) then return new; end if;
  insert into public.admin_spike_push_deliveries(alert_id,device_id,severity)
  select new.id,d.id,new.severity from public.admin_spike_push_devices d
    where d.last_seen_at>now()-interval '30 days'
      and public.has_role(d.user_id,'admin')
  on conflict(alert_id,device_id,severity) do nothing;
  return new;
end $$;
revoke all on function public.enqueue_admin_spike_push() from public,anon,authenticated;
create trigger admin_spike_alert_enqueue_push
  after insert or update of severity on public.admin_traffic_alerts
  for each row execute function public.enqueue_admin_spike_push();

create function public.claim_admin_spike_push_deliveries(p_limit integer default 20)
returns table(delivery_id uuid,alert_id uuid,device_token text,severity text,source text,cause text)
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Push worker access required';
  end if;
  if p_limit is null or p_limit<1 or p_limit>50 then
    raise check_violation using message='Invalid push batch size';
  end if;
  return query
    with due as (
      select x.id from public.admin_spike_push_deliveries x
      join public.admin_spike_push_devices d on d.id=x.device_id
      where (x.status='pending' and x.next_attempt_at<=now()
          or x.status='sending' and x.leased_until<now())
        and d.last_seen_at>now()-interval '30 days'
        and public.has_role(d.user_id,'admin')
      order by x.next_attempt_at,x.created_at
      limit p_limit for update of x skip locked
    ), claimed as (
      update public.admin_spike_push_deliveries x
      set status='sending',attempts=x.attempts+1,leased_until=now()+interval '2 minutes'
      from due where x.id=due.id
      returning x.id,x.alert_id,x.device_id,x.severity
    )
    select c.id,c.alert_id,d.fcm_token,c.severity,a.source,a.cause
      from claimed c join public.admin_spike_push_devices d on d.id=c.device_id
      join public.admin_traffic_alerts a on a.id=c.alert_id;
end $$;
revoke all on function public.claim_admin_spike_push_deliveries(integer) from public,anon,authenticated;
grant execute on function public.claim_admin_spike_push_deliveries(integer) to service_role;

create function public.finish_admin_spike_push_delivery(
  p_delivery_id uuid,p_sent boolean,p_error_code text default null,p_invalid_token boolean default false
) returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_delivery public.admin_spike_push_deliveries%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Push worker access required';
  end if;
  select * into v_delivery from public.admin_spike_push_deliveries
    where id=p_delivery_id for update;
  if not found or v_delivery.status<>'sending' then return; end if;
  update public.admin_spike_push_deliveries set
    status=case when p_sent then 'sent'
      when p_invalid_token or attempts>=5 then 'dead' else 'pending' end,
    next_attempt_at=case when p_sent then next_attempt_at
      else now()+make_interval(secs=>least(3600,30*(2^least(attempts,6))::integer)) end,
    leased_until=null,last_error_code=case when p_sent then null else left(coalesce(p_error_code,'send_failed'),80) end,
    sent_at=case when p_sent then now() else sent_at end
    where id=p_delivery_id;
  if p_invalid_token then
    delete from public.admin_spike_push_devices where id=v_delivery.device_id;
  end if;
end $$;
revoke all on function public.finish_admin_spike_push_delivery(uuid,boolean,text,boolean)
  from public,anon,authenticated;
grant execute on function public.finish_admin_spike_push_delivery(uuid,boolean,text,boolean)
  to service_role;

create function public.invoke_due_admin_spike_push() returns void
language plpgsql security definer set search_path=pg_catalog,public,net,vault as $$
declare v_secret text;
begin
  if not exists(select 1 from public.admin_spike_push_config where singleton and enabled) then return; end if;
  if not exists(select 1 from public.admin_spike_push_deliveries
    where status='pending' and next_attempt_at<=now()
       or status='sending' and leased_until<now()) then return; end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets
    where name='admin_spike_push_secret' order by created_at desc limit 1;
  if v_secret is null then raise exception 'Admin spike push worker secret is not configured'; end if;
  perform net.http_post(
    url:='https://yejiqfocqmdxjeajoexd.supabase.co/functions/v1/admin-spike-push',
    headers:=jsonb_build_object('Content-Type','application/json','x-admin-spike-secret',v_secret),
    body:='{}'::jsonb,timeout_milliseconds:=10000
  );
end $$;
revoke all on function public.invoke_due_admin_spike_push() from public,anon,authenticated;
select cron.schedule('kwik-parsel-admin-spike-push','* * * * *',
  'select public.invoke_due_admin_spike_push()');

-- Prune stale tokens and delivery history during the existing quiet period.
create function public.prune_admin_spike_push() returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  delete from public.admin_spike_push_devices where last_seen_at<now()-interval '30 days';
  delete from public.admin_spike_push_deliveries where status in ('sent','dead')
    and created_at<now()-interval '30 days';
end $$;
revoke all on function public.prune_admin_spike_push() from public,anon,authenticated;
select cron.schedule('kwik-parsel-prune-admin-spike-push','40 3 * * *',
  'select public.prune_admin_spike_push()');
