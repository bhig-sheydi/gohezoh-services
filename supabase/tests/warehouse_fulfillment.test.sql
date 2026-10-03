begin;
create temporary table fulfillment_fixture(customer_user uuid,warehouse_user uuid,operations_user uuid,bdo_user uuid,customer_id uuid,warehouse_id uuid,item_id uuid,fulfillment_id uuid,service_request_id uuid);
grant select on fulfillment_fixture to authenticated;
do $$
declare v_customer_user uuid:=gen_random_uuid();v_warehouse_user uuid:=gen_random_uuid();v_ops_user uuid:=gen_random_uuid();v_bdo_user uuid:=gen_random_uuid();v_customer uuid;v_warehouse uuid;v_received jsonb;v_order jsonb;v_item uuid;v_fulfillment uuid;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','fulfillment-customer-'||v_customer_user||'@example.test','',now(),'{}','{}',now(),now()),
    (v_warehouse_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','fulfillment-warehouse-'||v_warehouse_user||'@example.test','',now(),'{}','{}',now(),now()),
    (v_ops_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','fulfillment-ops-'||v_ops_user||'@example.test','',now(),'{}','{}',now(),now()),
    (v_bdo_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','fulfillment-bdo-'||v_bdo_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_warehouse_user,'warehouse'),(v_ops_user,'operations'),(v_bdo_user,'bdo');
  insert into public.customers(company_name,customer_type,contact_person,phone,created_by,status) values('Fulfillment Test Customer','business','Warehouse Contact','08000000001',v_customer_user,'active') returning id into v_customer;
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_customer_user);
  insert into public.warehouses(name,code,address,city,state) values('Lagos Test Warehouse','LAG-TEST','1 Warehouse Road','Lagos','Lagos') returning id into v_warehouse;
  perform set_config('request.jwt.claim.sub',v_warehouse_user::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',v_warehouse_user,'role','authenticated')::text,true);
  v_received:=public.receive_inventory(v_warehouse,v_customer,'SKU-001','Test Product',12,'A-01',null,'box',5000,1.2,'10x10x10 cm','Bubble wrap','Keep dry');v_item:=(v_received->>'item_id')::uuid;
  perform set_config('request.jwt.claim.sub',v_customer_user::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',v_customer_user,'role','authenticated')::text,true);
  v_order:=public.create_fulfillment_order(v_warehouse,jsonb_build_array(jsonb_build_object('item_id',v_item,'quantity',3)),'2 Delivery Road','Ibadan','Oyo','Test Recipient','08000000002','Leave with reception');v_fulfillment:=(v_order->>'fulfillment_id')::uuid;
  if not exists(select 1 from public.warehouse_inventory where warehouse_id=v_warehouse and inventory_item_id=v_item and quantity_on_hand=12 and quantity_reserved=3) then raise exception 'Fulfillment request did not reserve inventory';end if;
  insert into fulfillment_fixture(customer_user,warehouse_user,operations_user,bdo_user,customer_id,warehouse_id,item_id,fulfillment_id) values(v_customer_user,v_warehouse_user,v_ops_user,v_bdo_user,v_customer,v_warehouse,v_item,v_fulfillment);
end $$;

select set_config('request.jwt.claim.sub',(select operations_user::text from fulfillment_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select operations_user from fulfillment_fixture),'role','authenticated')::text,true);
do $$ declare v_order uuid;v_item uuid;begin
  select fulfillment_id,item_id into v_order,v_item from fulfillment_fixture;
  begin perform public.update_fulfillment_order(v_order,'start_picking');raise exception 'Operations started warehouse picking';exception when insufficient_privilege then null;end;
  begin perform public.confirm_fulfillment_pick(v_order,v_item,3);raise exception 'Operations confirmed warehouse picks';exception when insufficient_privilege then null;end;
end $$;

select set_config('request.jwt.claim.sub',(select warehouse_user::text from fulfillment_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select warehouse_user from fulfillment_fixture),'role','authenticated')::text,true);
do $$ declare v_order uuid;v_item uuid;begin
  select fulfillment_id,item_id into v_order,v_item from fulfillment_fixture;
  if not public.has_role(auth.uid(),'warehouse') or (select status from public.fulfillment_orders where id=v_order)<>'submitted' then
    raise exception 'Warehouse test setup invalid: actor %, warehouse role %, order status %', auth.uid(), public.has_role(auth.uid(),'warehouse'), (select status from public.fulfillment_orders where id=v_order);
  end if;
  perform public.update_fulfillment_order(v_order,'start_picking');
  begin perform public.update_fulfillment_order(v_order,'pack');raise exception 'Packed without confirmed picks';
  exception when object_not_in_prerequisite_state then null;end;
  begin perform public.confirm_fulfillment_pick(v_order,v_item,4);raise exception 'Picked more than ordered';
  exception when check_violation then null;end;
  perform public.confirm_fulfillment_pick(v_order,v_item,3);
  perform public.update_fulfillment_order(v_order,'pack');
end $$;

select set_config('request.jwt.claim.sub',(select operations_user::text from fulfillment_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select operations_user from fulfillment_fixture),'role','authenticated')::text,true);
do $$ declare v_order uuid;v_result jsonb;v_item uuid;begin
  select fulfillment_id,item_id into v_order,v_item from fulfillment_fixture;
  v_result:=public.update_fulfillment_order(v_order,'release');
  update fulfillment_fixture set service_request_id=(v_result->>'service_request_id')::uuid;
  if not exists(select 1 from public.service_requests where id=(v_result->>'service_request_id')::uuid and status='submitted' and parcel_summary like '%Test Product%') then raise exception 'Delivery handoff did not create an Operations-review request';end if;
  if not exists(select 1 from public.warehouse_inventory where inventory_item_id=v_item and quantity_on_hand=12 and quantity_reserved=3) then raise exception 'Release reduced customer stock before delivery';end if;
end $$;

do $$ declare v_request uuid;v_job uuid;begin
  select service_request_id into v_request from fulfillment_fixture;
  v_job:=(public.process_service_request(v_request,'approve',1000)->>'job_id')::uuid;
  perform public.update_job_status(v_job,'pickup_scheduled');
  perform public.update_job_status(v_job,'picked_up');
  perform public.update_job_status(v_job,'in_transit');
  perform public.update_job_status(v_job,'out_for_delivery');
  insert into public.otp_verifications(job_id,recipient_phone,code_hash,expires_at,verified_at)
    values(v_job,'08000000002','test',now()+interval '10 minutes',now());
  perform public.update_job_status(v_job,'delivered');
  if not exists(select 1 from public.fulfillment_orders where service_request_id=v_request and status='delivered') then raise exception 'Delivered job did not settle fulfillment';end if;
end $$;

-- A rejected Operations request releases the reservation and retains on-hand units.
select set_config('request.jwt.claim.sub',(select customer_user::text from fulfillment_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select customer_user from fulfillment_fixture),'role','authenticated')::text,true);
do $$ declare v_fulfillment uuid;v_item uuid;v_warehouse uuid;begin
  select item_id,warehouse_id into v_item,v_warehouse from fulfillment_fixture;
  v_fulfillment:=(public.create_fulfillment_order(v_warehouse,jsonb_build_array(jsonb_build_object('item_id',v_item,'quantity',2)),'3 Delivery Road','Lagos','Lagos','Another Recipient','08000000003')->>'fulfillment_id')::uuid;
  perform set_config('fulfillment.cancel_test_id',v_fulfillment::text,true);
