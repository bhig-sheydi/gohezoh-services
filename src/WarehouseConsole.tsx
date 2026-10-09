import { useCallback, useEffect, useState, type FormEvent } from 'react'
import type { getSupabaseClient } from './lib/supabase'
import WeightFields from './WeightFields'
import { weightInKilograms } from './lib/weight'

type Supabase = ReturnType<typeof getSupabaseClient>
type Warehouse = {id:string;warehouse_number:string;name:string;code:string;address:string;city:string;state:string|null}
type InventoryItem = {id:string;customer_id:string;sku:string;name:string;unit:string;unit_value:number|null;weight_kg:number|null;dimensions_cm:string|null;packaging_information:string|null;handling_instructions:string|null}
type Stock = {warehouse_id:string;inventory_item_id:string;location_code:string|null;quantity_on_hand:number;quantity_reserved:number}
type Fulfillment = {id:string;fulfillment_number:string;customer_id:string;warehouse_id:string;status:string;delivery_address:string;delivery_city:string;delivery_state:string|null;recipient_name:string;recipient_phone:string;customer_note:string|null;created_at:string;service_request_id:string|null}
type FulfillmentLine = {fulfillment_order_id:string;inventory_item_id:string;quantity:number;picked_quantity:number}

export default function WarehouseConsole({supabase,isCustomer,canReceive,canPick,canRelease,canManage,onError,onNotice}:{supabase:Supabase;isCustomer:boolean;canReceive:boolean;canPick:boolean;canRelease:boolean;canManage:boolean;onError:(message:string)=>void;onNotice:(message:string)=>void}) {
  const [warehouses,setWarehouses]=useState<Warehouse[]>([])
  const [items,setItems]=useState<InventoryItem[]>([])
  const [stock,setStock]=useState<Stock[]>([])
  const [orders,setOrders]=useState<Fulfillment[]>([])
  const [orderLines,setOrderLines]=useState<FulfillmentLine[]>([])
  const [customers,setCustomers]=useState<Array<{id:string;company_name:string}>>([])
  const [selectedWarehouseId,setSelectedWarehouseId]=useState('')
  const [busy,setBusy]=useState(false)
  const [loading,setLoading]=useState(true)
  const load=useCallback(async()=>{
    setLoading(true)
    const [warehouseResult,itemResult,stockResult,orderResult]=await Promise.all([
      supabase.from('warehouses').select('*').eq('is_active',true).order('name'),
      supabase.from('inventory_items').select('*').order('name'),
      supabase.from('warehouse_inventory').select('*'),
      supabase.from('fulfillment_orders').select('*').order('created_at',{ascending:false}).limit(100),
    ])
    const error=warehouseResult.error??itemResult.error??stockResult.error??orderResult.error
    if(error)onError(error.message)
    setWarehouses((warehouseResult.data??[]) as Warehouse[]);setItems((itemResult.data??[]) as InventoryItem[]);setStock((stockResult.data??[]) as Stock[]);setOrders((orderResult.data??[]) as Fulfillment[])
    const orderIds=(orderResult.data??[]).map((order)=>String(order.id))
    const {data:lineData,error:lineError}=orderIds.length?await supabase.from('fulfillment_order_items').select('*').in('fulfillment_order_id',orderIds):{data:[],error:null}
    if(lineError)onError(lineError.message)
    setOrderLines((lineData??[]) as FulfillmentLine[])
    if(canReceive){const {data,error:customerError}=await supabase.from('customers').select('id,company_name').order('company_name');if(customerError)onError(customerError.message);setCustomers((data??[]) as Array<{id:string;company_name:string}>)}
    setLoading(false)
  },[canReceive,onError,supabase])
  const availableAt=(itemId:string,warehouseId:string)=>{const row=stock.find((entry)=>entry.inventory_item_id===itemId&&entry.warehouse_id===warehouseId);return row?row.quantity_on_hand-row.quantity_reserved:0}
  useEffect(()=>{const timer=window.setTimeout(()=>void load(),0);return()=>window.clearTimeout(timer)},[load])
  async function submitReceive(event:FormEvent<HTMLFormElement>){
    event.preventDefault();const formElement=event.currentTarget;const form=new FormData(formElement);setBusy(true)
    let weightKg: number | null
    try { weightKg = weightInKilograms(form.get('weight'), String(form.get('weight_unit'))) }
    catch (error) { onError((error as Error).message); setBusy(false); return }
    const {data,error}=await supabase.rpc('receive_inventory',{p_warehouse_id:String(form.get('warehouse_id')),p_customer_id:String(form.get('customer_id')),p_sku:String(form.get('sku')),p_name:String(form.get('name')),p_quantity:Number(form.get('quantity')),p_location_code:String(form.get('location_code')||'')||null,p_description:String(form.get('description')||'')||null,p_unit:String(form.get('unit')||'unit'),p_unit_value:form.get('unit_value')?Number(form.get('unit_value')):null,p_weight_kg:weightKg,p_dimensions_cm:String(form.get('dimensions_cm')||'')||null,p_packaging_information:String(form.get('packaging_information')||'')||null,p_handling_instructions:String(form.get('handling_instructions')||'')||null})
    if(error)onError(error.message);else{onNotice(`Received ${data?.quantity_received} units (${data?.movement_number}).`);formElement.reset();await load()}setBusy(false)
  }
  async function createOrder(event:FormEvent<HTMLFormElement>){
    event.preventDefault();const formElement=event.currentTarget;const form=new FormData(formElement);setBusy(true)
    const warehouseId=String(form.get('warehouse_id'));const itemId=String(form.get('inventory_item_id'));const quantity=Number(form.get('quantity'));const balance=stock.find((entry)=>entry.warehouse_id===warehouseId&&entry.inventory_item_id===itemId);const available=balance?balance.quantity_on_hand-balance.quantity_reserved:0
    if(quantity<=0||quantity>available){onError(`Only ${formatQty(available)} units are available at the selected warehouse.`);setBusy(false);return}
    const {data,error}=await supabase.rpc('create_fulfillment_order',{p_warehouse_id:warehouseId,p_items:[{item_id:itemId,quantity}],p_delivery_address:String(form.get('delivery_address')),p_delivery_city:String(form.get('delivery_city')),p_delivery_state:String(form.get('delivery_state')||'')||null,p_recipient_name:String(form.get('recipient_name')),p_recipient_phone:String(form.get('recipient_phone')),p_customer_note:String(form.get('customer_note')||'')||null})
    if(error)onError(error.message);else{onNotice(`Fulfillment order ${data?.fulfillment_number} submitted.`);formElement.reset();await load()}setBusy(false)
  }
  async function transition(order:Fulfillment,action:string){
    setBusy(true);const {data,error}=await supabase.rpc('update_fulfillment_order',{p_fulfillment_id:order.id,p_action:action})
    if(error)onError(error.message);else{onNotice(action==='release'?`Delivery request ${data?.service_request_number} sent to Operations.`:`${order.fulfillment_number} updated.`);await load()}setBusy(false)
  }
  async function confirmPick(event:FormEvent<HTMLFormElement>,order:Fulfillment,line:FulfillmentLine){
    event.preventDefault();const form=new FormData(event.currentTarget);const pickedQuantity=Number(form.get('picked_quantity'))
    if(!Number.isInteger(pickedQuantity)||pickedQuantity<0||pickedQuantity>line.quantity){onError(`Enter a picked quantity from 0 to ${line.quantity}.`);return}
    setBusy(true)
    const {error}=await supabase.rpc('confirm_fulfillment_pick',{p_fulfillment_id:order.id,p_inventory_item_id:line.inventory_item_id,p_picked_quantity:pickedQuantity})
    if(error)onError(error.message);else{onNotice(`Picked count saved for ${order.fulfillment_number}.`);await load()}setBusy(false)
  }
  const formatQty=(n:number)=>n.toLocaleString('en-NG')
  return <main className="dashboard warehouse-page">
    <div className="dashboard-heading"><div><p className="eyebrow">PHASE 7 · WAREHOUSE & FULFILLMENT</p><h1>{isCustomer?'My inventory & fulfillment':'Warehouse desk'}</h1><p className="section-intro">Customer-owned stock is tracked by warehouse and bin. Fulfillment reserves available units, records picking and packing, then sends a delivery request to Operations.</p></div><button className="secondary-button" onClick={()=>void load()} disabled={loading}>Refresh inventory</button></div>
    {canManage&&<section className="history-panel"><p className="eyebrow">WAREHOUSE SETUP</p><h2>Add warehouse</h2><form className="form-grid warehouse-create" onSubmit={async(event)=>{event.preventDefault();const formElement=event.currentTarget;const form=new FormData(formElement);setBusy(true);const {error}=await supabase.from('warehouses').insert({name:String(form.get('name')),code:String(form.get('code')).toUpperCase(),address:String(form.get('address')),city:String(form.get('city')),state:String(form.get('state')||'')||null});if(error)onError(error.message);else{onNotice('Warehouse added.');formElement.reset();await load()}setBusy(false)}}><label className="field"><span>Name</span><input name="name" required/></label><label className="field"><span>Code</span><input name="code" required/></label><label className="field"><span>Address</span><input name="address" required/></label><label className="field"><span>City</span><input name="city" required/></label><label className="field"><span>State</span><input name="state"/></label><button className="primary-button" disabled={busy}>Add warehouse</button></form></section>}
    {canReceive&&<section className="form-card warehouse-receive"><p className="eyebrow">GOODS RECEIVING</p><h2>Receive customer inventory</h2><form className="form-grid" onSubmit={(event)=>void submitReceive(event)}><div className="field-row"><label className="field"><span>Customer</span><select name="customer_id" required defaultValue=""><option value="" disabled>Select customer</option>{customers.map((customer)=><option key={customer.id} value={customer.id}>{customer.company_name}</option>)}</select></label><label className="field"><span>Warehouse</span><select name="warehouse_id" required defaultValue=""><option value="" disabled>Select warehouse</option>{warehouses.map((warehouse)=><option key={warehouse.id} value={warehouse.id}>{warehouse.name} · {warehouse.city}</option>)}</select></label></div><div className="field-row"><label className="field"><span>SKU</span><input name="sku" required/></label><label className="field"><span>Product name</span><input name="name" required/></label><label className="field"><span>Quantity received</span><input name="quantity" type="number" min="1" required/></label><label className="field"><span>Bin/location</span><input name="location_code" placeholder="A-01"/></label></div><div className="field-row"><label className="field"><span>Unit</span><input name="unit" defaultValue="unit"/></label><label className="field"><span>Unit value (NGN)</span><input name="unit_value" type="number" min="0" step="0.01"/></label><WeightFields valueName="weight" unitName="weight_unit" /><label className="field"><span>Dimensions</span><input name="dimensions_cm" placeholder="L × W × H cm"/></label></div><label className="field"><span>Description</span><textarea name="description" rows={2}/></label><div className="field-row"><label className="field"><span>Packaging</span><input name="packaging_information"/></label><label className="field"><span>Handling instructions</span><input name="handling_instructions"/></label></div><button className="primary-button" disabled={busy||warehouses.length===0}>{busy?'Saving...':'Record goods received'}</button></form></section>}
    {isCustomer&&<section className="form-card warehouse-receive"><p className="eyebrow">CUSTOMER FULFILLMENT</p><h2>Order items from inventory</h2>{items.length===0?<p className="notification-empty">No stock is currently recorded for your account.</p>:<form className="form-grid" onSubmit={(event)=>void createOrder(event)}><div className="field-row"><label className="field"><span>Warehouse</span><select name="warehouse_id" required value={selectedWarehouseId} onChange={(event)=>setSelectedWarehouseId(event.target.value)}><option value="">Select warehouse</option>{warehouses.map((warehouse)=><option key={warehouse.id} value={warehouse.id}>{warehouse.name} · {warehouse.city}</option>)}</select></label><label className="field"><span>Product</span><select key={selectedWarehouseId} name="inventory_item_id" required defaultValue=""><option value="" disabled>Select product</option>{items.filter((item)=>availableAt(item.id,selectedWarehouseId)>0).map((item)=><option key={item.id} value={item.id}>{item.name} ({item.sku}) · {formatQty(availableAt(item.id,selectedWarehouseId))} available</option>)}</select></label><label className="field"><span>Quantity</span><input name="quantity" type="number" min="1" required/></label></div><label className="field"><span>Delivery address</span><input name="delivery_address" required/></label><div className="field-row"><label className="field"><span>City</span><input name="delivery_city" required/></label><label className="field"><span>State</span><input name="delivery_state"/></label></div><div className="field-row"><label className="field"><span>Recipient name</span><input name="recipient_name" required/></label><label className="field"><span>Recipient phone</span><input name="recipient_phone" type="tel" required/></label></div><label className="field"><span>Order notes</span><textarea name="customer_note" rows={2}/></label><button className="primary-button" disabled={busy||warehouses.length===0||!selectedWarehouseId}>Submit fulfillment order</button></form>}</section>}
    <section className="history-panel"><div className="history-heading"><div><p className="eyebrow">STOCK POSITION</p><h2>Inventory by warehouse</h2></div><span className="request-count">{stock.length}</span></div>{loading?<div className="loading">Loading warehouse records...</div>:stock.length===0?<p className="notification-empty">No inventory recorded.</p>:<div className="request-list">{stock.map((row)=>{const item=items.find((entry)=>entry.id===row.inventory_item_id);const warehouse=warehouses.find((entry)=>entry.id===row.warehouse_id);return <article className="request-item" key={`${row.warehouse_id}-${row.inventory_item_id}`}><div className="request-item-top"><strong>{item?.name||'Inventory item'} · {item?.sku}</strong><span className="finance-status">{formatQty(row.quantity_on_hand-row.quantity_reserved)} available</span></div><p>{warehouse?.name||'Warehouse'} · Bin {row.location_code||'Unassigned'} · {formatQty(row.quantity_on_hand)} on hand · {formatQty(row.quantity_reserved)} reserved</p><small>{item?.unit||'unit'}{item?.weight_kg?` · ${item.weight_kg} kg`:''}{item?.handling_instructions?` · ${item.handling_instructions}`:''}</small></article>})}</div>}</section>
    <section className="history-panel">
      <div className="history-heading">
        <div><p className="eyebrow">PICKING, PACKING & DELIVERY</p><h2>Fulfillment orders</h2></div>
        <span className="request-count">{orders.length}</span>
      </div>
      {orders.length===0?<p className="notification-empty">No fulfillment orders yet.</p>:<div className="request-list">
        {orders.map((order)=>{
          const lines=orderLines.filter((line)=>line.fulfillment_order_id===order.id)
          const allPicked=lines.length>0&&lines.every((line)=>line.picked_quantity===line.quantity)
          const customer=customers.find((entry)=>entry.id===order.customer_id)
          return <article className="request-item" key={order.id}>
            <div className="request-item-top"><strong>{order.fulfillment_number} · {order.recipient_name}</strong><span className={`finance-status finance-status-${order.status}`}>{order.status.replaceAll('_',' ')}</span></div>
            <p>{customer?.company_name?customer.company_name+' · ':''}{order.delivery_address}, {order.delivery_city}{order.delivery_state?', '+order.delivery_state:''} · {order.recipient_phone}</p>
            {order.customer_note&&<small>Order note: {order.customer_note}</small>}
            <div className="finance-record-list">
              <h3>Products to fulfill</h3>
              {lines.map((line)=>{
                const item=items.find((entry)=>entry.id===line.inventory_item_id)
                return <div key={line.inventory_item_id} className="warehouse-pick-line">
                  <p><strong>{item?.name||'Product'} ({item?.sku||'SKU unavailable'})</strong> · {line.quantity} ordered · {line.picked_quantity} picked</p>
                  {canPick&&order.status==='picking'&&<form className="field-row" onSubmit={(event)=>void confirmPick(event,order,line)}>
                    <label className="field"><span>Picked units</span><input key={line.picked_quantity} name="picked_quantity" type="number" min="0" max={line.quantity} defaultValue={line.picked_quantity||line.quantity} required/></label>
                    <button className="secondary-button" disabled={busy}>Save picked count</button>
                  </form>}
                </div>
              })}
            </div>
            {order.service_request_id&&<small>Delivery request sent to Operations for review. Stock remains reserved until delivery.</small>}
            <div className="bdo-record-actions">
              {canPick&&order.status==='submitted'&&<button className="secondary-button" disabled={busy} onClick={()=>void transition(order,'start_picking')}>Start picking</button>}
              {canPick&&order.status==='picking'&&<button className="secondary-button" disabled={busy||!allPicked} onClick={()=>void transition(order,'pack')}>Confirm packed</button>}
              {canRelease&&order.status==='packed'&&<button className="primary-button" disabled={busy} onClick={()=>void transition(order,'release')}>Send to Operations for delivery</button>}
              {order.status==='submitted'&&<button className="text-button finance-cancel" disabled={busy} onClick={()=>void transition(order,'cancel')}>Cancel order</button>}
            </div>
          </article>
        })}
      </div>}
    </section>
  </main>
}
