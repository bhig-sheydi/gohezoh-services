-- Public signup requests access; only the two named super admins may grant it.
create table public.staff_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  requested_role public.app_role not null check (requested_role in ('operations','finance','bdo','warehouse','partner','management')),
  organization_name text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, requested_role)
);
create index staff_applications_status_created_idx on public.staff_applications(status,created_at desc);

create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists (
    select 1 from public.user_roles ur
    join auth.users u on u.id=ur.user_id
    where ur.user_id=_user_id and ur.role=_role
      and (_role<>'admin' or lower(u.email) in ('admin@gohezohservices.org','info@gohezoservices.org'))
  );
$$;

create or replace function public.is_partner_user(_partner_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select public.has_role(auth.uid(),'partner') and exists (
    select 1 from public.partner_users pu where pu.partner_id=_partner_id and pu.user_id=auth.uid()
  );
$$;

drop policy user_roles_manage on public.user_roles;
create policy user_roles_manage on public.user_roles for all to authenticated
  using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));
drop policy partner_users_manage on public.partner_users;
create policy partner_users_manage on public.partner_users for all to authenticated
  using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));

alter table public.staff_applications enable row level security;
grant select on public.staff_applications to authenticated;
create policy staff_applications_read on public.staff_applications for select to authenticated
  using (user_id=auth.uid() or public.has_role(auth.uid(),'admin'));

create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_role text;
begin
  insert into public.profiles(user_id,full_name,email,phone)
  values(new.id,nullif(new.raw_user_meta_data->>'full_name',''),new.email,new.phone)
  on conflict(user_id) do nothing;

  if new.raw_user_meta_data->>'account_kind'='staff' then
    v_role:=new.raw_user_meta_data->>'requested_role';
    if v_role not in ('operations','finance','bdo','warehouse','partner','management') then
      raise check_violation using message='Choose a valid staff category';
    end if;
    insert into public.staff_applications(user_id,requested_role,organization_name)
    values(new.id,v_role::public.app_role,nullif(btrim(new.raw_user_meta_data->>'organization_name'),''));
  else
    insert into public.user_roles(user_id,role) values(new.id,'customer') on conflict do nothing;
  end if;
  return new;
end $$;

-- An existing verified customer may apply without creating a second auth account.
create or replace function public.request_staff_access(p_role public.app_role,p_organization_name text default null)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_user uuid:=auth.uid();v_id uuid;
begin
  if v_user is null or not exists(select 1 from auth.users where id=v_user and email_confirmed_at is not null) then
    raise insufficient_privilege using message='Confirm your email before requesting staff access';
  end if;
  if p_role not in ('operations','finance','bdo','warehouse','partner','management') then
    raise check_violation using message='Choose a valid staff category';
  end if;
  insert into public.staff_applications(user_id,requested_role,organization_name)
  values(v_user,p_role,nullif(btrim(p_organization_name),''))
  on conflict(user_id,requested_role) do update
    set organization_name=excluded.organization_name,status='pending',reviewed_by=null,reviewed_at=null
  where staff_applications.status='rejected'
  returning id into v_id;
  if v_id is null then raise unique_violation using message='This staff request already exists';end if;
  return v_id;
end $$;
revoke all on function public.request_staff_access(public.app_role,text) from public,anon,authenticated;
grant execute on function public.request_staff_access(public.app_role,text) to authenticated;

