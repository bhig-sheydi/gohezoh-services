-- Give each approved BDO a stable referral link and attribute first-time customer onboarding.
-- Attribution is informational until an approved commission policy is implemented.

create table public.bdo_referral_codes (
  id uuid primary key default gen_random_uuid(),
  bdo_user_id uuid not null unique references auth.users(id) on delete cascade,
  code text not null unique check (code ~ '^[A-Z0-9]{8,16}$'),
  created_at timestamptz not null default now()
);

alter table public.customers
  add column referral_code_id uuid references public.bdo_referral_codes(id) on delete set null;
create index customers_assigned_bdo_idx on public.customers(assigned_bdo_id, created_at desc)
  where assigned_bdo_id is not null;

create table public.customer_referral_intents (
  user_id uuid primary key references auth.users(id) on delete cascade,
  referral_code_id uuid references public.bdo_referral_codes(id) on delete set null,
  captured_at timestamptz not null default now()
);

alter table public.bdo_referral_codes enable row level security;
revoke all on public.bdo_referral_codes from public, anon, authenticated;
alter table public.customer_referral_intents enable row level security;
revoke all on public.customer_referral_intents from public, anon, authenticated;

create or replace function public.capture_customer_referral_intent()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_code text;
  v_code_id uuid;
begin
  v_code := upper(nullif(btrim(new.raw_user_meta_data->>'referral_code'), ''));
  if new.raw_user_meta_data->>'account_kind' is distinct from 'staff'
     and v_code ~ '^[A-Z0-9]{8,16}$' then
    select c.id into v_code_id
    from public.bdo_referral_codes c
    where c.code = v_code
      and c.bdo_user_id <> new.id
      and public.has_role(c.bdo_user_id, 'bdo');
  end if;
  -- Capture once at signup, including a null value, so later auth-metadata edits cannot
  -- create or redirect referral attribution.
  insert into public.customer_referral_intents(user_id, referral_code_id)
  values(new.id, v_code_id);
  return new;
end;
$$;
create trigger on_auth_user_referral_captured
after insert on auth.users
for each row execute function public.capture_customer_referral_intent();
revoke all on function public.capture_customer_referral_intent() from public, anon, authenticated;

create or replace function public.get_my_bdo_referral_code()
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_code text;
begin
  if v_user is null or not public.has_role(v_user, 'bdo') then
    raise insufficient_privilege using message = 'An approved BDO account is required';
  end if;

  select code into v_code from public.bdo_referral_codes where bdo_user_id = v_user;
  if v_code is null then
    loop
      v_code := upper(substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 12));
      insert into public.bdo_referral_codes(bdo_user_id, code) values(v_user, v_code)
      on conflict do nothing returning code into v_code;
      if v_code is null then
        select code into v_code from public.bdo_referral_codes where bdo_user_id = v_user;
      end if;
      exit when v_code is not null;
    end loop;
  end if;
  return v_code;
end;
$$;
revoke all on function public.get_my_bdo_referral_code() from public, anon;
grant execute on function public.get_my_bdo_referral_code() to authenticated;

