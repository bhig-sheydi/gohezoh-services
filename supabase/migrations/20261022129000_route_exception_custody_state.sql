-- Exception means an issue occurred, not that custody reversed. The verified
-- sender pickup code is the authoritative evidence that pickup is complete.
create function public.route_job_needs_pickup(p_job uuid,p_status text) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select p_status='pickup_scheduled' or (p_status='exception' and not exists(
    select 1 from public.pickup_handoff_codes c
    where c.job_id=p_job and c.verified_at is not null));
$$;
revoke all on function public.route_job_needs_pickup(uuid,text) from public,anon,authenticated;

do $$
declare v_definition text;v_revised text;
begin
  select pg_get_functiondef('public.commit_rider_route_plan(uuid,bigint,jsonb,text)'::regprocedure)
    into v_definition;
  v_revised:=replace(v_definition,
    'v_job.status not in (''pickup_scheduled'',''exception'')',
    'not public.route_job_needs_pickup(v_job.id,v_job.status::text)');
  v_revised:=replace(v_revised,
    'v_job.status in (''pickup_scheduled'',''exception'') and not v_stop.job_id=any(v_pickup_seen)',
    'public.route_job_needs_pickup(v_job.id,v_job.status::text) and not v_stop.job_id=any(v_pickup_seen)');
  v_revised:=replace(v_revised,
    'j.status in (''pickup_scheduled'',''exception'')',
    'public.route_job_needs_pickup(j.id,j.status::text)');
  v_revised:=replace(v_revised,
    'j.status in (''picked_up'',''in_transit'',''out_for_delivery'')',
    '(j.status in (''picked_up'',''in_transit'',''out_for_delivery'') or (j.status=''exception'' and not public.route_job_needs_pickup(j.id,j.status::text)))');
  if v_revised=v_definition or position('v_job.status not in (''pickup_scheduled'',''exception'')' in v_revised)>0
    or position('j.status in (''pickup_scheduled'',''exception'')' in v_revised)>0 then
    raise exception 'Could not update route custody checks';
  end if;
  execute v_revised;
end $$;
