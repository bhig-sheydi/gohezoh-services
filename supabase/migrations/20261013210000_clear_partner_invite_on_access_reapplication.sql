-- A revoked/rejected partner must receive a fresh organization invitation for
-- any later approval; do not reuse an already accepted invitation.
create or replace function public.request_staff_access(p_role public.app_role,p_organization_name text default null)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_user uuid:=auth.uid();v_id uuid;
begin
  if v_user is null or not exists(select 1 from auth.users where id=v_user and email_confirmed_at is not null) then
    raise insufficient_privilege using message='Confirm your email before requesting staff access';end if;
  if p_role not in ('operations','finance','bdo','warehouse','partner','management') then
    raise check_violation using message='Choose a valid staff category';end if;
  insert into public.staff_applications(user_id,requested_role,organization_name)
    values(v_user,p_role,nullif(btrim(p_organization_name),''))
    on conflict(user_id,requested_role) do update set organization_name=excluded.organization_name,status='pending',
      reviewed_by=null,reviewed_at=null,partner_document_type=null,partner_document_path=null,
      partner_document_submitted_at=null,partner_invitation_id=null
      where staff_applications.status in ('rejected','revoked')
    returning id into v_id;
  if v_id is null then raise unique_violation using message='This staff request already exists';end if;
  return v_id;
end $$;
revoke all on function public.request_staff_access(public.app_role,text) from public,anon,authenticated;
grant execute on function public.request_staff_access(public.app_role,text) to authenticated;
