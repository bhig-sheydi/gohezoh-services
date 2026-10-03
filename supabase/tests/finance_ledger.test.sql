begin;
create temporary table finance_fixture(user_id uuid, other_user_id uuid, customer_user_id uuid, job_id uuid, settlement_id uuid, management_user_id uuid);
grant select on finance_fixture to authenticated;
do $$
declare
  v_finance_user uuid := gen_random_uuid();
  v_management_user uuid := gen_random_uuid();
  v_customer_user uuid := gen_random_uuid();
  v_other_user uuid := gen_random_uuid();
  v_customer uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
  v_service uuid;
  v_request uuid := gen_random_uuid();
  v_order uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid();
  v_settlement uuid;
  v_result jsonb;
begin
  select id into v_service from public.services where code='SRV-0001';
  if v_service is null then raise exception 'Expected seeded Local Delivery service'; end if;
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_finance_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','finance-'||v_finance_user::text||'@example.test','',now(),'{}','{}',now(),now()),
    (v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','finance-customer-'||v_customer_user::text||'@example.test','',now(),'{}','{}',now(),now()),
    (v_other_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','finance-other-'||v_other_user::text||'@example.test','',now(),'{}','{}',now(),now()),
    (v_management_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','finance-management-'||v_management_user::text||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_finance_user,'finance'),(v_management_user,'management');
  insert into public.customers(id,company_name,customer_type,contact_person,email,phone,created_by)
  values(v_customer,'Finance test customer','business','Contact','finance@example.test','+2348000000001',v_customer_user);
  insert into public.customer_users(customer_id,user_id) values(v_customer,v_customer_user);
  insert into public.logistics_partners(id,partner_name,contact_person,phone,email,base_city,base_state)
  values(v_partner,'Finance test partner','Contact','+2348000000002','partner-finance@example.test','Lagos','Lagos');
  insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
  values(v_request,v_customer,v_service,v_customer_user,'1 Pickup Road','Lagos','Sender','+2348000000003','2 Delivery Road','Ibadan','Recipient','+2348000000004');
  insert into public.orders(id,service_request_id,customer_id,service_id,status,customer_price,confirmed_by,confirmed_at)
  values(v_order,v_request,v_customer,v_service,'confirmed',10000,v_finance_user,now());
  insert into public.jobs(id,order_id,customer_id,service_id,partner_id,status,pickup_address,pickup_city,sender_name,sender_phone,delivery_address,delivery_city,recipient_name,recipient_phone)
  values(v_job,v_order,v_customer,v_service,v_partner,'delivered','1 Pickup Road','Lagos','Sender','+2348000000003','2 Delivery Road','Ibadan','Recipient','+2348000000004');

  perform set_config('request.jwt.claim.sub',v_finance_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_finance_user,'role','authenticated')::text,true);
  v_result := public.save_job_financials(v_job,4000,500);
  if v_result->>'job_id' <> v_job::text then raise exception 'Financial summary was not saved'; end if;
  if (select currency from public.job_financials where job_id=v_job) <> (select currency from public.orders where id=v_order) then raise exception 'Financial currency did not follow the confirmed order'; end if;
  if (select customer_revenue from public.job_financials where job_id=v_job) <> (select customer_price from public.orders where id=v_order) then raise exception 'Financial revenue did not follow the confirmed order'; end if;
  begin
    update public.orders set customer_price=9000 where id=v_order;
    raise exception 'Order price changed after job creation';
  exception when sqlstate '55000' then null; end;
  perform public.record_customer_payment(v_job,4000,'bank_transfer','RCPT-001',null);
  begin
    perform public.record_customer_payment(v_job,100,'online','RCPT-001',null);
    raise exception 'Duplicate receipt reference was accepted for one job';
  exception when unique_violation then null; end;
  begin
    perform public.record_customer_payment(v_job,6500,'cash','RCPT-OVERPAY',null);
    raise exception 'Customer overpayment unexpectedly succeeded';
  exception when check_violation then null; end;
  v_result := public.create_partner_settlement(v_job,3000,'SETTLE-REQ-001','First tranche');
  v_settlement := (v_result->>'settlement_id')::uuid;
  begin
    perform public.create_partner_settlement(v_job,100,'SETTLE-REQ-001','Retry same request');
    raise exception 'Duplicate settlement request reference was accepted';
  exception when unique_violation then null; end;
  begin
    perform public.create_partner_settlement(v_job,1500,'SETTLE-REQ-002','Over allocation test');
    raise exception 'Partner settlement exceeded the recorded partner cost';
  exception when check_violation then null; end;
  begin
    perform public.update_partner_settlement_status(v_settlement,'approved');
    raise exception 'Finance role approved a settlement';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',v_management_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_management_user,'role','authenticated')::text,true);
  perform public.update_partner_settlement_status(v_settlement,'approved');
  perform set_config('request.jwt.claim.sub',v_finance_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_finance_user,'role','authenticated')::text,true);
  begin
    perform public.update_partner_settlement_status(v_settlement,'paid');
    raise exception 'Settlement was paid without a transfer reference';
  exception when check_violation then null; end;
  perform public.update_partner_settlement_status(v_settlement,'paid','BANK-SET-001');
  if (select status from public.partner_settlements where id=v_settlement) <> 'paid' then raise exception 'Settlement did not reach paid state'; end if;
  begin
    perform public.update_partner_settlement_status(v_settlement,'approved');
    raise exception 'Paid settlement unexpectedly changed state';
  exception when sqlstate '55000' then null; end;
  if (select customer_revenue - partner_cost - other_direct_cost from public.job_financials where job_id=v_job) <> 5500 then raise exception 'Job gross margin calculation failed'; end if;
  if (select customer_revenue - (select coalesce(sum(amount),0) from public.customer_payments where job_id=v_job and status='received') from public.job_financials where job_id=v_job) <> 6000 then raise exception 'Outstanding balance calculation failed'; end if;
  if not exists(select 1 from public.finance_dashboard_totals() t where t.currency='NGN' and t.customer_revenue=10000 and t.received=4000 and t.outstanding=6000 and t.gross_profit=5500) then raise exception 'Finance aggregate totals are incorrect'; end if;
  insert into finance_fixture(user_id,other_user_id,customer_user_id,job_id,settlement_id,management_user_id) values(v_finance_user,v_other_user,v_customer_user,v_job,v_settlement,v_management_user);
  perform set_config('request.jwt.claim.sub',v_other_user::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_other_user,'role','authenticated')::text,true);
  begin
    perform public.record_customer_payment(v_job,1,'cash');
    raise exception 'Unprivileged user unexpectedly recorded a payment';
  exception when insufficient_privilege then null; end;
