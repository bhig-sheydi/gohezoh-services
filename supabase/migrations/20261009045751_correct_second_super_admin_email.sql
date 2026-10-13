create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists (
    select 1 from public.user_roles ur
    join auth.users u on u.id=ur.user_id
    where ur.user_id=_user_id and ur.role=_role
      and (_role<>'admin' or lower(u.email) in ('admin@gohezohservices.org','info@gohezohservices.org'))
  );
$$;
