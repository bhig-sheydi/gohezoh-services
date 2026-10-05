alter table public.staff_applications drop constraint staff_applications_status_check;
alter table public.staff_applications add constraint staff_applications_status_check
  check(status in ('pending','approved','rejected','revoked'));

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
  where staff_applications.status in ('rejected','revoked')
  returning id into v_id;
  if v_id is null then raise unique_violation using message='This staff request already exists';end if;
  return v_id;
end $$;

create or replace function public.revoke_staff_access(p_user_id uuid,p_role public.app_role)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_admin uuid:=auth.uid();
begin
  if not public.has_role(v_admin,'admin') then raise insufficient_privilege using message='Super Admin access is required';end if;
  if p_role in ('admin','customer') then raise check_violation using message='Use the dedicated account process for this role';end if;
  delete from public.user_roles where user_id=p_user_id and role=p_role;
  if not found then raise no_data_found using message='This user does not have that role';end if;
  if p_role='partner' then delete from public.partner_users where user_id=p_user_id;end if;
  update public.staff_applications set status='revoked',reviewed_by=v_admin,reviewed_at=now()
    where user_id=p_user_id and requested_role=p_role and status='approved';
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
  values('user_role',p_user_id,'revoked',v_admin,array[p_role::text]);
end $$;
