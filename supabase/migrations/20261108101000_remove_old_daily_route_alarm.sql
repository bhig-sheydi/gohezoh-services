-- Remove obsolete fixed daily route-budget alarm after monthly revenue guard.
create or replace function public.sample_admin_traffic_spikes() returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_at timestamptz:=date_trunc('minute',clock_timestamp());
  v_previous public.admin_traffic_samples%rowtype;
  v_stats record;
  v_elapsed numeric;
  v_transactions integer:=0;
  v_fetched integer:=0;
  v_rollbacks integer:=0;
  v_google_today integer:=0;
  v_google_delta integer:=0;
  v_durable integer:=0;
  v_route integer:=0;
  v_dispatch integer:=0;
  v_quotes integer:=0;
  v_baseline record;
begin
  if session_user not in ('postgres','supabase_admin') and auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Traffic sampling is restricted to trusted workers';
  end if;
  if not pg_try_advisory_xact_lock(438769127) then return; end if;
  if exists(select 1 from public.admin_traffic_samples where sampled_at=v_at) then return; end if;

  select * into v_previous from public.admin_traffic_samples order by sampled_at desc limit 1;
  select xact_commit,xact_rollback,tup_fetched,stats_reset into v_stats
    from pg_catalog.pg_stat_database where datname=current_database();
  if not found then raise data_exception using message='Database statistics unavailable'; end if;
  v_elapsed:=extract(epoch from (v_at-v_previous.sampled_at));
  if v_previous.sampled_at is not null and v_elapsed>0
     and v_stats.stats_reset is not distinct from v_previous.stats_reset
     and v_stats.xact_commit>=v_previous.transactions_total
     and v_stats.xact_rollback>=v_previous.rollbacks_total
     and v_stats.tup_fetched>=v_previous.rows_fetched_total then
    v_transactions:=least(2147483647,round((v_stats.xact_commit-v_previous.transactions_total)*60/v_elapsed))::integer;
    v_fetched:=least(2147483647,round((v_stats.tup_fetched-v_previous.rows_fetched_total)*60/v_elapsed))::integer;
    v_rollbacks:=least(2147483647,round((v_stats.xact_rollback-v_previous.rollbacks_total)*60/v_elapsed))::integer;
  end if;
  select coalesce(elements_reserved,0) into v_google_today
    from public.google_route_matrix_daily_budget
    where budget_day=(v_at at time zone 'UTC')::date;
  v_google_today:=coalesce(v_google_today,0);
  if v_previous.sampled_at is not null
     and (v_previous.sampled_at at time zone 'UTC')::date=(v_at at time zone 'UTC')::date
     and v_google_today>=v_previous.google_elements_today then
    v_google_delta:=v_google_today-v_previous.google_elements_today;
  end if;
  -- LIMIT keeps every backlog probe bounded even if a worker stops for hours.
  select count(*) into v_durable from (
    select 1 from public.durable_jobs where status='pending'
      and available_at<v_at-interval '2 minutes' limit 1001) q;
  select count(*) into v_route from (
    select 1 from public.route_planner_events where status='pending'
      and available_at<v_at-interval '2 minutes' limit 1001) q;
  select count(*) into v_dispatch from (
    select 1 from public.dispatch_match_queue
      where next_attempt_at<v_at-interval '2 minutes' limit 1001) q;
  select count(*) into v_quotes from (
    select 1 from public.delivery_quote_windows where status='matching'
      and published_at<v_at-interval '2 minutes' limit 1001) q;

  insert into public.admin_traffic_samples values
    (v_at,v_stats.stats_reset,v_stats.xact_commit,v_stats.tup_fetched,v_stats.xact_rollback,
     v_transactions,v_fetched,v_rollbacks,v_google_today,v_google_delta,
     v_durable,v_route,v_dispatch,v_quotes);
  select coalesce(avg(transactions_per_minute),0) as transactions,
         coalesce(avg(rows_fetched_per_minute),0) as fetched,
         coalesce(avg(rollbacks_per_minute),0) as rollbacks,
         coalesce(avg(google_elements_per_minute),0) as google
    into v_baseline from public.admin_traffic_samples
    where sampled_at>=v_at-interval '30 minutes' and sampled_at<v_at;

  perform public.record_admin_traffic_signal('db_transactions',
    'Database requests rose sharply; inspect busy queries and repeated client refreshes.',
    v_transactions,v_baseline.transactions,
    greatest(600,3*v_baseline.transactions),greatest(1800,6*v_baseline.transactions),v_at);
  perform public.record_admin_traffic_signal('db_rows',
    'Read-heavy queries or repeated data fetches are increasing database work.',
    v_fetched,v_baseline.fetched,
    greatest(300000,3*v_baseline.fetched),greatest(1000000,6*v_baseline.fetched),v_at);
  perform public.record_admin_traffic_signal('db_rollbacks',
    'Failed or rejected database transactions increased; inspect recent errors.',
    v_rollbacks,v_baseline.rollbacks,
    greatest(20,3*v_baseline.rollbacks),greatest(100,6*v_baseline.rollbacks),v_at);
  perform public.record_admin_traffic_signal('google_elements',
    'Google route-matrix requests rose; route planning may be driving map usage.',
    v_google_delta,v_baseline.google,
    greatest(200,3*v_baseline.google),greatest(500,6*v_baseline.google),v_at);
  -- The former 5,000/day guard was removed. Resolve its historical alarm.
  update public.admin_traffic_alerts set resolved_at=coalesce(resolved_at,v_at)
    where source='google_budget' and resolved_at is null;
  perform public.record_admin_traffic_signal('quote_queue',
    'Quote windows are overdue; the quote worker may be falling behind.',
    v_durable,0,1,25,v_at);
  perform public.record_admin_traffic_signal('route_queue',
    'Route planning events are overdue; the route worker may be falling behind.',
    v_route,0,1,25,v_at);
  perform public.record_admin_traffic_signal('dispatch_queue',
    'Rider searches are overdue; the dispatch matcher may be falling behind.',
    v_dispatch,0,10,100,v_at);
  perform public.record_admin_traffic_signal('matching_windows',
    'Delivery matching windows have remained open too long.',
    v_quotes,0,1,25,v_at);

  if extract(hour from v_at at time zone 'UTC')=3
     and extract(minute from v_at at time zone 'UTC')=0 then
    delete from public.admin_traffic_samples where sampled_at<v_at-interval '7 days';
    delete from public.admin_traffic_alerts
      where resolved_at is not null and resolved_at<v_at-interval '30 days';
  end if;
