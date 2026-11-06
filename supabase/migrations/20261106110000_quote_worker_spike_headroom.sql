-- Find timed-out route matching windows without scanning all historical quotes.
create index if not exists delivery_quote_windows_matching_due_idx
  on public.delivery_quote_windows(published_at)
  where status='matching';

-- Once the daily spend guard is full, most calls should fail on a cheap indexed
-- read instead of queuing for the single daily budget row's update lock. The
-- original atomic UPSERT remains the authority under concurrent reservations.
create or replace function public.reserve_google_route_matrix_elements(
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
  if exists(select 1 from public.google_route_matrix_daily_budget
            where budget_day=v_day and elements_reserved>p_daily_limit-p_elements) then
    return false;
  end if;

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

-- Keep quote expiry near its one-minute promise during short arrival bursts.
-- A named cron.schedule call updates the existing job rather than adding one.
-- process_due_durable_jobs already claims due rows with FOR UPDATE SKIP LOCKED.
select cron.schedule(
  'gohezoh-process-durable-jobs',
  '10 seconds',
  'select * from public.process_due_durable_jobs(100)'
);
