begin;

do $$
declare
  v_admin uuid;v_before jsonb;v_after jsonb;v_record jsonb;
  v_ref text:='sql-cost-monitor-'||gen_random_uuid()::text;
  v_history bigint;v_day date:=(now() at time zone 'UTC')::date;
begin
  if has_function_privilege('anon','public.admin_cost_monitor()','EXECUTE')
     or has_function_privilege('anon','public.set_admin_cost_mode(text)','EXECUTE')
     or has_function_privilege('authenticated','public.get_routing_economy_mode()','EXECUTE')
     or has_table_privilege('authenticated','public.admin_operating_costs','SELECT')
     or has_table_privilege('authenticated','public.admin_cost_mode','UPDATE') then
    raise exception 'Cost controls leaked outside their gated RPCs';
  end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  begin
    perform public.admin_cost_monitor();
    raise exception 'Non-admin read cost details';
  exception when insufficient_privilege then null; end;
  begin
    perform public.set_admin_cost_mode('economy');
    raise exception 'Non-admin changed economy mode';
  exception when insufficient_privilege then null; end;
  begin
    perform public.record_admin_operating_cost('supabase',1,v_day,v_ref);
    raise exception 'Non-admin entered a provider charge';
  exception when insufficient_privilege then null; end;
  begin
    perform public.get_routing_economy_mode();
    raise exception 'Authenticated user read worker mode';
  exception when insufficient_privilege then null; end;

  select u.id into v_admin from auth.users u where lower(u.email) in
    ('admin@gohezohservices.org','info@gohezohservices.org','vevakporgodsanointed@gmail.com')
    and public.has_role(u.id,'admin') limit 1;
  if v_admin is null then raise exception 'No configured super admin for cost test'; end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  v_before:=public.admin_cost_monitor();
  if jsonb_typeof(v_before->'warnings')<>'array'
     or jsonb_typeof(v_before->'data_gaps')<>'array'
     or v_before->>'estimated_operating_cost_ngn' is not null
     or v_before->>'remaining_operating_budget_ngn' is not null then
    raise exception 'Cost snapshot implied a complete provider bill';
  end if;
  if (v_before->>'operating_budget_ngn')::numeric <>
       (v_before->>'collected_revenue_ngn')::numeric
       -(v_before->>'partner_payable_ngn')::numeric
       -(v_before->>'other_direct_cost_ngn')::numeric
       -(v_before->>'customer_referral_ngn')::numeric
       -(v_before->>'partner_referral_ngn')::numeric
       -(v_before->>'registration_referral_reserve_ngn')::numeric
       -(v_before->>'target_profit_ngn')::numeric then
    raise exception 'Operating allowance omitted an obligation';
  end if;

  select count(*) into v_history from public.admin_cost_mode_history;
  perform public.set_admin_cost_mode('economy');
  if (public.admin_cost_monitor()->>'mode')<>'economy'
     or (select count(*) from public.admin_cost_mode_history)<>v_history+1 then
    raise exception 'Economy mode was not persisted or audited';
  end if;
  perform set_config('request.jwt.claim.role','service_role',true);
  if public.get_routing_economy_mode() is distinct from true then
    raise exception 'Routing worker did not see economy mode';
  end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform public.set_admin_cost_mode('economy');
  if (select count(*) from public.admin_cost_mode_history)<>v_history+1 then
    raise exception 'Idempotent mode choice duplicated the audit row';
  end if;
  perform public.set_admin_cost_mode('normal');

  v_record:=public.record_admin_operating_cost('supabase',12.34,v_day,v_ref,'SQL test');
  if v_record->>'id' is null then raise exception 'Cost entry returned no id'; end if;
  v_after:=public.admin_cost_monitor();
  if (v_after->>'recorded_costs_ngn')::numeric<>(v_before->>'recorded_costs_ngn')::numeric+12.34
     or (v_after->>'known_cost_lower_bound_ngn')::numeric<>(v_before->>'known_cost_lower_bound_ngn')::numeric+12.34 then
    raise exception 'Recorded provider charge was not reflected exactly once';
  end if;
  begin
    perform public.record_admin_operating_cost('supabase',12.34,v_day,v_ref);
    raise exception 'Duplicate provider reference was accepted';
  exception when unique_violation then null; end;
end $$;

rollback;
