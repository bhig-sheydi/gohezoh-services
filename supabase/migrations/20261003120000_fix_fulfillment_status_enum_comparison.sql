-- Compare statuses as text in the shared request/job trigger because the tables use distinct enum types.
create or replace function public.settle_fulfillment_inventory()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_fulfillment public.fulfillment_orders%rowtype;v_line record;v_actor uuid;
begin
  if tg_table_name='service_requests' then
    if new.status::text not in ('rejected','cancelled') or new.status::text is not distinct from old.status::text then return new;end if;
    select * into v_fulfillment from public.fulfillment_orders where service_request_id=new.id and status='released' for update;
    if not found then return new;end if;
    v_actor:=coalesce(auth.uid(),new.reviewed_by,v_fulfillment.created_by);
  else
    if new.status::text not in ('delivered','cancelled') or new.status::text is not distinct from old.status::text then return new;end if;
    select f.* into v_fulfillment from public.fulfillment_orders f
      join public.service_requests sr on sr.id=f.service_request_id
      join public.orders o on o.service_request_id=sr.id
      where o.id=new.order_id and f.status='released' for update of f;
    if not found then return new;end if;
    v_actor:=coalesce(auth.uid(),new.assigned_operations_user_id,v_fulfillment.created_by);
  end if;
  if tg_table_name='jobs' and new.status::text='delivered' then
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
