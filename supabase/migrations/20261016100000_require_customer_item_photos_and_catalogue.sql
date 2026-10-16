-- A customer delivery and its reusable item record are committed together.
create function public.catalogue_customer_delivery_item() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_item jsonb; v_description text; v_saved_id text;
begin
  if auth.uid() is distinct from new.created_by or not public.has_role(auth.uid(),'customer') then return new; end if;
  if new.parcel_photo_path is null then
    raise check_violation using message='Add a photo of the goods before requesting delivery';
  end if;
  v_item:=new.parcel_items->0;
  if jsonb_typeof(v_item) is distinct from 'object' or nullif(btrim(v_item->>'description'),'') is null
    or nullif(v_item->>'weight_kg','') is null or nullif(v_item->>'length_cm','') is null
    or nullif(v_item->>'width_cm','') is null or nullif(v_item->>'height_cm','') is null then
    raise check_violation using message='Describe the item and select its weight and dimensions';
  end if;
  v_description:=btrim(v_item->>'description');
  v_saved_id:=v_item->>'saved_parcel_id';
  if v_saved_id ~ '^[0-9a-fA-F-]{36}$' then
    update public.customer_saved_parcels set description=v_description,
      declared_value=coalesce(nullif(v_item->>'declared_value','')::numeric,0),
      price=coalesce(nullif(v_item->>'price','')::numeric,0),
      length_cm=(v_item->>'length_cm')::numeric,width_cm=(v_item->>'width_cm')::numeric,
      height_cm=(v_item->>'height_cm')::numeric,weight_kg=(v_item->>'weight_kg')::numeric
    where id=v_saved_id::uuid and user_id=new.created_by and photo_path=new.parcel_photo_path;
    if found then return new; end if;
  end if;
  insert into public.customer_saved_parcels(user_id,item_name,description,declared_value,price,
    length_cm,width_cm,height_cm,weight_kg,photo_path)
  values(new.created_by,left(v_description,100),v_description,
    coalesce(nullif(v_item->>'declared_value','')::numeric,0),
    coalesce(nullif(v_item->>'price','')::numeric,0),
    (v_item->>'length_cm')::numeric,(v_item->>'width_cm')::numeric,
    (v_item->>'height_cm')::numeric,(v_item->>'weight_kg')::numeric,new.parcel_photo_path);
  return new;
end $$;
revoke all on function public.catalogue_customer_delivery_item() from public,anon,authenticated;
create trigger catalogue_customer_delivery_item_after_insert after insert on public.service_requests
for each row execute function public.catalogue_customer_delivery_item();

-- A customer may remove a catalogue card, but historical delivery photos stay available.
create policy customer_parcel_sent_photo_retention on storage.objects as restrictive
for delete to authenticated using (
  bucket_id<>'customer-saved-parcels' or not exists(select 1 from public.service_requests r
    where r.parcel_photo_path=name)
);
