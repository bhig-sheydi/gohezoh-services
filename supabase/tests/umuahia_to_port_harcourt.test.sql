begin;
do $$
begin
  if not exists (
    select 1 from public.coverage_corridors corridor
    join public.coverage_locations origin on origin.id = corridor.origin_id
    join public.coverage_locations destination on destination.id = corridor.destination_id
    where origin.name = 'Umuahia'
      and destination.name = 'Port Harcourt'
      and corridor.service_code = 'SRV-0002'
      and corridor.is_enabled
      and origin.is_enabled
      and destination.is_enabled
  ) then
    raise exception 'Umuahia to Port Harcourt interstate service is unavailable';
  end if;
end $$;
rollback;
