-- Local bike parcels use server-owned packed-size estimates. Historical weights and prices stay intact.
create table public.bike_item_catalogue (
  code text primary key check (code ~ '^[a-z0-9_]+$'),
  category text not null,
  label text not null,
  length_cm numeric(5,1) not null check (length_cm > 0 and length_cm <= 38),
  width_cm numeric(5,1) not null check (width_cm > 0 and width_cm <= 32),
  height_cm numeric(5,1) not null check (height_cm > 0 and height_cm <= 32),
  estimated_weight_kg numeric(5,2) not null check (estimated_weight_kg > 0 and estimated_weight_kg <= 25),
  measurement text not null default 'unit' check (measurement in ('unit','pages')),
  enabled boolean not null default true
);
alter table public.bike_item_catalogue enable row level security;
create policy bike_item_catalogue_read on public.bike_item_catalogue for select to authenticated using (enabled);
grant select on public.bike_item_catalogue to authenticated;

-- Measurements include normal protective packaging; estimates, not manufacturer specifications.
insert into public.bike_item_catalogue(code,category,label,length_cm,width_cm,height_cm,estimated_weight_kg,measurement) values
('documents','Documents','Documents / loose papers',32,24,1,0.10,'pages'),
('passport','Documents','Passport or small booklet',16,12,3,0.20,'unit'),
('book','Documents','Paperback book',24,17,4,0.40,'unit'),
('textbook','Documents','Textbook',29,23,6,1.20,'unit'),
('folder','Documents','File folder / certificate',35,27,3,0.50,'unit'),
('magazine','Documents','Magazine / catalogue',30,24,3,0.35,'unit'),
('business_cards','Documents','Box of business cards',12,8,6,0.30,'unit'),
('wig_short','Hair & beauty','Short wig (up to 12 inches)',25,20,9,0.45,'unit'),
('wig_medium','Hair & beauty','Medium wig (13–20 inches)',30,25,13,0.75,'unit'),
('wig_long','Hair & beauty','Long wig (21–30 inches)',35,28,18,1.10,'unit'),
('hair_bundle','Hair & beauty','Hair bundle / extension',32,13,7,0.30,'unit'),
('braiding_hair','Hair & beauty','Braiding hair pack',35,16,10,0.40,'unit'),
('hair_accessories','Hair & beauty','Hair clips / ornaments',16,12,6,0.20,'unit'),
('hair_bonnet','Hair & beauty','Hair bonnet',18,15,5,0.15,'unit'),
('cosmetics_small','Hair & beauty','Small makeup / skincare pack',18,14,9,0.35,'unit'),
('cosmetics_set','Hair & beauty','Makeup or skincare set',27,22,14,1.00,'unit'),
('shampoo','Hair & beauty','Sealed shampoo / lotion bottle',23,12,12,0.75,'unit'),
('shirt','Clothing','Shirt / blouse',27,23,5,0.35,'unit'),
('trousers','Clothing','Trousers / jeans',30,25,7,0.70,'unit'),
('dress','Clothing','Dress / gown',32,27,9,0.75,'unit'),
('wrapper','Clothing','Wrapper / ankara fabric',34,27,8,1.10,'unit'),
('aso_oke','Clothing','Aso-oke / folded ceremonial cloth',35,28,11,1.50,'unit'),
('tshirt_pack','Clothing','Pack of T-shirts',32,26,10,1.00,'unit'),
('baby_clothes','Clothing','Baby clothing pack',27,22,8,0.50,'unit'),
('sneakers','Fashion accessories','Pair of sneakers',35,24,15,1.20,'unit'),
('sandals','Fashion accessories','Pair of sandals / slippers',30,22,11,0.70,'unit'),
('handbag','Fashion accessories','Handbag',34,25,20,1.20,'unit'),
('small_bag','Fashion accessories','Small purse / wallet',20,15,8,0.40,'unit'),
('belt','Fashion accessories','Belt',24,18,6,0.25,'unit'),
('sunglasses','Fashion accessories','Sunglasses in case',18,10,8,0.20,'unit'),
('watch','Fashion accessories','Wristwatch in box',15,15,10,0.40,'unit'),
('phone','Electronics','Mobile phone in box',20,12,8,0.60,'unit'),
('tablet','Electronics','Tablet in box',30,23,8,1.10,'unit'),
('laptop_small','Electronics','Small laptop in padded case',38,28,9,2.50,'unit'),
('earbuds','Electronics','Earbuds / headphones',22,18,10,0.45,'unit'),
('charger','Electronics','Phone charger / cable pack',16,12,7,0.25,'unit'),
('power_bank','Electronics','Power bank in retail box',20,13,8,0.55,'unit'),
('router','Electronics','Wi-Fi router in box',27,22,12,0.90,'unit'),
('game_console','Electronics','Game console in box',37,30,16,3.50,'unit'),
('keyboard','Electronics','Computer keyboard',38,18,8,0.90,'unit'),
('mouse','Electronics','Computer mouse in box',16,12,9,0.25,'unit'),
('camera','Electronics','Camera in padded case',27,22,17,1.50,'unit'),
('speaker','Home electronics','Small Bluetooth speaker',26,20,20,1.70,'unit'),
('blender','Home electronics','Small blender in box',30,25,29,2.60,'unit'),
('kettle','Home electronics','Electric kettle in box',26,23,28,1.80,'unit'),
('iron','Home electronics','Electric iron in box',30,18,18,1.60,'unit'),
('hair_dryer','Home electronics','Hair dryer in box',32,24,16,1.20,'unit'),
('mini_fan','Home electronics','Mini fan in box',32,28,20,2.00,'unit'),
('lamp','Home electronics','Small lamp in box',30,25,23,1.20,'unit'),
('remote','Home electronics','Remote control',24,10,6,0.25,'unit'),
('meal_small','Food','Sealed small meal plate',22,22,10,0.80,'unit'),
('meal_medium','Food','Sealed medium meal plate',26,26,12,1.20,'unit'),
('meal_large','Food','Sealed large meal tray',32,30,15,2.00,'unit'),
('cake_small','Food','Small cake in box (6 inch)',23,23,20,1.50,'unit'),
('cake_medium','Food','Medium cake in box (8 inch)',28,28,23,2.50,'unit'),
('cake_large','Food','Large cake in box (10 inch)',34,32,27,4.00,'unit'),
('bread','Food','Loaf of bread',30,16,15,0.70,'unit'),
('pastries','Food','Pastry / snack box',28,22,12,1.00,'unit'),
('groceries_small','Food','Small sealed groceries bag',28,23,20,2.50,'unit'),
('groceries_medium','Food','Medium sealed groceries bag',34,28,26,5.00,'unit'),
('fruit_box','Food','Small fruit box',32,26,20,4.00,'unit'),
('dry_food','Food','Sealed dry food pack',27,22,15,2.00,'unit'),
('baby_formula','Baby & care','Baby formula tin',18,18,20,1.50,'unit'),
('diapers','Baby & care','Diaper pack',35,28,23,2.00,'unit'),
('baby_bottle','Baby & care','Baby bottle in box',20,15,13,0.35,'unit'),
('toys_small','Toys & gifts','Small toy in box',25,20,18,0.80,'unit'),
('toys_medium','Toys & gifts','Medium toy in box',35,28,24,1.80,'unit'),
('gift_box','Toys & gifts','Gift box / hamper',32,28,25,2.50,'unit'),
('flowers','Toys & gifts','Small bouquet in protective box',35,25,20,0.80,'unit'),
('stationery','Office & supplies','Stationery pack',24,18,9,0.80,'unit'),
('printer_paper','Office & supplies','Ream of A4 printer paper',32,24,7,2.50,'unit'),
('small_tools','Office & supplies','Small non-sharp tool kit',30,24,15,3.00,'unit'),
('car_part','Office & supplies','Small boxed vehicle part',32,26,20,4.00,'unit'),
('household_small','Home goods','Small household item',25,20,17,1.00,'unit'),
('cookware_small','Home goods','Small pot / cookware',32,28,22,2.00,'unit'),
('bedsheet','Home goods','Folded bedsheet / pillowcase',30,25,11,1.00,'unit'),
('towel','Home goods','Folded towel',28,23,10,0.75,'unit'),
('plastic_container','Home goods','Small storage container',32,27,21,1.00,'unit'),
('other_small','Other','Other small boxed item',25,20,18,2.00,'unit'),
('other_medium','Other','Other medium boxed item',34,28,24,5.00,'unit');

