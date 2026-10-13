-- Escalate a newly raised delivery exception to the internal teams that can act on it.
create or replace function public.notify_delivery_exception()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.status = 'exception' and (tg_op = 'INSERT' or old.status is distinct from 'exception') then
    insert into public.notifications(user_id, job_id, event_type, channel, title, body, payload, status)
    select distinct ur.user_id,
      new.id,
      'job_exception_escalated',
      'in_app',
      'Delivery exception needs review',
      'Job ' || new.job_number || ' has been marked as an exception. Review the delivery and coordinate the next step.',
      jsonb_build_object('job_id', new.id, 'job_number', new.job_number, 'status', new.status),
      'queued'
    from public.user_roles ur
    where ur.role in ('operations', 'management', 'admin')
    on conflict do nothing;
  end if;
  return new;
end;
$$;

revoke all on function public.notify_delivery_exception() from public, anon, authenticated;
create trigger jobs_notify_delivery_exception
  after insert or update of status on public.jobs
  for each row execute function public.notify_delivery_exception();

comment on function public.notify_delivery_exception() is
  'Creates role-scoped in-app alerts for Operations, Management, and Admin on each new delivery exception.';
