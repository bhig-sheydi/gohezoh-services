-- Phase 6: assigned lead, customer relationship, activity and partner prospect tracking.

create type public.business_lead_stage as enum ('lead','qualified','opportunity','proposal','won','lost');
create type public.business_partner_prospect_stage as enum ('identified','contacted','assessing','ready','declined','converted');
create sequence public.lead_number_seq start 1;
create sequence public.partner_prospect_number_seq start 1;
create sequence public.bdo_activity_number_seq start 1;

alter table public.customers add column assigned_bdo_id uuid references auth.users(id) on delete set null;
alter table public.customers add column onboarded_at timestamptz;

create table public.leads_opportunities (
  id uuid primary key default gen_random_uuid(),
  lead_number text not null unique default ('LED-' || lpad(nextval('public.lead_number_seq')::text,4,'0')),
  business_name text not null check(length(btrim(business_name)) between 2 and 160),
  contact_person text not null check(length(btrim(contact_person)) between 2 and 120),
  phone text not null check(length(btrim(phone)) between 5 and 40),
  email text check(email is null or length(email) <= 254),
  city text,
  state text,
  business_type text,
  lead_source text,
  assigned_bdo_id uuid not null references auth.users(id) on delete restrict,
  service_interest text,
  opportunity_value numeric(14,2) check(opportunity_value is null or opportunity_value >= 0),
  stage public.business_lead_stage not null default 'lead',
  next_action text,
  follow_up_at date,
  notes text,
  outcome text,
  converted_customer_id uuid unique references public.customers(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((stage='won' and converted_customer_id is not null) or (stage<>'won' and converted_customer_id is null))
);

create table public.lead_stage_history (
  id bigint generated always as identity primary key,
  lead_id uuid not null references public.leads_opportunities(id) on delete restrict,
  previous_stage public.business_lead_stage,
  new_stage public.business_lead_stage not null,
  changed_by uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now(),
  check(previous_stage is distinct from new_stage)
);
create index lead_stage_history_lead_idx on public.lead_stage_history(lead_id,id);

create or replace function public.record_lead_stage_history()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_previous public.business_lead_stage;
begin
  if tg_op='UPDATE' then v_previous:=old.stage; end if;
  if tg_op='INSERT' or v_previous is distinct from new.stage then
    insert into public.lead_stage_history(lead_id,previous_stage,new_stage,changed_by)
    values(new.id,v_previous,new.stage,auth.uid());
  end if;
  return new;
end $$;
create trigger leads_record_stage_history after insert or update of stage on public.leads_opportunities
  for each row execute function public.record_lead_stage_history();
revoke all on function public.record_lead_stage_history() from public,anon,authenticated;

create table public.partner_prospects (
  id uuid primary key default gen_random_uuid(),
  prospect_number text not null unique default ('PPR-' || lpad(nextval('public.partner_prospect_number_seq')::text,4,'0')),
  partner_name text not null check(length(btrim(partner_name)) between 2 and 160),
  contact_person text not null check(length(btrim(contact_person)) between 2 and 120),
  phone text not null check(length(btrim(phone)) between 5 and 40),
  email text check(email is null or length(email) <= 254),
  city text,
  state text,
  service_type text,
  coverage_areas text[] not null default '{}',
  capacity_notes text,
  assigned_bdo_id uuid not null references auth.users(id) on delete restrict,
  status public.business_partner_prospect_stage not null default 'identified',
  next_action text,
  follow_up_at date,
  notes text,
  converted_partner_id uuid unique references public.logistics_partners(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status='converted' and converted_partner_id is not null) or (status<>'converted' and converted_partner_id is null))
);

create table public.business_development_activities (
  id uuid primary key default gen_random_uuid(),
  activity_number text not null unique default ('BDA-' || lpad(nextval('public.bdo_activity_number_seq')::text,5,'0')),
  lead_id uuid references public.leads_opportunities(id) on delete restrict,
  customer_id uuid references public.customers(id) on delete restrict,
  partner_prospect_id uuid references public.partner_prospects(id) on delete restrict,
  activity_type text not null check(activity_type in ('call','email','meeting','site_visit','proposal','follow_up','other')),
  subject text not null check(length(btrim(subject)) between 2 and 160),
  details text,
  happened_at timestamptz not null default now(),
  next_action text,
  follow_up_at date,
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  check(num_nonnulls(lead_id,customer_id,partner_prospect_id)=1),
  check(details is null or length(details) <= 2000)
);

