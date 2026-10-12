-- Canonical coverage and pre-order delivery quotations. Existing requests and jobs remain intact.
create table public.coverage_locations (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(btrim(name)) between 2 and 100),
  state text not null,
  is_enabled boolean not null default true,
  change_reason text,
  updated_at timestamptz not null default now()
);

create table public.coverage_corridors (
  id uuid primary key default gen_random_uuid(),
  origin_id uuid not null references public.coverage_locations(id),
  destination_id uuid not null references public.coverage_locations(id),
  service_code text not null check (service_code in ('SRV-0001','SRV-0002')),
  is_enabled boolean not null default true,
  change_reason text,
  effective_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (service_code='SRV-0001' or origin_id <> destination_id),
  unique (origin_id,destination_id,service_code)
);

create table public.partner_corridor_coverage (
  partner_id uuid not null references public.logistics_partners(id),
  corridor_id uuid not null references public.coverage_corridors(id),
  is_enabled boolean not null default true,
  capacity_available boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (partner_id,corridor_id)
);

insert into public.coverage_locations(name,state) values
  ('Lagos','Lagos'),('Port Harcourt','Rivers'),('Aba','Abia'),('Umuahia','Abia');

insert into public.coverage_corridors(origin_id,destination_id,service_code)
select origin.id,destination.id,'SRV-0002'
from public.coverage_locations origin cross join public.coverage_locations destination
where (origin.name,destination.name) in (
  ('Lagos','Port Harcourt'),('Port Harcourt','Lagos'),
  ('Lagos','Aba'),('Aba','Lagos'),
  ('Port Harcourt','Aba'),('Aba','Port Harcourt'));

insert into public.coverage_corridors(origin_id,destination_id,service_code)
select id,id,'SRV-0001' from public.coverage_locations where name in ('Lagos','Port Harcourt','Aba');

create table public.delivery_quote_windows (
  request_id uuid primary key references public.service_requests(id) on delete restrict,
  corridor_id uuid not null references public.coverage_corridors(id),
  published_at timestamptz not null default now(),
  deadline_at timestamptz not null,
  closed_at timestamptz,
  status text not null default 'open' check (status in ('open','quoted','tie_review','no_bids','cancelled')),
  check (deadline_at > published_at)
);
create index delivery_quote_windows_due_idx on public.delivery_quote_windows(deadline_at) where status='open';

create table public.partner_quotes (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.delivery_quote_windows(request_id),
  partner_id uuid not null references public.logistics_partners(id),
  amount_ngn numeric(14,2) not null check (amount_ngn > 0),
  eta_hours integer not null check (eta_hours > 0),
  availability_confirmed boolean not null check (availability_confirmed),
  inclusions text not null check (length(btrim(inclusions)) > 0),
  exclusions text not null check (length(btrim(exclusions)) > 0),
  surcharge_conditions text not null check (length(btrim(surcharge_conditions)) > 0),
  status text not null default 'valid' check (status in ('valid','invalid','selected','declined')),
  invalidation_reason text,
  version integer not null default 1 check (version > 0),
  submitted_at timestamptz not null default now(),
  unique (request_id,partner_id,version)
);
create index partner_quotes_rank_idx on public.partner_quotes(request_id,amount_ngn,submitted_at,id) where status='valid';

