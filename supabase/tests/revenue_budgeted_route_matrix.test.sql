begin;
do $$
declare v_settings public.admin_cost_rate_settings%rowtype;
  v_before bigint; v_after bigint; v_day date:=(now() at time zone 'UTC')::date;
begin
  if has_function_privilege('authenticated',
      'public.reserve_google_route_matrix_elements_budgeted(integer)','EXECUTE') then
    raise exception 'Budgeted route reservation must be worker-only';
  end if;
  perform set_config('request.jwt.claim.role','service_role',true);
  select * into v_settings from public.admin_cost_rate_settings where id=1;
  select coalesce(elements_reserved,0) into v_before
    from public.google_route_matrix_daily_budget where budget_day=v_day;
  v_before:=coalesce(v_before,0);
  -- A free monthly allowance must continue to work beyond the former daily cap.
  update public.admin_cost_rate_settings set google_free_monthly_elements=10000000 where id=1;
  if not public.reserve_google_route_matrix_elements_budgeted(2) then
    raise exception 'Free monthly route allowance was rejected';
  end if;
  select elements_reserved into v_after from public.google_route_matrix_daily_budget where budget_day=v_day;
  if v_after<>v_before+2 then raise exception 'Route elements were not reserved atomically'; end if;
  begin
    perform public.reserve_google_route_matrix_elements_budgeted(101);
    raise exception 'Oversized matrix reservation was accepted';
  exception when check_violation then null; end;
end $$;
rollback;
