create or replace function public.respond_to_partner_assignment(p_assignment_id uuid, p_accept boolean, p_response_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_assignment public.partner_assignments%rowtype;
begin
  if p_accept is null then
    raise invalid_parameter_value using message = 'Choose whether to accept or decline the assignment';
  end if;
  select * into v_assignment from public.partner_assignments where id = p_assignment_id for update;
  if not found then raise no_data_found using message = 'Partner assignment was not found'; end if;
  if not public.is_partner_user(v_assignment.partner_id) then
    raise insufficient_privilege using message = 'Only the assigned partner can respond to this job';
  end if;
  if v_assignment.status <> 'assigned' then
    raise object_not_in_prerequisite_state using message = 'This assignment has already been answered';
  end if;

  update public.partner_assignments
  set status = case when p_accept then 'accepted'::public.assignment_state else 'rejected'::public.assignment_state end,
      responded_at = now(), response_note = nullif(btrim(p_response_note), '')
  where id = v_assignment.id;
  if not p_accept then
    update public.jobs
    set partner_id = null, status = 'order_confirmed'
    where id = v_assignment.job_id and partner_id = v_assignment.partner_id;
  end if;
  return jsonb_build_object('assignment_id', v_assignment.id, 'status', case when p_accept then 'accepted' else 'rejected' end);
end;
$$;

create or replace function public.guard_job_status_transition()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_staff boolean;
  v_accepted_partner boolean;
  v_rejected_partner boolean;
begin
  if new.status is not distinct from old.status then return new; end if;
  v_staff := public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management');
  v_accepted_partner := exists (
    select 1 from public.partner_assignments pa
    where pa.job_id = old.id and pa.partner_id = old.partner_id and pa.status = 'accepted' and public.is_partner_user(pa.partner_id)
  );
  v_rejected_partner := exists (
    select 1 from public.partner_assignments pa
    where pa.job_id = old.id and pa.partner_id = old.partner_id and pa.status = 'rejected' and public.is_partner_user(pa.partner_id)
  );
  if not (v_staff or v_accepted_partner or (v_rejected_partner and new.status = 'order_confirmed')) then
    raise insufficient_privilege using message = 'Only Gohezoh operations staff or the assigned partner can update delivery progress';
  end if;
  if v_accepted_partner and not v_staff and new.status not in ('pickup_scheduled', 'picked_up', 'in_transit', 'out_for_delivery', 'delivered', 'exception') then
    raise insufficient_privilege using message = 'Partners can update pickup, transit, delivery, or exception statuses only';
  end if;
  if not (
    (old.status = 'order_confirmed' and new.status in ('partner_assigned', 'pickup_scheduled', 'picked_up', 'exception', 'cancelled'))
    or (old.status = 'partner_assigned' and new.status in ('order_confirmed', 'pickup_scheduled', 'picked_up', 'exception', 'cancelled'))
    or (old.status = 'pickup_scheduled' and new.status in ('picked_up', 'exception', 'cancelled'))
    or (old.status = 'picked_up' and new.status in ('in_transit', 'exception'))
    or (old.status = 'in_transit' and new.status in ('out_for_delivery', 'exception'))
    or (old.status = 'out_for_delivery' and new.status in ('delivered', 'exception'))
    or (old.status = 'delivered' and new.status = 'closed')
    or (old.status = 'exception' and new.status in ('pickup_scheduled', 'picked_up', 'in_transit', 'out_for_delivery', 'cancelled'))
  ) then raise object_not_in_prerequisite_state using message = 'That delivery status transition is not allowed'; end if;
  return new;
end;
$$;

comment on function public.respond_to_partner_assignment(uuid, boolean, text)
  is 'Partner response to an assignment; declines release the job back to an unassigned confirmed order.';
comment on function public.guard_job_status_transition()
  is 'Enforces staff and accepted-partner job status transitions, including safe recovery after a partner decline.';
