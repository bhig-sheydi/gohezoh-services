-- Exclude companies that already missed this paid job before the bounded
-- candidate LIMIT. Filtering after LIMIT 100 can hide other eligible firms.
do $$
declare v_definition text; v_revised text;
begin
  select pg_get_functiondef('public.route_planner_candidates(uuid)'::regprocedure) into v_definition;
  v_revised:=replace(v_definition,
    'where r.id=p_request and r.pickup_latitude is not null',
    'where r.id=p_request and r.pickup_latitude is not null'
      ||' and not exists(select 1 from public.rider_assignment_responses missed'
      ||' join public.jobs mj on mj.id=missed.job_id'
      ||' join public.orders mo on mo.id=mj.order_id'
      ||' where mo.service_request_id=p_request and missed.partner_id=rp.partner_id)');
  if v_revised=v_definition then raise exception 'Route candidate prefilter insertion point was not found'; end if;
  execute v_revised;
end $$;
