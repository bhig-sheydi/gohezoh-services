-- One authenticated round trip for the rider's current dashboard. Reuse the
-- existing scoped readers so their custody and session checks remain intact.
create function public.my_rider_dashboard_snapshot() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
declare
  v_has_role boolean;
  v_active boolean;
begin
  if auth.role() is distinct from 'authenticated' or auth.uid() is null then
    raise insufficient_privilege using message='Rider sign-in required';
  end if;

  v_has_role := public.has_role(auth.uid(),'rider');
  v_active := v_has_role and public.rider_session_active();
  if not v_active then
    return jsonb_build_object(
      'has_role',v_has_role,'session_active',false,
      'jobs','[]'::jsonb,'profile','[]'::jsonb,
      'pickup_locations','[]'::jsonb,'delivery_locations','[]'::jsonb,
      'selected_pickups','[]'::jsonb,'next_stop','[]'::jsonb
    );
  end if;

  return jsonb_build_object(
    'has_role',true,'session_active',true,
    'jobs',(select coalesce(jsonb_agg(to_jsonb(t)-'ordinality' order by t.ordinality),'[]'::jsonb)
      from public.list_my_rider_jobs() with ordinality as t),
    'profile',(select coalesce(jsonb_agg(to_jsonb(t)-'ordinality' order by t.ordinality),'[]'::jsonb)
      from public.my_rider_profile() with ordinality as t),
    'pickup_locations',(select coalesce(jsonb_agg(to_jsonb(t)-'ordinality' order by t.ordinality),'[]'::jsonb)
      from public.list_my_rider_pickup_locations() with ordinality as t),
    'delivery_locations',(select coalesce(jsonb_agg(to_jsonb(t)-'ordinality' order by t.ordinality),'[]'::jsonb)
      from public.list_my_rider_delivery_locations() with ordinality as t),
    'selected_pickups',(select coalesce(jsonb_agg(to_jsonb(t)-'ordinality' order by t.ordinality),'[]'::jsonb)
      from public.list_my_selected_pickups() with ordinality as t),
    'next_stop',(select coalesce(jsonb_agg(to_jsonb(t)-'ordinality' order by t.ordinality),'[]'::jsonb)
      from public.my_rider_next_stop() with ordinality as t)
  );
end $$;

revoke all on function public.my_rider_dashboard_snapshot() from public,anon;
grant execute on function public.my_rider_dashboard_snapshot() to authenticated;
