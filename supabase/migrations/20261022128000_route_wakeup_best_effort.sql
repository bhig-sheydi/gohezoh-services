-- Network or secret failures must not abort the transaction that created work.
create or replace function public.wake_route_planner_on_event() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  begin
    perform public.invoke_due_route_planner();
  exception when others then
    null; -- The durable queue is retried by cron.
  end;
  return null;
end $$;
