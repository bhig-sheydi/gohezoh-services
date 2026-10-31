-- Operational fuel estimates. These do not alter bids, customer charges, or payouts.
create table public.job_fuel_cost_estimates (
  job_id uuid primary key references public.jobs(id) on delete cascade,
  estimated_fuel_cost_ngn numeric(14,2) not null check (estimated_fuel_cost_ngn >= 0),
  fuel_consumption_l_per_km numeric(8,5) not null check (fuel_consumption_l_per_km > 0),
  fuel_price_ngn_per_litre numeric(12,2) not null check (fuel_price_ngn_per_litre > 0),
  source text not null check (source = 'google_routes_drive'),
  calculated_at timestamptz not null default now()
);

alter table public.job_fuel_cost_estimates enable row level security;
revoke all on public.job_fuel_cost_estimates from anon, authenticated;
comment on table public.job_fuel_cost_estimates is
  'Internal pickup-to-drop-off fuel estimates only; excludes rider-to-pickup travel, detours, idle fuel, and other operating costs.';
