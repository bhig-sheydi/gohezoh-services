-- Keep delivery progress in valid operational order and expose a staff-only update action.
create or replace function public.guard_job_status_transition()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  if not (
    public.has_role(auth.uid(), 'operations')
    or public.has_role(auth.uid(), 'admin')
    or public.has_role(auth.uid(), 'management')
  ) then
    raise insufficient_privilege using message = 'Only Gohezoh operations staff can update delivery progress';
  end if;

  if not (
    (old.status = 'order_confirmed' and new.status in ('partner_assigned', 'pickup_scheduled', 'picked_up', 'exception', 'cancelled'))
    or (old.status = 'partner_assigned' and new.status in ('pickup_scheduled', 'picked_up', 'exception', 'cancelled'))
    or (old.status = 'pickup_scheduled' and new.status in ('picked_up', 'exception', 'cancelled'))
    or (old.status = 'picked_up' and new.status in ('in_transit', 'exception'))
    or (old.status = 'in_transit' and new.status in ('out_for_delivery', 'exception'))
    or (old.status = 'out_for_delivery' and new.status in ('delivered', 'exception'))
    or (old.status = 'delivered' and new.status = 'closed')
    or (old.status = 'exception' and new.status in ('pickup_scheduled', 'picked_up', 'in_transit', 'out_for_delivery', 'cancelled'))
  ) then
    raise object_not_in_prerequisite_state using message = 'That delivery status transition is not allowed';
  end if;

  return new;
end;
$$;

create trigger jobs_guard_status_transition
  before update of status on public.jobs
  for each row execute function public.guard_job_status_transition();

revoke all on function public.guard_job_status_transition() from public, anon, authenticated;

create or replace function public.update_job_status(p_job_id uuid, p_new_status public.job_state)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_job public.jobs%rowtype;
begin
  if auth.uid() is null or not (
    public.has_role(auth.uid(), 'operations')
    or public.has_role(auth.uid(), 'admin')
    or public.has_role(auth.uid(), 'management')
  ) then
    raise insufficient_privilege using message = 'Only Gohezoh operations staff can update delivery progress';
  end if;

  select * into v_job from public.jobs where id = p_job_id for update;
  if not found then
    raise no_data_found using message = 'Delivery job was not found';
  end if;

  update public.jobs set status = p_new_status where id = v_job.id;
  return jsonb_build_object('job_id', v_job.id, 'status', p_new_status);
end;
$$;

revoke all on function public.update_job_status(uuid, public.job_state) from public, anon, authenticated;
grant execute on function public.update_job_status(uuid, public.job_state) to authenticated;
comment on function public.update_job_status(uuid, public.job_state)
  is 'Operations-only delivery progress update with enforced status transitions and history tracking.';
