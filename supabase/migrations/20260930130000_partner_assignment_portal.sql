create or replace function public.create_logistics_partner(
  p_partner_name text,
  p_contact_person text,
  p_phone text,
  p_email text default null,
  p_base_city text default null,
  p_base_state text default null,
  p_service_areas text[] default '{}',
  p_portal_user_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_partner public.logistics_partners%rowtype;
  v_portal_user_id uuid;
begin
  if v_user_id is null or not (
    public.has_role(v_user_id, 'operations') or public.has_role(v_user_id, 'admin') or public.has_role(v_user_id, 'management')
  ) then
    raise insufficient_privilege using message = 'Only Gohezoh operations staff can add logistics partners';
  end if;
  if nullif(btrim(p_partner_name), '') is null or nullif(btrim(p_contact_person), '') is null or nullif(btrim(p_phone), '') is null then
    raise invalid_parameter_value using message = 'Partner name, contact person, and phone are required';
  end if;

  insert into public.logistics_partners(partner_name, contact_person, phone, email, base_city, base_state, service_areas, status)
  values (btrim(p_partner_name), btrim(p_contact_person), btrim(p_phone), nullif(btrim(p_email), ''), nullif(btrim(p_base_city), ''), nullif(btrim(p_base_state), ''), coalesce(p_service_areas, '{}'), 'active')
  returning * into v_partner;

  if nullif(btrim(p_portal_user_email), '') is not null then
    select id into v_portal_user_id from auth.users where lower(email) = lower(btrim(p_portal_user_email));
    if v_portal_user_id is null then
      raise no_data_found using message = 'Create the partner user account before linking it here';
    end if;
    insert into public.partner_users(partner_id, user_id) values (v_partner.id, v_portal_user_id);
    insert into public.user_roles(user_id, role) values (v_portal_user_id, 'partner') on conflict do nothing;
  end if;

  return jsonb_build_object('partner_id', v_partner.id, 'partner_number', v_partner.partner_number, 'partner_name', v_partner.partner_name);
end;
$$;

create or replace function public.assign_job_to_partner(p_job_id uuid, p_partner_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_job public.jobs%rowtype;
  v_partner public.logistics_partners%rowtype;
  v_assignment public.partner_assignments%rowtype;
begin
  if v_user_id is null or not (
    public.has_role(v_user_id, 'operations') or public.has_role(v_user_id, 'admin') or public.has_role(v_user_id, 'management')
  ) then
    raise insufficient_privilege using message = 'Only Gohezoh operations staff can assign delivery jobs';
  end if;
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found then raise no_data_found using message = 'Delivery job was not found'; end if;
  select * into v_partner from public.logistics_partners where id = p_partner_id for update;
  if not found or v_partner.status <> 'active' then
    raise check_violation using message = 'Choose an active logistics partner';
  end if;
  if v_job.partner_id is not null or v_job.status not in ('order_confirmed', 'partner_assigned') then
    raise object_not_in_prerequisite_state using message = 'This job is not available for partner assignment';
  end if;

  insert into public.partner_assignments(job_id, partner_id, status, assigned_by)
  values (v_job.id, v_partner.id, 'assigned', v_user_id)
  returning * into v_assignment;
  update public.jobs set partner_id = v_partner.id, status = 'partner_assigned' where id = v_job.id;

  return jsonb_build_object('assignment_id', v_assignment.id, 'job_number', v_job.job_number, 'partner_name', v_partner.partner_name, 'status', 'assigned');
end;
$$;

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
  if not p_accept then update public.jobs set partner_id = null where id = v_assignment.job_id and partner_id = v_assignment.partner_id; end if;
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
begin
  if new.status is not distinct from old.status then return new; end if;
  v_staff := public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management');
  v_accepted_partner := exists (
    select 1 from public.partner_assignments pa
    where pa.job_id = old.id and pa.partner_id = old.partner_id and pa.status = 'accepted' and public.is_partner_user(pa.partner_id)
  );
  if not (v_staff or v_accepted_partner) then
    raise insufficient_privilege using message = 'Only Gohezoh operations staff or the accepted partner can update delivery progress';
  end if;
  if v_accepted_partner and not v_staff and new.status not in ('picked_up', 'in_transit', 'out_for_delivery', 'delivered', 'exception') then
    raise insufficient_privilege using message = 'Partners can update pickup, transit, delivery, or exception statuses only';
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
  ) then raise object_not_in_prerequisite_state using message = 'That delivery status transition is not allowed'; end if;
  return new;
end;
$$;

create or replace function public.update_job_status(p_job_id uuid, p_new_status public.job_state)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_job public.jobs%rowtype;
  v_staff boolean;
  v_accepted_partner boolean;
begin
  v_staff := auth.uid() is not null and (
    public.has_role(auth.uid(), 'operations') or public.has_role(auth.uid(), 'admin') or public.has_role(auth.uid(), 'management')
  );
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found then raise no_data_found using message = 'Delivery job was not found'; end if;
  v_accepted_partner := exists (
    select 1 from public.partner_assignments pa
    where pa.job_id = v_job.id and pa.partner_id = v_job.partner_id and pa.status = 'accepted' and public.is_partner_user(pa.partner_id)
  );
  if not (v_staff or v_accepted_partner) then
    raise insufficient_privilege using message = 'Only Gohezoh operations staff or the accepted partner can update delivery progress';
  end if;
  update public.jobs set status = p_new_status where id = v_job.id;
  if p_new_status = 'delivered' then
    update public.partner_assignments
    set status = 'completed', completed_at = now()
    where job_id = v_job.id and status = 'accepted';
  end if;
  return jsonb_build_object('job_id', v_job.id, 'status', p_new_status);
end;
$$;

revoke all on function public.create_logistics_partner(text,text,text,text,text,text,text[],text) from public, anon, authenticated;
revoke all on function public.assign_job_to_partner(uuid,uuid) from public, anon, authenticated;
revoke all on function public.respond_to_partner_assignment(uuid,boolean,text) from public, anon, authenticated;
revoke all on function public.update_job_status(uuid,public.job_state) from public, anon, authenticated;
grant execute on function public.create_logistics_partner(text,text,text,text,text,text,text[],text) to authenticated;
grant execute on function public.assign_job_to_partner(uuid,uuid) to authenticated;
grant execute on function public.respond_to_partner_assignment(uuid,boolean,text) to authenticated;
grant execute on function public.update_job_status(uuid,public.job_state) to authenticated;
