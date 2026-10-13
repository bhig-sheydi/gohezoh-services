-- Store all entered units as kilograms without rounding milligram values to zero.
alter table public.inventory_items alter column weight_kg type numeric(16,9);
alter table public.job_parcels alter column weight_kg type numeric(16,9);

create or replace function public.validate_service_request_parcels()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
declare v_item jsonb;
begin
  if new.parcel_items is null then return new; end if;
  if jsonb_typeof(new.parcel_items) <> 'array' or jsonb_array_length(new.parcel_items) not between 1 and 50 then
    raise check_violation using message='Enter between one and fifty parcels';
  end if;
  for v_item in select value from jsonb_array_elements(new.parcel_items) loop
    if jsonb_typeof(v_item) <> 'object'
       or length(btrim(coalesce(v_item->>'description',''))) = 0
       or coalesce(v_item->>'quantity','') !~ '^[1-9][0-9]*$'
       or (v_item ? 'weight_kg' and v_item->>'weight_kg' is not null and (v_item->>'weight_kg') !~ '^[0-9]+(\.[0-9]{1,9})?$') then
      raise check_violation using message='Each parcel needs a description, positive quantity, and valid weight';
    end if;
    if (v_item->>'quantity')::numeric > 2147483647
       or (v_item ? 'weight_kg' and v_item->>'weight_kg' is not null and (v_item->>'weight_kg')::numeric > 9999999.999999999) then
      raise check_violation using message='Parcel quantity or weight is too large';
    end if;
  end loop;
  return new;
end $$;
