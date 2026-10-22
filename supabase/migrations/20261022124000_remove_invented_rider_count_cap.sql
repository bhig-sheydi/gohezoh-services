-- A rider reports available, almost_full, or full. The number of jobs is not
-- a proxy for physical box capacity. Route calculation remains cost bounded.
do $$
declare v_name text; v_definition text; v_revised text;
begin
  foreach v_name in array array[
    'public.nearby_dispatch_companies(uuid,uuid)',
    'public.company_can_bid_nearby(uuid,uuid)',
    'public.route_planner_candidates(uuid)',
    'public.assign_selected_pickup_rider_on_acceptance()'
  ] loop
    select pg_get_functiondef(v_name::regprocedure) into v_definition;
    v_revised:=regexp_replace(v_definition,
      'and[[:space:]]*\(select count\(\*\) from public\.jobs j where j\.assigned_rider_id=(rp\.user_id|i\.rider_id)[[:space:]]*and j\.status in \(''pickup_scheduled'',''picked_up'',''exception''\)\)<5',
      '', 'g');
    if v_revised=v_definition then
      raise exception 'Expected rider-count guard missing in %',v_name;
    end if;
    execute v_revised;
  end loop;
end $$;
