-- pg_stat_user_tables pinpoints which app tables are writing during a DB spike.
-- This reads five fixed counters once per minute, with no per-request logging.
alter table public.admin_traffic_samples
  add column write_totals jsonb not null default '{}'::jsonb,
  add column writes_per_minute jsonb not null default '{}'::jsonb;

create function public.sample_admin_table_write_causes() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_previous public.admin_traffic_samples%rowtype;
  v_totals jsonb;
  v_rates jsonb:='{}'::jsonb;
  v_key text;
  v_total bigint;
  v_old bigint;
  v_rate integer;
  v_elapsed numeric;
  v_gps integer;
  v_baseline numeric;
begin
  select * into v_previous from public.admin_traffic_samples
    where sampled_at<new.sampled_at order by sampled_at desc limit 1;
  select coalesce(jsonb_object_agg(relname,n_tup_ins+n_tup_upd+n_tup_del),'{}'::jsonb)
    into v_totals from pg_catalog.pg_stat_user_tables
    where schemaname='public' and relname in
      ('rider_presence','rider_location_latest','shared_delivery_places',
       'service_requests','route_planner_events');
  v_elapsed:=extract(epoch from new.sampled_at-v_previous.sampled_at);
  foreach v_key in array array['rider_presence','rider_location_latest',
    'shared_delivery_places','service_requests','route_planner_events'] loop
    v_total:=coalesce((v_totals->>v_key)::bigint,0);
    v_old:=coalesce((v_previous.write_totals->>v_key)::bigint,0);
    v_rate:=case when v_previous.sampled_at is not null and v_elapsed>0
                   and v_total>=v_old
      then least(2147483647,round((v_total-v_old)*60/v_elapsed))::integer
      else 0 end;
    v_rates:=v_rates||jsonb_build_object(v_key,v_rate);
  end loop;
  update public.admin_traffic_samples
    set write_totals=v_totals,writes_per_minute=v_rates
    where sampled_at=new.sampled_at;

  v_gps:=(v_rates->>'rider_presence')::integer+
         (v_rates->>'rider_location_latest')::integer;
  select coalesce(avg(coalesce((writes_per_minute->>'rider_presence')::numeric,0)+
      coalesce((writes_per_minute->>'rider_location_latest')::numeric,0)),0)
    into v_baseline from public.admin_traffic_samples
    where sampled_at<new.sampled_at and sampled_at>=new.sampled_at-interval '30 minutes';
  perform public.record_admin_traffic_signal('rider_gps_writes',
    'Rider location writes jumped; review GPS update frequency and retry loops.',
    v_gps,v_baseline,greatest(800,3*v_baseline),greatest(2500,6*v_baseline),new.sampled_at);

  foreach v_key in array array['shared_delivery_places','service_requests','route_planner_events'] loop
    select coalesce(avg(coalesce((writes_per_minute->>v_key)::numeric,0)),0)
      into v_baseline from public.admin_traffic_samples
      where sampled_at<new.sampled_at and sampled_at>=new.sampled_at-interval '30 minutes';
    perform public.record_admin_traffic_signal(
      case v_key when 'shared_delivery_places' then 'address_cache_writes'
        when 'service_requests' then 'delivery_request_writes' else 'route_event_writes' end,
      case v_key when 'shared_delivery_places' then
        'Shared address cache writes jumped; review place publication and deduplication.'
        when 'service_requests' then
        'Delivery request writes jumped; new or retried bookings may be driving traffic.'
        else 'Route-planner event writes jumped; review route update frequency.' end,
      (v_rates->>v_key)::numeric,v_baseline,
      greatest(case v_key when 'shared_delivery_places' then 80 else 100 end,3*v_baseline),
      greatest(case v_key when 'shared_delivery_places' then 250 else 500 end,6*v_baseline),
      new.sampled_at);
  end loop;
  return new;
end $$;
revoke all on function public.sample_admin_table_write_causes() from public,anon,authenticated;
create trigger admin_traffic_sample_write_causes
  after insert on public.admin_traffic_samples
  for each row execute function public.sample_admin_table_write_causes();

alter function public.admin_traffic_spike_snapshot()
  rename to admin_traffic_spike_snapshot_core;
revoke all on function public.admin_traffic_spike_snapshot_core() from public,anon,authenticated;

create function public.admin_traffic_spike_snapshot() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_base jsonb;v_sample public.admin_traffic_samples%rowtype;v_extra jsonb;
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  v_base:=public.admin_traffic_spike_snapshot_core();
  select * into v_sample from public.admin_traffic_samples order by sampled_at desc limit 1;
  if v_sample.sampled_at is null then return v_base; end if;
  select jsonb_agg(jsonb_build_object('key',m.source,'label',m.label,'current',m.current,
    'baseline',m.baseline,'unit','/min','status',coalesce(a.severity,'normal'))
    order by m.sort_order) into v_extra from (
    select 1 sort_order,'rider_gps_writes' source,'Rider GPS writes' label,
      (coalesce((v_sample.writes_per_minute->>'rider_presence')::numeric,0)+
       coalesce((v_sample.writes_per_minute->>'rider_location_latest')::numeric,0)) current,
      (select coalesce(avg(coalesce((writes_per_minute->>'rider_presence')::numeric,0)+
        coalesce((writes_per_minute->>'rider_location_latest')::numeric,0)),0)
        from public.admin_traffic_samples where sampled_at<v_sample.sampled_at
        and sampled_at>=v_sample.sampled_at-interval '30 minutes') baseline
    union all select 2,'delivery_request_writes','Delivery request writes',
      coalesce((v_sample.writes_per_minute->>'service_requests')::numeric,0),
      (select coalesce(avg(coalesce((writes_per_minute->>'service_requests')::numeric,0)),0)
        from public.admin_traffic_samples where sampled_at<v_sample.sampled_at
        and sampled_at>=v_sample.sampled_at-interval '30 minutes')
    union all select 3,'route_event_writes','Route event writes',
      coalesce((v_sample.writes_per_minute->>'route_planner_events')::numeric,0),
      (select coalesce(avg(coalesce((writes_per_minute->>'route_planner_events')::numeric,0)),0)
        from public.admin_traffic_samples where sampled_at<v_sample.sampled_at
        and sampled_at>=v_sample.sampled_at-interval '30 minutes')
    union all select 4,'address_cache_writes','Shared address writes',
      coalesce((v_sample.writes_per_minute->>'shared_delivery_places')::numeric,0),
      (select coalesce(avg(coalesce((writes_per_minute->>'shared_delivery_places')::numeric,0)),0)
        from public.admin_traffic_samples where sampled_at<v_sample.sampled_at
        and sampled_at>=v_sample.sampled_at-interval '30 minutes')
  ) m left join public.admin_traffic_alerts a on a.source=m.source and a.resolved_at is null;
  return jsonb_set(v_base,'{metrics}',coalesce(v_base->'metrics','[]'::jsonb)||coalesce(v_extra,'[]'::jsonb));
end $$;
revoke all on function public.admin_traffic_spike_snapshot() from public,anon,authenticated;
grant execute on function public.admin_traffic_spike_snapshot() to authenticated;
