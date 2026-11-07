-- Add app-reported Google SKU estimates and a partial-cost 10% margin warning.
alter function public.admin_cost_monitor() rename to admin_cost_monitor_before_google_skus;
revoke all on function public.admin_cost_monitor_before_google_skus() from public,anon,authenticated;

create function public.admin_cost_monitor() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_prior jsonb;v_settings public.admin_cost_rate_settings%rowtype;
  v_day date:=(now() at time zone 'UTC')::date;v_month date;
  v_google_extra_usd numeric:=0;v_google_extra_ngn numeric;
  v_google_total numeric;v_paystack numeric;v_supabase numeric;
  v_record_google numeric:=0;v_record_paystack numeric:=0;v_record_supabase numeric:=0;
  v_record_other numeric:=0;v_for_margin numeric;v_margin numeric;
  v_revenue numeric;v_available numeric;v_warning text;
  v_counts jsonb:='{}'::jsonb;
begin
  if not public.has_role(auth.uid(),'admin') then raise insufficient_privilege using message='Super Admin access is required'; end if;
  v_prior:=public.admin_cost_monitor_before_google_skus();
  select * into v_settings from public.admin_cost_rate_settings where id=1;
  v_month:=date_trunc('month',v_day::timestamp)::date;
  with sku_rates(sku,free_monthly,usd_per_1000) as (values
    ('places_text',5000,32::numeric),('places_nearby',5000,32::numeric),
    ('geocoding',10000,5::numeric),('dynamic_maps',10000,7::numeric),
    ('autocomplete_requests',10000,2.83::numeric),('place_details',10000,5::numeric),
    ('routes_compute',10000,5::numeric)),
  usage as (
    select b.sku,coalesce(sum(b.request_count) filter(where b.usage_day<v_day),0) before_count,
      coalesce(sum(b.request_count) filter(where b.usage_day=v_day),0) today_count
      from public.google_browser_usage_daily b where b.usage_day>=v_month and b.usage_day<=v_day group by b.sku
    union all
    select 'routes_compute',
      (select count(*) from public.bike_route_prices p where p.created_at>=v_month::timestamp at time zone 'UTC'
         and p.created_at<v_day::timestamp at time zone 'UTC'),
      (select count(*) from public.bike_route_prices p where p.created_at>=v_day::timestamp at time zone 'UTC'
         and p.created_at<(v_day+1)::timestamp at time zone 'UTC')
  ), priced as (
    select r.sku,coalesce(u.today_count,0) today_count,
      (greatest(coalesce(u.before_count,0)+coalesce(u.today_count,0)-r.free_monthly,0)
       -greatest(coalesce(u.before_count,0)-r.free_monthly,0))*r.usd_per_1000/1000 usd_today
      from sku_rates r left join usage u on u.sku=r.sku
  )
  select coalesce(sum(usd_today),0),coalesce(jsonb_object_agg(sku,today_count),'{}'::jsonb)
    into v_google_extra_usd,v_counts from priced;
  if v_settings.usd_to_ngn is not null then
    v_google_extra_ngn:=round(v_google_extra_usd*v_settings.usd_to_ngn,2);
  elsif v_google_extra_usd=0 then v_google_extra_ngn:=0;
  end if;
  v_google_total:=coalesce((v_prior->'modeled_costs'->>'google_route_matrix_ngn')::numeric,0)
    +coalesce(v_google_extra_ngn,0);
  v_paystack:=coalesce((v_prior->'modeled_costs'->>'paystack_ngn')::numeric,0);
  v_supabase:=coalesce((v_prior->'modeled_costs'->>'supabase_ngn')::numeric,0);
  select coalesce(sum(amount_ngn) filter(where source='google_route_matrix'),0),
    coalesce(sum(amount_ngn) filter(where source='paystack_payment'),0),
    coalesce(sum(amount_ngn) filter(where source='supabase'),0),
    coalesce(sum(amount_ngn) filter(where source in ('sms_delivery','other')),0)
    into v_record_google,v_record_paystack,v_record_supabase,v_record_other
    from public.admin_operating_costs where cost_day=v_day;
  v_for_margin:=greatest(v_record_google,v_google_total)+greatest(v_record_paystack,v_paystack)
    +greatest(v_record_supabase,v_supabase)+v_record_other;
  v_revenue:=(v_prior->>'collected_revenue_ngn')::numeric;
  v_available:=(v_prior->>'available_for_operations_ngn')::numeric;
  if v_revenue>0 then
    v_margin:=round((v_available-v_for_margin)*100/v_revenue,2);
    if v_margin<=10 then
      v_warning:='Measured and modeled costs leave an estimated margin of '||v_margin||'%. Other costs may lower it further.';
    end if;
  end if;
  return v_prior||jsonb_build_object(
    'google_other_api_counts_today',v_counts,
    'google_other_api_estimate_ngn',v_google_extra_ngn,
    'estimated_tracked_cost_ngn',(v_prior->>'estimated_tracked_cost_ngn')::numeric+coalesce(v_google_extra_ngn,0),
    'cost_for_margin_ngn',v_for_margin,
    'estimated_margin_percent',v_margin,
    'margin_warning',v_warning,
    'modeled_costs',(v_prior->'modeled_costs')||jsonb_build_object('google_other_apis_ngn',v_google_extra_ngn));
end $$;
revoke all on function public.admin_cost_monitor() from public,anon,authenticated;
grant execute on function public.admin_cost_monitor() to authenticated;
