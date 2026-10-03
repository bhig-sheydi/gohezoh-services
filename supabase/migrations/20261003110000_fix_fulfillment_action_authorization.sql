-- Return an authorization error before evaluating an action's status transition.
create or replace function public.update_fulfillment_order(p_fulfillment_id uuid,p_action text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_order public.fulfillment_orders%rowtype;v_request public.service_requests%rowtype;v_service uuid;v_line record;
begin
  if v_actor is null or not(public.has_role(v_actor,'customer') or public.has_role(v_actor,'warehouse') or public.has_role(v_actor,'operations') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='Warehouse or Operations access is required';end if;
  select * into v_order from public.fulfillment_orders where id=p_fulfillment_id for update;
  if not found then raise no_data_found using message='Fulfillment order was not found';end if;
  if p_action in ('start_picking','pack') and not(public.has_role(v_actor,'warehouse') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    raise insufficient_privilege using message='Warehouse access is required for picking and packing';
  end if;
  if p_action='release' and not(public.has_role(v_actor,'operations') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    raise insufficient_privilege using message='Operations access is required to release a fulfillment order';
  end if;
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
