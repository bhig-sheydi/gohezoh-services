-- One driver roster per company. Keep the identity and evidence after access is revoked.
create table public.company_riders (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.logistics_partners(id),
  full_name text not null check(length(btrim(full_name)) between 3 and 120),
  nin text not null check(nin ~ '^[0-9]{11}$'),
  nin_document_path text,
  licence_document_path text not null,
  photo_path text,
  source_vehicle_id uuid references public.partner_application_vehicles(id),
  status text not null default 'pending' check(status in ('pending','approved','rejected','archived')),
  rejection_reason text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  archived_at timestamptz,
  unique(partner_id,nin)
);
create unique index company_riders_source_vehicle_unique on public.company_riders(source_vehicle_id) where source_vehicle_id is not null;
create index company_riders_partner_status on public.company_riders(partner_id,status);
alter table public.company_riders enable row level security;
revoke all on public.company_riders from anon,authenticated;
grant select on public.company_riders to authenticated;
create policy company_rider_read on public.company_riders for select to authenticated using (
  public.has_role(auth.uid(),'admin') or exists(select 1 from public.partner_users pu
    where pu.partner_id=company_riders.partner_id and pu.user_id=auth.uid() and pu.membership_role='manager')
);

-- The earlier company approval included these licence files and NIN numbers.
insert into public.company_riders(partner_id,full_name,nin,licence_document_path,source_vehicle_id,status,reviewed_at)
select distinct on (v.partner_id,v.driver_nin) v.partner_id,v.driver_full_name,v.driver_nin,v.licence_document_path,v.id,'approved',now()
from public.partner_application_vehicles v
join public.staff_applications a on a.id=v.application_id and a.status='approved'
where v.partner_id is not null
order by v.partner_id,v.driver_nin,v.created_at;

create function public.sync_approved_vehicle_driver() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.partner_id is not null and old.partner_id is distinct from new.partner_id then
    insert into public.company_riders(partner_id,full_name,nin,licence_document_path,source_vehicle_id,status,reviewed_at)
    values(new.partner_id,new.driver_full_name,new.driver_nin,new.licence_document_path,new.id,'approved',now())
    on conflict (partner_id,nin) do nothing;
  end if;
  return new;
end $$;
create trigger partner_vehicle_driver_roster after update of partner_id on public.partner_application_vehicles
for each row execute function public.sync_approved_vehicle_driver();

alter table public.rider_credentials add column roster_id uuid unique references public.company_riders(id),
  add column device_label text,
  add column device_mismatch_attempts integer not null default 0,
  add column password_revoked_at timestamptz;

create or replace function public.rider_session_active()
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select public.has_role(auth.uid(),'rider')
    and exists(select 1 from public.rider_credentials c join public.company_riders r on r.id=c.roster_id
      where c.user_id=auth.uid() and c.revoked_at is null and c.password_revoked_at is null and r.status='approved')
    and exists(select 1 from auth.sessions s where s.user_id=auth.uid()
      and s.id=(auth.jwt()->>'session_id')::uuid);