create table public.customer_delivery_quotes (
  request_id uuid primary key references public.delivery_quote_windows(request_id),
  winning_bid_id uuid not null references public.partner_quotes(id),
  other_direct_cost_ngn numeric(14,2) not null default 0 check (other_direct_cost_ngn >= 0),
  total_direct_cost_ngn numeric(14,2) not null check (total_direct_cost_ngn > 0),
  unrounded_price_ngn numeric(16,4) not null check (unrounded_price_ngn > 0),
  customer_price_ngn numeric(14,2) check (customer_price_ngn > 0),
  formula_version text not null default 'direct-cost-divided-by-0.75-v1',
  status text not null default 'pending_price' check (status in ('pending_price','sent','accepted','rejected','expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  accepted_at timestamptz
);

create table public.delivery_pricing_policies (
  id uuid primary key default gen_random_uuid(),
  rounding_increment_ngn numeric(14,2) not null check(rounding_increment_ngn>0),
  reason text not null check(length(btrim(reason)) between 10 and 500),
  effective_at timestamptz not null default now(),
  retired_at timestamptz,
  approved_by uuid not null references auth.users(id),
  check(retired_at is null or retired_at>effective_at)
);
create unique index delivery_pricing_one_active_idx on public.delivery_pricing_policies((true)) where retired_at is null;
alter table public.customer_delivery_quotes add column pricing_policy_id uuid references public.delivery_pricing_policies(id);

alter table public.coverage_locations enable row level security;
alter table public.coverage_corridors enable row level security;
alter table public.partner_corridor_coverage enable row level security;
alter table public.delivery_quote_windows enable row level security;
alter table public.partner_quotes enable row level security;
alter table public.customer_delivery_quotes enable row level security;
alter table public.delivery_pricing_policies enable row level security;

create policy coverage_locations_read on public.coverage_locations for select to authenticated using (true);
create policy coverage_corridors_read on public.coverage_corridors for select to authenticated using (true);
create policy partner_coverage_read on public.partner_corridor_coverage for select to authenticated using (
  public.is_partner_user(partner_id) or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management'));
create policy windows_read on public.delivery_quote_windows for select to authenticated using (
  exists(select 1 from public.service_requests r where r.id=request_id and public.is_customer_user(r.customer_id))
  or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')
  or exists(select 1 from public.partner_corridor_coverage pc join public.logistics_partners lp on lp.id=pc.partner_id
    where pc.corridor_id=delivery_quote_windows.corridor_id and pc.is_enabled and pc.capacity_available
      and lp.status='active' and public.is_partner_user(lp.id)));
create policy bids_read_own_or_staff on public.partner_quotes for select to authenticated using (
  public.is_partner_user(partner_id) or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management'));
create policy customer_quotes_read on public.customer_delivery_quotes for select to authenticated using (
  exists(select 1 from public.service_requests r where r.id=request_id and public.is_customer_user(r.customer_id))
  or public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management'));
create policy pricing_policies_read on public.delivery_pricing_policies for select to authenticated using (
  public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management'));

-- Restrict all writes to audited, authorization-checking functions.
revoke insert,update,delete on public.coverage_locations,public.coverage_corridors,public.partner_corridor_coverage,
  public.delivery_quote_windows,public.partner_quotes,public.customer_delivery_quotes from authenticated;
revoke insert,update,delete on public.delivery_pricing_policies from authenticated;
grant select on public.coverage_locations,public.coverage_corridors,public.partner_corridor_coverage,
  public.delivery_quote_windows,public.partner_quotes,public.customer_delivery_quotes to authenticated;
grant select on public.delivery_pricing_policies to authenticated;

create or replace function public.configure_delivery_pricing_policy(p_rounding_increment_ngn numeric,p_reason text)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_id uuid;
begin
  if not (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only Management can approve pricing policy'; end if;
  if p_rounding_increment_ngn is null or p_rounding_increment_ngn<=0
    or length(btrim(p_reason))<10 then
    raise check_violation using message='Approved rounding increment and reason are required'; end if;
  update public.delivery_pricing_policies set retired_at=now() where retired_at is null;
  insert into public.delivery_pricing_policies(rounding_increment_ngn,reason,approved_by)
  values(p_rounding_increment_ngn,btrim(p_reason),auth.uid()) returning id into v_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,changed_fields)
  values(auth.uid(),'delivery_pricing_policy_changed','delivery_pricing_policy',v_id,array['rounding_increment_ngn']);
  return v_id;
end $$;

create or replace function public.guard_delivery_request_coverage()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
declare v_code text;
begin
  -- Historical requests and trusted migration fixtures are left unchanged.
  if current_user <> 'authenticated' then return new; end if;
  select code into v_code from public.services where id=new.service_id;
  if v_code not in ('SRV-0001','SRV-0002') then return new; end if;
  if not exists (
    select 1 from public.coverage_corridors c
    join public.coverage_locations o on o.id=c.origin_id
    join public.coverage_locations d on d.id=c.destination_id
    where c.service_code=v_code and c.is_enabled and o.is_enabled and d.is_enabled
      and lower(btrim(o.name))=lower(btrim(new.pickup_city))
      and lower(btrim(d.name))=lower(btrim(new.delivery_city))
  ) then raise check_violation using message='This delivery corridor is not enabled'; end if;
  return new;
end $$;
create trigger validate_delivery_request_coverage before insert or update of pickup_city,delivery_city,service_id
  on public.service_requests for each row execute function public.guard_delivery_request_coverage();

create or replace function public.set_coverage_corridor(p_corridor_id uuid,p_enabled boolean,p_reason text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_before public.coverage_corridors%rowtype;
begin
  if not (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only administrators can change coverage'; end if;
  if nullif(btrim(p_reason),'') is null then raise check_violation using message='A change reason is required'; end if;
  select * into v_before from public.coverage_corridors where id=p_corridor_id for update;
  if not found then raise no_data_found using message='Corridor not found'; end if;
  update public.coverage_corridors set is_enabled=p_enabled,change_reason=btrim(p_reason),effective_at=now(),updated_at=now() where id=p_corridor_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,changed_fields)
  values(auth.uid(),'coverage_changed:'||btrim(p_reason),'coverage_corridor',p_corridor_id,array['is_enabled','change_reason']);
end $$;

create or replace function public.configure_coverage_corridor(p_origin text,p_destination text,p_service_code text,p_enabled boolean,p_reason text)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_origin uuid;v_destination uuid;v_id uuid;
begin
  if not (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only administrators can configure coverage'; end if;
  if p_service_code not in ('SRV-0001','SRV-0002') or nullif(btrim(p_reason),'') is null then
    raise check_violation using message='Service and reason are required'; end if;
  select id into v_origin from public.coverage_locations where lower(name)=lower(btrim(p_origin)) and is_enabled;
  select id into v_destination from public.coverage_locations where lower(name)=lower(btrim(p_destination)) and is_enabled;
  if v_origin is null or v_destination is null then raise check_violation using message='Both locations must be enabled'; end if;
  if v_origin=v_destination and p_service_code='SRV-0002' then raise check_violation using message='Interstate corridor requires two locations'; end if;
  -- Same-city local service uses its own corridor row.
  insert into public.coverage_corridors(origin_id,destination_id,service_code,is_enabled,change_reason)
  values(v_origin,v_destination,p_service_code,p_enabled,btrim(p_reason))
  on conflict(origin_id,destination_id,service_code) do update
  set is_enabled=excluded.is_enabled,change_reason=excluded.change_reason,effective_at=now(),updated_at=now()
  returning id into v_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,changed_fields)
  values(auth.uid(),'coverage_configured:'||btrim(p_reason),'coverage_corridor',v_id,array['is_enabled','origin_id','destination_id','service_code']);
  return v_id;
end $$;

create or replace function public.configure_coverage_location(p_name text,p_state text,p_enabled boolean,p_reason text)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_id uuid;
begin
  if not (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only administrators can configure locations'; end if;
  if length(btrim(p_name))<2 or length(btrim(p_state))<2 or nullif(btrim(p_reason),'') is null then
    raise check_violation using message='Location, state and reason are required'; end if;
  insert into public.coverage_locations(name,state,is_enabled,change_reason)
  values(btrim(p_name),btrim(p_state),p_enabled,btrim(p_reason))
  on conflict(name) do update set state=excluded.state,is_enabled=excluded.is_enabled,
    change_reason=excluded.change_reason,updated_at=now()
  returning id into v_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,changed_fields)
  values(auth.uid(),'coverage_location_changed:'||btrim(p_reason),'coverage_location',v_id,array['name','state','is_enabled']);
  return v_id;
end $$;

create or replace function public.set_partner_corridor_coverage(p_partner_id uuid,p_corridor_id uuid,p_enabled boolean)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only administrators can assign partner coverage'; end if;
  if not exists(select 1 from public.logistics_partners where id=p_partner_id and status='active') then
    raise check_violation using message='Partner must be active'; end if;
  insert into public.partner_corridor_coverage(partner_id,corridor_id,is_enabled)
  values(p_partner_id,p_corridor_id,p_enabled)
  on conflict(partner_id,corridor_id) do update set is_enabled=excluded.is_enabled;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,changed_fields)
  values(auth.uid(),'partner_coverage_changed','logistics_partner',p_partner_id,array['corridor_id','is_enabled']);
end $$;

create or replace function public.publish_delivery_request(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_request public.service_requests%rowtype;v_code text;v_corridor uuid;v_deadline timestamptz;
begin
  if not (public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only Operations can publish delivery bids'; end if;
  select * into v_request from public.service_requests where id=p_request_id for update;
  if not found then raise no_data_found using message='Request not found'; end if;
  if v_request.status not in ('submitted','under_review') then raise object_not_in_prerequisite_state using message='Request cannot be published'; end if;
  select code into v_code from public.services where id=v_request.service_id;
  if v_code not in ('SRV-0001','SRV-0002') then raise check_violation using message='Only delivery requests can be published'; end if;
  select c.id into v_corridor from public.coverage_corridors c
  join public.coverage_locations o on o.id=c.origin_id join public.coverage_locations d on d.id=c.destination_id
  where c.service_code=v_code and c.is_enabled and o.is_enabled and d.is_enabled
    and lower(btrim(o.name))=lower(btrim(v_request.pickup_city)) and lower(btrim(d.name))=lower(btrim(v_request.delivery_city));
  if v_corridor is null then raise check_violation using message='Delivery corridor is not enabled'; end if;
  v_deadline:=now()+interval '2 hours';
  insert into public.delivery_quote_windows(request_id,corridor_id,published_at,deadline_at)
  values(p_request_id,v_corridor,now(),v_deadline)
  on conflict (request_id) do nothing;
  update public.service_requests set status='under_review' where id=p_request_id;
  select deadline_at into v_deadline from public.delivery_quote_windows where request_id=p_request_id;
  return jsonb_build_object('request_id',p_request_id,'deadline_at',v_deadline,'corridor_id',v_corridor);
end $$;

create or replace function public.submit_partner_quote(p_request_id uuid,p_amount_ngn numeric,p_eta_hours integer,
  p_inclusions text,p_exclusions text,p_availability_confirmed boolean,p_surcharge_conditions text)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_window public.delivery_quote_windows%rowtype;v_partner uuid;v_id uuid;
begin
  select * into v_window from public.delivery_quote_windows where request_id=p_request_id for update;
  if not found or v_window.status<>'open' or now()>=v_window.deadline_at then
    raise object_not_in_prerequisite_state using message='Quote window is closed'; end if;
  select pc.partner_id into v_partner from public.partner_corridor_coverage pc
  join public.logistics_partners p on p.id=pc.partner_id
  where pc.corridor_id=v_window.corridor_id and pc.is_enabled and pc.capacity_available
    and p.status='active' and public.is_partner_user(p.id)
  order by pc.partner_id limit 1;
  if v_partner is null then raise insufficient_privilege using message='Partner is not eligible for this corridor'; end if;
  if p_amount_ngn is null or p_amount_ngn<=0 or p_eta_hours is null or p_eta_hours<=0
    or p_availability_confirmed is distinct from true
    or nullif(btrim(p_inclusions),'') is null or nullif(btrim(p_exclusions),'') is null
    or nullif(btrim(p_surcharge_conditions),'') is null then
    raise check_violation using message='Complete quote details are required'; end if;
  update public.partner_quotes set status='invalid',invalidation_reason='Superseded by a newer quote'
  where request_id=p_request_id and partner_id=v_partner and status='valid';
  insert into public.partner_quotes(request_id,partner_id,amount_ngn,eta_hours,availability_confirmed,
    inclusions,exclusions,surcharge_conditions,version)
  values(p_request_id,v_partner,p_amount_ngn,p_eta_hours,true,btrim(p_inclusions),btrim(p_exclusions),
    btrim(p_surcharge_conditions),
    coalesce((select max(version)+1 from public.partner_quotes where request_id=p_request_id and partner_id=v_partner),1))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.list_eligible_delivery_requests()
returns table(request_id uuid,request_number text,pickup_city text,delivery_city text,parcel_summary text,
  preferred_pickup_at timestamptz,special_instructions text,published_at timestamptz,deadline_at timestamptz,
  own_bid_amount_ngn numeric,own_bid_status text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select r.id,r.request_number,r.pickup_city,r.delivery_city,r.parcel_summary,r.preferred_pickup_at,
    r.special_instructions,w.published_at,w.deadline_at,
    (select q.amount_ngn from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id
      order by q.version desc limit 1),
    (select q.status from public.partner_quotes q where q.request_id=r.id and q.partner_id=pc.partner_id
      order by q.version desc limit 1)
  from public.delivery_quote_windows w
  join public.service_requests r on r.id=w.request_id
  join public.partner_corridor_coverage pc on pc.corridor_id=w.corridor_id and pc.is_enabled and pc.capacity_available
  join public.logistics_partners p on p.id=pc.partner_id and p.status='active'
  where public.is_partner_user(pc.partner_id) and w.status='open' and now()<w.deadline_at;
$$;

create or replace function public.close_delivery_quote_window(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_window public.delivery_quote_windows%rowtype;v_bid public.partner_quotes%rowtype;v_cost numeric(14,2);v_price numeric(16,4);v_ties integer;
begin
  if not (public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management'))
    and current_setting('gohezoh.quote_worker',true) is distinct from 'on' then
    raise insufficient_privilege using message='Only Operations can close bids'; end if;
  select * into v_window from public.delivery_quote_windows where request_id=p_request_id for update;
  if not found or v_window.status<>'open' then raise object_not_in_prerequisite_state using message='Window is not open'; end if;
  if now()<v_window.deadline_at then raise object_not_in_prerequisite_state using message='Quote deadline has not passed'; end if;
  select * into v_bid from public.partner_quotes where request_id=p_request_id and status='valid' and submitted_at<v_window.deadline_at
    order by amount_ngn,submitted_at,id limit 1;
  if not found then
    update public.delivery_quote_windows set status='no_bids',closed_at=now() where request_id=p_request_id;
    return jsonb_build_object('status','no_bids');
  end if;
  select count(*) into v_ties from public.partner_quotes
    where request_id=p_request_id and status='valid' and submitted_at<v_window.deadline_at and amount_ngn=v_bid.amount_ngn;
  if v_ties>1 then
    update public.delivery_quote_windows set status='tie_review',closed_at=now() where request_id=p_request_id;
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,changed_fields)
    values(auth.uid(),'delivery_bid_tie_requires_review','service_request',p_request_id,array['lowest_bid_amount','tied_bid_count']);
    return jsonb_build_object('status','tie_review','lowest_amount_ngn',v_bid.amount_ngn,'tied_bid_count',v_ties);
  end if;
  v_cost:=v_bid.amount_ngn;
  v_price:=round(v_cost/0.75,4);
  update public.partner_quotes set status='selected' where id=v_bid.id;
  update public.delivery_quote_windows set status='quoted',closed_at=now() where request_id=p_request_id;
  insert into public.customer_delivery_quotes(request_id,winning_bid_id,total_direct_cost_ngn,unrounded_price_ngn)
  values(p_request_id,v_bid.id,v_cost,v_price);
  return jsonb_build_object('status','quoted','winning_bid_id',v_bid.id,'unrounded_price_ngn',v_price);
end $$;

create or replace function public.resolve_delivery_quote_tie(p_request_id uuid,p_winning_bid_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_window public.delivery_quote_windows%rowtype;v_bid public.partner_quotes%rowtype;v_lowest numeric(14,2);
begin
  if not (public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only Operations can resolve a quote tie'; end if;
  if length(btrim(p_reason))<10 then raise check_violation using message='Tie decision reason is required'; end if;
  select * into v_window from public.delivery_quote_windows where request_id=p_request_id and status='tie_review' for update;
  if not found then raise object_not_in_prerequisite_state using message='No tie awaits review'; end if;
  select min(amount_ngn) into v_lowest from public.partner_quotes
    where request_id=p_request_id and status='valid' and submitted_at<v_window.deadline_at;
  select * into v_bid from public.partner_quotes where id=p_winning_bid_id and request_id=p_request_id
    and status='valid' and submitted_at<v_window.deadline_at and amount_ngn=v_lowest;
  if not found then raise check_violation using message='Only a tied lowest valid bid can be selected'; end if;
  update public.partner_quotes set status='selected' where id=v_bid.id;
  update public.delivery_quote_windows set status='quoted' where request_id=p_request_id;
  insert into public.customer_delivery_quotes(request_id,winning_bid_id,total_direct_cost_ngn,unrounded_price_ngn)
  values(p_request_id,v_bid.id,v_bid.amount_ngn,round(v_bid.amount_ngn/0.75,4));
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,changed_fields)
  values(auth.uid(),'delivery_bid_tie_resolved:'||btrim(p_reason),'service_request',p_request_id,array['winning_bid_id']);
end $$;

create or replace function public.invalidate_partner_quote(p_bid_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_request_id uuid;
begin
  if not (public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only Operations can invalidate bids'; end if;
  if length(btrim(p_reason))<10 then raise check_violation using message='Invalidation reason is required'; end if;
  select q.request_id into v_request_id from public.partner_quotes q
    join public.delivery_quote_windows w on w.request_id=q.request_id
    where q.id=p_bid_id and q.status='valid' and w.status in ('open','tie_review') for update of q;
  if v_request_id is null then raise object_not_in_prerequisite_state using message='Bid cannot be invalidated'; end if;
  update public.partner_quotes set status='invalid',invalidation_reason=btrim(p_reason) where id=p_bid_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,changed_fields)
  values(auth.uid(),'delivery_bid_invalidated:'||btrim(p_reason),'service_request',v_request_id,array['bid_status','invalidation_reason']);
end $$;

create or replace function public.reopen_delivery_quote_window(p_request_id uuid,p_reason text)
returns timestamptz language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_deadline timestamptz;
begin
  if not (public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only Operations can reopen bidding'; end if;
  if length(btrim(p_reason))<10 then raise check_violation using message='Reopening reason is required'; end if;
  v_deadline:=now()+interval '2 hours';
  update public.delivery_quote_windows set status='open',published_at=now(),deadline_at=v_deadline,closed_at=null
  where request_id=p_request_id and status='no_bids';
  if not found then raise object_not_in_prerequisite_state using message='Only no-bid windows can be reopened'; end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,changed_fields)
  values(auth.uid(),'delivery_bids_reopened:'||btrim(p_reason),'service_request',p_request_id,array['published_at','deadline_at']);
  return v_deadline;
end $$;

create or replace function public.accept_customer_delivery_quote(p_request_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_customer uuid;v_quote public.customer_delivery_quotes%rowtype;
begin
  select customer_id into v_customer from public.service_requests where id=p_request_id;
  if v_customer is null or not public.is_customer_user(v_customer) then raise insufficient_privilege using message='Only the customer can accept this quote'; end if;
  select * into v_quote from public.customer_delivery_quotes where request_id=p_request_id for update;
  if not found or v_quote.status<>'sent' or v_quote.customer_price_ngn is null
     or (v_quote.expires_at is not null and now()>=v_quote.expires_at) then
    raise object_not_in_prerequisite_state using message='Quote is unavailable or expired'; end if;
  update public.customer_delivery_quotes set status='accepted',accepted_at=now() where request_id=p_request_id;
end $$;

create or replace function public.set_delivery_quote_price(p_request_id uuid,p_other_direct_cost_ngn numeric,p_customer_price_ngn numeric,p_reason text,p_expires_at timestamptz)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_quote public.customer_delivery_quotes%rowtype;v_bid public.partner_quotes%rowtype;v_policy public.delivery_pricing_policies%rowtype;
  v_cost numeric(14,2);v_raw numeric(16,4);v_expected numeric(14,2);
begin
  if not (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only administrators can finalize pricing'; end if;
  if p_other_direct_cost_ngn is null or p_other_direct_cost_ngn<0 or p_customer_price_ngn is null
    or p_customer_price_ngn<=0 or nullif(btrim(p_reason),'') is null
    or p_expires_at is null or p_expires_at<=now() then
    raise check_violation using message='Approved final price, costs, expiry and reason are required'; end if;
  select * into v_quote from public.customer_delivery_quotes where request_id=p_request_id and status='pending_price' for update;
  if not found then raise object_not_in_prerequisite_state using message='Quote is not awaiting pricing'; end if;
  select * into v_bid from public.partner_quotes where id=v_quote.winning_bid_id;
  v_cost:=v_bid.amount_ngn+p_other_direct_cost_ngn;
  v_raw:=round(v_cost/0.75,4);
  select * into v_policy from public.delivery_pricing_policies where retired_at is null for share;
  if not found then raise object_not_in_prerequisite_state using message='Management must approve a rounding policy'; end if;
  v_expected:=round(round((v_cost/0.75)/v_policy.rounding_increment_ngn)*v_policy.rounding_increment_ngn,2);
  if p_customer_price_ngn is distinct from v_expected then
    raise check_violation using message='Customer price must match the approved direct-cost formula and rounding policy'; end if;
  update public.customer_delivery_quotes set other_direct_cost_ngn=p_other_direct_cost_ngn,
    total_direct_cost_ngn=v_cost,unrounded_price_ngn=v_raw,
    customer_price_ngn=p_customer_price_ngn,expires_at=p_expires_at,status='sent',pricing_policy_id=v_policy.id
  where request_id=p_request_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,changed_fields)
  values(auth.uid(),'delivery_price_finalized:'||btrim(p_reason),'service_request',p_request_id,
    array['other_direct_cost_ngn','unrounded_price_ngn','customer_price_ngn','expires_at']);
end $$;

-- The existing conversion procedure may handle warehouse/legacy requests, but quoted delivery
-- requests cannot be approved before customer acceptance and payment policy review.
create or replace function public.guard_quoted_request_conversion()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if new.status='converted' and exists(select 1 from public.delivery_quote_windows where request_id=new.id)
    and not exists(select 1 from public.customer_delivery_quotes where request_id=new.id and status='accepted') then
    raise check_violation using message='Customer quote acceptance is required before conversion'; end if;
  return new;
end $$;
create trigger guard_quoted_request_conversion before update of status on public.service_requests
for each row execute function public.guard_quoted_request_conversion();

create or replace function public.guard_new_delivery_order()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
declare v_request public.service_requests%rowtype;v_code text;v_quote public.customer_delivery_quotes%rowtype;
begin
  -- Historical data and migration fixtures predate this workflow.
  if auth.uid() is null then return new; end if;
  select * into v_request from public.service_requests where id=new.service_request_id;
  select code into v_code from public.services where id=v_request.service_id;
  if v_code in ('SRV-0001','SRV-0002') and exists (
    select 1 from public.delivery_quote_windows where request_id=v_request.id
  ) then
    select * into v_quote from public.customer_delivery_quotes where request_id=v_request.id;
    if not found or v_quote.status<>'accepted' or v_quote.customer_price_ngn is null then
      raise check_violation using message='An accepted delivery quote is required before conversion'; end if;
    if new.customer_price is distinct from v_quote.customer_price_ngn then
      raise check_violation using message='Order price must match the accepted quote'; end if;
  end if;
  return new;
end $$;
create trigger guard_new_delivery_order before insert on public.orders
for each row execute function public.guard_new_delivery_order();

create table public.delivery_credit_approvals (
  job_id uuid primary key references public.jobs(id) on delete restrict,
  approved_by uuid not null references auth.users(id),
  reason text not null check(length(btrim(reason)) between 10 and 500),
  approved_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid references auth.users(id)
);
alter table public.delivery_credit_approvals enable row level security;
create policy delivery_credit_read_staff on public.delivery_credit_approvals for select to authenticated using (
  public.has_role(auth.uid(),'finance') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management'));
revoke insert,update,delete on public.delivery_credit_approvals from authenticated;
grant select on public.delivery_credit_approvals to authenticated;

create or replace function public.approve_delivery_credit(p_job_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only Management can approve credit'; end if;
  if not exists(select 1 from public.jobs j join public.orders o on o.id=j.order_id
    join public.customer_delivery_quotes q on q.request_id=o.service_request_id
    where j.id=p_job_id and q.status='accepted') then
    raise check_violation using message='Accepted quoted delivery job required'; end if;
  insert into public.delivery_credit_approvals(job_id,approved_by,reason)
  values(p_job_id,auth.uid(),p_reason)
  on conflict(job_id) do update set approved_by=excluded.approved_by,reason=excluded.reason,
    approved_at=now(),revoked_at=null,revoked_by=null;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,changed_fields)
  values(auth.uid(),'delivery_credit_approved','job',p_job_id,array['credit_approval']);
end $$;

create or replace function public.guard_quoted_partner_award()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
declare v_price numeric(14,2);v_request_id uuid;v_paid numeric(14,2);
begin
  if new.status not in ('assigned','accepted') then return new; end if;
  select o.service_request_id,o.customer_price into v_request_id,v_price
  from public.jobs j join public.orders o on o.id=j.order_id where j.id=new.job_id;
  if not exists(select 1 from public.customer_delivery_quotes where request_id=v_request_id) then return new; end if;
  select coalesce(sum(amount),0) into v_paid from public.customer_payments
  where job_id=new.job_id and status='received';
  if v_paid < v_price and not exists(select 1 from public.delivery_credit_approvals
    where job_id=new.job_id and revoked_at is null) then
    raise check_violation using message='Customer payment or approved credit is required before partner award'; end if;
  return new;
end $$;
create trigger guard_quoted_partner_award before insert or update of status on public.partner_assignments
for each row execute function public.guard_quoted_partner_award();

create table public.coverage_change_history (
  id bigint generated always as identity primary key,
  entity_type text not null check(entity_type in ('location','corridor')),
  entity_id uuid not null,
  actor_id uuid references auth.users(id),
  reason text,
  previous_state jsonb,
  new_state jsonb not null,
  changed_at timestamptz not null default now()
);
alter table public.coverage_change_history enable row level security;
create policy coverage_history_staff_read on public.coverage_change_history for select to authenticated using (
  public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management'));
grant select on public.coverage_change_history to authenticated;
revoke insert,update,delete on public.coverage_change_history from authenticated;

create or replace function public.record_coverage_change()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  insert into public.coverage_change_history(entity_type,entity_id,actor_id,reason,previous_state,new_state)
  values(case when tg_table_name='coverage_locations' then 'location' else 'corridor' end,
    new.id,auth.uid(),new.change_reason,
    case when tg_op='INSERT' then null else to_jsonb(old) end,to_jsonb(new));
  return new;
end $$;
create trigger audit_coverage_location after insert or update on public.coverage_locations
for each row execute function public.record_coverage_change();
create trigger audit_coverage_corridor after insert or update on public.coverage_corridors
for each row execute function public.record_coverage_change();

-- A database scheduler closes expired windows even when no browser is open.
create extension if not exists pg_cron with schema extensions;
create or replace function public.close_due_delivery_quote_windows()
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_id uuid;v_count integer:=0;
begin
  if current_user <> 'postgres' then
    raise insufficient_privilege using message='Only the database scheduler can close due windows'; end if;
  perform set_config('gohezoh.quote_worker','on',true);
  for v_id in select request_id from public.delivery_quote_windows
    where status='open' and deadline_at<=now() order by deadline_at limit 100
  loop
    perform public.close_delivery_quote_window(v_id);
    v_count:=v_count+1;
  end loop;
  return v_count;
end $$;
revoke all on function public.close_due_delivery_quote_windows() from public,anon,authenticated;
select cron.schedule('gohezoh-close-delivery-quotes','* * * * *','select public.close_due_delivery_quote_windows()');

revoke all on function public.set_coverage_corridor(uuid,boolean,text),
  public.configure_delivery_pricing_policy(numeric,text),
  public.configure_coverage_corridor(text,text,text,boolean,text),public.set_partner_corridor_coverage(uuid,uuid,boolean),
  public.configure_coverage_location(text,text,boolean,text),
  public.set_delivery_quote_price(uuid,numeric,numeric,text,timestamptz),public.publish_delivery_request(uuid),
  public.list_eligible_delivery_requests(),
  public.resolve_delivery_quote_tie(uuid,uuid,text),public.invalidate_partner_quote(uuid,text),
  public.reopen_delivery_quote_window(uuid,text),
  public.submit_partner_quote(uuid,numeric,integer,text,text,boolean,text),public.close_delivery_quote_window(uuid),
  public.accept_customer_delivery_quote(uuid) from public,anon,authenticated;
revoke all on function public.approve_delivery_credit(uuid,text) from public,anon,authenticated;
grant execute on function public.set_coverage_corridor(uuid,boolean,text),
  public.configure_delivery_pricing_policy(numeric,text),
  public.configure_coverage_corridor(text,text,text,boolean,text),public.set_partner_corridor_coverage(uuid,uuid,boolean),
  public.configure_coverage_location(text,text,boolean,text),
  public.set_delivery_quote_price(uuid,numeric,numeric,text,timestamptz),public.publish_delivery_request(uuid),
  public.list_eligible_delivery_requests(),
  public.resolve_delivery_quote_tie(uuid,uuid,text),public.invalidate_partner_quote(uuid,text),
  public.reopen_delivery_quote_window(uuid,text),
  public.submit_partner_quote(uuid,numeric,integer,text,text,boolean,text),public.close_delivery_quote_window(uuid),
  public.accept_customer_delivery_quote(uuid) to authenticated;
grant execute on function public.approve_delivery_credit(uuid,text) to authenticated;