create table public.business_development_reports (
  id uuid primary key default gen_random_uuid(),
  report_number text not null unique default ('BDR-' || lpad(nextval('public.bdo_activity_number_seq')::text,5,'0')),
  bdo_id uuid not null references auth.users(id) on delete restrict,
  period_start date not null,
  period_end date not null,
  leads_created integer not null default 0,
  meetings integer not null default 0,
  proposals integer not null default 0,
  won_opportunities integer not null default 0,
  partner_prospects integer not null default 0,
  summary text not null check(length(btrim(summary)) between 10 and 2000),
  submitted_at timestamptz not null default now(),
  check(period_end >= period_start),
  unique(bdo_id,period_start,period_end)
);

create index leads_opportunities_bdo_stage_idx on public.leads_opportunities(assigned_bdo_id,stage,follow_up_at);
create index partner_prospects_bdo_status_idx on public.partner_prospects(assigned_bdo_id,status,follow_up_at);
create index bdo_activities_created_idx on public.business_development_activities(created_by,happened_at desc);
create index bdo_reports_period_idx on public.business_development_reports(bdo_id,period_start desc);

create or replace function public.require_assigned_bdo_role()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not public.has_role(new.assigned_bdo_id,'bdo') then raise check_violation using message='Records must be assigned to a user with the BDO role'; end if;
  if tg_op='INSERT' and tg_table_name='leads_opportunities' and (new.stage<>'lead' or new.converted_customer_id is not null) then raise check_violation using message='New leads must start in the lead stage'; end if;
  if tg_op='INSERT' and tg_table_name='partner_prospects' and (new.status<>'identified' or new.converted_partner_id is not null) then raise check_violation using message='New partner prospects must start as identified'; end if;
  return new;
end $$;
create trigger leads_require_bdo_assignee before insert or update of assigned_bdo_id on public.leads_opportunities for each row execute function public.require_assigned_bdo_role();
create trigger prospects_require_bdo_assignee before insert or update of assigned_bdo_id on public.partner_prospects for each row execute function public.require_assigned_bdo_role();
revoke all on function public.require_assigned_bdo_role() from public,anon,authenticated;

alter table public.leads_opportunities enable row level security;
alter table public.lead_stage_history enable row level security;
alter table public.partner_prospects enable row level security;
alter table public.business_development_activities enable row level security;
alter table public.business_development_reports enable row level security;

grant select,insert on public.leads_opportunities,public.partner_prospects to authenticated;
grant select on public.lead_stage_history to authenticated;
grant select,insert on public.business_development_activities,public.business_development_reports to authenticated;
revoke update on public.leads_opportunities,public.partner_prospects from authenticated;
grant select on public.customers to authenticated;
revoke delete on public.leads_opportunities,public.partner_prospects,public.business_development_activities,public.business_development_reports from authenticated;

create policy leads_read_assigned_or_management on public.leads_opportunities for select to authenticated
  using (assigned_bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));
create policy lead_stage_history_read_assigned_or_management on public.lead_stage_history for select to authenticated
  using (exists(select 1 from public.leads_opportunities l where l.id=lead_id));
