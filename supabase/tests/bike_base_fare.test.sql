begin;
do $$
begin
  if public.bike_customer_price(3580,1400,13019,4000,1400,0.025) <> 2100 then
    raise exception 'Former NGN 1100 route must cost NGN 2100 with the booking charge';
  end if;
  if public.bike_customer_price(100,1400,13019,4000,1400,0.025) <> 2000 then
    raise exception 'Bike fare minimum must be NGN 2000 including booking charge';
  end if;
  if public.bike_customer_price(3580,1500,13019,4000,1400,0.025) <= 2100 then
    raise exception 'Increased fuel price must raise the bike fare';
  end if;
end $$;
rollback;
