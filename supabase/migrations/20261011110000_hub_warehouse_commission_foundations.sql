-- Corrective specification foundations. Policy-dependent prices and commissions remain unconfigured.

create table public.port_harcourt_hub_receipts (
  inbound_job_id uuid primary key references public.jobs(id) on delete restrict,
  warehouse_id uuid not null references public.warehouses(id) on delete restrict,
  scan_reference text not null check (length(btrim(scan_reference)) between 1 and 120),
  parcel_condition text not null check (length(btrim(parcel_condition)) between 2 and 500),
  received_by uuid not null references auth.users(id) on delete restrict,
  received_at timestamptz not null default now(),
  handed_off_at timestamptz
);

create sequence public.hub_last_mile_leg_number_seq start 1;
create table public.hub_last_mile_legs (
  id uuid primary key default gen_random_uuid(),
  leg_number text not null unique default ('PHL-'||lpad(nextval('public.hub_last_mile_leg_number_seq')::text,5,'0')),
  job_id uuid not null unique references public.jobs(id) on delete restrict,
  warehouse_id uuid not null references public.warehouses(id) on delete restrict,
  partner_id uuid not null references public.logistics_partners(id) on delete restrict,
  assignment_id uuid not null unique references public.partner_assignments(id) on delete restrict,
  assigned_by uuid not null references auth.users(id) on delete restrict,
  assigned_at timestamptz not null default now()
);

create table public.port_harcourt_delivery_overrides (
  job_id uuid primary key references public.jobs(id) on delete restrict,
  reason text not null check (length(btrim(reason)) between 10 and 1000),
  approved_by uuid not null references auth.users(id) on delete restrict,
  approved_at timestamptz not null default now()
);

