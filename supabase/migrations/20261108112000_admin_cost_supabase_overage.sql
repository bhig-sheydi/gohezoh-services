alter function public.admin_cost_monitor() rename to admin_cost_monitor_before_supabase_usage;
revoke all on function public.admin_cost_monitor_before_supabase_usage() from public,anon,authenticated;

create function public.admin_cost_monitor() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_prior jsonb;v_extra numeric;v_base numeric;v_recorded numeric;
  v_old numeric;v_new numeric;v_revenue numeric;v_margin numeric;v_warning text;
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  v_prior:=public.admin_cost_monitor_before_supabase_usage();
  v_extra:=public.supabase_overage_daily_estimate_ngn();
  v_base:=coalesce((v_prior->'modeled_costs'->>'supabase_ngn')::numeric,0);
  select coalesce(sum(amount_ngn),0) into v_recorded from public.admin_operating_costs
    where cost_day=(now() at time zone 'UTC')::date and source='supabase';
  v_old:=greatest(v_base,v_recorded);
  v_new:=greatest(v_base+coalesce(v_extra,0),v_recorded);
  v_revenue:=(v_prior->>'collected_revenue_ngn')::numeric;
  if v_revenue>0 then
    v_margin:=round(((v_prior->>'available_for_operations_ngn')::numeric
      -(v_prior->>'cost_for_margin_ngn')::numeric-(v_new-v_old))*100/v_revenue,2);
    if v_margin<=10 then
      v_warning:='Measured and modeled costs leave an estimated margin of '||v_margin||'%. Other costs may lower it further.';
    end if;
  end if;
  return v_prior||jsonb_build_object(
    'supabase_overage_daily_estimate_ngn',v_extra,
    'estimated_tracked_cost_ngn',coalesce((v_prior->>'estimated_tracked_cost_ngn')::numeric,0)+coalesce(v_extra,0),
    'cost_for_margin_ngn',(v_prior->>'cost_for_margin_ngn')::numeric+(v_new-v_old),
    'estimated_margin_percent',v_margin,'margin_warning',v_warning,
    'modeled_costs',(v_prior->'modeled_costs')||jsonb_build_object('supabase_ngn',v_base+coalesce(v_extra,0)));
end $$;
revoke all on function public.admin_cost_monitor() from public,anon,authenticated;
grant execute on function public.admin_cost_monitor() to authenticated;