alter table public.customer_saved_parcels add column catalog_code text references public.bike_item_catalogue(code);
alter table public.customer_saved_parcels add column pages integer check (pages between 1 and 500);
alter table public.customer_saved_parcels drop constraint if exists customer_saved_parcels_length_cm_check;
alter table public.customer_saved_parcels drop constraint if exists customer_saved_parcels_width_cm_check;
alter table public.customer_saved_parcels drop constraint if exists customer_saved_parcels_height_cm_check;
alter table public.customer_saved_parcels drop constraint if exists customer_saved_parcels_weight_kg_check;
alter table public.customer_saved_parcels add constraint saved_bike_box_dimensions check
  (length_cm > 0 and length_cm <= 38 and width_cm > 0 and width_cm <= 32 and height_cm > 0 and height_cm <= 32);
alter table public.customer_saved_parcels add constraint saved_bike_box_weight check (weight_kg > 0 and weight_kg <= 25);
alter table public.customer_saved_parcels add constraint saved_goods_value_limit check (declared_value <= 70000) not valid;

create or replace function public.normalize_saved_bike_item() returns trigger
language plpgsql set search_path=pg_catalog,public as $$
declare v_entry public.bike_item_catalogue%rowtype;
begin
  if new.catalog_code is null then
    if tg_op='INSERT' then raise check_violation using message='Choose an item from the catalogue'; end if;
    return new;
  end if;
  select * into v_entry from public.bike_item_catalogue where code=new.catalog_code and enabled;
  if not found then raise check_violation using message='Choose an available item'; end if;
  if v_entry.measurement='pages' then
    if new.pages is null or new.pages not between 1 and 500 then
      raise check_violation using message='Choose 1 to 500 document pages'; end if;
    new.height_cm:=round(0.5+new.pages*0.01,1);
    new.weight_kg:=0.02+new.pages*0.005;
  else
    new.pages:=null;
    new.height_cm:=v_entry.height_cm;
    new.weight_kg:=v_entry.estimated_weight_kg;
  end if;
  new.length_cm:=v_entry.length_cm; new.width_cm:=v_entry.width_cm;
  return new;
