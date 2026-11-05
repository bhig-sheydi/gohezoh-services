begin;

do $$
declare v_day date := (now() at time zone 'UTC')::date;
        v_old_budget integer;
begin
  perform set_config('request.jwt.claim.role','authenticated',true);
  begin
    perform public.reserve_google_route_matrix_elements(1);
    raise exception 'Client reserved Google routing budget';
  exception when insufficient_privilege then null; end;

  perform set_config('request.jwt.claim.role','service_role',true);
  select credits_reserved into v_old_budget from public.route_matrix_daily_budget
    where budget_day=v_day;
  insert into public.google_route_matrix_daily_budget(budget_day,elements_reserved)
    values(v_day,0) on conflict(budget_day) do update set elements_reserved=0;

  if not public.reserve_google_route_matrix_elements(100,100) then
    raise exception 'Expected first reservation to succeed';
  end if;
  if public.reserve_google_route_matrix_elements(1,100) then
    raise exception 'Reservation exceeded the configured daily limit';
  end if;
  if not public.reserve_google_route_matrix_elements(1,101) then
    raise exception 'Raising the configured daily limit did not work';
  end if;
  if not public.reserve_google_route_matrix_elements(1) then
    raise exception 'Default Google routing budget did not work';
  end if;
  if public.reserve_google_route_matrix_elements(2,1) then
    raise exception 'Call larger than the configured daily limit was accepted';
  end if;
  if (select elements_reserved from public.google_route_matrix_daily_budget
      where budget_day=v_day)<>102 then
    raise exception 'Unexpected Google routing budget total';
  end if;
  if (select credits_reserved from public.route_matrix_daily_budget
      where budget_day=v_day) is distinct from v_old_budget then
    raise exception 'Google reservation changed the Geoapify budget';
  end if;

  begin
    perform public.reserve_google_route_matrix_elements(101,100000);
    raise exception 'Oversized matrix reservation was accepted';
  exception when check_violation then null; end;
  begin
    perform public.reserve_google_route_matrix_elements(1,1000001);
    raise exception 'Unbounded daily limit was accepted';
  exception when check_violation then null; end;
  begin
    perform public.reserve_google_route_matrix_elements(1,null);
    raise exception 'Null daily limit was accepted';
  exception when check_violation then null; end;

  if has_function_privilege('authenticated',
      'public.reserve_google_route_matrix_elements(integer,integer)','EXECUTE') then
    raise exception 'Google routing budget RPC leaked to clients';
  end if;
  if has_table_privilege('authenticated',
      'public.google_route_matrix_daily_budget','SELECT')
    or has_table_privilege('service_role',
      'public.google_route_matrix_daily_budget','UPDATE') then
    raise exception 'Google routing ledger has unexpected direct access';
  end if;
end $$;

rollback;