create or replace function public.record_port_harcourt_hub_receipt(
  p_inbound_job_id uuid, p_warehouse_id uuid, p_scan_reference text, p_parcel_condition text
) returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype;
begin
  if not (public.has_role(auth.uid(),'warehouse') or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')) then
    raise insufficient_privilege using message='Warehouse or Operations access required';
  end if;
  select * into v_job from public.jobs where id=p_inbound_job_id for update;
  if not found or lower(btrim(v_job.delivery_city)) <> 'port harcourt'
    or lower(btrim(v_job.pickup_city))='port harcourt' then
    raise check_violation using message='An inbound Port Harcourt job is required';
  end if;
  if not exists(select 1 from public.warehouses where id=p_warehouse_id and is_active and lower(btrim(city))='port harcourt') then
    raise check_violation using message='An active Gohezoh Port Harcourt warehouse is required';
  end if;
  insert into public.port_harcourt_hub_receipts(inbound_job_id,warehouse_id,scan_reference,parcel_condition,received_by)
    values(p_inbound_job_id,p_warehouse_id,btrim(p_scan_reference),btrim(p_parcel_condition),auth.uid());
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('job',p_inbound_job_id,'port_harcourt_hub_received',auth.uid(),array['warehouse_id','scan_reference','parcel_condition']);
end $$;

create or replace function public.assign_port_harcourt_last_mile(p_job_id uuid,p_partner_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype;v_receipt public.port_harcourt_hub_receipts%rowtype;
  v_old_assignment uuid;v_new_assignment uuid;v_leg_number text;
begin
  if not (public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')) then
    raise insufficient_privilege using message='Operations access required';
  end if;
  select * into v_job from public.jobs where id=p_job_id for update;
  select * into v_receipt from public.port_harcourt_hub_receipts where inbound_job_id=p_job_id for update;
  if v_job.id is null or v_receipt.inbound_job_id is null or v_job.status<>'hub_received'
    or lower(btrim(v_job.delivery_city))<>'port harcourt' then
    raise object_not_in_prerequisite_state using message='Job must be received at the Port Harcourt hub';
  end if;
  if exists(select 1 from public.hub_last_mile_legs where job_id=p_job_id) then
    raise unique_violation using message='Last-mile leg already assigned';end if;
  if not exists(select 1 from public.logistics_partners where id=p_partner_id and status='active')
    or not exists(select 1 from public.partner_corridor_coverage pc
      join public.coverage_corridors c on c.id=pc.corridor_id
      join public.coverage_locations o on o.id=c.origin_id
      join public.coverage_locations d on d.id=c.destination_id
      where pc.partner_id=p_partner_id and pc.is_enabled and pc.capacity_available and c.is_enabled and c.service_code='SRV-0001'
        and o.is_enabled and d.is_enabled and lower(btrim(o.name))='port harcourt' and lower(btrim(d.name))='port harcourt') then
    raise check_violation using message='An active partner approved for Port Harcourt local delivery is required';end if;
  select id into v_old_assignment from public.partner_assignments
    where job_id=p_job_id and partner_id=v_job.partner_id and status='accepted' for update;
  if v_old_assignment is null then raise object_not_in_prerequisite_state using message='Accepted inbound assignment required';end if;
  update public.partner_assignments set status='completed',completed_at=now(),response_note='Handed over at Gohezoh Port Harcourt hub'
    where id=v_old_assignment;
  insert into public.partner_assignments(job_id,partner_id,status,assigned_by)
    values(p_job_id,p_partner_id,'assigned',auth.uid()) returning id into v_new_assignment;
  insert into public.hub_last_mile_legs(job_id,warehouse_id,partner_id,assignment_id,assigned_by)
    values(p_job_id,v_receipt.warehouse_id,p_partner_id,v_new_assignment,auth.uid()) returning leg_number into v_leg_number;
  update public.jobs set route_id=null,partner_id=p_partner_id,status='partner_assigned' where id=p_job_id;
  update public.port_harcourt_hub_receipts set handed_off_at=now() where inbound_job_id=p_job_id;
  perform public.discard_delivery_otp(p_job_id);
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('job',p_job_id,'port_harcourt_last_mile_assigned',auth.uid(),array['partner_id','assignment_id','leg_number']);
  return jsonb_build_object('job_id',p_job_id,'leg_number',v_leg_number,'assignment_id',v_new_assignment);
end $$;

create or replace function public.authorize_port_harcourt_delivery_override(p_job_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not (public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')) then
    raise insufficient_privilege using message='Management access required';
  end if;
  if not exists(select 1 from public.jobs where id=p_job_id and lower(btrim(delivery_city))='port harcourt') then
    raise check_violation using message='Port Harcourt job required';
  end if;
  insert into public.port_harcourt_delivery_overrides(job_id,reason,approved_by)
    values(p_job_id,btrim(p_reason),auth.uid());
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('job',p_job_id,'port_harcourt_hub_override',auth.uid(),array['reason']);
end $$;

create or replace function public.guard_port_harcourt_delivery()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.status is not distinct from old.status or lower(btrim(new.delivery_city)) <> 'port harcourt'
    or lower(btrim(new.pickup_city))='port harcourt' then return new; end if;
  if exists(select 1 from public.port_harcourt_delivery_overrides where job_id=new.id) then return new; end if;
  if new.status='hub_received' and not exists(select 1 from public.port_harcourt_hub_receipts where inbound_job_id=new.id) then
    raise object_not_in_prerequisite_state using message='Hub receipt must be recorded before handoff';
  end if;
  if new.status='delivered' and not exists (
    select 1 from public.hub_last_mile_legs l
    join public.partner_assignments pa on pa.id=l.assignment_id
    where l.job_id=new.id and l.partner_id=new.partner_id and pa.status='accepted'
  ) then
    raise object_not_in_prerequisite_state using message='Accepted Port Harcourt last-mile assignment required before delivery';
  end if;
  return new;
end $$;
create trigger jobs_guard_port_harcourt_delivery before update of status on public.jobs
  for each row execute function public.guard_port_harcourt_delivery();

-- The SMS Edge Function only sends after issue_delivery_otp inserts a row. Blocking the
-- insert prevents a premature recipient code; blocking verification covers older codes.
create or replace function public.guard_port_harcourt_recipient_otp()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype;
begin
  if tg_op='UPDATE' and new.verified_at is not distinct from old.verified_at then return new;end if;
  select * into v_job from public.jobs where id=new.job_id;
  if lower(btrim(v_job.delivery_city))='port harcourt' and lower(btrim(v_job.pickup_city))<>'port harcourt'
    and not exists(select 1 from public.port_harcourt_delivery_overrides where job_id=v_job.id)
    and not exists(select 1 from public.hub_last_mile_legs l
      join public.partner_assignments pa on pa.id=l.assignment_id
      where l.job_id=v_job.id and l.partner_id=v_job.partner_id and pa.status='accepted') then
    raise object_not_in_prerequisite_state using message='Recipient code is available only after Port Harcourt last-mile acceptance';
  end if;
  return new;
end $$;
create trigger otp_guard_port_harcourt_last_mile before insert or update of verified_at on public.otp_verifications
  for each row execute function public.guard_port_harcourt_recipient_otp();

-- Hub handoff is an operational status, not recipient delivery; OTP is used once on the final leg.
create or replace function public.guard_job_status_transition()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_staff boolean;v_accepted_partner boolean;v_rejected_partner boolean;
begin
  if new.status is not distinct from old.status then return new; end if;
  if new.status='delivered' and not exists(select 1 from public.otp_verifications ov where ov.job_id=old.id and ov.verified_at is not null) then
    raise object_not_in_prerequisite_state using message='Recipient delivery code must be verified before marking delivered';
  end if;
  v_staff:=public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management');
  v_accepted_partner:=exists(select 1 from public.partner_assignments pa where pa.job_id=old.id and pa.partner_id=old.partner_id and pa.status='accepted' and public.is_partner_user(pa.partner_id));
  v_rejected_partner:=exists(select 1 from public.partner_assignments pa where pa.job_id=old.id and pa.partner_id=old.partner_id and pa.status='rejected' and public.is_partner_user(pa.partner_id));
  if not (v_staff or v_accepted_partner or (v_rejected_partner and old.status='partner_assigned' and new.status='order_confirmed' and new.partner_id is null)) then
    raise insufficient_privilege using message='Only Gohezoh operations staff or the accepted partner can update delivery progress';
  end if;
  if v_accepted_partner and not v_staff and new.status not in ('pickup_scheduled','picked_up','in_transit','out_for_delivery','delivered','exception','hub_received') then
    raise insufficient_privilege using message='Partners can update pickup, transit, hub handoff, delivery, or exception statuses only';
  end if;
  if not (
    (old.status='order_confirmed' and new.status in ('partner_assigned','pickup_scheduled','picked_up','exception','cancelled'))
    or (old.status='partner_assigned' and new.status in ('order_confirmed','pickup_scheduled','picked_up','exception','cancelled'))
    or (old.status='pickup_scheduled' and new.status in ('picked_up','exception','cancelled'))
    or (old.status='picked_up' and new.status in ('in_transit','exception'))
    or (old.status='in_transit' and new.status in ('out_for_delivery','hub_received','exception'))
    or (old.status='out_for_delivery' and new.status in ('delivered','hub_received','exception'))
    or (old.status='hub_received' and new.status='partner_assigned')
    or (old.status='delivered' and new.status='closed')
    or (old.status='exception' and new.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery','cancelled'))
  ) then raise object_not_in_prerequisite_state using message='That delivery status transition is not allowed'; end if;
  return new;
end $$;

alter table public.port_harcourt_hub_receipts enable row level security;
alter table public.hub_last_mile_legs enable row level security;
alter table public.port_harcourt_delivery_overrides enable row level security;
grant select on public.port_harcourt_hub_receipts,public.hub_last_mile_legs,public.port_harcourt_delivery_overrides to authenticated;
create policy hub_receipts_staff_read on public.port_harcourt_hub_receipts for select to authenticated
  using (public.has_role(auth.uid(),'warehouse') or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));
create policy hub_overrides_staff_read on public.port_harcourt_delivery_overrides for select to authenticated
  using (public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));
create policy hub_last_mile_staff_read on public.hub_last_mile_legs for select to authenticated
  using (public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')
    or public.is_partner_user(partner_id));
revoke all on function public.guard_port_harcourt_delivery() from public,anon,authenticated;
revoke all on function public.guard_port_harcourt_recipient_otp() from public,anon,authenticated;
revoke all on function public.record_port_harcourt_hub_receipt(uuid,uuid,text,text),public.assign_port_harcourt_last_mile(uuid,uuid),public.authorize_port_harcourt_delivery_override(uuid,text) from public,anon;
grant execute on function public.record_port_harcourt_hub_receipt(uuid,uuid,text,text),public.assign_port_harcourt_last_mile(uuid,uuid),public.authorize_port_harcourt_delivery_override(uuid,text) to authenticated;

-- Confirmed nominal rates. No implicit five-unit cap, partial-month billing, or returns fee.
create table public.warehouse_fee_schedule (
  id uuid primary key default gen_random_uuid(),
  fee_code text not null check (fee_code in ('standard_processing','standard_carton_month')),
  amount_ngn numeric(14,2) not null check (amount_ngn>=0),
  carton_length_cm numeric(8,2),
  carton_width_cm numeric(8,2),
  carton_height_cm numeric(8,2),
  max_carton_weight_kg numeric(8,3),
  effective_from timestamptz not null default now(),
  effective_until timestamptz,
  approved_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (effective_until is null or effective_until>effective_from),
  check ((fee_code='standard_carton_month')=(carton_length_cm is not null and carton_width_cm is not null and carton_height_cm is not null and max_carton_weight_kg is not null))
);
create unique index warehouse_fee_schedule_current_idx on public.warehouse_fee_schedule(fee_code) where effective_until is null;
insert into public.warehouse_fee_schedule(fee_code,amount_ngn) values('standard_processing',1000);
insert into public.warehouse_fee_schedule(fee_code,amount_ngn,carton_length_cm,carton_width_cm,carton_height_cm,max_carton_weight_kg)
  values('standard_carton_month',2000,40,30,30,15);
alter table public.warehouse_fee_schedule enable row level security;
grant select on public.warehouse_fee_schedule to authenticated;
create policy warehouse_fee_schedule_read on public.warehouse_fee_schedule for select to authenticated using(true);

-- Attribution and commission records remain inert until approved plans are entered.
create table public.partner_attributions (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.logistics_partners(id) on delete restrict,
  bdo_id uuid not null references auth.users(id) on delete restrict,
  attribution_type text not null check(attribution_type in ('partner_development','customer_acquisition')),
  effective_from date not null,
  effective_until date,
  status text not null default 'pending' check(status in ('pending','approved','rejected','revoked')),
  approved_by uuid references auth.users(id) on delete restrict,
  decision_reason text,
  created_at timestamptz not null default now(),
  check(effective_until is null or effective_until>=effective_from)
);
create index partner_attributions_bdo_idx on public.partner_attributions(bdo_id,status,effective_from desc);
create table public.commission_plans (
  id uuid primary key default gen_random_uuid(),
  bdo_id uuid not null references auth.users(id) on delete restrict,
  version integer not null check(version>0),
  basis text not null check(basis in ('collected_revenue','contribution','fixed_transaction','tiered')),
  rate numeric(12,6) check(rate is null or rate>=0),
  fixed_amount_ngn numeric(14,2) check(fixed_amount_ngn is null or fixed_amount_ngn>=0),
  terms jsonb not null default '{}'::jsonb,
  effective_from date not null,
  effective_until date,
  approved_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(bdo_id,version),
  check(effective_until is null or effective_until>=effective_from)
);
create table public.commission_ledger (
  id uuid primary key default gen_random_uuid(),
  bdo_id uuid not null references auth.users(id) on delete restrict,
  partner_id uuid references public.logistics_partners(id) on delete restrict,
  job_id uuid not null references public.jobs(id) on delete restrict,
  payment_id uuid references public.customer_payments(id) on delete restrict,
  attribution_id uuid references public.partner_attributions(id) on delete restrict,
  plan_id uuid not null references public.commission_plans(id) on delete restrict,
  eligible_amount_ngn numeric(14,2) not null check(eligible_amount_ngn>=0),
  calculated_amount_ngn numeric(14,2) not null,
  status text not null default 'pending_eligibility' check(status in ('pending_eligibility','calculated','under_review','approved','paid','reversed','adjusted')),
  adjustment_of uuid references public.commission_ledger(id) on delete restrict,
  payment_reference text,
  reviewer_id uuid references auth.users(id) on delete restrict,
  calculated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index commission_ledger_bdo_idx on public.commission_ledger(bdo_id,created_at desc);
create index commission_ledger_job_idx on public.commission_ledger(job_id);
alter table public.partner_attributions enable row level security;
alter table public.commission_plans enable row level security;
alter table public.commission_ledger enable row level security;
grant select on public.partner_attributions,public.commission_plans,public.commission_ledger to authenticated;
create policy partner_attributions_bdo_read on public.partner_attributions for select to authenticated
  using((bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo')) or public.has_role(auth.uid(),'finance') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));
create policy commission_plans_bdo_read on public.commission_plans for select to authenticated
  using((bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo')) or public.has_role(auth.uid(),'finance') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));
create policy commission_ledger_bdo_read on public.commission_ledger for select to authenticated
  using((bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo')) or public.has_role(auth.uid(),'finance') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));

create or replace function public.approve_partner_attribution(
  p_partner_id uuid,p_bdo_id uuid,p_attribution_type text,p_effective_from date,p_reason text
) returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_id uuid;
begin
  if not (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Management approval required';end if;
  if not public.has_role(p_bdo_id,'bdo') or not exists(select 1 from public.logistics_partners where id=p_partner_id and status='active')
    or p_attribution_type not in ('partner_development','customer_acquisition')
    or p_effective_from is null or nullif(btrim(p_reason),'') is null then
    raise check_violation using message='Valid partner, BDO, attribution, date and reason required';end if;
  if exists(select 1 from public.partner_attributions where partner_id=p_partner_id and attribution_type=p_attribution_type
    and status='approved' and (effective_until is null or effective_until>=p_effective_from)) then
    raise unique_violation using message='An approved attribution already applies; resolve the conflict before changing ownership';end if;
  insert into public.partner_attributions(partner_id,bdo_id,attribution_type,effective_from,status,approved_by,decision_reason)
    values(p_partner_id,p_bdo_id,p_attribution_type,p_effective_from,'approved',auth.uid(),btrim(p_reason)) returning id into v_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('partner_attribution',v_id,'approved',auth.uid(),array['partner_id','bdo_id','attribution_type','effective_from','decision_reason']);
  return v_id;
end $$;

create or replace function public.approve_commission_plan(
  p_bdo_id uuid,p_basis text,p_rate numeric,p_fixed_amount_ngn numeric,p_terms jsonb,p_effective_from date,p_reason text
) returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_id uuid;v_version integer;
begin
  if not (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Management approval required';end if;
  if not public.has_role(p_bdo_id,'bdo') or p_basis not in ('collected_revenue','contribution','fixed_transaction','tiered')
    or p_effective_from is null or p_effective_from<current_date
    or p_terms is null or jsonb_typeof(p_terms)<>'object' or nullif(btrim(p_terms->>'agreement_reference'),'') is null
    or nullif(btrim(p_reason),'') is null
    or (p_basis in ('collected_revenue','contribution') and (p_rate is null or p_rate<0 or p_rate>1))
    or (p_basis='fixed_transaction' and (p_fixed_amount_ngn is null or p_fixed_amount_ngn<0)) then
    raise check_violation using message='Signed agreement reference, valid terms, amount, effective date and reason required';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_bdo_id::text,0));
  if exists(select 1 from public.commission_plans where bdo_id=p_bdo_id and effective_from>=p_effective_from) then
    raise check_violation using message='New plan must start after the existing plan';end if;
  update public.commission_plans set effective_until=p_effective_from-1 where bdo_id=p_bdo_id and effective_until is null;
  select coalesce(max(version),0)+1 into v_version from public.commission_plans where bdo_id=p_bdo_id;
  insert into public.commission_plans(bdo_id,version,basis,rate,fixed_amount_ngn,terms,effective_from,approved_by)
    values(p_bdo_id,v_version,p_basis,p_rate,p_fixed_amount_ngn,p_terms,p_effective_from,auth.uid()) returning id into v_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('commission_plan',v_id,'approved:'||btrim(p_reason),auth.uid(),array['version','basis','rate','fixed_amount_ngn','terms','effective_from']);
  return v_id;
end $$;
revoke all on function public.approve_partner_attribution(uuid,uuid,text,date,text),
  public.approve_commission_plan(uuid,text,numeric,numeric,jsonb,date,text) from public,anon;
grant execute on function public.approve_partner_attribution(uuid,uuid,text,date,text),
  public.approve_commission_plan(uuid,text,numeric,numeric,jsonb,date,text) to authenticated;

-- Narrow projections for BDO transparency. General partner/job RLS remains unchanged.
create or replace function public.list_my_bdo_partners()
returns table(attribution_id uuid,partner_id uuid,partner_number text,partner_name text,partner_status public.partner_state,
  attribution_type text,effective_from date,attribution_status text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select a.id,p.id,p.partner_number,p.partner_name,p.status,a.attribution_type,a.effective_from,a.status
  from public.partner_attributions a join public.logistics_partners p on p.id=a.partner_id
  where a.bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo') and a.status='approved'
  order by a.effective_from desc,a.id;
$$;

create or replace function public.list_my_bdo_commissions()
returns table(id uuid,partner_id uuid,partner_number text,partner_name text,job_id uuid,job_number text,
  eligible_amount_ngn numeric,calculated_amount_ngn numeric,status text,payment_reference text,
  calculated_at timestamptz,created_at timestamptz,customer_price_ngn numeric,collected_amount_ngn numeric)
language sql stable security definer set search_path=pg_catalog,public as $$
  select l.id,l.partner_id,p.partner_number,p.partner_name,l.job_id,j.job_number,
    l.eligible_amount_ngn,l.calculated_amount_ngn,l.status,l.payment_reference,l.calculated_at,l.created_at,
    o.customer_price,coalesce((select sum(pay.amount) from public.customer_payments pay
      where pay.job_id=l.job_id and pay.status='received'),0)
  from public.commission_ledger l
  join public.jobs j on j.id=l.job_id
  join public.orders o on o.id=j.order_id
  left join public.logistics_partners p on p.id=l.partner_id
  where l.bdo_id=auth.uid() and public.has_role(auth.uid(),'bdo')
  order by l.created_at desc,l.id desc limit 500;
$$;
revoke all on function public.list_my_bdo_partners(),public.list_my_bdo_commissions() from public,anon;
grant execute on function public.list_my_bdo_partners(),public.list_my_bdo_commissions() to authenticated;
