-- Preserve parcel details from a customer's request through the job/waybill.
alter table public.service_requests add column parcel_items jsonb;

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
       or (v_item ? 'weight_kg' and v_item->>'weight_kg' is not null and (v_item->>'weight_kg') !~ '^[0-9]+(\.[0-9]{1,3})?$') then
      raise check_violation using message='Each parcel needs a description, positive quantity, and valid weight';
    end if;
    if (v_item->>'quantity')::numeric > 2147483647
       or (v_item ? 'weight_kg' and v_item->>'weight_kg' is not null and (v_item->>'weight_kg')::numeric > 9999999.999) then
      raise check_violation using message='Parcel quantity or weight is too large';
    end if;
  end loop;
  return new;
end $$;
create trigger validate_service_request_parcels_before_write
before insert or update of parcel_items on public.service_requests
for each row execute function public.validate_service_request_parcels();

create or replace function public.create_job_parcels_from_request()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_request public.service_requests%rowtype;v_item jsonb;v_number integer:=0;
begin
  select r.* into v_request from public.orders o
  join public.service_requests r on r.id=o.service_request_id where o.id=new.order_id;
  if not found then raise foreign_key_violation using message='Job order has no service request'; end if;
  if v_request.parcel_items is not null then
    for v_item in select value from jsonb_array_elements(v_request.parcel_items) loop
      v_number:=v_number+1;
      insert into public.job_parcels(job_id,parcel_number,description,quantity,weight_kg)
      values(new.id,v_number,btrim(v_item->>'description'),(v_item->>'quantity')::integer,
             nullif(v_item->>'weight_kg','')::numeric);
    end loop;
  elsif nullif(btrim(coalesce(v_request.parcel_summary,'')),'') is not null then
    -- Historical and warehouse-originated requests predate structured parcel capture.
    insert into public.job_parcels(job_id,parcel_number,description,quantity)
    values(new.id,1,btrim(v_request.parcel_summary),1);
  end if;
  return new;
end $$;
create trigger create_job_parcels_after_insert
after insert on public.jobs for each row execute function public.create_job_parcels_from_request();

revoke all on function public.create_job_parcels_from_request() from public,anon,authenticated;
revoke all on function public.validate_service_request_parcels() from public,anon,authenticated;
