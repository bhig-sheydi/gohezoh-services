begin;
create temporary table commission_accrual_fixture(
  finance_user uuid,management_user uuid,bdo_user uuid,customer_user uuid,marketer_user uuid,
  partner_id uuid,direct_job uuid,pending_job uuid,marketer_job uuid
);
grant select on commission_accrual_fixture to authenticated;

do $$
declare
  v_finance uuid:=gen_random_uuid();v_management uuid:=gen_random_uuid();v_bdo uuid:=gen_random_uuid();
  v_customer_user uuid:=gen_random_uuid();v_marketer uuid:=gen_random_uuid();v_partner uuid:=gen_random_uuid();
  v_service uuid;v_service_code text;v_corridor uuid;v_customer uuid;v_request uuid;v_order uuid;v_job uuid;v_bid uuid;
  v_direct_job uuid;v_pending_job uuid;v_marketer_job uuid;v_receipt jsonb;v_payment_a uuid;v_payment_b uuid;
  v_count integer;v_total numeric;v_adjustment numeric;v_direct_entry uuid;v_marketer_entry uuid;v_share_entry uuid;
  v_direct_recovery uuid;v_marketer_recovery uuid;v_share_recovery uuid;v_future_direct uuid;v_future_marketer uuid;v_future_share uuid;v_batch uuid;
