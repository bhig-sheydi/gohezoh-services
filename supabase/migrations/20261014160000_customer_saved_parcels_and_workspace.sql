-- Reusable customer parcel templates, bounded to the researched small-carton envelope.
-- Reference: Indomie 40 x 70 g carton, 33 x 20 x 23.5 cm and 3.3 kg gross.
create table public.customer_saved_parcels (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  item_name text not null check (length(btrim(item_name)) between 1 and 100),
  description text not null check (length(btrim(description)) between 1 and 500),
  declared_value numeric(14,2) not null check (declared_value >= 0),
  price numeric(14,2) not null check (price >= 0),
  length_cm numeric(5,1) not null check (length_cm > 0 and length_cm <= 33),
  width_cm numeric(5,1) not null check (width_cm > 0 and width_cm <= 20),
  height_cm numeric(5,1) not null check (height_cm > 0 and height_cm <= 23.5),
  weight_kg numeric(5,3) not null check (weight_kg > 0 and weight_kg <= 3.3),
  photo_path text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (photo_path ~ '^[0-9a-fA-F-]{36}/[^/]+\.(jpg|jpeg|png|webp)$')
);
create index customer_saved_parcels_user_created_idx on public.customer_saved_parcels(user_id,created_at desc);
alter table public.customer_saved_parcels enable row level security;
revoke all on public.customer_saved_parcels from public,anon;
grant select,insert,update,delete on public.customer_saved_parcels to authenticated;
create policy customer_saved_parcels_customer_owner on public.customer_saved_parcels
for all to authenticated
using (user_id=auth.uid() and public.is_customer_parcel_pal_user(auth.uid()))
with check (user_id=auth.uid() and public.is_customer_parcel_pal_user(auth.uid()));

create or replace function public.validate_customer_saved_parcel_photo()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if split_part(new.photo_path,'/',1)<>new.user_id::text then
    raise insufficient_privilege using message='Saved parcel photos must belong to the signed-in customer';
  end if;
  new.updated_at:=now();
  return new;
end $$;
revoke all on function public.validate_customer_saved_parcel_photo() from public,anon,authenticated;
create trigger validate_customer_saved_parcel_photo_before_write
before insert or update on public.customer_saved_parcels
for each row execute function public.validate_customer_saved_parcel_photo();

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('customer-saved-parcels','customer-saved-parcels',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy customer_saved_parcel_photos_read on storage.objects for select to authenticated
using(bucket_id='customer-saved-parcels' and public.is_customer_parcel_pal_user(auth.uid()) and (storage.foldername(name))[1]=auth.uid()::text);
create policy customer_saved_parcel_photos_insert on storage.objects for insert to authenticated
with check(bucket_id='customer-saved-parcels' and public.is_customer_parcel_pal_user(auth.uid()) and (storage.foldername(name))[1]=auth.uid()::text and array_length(storage.foldername(name),1)=1);
create policy customer_saved_parcel_photos_update on storage.objects for update to authenticated
using(bucket_id='customer-saved-parcels' and public.is_customer_parcel_pal_user(auth.uid()) and (storage.foldername(name))[1]=auth.uid()::text and array_length(storage.foldername(name),1)=1)
with check(bucket_id='customer-saved-parcels' and public.is_customer_parcel_pal_user(auth.uid()) and (storage.foldername(name))[1]=auth.uid()::text and array_length(storage.foldername(name),1)=1);
create policy customer_saved_parcel_photos_delete on storage.objects for delete to authenticated
using(bucket_id='customer-saved-parcels' and public.is_customer_parcel_pal_user(auth.uid()) and (storage.foldername(name))[1]=auth.uid()::text and array_length(storage.foldername(name),1)=1);

alter table public.job_parcels add column item_price numeric(14,2) check(item_price is null or item_price>=0);

create or replace function public.validate_service_request_parcels()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
declare v_item jsonb; v_number numeric;
begin
  if new.parcel_items is null then return new; end if;
  if jsonb_typeof(new.parcel_items)<>'array' or jsonb_array_length(new.parcel_items) not between 1 and 50 then
    raise check_violation using message='Enter between one and fifty parcels';
  end if;
  for v_item in select value from jsonb_array_elements(new.parcel_items) loop
    if jsonb_typeof(v_item)<>'object' or length(btrim(coalesce(v_item->>'description','')))=0
      or coalesce(v_item->>'quantity','') !~ '^[1-9][0-9]*$'
      or (v_item ? 'weight_kg' and v_item->>'weight_kg' is not null and (v_item->>'weight_kg') !~ '^[0-9]+(\.[0-9]{1,9})?$') then
      raise check_violation using message='Each parcel needs a description, positive quantity, and valid weight';
    end if;
    if (v_item->>'quantity')::numeric>2147483647 or (v_item ? 'weight_kg' and v_item->>'weight_kg' is not null and (v_item->>'weight_kg')::numeric>3.3) then
      raise check_violation using message='Parcel quantity or weight exceeds the allowed limit';
    end if;
    foreach v_number in array array[
      nullif(v_item->>'length_cm','')::numeric,
      nullif(v_item->>'width_cm','')::numeric,
      nullif(v_item->>'height_cm','')::numeric,
      nullif(v_item->>'declared_value','')::numeric,
      nullif(v_item->>'price','')::numeric
    ] loop
      if v_number is not null and v_number<0 then raise check_violation using message='Parcel values cannot be negative'; end if;
    end loop;
    if (v_item ? 'length_cm' and nullif(v_item->>'length_cm','')::numeric>33)
      or (v_item ? 'width_cm' and nullif(v_item->>'width_cm','')::numeric>20)
      or (v_item ? 'height_cm' and nullif(v_item->>'height_cm','')::numeric>23.5)
      or (v_item ? 'declared_value' and nullif(v_item->>'declared_value','')::numeric>999999999999.99)
      or (v_item ? 'price' and nullif(v_item->>'price','')::numeric>999999999999.99) then
      raise check_violation using message='Parcel dimensions or value exceeds the allowed limit';
    end if;
  end loop;
  return new;
end $$;

create or replace function public.create_job_parcels_from_request()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_request public.service_requests%rowtype; v_item jsonb; v_number integer:=0;
begin
  select r.* into v_request from public.orders o join public.service_requests r on r.id=o.service_request_id where o.id=new.order_id;
  if not found then raise foreign_key_violation using message='Job order has no service request'; end if;
  if v_request.parcel_items is not null then
    for v_item in select value from jsonb_array_elements(v_request.parcel_items) loop
      v_number:=v_number+1;
      insert into public.job_parcels(job_id,parcel_number,description,quantity,weight_kg,length_cm,width_cm,height_cm,declared_value,item_price)
      values(new.id,v_number,btrim(v_item->>'description'),(v_item->>'quantity')::integer,
        nullif(v_item->>'weight_kg','')::numeric,nullif(v_item->>'length_cm','')::numeric,
        nullif(v_item->>'width_cm','')::numeric,nullif(v_item->>'height_cm','')::numeric,
        nullif(v_item->>'declared_value','')::numeric,nullif(v_item->>'price','')::numeric);
    end loop;
  elsif nullif(btrim(coalesce(v_request.parcel_summary,'')),'') is not null then
    insert into public.job_parcels(job_id,parcel_number,description,quantity) values(new.id,1,btrim(v_request.parcel_summary),1);
  end if;
  return new;
end $$;
revoke all on function public.create_job_parcels_from_request() from public,anon,authenticated;\n