create policy leads_create_assigned_or_management on public.leads_opportunities for insert to authenticated
  with check ((assigned_bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')) and created_by=auth.uid());
create policy leads_update_assigned_or_management on public.leads_opportunities for update to authenticated
  using (assigned_bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'))
  with check (assigned_bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));

create policy partner_prospects_read_assigned_or_management on public.partner_prospects for select to authenticated
  using (assigned_bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));
create policy partner_prospects_create_assigned_or_management on public.partner_prospects for insert to authenticated
  with check ((assigned_bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')) and created_by=auth.uid());
create policy partner_prospects_update_assigned_or_management on public.partner_prospects for update to authenticated
  using (assigned_bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'))
  with check (assigned_bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));

create policy bdo_activities_read_related on public.business_development_activities for select to authenticated
  using (public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')
    or public.has_role(auth.uid(),'bdo') and (
      lead_id is not null and exists(select 1 from public.leads_opportunities l where l.id=lead_id and l.assigned_bdo_id=auth.uid())
      or customer_id is not null and exists(select 1 from public.customers c where c.id=customer_id and c.assigned_bdo_id=auth.uid())
      or partner_prospect_id is not null and exists(select 1 from public.partner_prospects p where p.id=partner_prospect_id and p.assigned_bdo_id=auth.uid())
    ));
create policy bdo_activities_insert_related on public.business_development_activities for insert to authenticated
  with check (created_by=auth.uid() and (public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'bdo'))
    and (public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin') or lead_id is null or exists(select 1 from public.leads_opportunities l where l.id=lead_id and l.assigned_bdo_id=auth.uid()))
    and (public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin') or customer_id is null or exists(select 1 from public.customers c where c.id=customer_id and c.assigned_bdo_id=auth.uid()))
    and (public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin') or partner_prospect_id is null or exists(select 1 from public.partner_prospects p where p.id=partner_prospect_id and p.assigned_bdo_id=auth.uid())));
create policy bdo_reports_read_self_or_management on public.business_development_reports for select to authenticated
  using (bdo_id=auth.uid() or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));

create policy customers_read_assigned_bdo on public.customers for select to authenticated
  using (assigned_bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo'));

create or replace function public.update_business_lead(
  p_lead_id uuid,p_stage text default null,p_next_action text default null,p_follow_up_at date default null,
  p_notes text default null,p_outcome text default null,p_opportunity_value numeric default null,p_assigned_bdo_id uuid default null,p_replace_details boolean default false
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid(); v_lead public.leads_opportunities%rowtype; v_stage public.business_lead_stage;
begin
  if v_actor is null or not(public.has_role(v_actor,'bdo') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='Business Development access is required'; end if;
  select * into v_lead from public.leads_opportunities where id=p_lead_id for update;
  if not found then raise no_data_found using message='Lead was not found'; end if;
  if not (v_lead.assigned_bdo_id=v_actor or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='This lead is assigned to another BDO'; end if;
  if p_assigned_bdo_id is not null and not(public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='Only Management or Admin can reassign a lead'; end if;
  if p_assigned_bdo_id is not null and not public.has_role(p_assigned_bdo_id,'bdo') then raise check_violation using message='Choose a user with the BDO role'; end if;
  if p_stage is not null then
    begin v_stage:=p_stage::public.business_lead_stage; exception when invalid_text_representation then raise invalid_parameter_value using message='Choose a valid lead stage'; end;
    if v_stage='won' then raise invalid_parameter_value using message='Use customer conversion to mark an opportunity won'; end if;
    if not (v_lead.stage=v_stage or (v_lead.stage='lead' and v_stage in ('qualified','lost')) or (v_lead.stage='qualified' and v_stage in ('opportunity','lost')) or (v_lead.stage='opportunity' and v_stage in ('proposal','lost')) or (v_lead.stage='proposal' and v_stage in ('opportunity','lost'))) then raise object_not_in_prerequisite_state using message='That lead-stage transition is not allowed'; end if;
  else v_stage:=v_lead.stage; end if;
  if p_opportunity_value is not null and p_opportunity_value<0 then raise check_violation using message='Opportunity value cannot be negative'; end if;
  update public.leads_opportunities set stage=v_stage,next_action=case when p_replace_details then p_next_action else coalesce(p_next_action,next_action) end,follow_up_at=case when p_replace_details then p_follow_up_at else coalesce(p_follow_up_at,follow_up_at) end,notes=case when p_replace_details then p_notes else coalesce(p_notes,notes) end,outcome=case when p_replace_details then p_outcome else coalesce(p_outcome,outcome) end,opportunity_value=case when p_replace_details then p_opportunity_value else coalesce(p_opportunity_value,opportunity_value) end,assigned_bdo_id=coalesce(p_assigned_bdo_id,assigned_bdo_id),updated_at=now() where id=p_lead_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields) values('lead_opportunity',p_lead_id,'updated',v_actor,array['stage','next_action','follow_up_at','notes','outcome','opportunity_value']);
  return jsonb_build_object('lead_id',p_lead_id,'stage',v_stage);
end $$;
revoke all on function public.update_business_lead(uuid,text,text,date,text,text,numeric,uuid,boolean) from public,anon,authenticated;
grant execute on function public.update_business_lead(uuid,text,text,date,text,text,numeric,uuid,boolean) to authenticated;

create or replace function public.convert_business_lead_to_customer(p_lead_id uuid,p_customer_type text default 'business')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid(); v_lead public.leads_opportunities%rowtype; v_customer_id uuid;
begin
  if v_actor is null or not(public.has_role(v_actor,'bdo') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='Business Development access is required'; end if;
  select * into v_lead from public.leads_opportunities where id=p_lead_id for update;
  if not found then raise no_data_found using message='Lead was not found'; end if;
  if not (v_lead.assigned_bdo_id=v_actor or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='This lead is assigned to another BDO'; end if;
  if v_lead.stage not in ('opportunity','proposal') or v_lead.converted_customer_id is not null then raise object_not_in_prerequisite_state using message='Only an open opportunity or proposal can become a customer'; end if;
  insert into public.customers(company_name,customer_type,contact_person,email,phone,city,state,status,created_by,assigned_bdo_id,onboarded_at)
  values(v_lead.business_name,coalesce(nullif(btrim(p_customer_type),''),'business'),v_lead.contact_person,v_lead.email,v_lead.phone,v_lead.city,v_lead.state,'pending',v_actor,v_lead.assigned_bdo_id,now()) returning id into v_customer_id;
  update public.leads_opportunities set stage='won',converted_customer_id=v_customer_id,updated_at=now(),outcome=coalesce(outcome,'Converted to customer') where id=p_lead_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields) values('lead_opportunity',p_lead_id,'converted_to_customer',v_actor,array['stage','converted_customer_id']);
  return jsonb_build_object('customer_id',v_customer_id,'lead_number',v_lead.lead_number,'customer_number',(select customer_number from public.customers where id=v_customer_id));
end $$;
revoke all on function public.convert_business_lead_to_customer(uuid,text) from public,anon,authenticated;
grant execute on function public.convert_business_lead_to_customer(uuid,text) to authenticated;

create or replace function public.update_partner_prospect(p_prospect_id uuid,p_status text default null,p_next_action text default null,p_follow_up_at date default null,p_notes text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid(); v_prospect public.partner_prospects%rowtype; v_status public.business_partner_prospect_stage;
begin
  if v_actor is null or not(public.has_role(v_actor,'bdo') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='Business Development access is required'; end if;
  select * into v_prospect from public.partner_prospects where id=p_prospect_id for update;
  if not found then raise no_data_found using message='Partner prospect was not found'; end if;
  if not(v_prospect.assigned_bdo_id=v_actor or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='This prospect is assigned to another BDO'; end if;
  if p_status is not null then
    begin v_status:=p_status::public.business_partner_prospect_stage; exception when invalid_text_representation then raise invalid_parameter_value using message='Choose a valid partner prospect status'; end;
    if v_status='converted' then raise invalid_parameter_value using message='Only Management or Admin can approve a partner prospect'; end if;
  else v_status:=v_prospect.status; end if;
  update public.partner_prospects set status=v_status,next_action=coalesce(p_next_action,next_action),follow_up_at=coalesce(p_follow_up_at,follow_up_at),notes=coalesce(p_notes,notes),updated_at=now() where id=p_prospect_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields) values('partner_prospect',p_prospect_id,'updated',v_actor,array['status','next_action','follow_up_at','notes']);
  return jsonb_build_object('prospect_id',p_prospect_id,'status',v_status);
end $$;
revoke all on function public.update_partner_prospect(uuid,text,text,date,text) from public,anon,authenticated;
grant execute on function public.update_partner_prospect(uuid,text,text,date,text) to authenticated;

create or replace function public.approve_partner_prospect(p_prospect_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid(); v_prospect public.partner_prospects%rowtype; v_partner_id uuid;
begin
  if v_actor is null or not(public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='Management or Admin approval is required to add an operational partner'; end if;
  select * into v_prospect from public.partner_prospects where id=p_prospect_id for update;
  if not found then raise no_data_found using message='Partner prospect was not found'; end if;
  if v_prospect.converted_partner_id is not null or v_prospect.status not in ('ready') then raise object_not_in_prerequisite_state using message='Only a ready partner prospect can be approved'; end if;
  insert into public.logistics_partners(partner_name,contact_person,phone,email,base_city,base_state,partner_type,service_areas,status,notes)
  values(v_prospect.partner_name,v_prospect.contact_person,v_prospect.phone,v_prospect.email,v_prospect.city,v_prospect.state,coalesce(nullif(v_prospect.service_type,''),'logistics'),v_prospect.coverage_areas,'pending',v_prospect.capacity_notes) returning id into v_partner_id;
  update public.partner_prospects set status='converted',converted_partner_id=v_partner_id,updated_at=now() where id=p_prospect_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields) values('partner_prospect',p_prospect_id,'approved_as_partner',v_actor,array['status','converted_partner_id']);
  return jsonb_build_object('partner_id',v_partner_id,'prospect_number',v_prospect.prospect_number);
end $$;
revoke all on function public.approve_partner_prospect(uuid) from public,anon,authenticated;
grant execute on function public.approve_partner_prospect(uuid) to authenticated;

create or replace function public.record_business_development_activity(
  p_activity_type text,p_subject text,p_details text default null,p_happened_at timestamptz default now(),p_next_action text default null,p_follow_up_at date default null,
  p_lead_id uuid default null,p_customer_id uuid default null,p_partner_prospect_id uuid default null
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid(); v_activity public.business_development_activities%rowtype;
begin
  if v_actor is null or not(public.has_role(v_actor,'bdo') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='Business Development access is required'; end if;
  if num_nonnulls(p_lead_id,p_customer_id,p_partner_prospect_id)<>1 or p_subject is null or length(btrim(p_subject)) not between 2 and 160 or p_activity_type not in ('call','email','meeting','site_visit','proposal','follow_up','other') then raise check_violation using message='Choose one assigned record, an activity type, and a subject'; end if;
  if p_lead_id is not null and not exists(select 1 from public.leads_opportunities where id=p_lead_id and (assigned_bdo_id=v_actor or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin'))) then raise insufficient_privilege using message='This lead is not assigned to you'; end if;
  if p_customer_id is not null and not exists(select 1 from public.customers where id=p_customer_id and (assigned_bdo_id=v_actor or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin'))) then raise insufficient_privilege using message='This customer is not assigned to you'; end if;
  if p_partner_prospect_id is not null and not exists(select 1 from public.partner_prospects where id=p_partner_prospect_id and (assigned_bdo_id=v_actor or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin'))) then raise insufficient_privilege using message='This partner prospect is not assigned to you'; end if;
  insert into public.business_development_activities(lead_id,customer_id,partner_prospect_id,activity_type,subject,details,happened_at,next_action,follow_up_at,created_by)
  values(p_lead_id,p_customer_id,p_partner_prospect_id,p_activity_type,btrim(p_subject),nullif(btrim(p_details),''),coalesce(p_happened_at,now()),p_next_action,p_follow_up_at,v_actor) returning * into v_activity;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields) values('business_development_activity',v_activity.id,'recorded',v_actor,array['lead_id','customer_id','partner_prospect_id','activity_type','subject']);
  return jsonb_build_object('activity_id',v_activity.id,'activity_number',v_activity.activity_number);
end $$;
revoke all on function public.record_business_development_activity(text,text,text,timestamptz,text,date,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.record_business_development_activity(text,text,text,timestamptz,text,date,uuid,uuid,uuid) to authenticated;

create or replace function public.business_development_dashboard(p_bdo_id uuid default null)
returns table(bdo_id uuid,assigned_leads bigint,followups_due bigint,meetings_this_week bigint,proposals bigint,won_opportunities bigint,assigned_customers bigint,partner_prospects bigint,activities_this_week bigint,won_opportunity_value numeric)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid(); v_target uuid;
begin
  if v_actor is null or not(public.has_role(v_actor,'bdo') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='Business Development dashboard access is required'; end if;
  if public.has_role(v_actor,'bdo') then v_target:=v_actor; else v_target:=coalesce(p_bdo_id,v_actor); end if;
  if v_target<>v_actor and not(public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='You may only view your own BDO dashboard'; end if;
  return query select v_target,
    (select count(*) from public.leads_opportunities l where l.assigned_bdo_id=v_target and l.stage not in ('won','lost')),
    (select count(*) from public.leads_opportunities l where l.assigned_bdo_id=v_target and l.follow_up_at<=current_date and l.stage not in ('won','lost'))+(select count(*) from public.partner_prospects p where p.assigned_bdo_id=v_target and p.follow_up_at<=current_date and p.status not in ('converted','declined')),
    (select count(*) from public.business_development_activities a where a.created_by=v_target and a.activity_type='meeting' and a.happened_at>=date_trunc('week',now())),
    (select count(*) from public.leads_opportunities l where l.assigned_bdo_id=v_target and l.stage='proposal'),
    (select count(*) from public.leads_opportunities l where l.assigned_bdo_id=v_target and l.stage='won'),
    (select count(*) from public.customers c where c.assigned_bdo_id=v_target),
    (select count(*) from public.partner_prospects p where p.assigned_bdo_id=v_target and p.status<>'converted'),
    (select count(*) from public.business_development_activities a where a.created_by=v_target and a.happened_at>=date_trunc('week',now())),
    (select coalesce(sum(l.opportunity_value),0) from public.leads_opportunities l where l.assigned_bdo_id=v_target and l.stage='won');
end $$;
revoke all on function public.business_development_dashboard(uuid) from public,anon,authenticated;
grant execute on function public.business_development_dashboard(uuid) to authenticated;

create or replace function public.submit_business_development_report(p_period_start date,p_period_end date,p_summary text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid(); v_report public.business_development_reports%rowtype;
begin
  if v_actor is null or not(public.has_role(v_actor,'bdo') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then raise insufficient_privilege using message='Business Development access is required'; end if;
  if p_period_end<p_period_start or p_period_end>current_date or p_summary is null or length(btrim(p_summary)) not between 10 and 2000 then raise check_violation using message='Enter a valid completed reporting period and summary'; end if;
  insert into public.business_development_reports(bdo_id,period_start,period_end,leads_created,meetings,proposals,won_opportunities,partner_prospects,summary)
  select v_actor,p_period_start,p_period_end,
    (select count(*)::int from public.leads_opportunities l where l.assigned_bdo_id=v_actor and l.created_at::date between p_period_start and p_period_end),
    (select count(*)::int from public.business_development_activities a where a.created_by=v_actor and a.activity_type='meeting' and a.happened_at::date between p_period_start and p_period_end),
    (select count(*)::int from public.leads_opportunities l where l.assigned_bdo_id=v_actor and l.stage='proposal' and l.updated_at::date between p_period_start and p_period_end),
    (select count(*)::int from public.leads_opportunities l where l.assigned_bdo_id=v_actor and l.stage='won' and l.updated_at::date between p_period_start and p_period_end),
    (select count(*)::int from public.partner_prospects p where p.assigned_bdo_id=v_actor and p.created_at::date between p_period_start and p_period_end),btrim(p_summary)
  returning * into v_report;
  return jsonb_build_object('report_number',v_report.report_number,'period_start',v_report.period_start,'period_end',v_report.period_end);
end $$;
revoke all on function public.submit_business_development_report(date,date,text) from public,anon,authenticated;
grant execute on function public.submit_business_development_report(date,date,text) to authenticated;

comment on table public.leads_opportunities is 'Assigned BDO prospect and opportunity pipeline; won leads are linked to converted customer records.';
comment on table public.partner_prospects is 'Potential logistics partners under BDO development; only Management/Admin can approve conversion into operational partners.';
comment on table public.business_development_activities is 'Append-only prospect, customer, and partner-development activity history.';
