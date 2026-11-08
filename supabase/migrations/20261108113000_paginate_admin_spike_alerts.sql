-- Return only the requested alert page while keeping a complete active count
-- for the alarm and banner. The existing snapshot RPC remains compatible.
create function public.admin_traffic_spike_snapshot_page(p_page integer default 1,p_page_size integer default 8)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_base jsonb;v_total bigint;v_active bigint;v_alerts jsonb;
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  if p_page is null or p_page<1 or p_page>100000 or p_page_size is null or p_page_size<1 or p_page_size>20 then
    raise check_violation using message='Invalid alert page';
  end if;
  v_base:=public.admin_traffic_spike_snapshot();
  select count(*) filter(where a.resolved_at is null and ack.acknowledged_at is null),count(*)
    into v_active,v_total from public.admin_traffic_alerts a
    left join public.admin_traffic_acknowledgements ack
      on ack.alert_id=a.id and ack.user_id=auth.uid()
    where a.resolved_at is null or a.resolved_at>now()-interval '24 hours';
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',a.id,'severity',a.severity,'source',a.source,'cause',a.cause,
    'observed',a.observed,'baseline',a.baseline,'threshold',a.threshold,
    'detected_at',a.detected_at,'resolved_at',a.resolved_at,
    'acknowledged_at',ack.acknowledged_at) order by a.detected_at desc),'[]'::jsonb)
    into v_alerts from (
      select * from public.admin_traffic_alerts
      where resolved_at is null or resolved_at>now()-interval '24 hours'
      order by detected_at desc,id desc limit p_page_size offset (p_page-1)*p_page_size
    ) a left join public.admin_traffic_acknowledgements ack
      on ack.alert_id=a.id and ack.user_id=auth.uid();
  return v_base||jsonb_build_object('alerts',v_alerts,'alerts_total',v_total,
    'active_alerts_total',v_active,'alerts_page',p_page,'alerts_page_size',p_page_size);
end $$;
revoke all on function public.admin_traffic_spike_snapshot_page(integer,integer) from public,anon,authenticated;
grant execute on function public.admin_traffic_spike_snapshot_page(integer,integer) to authenticated;
