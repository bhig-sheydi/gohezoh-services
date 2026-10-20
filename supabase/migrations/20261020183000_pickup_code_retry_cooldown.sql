-- A locked code recovers without requiring a staff member to alter the job.
alter table public.pickup_handoff_codes add column blocked_until timestamptz;

create or replace function public.verify_pickup_handoff_code(p_job_id uuid,p_code text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype;v_handoff public.pickup_handoff_codes%rowtype;
begin
  if p_code !~ '^[0-9]{8}$' then raise invalid_parameter_value using message='Enter the eight-digit pickup code'; end if;
  if not public.rider_session_active() then raise insufficient_privilege using message='Active rider access required'; end if;
  select * into v_job from public.jobs where id=p_job_id for update;
  if not found or v_job.assigned_rider_id is distinct from auth.uid()
    or v_job.status not in ('partner_assigned','pickup_scheduled','exception')
    or not exists(select 1 from public.partner_users pu where pu.partner_id=v_job.partner_id and pu.user_id=auth.uid() and pu.membership_role='rider')
    or not exists(select 1 from public.partner_assignments a where a.job_id=v_job.id and a.partner_id=v_job.partner_id and a.status='accepted') then
    raise insufficient_privilege using message='This pickup is not assigned to you';
  end if;
  if exists(select 1 from public.customer_payment_holds h join public.orders o on o.service_request_id=h.request_id
    where o.id=v_job.order_id and h.status<>'paid') then
    raise object_not_in_prerequisite_state using message='Customer payment has not been confirmed';
  end if;
  select * into v_handoff from public.pickup_handoff_codes where job_id=p_job_id for update;
  if not found or v_handoff.verified_at is not null then raise object_not_in_prerequisite_state using message='Pickup code is unavailable'; end if;
  if v_handoff.blocked_until>clock_timestamp() then
    raise insufficient_privilege using message='Too many incorrect codes. Try again in 15 minutes';
  end if;
  if v_handoff.blocked_until is not null then
    update public.pickup_handoff_codes set attempt_count=0,blocked_until=null where job_id=p_job_id;
    v_handoff.attempt_count:=0;
  end if;
  if v_handoff.code<>p_code then
    update public.pickup_handoff_codes set attempt_count=attempt_count+1,
      blocked_until=case when attempt_count+1>=5 then clock_timestamp()+interval '15 minutes' else null end
    where job_id=p_job_id;
    return jsonb_build_object('verified',false,'attempts_remaining',greatest(0,4-v_handoff.attempt_count));
  end if;
  update public.pickup_handoff_codes set verified_at=clock_timestamp(),verified_by=auth.uid() where job_id=p_job_id;
  update public.jobs set status='picked_up' where id=p_job_id;
  return jsonb_build_object('verified',true,'job_id',p_job_id,'status','picked_up');
end $$;
