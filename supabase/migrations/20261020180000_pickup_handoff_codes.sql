-- The sender holds the pickup code; only the assigned rider can verify it.
create table public.pickup_handoff_codes (
  job_id uuid primary key references public.jobs(id) on delete cascade,
  code text not null check (code ~ '^[0-9]{8}$'),
  attempt_count smallint not null default 0 check (attempt_count between 0 and 5),
  verified_at timestamptz,
  verified_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.pickup_handoff_codes enable row level security;
revoke all on public.pickup_handoff_codes from public, anon, authenticated;

create function public.create_pickup_handoff_code()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare v_bytes bytea;
begin
  v_bytes := extensions.gen_random_bytes(4);
  insert into public.pickup_handoff_codes(job_id,code)
  values(new.id,lpad(((get_byte(v_bytes,0)::bigint * 16777216 + get_byte(v_bytes,1)::bigint * 65536 +
    get_byte(v_bytes,2)::bigint * 256 + get_byte(v_bytes,3)::bigint) % 100000000)::text,8,'0'));
  return new;
end $$;
revoke all on function public.create_pickup_handoff_code() from public,anon,authenticated;
create trigger create_pickup_handoff_code after insert on public.jobs
for each row execute function public.create_pickup_handoff_code();

-- Existing jobs that have already passed pickup retain their valid history.
insert into public.pickup_handoff_codes(job_id,code,verified_at)
select j.id,lpad(((get_byte(b.bytes,0)::bigint * 16777216 + get_byte(b.bytes,1)::bigint * 65536 +
  get_byte(b.bytes,2)::bigint * 256 + get_byte(b.bytes,3)::bigint) % 100000000)::text,8,'0'),
  case when j.status in ('picked_up','in_transit','out_for_delivery','hub_received','delivered','closed') then j.updated_at end
from public.jobs j cross join lateral (select extensions.gen_random_bytes(4) as bytes where j.id is not null) b
on conflict(job_id) do nothing;

create function public.get_my_pickup_handoff_codes(p_job_ids uuid[])
returns table(job_id uuid, code text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select j.id,c.code from public.jobs j
  join public.pickup_handoff_codes c on c.job_id=j.id
  join public.orders o on o.id=j.order_id
  join public.service_requests r on r.id=o.service_request_id
  where j.id=any(p_job_ids) and array_length(p_job_ids,1) between 1 and 20
    and public.is_customer_user(j.customer_id)
    and j.assigned_rider_id is not null and j.status in ('partner_assigned','pickup_scheduled','exception')
    and c.verified_at is null
    and exists(select 1 from public.partner_assignments a where a.job_id=j.id and a.partner_id=j.partner_id and a.status='accepted')
    and (not exists(select 1 from public.customer_payment_holds h where h.request_id=r.id)
      or exists(select 1 from public.customer_payment_holds h where h.request_id=r.id and h.status='paid'));
$$;
revoke all on function public.get_my_pickup_handoff_codes(uuid[]) from public,anon;
grant execute on function public.get_my_pickup_handoff_codes(uuid[]) to authenticated;

create function public.verify_pickup_handoff_code(p_job_id uuid,p_code text)
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
  if v_handoff.attempt_count>=5 then raise insufficient_privilege using message='Too many incorrect codes. Contact your company'; end if;
  if v_handoff.code<>p_code then
    update public.pickup_handoff_codes set attempt_count=attempt_count+1 where job_id=p_job_id;
    return jsonb_build_object('verified',false,'attempts_remaining',4-v_handoff.attempt_count);
  end if;
  update public.pickup_handoff_codes set verified_at=clock_timestamp(),verified_by=auth.uid() where job_id=p_job_id;
  update public.jobs set status='picked_up' where id=p_job_id;
  return jsonb_build_object('verified',true,'job_id',p_job_id,'status','picked_up');
end $$;
revoke all on function public.verify_pickup_handoff_code(uuid,text) from public,anon;
grant execute on function public.verify_pickup_handoff_code(uuid,text) to authenticated;

-- A status update, whether from rider, partner or staff, cannot replace handoff verification.
create function public.require_pickup_handoff_verification()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if old.status in ('order_confirmed','partner_assigned','pickup_scheduled','exception')
    and new.status in ('picked_up','in_transit','out_for_delivery','hub_received','delivered')
    and not exists(select 1 from public.pickup_handoff_codes c where c.job_id=old.id and c.verified_at is not null) then
    raise object_not_in_prerequisite_state using message='The sender pickup code must be verified before collection';
  end if;
  return new;
end $$;
revoke all on function public.require_pickup_handoff_verification() from public,anon,authenticated;
create trigger require_pickup_handoff_verification before update of status on public.jobs
for each row execute function public.require_pickup_handoff_verification();
