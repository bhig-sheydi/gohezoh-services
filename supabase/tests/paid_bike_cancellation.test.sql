begin;
do $$
declare
  v_manager uuid:=gen_random_uuid();v_customer_user uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();v_partner uuid:=gen_random_uuid();v_service uuid;
  v_request uuid:=gen_random_uuid();v_order uuid:=gen_random_uuid();v_job uuid:=gen_random_uuid();
  v_ref text:='KWP-REFUND-'||replace(gen_random_uuid()::text,'-','');
begin
  select id into v_service from public.services where code='SRV-0001';
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_manager,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','cancel-manager-'||v_manager||'@example.test','',now(),'{}','{}',now(),now()),
    (v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','cancel-customer-'||v_customer_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.customers(id,company_name,customer_type,contact_person,email,phone,created_by)
    values(v_customer,'Cancellation fixture','business','Customer','cancel@example.test','+2348000000101',v_customer_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_customer_user);
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
    values(v_partner,'Cancellation partner','Manager','+2348000000102','active');
  insert into public.partner_users(partner_id,user_id,membership_role) values(v_partner,v_manager,'manager');
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,
    delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_request,v_customer,v_service,v_customer_user,'Pickup','Lagos','Sender','+2348000000103','Dropoff','Lagos','Receiver','+2348000000104');
  insert into public.orders(id,service_request_id,customer_id,service_id,status,customer_price)
    values(v_order,v_request,v_customer,v_service,'cancelled',2100);
  insert into public.jobs(id,order_id,customer_id,service_id,partner_id,status,pickup_address,pickup_city,sender_name,sender_phone,
    delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_job,v_order,v_customer,v_service,v_partner,'cancelled','Pickup','Lagos','Sender','+2348000000103','Dropoff','Lagos','Receiver','+2348000000104');
  insert into public.job_financials(job_id,customer_revenue,partner_cost,currency) values(v_job,2100,1575,'NGN');
  insert into public.customer_payments(job_id,amount,currency,method,reference,recorded_by)
    values(v_job,2100,'NGN','online','cancel-payment-'||v_job,v_manager);
  insert into public.paid_booking_cancellations(job_id,customer_id,partner_id,rider_user_id,payment_reference,
    provider_transaction_id,refund_reference,paid_amount_ngn)
    values(v_job,v_customer,v_partner,v_manager,'cancel-payment-'||v_job,123456789,v_ref,2100);
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  if (select available_ngn from public.get_my_partner_payables() where partner_id=v_partner)<>0 then
    raise exception 'Unrefunded cancellation released company earnings'; end if;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  perform public.finish_paid_bike_refund(v_ref,'pending',null);
  if (select available_ngn from public.get_my_partner_payables() where partner_id=v_partner)<>0 then
    raise exception 'Pending refund released company earnings'; end if;
  perform public.finish_paid_bike_refund(v_ref,'processed',111);
  perform public.finish_paid_bike_refund(v_ref,'processed',111);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  if (select available_ngn from public.get_my_partner_payables() where partner_id=v_partner)<>300 then
    raise exception 'Processed refund did not release exactly NGN 300'; end if;
  if (select amount_ngn from public.list_my_partner_cancellation_compensation(v_partner) where job_id=v_job)<>300 then
    raise exception 'Rider compensation is missing from the company statement'; end if;
  if (select customer_revenue from public.job_financials where job_id=v_job)<>1000
    or (select partner_cost from public.job_financials where job_id=v_job)<>300 then
    raise exception 'Cancellation accounting is wrong'; end if;
end $$;
rollback;