begin
  select id,code into v_service,v_service_code from public.services where code='SRV-0001';
  select c.id into v_corridor from public.coverage_corridors c
    join public.coverage_locations o on o.id=c.origin_id join public.coverage_locations d on d.id=c.destination_id
    where c.service_code='SRV-0001' and o.name='Lagos' and d.name='Lagos';
  if v_service is null or v_corridor is null then raise exception 'Expected local delivery service and Lagos corridor';end if;

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_finance,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','commission-finance-'||v_finance||'@example.test','',now(),'{}','{}',now(),now()),
    (v_management,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','commission-management-'||v_management||'@example.test','',now(),'{}','{}',now(),now()),
    (v_bdo,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','commission-direct-bdo-'||v_bdo||'@example.test','',now(),'{}','{}',now(),now()),
    (v_customer_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','commission-customer-'||v_customer_user||'@example.test','',now(),'{}','{}',now(),now()),
    (v_marketer,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','commission-marketer-'||v_marketer||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_finance,'finance'),(v_management,'management'),(v_bdo,'bdo'),(v_marketer,'marketer');
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
  values(v_partner,'Commission Test Partner','Contact','+2348000000111','active');

  perform set_config('request.jwt.claim.sub',v_management::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_management,'role','authenticated')::text,true);
  perform public.approve_commission_plan(v_bdo,'collected_revenue',0.10,null,
    jsonb_build_object('agreement_reference','TEST-DIRECT-AGREEMENT','eligible_service_codes',jsonb_build_array(v_service_code)),
    current_date,'Verified direct BDO test agreement');
  insert into public.bdo_marketer_invites(bdo_user_id,email,token_hash,used_by)
    values(v_bdo,'commission-marketer-'||v_marketer||'@example.test',extensions.digest(v_marketer::text,'sha256'),v_marketer)
    returning id into v_bid;
  insert into public.bdo_marketers(marketer_user_id,bdo_user_id,invite_id) values(v_marketer,v_bdo,v_bid);
  perform public.approve_marketer_commission_plan(v_marketer,0.10,
    jsonb_build_object('agreement_reference','TEST-MARKETER-AGREEMENT','eligible_service_codes',jsonb_build_array(v_service_code)),
    current_date,'Verified marketer test agreement');
  perform public.approve_bdo_marketer_share_plan(v_bdo,0.05,
    jsonb_build_object('agreement_reference','TEST-BDO-MARKETER-SHARE','eligible_service_codes',jsonb_build_array(v_service_code)),
    current_date,'Verified supervising BDO share agreement');

  for v_customer,v_job in
    select gen_random_uuid(),gen_random_uuid() from generate_series(1,3)
  loop
    v_request:=gen_random_uuid();v_order:=gen_random_uuid();v_bid:=gen_random_uuid();
    insert into public.customers(id,company_name,customer_type,contact_person,email,phone,created_by,assigned_bdo_id,referred_by_marketer_id)
    values(v_customer,'Commission Test Customer','business','Test Contact','commission-'||v_customer||'@example.test','+2348000000112',
      v_customer_user,v_bdo,null);
    insert into public.service_requests(id,customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,
      delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_request,v_customer,v_service,v_customer_user,'1 Pickup Road','Lagos','Sender','+2348000000113',
      '2 Delivery Road','Lagos','Recipient','+2348000000114');
    insert into public.orders(id,service_request_id,customer_id,service_id,status,customer_price,confirmed_by,confirmed_at)
      values(v_order,v_request,v_customer,v_service,'confirmed',10000,v_management,now());
    insert into public.jobs(id,order_id,customer_id,service_id,partner_id,status,pickup_address,pickup_city,sender_name,sender_phone,
      delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_job,v_order,v_customer,v_service,v_partner,
      case when v_direct_job is null then 'delivered'::public.job_state when v_pending_job is null then 'out_for_delivery'::public.job_state else 'delivered'::public.job_state end,
      '1 Pickup Road','Lagos','Sender','+2348000000113','2 Delivery Road','Lagos','Recipient','+2348000000114');
    insert into public.job_financials(job_id,customer_revenue,partner_cost,other_direct_cost,currency)
      values(v_job,10000,7500,0,'NGN');
    insert into public.delivery_quote_windows(request_id,corridor_id,deadline_at,status)
      values(v_request,v_corridor,now()+interval '2 hours','quoted');
    insert into public.partner_quotes(id,request_id,partner_id,amount_ngn,eta_hours,availability_confirmed,inclusions,exclusions,surcharge_conditions)
      values(v_bid,v_request,v_partner,7500,4,true,'Pickup and delivery','No insurance','No surcharge');
    insert into public.customer_delivery_quotes(request_id,winning_bid_id,total_direct_cost_ngn,unrounded_price_ngn,customer_price_ngn,status,accepted_at)
      values(v_request,v_bid,7500,10000,10000,'accepted',now());
    if v_direct_job is null then v_direct_job:=v_job;
    elsif v_pending_job is null then v_pending_job:=v_job;
    else v_marketer_job:=v_job;
    end if;
  end loop;

  -- Make only the third customer marketer-attributed; the commission engine must exclude it.
  update public.customers set referred_by_marketer_id=v_marketer where id=(select customer_id from public.jobs where id=v_marketer_job);
  perform set_config('request.jwt.claim.sub',v_finance::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_finance,'role','authenticated')::text,true);
  v_receipt:=public.record_customer_payment(v_direct_job,4000,'bank_transfer','COMMISSION-REC-001',null);
  v_payment_a:=(v_receipt->>'payment_id')::uuid;
  v_receipt:=public.record_customer_payment(v_direct_job,6000,'bank_transfer','COMMISSION-REC-002',null);
  v_payment_b:=(v_receipt->>'payment_id')::uuid;
  select count(*),sum(eligible_amount_ngn),sum(calculated_amount_ngn) into v_count,v_total,v_adjustment
    from public.commission_ledger where job_id=v_direct_job and adjustment_of is null;
  if v_count<>2 or v_total<>10000 or v_adjustment<>1000 then raise exception 'Collected-revenue commissions were not accrued per actual receipt';end if;

  -- Receipts before delivery do not earn commission until the physical delivery is confirmed.
  perform public.record_customer_payment(v_pending_job,10000,'bank_transfer','COMMISSION-REC-PENDING',null);
  if exists(select 1 from public.commission_ledger where job_id=v_pending_job) then raise exception 'An undelivered job earned commission';end if;
  insert into public.otp_verifications(job_id,recipient_phone,code_hash,expires_at,verified_at)
    select v_pending_job,recipient_phone,'verified-test-code',now()+interval '1 hour',now() from public.jobs where id=v_pending_job;
  perform set_config('request.jwt.claim.sub',v_management::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_management,'role','authenticated')::text,true);
  update public.jobs set status='delivered' where id=v_pending_job;
  if not exists(select 1 from public.commission_ledger where job_id=v_pending_job and status='calculated' and calculated_amount_ngn=1000) then
    raise exception 'Delivery completion did not accrue an earlier received payment';end if;

  -- Marketer-referred customers must not receive the direct-BDO commission path.
  perform set_config('request.jwt.claim.sub',v_finance::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_finance,'role','authenticated')::text,true);
  perform public.record_customer_payment(v_marketer_job,10000,'bank_transfer','COMMISSION-REC-MARKETER',null);
  if exists(select 1 from public.commission_ledger where job_id=v_marketer_job) then raise exception 'Marketer-attributed sale earned a direct-BDO commission';end if;
  if not exists(select 1 from public.marketer_commission_ledger where job_id=v_marketer_job and marketer_user_id=v_marketer
    and eligible_amount_ngn=10000 and calculated_amount_ngn=1000 and status='calculated') then
    raise exception 'Eligible marketer commission was not accrued at the approved rate'; end if;
  if not exists(select 1 from public.bdo_marketer_share_ledger where job_id=v_marketer_job and bdo_user_id=v_bdo
    and eligible_contribution_ngn=2500 and calculated_amount_ngn=125 and status='calculated') then
    raise exception 'Supervising BDO share was not calculated from the accepted contribution'; end if;
  if (select count(*) from public.marketer_commission_ledger where job_id=v_marketer_job and adjustment_of is null)<>1 then
    raise exception 'Marketer accrual was not idempotent'; end if;

  -- The same closed-job completion event is idempotent, and reversal creates a negative audit entry.
  perform set_config('request.jwt.claim.sub',v_management::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_management,'role','authenticated')::text,true);
  update public.jobs set status='closed' where id=v_direct_job;
  if (select count(*) from public.commission_ledger where job_id=v_direct_job and adjustment_of is null)<>2 then
    raise exception 'A repeated completion event duplicated commissions';end if;
  select id into v_direct_entry from public.commission_ledger where payment_id=v_payment_b and adjustment_of is null;
  select id into v_marketer_entry from public.marketer_commission_ledger where payment_reference='COMMISSION-REC-MARKETER' and adjustment_of is null;
  select id into v_share_entry from public.bdo_marketer_share_ledger where payment_reference='COMMISSION-REC-MARKETER' and adjustment_of is null;
  perform public.review_commission_entry('direct_bdo',v_direct_entry,true,'Verified eligible receipt and approved plan');
  perform public.review_commission_entry('marketer',v_marketer_entry,true,'Verified referral and approved plan');
  perform public.review_commission_entry('bdo_network_share',v_share_entry,true,'Verified contribution and signed share plan');
  begin
    perform public.record_commission_payout('direct_bdo',array[v_direct_entry],'TEST-TRANSFER-SAME-REVIEWER');
    raise exception 'The reviewer was able to record their own payout';
  exception when object_not_in_prerequisite_state then null; end;
  perform set_config('request.jwt.claim.sub',v_finance::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_finance,'role','authenticated')::text,true);
  perform public.record_commission_payout('direct_bdo',array[v_direct_entry],'TEST-TRANSFER-DIRECT-001');
  perform public.record_commission_payout('marketer',array[v_marketer_entry],'TEST-TRANSFER-MARKETER-001');
  perform public.record_commission_payout('bdo_network_share',array[v_share_entry],'TEST-TRANSFER-SHARE-001');
  if not exists(select 1 from public.commission_payout_batches where transfer_reference='TEST-TRANSFER-DIRECT-001' and amount_ngn=600 and paid_by=v_finance) then
    raise exception 'Direct BDO payout amount, reference or payer was not recorded'; end if;
  if not exists(select 1 from public.marketer_commission_ledger where id=v_marketer_entry and status='paid' and payout_reference='TEST-TRANSFER-MARKETER-001')
    or not exists(select 1 from public.bdo_marketer_share_ledger where id=v_share_entry and status='paid' and payout_reference='TEST-TRANSFER-SHARE-001') then
    raise exception 'Marketer or BDO network-share payout was not recorded'; end if;
  perform public.reverse_customer_payment(v_payment_a,'Test receipt reversal after commission accrual');
  if not exists(select 1 from public.commission_ledger where payment_id=v_payment_a and status='reversed') then
    raise exception 'Original commission was not marked reversed';end if;
  select calculated_amount_ngn into v_adjustment from public.commission_ledger where adjustment_of=(select id from public.commission_ledger where payment_id=v_payment_a and adjustment_of is null);
  if v_adjustment<>-400 or not exists(select 1 from public.commission_ledger where adjustment_of is not null and adjustment_reason='Test receipt reversal after commission accrual') then
    raise exception 'Receipt reversal did not create the correct negative commission adjustment';end if;
  perform public.reverse_customer_payment((select id from public.customer_payments where reference='COMMISSION-REC-MARKETER'),'Marketer receipt reversal test');
  if not exists(select 1 from public.marketer_commission_ledger where adjustment_of is not null and calculated_amount_ngn=-1000
    and adjustment_reason='Marketer receipt reversal test') then raise exception 'Marketer receipt reversal did not create a negative adjustment'; end if;
  if not exists(select 1 from public.bdo_marketer_share_ledger where adjustment_of is not null and calculated_amount_ngn=-125
    and adjustment_reason='Marketer receipt reversal test') then raise exception 'BDO marketer share reversal did not create a negative adjustment'; end if;

  -- Only reversals of already-paid entries can be approved as a future payout offset.
  perform public.reverse_customer_payment(v_payment_b,'Already-paid direct commission reversal test');
  select id into v_direct_recovery from public.commission_ledger where adjustment_of=v_direct_entry;
  select id into v_marketer_recovery from public.marketer_commission_ledger where adjustment_of=v_marketer_entry;
  select id into v_share_recovery from public.bdo_marketer_share_ledger where adjustment_of=v_share_entry;
  perform set_config('request.jwt.claim.sub',v_management::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_management,'role','authenticated')::text,true);
  perform public.review_commission_recovery('direct_bdo',v_direct_recovery,true,'Approved after checking paid receipt reversal');
  perform public.review_commission_recovery('marketer',v_marketer_recovery,true,'Approved after checking paid receipt reversal');
  perform public.review_commission_recovery('bdo_network_share',v_share_recovery,true,'Approved after checking paid receipt reversal');

  -- Unpaid reversals cannot be approved for recovery.
  begin
    perform public.review_commission_recovery('direct_bdo',(select id from public.commission_ledger where adjustment_of=(select id from public.commission_ledger where payment_id=v_payment_a and adjustment_of is null)),true,'This reversal happened before payout');
    raise exception 'Unpaid commission reversal was approved as a recovery';
  exception when object_not_in_prerequisite_state then null; end;

  insert into public.commission_ledger(bdo_id,partner_id,job_id,plan_id,eligible_amount_ngn,calculated_amount_ngn,status,reviewer_id)
    select v_bdo,partner_id,job_id,plan_id,10000,1000,'approved',v_management from public.commission_ledger where id=v_direct_entry returning id into v_future_direct;
  insert into public.marketer_commission_ledger(marketer_user_id,bdo_id,job_id,plan_id,eligible_amount_ngn,calculated_amount_ngn,status,reviewer_id)
    select marketer_user_id,bdo_id,job_id,plan_id,10000,1000,'approved',v_management from public.marketer_commission_ledger where id=v_marketer_entry returning id into v_future_marketer;
  insert into public.bdo_marketer_share_ledger(bdo_user_id,marketer_user_id,job_id,plan_id,eligible_contribution_ngn,calculated_amount_ngn,status,reviewer_id)
    select bdo_user_id,marketer_user_id,job_id,plan_id,2500,250,'approved',v_management from public.bdo_marketer_share_ledger where id=v_share_entry returning id into v_future_share;
  -- Recovery reviewer cannot also apply the offset or authorize the payout.
  begin
    perform public.record_commission_payout('direct_bdo',array[v_future_direct],'TEST-OFFSET-SAME-REVIEWER');
    raise exception 'Recovery reviewer was able to apply their own offset';
  exception when object_not_in_prerequisite_state then null; end;
  perform set_config('request.jwt.claim.sub',v_finance::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_finance,'role','authenticated')::text,true);
  v_batch:=public.record_commission_payout('direct_bdo',array[v_future_direct],'TEST-OFFSET-DIRECT-001');
  if not exists(select 1 from public.commission_payout_batches where id=v_batch and gross_amount_ngn=1000 and offset_amount_ngn=600 and amount_ngn=400)
    or not exists(select 1 from public.commission_offset_applications where payout_batch_id=v_batch and adjustment_entry_id=v_direct_recovery and amount_ngn=600) then
    raise exception 'Direct-BDO recovery was not applied and audited against future payout'; end if;
  v_batch:=public.record_commission_payout('marketer',array[v_future_marketer],null);
  if not exists(select 1 from public.commission_payout_batches where id=v_batch and gross_amount_ngn=1000 and offset_amount_ngn=1000 and amount_ngn=0 and transfer_reference is null)
    or not exists(select 1 from public.commission_offset_applications where payout_batch_id=v_batch and adjustment_entry_id=v_marketer_recovery and amount_ngn=1000) then
    raise exception 'Full marketer recovery was not recorded as an offset-only settlement'; end if;
  v_batch:=public.record_commission_payout('bdo_network_share',array[v_future_share],'TEST-OFFSET-SHARE-001');
  if not exists(select 1 from public.commission_payout_batches where id=v_batch and gross_amount_ngn=250 and offset_amount_ngn=125 and amount_ngn=125)
    or not exists(select 1 from public.commission_offset_applications where payout_batch_id=v_batch and adjustment_entry_id=v_share_recovery and amount_ngn=125) then
    raise exception 'BDO network-share recovery was not applied and audited against future payout'; end if;

  insert into commission_accrual_fixture values(v_finance,v_management,v_bdo,v_customer_user,v_marketer,v_partner,v_direct_job,v_pending_job,v_marketer_job);
