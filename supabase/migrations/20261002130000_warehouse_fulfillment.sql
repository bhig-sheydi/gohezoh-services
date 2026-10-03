-- Phase 7: auditable customer inventory, reservation, picking, packing, and delivery handoff.
create sequence public.warehouse_number_seq start 1;
create sequence public.inventory_movement_number_seq start 1;
create sequence public.fulfillment_order_number_seq start 1;

create table public.warehouses (
  id uuid primary key default gen_random_uuid(),
  warehouse_number text not null unique default ('WH-'||lpad(nextval('public.warehouse_number_seq')::text,4,'0')),
  name text not null check(length(btrim(name)) between 2 and 120),
  code text not null unique check(code ~ '^[A-Z0-9_-]{2,20}$'),
  address text not null,
  city text not null,
  state text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  sku text not null check(length(btrim(sku)) between 1 and 80),
  name text not null check(length(btrim(name)) between 2 and 160),
  description text,
  unit text not null default 'unit',
  unit_value numeric(14,2) check(unit_value is null or unit_value>=0),
  weight_kg numeric(10,3) check(weight_kg is null or weight_kg>=0),
  dimensions_cm text,
  packaging_information text,
  handling_instructions text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique(customer_id,sku)
);

create table public.warehouse_inventory (
  warehouse_id uuid not null references public.warehouses(id) on delete restrict,
  inventory_item_id uuid not null references public.inventory_items(id) on delete restrict,
  location_code text,
  quantity_on_hand integer not null default 0 check(quantity_on_hand>=0),
  quantity_reserved integer not null default 0 check(quantity_reserved>=0 and quantity_reserved<=quantity_on_hand),
  updated_at timestamptz not null default now(),
  primary key(warehouse_id,inventory_item_id)
);

