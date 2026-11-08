begin;
do $$
declare
  v_day date:=(now() at time zone 'UTC')::date;
  v_month date:=date_trunc('month',now() at time zone 'UTC')::date;
  v_before bigint;v_admin uuid;v_view jsonb;
begin
  if has_function_privilege('authenticated',
      'public.reserve_google_route_matrix_elements_budgeted(integer)','EXECUTE')
    or has_function_privilege('service_role',
      'public.reserve_google_route_matrix_elements_before_sample_safety(integer)','EXECUTE') then
    raise exception 'A route budget implementation leaked to clients or workers';
  end if;
  perform set_config('request.jwt.claim.role','service_role',true);

  -- Test the actual published allowance, not an artificial 10M-element limit.
  update public.admin_cost_rate_settings set supabase_plan='pro',
    supabase_monthly_usd=25,google_route_sku='essentials',
    google_free_monthly_elements=10000,google_usd_per_1000=5 where id=1;
  update public.google_route_matrix_daily_budget set elements_reserved=0
    where budget_day>=v_month and budget_day<=v_day;
  insert into public.google_route_matrix_daily_budget(budget_day,elements_reserved)
    values(v_day,0) on conflict(budget_day) do update set elements_reserved=0;
  update public.admin_supabase_usage_sample set sampled_at=now()-interval '3 hours' where id=1;
  if not public.reserve_google_route_matrix_elements_budgeted(1) then
    raise exception 'A stale sample blocked a free Google route element';
  end if;

  update public.google_route_matrix_daily_budget set elements_reserved=9999
    where budget_day=v_day;
  select elements_reserved into v_before from public.google_route_matrix_daily_budget
    where budget_day=v_day;
  if public.reserve_google_route_matrix_elements_budgeted(2) then
    raise exception 'Stale Supabase usage authorized a paid route element';
  end if;
  if (select elements_reserved from public.google_route_matrix_daily_budget
      where budget_day=v_day)<>v_before then
    raise exception 'Rejected route reservation changed the ledger';
  end if;

  begin
    update public.admin_cost_rate_settings set google_free_monthly_elements=10000000 where id=1;
    raise exception 'Oversized free Google allowance was accepted';
  exception when check_violation then null; end;
  begin
    update public.admin_cost_rate_settings set google_usd_per_1000=0 where id=1;
    raise exception 'Zero paid Google rate was accepted';
  exception when check_violation then null; end;
  begin
    update public.admin_cost_rate_settings set supabase_monthly_usd=0 where id=1;
    raise exception 'A zero-cost Pro plan was accepted';
  exception when check_violation then null; end;

  -- A fresh cached margin of 10% or lower automatically reduces optional
  -- new-job road checks; manual savings still overrides a healthy reading.
  insert into public.admin_alarm_margin_state
    (alarm_day,evaluated_at,below_threshold,last_margin_percent)
    values(v_day,now(),true,10)
    on conflict(alarm_day) do update set evaluated_at=now(),
      below_threshold=true,last_margin_percent=10;
  update public.admin_cost_mode set mode='normal' where id=1;
  if not public.get_routing_economy_mode() then
    raise exception '10 percent margin did not activate automatic economy';
  end if;
  update public.admin_alarm_margin_state set below_threshold=false,
    last_margin_percent=10.01 where alarm_day=v_day;
  if public.get_routing_economy_mode() then
    raise exception 'Healthy margin activated automatic economy';
  end if;
  update public.admin_cost_mode set mode='economy' where id=1;
  if not public.get_routing_economy_mode() then
    raise exception 'Manual economy did not override healthy margin';
  end if;

  select u.id into v_admin from auth.users u where lower(u.email) in
    ('admin@gohezohservices.org','info@gohezohservices.org',
     'vevakporgodsanointed@gmail.com') and public.has_role(u.id,'admin') limit 1;
  if v_admin is null then raise exception 'No super admin for integration test'; end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  v_view:=public.admin_cost_monitor();
  if v_view->>'mode'<>'economy' or v_view->>'effective_mode'<>'economy'
    or v_view->>'economy_reason'<>'manual' then
    raise exception 'Dashboard confused manual and effective economy';
  end if;
  begin
    perform public.get_routing_economy_mode();
    raise exception 'Authenticated admin called worker-only economy RPC';
  exception when insufficient_privilege then null; end;
end $$;
rollback;
