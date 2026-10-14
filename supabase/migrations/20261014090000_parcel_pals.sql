-- Private six-digit Parcel Pal codes and mutually accepted connections.
create table public.parcel_pal_codes (
  code text primary key check (code ~ '^[0-9]{6}$'),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.parcel_pal_codes enable row level security;
revoke all on public.parcel_pal_codes from public, anon, authenticated;

create table public.parcel_pal_connections (
  user_a uuid not null references auth.users(id) on delete cascade,
  user_b uuid not null references auth.users(id) on delete cascade,
  requested_by uuid not null references auth.users(id) on delete cascade,
  status text not null check (status in ('pending','accepted','declined','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (user_a,user_b),
  check (user_a < user_b),
  check (requested_by in (user_a,user_b)),
  check ((status='accepted' and responded_at is not null) or status<>'accepted')
);
create index parcel_pal_connections_pending_user_a_idx
  on public.parcel_pal_connections(user_a,created_at desc) where status='pending';
create index parcel_pal_connections_pending_user_b_idx
  on public.parcel_pal_connections(user_b,created_at desc) where status='pending';
alter table public.parcel_pal_connections enable row level security;
revoke all on public.parcel_pal_connections from public, anon, authenticated;

-- Bound code enumeration and request spam. Counters are private and roll over daily.
create table public.parcel_pal_daily_limits (
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null check (action in ('search','request')),
  usage_date date not null,
  use_count integer not null check (use_count > 0),
  primary key (user_id,action)
);
alter table public.parcel_pal_daily_limits enable row level security;
revoke all on public.parcel_pal_daily_limits from public, anon, authenticated;

create or replace function public.ensure_parcel_pal_code(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_code text;
  v_candidate text;
  v_attempt integer;
begin
  if p_user_id is null then raise exception 'A user account is required'; end if;
  select code into v_code from public.parcel_pal_codes where user_id=p_user_id;
  if v_code is not null then return v_code; end if;

  for v_attempt in 1..100 loop
    v_candidate := lpad(floor(random()*1000000)::integer::text,6,'0');
    insert into public.parcel_pal_codes(code,user_id)
      values(v_candidate,p_user_id) on conflict do nothing returning code into v_code;
    if v_code is not null then return v_code; end if;
    select code into v_code from public.parcel_pal_codes where user_id=p_user_id;
    if v_code is not null then return v_code; end if;
  end loop;
  raise exception 'Could not allocate a unique Parcel Pal number; try again';
end;
$$;
revoke all on function public.ensure_parcel_pal_code(uuid) from public, anon, authenticated;

create or replace function public.assign_parcel_pal_code_on_signup()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  perform public.ensure_parcel_pal_code(new.id);
  return new;
end;
$$;
revoke all on function public.assign_parcel_pal_code_on_signup() from public, anon, authenticated;
create trigger on_auth_user_parcel_pal_code
  after insert on auth.users
  for each row execute function public.assign_parcel_pal_code_on_signup();

do $$
declare v_user record;
begin
  for v_user in select id from auth.users loop
    perform public.ensure_parcel_pal_code(v_user.id);
  end loop;
end;
$$;

create or replace function public.check_parcel_pal_daily_limit(p_action text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_limit integer;
  v_count integer;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to use Parcel Pals'; end if;
  v_limit := case p_action when 'search' then 60 when 'request' then 20 else null end;
  if v_limit is null then raise invalid_parameter_value using message='Invalid Parcel Pal action'; end if;
  insert into public.parcel_pal_daily_limits as limits(user_id,action,usage_date,use_count)
    values(v_user,p_action,(now() at time zone 'utc')::date,1)
    on conflict(user_id,action) do update
      set use_count=case when limits.usage_date=excluded.usage_date then limits.use_count+1 else 1 end,
          usage_date=excluded.usage_date
    returning use_count into v_count;
  if v_count > v_limit then
    raise sqlstate 'P4290' using message='Daily Parcel Pal limit reached. Try again tomorrow.';
  end if;
end;
$$;
revoke all on function public.check_parcel_pal_daily_limit(text) from public, anon, authenticated;

create or replace function public.get_my_parcel_pal_code()
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
begin
  if auth.uid() is null then raise insufficient_privilege using message='Sign in to view your Parcel Pal number'; end if;
  return public.ensure_parcel_pal_code(auth.uid());
end;
$$;
revoke all on function public.get_my_parcel_pal_code() from public, anon;
grant execute on function public.get_my_parcel_pal_code() to authenticated;

create or replace function public.search_parcel_pals(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_target uuid;
  v_a uuid;
  v_b uuid;
  v_status text;
  v_requester uuid;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to search Parcel Pals'; end if;
  if coalesce(p_code,'') !~ '^[0-9]{6}$' then raise invalid_parameter_value using message='Enter a six-digit Parcel Pal number'; end if;
  perform public.check_parcel_pal_daily_limit('search');
  select c.user_id into v_target
  from public.parcel_pal_codes c join auth.users u on u.id=c.user_id
  where c.code=p_code and c.user_id<>v_user and u.email_confirmed_at is not null;
  if v_target is null then return jsonb_build_object('found',false); end if;
  v_a := least(v_user,v_target); v_b := greatest(v_user,v_target);
  select status,requested_by into v_status,v_requester
    from public.parcel_pal_connections where user_a=v_a and user_b=v_b;
  return jsonb_build_object(
    'found',true,
    'code',p_code,
    'status',coalesce(v_status,'none'),
    'direction',case when v_status is null then null when v_status='accepted' then 'connected'
      when v_requester=v_user then 'sent' else 'received' end
  );
end;
$$;
revoke all on function public.search_parcel_pals(text) from public, anon;
grant execute on function public.search_parcel_pals(text) to authenticated;

create or replace function public.send_parcel_pal_request(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_target uuid;
  v_a uuid;
  v_b uuid;
  v_status text;
  v_requester uuid;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to request a Parcel Pal'; end if;
  if coalesce(p_code,'') !~ '^[0-9]{6}$' then raise invalid_parameter_value using message='Enter a six-digit Parcel Pal number'; end if;
  perform public.check_parcel_pal_daily_limit('request');
  select c.user_id into v_target
  from public.parcel_pal_codes c join auth.users u on u.id=c.user_id
  where c.code=p_code and c.user_id<>v_user and u.email_confirmed_at is not null;
  if v_target is null then return jsonb_build_object('status','not_found'); end if;
  v_a := least(v_user,v_target); v_b := greatest(v_user,v_target);
  insert into public.parcel_pal_connections(user_a,user_b,requested_by,status)
    values(v_a,v_b,v_user,'pending')
    on conflict(user_a,user_b) do update
      set requested_by=excluded.requested_by,status='pending',created_at=now(),updated_at=now(),responded_at=null
      where public.parcel_pal_connections.status in ('declined','cancelled');
  select status,requested_by into v_status,v_requester
    from public.parcel_pal_connections where user_a=v_a and user_b=v_b;
  return jsonb_build_object('status',case when v_status='accepted' then 'accepted'
    when v_status='pending' and v_requester=v_user then 'pending'
    when v_status='pending' then 'incoming_request' else v_status end);
end;
$$;
revoke all on function public.send_parcel_pal_request(text) from public, anon;
grant execute on function public.send_parcel_pal_request(text) to authenticated;

create or replace function public.respond_to_parcel_pal_request(p_code text,p_accept boolean)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_target uuid;
  v_a uuid;
  v_b uuid;
  v_status text;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to respond to a Parcel Pal request'; end if;
  if coalesce(p_code,'') !~ '^[0-9]{6}$' then raise invalid_parameter_value using message='Enter a six-digit Parcel Pal number'; end if;
  select user_id into v_target from public.parcel_pal_codes where code=p_code and user_id<>v_user;
  if v_target is null then raise no_data_found using message='Parcel Pal request not found'; end if;
  v_a := least(v_user,v_target); v_b := greatest(v_user,v_target);
  update public.parcel_pal_connections
    set status=case when p_accept then 'accepted' else 'declined' end,
        updated_at=now(),responded_at=case when p_accept then now() else null end
    where user_a=v_a and user_b=v_b and status='pending' and requested_by<>v_user
    returning status into v_status;
  if v_status is null then raise insufficient_privilege using message='There is no incoming Parcel Pal request to respond to'; end if;
  return v_status;
end;
$$;
revoke all on function public.respond_to_parcel_pal_request(text,boolean) from public, anon;
grant execute on function public.respond_to_parcel_pal_request(text,boolean) to authenticated;

create or replace function public.list_parcel_pal_requests()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare v_user uuid := auth.uid(); v_result jsonb;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to view Parcel Pal requests'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'code',c.code,'status',x.status,
    'direction',case when x.requested_by=v_user then 'sent' else 'received' end,
    'created_at',x.created_at
  ) order by x.created_at desc),'[]'::jsonb) into v_result
  from public.parcel_pal_connections x
  join public.parcel_pal_codes c on c.user_id=case when x.user_a=v_user then x.user_b else x.user_a end
  where v_user in (x.user_a,x.user_b) and x.status='pending';
  return v_result;
end;
$$;
revoke all on function public.list_parcel_pal_requests() from public, anon;
grant execute on function public.list_parcel_pal_requests() to authenticated;

create or replace function public.list_my_parcel_pals()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare v_user uuid := auth.uid(); v_result jsonb;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to view Parcel Pals'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'code',c.code,'full_name',p.full_name,'phone',p.phone,
    'address',addr.address,'city',addr.city,'state',addr.state,
    'connected_at',x.responded_at
  ) order by p.full_name nulls last,c.code),'[]'::jsonb) into v_result
  from public.parcel_pal_connections x
  join public.parcel_pal_codes c on c.user_id=case when x.user_a=v_user then x.user_b else x.user_a end
  left join public.profiles p on p.user_id=c.user_id
  left join lateral (
    select cu.address,cu.city,cu.state from public.customer_users m
    join public.customers cu on cu.id=m.customer_id
    where m.user_id=c.user_id
    order by cu.created_at desc limit 1
  ) addr on true
  where v_user in (x.user_a,x.user_b) and x.status='accepted';
  return v_result;
end;
$$;
revoke all on function public.list_my_parcel_pals() from public, anon;
grant execute on function public.list_my_parcel_pals() to authenticated;