create or replace function public.register_customer_profile(
  p_company_name text,
  p_customer_type text,
  p_contact_person text,
  p_email text,
  p_phone text,
  p_address text default null,
  p_city text default null,
  p_state text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_customer_id uuid;
  v_referral_id uuid;
  v_bdo_id uuid;
begin
  if v_user_id is null then
    raise exception 'Sign in is required to create a customer profile';
  end if;

  if not (
    public.has_role(v_user_id, 'customer')
    or public.has_role(v_user_id, 'operations')
    or public.has_role(v_user_id, 'admin')
    or public.has_role(v_user_id, 'management')
  ) then
    raise exception 'This account cannot create a customer profile';
  end if;

  if nullif(btrim(p_company_name), '') is null
     or nullif(btrim(p_contact_person), '') is null
     or nullif(btrim(p_phone), '') is null then
    raise exception 'Customer name, contact name, and phone are required';
  end if;

  -- A retry must return the existing profile, preserving its original attribution.
  select customer_id into v_customer_id
  from public.customer_users where user_id = v_user_id
  order by created_at limit 1;
  if v_customer_id is not null then return v_customer_id; end if;

  select c.id, c.bdo_user_id into v_referral_id, v_bdo_id
  from public.customer_referral_intents i
  join public.bdo_referral_codes c on c.id = i.referral_code_id
  where i.user_id = v_user_id and public.has_role(c.bdo_user_id, 'bdo');

  insert into public.customers (
    company_name, customer_type, contact_person, email, phone,
    address, city, state, status, created_by, assigned_bdo_id, referral_code_id
  ) values (
    btrim(p_company_name), coalesce(nullif(btrim(p_customer_type), ''), 'individual'),
    btrim(p_contact_person), nullif(btrim(p_email), ''), btrim(p_phone),
    nullif(btrim(p_address), ''), nullif(btrim(p_city), ''), nullif(btrim(p_state), ''),
    'pending', v_user_id, v_bdo_id, v_referral_id
  ) returning id into v_customer_id;

  insert into public.customer_users (customer_id, user_id) values (v_customer_id, v_user_id);

  update public.profiles
  set full_name = btrim(p_contact_person), email = nullif(btrim(p_email), ''), phone = btrim(p_phone)
  where user_id = v_user_id;

  if v_bdo_id is not null then
    insert into public.audit_logs(entity_type, entity_id, action, actor_id, changed_fields)
    values('customer_referral', v_customer_id, 'attributed_on_signup', v_user_id,
      array['assigned_bdo_id', 'referral_code_id']);
  end if;
  return v_customer_id;
end;
$$;
revoke all on function public.register_customer_profile(text, text, text, text, text, text, text, text)
  from public, anon;
grant execute on function public.register_customer_profile(text, text, text, text, text, text, text, text)
  to authenticated;

create or replace function public.ensure_customer_profile()
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_email text;
  v_name text;
  v_phone text;
  v_company text;
begin
  if v_user is null or not public.has_role(v_user, 'customer') then
    raise insufficient_privilege using message = 'Customer access is required';
  end if;
  select email,
    nullif(btrim(raw_user_meta_data->>'full_name'), ''),
    nullif(btrim(raw_user_meta_data->>'phone'), ''),
    nullif(btrim(raw_user_meta_data->>'company_name'), '')
  into v_email, v_name, v_phone, v_company
  from auth.users where id = v_user;
  if v_phone is null then return null; end if;
  v_name := coalesce(v_name, nullif(split_part(coalesce(v_email, ''), '@', 1), ''), 'Customer');
  return public.register_customer_profile(
    coalesce(v_company, v_name), 'individual', v_name, v_email, v_phone, null, null, null
  );
end;
$$;
revoke all on function public.ensure_customer_profile() from public, anon;
grant execute on function public.ensure_customer_profile() to authenticated;

create or replace function public.guard_customer_referral_attribution()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if current_user in ('anon', 'authenticated') then
    if tg_op = 'INSERT' and (new.assigned_bdo_id is not null or new.referral_code_id is not null) then
      if not (public.has_role(auth.uid(), 'management') or public.has_role(auth.uid(), 'admin')) then
        raise insufficient_privilege using message = 'Customer referral attribution is system managed';
      end if;
    elsif tg_op = 'UPDATE' and
      (new.assigned_bdo_id is distinct from old.assigned_bdo_id or new.referral_code_id is distinct from old.referral_code_id) then
      if not (public.has_role(auth.uid(), 'management') or public.has_role(auth.uid(), 'admin')) then
        raise insufficient_privilege using message = 'Customer referral attribution is system managed';
      end if;
    end if;
  end if;
  return new;
end;
$$;
create trigger customers_guard_referral_attribution
before insert or update of assigned_bdo_id, referral_code_id on public.customers
for each row execute function public.guard_customer_referral_attribution();
revoke all on function public.guard_customer_referral_attribution() from public, anon, authenticated;
