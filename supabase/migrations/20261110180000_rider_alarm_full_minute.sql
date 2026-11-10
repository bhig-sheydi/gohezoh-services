alter table public.rider_assignment_responses add column alert_sent_at timestamptz;

-- Start the response minute when Firebase accepts the first rider alert,
-- rather than using up part of it while the queue waits for its next poll.
create function public.start_rider_response_on_push() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.event_type='rider_assignment' and new.status='sent' and old.status is distinct from 'sent' then
    update public.rider_assignment_responses r
      set alert_sent_at=now(),deadline_at=now()+interval '1 minute'
      from public.ride_push_devices d
      where d.id=new.device_id and r.job_id=new.source_id and r.rider_id=d.user_id
        and r.alert_sent_at is null and r.accepted_at is null and r.timed_out_at is null;
  end if;
  return new;
end $$;
create trigger start_rider_response_on_push after update of status on public.ride_push_deliveries
  for each row execute function public.start_rider_response_on_push();
