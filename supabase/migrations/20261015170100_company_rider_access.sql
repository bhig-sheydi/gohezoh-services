-- Riders have individual identities without requiring personal email addresses.

create table public.rider_credentials (
  user_id uuid primary key references auth.users(id) on delete cascade,
  partner_id uuid not null references public.logistics_partners(id) on delete cascade,
  rider_name text not null check (length(btrim(rider_name)) between 3 and 120),
  auth_secret_seed text not null unique,
  link_hash text not null unique,
  password_salt text not null,
  password_hash text not null,
  password_fingerprint text not null unique,
  device_public_key jsonb,
  device_bound_at timestamptz,
  challenge text,
  challenge_expires_at timestamptz,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index rider_credentials_partner_idx on public.rider_credentials(partner_id, created_at desc);
alter table public.rider_credentials enable row level security;
revoke all on public.rider_credentials from public, anon, authenticated;

create or replace function public.rider_session_active()
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select public.has_role(auth.uid(),'rider')
    and exists(select 1 from public.rider_credentials c where c.user_id=auth.uid() and c.revoked_at is null)
    and exists(select 1 from auth.sessions s where s.user_id=auth.uid()
      and s.id=(auth.jwt()->>'session_id')::uuid);
$$;
revoke all on function public.rider_session_active() from public,anon;
grant execute on function public.rider_session_active() to authenticated;

create or replace function public.rider_actor_session_active(p_user_id uuid,p_session_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists(select 1 from auth.sessions s where s.id=p_session_id and s.user_id=p_user_id)
    and exists(select 1 from public.rider_credentials c where c.user_id=p_user_id and c.revoked_at is null);
$$;
revoke all on function public.rider_actor_session_active(uuid,uuid) from public,anon,authenticated;
grant execute on function public.rider_actor_session_active(uuid,uuid) to service_role;

-- A rider is not a company manager or a general partner portal user.
create policy jobs_read_assigned_rider on public.jobs for select to authenticated
  using (assigned_rider_id=auth.uid() and public.rider_session_active());

create or replace function public.list_my_rider_jobs()
returns table(job_id uuid, job_number text, status text, pickup_address text, pickup_city text,
  delivery_address text, delivery_city text, recipient_name text, recipient_phone text,
  parcel_summary text, company_name text)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.rider_session_active() then
    raise insufficient_privilege using message='Rider access required';
  end if;
  return query select j.id,j.job_number,j.status::text,j.pickup_address,j.pickup_city,
    j.delivery_address,j.delivery_city,j.recipient_name,j.recipient_phone,
    r.parcel_summary,p.partner_name
  from public.jobs j join public.partner_assignments a on a.job_id=j.id and a.partner_id=j.partner_id
    join public.orders o on o.id=j.order_id join public.service_requests r on r.id=o.service_request_id
    join public.logistics_partners p on p.id=j.partner_id
    join public.partner_users pu on pu.partner_id=j.partner_id and pu.user_id=auth.uid() and pu.membership_role='rider'
  where j.assigned_rider_id=auth.uid() and a.status in ('accepted','completed')
  order by j.updated_at desc limit 50;
end $$;
revoke all on function public.list_my_rider_jobs() from public,anon;
grant execute on function public.list_my_rider_jobs() to authenticated;

-- Preserve the existing transition and delivery-OTP rules while permitting only
-- the individually assigned rider to move their own accepted job forward.
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
    or (old.status='partner_assigned' and new.status in ('order_confirmed','pickup_scheduled','picked_up','exception','cancelled'))
    or (old.status='pickup_scheduled' and new.status in ('picked_up','exception','cancelled'))
    or (old.status='picked_up' and new.status in ('in_transit','exception'))
    or (old.status='in_transit' and new.status in ('out_for_delivery','hub_received','exception'))
    or (old.status='out_for_delivery' and new.status in ('delivered','hub_received','exception'))
    or (old.status='hub_received' and new.status='partner_assigned')
    or (old.status='delivered' and new.status='closed')
    or (old.status='exception' and new.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery','cancelled'))
  ) then raise object_not_in_prerequisite_state using message='That delivery status transition is not allowed'; end if;
  return new;
end $$;

create or replace function public.rider_update_job_status(p_job_id uuid,p_new_status public.job_state)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype;
begin
  if not public.rider_session_active() then raise insufficient_privilege using message='Rider access required'; end if;
  select * into v_job from public.jobs where id=p_job_id for update;
  if not found or v_job.assigned_rider_id is distinct from auth.uid()
    or not exists(select 1 from public.partner_users pu where pu.partner_id=v_job.partner_id and pu.user_id=auth.uid() and pu.membership_role='rider')
    or not exists(select 1 from public.partner_assignments a where a.job_id=v_job.id and a.partner_id=v_job.partner_id and a.status='accepted') then
    raise insufficient_privilege using message='This delivery is not assigned to you';
  end if;
  update public.jobs set status=p_new_status where id=p_job_id;
  if p_new_status='delivered' then
    update public.partner_assignments set status='completed',completed_at=now()
      where job_id=p_job_id and status='accepted';
  end if;
  return jsonb_build_object('job_id',p_job_id,'status',p_new_status);
end $$;
revoke all on function public.rider_update_job_status(uuid,public.job_state) from public,anon;
grant execute on function public.rider_update_job_status(uuid,public.job_state) to authenticated;


-- Internal rider identities bypass public customer/staff signup.
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_role text;v_marketer_invite public.bdo_marketer_invites%rowtype;v_partner_invite public.partner_staff_invitations%rowtype;v_token text;v_org text;
begin
  insert into public.profiles(user_id,full_name,email,phone) values(new.id,nullif(new.raw_user_meta_data->>'full_name',''),new.email,new.phone) on conflict(user_id) do nothing;
  if new.raw_user_meta_data->>'account_kind'='company_rider' then return new; end if;
  if new.raw_user_meta_data->>'account_kind'='staff' then
    v_role:=new.raw_user_meta_data->>'requested_role';
    if v_role not in ('operations','finance','bdo','warehouse','partner','management','marketer') then raise check_violation using message='Choose a valid staff category';end if;
    if v_role='marketer' then
      v_token:=nullif(btrim(new.raw_user_meta_data->>'marketer_invite'),'');
      if v_token is null or length(v_token)<32 then raise insufficient_privilege using message='A valid BDO invitation is required to register as a marketer';end if;
      select * into v_marketer_invite from public.bdo_marketer_invites where token_hash=extensions.digest(v_token,'sha256') and email=lower(btrim(new.email))
        and used_by is null and expires_at>now() and public.has_role(bdo_user_id,'bdo') for update;
      if not found then raise insufficient_privilege using message='This marketer invitation is invalid, expired, or for another email';end if;
      update public.bdo_marketer_invites set used_by=new.id where id=v_marketer_invite.id;
      insert into public.staff_applications(user_id,requested_role,organization_name,invited_by_bdo_id)
        values(new.id,'marketer',nullif(btrim(new.raw_user_meta_data->>'organization_name'),''),v_marketer_invite.bdo_user_id);
    elsif v_role='partner' and nullif(btrim(new.raw_user_meta_data->>'partner_invite'),'') is not null then
      v_token:=btrim(new.raw_user_meta_data->>'partner_invite');
      select * into v_partner_invite from public.partner_staff_invitations where token_hash=extensions.digest(v_token,'sha256')
        and invited_email=lower(btrim(new.email)) and status='pending' and expires_at>now() for update;
      if not found then raise insufficient_privilege using message='This partner invitation is invalid, expired, or for another email';end if;
      select partner_name into v_org from public.logistics_partners where id=v_partner_invite.partner_id and status='active';
      if v_org is null then raise object_not_in_prerequisite_state using message='This partner company is inactive';end if;
      update public.partner_staff_invitations set status='claimed',claimed_by=new.id,claimed_at=now() where id=v_partner_invite.id;
      insert into public.staff_applications(user_id,requested_role,organization_name,partner_invitation_id)
        values(new.id,'partner',v_org,v_partner_invite.id);
    else
      insert into public.staff_applications(user_id,requested_role,organization_name)
        values(new.id,v_role::public.app_role,nullif(btrim(new.raw_user_meta_data->>'organization_name'),''));
    end if;
  else insert into public.user_roles(user_id,role) values(new.id,'customer') on conflict do nothing;
  end if;
  return new;
end $$;

-- Company riders may send and verify recipient OTPs only for their own assigned jobs.
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
  if v_job.status <> 'out_for_delivery' then
    raise object_not_in_prerequisite_state using message = 'A delivery code can only be sent when the job is out for delivery';
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
  if v_job.status <> 'out_for_delivery' then
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
