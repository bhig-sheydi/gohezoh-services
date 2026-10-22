-- The event payload must carry the rider whose plan needs rebuilding.
alter table public.route_planner_events
  add column if not exists rider_id uuid references auth.users(id) on delete cascade;
create index route_planner_events_rider_due_idx
  on public.route_planner_events(rider_id,available_at)
  where status='pending' and rider_id is not null;
