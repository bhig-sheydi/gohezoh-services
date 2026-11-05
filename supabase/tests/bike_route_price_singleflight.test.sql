begin;

do $$
declare v_request uuid := gen_random_uuid();
        v_first uuid;
        v_reclaimed uuid;
        v_denied boolean := false;
begin
  perform set_config('request.jwt.claim.role','authenticated',true);
  begin
    perform public.claim_bike_route_price_calculation(v_request,4.88,7.00,4.90,7.10);
  exception when insufficient_privilege then v_denied := true; end;
  if not v_denied then raise exception 'Customer claimed the road-pricing lease'; end if;

  perform set_config('request.jwt.claim.role','service_role',true);
  v_first := public.claim_bike_route_price_calculation(v_request,4.88,7.00,4.90,7.10);
  if v_first is null then raise exception 'First worker did not claim road pricing'; end if;
  if public.claim_bike_route_price_calculation(v_request,4.88,7.00,4.90,7.10) is not null then
    raise exception 'A second worker acquired an active pricing lease';
  end if;

  perform public.release_bike_route_price_calculation(v_request,gen_random_uuid());
  if public.claim_bike_route_price_calculation(v_request,4.88,7.00,4.90,7.10) is not null then
    raise exception 'A wrong token released the active pricing lease';
  end if;

  update public.bike_route_price_leases set leased_until=now()-interval '1 second'
    where request_id=v_request;
  v_reclaimed := public.claim_bike_route_price_calculation(v_request,4.88,7.00,4.90,7.10);
  if v_reclaimed is null or v_reclaimed=v_first then
    raise exception 'A dead worker lease was not safely reclaimed';
  end if;
  begin
    perform public.complete_bike_route_price_calculation(v_request,v_first,1000,300);
    raise exception 'A stale worker completed a reclaimed pricing lease';
  exception when check_violation then null; end;
  perform public.release_bike_route_price_calculation(v_request,v_first);
  if public.claim_bike_route_price_calculation(v_request,4.88,7.00,4.90,7.10) is not null then
    raise exception 'A stale worker released the new owner lease';
  end if;

  perform public.release_bike_route_price_calculation(v_request,v_reclaimed);
  if public.claim_bike_route_price_calculation(v_request,4.88,7.00,4.90,7.10) is null then
    raise exception 'A released lease could not be claimed again';
  end if;

  if has_table_privilege('authenticated','public.bike_route_price_leases','SELECT')
    or has_table_privilege('service_role','public.bike_route_price_leases','UPDATE')
    or has_function_privilege('authenticated',
      'public.complete_bike_route_price_calculation(uuid,uuid,integer,integer)','EXECUTE') then
    raise exception 'Pricing lease storage or RPC leaked to clients';
  end if;
end $$;

rollback;
