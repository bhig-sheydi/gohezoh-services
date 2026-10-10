alter table public.staff_applications
  add column partner_document_type text check (partner_document_type in ('nin','cac')),
  add column partner_document_path text,
  add column partner_document_submitted_at timestamptz;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('partner-verification','partner-verification',false,5242880,array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create or replace function public.partner_document_upload_allowed(p_path text)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select auth.uid() is not null and exists (
    select 1 from public.staff_applications sa join auth.users u on u.id=sa.user_id
    where sa.user_id=auth.uid() and sa.requested_role='partner' and sa.status='pending'
      and u.email_confirmed_at is not null
      and p_path like sa.user_id::text || '/' || sa.id::text || '/%'
      and split_part(p_path,'/',4)=''
  );
$$;
revoke all on function public.partner_document_upload_allowed(text) from public,anon;
grant execute on function public.partner_document_upload_allowed(text) to authenticated;

create policy partner_verification_upload on storage.objects for insert to authenticated
with check(bucket_id='partner-verification' and owner_id=auth.uid()::text
  and public.partner_document_upload_allowed(name));
create policy partner_verification_read on storage.objects for select to authenticated
using(bucket_id='partner-verification' and exists (
  select 1 from public.staff_applications sa
  where sa.partner_document_path=name and
    (sa.user_id=auth.uid() or public.has_role(auth.uid(),'admin'))
));
create policy partner_verification_cleanup on storage.objects for delete to authenticated
using(bucket_id='partner-verification' and owner_id=auth.uid()::text
  and public.partner_document_upload_allowed(name)
  and not exists(select 1 from public.staff_applications sa where sa.partner_document_path=name));

create or replace function public.submit_partner_document(p_application_id uuid,p_document_type text,p_storage_path text)
returns void language plpgsql security definer set search_path=pg_catalog,public,auth,storage as $$
declare v_application public.staff_applications%rowtype;
begin
  select * into v_application from public.staff_applications where id=p_application_id for update;
  if not found or v_application.user_id is distinct from auth.uid() or v_application.requested_role<>'partner' or v_application.status<>'pending' then
    raise insufficient_privilege using message='A pending Partner application is required';
  end if;
  if not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then
    raise insufficient_privilege using message='Confirm your email before submitting a document';
  end if;
  if p_document_type not in ('nin','cac') or p_document_type is null then
    raise check_violation using message='Select NIN or CAC';
  end if;
  if not public.partner_document_upload_allowed(p_storage_path) or not exists(
    select 1 from storage.objects o where o.bucket_id='partner-verification' and o.name=p_storage_path
      and o.owner_id=auth.uid()::text
      and o.metadata->>'mimetype' in ('application/pdf','image/jpeg','image/png','image/webp')
      and case when o.metadata->>'size' ~ '^[0-9]+$' then (o.metadata->>'size')::bigint between 1 and 5242880 else false end
  ) then raise check_violation using message='Upload a valid PDF or image (5 MB maximum)';end if;
  update public.staff_applications set partner_document_type=p_document_type,
    partner_document_path=p_storage_path,partner_document_submitted_at=now() where id=p_application_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('staff_application',p_application_id,'partner_document_submitted',auth.uid(),array['partner_document_type','partner_document_path']);
end $$;
revoke all on function public.submit_partner_document(uuid,text,text) from public,anon,authenticated;
grant execute on function public.submit_partner_document(uuid,text,text) to authenticated;

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
    set organization_name=excluded.organization_name,status='pending',reviewed_by=null,reviewed_at=null,
      partner_document_type=null,partner_document_path=null,partner_document_submitted_at=null
  where staff_applications.status in ('rejected','revoked')
  returning id into v_id;
  if v_id is null then raise unique_violation using message='This staff request already exists';end if;
  return v_id;
end $$;

create or replace function public.review_staff_application(p_application_id uuid,p_approve boolean,p_partner_id uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,storage as $$
declare v_admin uuid:=auth.uid();v_request public.staff_applications%rowtype;v_email text;
begin
  if not public.has_role(v_admin,'admin') then raise insufficient_privilege using message='Super Admin access is required';end if;
  select * into v_request from public.staff_applications where id=p_application_id for update;
  if not found then raise no_data_found using message='Staff request was not found';end if;
  if v_request.status<>'pending' then raise object_not_in_prerequisite_state using message='This request has already been reviewed';end if;
  select email into v_email from auth.users where id=v_request.user_id and email_confirmed_at is not null;
  if p_approve and v_email is null then raise object_not_in_prerequisite_state using message='Applicant must confirm their email first';end if;
  if p_approve and v_request.requested_role='partner' then
    if v_request.partner_document_type is null or v_request.partner_document_path is null or not exists(
      select 1 from storage.objects o where o.bucket_id='partner-verification'
        and o.name=v_request.partner_document_path and o.owner_id=v_request.user_id::text
    ) then raise check_violation using message='Partner must submit a NIN or CAC document before approval';end if;
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
