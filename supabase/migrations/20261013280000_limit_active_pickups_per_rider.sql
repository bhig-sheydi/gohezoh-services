-- Assign accepted partner jobs to individual riders and cap each rider at five
-- active pickups. Company dispatchers and managers are not counted as riders.
alter table public.jobs
  add column assigned_rider_id uuid references auth.users(id) on delete set null;

create index jobs_assigned_rider_active_idx
  on public.jobs(assigned_rider_id, status)
  where assigned_rider_id is not null;

create or replace function public.list_partner_rider_jobs()
returns table(
  partner_id uuid,
  job_id uuid,
  job_number text,
  status public.job_state,
  assigned_rider_id uuid
)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.partner_users pu
    where pu.user_id=auth.uid() and pu.membership_role in ('manager','dispatcher')
  ) then
    raise insufficient_privilege using message='Partner manager or dispatcher access is required';
  end if;
  return query
    select j.partner_id,j.id,j.job_number,j.status,j.assigned_rider_id
    from public.jobs j
    join public.partner_assignments pa on pa.job_id=j.id and pa.partner_id=j.partner_id and pa.status='accepted'
    join public.partner_users mine on mine.partner_id=j.partner_id and mine.user_id=auth.uid()
    where mine.membership_role in ('manager','dispatcher')
      and j.status in ('partner_assigned','pickup_scheduled')
    order by j.updated_at desc
    limit 100;
end;
$$;

create or replace function public.guard_rider_active_pickup_limit()
returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_active_count integer;
begin
  if new.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery')
    and exists (
      select 1 from public.partner_assignments pa
      where pa.job_id=new.id and pa.partner_id=new.partner_id and pa.status='accepted'
    ) and new.assigned_rider_id is null then
    raise check_violation using message='Assign a partner-company rider before scheduling or progressing this pickup';
  end if;
  if tg_op='UPDATE' and new.status='exception'
    and old.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery')
    and new.assigned_rider_id is null
    and exists (
      select 1 from public.partner_assignments pa
      where pa.job_id=new.id and pa.partner_id=new.partner_id and pa.status='accepted'
    ) then
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

create trigger jobs_guard_rider_active_pickup_limit
  before insert or update of assigned_rider_id,partner_id,status on public.jobs
  for each row execute function public.guard_rider_active_pickup_limit();

create or replace function public.guard_rider_status_assignment()
returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.status is distinct from old.status
    and not (public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management'))
    and exists (
      select 1 from public.partner_users pu
      where pu.partner_id=old.partner_id and pu.user_id=auth.uid() and pu.membership_role='rider'
    ) and old.assigned_rider_id is distinct from auth.uid() then
    raise insufficient_privilege using message='Riders can update delivery progress only for jobs assigned to them';
  end if;
  return new;
end;
$$;

create trigger jobs_guard_rider_status_assignment
  before update of status on public.jobs
  for each row execute function public.guard_rider_status_assignment();

create or replace function public.assign_job_to_rider(p_job_id uuid,p_rider_user_id uuid)
returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_actor uuid:=auth.uid();
  v_job public.jobs%rowtype;
begin
  if v_actor is null then
    raise insufficient_privilege using message='Sign in as a partner manager or dispatcher to assign a rider';
  end if;
  select * into v_job from public.jobs where id=p_job_id for update;
  if not found then raise no_data_found using message='Delivery job was not found'; end if;
  if v_job.partner_id is null or not exists (
    select 1 from public.partner_users pu
    where pu.partner_id=v_job.partner_id and pu.user_id=v_actor
      and pu.membership_role in ('manager','dispatcher')
  ) then
    raise insufficient_privilege using message='Only this partner company manager or dispatcher can assign its riders';
  end if;
  if v_job.status not in ('partner_assigned','pickup_scheduled') then
    raise object_not_in_prerequisite_state using message='Riders can be assigned before pickup or while pickup is scheduled';
  end if;
  if not exists (
    select 1 from public.partner_assignments pa
    where pa.job_id=v_job.id and pa.partner_id=v_job.partner_id and pa.status='accepted'
  ) then
    raise object_not_in_prerequisite_state using message='The partner must accept the job before assigning a rider';
  end if;
  if not exists (
    select 1 from public.partner_users pu
    where pu.partner_id=v_job.partner_id and pu.user_id=p_rider_user_id and pu.membership_role='rider'
  ) then
    raise check_violation using message='Choose a rider who belongs to the assigned partner company';
  end if;

  update public.jobs set assigned_rider_id=p_rider_user_id where id=v_job.id;
  return jsonb_build_object('job_id',v_job.id,'rider_user_id',p_rider_user_id,'status','assigned');
end;
$$;

revoke all on function public.list_partner_rider_jobs() from public,anon;
grant execute on function public.list_partner_rider_jobs() to authenticated;
revoke all on function public.guard_rider_active_pickup_limit() from public,anon,authenticated;
revoke all on function public.guard_rider_status_assignment() from public,anon,authenticated;
revoke all on function public.assign_job_to_rider(uuid,uuid) from public,anon;
grant execute on function public.assign_job_to_rider(uuid,uuid) to authenticated;

comment on column public.jobs.assigned_rider_id is
  'Individual partner-company rider responsible for this job. Active pickup capacity counts pickup_scheduled, picked_up, and exception work until it moves into transit or is otherwise completed/cancelled.';