create or replace function public.review_staff_application(p_application_id uuid,p_approve boolean,p_partner_id uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_admin uuid:=auth.uid();v_request public.staff_applications%rowtype;v_email text;
begin
  if not public.has_role(v_admin,'admin') then raise insufficient_privilege using message='Super Admin access is required';end if;
  select * into v_request from public.staff_applications where id=p_application_id for update;
  if not found then raise no_data_found using message='Staff request was not found';end if;
  if v_request.status<>'pending' then raise object_not_in_prerequisite_state using message='This request has already been reviewed';end if;
  select email into v_email from auth.users where id=v_request.user_id and email_confirmed_at is not null;
  if p_approve and v_email is null then raise object_not_in_prerequisite_state using message='Applicant must confirm their email first';end if;
  if p_approve and v_request.requested_role='partner' then
    if p_partner_id is null or not exists(select 1 from public.logistics_partners where id=p_partner_id and status='active') then
      raise check_violation using message='Choose an active logistics partner';
    end if;
    insert into public.partner_users(partner_id,user_id) values(p_partner_id,v_request.user_id) on conflict do nothing;
  elsif p_partner_id is not null then
    raise check_violation using message='A partner can only be selected for Partner access';
  end if;
  if p_approve then
    insert into public.user_roles(user_id,role) values(v_request.user_id,v_request.requested_role) on conflict do nothing;
  end if;
  update public.staff_applications set status=case when p_approve then 'approved' else 'rejected' end,
    reviewed_by=v_admin,reviewed_at=now() where id=v_request.id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
  values('staff_application',v_request.id,case when p_approve then 'approved' else 'rejected' end,v_admin,array['status','requested_role']);
  return jsonb_build_object('user_id',v_request.user_id,'role',v_request.requested_role,'status',case when p_approve then 'approved' else 'rejected' end);
end $$;
revoke all on function public.review_staff_application(uuid,boolean,uuid) from public,anon,authenticated;
grant execute on function public.review_staff_application(uuid,boolean,uuid) to authenticated;

create or replace function public.revoke_staff_access(p_user_id uuid,p_role public.app_role)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_admin uuid:=auth.uid();
begin
  if not public.has_role(v_admin,'admin') then raise insufficient_privilege using message='Super Admin access is required';end if;
  if p_role in ('admin','customer') then raise check_violation using message='Use the dedicated account process for this role';end if;
  delete from public.user_roles where user_id=p_user_id and role=p_role;
  if not found then raise no_data_found using message='This user does not have that role';end if;
  if p_role='partner' then delete from public.partner_users where user_id=p_user_id;end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
  values('user_role',p_user_id,'revoked',v_admin,array[p_role::text]);
end $$;
revoke all on function public.revoke_staff_access(uuid,public.app_role) from public,anon,authenticated;
grant execute on function public.revoke_staff_access(uuid,public.app_role) to authenticated;

create or replace function public.list_staff_access()
returns table(user_id uuid,email text,full_name text,role public.app_role,organization_name text)
language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select ur.user_id,u.email,p.full_name,ur.role,
    (select sa.organization_name from public.staff_applications sa where sa.user_id=ur.user_id and sa.requested_role=ur.role limit 1)
  from public.user_roles ur join auth.users u on u.id=ur.user_id
  left join public.profiles p on p.user_id=ur.user_id
  where public.has_role(auth.uid(),'admin') and ur.role not in ('customer','admin')
  order by u.email,ur.role;
$$;
revoke all on function public.list_staff_access() from public,anon,authenticated;
grant execute on function public.list_staff_access() to authenticated;

create or replace function public.list_staff_applications()
returns table(id uuid,user_id uuid,email text,full_name text,requested_role public.app_role,
  organization_name text,status text,email_confirmed boolean,created_at timestamptz)
language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select sa.id,sa.user_id,u.email,p.full_name,sa.requested_role,sa.organization_name,
    sa.status,u.email_confirmed_at is not null,sa.created_at
  from public.staff_applications sa join auth.users u on u.id=sa.user_id
  left join public.profiles p on p.user_id=sa.user_id
  where public.has_role(auth.uid(),'admin')
  order by (sa.status='pending') desc,sa.created_at desc;
$$;
revoke all on function public.list_staff_applications() from public,anon,authenticated;
grant execute on function public.list_staff_applications() to authenticated;

-- Operations may create a partner company, but linking a portal user now requires Super Admin review.
create or replace function public.create_logistics_partner(
  p_partner_name text,p_contact_person text,p_phone text,p_email text default null,
  p_base_city text default null,p_base_state text default null,p_service_areas text[] default '{}',
  p_portal_user_email text default null
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_partner public.logistics_partners%rowtype;
begin
  if v_actor is null or not(public.has_role(v_actor,'operations') or public.has_role(v_actor,'admin') or public.has_role(v_actor,'management')) then
    raise insufficient_privilege using message='Only Operations can add logistics partners';
  end if;
  if nullif(btrim(p_portal_user_email),'') is not null then
    raise insufficient_privilege using message='Partner portal access requires Super Admin approval';
  end if;
  if nullif(btrim(p_partner_name),'') is null or nullif(btrim(p_contact_person),'') is null or nullif(btrim(p_phone),'') is null then
    raise invalid_parameter_value using message='Partner name, contact person, and phone are required';
  end if;
  insert into public.logistics_partners(partner_name,contact_person,phone,email,base_city,base_state,service_areas,status)
  values(btrim(p_partner_name),btrim(p_contact_person),btrim(p_phone),nullif(btrim(p_email),''),nullif(btrim(p_base_city),''),nullif(btrim(p_base_state),''),coalesce(p_service_areas,'{}'),'active')
  returning * into v_partner;
  return jsonb_build_object('partner_id',v_partner.id,'partner_number',v_partner.partner_number,'partner_name',v_partner.partner_name);
end $$;