end $$;
create trigger normalize_saved_bike_item_before_write before insert or update on public.customer_saved_parcels
for each row execute function public.normalize_saved_bike_item();

create or replace function public.validate_service_request_parcels()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
declare v_item jsonb; v_entry public.bike_item_catalogue%rowtype; v_items jsonb:='[]'::jsonb;
  v_quantity integer; v_pages integer; v_length numeric; v_width numeric; v_height numeric;
  v_total_volume numeric:=0; v_total_weight numeric:=0; v_total_value numeric:=0; v_fits boolean;
begin
  if new.parcel_items is null then return new; end if;
  -- Trusted service-role imports may still carry historical parcel shapes.
  if auth.uid() is null then return new; end if;
  if tg_op='UPDATE' and new.parcel_items is not distinct from old.parcel_items then return new; end if;
  if tg_op='UPDATE' and exists(select 1 from public.bike_route_prices where request_id=new.id) then
    raise check_violation using message='Parcel details cannot change after a price is issued'; end if;
  if jsonb_typeof(new.parcel_items)<>'array' or jsonb_array_length(new.parcel_items) not between 1 and 50 then
    raise check_violation using message='Choose a valid parcel item'; end if;
  for v_item in select value from jsonb_array_elements(new.parcel_items) loop
    if jsonb_typeof(v_item)<>'object' or coalesce(v_item->>'quantity','') !~ '^[1-9][0-9]*$'
      or length(btrim(coalesce(v_item->>'description',''))) not between 1 and 500
      or coalesce(v_item->>'declared_value','0') !~ '^[0-9]+(\.[0-9]{1,2})?$'
      or (v_item ? 'price' and v_item->>'price' !~ '^[0-9]+(\.[0-9]{1,2})?$') then
      raise check_violation using message='Choose an item, count, description and declared value'; end if;
    select * into v_entry from public.bike_item_catalogue where code=v_item->>'catalog_code' and enabled;
    if not found then raise check_violation using message='Choose an item from the catalogue'; end if;
    if (v_item->>'quantity')::numeric>50 then raise check_violation using message='Choose at most 50 matching units'; end if;
    v_quantity:=(v_item->>'quantity')::integer;
    v_pages:=0;
    if v_entry.measurement='pages' then
      if coalesce(v_item->>'pages','') !~ '^[1-9][0-9]*$' or (v_item->>'pages')::numeric>500 then
        raise check_violation using message='Choose 1 to 500 pages per document envelope'; end if;
      v_pages:=(v_item->>'pages')::integer;
    end if;
    v_length:=v_entry.length_cm; v_width:=v_entry.width_cm;
    v_height:=case when v_entry.measurement='pages' then round(0.5+v_pages*0.01,1) else v_entry.height_cm end;
    v_fits:=
      floor(38/v_length)*floor(32/v_width)*floor(32/v_height)>=v_quantity or
      floor(38/v_length)*floor(32/v_height)*floor(32/v_width)>=v_quantity or
      floor(38/v_width)*floor(32/v_length)*floor(32/v_height)>=v_quantity or
      floor(38/v_width)*floor(32/v_height)*floor(32/v_length)>=v_quantity or
      floor(38/v_height)*floor(32/v_length)*floor(32/v_width)>=v_quantity or
      floor(38/v_height)*floor(32/v_width)*floor(32/v_length)>=v_quantity;
    if not v_fits then raise check_violation using message='These matching units do not fit a bike box'; end if;
    v_total_volume:=v_total_volume+v_length*v_width*v_height*v_quantity;
    v_total_weight:=v_total_weight+(case when v_entry.measurement='pages' then 0.02+v_pages*0.005 else v_entry.estimated_weight_kg end)*v_quantity;
    v_total_value:=v_total_value+coalesce((v_item->>'declared_value')::numeric,0)*v_quantity;
    v_items:=v_items||jsonb_build_array((v_item - 'length_cm' - 'width_cm' - 'height_cm' - 'weight_kg')
      ||jsonb_build_object('length_cm',v_length,'width_cm',v_width,'height_cm',v_height,
        'weight_kg',least(25,case when v_entry.measurement='pages' then 0.02+v_pages*0.005 else v_entry.estimated_weight_kg end)));
  end loop;
  if v_total_volume>38912 or v_total_weight>25 then
    raise check_violation using message='These items exceed a bike box; reduce the quantity or request a larger vehicle'; end if;
  if v_total_value>70000 then
    raise check_violation using message='The combined declared worth of goods must not exceed NGN 70,000'; end if;
  new.parcel_items:=v_items;
  return new;
