-- A fixed booking component is added to the existing distance/fuel bike fare.
-- Prices already snapshotted in bike_route_prices remain unchanged.
create or replace function public.bike_customer_price(p_distance_metres integer,p_fuel_price_ngn numeric,
  p_benchmark_distance_metres integer,p_benchmark_charge_ngn numeric,p_benchmark_fuel_price_ngn numeric,
  p_litres_per_km numeric) returns integer
language sql immutable set search_path=pg_catalog as $$
  select 1000 + greatest(1000,ceil((p_benchmark_charge_ngn * p_distance_metres / p_benchmark_distance_metres
    + p_distance_metres / 1000.0 * p_litres_per_km * (p_fuel_price_ngn-p_benchmark_fuel_price_ngn))/100.0)*100)::integer;
$$;
