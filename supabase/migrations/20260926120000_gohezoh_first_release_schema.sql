-- Gohezoh first production release: customer request through delivery and POD.
-- Finance, BDO, settlements, and warehouse inventory remain later phases.

create type public.app_role as enum (
  'customer', 'partner', 'operations', 'finance', 'admin', 'management'
);

create type public.customer_state as enum ('pending', 'active', 'inactive');
create type public.partner_state as enum ('pending', 'active', 'suspended', 'inactive');
create type public.request_state as enum (
  'submitted', 'under_review', 'approved', 'rejected', 'converted', 'cancelled'
);
create type public.order_state as enum ('confirmed', 'processing', 'completed', 'cancelled');
create type public.job_state as enum (
  'order_confirmed', 'partner_assigned', 'pickup_scheduled', 'picked_up',
  'in_transit', 'out_for_delivery', 'delivered', 'exception', 'closed', 'cancelled'
);
create type public.assignment_state as enum ('assigned', 'accepted', 'rejected', 'completed', 'cancelled');

create sequence public.customer_number_seq start 1;
create sequence public.partner_number_seq start 1;
create sequence public.route_number_seq start 1;
create sequence public.request_number_seq start 1;
create sequence public.order_number_seq start 1;
create sequence public.job_number_seq start 1;

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  email text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.user_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.app_role not null,
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  customer_number text not null unique default (
    'CUS-' || lpad(nextval('public.customer_number_seq')::text, 5, '0')
  ),
  company_name text not null,
  customer_type text not null default 'individual',
  contact_person text not null,
  email text,
  phone text not null,
  address text,
  city text,
  state text,
  status public.customer_state not null default 'pending',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.customer_users (
  customer_id uuid not null references public.customers(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (customer_id, user_id)
);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null unique,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.logistics_partners (
  id uuid primary key default gen_random_uuid(),
  partner_number text not null unique default (
    'PRT-' || lpad(nextval('public.partner_number_seq')::text, 4, '0')
  ),
  partner_name text not null,
  contact_person text not null,
  email text,
  phone text not null,
  base_city text,
  base_state text,
  partner_type text not null default 'logistics',
  service_areas text[] not null default '{}',
  status public.partner_state not null default 'pending',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.partner_users (
  partner_id uuid not null references public.logistics_partners(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (partner_id, user_id)
);

create table public.routes (
  id uuid primary key default gen_random_uuid(),
  route_number text not null unique default (
    'RTE-' || lpad(nextval('public.route_number_seq')::text, 4, '0')
  ),
  route_name text not null,
  origin_city text not null,
  origin_state text,
  destination_city text not null,
  destination_state text,
  partner_id uuid references public.logistics_partners(id) on delete set null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.service_requests (
  id uuid primary key default gen_random_uuid(),
  request_number text not null unique default (
    'REQ-' || lpad(nextval('public.request_number_seq')::text, 5, '0')
  ),
  customer_id uuid not null references public.customers(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  status public.request_state not null default 'submitted',
  pickup_address text not null,
  pickup_city text not null,
  pickup_state text,
  sender_name text not null,
  sender_phone text not null,
  delivery_address text not null,
  delivery_city text not null,
  delivery_state text,
  recipient_name text not null,
  recipient_phone text not null,
  preferred_pickup_at timestamptz,
  parcel_summary text,
  special_instructions text,
  operations_note text,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique default (
    'ORD-' || lpad(nextval('public.order_number_seq')::text, 5, '0')
  ),
  service_request_id uuid not null unique references public.service_requests(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  status public.order_state not null default 'confirmed',
  customer_price numeric(14, 2) check (customer_price is null or customer_price >= 0),
  currency text not null default 'NGN' check (currency ~ '^[A-Z]{3}$'),
  confirmed_by uuid references auth.users(id) on delete set null,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, customer_id, service_id)
);

create table public.jobs (
  id uuid primary key default gen_random_uuid(),
  job_number text not null unique default (
    'JOB-' || lpad(nextval('public.job_number_seq')::text, 5, '0')
  ),
  order_id uuid not null unique,
  customer_id uuid not null,
  service_id uuid not null,
  partner_id uuid references public.logistics_partners(id) on delete set null,
  route_id uuid references public.routes(id) on delete set null,
  assigned_operations_user_id uuid references auth.users(id) on delete set null,
  status public.job_state not null default 'order_confirmed',
  pickup_address text not null,
  pickup_city text not null,
  pickup_state text,
  sender_name text not null,
  sender_phone text not null,
  delivery_address text not null,
  delivery_city text not null,
  delivery_state text,
  recipient_name text not null,
  recipient_phone text not null,
  preferred_pickup_at timestamptz,
  exception_details text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (order_id, customer_id, service_id)
    references public.orders(id, customer_id, service_id) on delete restrict
);

create table public.job_parcels (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  parcel_number smallint not null check (parcel_number > 0),
  description text not null,
  quantity integer not null default 1 check (quantity > 0),
  weight_kg numeric(10, 3) check (weight_kg is null or weight_kg >= 0),
  length_cm numeric(10, 2) check (length_cm is null or length_cm >= 0),
  width_cm numeric(10, 2) check (width_cm is null or width_cm >= 0),
  height_cm numeric(10, 2) check (height_cm is null or height_cm >= 0),
  declared_value numeric(14, 2) check (declared_value is null or declared_value >= 0),
  packaging_information text,
  handling_instructions text,
  created_at timestamptz not null default now(),
  unique (job_id, parcel_number)
);

create table public.job_financials (
  job_id uuid primary key references public.jobs(id) on delete cascade,
  customer_revenue numeric(14, 2) not null default 0 check (customer_revenue >= 0),
  partner_cost numeric(14, 2) not null default 0 check (partner_cost >= 0),
  other_direct_cost numeric(14, 2) not null default 0 check (other_direct_cost >= 0),
  currency text not null default 'NGN' check (currency ~ '^[A-Z]{3}$'),
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.partner_assignments (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  partner_id uuid not null references public.logistics_partners(id) on delete restrict,
  status public.assignment_state not null default 'assigned',
  assigned_by uuid references auth.users(id) on delete set null,
  assigned_at timestamptz not null default now(),
  responded_at timestamptz,
  response_note text,
  completed_at timestamptz
);

create unique index partner_assignments_one_open_per_job
  on public.partner_assignments(job_id)
  where status in ('assigned', 'accepted');

create table public.job_status_history (
  id bigint generated always as identity primary key,
  job_id uuid not null references public.jobs(id) on delete cascade,
  previous_status public.job_state,
  new_status public.job_state not null,
  changed_by uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now()
);

create table public.otp_verifications (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  recipient_phone text not null,
  code_hash text not null,
  expires_at timestamptz not null,
  attempt_count smallint not null default 0 check (attempt_count >= 0),
  verified_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.proof_of_delivery (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  storage_path text not null,
  content_type text,
  file_size_bytes bigint check (file_size_bytes is null or file_size_bytes >= 0),
  recipient_name text,
  notes text,
  recorded_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  job_id uuid references public.jobs(id) on delete cascade,
  event_type text not null,
  channel text not null default 'in_app'
    check (channel in ('in_app', 'email', 'sms', 'whatsapp')),
  title text not null,
  body text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'queued'
    check (status in ('queued', 'sent', 'delivered', 'failed')),
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  entity_type text not null,
  entity_id uuid not null,
  action text not null,
  actor_id uuid references auth.users(id) on delete set null,
  changed_fields text[] not null default '{}',
  created_at timestamptz not null default now()
);

create index customer_users_user_id_idx on public.customer_users(user_id);
create index partner_users_user_id_idx on public.partner_users(user_id);
create index service_requests_customer_created_idx on public.service_requests(customer_id, created_at desc);
create index service_requests_status_created_idx on public.service_requests(status, created_at desc);
create index orders_customer_created_idx on public.orders(customer_id, created_at desc);
create index jobs_customer_created_idx on public.jobs(customer_id, created_at desc);
create index jobs_partner_status_idx on public.jobs(partner_id, status);
create index jobs_status_created_idx on public.jobs(status, created_at desc);
create index job_parcels_job_id_idx on public.job_parcels(job_id);
create index partner_assignments_partner_status_idx on public.partner_assignments(partner_id, status);
create index job_status_history_job_changed_idx on public.job_status_history(job_id, changed_at desc);
create index otp_verifications_job_expiry_idx on public.otp_verifications(job_id, expires_at desc);
create index proof_of_delivery_job_created_idx on public.proof_of_delivery(job_id, created_at desc);
create index notifications_user_created_idx on public.notifications(user_id, created_at desc);
create index audit_logs_entity_created_idx on public.audit_logs(entity_type, entity_id, created_at desc);

create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.user_roles ur
    where ur.user_id = _user_id and ur.role = _role
  );
$$;

create or replace function public.is_customer_user(_customer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.customer_users cu
    where cu.customer_id = _customer_id and cu.user_id = auth.uid()
  );
$$;

create or replace function public.is_partner_user(_partner_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.partner_users pu
    where pu.partner_id = _partner_id and pu.user_id = auth.uid()
  );
$$;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  insert into public.profiles (user_id, full_name, email, phone)
  values (
    new.id,
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    new.email,
    new.phone
  )
  on conflict (user_id) do nothing;

  insert into public.user_roles (user_id, role)
  values (new.id, 'customer')
  on conflict (user_id, role) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_touch_updated_at before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger customers_touch_updated_at before update on public.customers
  for each row execute function public.touch_updated_at();
create trigger services_touch_updated_at before update on public.services
  for each row execute function public.touch_updated_at();
create trigger partners_touch_updated_at before update on public.logistics_partners
  for each row execute function public.touch_updated_at();
create trigger routes_touch_updated_at before update on public.routes
  for each row execute function public.touch_updated_at();
create trigger requests_touch_updated_at before update on public.service_requests
  for each row execute function public.touch_updated_at();
create trigger orders_touch_updated_at before update on public.orders
  for each row execute function public.touch_updated_at();
create trigger jobs_touch_updated_at before update on public.jobs
  for each row execute function public.touch_updated_at();
create trigger job_financials_touch_updated_at before update on public.job_financials
  for each row execute function public.touch_updated_at();

create or replace function public.protect_customer_identity_fields()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is not null
     and not (
       public.has_role(auth.uid(), 'operations')
       or public.has_role(auth.uid(), 'admin')
       or public.has_role(auth.uid(), 'management')
     )
     and (
       new.customer_number is distinct from old.customer_number
       or new.status is distinct from old.status
       or new.created_by is distinct from old.created_by
     ) then
    raise exception 'Only Gohezoh operations can change customer status or identifiers';
  end if;
  return new;
end;
$$;

create trigger customers_protect_identity
  before update on public.customers
  for each row execute function public.protect_customer_identity_fields();

create or replace function public.record_job_status_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.job_status_history (job_id, previous_status, new_status, changed_by)
    values (new.id, null, new.status, auth.uid());
  elsif new.status is distinct from old.status then
    insert into public.job_status_history (job_id, previous_status, new_status, changed_by)
    values (new.id, old.status, new.status, auth.uid());
  end if;
  return new;
end;
$$;

create trigger jobs_record_status
  after insert or update of status on public.jobs
  for each row execute function public.record_job_status_change();

create or replace function public.record_audit_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  old_row jsonb := '{}'::jsonb;
  new_row jsonb := '{}'::jsonb;
  entity_uuid uuid;
  fields text[];
begin
  if tg_op <> 'INSERT' then old_row := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then new_row := to_jsonb(new); end if;

  if tg_op = 'DELETE' then
    entity_uuid := (old_row ->> 'id')::uuid;
    fields := array(select key from jsonb_each(old_row));
  elsif tg_op = 'INSERT' then
    entity_uuid := (new_row ->> 'id')::uuid;
    fields := array(select key from jsonb_each(new_row));
  else
    entity_uuid := (new_row ->> 'id')::uuid;
    fields := array(
      select n.key
      from jsonb_each(new_row) as n(key, value)
      where old_row -> n.key is distinct from n.value
    );
  end if;

  insert into public.audit_logs (entity_type, entity_id, action, actor_id, changed_fields)
  values (tg_table_name, entity_uuid, lower(tg_op), auth.uid(), coalesce(fields, '{}'));

  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

create trigger customers_audit after insert or update or delete on public.customers
  for each row execute function public.record_audit_change();
create trigger requests_audit after insert or update or delete on public.service_requests
  for each row execute function public.record_audit_change();
create trigger orders_audit after insert or update or delete on public.orders
  for each row execute function public.record_audit_change();
create trigger jobs_audit after insert or update or delete on public.jobs
  for each row execute function public.record_audit_change();
create trigger assignments_audit after insert or update or delete on public.partner_assignments
  for each row execute function public.record_audit_change();
create trigger pod_audit after insert or update or delete on public.proof_of_delivery
  for each row execute function public.record_audit_change();

insert into public.services (code, name, description) values
  ('SRV-0001', 'Local Delivery', 'Movement of goods within a local operating area.'),
  ('SRV-0002', 'Interstate Delivery', 'Movement of goods between cities or states.'),
  ('SRV-0003', 'Warehousing', 'Receiving, storing, and managing customer inventory.'),
  ('SRV-0004', 'Order Fulfillment', 'Receiving, picking, packing, and coordinating delivery of customer orders.')
on conflict (code) do nothing;

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.customers enable row level security;
alter table public.customer_users enable row level security;
alter table public.services enable row level security;
alter table public.logistics_partners enable row level security;
alter table public.partner_users enable row level security;
alter table public.routes enable row level security;
alter table public.service_requests enable row level security;
alter table public.orders enable row level security;
alter table public.jobs enable row level security;
alter table public.job_parcels enable row level security;
alter table public.job_financials enable row level security;
alter table public.partner_assignments enable row level security;
alter table public.job_status_history enable row level security;
alter table public.otp_verifications enable row level security;
alter table public.proof_of_delivery enable row level security;
alter table public.notifications enable row level security;
alter table public.audit_logs enable row level security;

create policy profiles_read_self_or_management on public.profiles
  for select to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));
create policy profiles_insert_self on public.profiles
  for insert to authenticated with check (user_id = auth.uid());
create policy profiles_update_self on public.profiles
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy user_roles_read_self_or_management on public.user_roles
  for select to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));
create policy user_roles_manage on public.user_roles
  for all to authenticated
  using (public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'))
  with check (public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create policy customers_read_authorized on public.customers
  for select to authenticated
  using (
    public.is_customer_user(id) or created_by = auth.uid()
    or public.has_role(auth.uid(), 'operations')
    or public.has_role(auth.uid(), 'finance')
    or public.has_role(auth.uid(), 'admin')
    or public.has_role(auth.uid(), 'management')
  );
create policy customers_register_self on public.customers
  for insert to authenticated
  with check (created_by = auth.uid() and public.has_role(auth.uid(), 'customer'));
create policy customers_update_authorized on public.customers
  for update to authenticated
  using (
    public.is_customer_user(id) or created_by = auth.uid()
    or public.has_role(auth.uid(), 'operations')
    or public.has_role(auth.uid(), 'admin')
    or public.has_role(auth.uid(), 'management')
  )
  with check (
    public.is_customer_user(id) or created_by = auth.uid()
    or public.has_role(auth.uid(), 'operations')
    or public.has_role(auth.uid(), 'admin')
    or public.has_role(auth.uid(), 'management')
  );

create policy customer_users_read_authorized on public.customer_users
  for select to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));
create policy customer_users_add_self_or_staff on public.customer_users
  for insert to authenticated
  with check (
    public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management')
    or (user_id = auth.uid() and exists (
      select 1 from public.customers c where c.id = customer_id and c.created_by = auth.uid()
    ))
  );
create policy customer_users_remove_self_or_management on public.customer_users
  for delete to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create policy services_read_authenticated on public.services
  for select to authenticated using (true);
create policy services_manage on public.services
  for all to authenticated
  using (public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'))
  with check (public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create policy partners_read_staff_or_self on public.logistics_partners
  for select to authenticated
  using (
    public.is_partner_user(id)
    or public.has_role(auth.uid(), 'operations')
    or public.has_role(auth.uid(), 'finance')
    or public.has_role(auth.uid(), 'admin')
    or public.has_role(auth.uid(), 'management')
  );
create policy partners_manage on public.logistics_partners
  for all to authenticated
  using (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'))
  with check (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create policy partner_users_read_self_or_staff on public.partner_users
  for select to authenticated
  using (user_id = auth.uid() or public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));
create policy partner_users_manage on public.partner_users
  for all to authenticated
  using (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'))
  with check (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create policy routes_read_staff_or_assigned_partner on public.routes
  for select to authenticated
  using (
    public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management')
    or (partner_id is not null and public.is_partner_user(partner_id))
  );
create policy routes_manage on public.routes
  for all to authenticated
  using (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'))
  with check (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create policy requests_read_customer_or_staff on public.service_requests
  for select to authenticated
  using (
    public.is_customer_user(customer_id)
    or public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management')
  );
create policy requests_submit_customer on public.service_requests
  for insert to authenticated
  with check (
    created_by = auth.uid() and status = 'submitted'
    and public.is_customer_user(customer_id)
  );
create policy requests_update_staff on public.service_requests
  for update to authenticated
  using (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'))
  with check (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create policy orders_read_customer_or_staff on public.orders
  for select to authenticated
  using (
    public.is_customer_user(customer_id)
    or public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'finance')
    or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management')
  );
create policy orders_manage on public.orders
  for all to authenticated
  using (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'))
  with check (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create policy jobs_read_customer_staff_or_assigned_partner on public.jobs
  for select to authenticated
  using (
    public.is_customer_user(customer_id)
    or (partner_id is not null and public.is_partner_user(partner_id))
    or public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'finance')
    or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management')
  );
create policy jobs_manage_operations on public.jobs
  for all to authenticated
  using (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'))
  with check (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create policy parcels_read_via_job on public.job_parcels
  for select to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_id));
create policy parcels_manage_operations on public.job_parcels
  for all to authenticated
  using (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'))
  with check (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create policy job_financials_read_finance_management on public.job_financials
  for select to authenticated
  using (public.has_role(auth.uid(), 'finance') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));
create policy job_financials_manage_finance_management on public.job_financials
  for all to authenticated
  using (public.has_role(auth.uid(), 'finance') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'))
  with check (public.has_role(auth.uid(), 'finance') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create policy assignments_read_staff_or_assigned_partner on public.partner_assignments
  for select to authenticated
  using (
    public.is_partner_user(partner_id)
    or public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management')
  );
create policy assignments_manage_operations on public.partner_assignments
  for all to authenticated
  using (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'))
  with check (public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

create policy job_history_read_via_job on public.job_status_history
  for select to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_id));

create policy pod_read_via_job on public.proof_of_delivery
  for select to authenticated
  using (exists (select 1 from public.jobs j where j.id = job_id));
create policy pod_add_operations_or_assigned_partner on public.proof_of_delivery
  for insert to authenticated
  with check (
    public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management')
    or exists (
      select 1 from public.jobs j
      where j.id = job_id and j.partner_id is not null and public.is_partner_user(j.partner_id)
    )
  );

create policy notifications_read_self on public.notifications
  for select to authenticated using (user_id = auth.uid());

create policy audit_logs_read_management on public.audit_logs
  for select to authenticated
  using (public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management'));

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant usage on schema public to authenticated;
grant usage on all sequences in schema public to authenticated;

grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.user_roles to authenticated;
grant select, insert, update on public.customers to authenticated;
grant select, insert, delete on public.customer_users to authenticated;
grant select, insert, update, delete on public.services to authenticated;
grant select, insert, update, delete on public.logistics_partners to authenticated;
grant select, insert, update, delete on public.partner_users to authenticated;
grant select, insert, update, delete on public.routes to authenticated;
grant select, insert, update on public.service_requests to authenticated;
grant select, insert, update on public.orders to authenticated;
grant select, insert, update on public.jobs to authenticated;
grant select, insert, update, delete on public.job_parcels to authenticated;
grant select, insert, update, delete on public.job_financials to authenticated;
grant select, insert, update, delete on public.partner_assignments to authenticated;
grant select on public.job_status_history to authenticated;
grant select, insert on public.proof_of_delivery to authenticated;
grant select on public.notifications to authenticated;
grant select on public.audit_logs to authenticated;

grant all on public.otp_verifications to service_role;
grant all on public.notifications to service_role;
grant all on public.audit_logs to service_role;

revoke all on function public.has_role(uuid, public.app_role) from public, anon;
revoke all on function public.is_customer_user(uuid) from public, anon;
revoke all on function public.is_partner_user(uuid) from public, anon;
revoke all on function public.handle_new_auth_user() from public, anon, authenticated;
revoke all on function public.touch_updated_at() from public, anon, authenticated;
revoke all on function public.protect_customer_identity_fields() from public, anon, authenticated;
revoke all on function public.record_job_status_change() from public, anon, authenticated;
revoke all on function public.record_audit_change() from public, anon, authenticated;
grant execute on function public.has_role(uuid, public.app_role) to authenticated;
grant execute on function public.is_customer_user(uuid) to authenticated;
grant execute on function public.is_partner_user(uuid) to authenticated;

comment on table public.service_requests is 'Customer-submitted service requests awaiting Gohezoh operations review.';
comment on table public.orders is 'Confirmed customer orders; one order can create one logistics job in the first release.';
comment on table public.jobs is 'Operational waybill and delivery record. Financial values are kept in a separately protected table.';
comment on table public.job_financials is 'Restricted financial facts for each job; hidden from customers and logistics partners.';
comment on table public.otp_verifications is 'Stores only server-generated OTP hashes. Client roles have no access.';
comment on table public.audit_logs is 'Append-only change metadata. Field names are recorded without copying personal or financial values.';