end $$;

create or replace function public.catalogue_customer_delivery_item() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_item jsonb; v_description text; v_saved_id text;
begin
  if auth.uid() is distinct from new.created_by or not public.has_role(auth.uid(),'customer') then return new; end if;
  if new.parcel_photo_path is null then raise check_violation using message='Add a photo of the goods before requesting delivery'; end if;
  v_item:=new.parcel_items->0;
  if jsonb_typeof(v_item) is distinct from 'object' or nullif(btrim(v_item->>'description'),'') is null
    or nullif(v_item->>'catalog_code','') is null then
    raise check_violation using message='Choose an item from the catalogue'; end if;
  v_description:=btrim(v_item->>'description'); v_saved_id:=v_item->>'saved_parcel_id';
  if v_saved_id ~ '^[0-9a-fA-F-]{36}$' then
    update public.customer_saved_parcels set description=v_description,catalog_code=v_item->>'catalog_code',
      pages=nullif(v_item->>'pages','')::integer,
      declared_value=coalesce((v_item->>'declared_value')::numeric,0),price=coalesce((v_item->>'price')::numeric,0),
      length_cm=(v_item->>'length_cm')::numeric,width_cm=(v_item->>'width_cm')::numeric,
      height_cm=(v_item->>'height_cm')::numeric,weight_kg=(v_item->>'weight_kg')::numeric
    where id=v_saved_id::uuid and user_id=new.created_by and photo_path=new.parcel_photo_path;
    if found then return new; end if;
  end if;
  insert into public.customer_saved_parcels(user_id,item_name,description,declared_value,price,
    length_cm,width_cm,height_cm,weight_kg,photo_path,catalog_code,pages)
  values(new.created_by,left(v_description,100),v_description,
    coalesce((v_item->>'declared_value')::numeric,0),coalesce((v_item->>'price')::numeric,0),
    (v_item->>'length_cm')::numeric,(v_item->>'width_cm')::numeric,
    (v_item->>'height_cm')::numeric,(v_item->>'weight_kg')::numeric,new.parcel_photo_path,v_item->>'catalog_code',
    nullif(v_item->>'pages','')::integer);
  return new;
