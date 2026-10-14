-- Enforce aggregate shipment capacity for repeated identical items.
-- Dimensions are estimated as a regular packed grid; items may be rotated.
create or replace function public.validate_service_request_parcels()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
declare
  v_item jsonb;
  v_number numeric;
  v_quantity integer;
  v_length numeric;
  v_width numeric;
  v_height numeric;
  v_weight numeric;
  v_fits boolean;
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

    if (v_item->>'quantity')::numeric>50 then raise check_violation using message='Choose between one and fifty matching items'; end if;
    v_quantity:=(v_item->>'quantity')::integer;
    v_weight:=nullif(v_item->>'weight_kg','')::numeric;
    v_length:=nullif(v_item->>'length_cm','')::numeric;
    v_width:=nullif(v_item->>'width_cm','')::numeric;
    v_height:=nullif(v_item->>'height_cm','')::numeric;
    if (v_length is not null and v_length<=0) or (v_width is not null and v_width<=0) or (v_height is not null and v_height<=0) then
      raise check_violation using message='Parcel dimensions must be greater than zero';
    end if;
    if v_weight is not null then
      if v_weight<=0 or v_weight>9.9 or v_weight*v_quantity>9.9 then
        raise check_violation using message='The selected item count exceeds the 9.9 kg shipment limit';
      end if;
    end if;

    foreach v_number in array array[v_length,v_width,v_height,nullif(v_item->>'declared_value','')::numeric,nullif(v_item->>'price','')::numeric] loop
      if v_number is not null and v_number<0 then raise check_violation using message='Parcel measurements and values cannot be negative'; end if;
    end loop;
    if (v_length is not null and v_length>99) or (v_width is not null and v_width>60) or (v_height is not null and v_height>70.5)
      or (v_item ? 'declared_value' and nullif(v_item->>'declared_value','')::numeric>999999999999.99)
      or (v_item ? 'price' and nullif(v_item->>'price','')::numeric>999999999999.99) then
      raise check_violation using message='Parcel dimensions or value exceeds the allowed limit';
    end if;

    if v_length is not null and v_width is not null and v_height is not null then
      v_fits :=
        floor(99/v_length)*floor(60/v_width)*floor(70.5/v_height)>=v_quantity or
        floor(99/v_length)*floor(70.5/v_width)*floor(60/v_height)>=v_quantity or
        floor(60/v_length)*floor(99/v_width)*floor(70.5/v_height)>=v_quantity or
        floor(60/v_length)*floor(70.5/v_width)*floor(99/v_height)>=v_quantity or
        floor(70.5/v_length)*floor(99/v_width)*floor(60/v_height)>=v_quantity or
        floor(70.5/v_length)*floor(60/v_width)*floor(99/v_height)>=v_quantity;
      if not v_fits then raise check_violation using message='The selected item count does not fit within the shipment dimensions'; end if;
    end if;
  end loop;
  return new;
end $$;
revoke all on function public.validate_service_request_parcels() from public,anon,authenticated;
