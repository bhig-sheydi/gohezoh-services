-- A short critical spike must still reach a phone whose 15-minute Android check
-- ran after the incident resolved. Keep the delivery window bounded and per-device
-- acknowledgements intact; this does not create extra polling or traffic.
create or replace function public.admin_poll_alarm_device(p_device_id uuid,p_secret text,
  p_ack_ids uuid[] default '{}'::uuid[]) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_device public.admin_alarm_devices%rowtype;v_alerts jsonb;v_now timestamptz:=now();
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Alarm worker access required';
  end if;
  if p_device_id is null or p_secret is null or p_secret !~ '^[A-Za-z0-9_-]{43}$'
      or p_ack_ids is null or array_length(p_ack_ids,1)>20 then
    return jsonb_build_object('error','unauthorized');
  end if;
  select * into v_device from public.admin_alarm_devices
    where device_id=p_device_id for update;
  if not found or v_device.revoked_at is not null or v_device.secret_hash is null
    or v_device.secret_hash<>extensions.digest(p_secret,'sha256') then
    return jsonb_build_object('error','unauthorized');
  end if;
  if not public.has_role(v_device.user_id,'admin') then
    update public.admin_alarm_devices set revoked_at=v_now,secret_hash=null
      where device_id=p_device_id;
    return jsonb_build_object('error','revoked');
  end if;
  if v_device.last_poll_at is not null and v_device.last_poll_at>v_now-interval '30 seconds' then
    return jsonb_build_object('error','rate_limited');
  end if;
  update public.admin_alarm_devices set last_poll_at=v_now where device_id=p_device_id;
  insert into public.admin_alarm_acknowledgements(device_id,event_id)
    select p_device_id,x.event_id from unnest(p_ack_ids) as x(event_id)
    where exists(select 1 from public.admin_alarm_margin_events m where m.id=x.event_id)
      or exists(select 1 from public.admin_traffic_alerts a
        where md5(a.id::text||':'||a.severity)::uuid=x.event_id)
    on conflict do nothing;
  perform public.admin_alarm_current_margin();
  with pending as (
    select md5(a.id::text||':'||a.severity)::uuid as id,
      'spike'::text as type,a.severity,
      case when a.resolved_at is null then 'Kwik-Parsel service spike'
        else 'Kwik-Parsel service spike (resolved)' end as title,
      left(a.source||': '||case when a.resolved_at is null then a.cause
        else 'This critical spike has resolved. '||a.cause end,220) as body,
      coalesce(a.resolved_at,a.detected_at) as detected_at
    from public.admin_traffic_alerts a
    where (a.resolved_at is null
        or (a.severity='critical' and a.resolved_at>=v_now-interval '1 hour'))
      and not exists(select 1 from public.admin_alarm_acknowledgements ack
        where ack.device_id=p_device_id
          and ack.event_id=md5(a.id::text||':'||a.severity)::uuid)
      and not exists(select 1 from public.admin_traffic_acknowledgements ack
        where ack.user_id=v_device.user_id and ack.alert_id=a.id)
    union all
    select m.id,'margin'::text,'critical'::text,
      'Kwik-Parsel spending warning'::text,
      'Estimated profit margin is '||m.margin_percent||'%, at or below the 10% warning level.',
      m.detected_at
    from public.admin_alarm_margin_events m
    where exists(select 1 from public.admin_alarm_margin_state s
      where s.alarm_day=m.alarm_day and s.below_threshold)
      and m.id=(select latest.id from public.admin_alarm_margin_events latest
        where latest.alarm_day=m.alarm_day order by latest.detected_at desc limit 1)
      and m.detected_at>=v_now-interval '24 hours'
      and not exists(select 1 from public.admin_alarm_acknowledgements ack
        where ack.device_id=p_device_id and ack.event_id=m.id)
  )
  select coalesce(jsonb_agg(to_jsonb(q) order by q.detected_at desc),'[]'::jsonb)
    into v_alerts from (select * from pending order by detected_at desc,id desc limit 20) q;
  return jsonb_build_object('alerts',v_alerts,'checked_at',v_now);
end $$;
revoke all on function public.admin_poll_alarm_device(uuid,text,uuid[]) from public,anon,authenticated;
grant execute on function public.admin_poll_alarm_device(uuid,text,uuid[]) to service_role;
