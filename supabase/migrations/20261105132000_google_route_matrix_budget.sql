-- Google Compute Route Matrix is billed per origin x destination element.
-- Keep its reservations separate from the older Geoapify credit budget.
-- A reservation is deliberately not refunded after an HTTP failure: retrying
-- must not allow the worker to spend beyond its configured daily guard.
create table public.google_route_matrix_daily_budget (
  budget_day date primary key,
  elements_reserved integer not null default 0
    check (elements_reserved between 0 and 1000000),
  updated_at timestamptz not null default now()
);

alter table public.google_route_matrix_daily_budget enable row level security;
revoke all on public.google_route_matrix_daily_budget
  from public, anon, authenticated, service_role;
grant select on public.google_route_matrix_daily_budget to service_role;

-- The 5,000/day pilot default is an application spend guard, not Google's
-- monthly free quota; it can incur Google charges when used every day.
-- The worker may pass a lower or higher configured daily limit (up to 1m).
-- Each call is capped at 100 elements, matching the worker's 10x10 matrix.
create function public.reserve_google_route_matrix_elements(
  p_elements integer,
  p_daily_limit integer default 5000
) returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_day date := (now() at time zone 'UTC')::date;
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Routing worker access required';
  end if;
  if p_elements is null or p_elements<1 or p_elements>100 then
    raise check_violation using message='Invalid Google matrix element reservation';
  end if;
  if p_daily_limit is null or p_daily_limit<1 or p_daily_limit>1000000 then
    raise check_violation using message='Invalid Google matrix daily limit';
  end if;
  if p_elements>p_daily_limit then return false; end if;

  -- The primary-key conflict serializes concurrent reservations for the day;
  -- a losing call returns false without exceeding the chosen limit.
  insert into public.google_route_matrix_daily_budget(budget_day,elements_reserved)
    values(v_day,p_elements)
    on conflict(budget_day) do update
    set elements_reserved=public.google_route_matrix_daily_budget.elements_reserved
                          +excluded.elements_reserved,
        updated_at=now()
    where public.google_route_matrix_daily_budget.elements_reserved
          +excluded.elements_reserved<=p_daily_limit;
  return found;
end $$;

revoke all on function public.reserve_google_route_matrix_elements(integer,integer)
  from public,anon,authenticated;
grant execute on function public.reserve_google_route_matrix_elements(integer,integer)
  to service_role;