end $$;
select set_config('request.jwt.claim.sub',(select warehouse_user::text from fulfillment_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select warehouse_user from fulfillment_fixture),'role','authenticated')::text,true);
do $$ declare v_fulfillment uuid:=current_setting('fulfillment.cancel_test_id')::uuid;v_item uuid;begin
  select item_id into v_item from fulfillment_fixture;
  perform public.update_fulfillment_order(v_fulfillment,'start_picking');
  perform public.confirm_fulfillment_pick(v_fulfillment,v_item,2);
  perform public.update_fulfillment_order(v_fulfillment,'pack');
end $$;
select set_config('request.jwt.claim.sub',(select operations_user::text from fulfillment_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select operations_user from fulfillment_fixture),'role','authenticated')::text,true);
do $$ declare v_fulfillment uuid:=current_setting('fulfillment.cancel_test_id')::uuid;v_request uuid;v_item uuid;begin
  select item_id into v_item from fulfillment_fixture;
  v_request:=(public.update_fulfillment_order(v_fulfillment,'release')->>'service_request_id')::uuid;
  perform public.process_service_request(v_request,'reject',null,'Declined in test');
  if not exists(select 1 from public.fulfillment_orders where id=v_fulfillment and status='delivery_cancelled') then raise exception 'Rejected request did not cancel fulfillment';end if;
  if not exists(select 1 from public.warehouse_inventory where inventory_item_id=v_item and quantity_on_hand=9 and quantity_reserved=0) then raise exception 'Rejected request did not release stock reservation';end if;
