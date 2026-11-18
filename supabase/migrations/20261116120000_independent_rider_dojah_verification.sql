-- Independent riders verify themselves; no logistics-company selection is needed.
-- Dojah's signed webhook is the only path that activates a rider account.
create table public.independent_rider_verifications (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reference_id text not null unique,
  phone text not null check (phone ~ '^\+?[0-9]{10,15}$'),
  status text not null default 'pending' check (status in ('pending','verified','failed')),
  failure_reason text,
  rider_id uuid unique references public.company_riders(id),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
alter table public.independent_rider_verifications enable row level security;
revoke all on public.independent_rider_verifications from anon,authenticated;

create function public.my_independent_rider_verification()
returns table(reference_id text,status text,failure_reason text)
language sql stable security definer set search_path=pg_catalog,public as $$
  select v.reference_id,v.status,v.failure_reason
  from public.independent_rider_verifications v where v.user_id=auth.uid();
$$;
revoke all on function public.my_independent_rider_verification() from public,anon;
grant execute on function public.my_independent_rider_verification() to authenticated;

create function public.begin_independent_rider_verification(p_phone text)
returns text language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_user uuid:=auth.uid();v_reference text;
begin
  if v_user is null or auth.role()<>'authenticated' or not exists(
    select 1 from auth.users u where u.id=v_user and u.email_confirmed_at is not null
      and u.raw_user_meta_data->>'account_kind'='independent_rider') then
    raise insufficient_privilege using message='Confirm your independent rider email first';
  end if;
  if p_phone !~ '^\+?[0-9]{10,15}$' then raise check_violation using message='Enter a valid phone number'; end if;
  if exists(select 1 from public.company_riders where independent_user_id=v_user and status='approved') then
    raise unique_violation using message='Rider account is already active'; end if;
  select reference_id into v_reference from public.independent_rider_verifications
    where user_id=v_user and status='pending';
  if v_reference is not null then return v_reference; end if;
  v_reference:='KWP-RIDER-'||extensions.gen_random_uuid()::text;
  insert into public.independent_rider_verifications(user_id,reference_id,phone)
    values(v_user,v_reference,p_phone)
    on conflict(user_id) do update set reference_id=excluded.reference_id,phone=excluded.phone,
      status='pending',failure_reason=null,created_at=now(),reviewed_at=null;
  return v_reference;
end $$;
revoke all on function public.begin_independent_rider_verification(text) from public,anon;
grant execute on function public.begin_independent_rider_verification(text) to authenticated;

-- Called only after the Edge Function verifies Dojah's HMAC and required steps.
create function public.finish_independent_rider_verification(p_reference text,p_passed boolean,p_reason text default null)
returns void language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_record public.independent_rider_verifications%rowtype;v_name text;v_email text;
  v_partner uuid;v_rider uuid;v_seed text;
begin
  select * into v_record from public.independent_rider_verifications
    where reference_id=p_reference for update;
  if not found or v_record.status<>'pending' then return; end if;
  if not p_passed then
    update public.independent_rider_verifications set status='failed',
      failure_reason=left(coalesce(p_reason,'Verification did not pass'),160),reviewed_at=now()
      where user_id=v_record.user_id;
    return;
  end if;
  select nullif(btrim(p.full_name),''),u.email into v_name,v_email
    from public.profiles p join auth.users u on u.id=p.user_id where p.user_id=v_record.user_id;
  if length(coalesce(v_name,''))<3 or v_email is null then
    raise check_violation using message='Verified rider profile is incomplete'; end if;
  insert into public.logistics_partners(partner_name,contact_person,phone,email,partner_type,status)
    values('Independent rider - '||v_name,v_name,v_record.phone,v_email,'independent_rider','active')
    returning id into v_partner;
  insert into public.company_riders(partner_id,full_name,phone,status,reviewed_at,independent_user_id)
    values(v_partner,v_name,v_record.phone,'approved',now(),v_record.user_id) returning id into v_rider;
  insert into public.partner_users(partner_id,user_id,membership_role)
    values(v_partner,v_record.user_id,'rider');
  insert into public.user_roles(user_id,role) values(v_record.user_id,'rider') on conflict do nothing;
  delete from public.user_roles where user_id=v_record.user_id and role='customer';
  v_seed:=encode(extensions.gen_random_bytes(32),'hex');
  insert into public.rider_credentials(user_id,partner_id,rider_name,roster_id,auth_secret_seed,
    link_hash,password_salt,password_hash,password_fingerprint)
    values(v_record.user_id,v_partner,v_name,v_rider,v_seed,
      encode(extensions.digest(v_seed||'link','sha256'),'hex'),
      encode(extensions.gen_random_bytes(16),'hex'),encode(extensions.digest(v_seed||'password','sha256'),'hex'),
      encode(extensions.digest(v_seed||'fingerprint','sha256'),'hex'));
  update public.profiles set phone=v_record.phone where user_id=v_record.user_id;
  update public.independent_rider_verifications set status='verified',rider_id=v_rider,
    reviewed_at=now(),failure_reason=null where user_id=v_record.user_id;
end $$;
revoke all on function public.finish_independent_rider_verification(text,boolean,text) from public,anon,authenticated;
grant execute on function public.finish_independent_rider_verification(text,boolean,text) to service_role;

-- Self-operated riders have no registered company vehicle hours. Preserve the
-- existing daily closing override and give them the same 20:00 default used
-- for dispatch planning, otherwise every matched offer would be rejected.
create or replace function public.company_dispatch_close_at(p_partner uuid,p_at timestamptz default now())
returns timestamptz language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_day date:=(p_at at time zone 'Africa/Lagos')::date;
  v_clock time:=(p_at at time zone 'Africa/Lagos')::time;
  v_close timestamptz;
begin
  select d.closes_at into v_close from public.company_daily_dispatch_closing d
    where d.partner_id=p_partner and d.work_date in (v_day,v_day-1)
      and d.closes_at>p_at order by d.work_date desc limit 1;
  if v_close is not null then return v_close; end if;
  if exists(select 1 from public.company_daily_dispatch_closing d
    where d.partner_id=p_partner and d.work_date=v_day) then
    select d.closes_at into v_close from public.company_daily_dispatch_closing d
      where d.partner_id=p_partner and d.work_date=v_day;
    return v_close;
  end if;
  if exists(select 1 from public.logistics_partners p where p.id=p_partner
    and p.partner_type='independent_rider' and p.status='active') then
    return (v_day+time '20:00') at time zone 'Africa/Lagos';
  end if;
  select max(case when v.closing_time>v.opening_time then
      (v_day+v.closing_time) at time zone 'Africa/Lagos'
    when v_clock<v.closing_time or v_clock<v.opening_time then
      (v_day+v.closing_time) at time zone 'Africa/Lagos'
    else ((v_day+1)+v.closing_time) at time zone 'Africa/Lagos' end)
    into v_close from public.partner_application_vehicles v where v.partner_id=p_partner;
  return v_close;
end $$;

-- Retire the former company-picker registration RPC. A browser must never self-approve.
revoke execute on function public.register_independent_rider(uuid,text) from authenticated;
