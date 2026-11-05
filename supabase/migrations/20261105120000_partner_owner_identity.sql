alter table public.staff_applications
  add column if not exists owner_nin text check (owner_nin ~ '^[0-9]{11}$'),
  add column if not exists owner_selfie_path text,
  add column if not exists owner_identity_submitted_at timestamptz;

create unique index if not exists staff_applications_owner_selfie_path_key
  on public.staff_applications(owner_selfie_path) where owner_selfie_path is not null;

drop policy if exists partner_owner_selfie_read on storage.objects;
create policy partner_owner_selfie_read on storage.objects for select to authenticated
using (bucket_id='partner-verification' and exists (
  select 1 from public.staff_applications a where a.owner_selfie_path=name
    and (a.user_id=auth.uid() or public.has_role(auth.uid(),'admin'))
));

drop policy if exists partner_verification_cleanup on storage.objects;
create policy partner_verification_cleanup on storage.objects for delete to authenticated
using (bucket_id='partner-verification' and owner_id=auth.uid()::text
  and public.partner_document_upload_allowed(name)
  and not exists(select 1 from public.staff_applications a
    where name in (a.partner_document_path,a.owner_selfie_path)));

create or replace function public.submit_partner_owner_identity(
  p_application_id uuid,p_nin text,p_selfie_path text)
returns void language plpgsql security definer set search_path=pg_catalog,public,auth,storage as $$
declare a public.staff_applications%rowtype;
begin
  select * into a from public.staff_applications where id=p_application_id for update;
  if not found or a.user_id is distinct from auth.uid() or a.requested_role<>'partner'
    or a.status<>'pending' or a.partner_invitation_id is not null then
    raise insufficient_privilege using message='A pending company-owner application is required';
  end if;
  if p_nin is null or p_nin !~ '^[0-9]{11}$' then
    raise check_violation using message='Enter the owner NIN as 11 digits';
  end if;
  if not public.partner_document_upload_allowed(p_selfie_path) or not exists (
    select 1 from storage.objects o where o.bucket_id='partner-verification'
      and o.name=p_selfie_path and o.owner_id=auth.uid()::text
      and o.metadata->>'mimetype'='image/jpeg'
      and case when o.metadata->>'size' ~ '^[0-9]+$'
        then (o.metadata->>'size')::bigint between 1 and 5242880 else false end
  ) then raise check_violation using message='Capture a valid owner face photo'; end if;
  update public.staff_applications set owner_nin=p_nin,owner_selfie_path=p_selfie_path,
    owner_identity_submitted_at=now() where id=p_application_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('staff_application',p_application_id,'owner_identity_submitted',auth.uid(),
      array['owner_nin','owner_selfie_path']);
end $$;
revoke all on function public.submit_partner_owner_identity(uuid,text,text) from public,anon,authenticated;
grant execute on function public.submit_partner_owner_identity(uuid,text,text) to authenticated;

create or replace function public.require_partner_owner_identity_before_approval()
returns trigger language plpgsql set search_path=pg_catalog,public,storage as $$
begin
  if new.status='approved' and old.status is distinct from new.status
    and new.requested_role='partner' and new.partner_invitation_id is null then
    if new.owner_nin is null or new.owner_selfie_path is null or not exists (
      select 1 from storage.objects o where o.bucket_id='partner-verification'
        and o.name=new.owner_selfie_path and o.owner_id=new.user_id::text
    ) then raise check_violation using message='Company owner NIN and live face photo are required'; end if;
  end if;
  return new;
end $$;
revoke all on function public.require_partner_owner_identity_before_approval() from public,anon,authenticated;
drop trigger if exists require_partner_owner_identity_before_approval on public.staff_applications;
create trigger require_partner_owner_identity_before_approval before update of status
on public.staff_applications for each row execute function public.require_partner_owner_identity_before_approval();