end $$;

select set_config('request.jwt.claim.sub',(select bdo_user::text from commission_accrual_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select bdo_user from commission_accrual_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare v_job uuid;v_bdo uuid;
begin
  select direct_job,bdo_user into v_job,v_bdo from commission_accrual_fixture;
  if not exists(select 1 from public.list_my_bdo_commissions() where job_id=v_job and payment_reference='COMMISSION-REC-001') then
    raise exception 'The BDO cannot see their earned commission and payment reference';end if;
  begin
    insert into public.commission_ledger(bdo_id,job_id,plan_id,eligible_amount_ngn,calculated_amount_ngn)
    select v_bdo,v_job,id,1,1 from public.commission_plans where bdo_id=v_bdo limit 1;
    raise exception 'BDO was able to write to the commission ledger';
  exception when insufficient_privilege then null;end;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select marketer_user::text from commission_accrual_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select marketer_user from commission_accrual_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare v_job uuid;
begin
  select marketer_job into v_job from commission_accrual_fixture;
  if not exists(select 1 from public.list_my_marketer_commissions() where job_id=v_job and payment_reference='COMMISSION-REC-MARKETER') then
    raise exception 'The marketer cannot view their own commission ledger'; end if;
  if not exists(select 1 from public.list_my_commission_payouts() where commission_type='marketer' and transfer_reference='TEST-TRANSFER-MARKETER-001') then
    raise exception 'The marketer cannot view their recorded payout history'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select bdo_user::text from commission_accrual_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select bdo_user from commission_accrual_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare v_job uuid;
begin
  select marketer_job into v_job from commission_accrual_fixture;
  if not exists(select 1 from public.list_my_bdo_marketer_share_commissions() where job_id=v_job and payment_reference='COMMISSION-REC-MARKETER') then
    raise exception 'The BDO cannot view their marketer-network share'; end if;
  if not exists(select 1 from public.list_my_commission_payouts() where commission_type='bdo_network_share' and transfer_reference='TEST-TRANSFER-SHARE-001') then
    raise exception 'The BDO cannot view their recorded network-share payout history'; end if;
end $$;
reset role;
rollback;