create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  movement_number text not null unique default ('INV-'||lpad(nextval('public.inventory_movement_number_seq')::text,6,'0')),
  warehouse_id uuid not null references public.warehouses(id) on delete restrict,
  inventory_item_id uuid not null references public.inventory_items(id) on delete restrict,
  fulfillment_order_id uuid,
  movement_type text not null check(movement_type in ('received','adjusted','reserved','released','picked','cancelled')),
  quantity_delta integer not null default 0,
  reserved_delta integer not null default 0,
  check(quantity_delta<>0 or reserved_delta<>0),
  note text,
  actor_id uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.fulfillment_orders (
  id uuid primary key default gen_random_uuid(),
  fulfillment_number text not null unique default ('FUL-'||lpad(nextval('public.fulfillment_order_number_seq')::text,5,'0')),
  customer_id uuid not null references public.customers(id) on delete restrict,
  warehouse_id uuid not null references public.warehouses(id) on delete restrict,
  status text not null default 'submitted' check(status in ('submitted','picking','packed','released','delivered','delivery_cancelled','cancelled')),
  delivery_address text not null,
  delivery_city text not null,
  delivery_state text,
  recipient_name text not null,
  recipient_phone text not null,
  customer_note text,
  created_by uuid not null references auth.users(id),
  service_request_id uuid unique references public.service_requests(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check((status in ('released','delivered','delivery_cancelled'))=(service_request_id is not null))
);

create table public.fulfillment_order_items (
  fulfillment_order_id uuid not null references public.fulfillment_orders(id) on delete restrict,
  inventory_item_id uuid not null references public.inventory_items(id) on delete restrict,
  quantity integer not null check(quantity>0),
  picked_quantity integer not null default 0 check(picked_quantity>=0 and picked_quantity<=quantity),
  primary key(fulfillment_order_id,inventory_item_id)
);
alter table public.inventory_movements add constraint inventory_movements_fulfillment_fk foreign key(fulfillment_order_id) references public.fulfillment_orders(id) on delete restrict;

create index inventory_customer_sku_idx on public.inventory_items(customer_id,sku);
create index inventory_movements_item_idx on public.inventory_movements(inventory_item_id,created_at desc);
create index fulfillment_customer_status_idx on public.fulfillment_orders(customer_id,status,created_at desc);

grant select,insert on public.warehouses,public.inventory_items to authenticated;
grant select on public.warehouse_inventory,public.inventory_movements,public.fulfillment_orders,public.fulfillment_order_items to authenticated;
revoke update,delete on public.warehouses,public.inventory_items,public.warehouse_inventory,public.inventory_movements,public.fulfillment_orders,public.fulfillment_order_items from authenticated;
grant usage on sequence public.warehouse_number_seq,public.inventory_movement_number_seq,public.fulfillment_order_number_seq to authenticated;

alter table public.warehouses enable row level security;
alter table public.inventory_items enable row level security;
alter table public.warehouse_inventory enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.fulfillment_orders enable row level security;
alter table public.fulfillment_order_items enable row level security;

create policy warehouses_staff_read on public.warehouses for select to authenticated
  using(is_active and (public.has_role(auth.uid(),'customer') or public.has_role(auth.uid(),'warehouse') or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')));
create policy warehouses_admin_write on public.warehouses for insert to authenticated
  with check(public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));
create policy inventory_items_related_read on public.inventory_items for select to authenticated
  using(public.has_role(auth.uid(),'warehouse') or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin') or public.is_customer_user(customer_id));
create policy inventory_items_staff_insert on public.inventory_items for insert to authenticated
  with check(created_by=auth.uid() and (public.has_role(auth.uid(),'warehouse') or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')));
create policy warehouse_inventory_staff_read on public.warehouse_inventory for select to authenticated
  using(public.has_role(auth.uid(),'warehouse') or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin') or exists(select 1 from public.inventory_items i where i.id=inventory_item_id and public.is_customer_user(i.customer_id)));
create policy inventory_movements_related_read on public.inventory_movements for select to authenticated
  using(public.has_role(auth.uid(),'warehouse') or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin') or exists(select 1 from public.inventory_items i where i.id=inventory_item_id and public.is_customer_user(i.customer_id)));
create policy fulfillment_orders_related_read on public.fulfillment_orders for select to authenticated
  using(created_by=auth.uid() or public.is_customer_user(customer_id) or public.has_role(auth.uid(),'warehouse') or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));
create policy fulfillment_lines_related_read on public.fulfillment_order_items for select to authenticated
  using(exists(select 1 from public.fulfillment_orders f where f.id=fulfillment_order_id and (f.created_by=auth.uid() or public.is_customer_user(f.customer_id) or public.has_role(auth.uid(),'warehouse') or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'))));
create policy customers_read_warehouse on public.customers for select to authenticated
  using(public.has_role(auth.uid(),'warehouse'));

create or replace function public.receive_inventory(
  p_warehouse_id uuid,p_customer_id uuid,p_sku text,p_name text,p_quantity integer,p_location_code text default null,
  p_description text default null,p_unit text default 'unit',p_unit_value numeric default null,p_weight_kg numeric default null,
  p_dimensions_cm text default null,p_packaging_information text default null,p_handling_instructions text default null
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_item uuid;v_movement public.inventory_movements%rowtype;
begin
  if v_actor is null or not(public.has_role(v_actor,'warehouse') or public.has_role(v_actor,'operations') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='Warehouse access is required';end if;
  if p_quantity<=0 or length(btrim(p_sku)) not between 1 and 80 or length(btrim(p_name)) not between 2 and 160 then raise check_violation using message='Enter a valid SKU, product name, and received quantity';end if;
  if not exists(select 1 from public.warehouses where id=p_warehouse_id and is_active) then raise foreign_key_violation using message='Choose an active warehouse';end if;
  if not(public.has_role(v_actor,'warehouse') or public.has_role(v_actor,'operations') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege;end if;
  insert into public.inventory_items(customer_id,sku,name,description,unit,unit_value,weight_kg,dimensions_cm,packaging_information,handling_instructions,created_by)
  values(p_customer_id,upper(btrim(p_sku)),btrim(p_name),p_description,coalesce(nullif(btrim(p_unit),''),'unit'),p_unit_value,p_weight_kg,p_dimensions_cm,p_packaging_information,p_handling_instructions,v_actor)
  on conflict(customer_id,sku) do update set name=excluded.name,description=coalesce(excluded.description,inventory_items.description),unit=excluded.unit,unit_value=coalesce(excluded.unit_value,inventory_items.unit_value),weight_kg=coalesce(excluded.weight_kg,inventory_items.weight_kg),dimensions_cm=coalesce(excluded.dimensions_cm,inventory_items.dimensions_cm),packaging_information=coalesce(excluded.packaging_information,inventory_items.packaging_information),handling_instructions=coalesce(excluded.handling_instructions,inventory_items.handling_instructions)
  returning id into v_item;
  insert into public.warehouse_inventory(warehouse_id,inventory_item_id,location_code,quantity_on_hand) values(p_warehouse_id,v_item,p_location_code,p_quantity)
  on conflict(warehouse_id,inventory_item_id) do update set location_code=coalesce(excluded.location_code,warehouse_inventory.location_code),quantity_on_hand=warehouse_inventory.quantity_on_hand+excluded.quantity_on_hand,updated_at=now();
  insert into public.inventory_movements(warehouse_id,inventory_item_id,movement_type,quantity_delta,reserved_delta,note,actor_id) values(p_warehouse_id,v_item,'received',p_quantity,0,'Stock received',v_actor) returning * into v_movement;
  return jsonb_build_object('item_id',v_item,'movement_number',v_movement.movement_number,'quantity_received',p_quantity);
end $$;
revoke all on function public.receive_inventory(uuid,uuid,text,text,integer,text,text,text,numeric,numeric,text,text,text) from public,anon,authenticated;
grant execute on function public.receive_inventory(uuid,uuid,text,text,integer,text,text,text,numeric,numeric,text,text,text) to authenticated;

create or replace function public.create_fulfillment_order(
  p_warehouse_id uuid,p_items jsonb,p_delivery_address text,p_delivery_city text,p_delivery_state text,p_recipient_name text,p_recipient_phone text,p_customer_note text default null
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_customer uuid;v_order public.fulfillment_orders%rowtype;v_line jsonb;v_item uuid;v_qty integer;v_balance public.warehouse_inventory%rowtype;
begin
  select customer_id into v_customer from public.customer_users where user_id=v_actor limit 1;
  if v_actor is null or v_customer is null then raise insufficient_privilege using message='A customer account is required to place a fulfillment order';end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>50 then raise check_violation using message='Add between one and fifty products';end if;
  if not exists(select 1 from public.warehouses where id=p_warehouse_id and is_active) then raise foreign_key_violation using message='Choose an active warehouse';end if;
  insert into public.fulfillment_orders(customer_id,warehouse_id,delivery_address,delivery_city,delivery_state,recipient_name,recipient_phone,customer_note,created_by)
  values(v_customer,p_warehouse_id,btrim(p_delivery_address),btrim(p_delivery_city),p_delivery_state,btrim(p_recipient_name),btrim(p_recipient_phone),p_customer_note,v_actor) returning * into v_order;
  -- Lock stock rows in a stable order so concurrent multi-product orders do not deadlock.
  for v_line in select value from jsonb_array_elements(p_items) order by value->>'item_id' loop
    v_item:=(v_line->>'item_id')::uuid;v_qty:=(v_line->>'quantity')::integer;
    if v_qty<=0 then raise check_violation using message='Product quantities must be positive';end if;
    select wi.* into v_balance from public.warehouse_inventory wi join public.inventory_items i on i.id=wi.inventory_item_id where wi.warehouse_id=p_warehouse_id and wi.inventory_item_id=v_item and i.customer_id=v_customer for update of wi;
    if not found or v_balance.quantity_on_hand-v_balance.quantity_reserved<v_qty then raise check_violation using message='Requested quantity is not available for one or more products';end if;
    insert into public.fulfillment_order_items(fulfillment_order_id,inventory_item_id,quantity) values(v_order.id,v_item,v_qty);
    update public.warehouse_inventory set quantity_reserved=quantity_reserved+v_qty,updated_at=now() where warehouse_id=p_warehouse_id and inventory_item_id=v_item;
    insert into public.inventory_movements(warehouse_id,inventory_item_id,fulfillment_order_id,movement_type,quantity_delta,reserved_delta,note,actor_id) values(p_warehouse_id,v_item,v_order.id,'reserved',0,v_qty,'Reserved for customer fulfillment order',v_actor);
  end loop;
  return jsonb_build_object('fulfillment_id',v_order.id,'fulfillment_number',v_order.fulfillment_number,'status',v_order.status);
end $$;
revoke all on function public.create_fulfillment_order(uuid,jsonb,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.create_fulfillment_order(uuid,jsonb,text,text,text,text,text,text) to authenticated;

create or replace function public.confirm_fulfillment_pick(p_fulfillment_id uuid,p_inventory_item_id uuid,p_picked_quantity integer)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_order public.fulfillment_orders%rowtype;v_line public.fulfillment_order_items%rowtype;
begin
  if v_actor is null or not(public.has_role(v_actor,'warehouse') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    raise insufficient_privilege using message='Warehouse access is required to confirm picked products';
  end if;
  select * into v_order from public.fulfillment_orders where id=p_fulfillment_id for update;
  if not found then raise no_data_found using message='Fulfillment order was not found';end if;
  if v_order.status<>'picking' then raise object_not_in_prerequisite_state using message='Picking must be in progress';end if;
  select * into v_line from public.fulfillment_order_items
    where fulfillment_order_id=p_fulfillment_id and inventory_item_id=p_inventory_item_id for update;
  if not found then raise no_data_found using message='Product was not found on this fulfillment order';end if;
  if p_picked_quantity is null or p_picked_quantity<0 or p_picked_quantity>v_line.quantity then
    raise check_violation using message='Picked quantity must be between zero and the ordered quantity';
  end if;
  update public.fulfillment_order_items set picked_quantity=p_picked_quantity
    where fulfillment_order_id=p_fulfillment_id and inventory_item_id=p_inventory_item_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('fulfillment_order',p_fulfillment_id,'pick_confirmed',v_actor,array['inventory_item_id','picked_quantity']);
  return jsonb_build_object('fulfillment_id',p_fulfillment_id,'item_id',p_inventory_item_id,'picked_quantity',p_picked_quantity,'ordered_quantity',v_line.quantity);
end $$;
revoke all on function public.confirm_fulfillment_pick(uuid,uuid,integer) from public,anon,authenticated;
grant execute on function public.confirm_fulfillment_pick(uuid,uuid,integer) to authenticated;

create or replace function public.update_fulfillment_order(p_fulfillment_id uuid,p_action text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_order public.fulfillment_orders%rowtype;v_request public.service_requests%rowtype;v_service uuid;v_line record;
begin
  if v_actor is null or not(public.has_role(v_actor,'customer') or public.has_role(v_actor,'warehouse') or public.has_role(v_actor,'operations') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='Warehouse or Operations access is required';end if;
  select * into v_order from public.fulfillment_orders where id=p_fulfillment_id for update;
  if not found then raise no_data_found using message='Fulfillment order was not found';end if;
  if p_action='start_picking' and v_order.status='submitted' and (public.has_role(v_actor,'warehouse') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    update public.fulfillment_orders set status='picking',updated_at=now() where id=v_order.id;
  elsif p_action='pack' and v_order.status='picking' and (public.has_role(v_actor,'warehouse') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    if exists(select 1 from public.fulfillment_order_items where fulfillment_order_id=v_order.id and picked_quantity<>quantity) then
      raise object_not_in_prerequisite_state using message='Confirm every ordered product as picked before packing';
    end if;
    update public.fulfillment_orders set status='packed',updated_at=now() where id=v_order.id;
  elsif p_action='release' and v_order.status='packed' and (public.has_role(v_actor,'operations') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    select s.id into v_service from public.services s where s.code='SRV-0004' and s.is_active;
    if v_service is null then raise no_data_found using message='Order Fulfillment service is not configured';end if;
    insert into public.service_requests(customer_id,service_id,created_by,status,pickup_address,pickup_city,pickup_state,sender_name,sender_phone,delivery_address,delivery_city,delivery_state,recipient_name,recipient_phone,parcel_summary,special_instructions)
    select v_order.customer_id,v_service,v_order.created_by,'submitted',w.address,w.city,w.state,w.name,'Gohezoh Warehouse',v_order.delivery_address,v_order.delivery_city,v_order.delivery_state,v_order.recipient_name,v_order.recipient_phone,string_agg(i.name||' × '||foi.quantity,', '),'Fulfillment order '||v_order.fulfillment_number
    from public.warehouses w join public.fulfillment_order_items foi on foi.fulfillment_order_id=v_order.id join public.inventory_items i on i.id=foi.inventory_item_id where w.id=v_order.warehouse_id group by w.id returning * into v_request;
    update public.fulfillment_orders set status='released',service_request_id=v_request.id,updated_at=now() where id=v_order.id;
    return jsonb_build_object('fulfillment_number',v_order.fulfillment_number,'status','released','service_request_number',v_request.request_number,'service_request_id',v_request.id);
  elsif p_action='cancel' and v_order.status in ('submitted','picking','packed') and ((v_order.created_by=v_actor and v_order.status='submitted') or public.has_role(v_actor,'warehouse') or public.has_role(v_actor,'operations') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    for v_line in select * from public.fulfillment_order_items where fulfillment_order_id=v_order.id loop
      update public.warehouse_inventory set quantity_reserved=quantity_reserved-v_line.quantity,updated_at=now() where warehouse_id=v_order.warehouse_id and inventory_item_id=v_line.inventory_item_id;
      insert into public.inventory_movements(warehouse_id,inventory_item_id,fulfillment_order_id,movement_type,quantity_delta,reserved_delta,note,actor_id) values(v_order.warehouse_id,v_line.inventory_item_id,v_order.id,'cancelled',0,-v_line.quantity,'Released reservation for cancelled fulfillment order',v_actor);
    end loop;
    update public.fulfillment_orders set status='cancelled',updated_at=now() where id=v_order.id;
  else raise object_not_in_prerequisite_state using message='That fulfillment transition is not allowed';end if;
  return jsonb_build_object('fulfillment_number',v_order.fulfillment_number,'status',case p_action when 'start_picking' then 'picking' when 'pack' then 'packed' else 'cancelled' end);
end $$;
revoke all on function public.update_fulfillment_order(uuid,text) from public,anon,authenticated;
grant execute on function public.update_fulfillment_order(uuid,text) to authenticated;

-- Stock remains reserved during Operations review and transit. Only completed delivery
-- consumes customer-owned units. A rejected or cancelled handoff frees its reservation.
create or replace function public.settle_fulfillment_inventory()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_fulfillment public.fulfillment_orders%rowtype;v_line record;v_actor uuid;
begin
  if tg_table_name='service_requests' then
    if new.status not in ('rejected','cancelled') or new.status is not distinct from old.status then return new;end if;
    select * into v_fulfillment from public.fulfillment_orders where service_request_id=new.id and status='released' for update;
    if not found then return new;end if;
    v_actor:=coalesce(auth.uid(),new.reviewed_by,v_fulfillment.created_by);
  else
    if new.status not in ('delivered','cancelled') or new.status is not distinct from old.status then return new;end if;
    select f.* into v_fulfillment from public.fulfillment_orders f
      join public.service_requests sr on sr.id=f.service_request_id
      join public.orders o on o.service_request_id=sr.id
      where o.id=new.order_id and f.status='released' for update of f;
    if not found then return new;end if;
    v_actor:=coalesce(auth.uid(),new.assigned_operations_user_id,v_fulfillment.created_by);
  end if;
  if tg_table_name='jobs' and new.status='delivered' then
    for v_line in select * from public.fulfillment_order_items where fulfillment_order_id=v_fulfillment.id order by inventory_item_id loop
      update public.warehouse_inventory set quantity_on_hand=quantity_on_hand-v_line.quantity,
        quantity_reserved=quantity_reserved-v_line.quantity,updated_at=now()
        where warehouse_id=v_fulfillment.warehouse_id and inventory_item_id=v_line.inventory_item_id;
      insert into public.inventory_movements(warehouse_id,inventory_item_id,fulfillment_order_id,movement_type,quantity_delta,reserved_delta,note,actor_id)
        values(v_fulfillment.warehouse_id,v_line.inventory_item_id,v_fulfillment.id,'released',-v_line.quantity,-v_line.quantity,
          'Delivered through job '||new.job_number,v_actor);
    end loop;
    update public.fulfillment_orders set status='delivered',updated_at=now() where id=v_fulfillment.id;
  else
    for v_line in select * from public.fulfillment_order_items where fulfillment_order_id=v_fulfillment.id order by inventory_item_id loop
      update public.warehouse_inventory set quantity_reserved=quantity_reserved-v_line.quantity,updated_at=now()
        where warehouse_id=v_fulfillment.warehouse_id and inventory_item_id=v_line.inventory_item_id;
      insert into public.inventory_movements(warehouse_id,inventory_item_id,fulfillment_order_id,movement_type,quantity_delta,reserved_delta,note,actor_id)
        values(v_fulfillment.warehouse_id,v_line.inventory_item_id,v_fulfillment.id,'cancelled',0,-v_line.quantity,
          'Delivery handoff cancelled',v_actor);
    end loop;
    update public.fulfillment_orders set status='delivery_cancelled',updated_at=now() where id=v_fulfillment.id;
  end if;
  return new;
end $$;
create trigger fulfillment_request_terminal_inventory after update of status on public.service_requests
  for each row execute function public.settle_fulfillment_inventory();
create trigger fulfillment_job_terminal_inventory after update of status on public.jobs
  for each row execute function public.settle_fulfillment_inventory();
revoke all on function public.settle_fulfillment_inventory() from public,anon,authenticated;

comment on table public.warehouse_inventory is 'Customer-owned stock by warehouse; available quantity equals on hand less reserved.';
comment on table public.inventory_movements is 'Append-only inventory ledger; quantity_delta tracks physical on-hand and reserved_delta tracks allocations.';
comment on table public.fulfillment_orders is 'Customer product orders with stock reserved through delivery; on-hand stock decreases only when the linked job is delivered.';
