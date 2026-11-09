-- Deliver the 10% margin crossing through the same FCM queue as traffic spikes.
alter table public.admin_spike_push_deliveries
  alter column alert_id drop not null,
  add column margin_event_id uuid references public.admin_alarm_margin_events(id) on delete cascade,
  add constraint admin_push_one_event check ((alert_id is null) <> (margin_event_id is null));
create unique index admin_margin_push_once_idx on public.admin_spike_push_deliveries(margin_event_id,device_id)
  where margin_event_id is not null;

create function public.enqueue_admin_margin_push() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not exists(select 1 from public.admin_spike_push_config where singleton and enabled) then return new; end if;
  insert into public.admin_spike_push_deliveries(margin_event_id,device_id,severity)
  select new.id,d.id,'critical' from public.admin_spike_push_devices d
    where d.last_seen_at>now()-interval '30 days' and public.has_role(d.user_id,'admin')
  on conflict do nothing;
  return new;
end $$;
revoke all on function public.enqueue_admin_margin_push() from public,anon,authenticated;
create trigger admin_margin_event_enqueue_push after insert on public.admin_alarm_margin_events
  for each row execute function public.enqueue_admin_margin_push();

drop function public.claim_admin_spike_push_deliveries(integer);
create function public.claim_admin_spike_push_deliveries(p_limit integer default 20)
returns table(delivery_id uuid,alert_id uuid,device_token text,severity text,source text,cause text,event_type text)
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
      returning x.id,x.alert_id,x.margin_event_id,x.device_id,x.severity
    )
    select c.id,coalesce(c.alert_id,c.margin_event_id),d.fcm_token,c.severity,
      coalesce(a.source,'margin threshold')::text,
      coalesce(a.cause,'Estimated operating margin reached 10%')::text,
      case when c.margin_event_id is null then 'spike' else 'margin' end::text
    from claimed c join public.admin_spike_push_devices d on d.id=c.device_id
      left join public.admin_traffic_alerts a on a.id=c.alert_id;
end $$;
revoke all on function public.claim_admin_spike_push_deliveries(integer) from public,anon,authenticated;
grant execute on function public.claim_admin_spike_push_deliveries(integer) to service_role;
