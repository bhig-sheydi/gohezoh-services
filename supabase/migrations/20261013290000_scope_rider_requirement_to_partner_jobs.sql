-- Rider assignment is required only for jobs accepted by a partner company.
-- Operations-owned jobs still need to use the exception workflow.
create or replace function public.guard_rider_active_pickup_limit()
returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_active_count integer;
  v_partner_accepted boolean;
begin
  select exists (
    select 1 from public.partner_assignments pa
    where pa.job_id=new.id and pa.partner_id=new.partner_id and pa.status='accepted'
  ) into v_partner_accepted;

  if new.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery')
    and v_partner_accepted and new.assigned_rider_id is null then
    raise check_violation using message='Assign a partner-company rider before scheduling or progressing this pickup';
  end if;
  if tg_op='UPDATE' and new.status='exception'
    and old.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery')
    and v_partner_accepted and new.assigned_rider_id is null then
    raise check_violation using message='Keep the assigned rider on an active delivery exception until it is resolved';
  end if;
  if new.assigned_rider_id is null then
    return new;
  end if;

  if new.partner_id is null or not exists (
    select 1 from public.partner_users pu
    where pu.partner_id=new.partner_id
      and pu.user_id=new.assigned_rider_id
      and pu.membership_role='rider'
  ) then
    raise check_violation using message='Choose a rider who belongs to the assigned partner company';
  end if;

  -- Serialize concurrent assignments/status changes for one rider so two
  -- dispatchers cannot both consume the fifth available slot.
  perform 1 from auth.users u where u.id=new.assigned_rider_id for update;

  if new.status in ('pickup_scheduled','picked_up','exception') then
    select count(*) into v_active_count
    from public.jobs j
    where j.assigned_rider_id=new.assigned_rider_id
      and j.id<>new.id
      and j.status in ('pickup_scheduled','picked_up','exception');
    if v_active_count >= 5 then
      raise check_violation using message='This rider already has five active pickups. Assign another rider or wait until an active delivery is completed.';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.guard_rider_active_pickup_limit() from public,anon,authenticated;