end $$;

-- A cancelled job also frees its reservation, without reducing on-hand units.
select set_config('request.jwt.claim.sub',(select customer_user::text from fulfillment_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select customer_user from fulfillment_fixture),'role','authenticated')::text,true);
do $$ declare v_fulfillment uuid;v_item uuid;v_warehouse uuid;begin
  select item_id,warehouse_id into v_item,v_warehouse from fulfillment_fixture;
  v_fulfillment:=(public.create_fulfillment_order(v_warehouse,jsonb_build_array(jsonb_build_object('item_id',v_item,'quantity',1)),'4 Delivery Road','Lagos','Lagos','Third Recipient','08000000004')->>'fulfillment_id')::uuid;
  perform set_config('fulfillment.job_cancel_test_id',v_fulfillment::text,true);
end $$;
select set_config('request.jwt.claim.sub',(select warehouse_user::text from fulfillment_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select warehouse_user from fulfillment_fixture),'role','authenticated')::text,true);
do $$ declare v_fulfillment uuid:=current_setting('fulfillment.job_cancel_test_id')::uuid;v_item uuid;begin
  select item_id into v_item from fulfillment_fixture;
  perform public.update_fulfillment_order(v_fulfillment,'start_picking');
  perform public.confirm_fulfillment_pick(v_fulfillment,v_item,1);
  perform public.update_fulfillment_order(v_fulfillment,'pack');
end $$;
select set_config('request.jwt.claim.sub',(select operations_user::text from fulfillment_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select operations_user from fulfillment_fixture),'role','authenticated')::text,true);
do $$ declare v_fulfillment uuid:=current_setting('fulfillment.job_cancel_test_id')::uuid;v_request uuid;v_job uuid;v_item uuid;begin
  select item_id into v_item from fulfillment_fixture;
  v_request:=(public.update_fulfillment_order(v_fulfillment,'release')->>'service_request_id')::uuid;
  v_job:=(public.process_service_request(v_request,'approve',500)->>'job_id')::uuid;
  perform public.update_job_status(v_job,'cancelled');
  if not exists(select 1 from public.fulfillment_orders where id=v_fulfillment and status='delivery_cancelled') then raise exception 'Cancelled job did not cancel fulfillment';end if;
  if not exists(select 1 from public.warehouse_inventory where inventory_item_id=v_item and quantity_on_hand=9 and quantity_reserved=0) then raise exception 'Cancelled job did not release stock reservation';end if;
end $$;

select set_config('request.jwt.claim.sub',(select customer_user::text from fulfillment_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select customer_user from fulfillment_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$ declare v_item uuid;v_order uuid;v_request uuid;begin select item_id,fulfillment_id,service_request_id into v_item,v_order,v_request from fulfillment_fixture;if not exists(select 1 from public.inventory_items where id=v_item) then raise exception 'Customer cannot see their own inventory item';end if;if exists(select 1 from public.inventory_items i join public.customers c on c.id=i.customer_id where c.id<> (select customer_id from fulfillment_fixture)) then raise exception 'Customer can see another account inventory';end if;if not exists(select 1 from public.fulfillment_orders where id=v_order and status='delivered' and service_request_id=v_request) then raise exception 'Customer cannot see delivered fulfillment';end if;if not exists(select 1 from public.warehouse_inventory where inventory_item_id=v_item and quantity_on_hand=9 and quantity_reserved=0) then raise exception 'Delivery did not reduce on-hand and reserved stock';end if;if (select sum(quantity_delta) from public.inventory_movements where inventory_item_id=v_item)<>9 or (select sum(reserved_delta) from public.inventory_movements where inventory_item_id=v_item)<>0 then raise exception 'Physical and reserved stock movement ledgers do not reconcile';end if;end $$;
reset role;

select set_config('request.jwt.claim.sub',(select bdo_user::text from fulfillment_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select bdo_user from fulfillment_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$ declare v_order uuid;begin select fulfillment_id into v_order from fulfillment_fixture;begin perform public.update_fulfillment_order(v_order,'start_picking');raise exception 'BDO progressed warehouse fulfillment';exception when insufficient_privilege then null;end;if exists(select 1 from public.warehouse_inventory) then raise exception 'BDO can read inventory balances';end if;end $$;
reset role;
rollback;
