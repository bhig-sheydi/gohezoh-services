-- Wake the worker as soon as a transaction enqueues route work. The one-minute
-- cron job remains a retry path if a network request fails.
create function public.wake_route_planner_on_event() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  begin
    perform public.invoke_due_route_planner();
  exception when others then
    -- Routing availability must never roll back a booking or custody update.
    -- Cron retries the durable event after the transaction commits.
    null;
  end;
  return null;
end $$;
create trigger route_planner_event_wakeup
  after insert on public.route_planner_events
  for each statement execute function public.wake_route_planner_on_event();
revoke all on function public.wake_route_planner_on_event() from public,anon,authenticated;
