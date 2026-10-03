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
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_customer_id uuid;
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
    raise exception 'Business name, contact name, and phone are required';
  end if;

  insert into public.customers (
    company_name, customer_type, contact_person, email, phone,
    address, city, state, status, created_by
  ) values (
    btrim(p_company_name), coalesce(nullif(btrim(p_customer_type), ''), 'individual'),
    btrim(p_contact_person), nullif(btrim(p_email), ''), btrim(p_phone),
    nullif(btrim(p_address), ''), nullif(btrim(p_city), ''), nullif(btrim(p_state), ''),
    'pending', v_user_id
  ) returning id into v_customer_id;

  insert into public.customer_users (customer_id, user_id)
  values (v_customer_id, v_user_id);

  update public.profiles
  set full_name = btrim(p_contact_person), email = nullif(btrim(p_email), ''), phone = btrim(p_phone)
  where user_id = v_user_id;

  return v_customer_id;
end;
$$;

revoke all on function public.register_customer_profile(text, text, text, text, text, text, text, text)
  from public, anon;
grant execute on function public.register_customer_profile(text, text, text, text, text, text, text, text)
  to authenticated;