$$;
create or replace function public.rider_actor_session_active(p_user_id uuid,p_session_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists(select 1 from auth.sessions s where s.id=p_session_id and s.user_id=p_user_id)
    and exists(select 1 from public.rider_credentials c join public.company_riders r on r.id=c.roster_id
      where c.user_id=p_user_id and c.revoked_at is null and c.password_revoked_at is null and r.status='approved');
$$;

-- Existing rider accounts created before this roster must be reviewed and linked manually.
-- They cannot receive jobs while they lack a verified roster entry.
create or replace function public.company_rider_upload_allowed(p_path text) returns boolean
language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists(select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
    where pu.user_id=auth.uid() and pu.membership_role='manager' and p.status='active'
    and split_part(p_path,'/',1)=pu.partner_id::text
    and split_part(p_path,'/',2)=auth.uid()::text
    and split_part(p_path,'/',3)<>'' and split_part(p_path,'/',4)='');
$$;
revoke all on function public.company_rider_upload_allowed(text) from public,anon;
grant execute on function public.company_rider_upload_allowed(text) to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('rider-evidence','rider-evidence',false,5242880,array['application/pdf','image/jpeg','image/png','image/webp']);
create policy rider_evidence_upload on storage.objects for insert to authenticated
with check(bucket_id='rider-evidence' and owner_id=auth.uid()::text and public.company_rider_upload_allowed(name));
create policy rider_evidence_read on storage.objects for select to authenticated using (
  bucket_id='rider-evidence' and exists(select 1 from public.company_riders r
    where name in (r.nin_document_path,r.licence_document_path,r.photo_path)
    and (public.has_role(auth.uid(),'admin') or exists(select 1 from public.partner_users pu
      where pu.partner_id=r.partner_id and pu.user_id=auth.uid() and pu.membership_role='manager')))
);


-- An archived or unapproved rider cannot be assigned even if a stale membership survives.
create or replace function public.guard_company_rider_assignment() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.assigned_rider_id is not null and (tg_op='INSERT' or new.assigned_rider_id is distinct from old.assigned_rider_id)
    and not exists(select 1 from public.rider_credentials c join public.company_riders r on r.id=c.roster_id
      where c.user_id=new.assigned_rider_id and c.partner_id=new.partner_id
      and c.revoked_at is null and c.password_revoked_at is null and r.status='approved') then
    raise check_violation using message='Choose an approved active rider';
  end if;
  return new;
end $$;
create trigger jobs_guard_company_rider_assignment before insert or update of assigned_rider_id on public.jobs
for each row execute function public.guard_company_rider_assignment();

create function public.register_company_rider(p_partner_id uuid,p_full_name text,p_nin text,
  p_nin_document_path text,p_licence_document_path text,p_photo_path text default null)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,auth,storage as $$
declare v_path text; v_id uuid;
begin
  if not exists(select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
    where pu.partner_id=p_partner_id and pu.user_id=auth.uid() and pu.membership_role='manager' and p.status='active') then
    raise insufficient_privilege using message='Company manager access required'; end if;
  if length(btrim(p_full_name)) not between 3 and 120 or p_nin !~ '^[0-9]{11}$' then
    raise check_violation using message='Enter a full name and an 11-digit NIN'; end if;
  foreach v_path in array array[p_nin_document_path,p_licence_document_path,p_photo_path] loop
    if v_path is not null and (not public.company_rider_upload_allowed(v_path) or not exists(
      select 1 from storage.objects o where o.bucket_id='rider-evidence' and o.name=v_path
        and o.owner_id=auth.uid()::text
        and o.metadata->>'mimetype' in ('application/pdf','image/jpeg','image/png','image/webp')
        and case when o.metadata->>'size' ~ '^[0-9]+$' then (o.metadata->>'size')::bigint between 1 and 5242880 else false end)) then
      raise check_violation using message='Upload valid rider documents under 5 MB'; end if;
  end loop;
  if p_nin_document_path is null or p_licence_document_path is null or p_nin_document_path=p_licence_document_path then
    raise check_violation using message='NIN and licence documents are required'; end if;
  insert into public.company_riders(partner_id,full_name,nin,nin_document_path,licence_document_path,photo_path)
  values(p_partner_id,btrim(p_full_name),p_nin,p_nin_document_path,p_licence_document_path,p_photo_path)
  returning id into v_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
  values('company_rider',v_id,'submitted',auth.uid(),array['nin_document_path','licence_document_path']);
  return v_id;
end $$;
revoke all on function public.register_company_rider(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.register_company_rider(uuid,text,text,text,text,text) to authenticated;

create function public.review_company_rider(p_rider_id uuid,p_approve boolean,p_reason text default null)
returns void language plpgsql security definer set search_path=pg_catalog,public,auth as $$
begin
  if not public.has_role(auth.uid(),'admin') then raise insufficient_privilege using message='Super Admin access required'; end if;
  if not p_approve and length(btrim(coalesce(p_reason,'')))<3 then
    raise check_violation using message='A rejection reason is required'; end if;
  update public.company_riders set status=case when p_approve then 'approved' else 'rejected' end,
    rejection_reason=case when p_approve then null else btrim(p_reason) end,reviewed_at=now()
  where id=p_rider_id and status='pending';
  if not found then raise no_data_found using message='Pending rider not found'; end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
  values('company_rider',p_rider_id,case when p_approve then 'approved' else 'rejected' end,auth.uid(),array['status']);
end $$;
revoke all on function public.review_company_rider(uuid,boolean,text) from public,anon;
grant execute on function public.review_company_rider(uuid,boolean,text) to authenticated;

create function public.archive_company_rider(p_rider_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_partner uuid;
begin
  select partner_id into v_partner from public.company_riders where id=p_rider_id for update;
  if v_partner is null or not exists(select 1 from public.partner_users
    where partner_id=v_partner and user_id=auth.uid() and membership_role='manager') then
    raise insufficient_privilege using message='Company manager access required'; end if;
  update public.company_riders set status='archived',archived_at=now() where id=p_rider_id and status<>'archived';
  update public.rider_credentials set revoked_at=now(),challenge=null,challenge_expires_at=null
    where roster_id=p_rider_id and revoked_at is null;
  delete from public.partner_users where partner_id=v_partner and user_id in
    (select user_id from public.rider_credentials where roster_id=p_rider_id);
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
  values('company_rider',p_rider_id,'archived',auth.uid(),array['status','revoked_at']);
end $$;
revoke all on function public.archive_company_rider(uuid) from public,anon;
grant execute on function public.archive_company_rider(uuid) to authenticated;

create function public.record_rider_device_mismatch(p_user_id uuid) returns integer
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_count integer;
begin
  update public.rider_credentials set device_mismatch_attempts=device_mismatch_attempts+1,
    password_revoked_at=case when device_mismatch_attempts+1>3 then now() else password_revoked_at end
  where user_id=p_user_id and revoked_at is null and password_revoked_at is null
  returning device_mismatch_attempts into v_count;
  return coalesce(v_count,4);
end $$;
revoke all on function public.record_rider_device_mismatch(uuid) from public,anon,authenticated;
grant execute on function public.record_rider_device_mismatch(uuid) to service_role;

create function public.set_company_rider_photo(p_rider_id uuid,p_photo_path text)
returns void language plpgsql security definer set search_path=pg_catalog,public,auth,storage as $$
declare v_partner uuid;
begin
  select partner_id into v_partner from public.company_riders where id=p_rider_id;
  if v_partner is null or not exists(select 1 from public.partner_users where partner_id=v_partner
    and user_id=auth.uid() and membership_role='manager') then
    raise insufficient_privilege using message='Company manager access required'; end if;
  if not public.company_rider_upload_allowed(p_photo_path) or not exists(select 1 from storage.objects o
    where o.bucket_id='rider-evidence' and o.name=p_photo_path and o.owner_id=auth.uid()::text
    and o.metadata->>'mimetype' in ('image/jpeg','image/png','image/webp')) then
    raise check_violation using message='Upload a valid rider photo first'; end if;
  update public.company_riders set photo_path=p_photo_path where id=p_rider_id and status<>'archived';
end $$;
revoke all on function public.set_company_rider_photo(uuid,text) from public,anon;
grant execute on function public.set_company_rider_photo(uuid,text) to authenticated;
