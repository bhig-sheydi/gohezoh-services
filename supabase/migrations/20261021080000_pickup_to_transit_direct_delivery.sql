-- Pickup confirmation starts transit immediately; delivery confirmation completes it.

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
  update public.jobs set status='in_transit' where id=p_job_id;
  return jsonb_build_object('verified',true,'job_id',p_job_id,'status','in_transit');
end $$;

create or replace function public.issue_delivery_otp(p_job_id uuid, p_actor_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_job public.jobs%rowtype;
  v_code text;
  v_hash text;
  v_random bytea;
  v_sent_count integer;
  v_attempt_count integer;
begin
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found then raise no_data_found using message = 'Delivery job was not found'; end if;
  if not exists (
    select 1 from public.partner_assignments pa
    where pa.job_id = v_job.id and pa.partner_id = v_job.partner_id
      and pa.status = 'accepted'
      and exists (select 1 from public.partner_users pu where pu.partner_id = pa.partner_id and pu.user_id = p_actor_id
        and (pu.membership_role <> 'rider' or v_job.assigned_rider_id = p_actor_id))
  ) then raise insufficient_privilege using message = 'Only the assigned partner can request a delivery code'; end if;
  if v_job.status not in ('picked_up','in_transit','out_for_delivery') then
    raise object_not_in_prerequisite_state using message = 'A delivery code can only be sent after pickup is confirmed';
  end if;
  select count(*), coalesce(sum(ov.attempt_count), 0)::integer
    into v_sent_count, v_attempt_count
    from public.otp_verifications ov
    where ov.job_id = v_job.id and ov.created_at > now() - interval '1 hour';
  if v_sent_count >= 3 then raise insufficient_privilege using message = 'Too many delivery codes requested. Try again later'; end if;
  if v_attempt_count >= 5 then raise insufficient_privilege using message = 'Too many incorrect codes. Try again later'; end if;
  if exists (
    select 1 from public.otp_verifications ov
    where ov.job_id = v_job.id and ov.verified_at is null and ov.expires_at > now()
      and ov.created_at > now() - interval '60 seconds'
  ) then raise object_not_in_prerequisite_state using message = 'A delivery code was sent recently. Please wait before requesting another'; end if;

  update public.otp_verifications set expires_at = now()
    where job_id = v_job.id and verified_at is null and expires_at > now();
  v_random := extensions.gen_random_bytes(4);
  v_code := lpad(((get_byte(v_random, 0)::bigint * 16777216 + get_byte(v_random, 1)::bigint * 65536 + get_byte(v_random, 2)::bigint * 256 + get_byte(v_random, 3)::bigint) % 1000000)::text, 6, '0');
  v_hash := extensions.crypt(v_code, extensions.gen_salt('bf', 10));
  insert into public.otp_verifications(job_id, recipient_phone, code_hash, expires_at)
    values (v_job.id, v_job.recipient_phone, v_hash, now() + interval '10 minutes');
  return jsonb_build_object('code', v_code, 'recipient_phone', v_job.recipient_phone, 'job_number', v_job.job_number);
end;
$$;

create or replace function public.verify_delivery_otp(p_job_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_job public.jobs%rowtype;
  v_otp public.otp_verifications%rowtype;
  v_total_attempts integer;
begin
  if p_code !~ '^[0-9]{6}$' then raise invalid_parameter_value using message = 'Enter the six-digit delivery code'; end if;
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found then raise no_data_found using message = 'Delivery job was not found'; end if;
  if not exists (
    select 1 from public.partner_assignments pa
    join public.partner_users pu on pu.partner_id = pa.partner_id
    where pa.job_id = v_job.id and pa.partner_id = v_job.partner_id
      and pa.status = 'accepted' and pu.user_id = auth.uid()
      and (pu.membership_role <> 'rider' or (v_job.assigned_rider_id = auth.uid() and public.rider_session_active()))
  ) then raise insufficient_privilege using message = 'Only the accepted partner can verify the delivery code'; end if;
  if v_job.status not in ('picked_up','in_transit','out_for_delivery') then
    raise object_not_in_prerequisite_state using message = 'This delivery is not awaiting recipient confirmation';
  end if;
  select * into v_otp from public.otp_verifications ov
    where ov.job_id = v_job.id and ov.verified_at is null and ov.expires_at > now()
    order by ov.created_at desc limit 1 for update;
  if not found then raise object_not_in_prerequisite_state using message = 'Request a new delivery code before verifying'; end if;
  select coalesce(sum(ov.attempt_count), 0)::integer into v_total_attempts
    from public.otp_verifications ov
    where ov.job_id = v_job.id and ov.created_at > now() - interval '1 hour';
  if v_total_attempts >= 5 then raise insufficient_privilege using message = 'Too many incorrect codes. Try again later'; end if;
  if v_otp.attempt_count >= 5 then raise insufficient_privilege using message = 'Too many incorrect codes. Request a new code'; end if;
  if extensions.crypt(p_code, v_otp.code_hash) <> v_otp.code_hash then
    update public.otp_verifications set attempt_count = attempt_count + 1 where id = v_otp.id;
    return jsonb_build_object('verified', false, 'attempts_remaining', 4 - v_otp.attempt_count);
  end if;
  update public.otp_verifications set verified_at = now(), attempt_count = attempt_count + 1 where id = v_otp.id;
  update public.jobs set status = 'delivered' where id = v_job.id;
  update public.partner_assignments set status = 'completed', completed_at = now()
    where job_id = v_job.id and status = 'accepted';
  return jsonb_build_object('verified', true, 'job_id', v_job.id, 'job_number', v_job.job_number, 'status', 'delivered');
end;
$$;

create or replace function public.guard_job_status_transition()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_staff boolean;v_accepted_partner boolean;v_rejected_partner boolean;v_rider boolean;
begin
  if new.status is not distinct from old.status then return new; end if;
  if new.status='delivered' and not exists(select 1 from public.otp_verifications ov where ov.job_id=old.id and ov.verified_at is not null) then
    raise object_not_in_prerequisite_state using message='Recipient delivery code must be verified before marking delivered';
  end if;
  v_staff:=public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management');
  v_accepted_partner:=exists(select 1 from public.partner_assignments pa where pa.job_id=old.id and pa.partner_id=old.partner_id and pa.status='accepted' and public.is_partner_user(pa.partner_id));
  v_rejected_partner:=exists(select 1 from public.partner_assignments pa where pa.job_id=old.id and pa.partner_id=old.partner_id and pa.status='rejected' and public.is_partner_user(pa.partner_id));
  v_rider:=public.rider_session_active() and old.assigned_rider_id=auth.uid() and exists(
    select 1 from public.partner_assignments pa join public.partner_users pu on pu.partner_id=pa.partner_id
    where pa.job_id=old.id and pa.partner_id=old.partner_id and pa.status='accepted'
      and pu.user_id=auth.uid() and pu.membership_role='rider');
  if not (v_staff or v_accepted_partner or v_rider or (v_rejected_partner and old.status='partner_assigned' and new.status='order_confirmed' and new.partner_id is null)) then
    raise insufficient_privilege using message='Only Gohezoh operations staff or the assigned accepted partner rider can update delivery progress';
  end if;
  if (v_accepted_partner or v_rider) and not v_staff and new.status not in ('pickup_scheduled','picked_up','in_transit','out_for_delivery','delivered','exception','hub_received') then
    raise insufficient_privilege using message='Riders can update pickup, transit, hub handoff, delivery, or exception statuses only';
  end if;
  if not (
    (old.status='order_confirmed' and new.status in ('partner_assigned','pickup_scheduled','picked_up','exception','cancelled'))
    or (old.status='partner_assigned' and new.status in ('order_confirmed','pickup_scheduled','picked_up','in_transit','exception','cancelled'))
    or (old.status='pickup_scheduled' and new.status in ('picked_up','in_transit','exception','cancelled'))
    or (old.status='picked_up' and new.status in ('in_transit','delivered','exception'))
    or (old.status='in_transit' and new.status in ('out_for_delivery','hub_received','delivered','exception'))
    or (old.status='out_for_delivery' and new.status in ('delivered','hub_received','exception'))
    or (old.status='hub_received' and new.status='partner_assigned')
    or (old.status='delivered' and new.status='closed')
    or (old.status='exception' and new.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery','cancelled'))
  ) then raise object_not_in_prerequisite_state using message='That delivery status transition is not allowed'; end if;
  return new;
end $$;
