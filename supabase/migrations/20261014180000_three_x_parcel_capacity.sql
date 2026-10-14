-- Allow one destination shipment to contain up to 50 matching items and use
-- an outer parcel envelope up to three times the researched pilot carton.
alter table public.customer_saved_parcels
  drop constraint if exists customer_saved_parcels_length_cm_check,
  drop constraint if exists customer_saved_parcels_width_cm_check,
  drop constraint if exists customer_saved_parcels_height_cm_check,
  drop constraint if exists customer_saved_parcels_weight_kg_check;

alter table public.customer_saved_parcels
  add constraint customer_saved_parcels_length_capacity_check check (length_cm > 0 and length_cm <= 99),
  add constraint customer_saved_parcels_width_capacity_check check (width_cm > 0 and width_cm <= 60),
  add constraint customer_saved_parcels_height_capacity_check check (height_cm > 0 and height_cm <= 70.5),
  add constraint customer_saved_parcels_weight_capacity_check check (weight_kg > 0 and weight_kg <= 9.9);

create or replace function public.validate_service_request_parcels()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
declare v_item jsonb; v_number numeric;
begin
  if new.parcel_items is null then return new; end if;
  if jsonb_typeof(new.parcel_items)<>'array' or jsonb_array_length(new.parcel_items) not between 1 and 50 then
    raise check_violation using message='Enter between one and fifty parcel types';
  end if;
  for v_item in select value from jsonb_array_elements(new.parcel_items) loop
    if jsonb_typeof(v_item)<>'object'
      or length(btrim(coalesce(v_item->>'description','')))=0
      or coalesce(v_item->>'quantity','') !~ '^[1-9][0-9]*$'
      or (v_item ? 'weight_kg' and v_item->>'weight_kg' is not null and (v_item->>'weight_kg') !~ '^[0-9]+(\.[0-9]{1,9})?$')
      or (v_item ? 'length_cm' and v_item->>'length_cm' is not null and (v_item->>'length_cm') !~ '^[0-9]+(\.[0-9]{1,9})?$')
      or (v_item ? 'width_cm' and v_item->>'width_cm' is not null and (v_item->>'width_cm') !~ '^[0-9]+(\.[0-9]{1,9})?$')
      or (v_item ? 'height_cm' and v_item->>'height_cm' is not null and (v_item->>'height_cm') !~ '^[0-9]+(\.[0-9]{1,9})?$') then
      raise check_violation using message='Each parcel needs a description, valid item count, and numeric measurements';
    end if;
    if (v_item->>'quantity')::numeric>50
      or (v_item ? 'weight_kg' and v_item->>'weight_kg' is not null and (v_item->>'weight_kg')::numeric>9.9) then
      raise check_violation using message='Item count or parcel weight exceeds the allowed limit';
    end if;
    foreach v_number in array array[
      nullif(v_item->>'length_cm','')::numeric,
      nullif(v_item->>'width_cm','')::numeric,
      nullif(v_item->>'height_cm','')::numeric,
      nullif(v_item->>'declared_value','')::numeric,
      nullif(v_item->>'price','')::numeric
    ] loop
      if v_number is not null and v_number<0 then
        raise check_violation using message='Parcel measurements and values cannot be negative';
      end if;
    end loop;
    if (v_item ? 'length_cm' and nullif(v_item->>'length_cm','')::numeric>99)
      or (v_item ? 'width_cm' and nullif(v_item->>'width_cm','')::numeric>60)
      or (v_item ? 'height_cm' and nullif(v_item->>'height_cm','')::numeric>70.5)
      or (v_item ? 'declared_value' and nullif(v_item->>'declared_value','')::numeric>999999999999.99)
      or (v_item ? 'price' and nullif(v_item->>'price','')::numeric>999999999999.99) then
      raise check_violation using message='Parcel dimensions or value exceeds the allowed limit';
    end if;
  end loop;
  return new;
end $$;
revoke all on function public.validate_service_request_parcels() from public,anon,authenticated;