end $$;
create or replace function public.admin_traffic_spike_snapshot() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_sample public.admin_traffic_samples%rowtype;v_metrics jsonb;v_alerts jsonb;
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  select * into v_sample from public.admin_traffic_samples order by sampled_at desc limit 1;
  if v_sample.sampled_at is null then
    return jsonb_build_object('checked_at',now(),'window_minutes',1,'metrics','[]'::jsonb,'alerts','[]'::jsonb);
  end if;
  select jsonb_agg(jsonb_build_object('key',m.source,'label',m.label,'current',m.current,
      'baseline',m.baseline,'unit',m.unit,'status',coalesce(a.severity,'normal')) order by m.sort_order)
    into v_metrics from (
    select 1 sort_order,'db_transactions' source,'DB transactions' label,
      v_sample.transactions_per_minute::numeric current,'/min' unit,
      (select coalesce(avg(transactions_per_minute),0) from public.admin_traffic_samples
        where sampled_at<v_sample.sampled_at and sampled_at>=v_sample.sampled_at-interval '30 minutes') baseline
    union all select 2,'db_rows','Rows fetched',v_sample.rows_fetched_per_minute,'/min',
      (select coalesce(avg(rows_fetched_per_minute),0) from public.admin_traffic_samples
        where sampled_at<v_sample.sampled_at and sampled_at>=v_sample.sampled_at-interval '30 minutes')
    union all select 3,'db_rollbacks','DB rollbacks',v_sample.rollbacks_per_minute,'/min',
      (select coalesce(avg(rollbacks_per_minute),0) from public.admin_traffic_samples
        where sampled_at<v_sample.sampled_at and sampled_at>=v_sample.sampled_at-interval '30 minutes')
    union all select 4,'quote_queue','Overdue quote jobs',v_sample.durable_overdue,'jobs',0
    union all select 5,'route_queue','Overdue route jobs',v_sample.route_overdue,'jobs',0
    union all select 6,'dispatch_queue','Overdue rider searches',v_sample.dispatch_overdue,'jobs',0
    union all select 7,'matching_windows','Overdue matching windows',v_sample.quotes_overdue,'windows',0
    union all select 8,'google_elements','Google route elements',v_sample.google_elements_per_minute,'/min',
      (select coalesce(avg(google_elements_per_minute),0) from public.admin_traffic_samples
        where sampled_at<v_sample.sampled_at and sampled_at>=v_sample.sampled_at-interval '30 minutes')

  ) m left join public.admin_traffic_alerts a on a.source=m.source and a.resolved_at is null;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id',a.id,'severity',a.severity,'source',a.source,'cause',a.cause,
      'observed',a.observed,'baseline',a.baseline,'threshold',a.threshold,
      'detected_at',a.detected_at,'resolved_at',a.resolved_at,
      'acknowledged_at',ack.acknowledged_at) order by a.detected_at desc),'[]'::jsonb)
    into v_alerts from (
      select * from public.admin_traffic_alerts
      where resolved_at is null or resolved_at>now()-interval '24 hours'
      order by detected_at desc limit 20
    ) a left join public.admin_traffic_acknowledgements ack
      on ack.alert_id=a.id and ack.user_id=auth.uid();
  return jsonb_build_object('checked_at',v_sample.sampled_at,'window_minutes',1,
    'metrics',coalesce(v_metrics,'[]'::jsonb),'alerts',v_alerts);
end $$;