end $$;

-- The route price remains immutable per request. Packed space is a surcharge on that price.
alter table public.bike_route_prices add column space_surcharge_ngn integer not null default 0;
create or replace function public.record_bike_route_price(p_request_id uuid,p_distance_metres integer,p_duration_seconds integer)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_policy public.bike_price_policy%rowtype; v_request public.service_requests%rowtype;
  v_price integer; v_space integer; v_volume numeric; v_pages integer;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v_request from public.service_requests where id=p_request_id;
  if not found or v_request.pickup_city<>v_request.delivery_city or v_request.pickup_latitude is null
    or v_request.pickup_longitude is null or v_request.delivery_latitude is null or v_request.delivery_longitude is null then
    raise check_violation using message='Only geocoded local requests can use automatic bike pricing'; end if;
  if p_distance_metres not between 100 and 200000 or p_duration_seconds not between 30 and 86400 then
    raise check_violation using message='Invalid route distance or duration'; end if;
  select * into v_policy from public.bike_price_policy where id=true;
  v_volume:=coalesce((select sum((item->>'length_cm')::numeric*(item->>'width_cm')::numeric*(item->>'height_cm')::numeric
    *(item->>'quantity')::integer) from jsonb_array_elements(v_request.parcel_items) item),0);
  v_pages:=coalesce((select sum((item->>'pages')::integer*(item->>'quantity')::integer)
    from jsonb_array_elements(v_request.parcel_items) item where item->>'catalog_code'='documents'),0);
  v_space:=ceil(greatest(0,v_volume-3000)/1000.0*40/50.0)::integer*50
    +ceil(v_pages/100.0)::integer*50;
  v_price:=public.bike_customer_price(p_distance_metres,v_policy.fuel_price_ngn,v_policy.benchmark_distance_metres,
    v_policy.benchmark_charge_ngn,v_policy.benchmark_fuel_price_ngn,v_policy.litres_per_km)+v_space;
  insert into public.bike_route_prices(request_id,distance_metres,duration_seconds,customer_price_ngn,
    estimated_fuel_litres,fuel_price_ngn_per_litre,source,space_surcharge_ngn)
  values(p_request_id,p_distance_metres,p_duration_seconds,v_price,
    round(p_distance_metres/1000.0*v_policy.litres_per_km,3),v_policy.fuel_price_ngn,'google_routes_drive',v_space)
  on conflict(request_id) do nothing;
end $$;