end;
$$;
select set_config('request.jwt.claim.sub',(select user_id::text from finance_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select user_id from finance_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare
  v_user uuid;
  v_other uuid;
  v_customer uuid;
  v_job uuid;
  v_settlement uuid;
  v_management uuid;
begin
  select user_id,other_user_id,customer_user_id,job_id,settlement_id,management_user_id into v_user,v_other,v_customer,v_job,v_settlement,v_management from finance_fixture;
  if current_setting('request.jwt.claim.sub')::uuid <> v_user or not public.has_role(v_user,'finance') then raise exception 'Finance role test JWT was not set'; end if;
  if not exists(select 1 from public.job_financials where job_id=v_job) then raise exception 'Finance role cannot read job financials'; end if;
  if not exists(select 1 from public.customer_payments where job_id=v_job) then raise exception 'Finance role cannot read customer receipts'; end if;
  if not exists(select 1 from public.partner_settlements where id=v_settlement) then raise exception 'Finance role cannot read partner settlements'; end if;
  begin
    insert into public.job_financials(job_id,customer_revenue,partner_cost,other_direct_cost,currency) values(v_job,0,0,0,'NGN');
    raise exception 'Direct financial writes unexpectedly allowed';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.customer_payments(job_id,amount,currency,method,recorded_by) values(v_job,1,'NGN','cash',v_user);
    raise exception 'Direct customer payment writes unexpectedly allowed';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
select set_config('request.jwt.claim.sub',(select customer_user_id::text from finance_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select customer_user_id from finance_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare
  v_job uuid;
  v_claim uuid := (select customer_user_id from finance_fixture);
begin
  perform set_config('request.jwt.claim.sub',v_claim::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_claim,'role','authenticated')::text,true);
  select job_id into v_job from finance_fixture;
  if exists(select 1 from public.customer_payments where job_id=v_job) then raise exception 'Customer read raw receipts with internal columns'; end if;
  if not exists(select 1 from public.list_my_customer_payments() p where p.job_id=v_job and p.payment_number is not null) then raise exception 'Customer safe receipt RPC did not return their receipt'; end if;
  if exists(select 1 from public.partner_settlements where job_id=v_job) then raise exception 'Customer can read partner settlement data'; end if;
  if exists(select 1 from public.job_financials where job_id=v_job) then raise exception 'Customer can read internal job costs'; end if;
end;
$$;
reset role;
select set_config('request.jwt.claim.sub',(select other_user_id::text from finance_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select other_user_id from finance_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare v_job uuid;
begin
  select job_id into v_job from finance_fixture;
  if exists(select 1 from public.customer_payments where job_id=v_job) then raise exception 'Unrelated account can read another customer receipts'; end if;
  if exists(select 1 from public.list_my_customer_payments() p where p.job_id=v_job) then raise exception 'Unrelated account can read safe receipt RPC data'; end if;
  if exists(select 1 from public.partner_settlements where job_id=v_job) then raise exception 'Unrelated account can read partner settlements'; end if;
end;
$$;
reset role;
select set_config('request.jwt.claim.sub',(select user_id::text from finance_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select user_id from finance_fixture),'role','authenticated')::text,true);
do $$
declare v_job uuid; v_payment uuid;
begin
  select job_id into v_job from finance_fixture;
  select id into v_payment from public.customer_payments where job_id=v_job;
  perform public.reverse_customer_payment(v_payment,'Duplicate receipt entered by mistake');
  if (select status from public.customer_payments where id=v_payment) <> 'reversed' then raise exception 'Receipt was not marked reversed'; end if;
  if (select coalesce(sum(amount),0) from public.customer_payments where job_id=v_job and status='received') <> 0 then raise exception 'Reversed receipt is still included as received'; end if;
end;
$$;
rollback;
