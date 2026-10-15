alter table public.staff_applications add column rejection_reason text
  check(rejection_reason is null or length(btrim(rejection_reason)) between 3 and 2000);

-- Keep the existing invitation, referral, role and fleet checks in one place.
alter function public.review_staff_application(uuid,boolean,uuid) rename to review_staff_application_internal;
revoke all on function public.review_staff_application_internal(uuid,boolean,uuid) from public,anon,authenticated;

create function public.review_staff_application(p_application_id uuid,p_approve boolean,p_partner_id uuid default null,p_rejection_reason text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare a public.staff_applications%rowtype; company_id uuid:=p_partner_id; result jsonb;
begin
  if not public.has_role(auth.uid(),'admin') then raise insufficient_privilege using message='Super Admin access is required'; end if;
  if p_approve is null then raise check_violation using message='Choose approve or reject'; end if;
  select * into a from public.staff_applications where id=p_application_id for update;
  if not found or a.status<>'pending' then raise check_violation using message='A pending application is required'; end if;
  if not p_approve and (p_rejection_reason is null or length(btrim(p_rejection_reason)) not between 3 and 2000) then
    raise check_violation using message='Enter a rejection reason (3 to 2000 characters)'; end if;
  if p_approve and a.requested_role='partner' and a.partner_invitation_id is null and a.partner_prospect_id is null and company_id is null then
    if nullif(btrim(a.organization_name),'') is null then raise check_violation using message='The company name is missing from this application'; end if;
    -- Do not join an unrelated company just because an applicant reused its name.
    insert into public.logistics_partners(partner_name,contact_person,phone,email,partner_type,status)
    select btrim(a.organization_name),coalesce(nullif(p.full_name,''),u.email),coalesce(p.phone,u.phone,''),u.email,'logistics','active'
    from auth.users u left join public.profiles p on p.user_id=u.id where u.id=a.user_id returning id into company_id;
  end if;
  update public.staff_applications set rejection_reason=case when p_approve then null else btrim(p_rejection_reason) end where id=a.id;
  result:=public.review_staff_application_internal(a.id,p_approve,company_id);
  if not p_approve then
    insert into public.notifications(user_id,event_type,channel,title,body,payload,status,sent_at)
    values(a.user_id,'application_rejected','in_app','Application needs changes',btrim(p_rejection_reason),
      jsonb_build_object('application_id',a.id,'requested_role',a.requested_role),'delivered',now());
  end if;
  return result || jsonb_build_object('rejection_reason',case when p_approve then null else btrim(p_rejection_reason) end);
end $$;
revoke all on function public.review_staff_application(uuid,boolean,uuid,text) from public,anon;
grant execute on function public.review_staff_application(uuid,boolean,uuid,text) to authenticated;

create function public.enforce_application_rejection_reason() returns trigger language plpgsql
set search_path=pg_catalog,public as $$
begin
  if old.status is distinct from new.status and new.status='rejected' and nullif(btrim(new.rejection_reason),'') is null then
    raise check_violation using message='A rejection reason is required';
  end if;
  if old.status is distinct from new.status and new.status='pending' then new.rejection_reason:=null; end if;
  return new;
end $$;
revoke all on function public.enforce_application_rejection_reason() from public,anon,authenticated;
create trigger enforce_application_rejection_reason before update of status on public.staff_applications
for each row execute function public.enforce_application_rejection_reason();
