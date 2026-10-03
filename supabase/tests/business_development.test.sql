begin;
create temporary table bdo_fixture(bdo_a uuid,bdo_b uuid,manager uuid,lead_a uuid,lead_b uuid,customer_id uuid,prospect_id uuid,partner_id uuid);
grant select on bdo_fixture to authenticated;
do $$
declare
  v_a uuid:=gen_random_uuid(); v_b uuid:=gen_random_uuid(); v_manager uuid:=gen_random_uuid();
  v_lead_a uuid; v_lead_b uuid; v_customer uuid; v_prospect uuid; v_partner uuid; v_result jsonb; v_service uuid;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_a,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','bdo-a-'||v_a||'@example.test','',now(),'{}','{}',now(),now()),
    (v_b,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','bdo-b-'||v_b||'@example.test','',now(),'{}','{}',now(),now()),
    (v_manager,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','bdo-manager-'||v_manager||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_a,'bdo'),(v_b,'bdo'),(v_manager,'management');
  insert into public.leads_opportunities(business_name,contact_person,phone,assigned_bdo_id,created_by,service_interest,opportunity_value)
  values('BDO Test Lead A','Contact A','+2348000000011',v_a,v_a,'Local delivery',25000) returning id into v_lead_a;
  insert into public.leads_opportunities(business_name,contact_person,phone,assigned_bdo_id,created_by)
  values('BDO Test Lead B','Contact B','+2348000000012',v_b,v_b) returning id into v_lead_b;
  insert into public.partner_prospects(partner_name,contact_person,phone,city,state,assigned_bdo_id,created_by,status)
  values('BDO Prospective Partner','Partner Contact','+2348000000013','Lagos','Lagos',v_a,v_a,'identified') returning id into v_prospect;

  perform set_config('request.jwt.claim.sub',v_a::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_a,'role','authenticated')::text,true);
  v_result:=public.update_business_lead(v_lead_a,'qualified','Send quote',current_date+1,'Initial qualification',null,25000);
  perform public.update_business_lead(v_lead_a,p_stage=>'qualified');
  if not exists(select 1 from public.leads_opportunities where id=v_lead_a and next_action='Send quote' and follow_up_at=current_date+1 and notes='Initial qualification' and opportunity_value=25000) then raise exception 'Partial lead update erased existing follow-up details'; end if;
  perform public.update_business_lead(v_lead_a,p_stage=>'qualified',p_next_action=>null,p_follow_up_at=>null,p_notes=>null,p_outcome=>null,p_opportunity_value=>null,p_replace_details=>true);
  if not exists(select 1 from public.leads_opportunities where id=v_lead_a and next_action is null and follow_up_at is null and notes is null and opportunity_value is null) then raise exception 'Explicit lead-detail clearing did not work'; end if;
  perform public.update_business_lead(v_lead_a,'opportunity','Prepare proposal',current_date+2,'Qualified opportunity',null,null);
  perform public.update_business_lead(v_lead_a,'proposal','Follow up proposal',current_date+3,'Proposal sent',null,null);
  perform public.record_business_development_activity('meeting','Discovery meeting','Discussed delivery volume',now(),'Send proposal',current_date+2,v_lead_a,null,null);
  v_result:=public.convert_business_lead_to_customer(v_lead_a,'business');
  v_customer:=(v_result->>'customer_id')::uuid;
  if not exists(select 1 from public.leads_opportunities where id=v_lead_a and stage='won' and converted_customer_id=v_customer) then raise exception 'Lead conversion did not retain the won opportunity history'; end if;
  if (select array_agg(new_stage::text order by id) from public.lead_stage_history where lead_id=v_lead_a)
     is distinct from array['lead','qualified','opportunity','proposal','won'] then
    raise exception 'Lead lifecycle history omitted or duplicated a stage';
  end if;
  if not exists(select 1 from public.lead_stage_history where lead_id=v_lead_a and previous_stage='proposal' and new_stage='won' and changed_by=v_a) then
    raise exception 'Lead conversion history did not record the previous stage and actor';
  end if;
  if not exists(select 1 from public.customers where id=v_customer and assigned_bdo_id=v_a) then raise exception 'Converted customer was not assigned to its BDO'; end if;
  perform public.update_partner_prospect(v_prospect,'contacted','Schedule capacity review',current_date+4,'Initial partner call');
  perform public.update_partner_prospect(v_prospect,p_status=>'contacted');
  if not exists(select 1 from public.partner_prospects where id=v_prospect and next_action='Schedule capacity review' and follow_up_at=current_date+4 and notes='Initial partner call') then raise exception 'Partial partner prospect update erased follow-up details'; end if;
  perform public.update_partner_prospect(v_prospect,'assessing','Review coverage',current_date+5,'Coverage review');
  perform public.update_partner_prospect(v_prospect,'ready','Submit for approval',current_date+6,'Ready for management review');
  begin
    perform public.approve_partner_prospect(v_prospect);
    raise exception 'BDO converted a potential partner into an operational partner without approval';
  exception when insufficient_privilege then null; end;
  begin
    perform public.record_business_development_activity('call','Unauthorized activity',null,now(),null,null,v_lead_b,null,null);
    raise exception 'BDO recorded an activity against another BDO lead';
  exception when insufficient_privilege then null; end;
  perform public.submit_business_development_report(current_date-6,current_date,'Completed prospecting and partner follow-ups.');
  if not exists(select 1 from public.business_development_dashboard() d where d.bdo_id=v_a and d.won_opportunities=1 and d.assigned_customers=1 and d.meetings_this_week>=1) then raise exception 'BDO dashboard metrics are incorrect'; end if;
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  v_result:=public.approve_partner_prospect(v_prospect);
  v_partner:=(v_result->>'partner_id')::uuid;
  if not exists(select 1 from public.logistics_partners where id=v_partner and status='pending') then raise exception 'Management approval did not create a pending operational partner'; end if;
  insert into bdo_fixture values(v_a,v_b,v_manager,v_lead_a,v_lead_b,v_customer,v_prospect,v_partner);
end $$;

select set_config('request.jwt.claim.sub',(select bdo_a::text from bdo_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select bdo_a from bdo_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare v_a uuid; v_lead_a uuid; v_lead_b uuid; v_customer uuid; v_prospect uuid;
begin
  select bdo_a,lead_a,lead_b,customer_id,prospect_id into v_a,v_lead_a,v_lead_b,v_customer,v_prospect from bdo_fixture;
  if not exists(select 1 from public.leads_opportunities where id=v_lead_a) then raise exception 'BDO cannot read their assigned lead'; end if;
  if exists(select 1 from public.leads_opportunities where id=v_lead_b) then raise exception 'BDO can read another BDO lead'; end if;
  if (select count(*) from public.lead_stage_history where lead_id=v_lead_a)<>5 then raise exception 'BDO cannot read assigned lead history'; end if;
  if exists(select 1 from public.lead_stage_history where lead_id=v_lead_b) then raise exception 'BDO can read another BDO lead history'; end if;
  if not exists(select 1 from public.customers where id=v_customer and assigned_bdo_id=v_a) then raise exception 'BDO cannot read their converted customer'; end if;
  if not exists(select 1 from public.business_development_activities where lead_id=v_lead_a) then raise exception 'BDO cannot read activities for their assigned lead'; end if;
  if exists(select 1 from public.partner_settlements) then raise exception 'BDO can read financial settlements'; end if;
  begin
    update public.leads_opportunities set stage='lost' where id=v_lead_a;
    raise exception 'BDO directly bypassed the lead lifecycle function';
  exception when insufficient_privilege then null; end;
  if not exists(select 1 from public.partner_prospects where id=v_prospect and status='converted') then raise exception 'BDO cannot see approved prospect history'; end if;
end $$;
reset role;

select set_config('request.jwt.claim.sub',(select bdo_b::text from bdo_fixture),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',(select bdo_b from bdo_fixture),'role','authenticated')::text,true);
set local role authenticated;
do $$
declare v_lead_a uuid;
begin
  select lead_a into v_lead_a from bdo_fixture;
  if exists(select 1 from public.leads_opportunities where id=v_lead_a) then raise exception 'Second BDO can read the first BDO lead'; end if;
  if exists(select 1 from public.lead_stage_history where lead_id=v_lead_a) then raise exception 'Second BDO can read the first BDO lead history'; end if;
end $$;
reset role;
rollback;
