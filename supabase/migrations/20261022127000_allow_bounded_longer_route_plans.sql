-- The first road-matrix horizon is bounded separately from the number of
-- parcels a rider can carry. Keep all assigned stops visible in the plan.
do $$
declare v_definition text;v_revised text;
begin
  select pg_get_functiondef('public.commit_rider_route_plan(uuid,bigint,jsonb,text)'::regprocedure)
    into v_definition;
  v_revised:=replace(v_definition,'jsonb_array_length(p_stops) > 10',
    'jsonb_array_length(p_stops) > 100');
  if v_revised=v_definition then
    v_revised:=replace(v_definition,'jsonb_array_length(p_stops)>10',
      'jsonb_array_length(p_stops)>100');
  end if;
  if v_revised=v_definition then raise exception 'Route plan bound not found'; end if;
  execute v_revised;
end $$;
