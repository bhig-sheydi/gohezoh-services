-- Vehicle and driver evidence is private to the company applicant and Super Admin.
create table public.partner_application_vehicles (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.staff_applications(id) on delete cascade,
  partner_id uuid references public.logistics_partners(id),
  vehicle_type text not null check(vehicle_type in ('motorcycle','tricycle','car','van','bus','truck')),
  registration_number text not null unique check(registration_number ~ '^[A-Z0-9-]{4,20}$'),
  registered_company_name text not null check(length(btrim(registered_company_name)) between 2 and 200),
  vehicle_document_path text not null unique,
  driver_full_name text not null check(length(btrim(driver_full_name)) between 3 and 200),
  driver_nin text not null check(driver_nin ~ '^[0-9]{11}$'),
  licence_document_path text not null unique,
  opening_time time not null,
  closing_time time not null,
  created_at timestamptz not null default now(),
  check(opening_time <> closing_time),
  check(vehicle_document_path <> licence_document_path)
);
create index partner_application_vehicles_application_idx on public.partner_application_vehicles(application_id);
create index partner_application_vehicles_partner_idx on public.partner_application_vehicles(partner_id) where partner_id is not null;
alter table public.partner_application_vehicles enable row level security;
revoke all on public.partner_application_vehicles from anon,authenticated;
grant select on public.partner_application_vehicles to authenticated;
create policy partner_vehicle_read on public.partner_application_vehicles for select to authenticated using (
  public.has_role(auth.uid(),'admin') or exists(select 1 from public.staff_applications a
    where a.id=application_id and a.user_id=auth.uid() and (a.status='pending' or (a.status='approved' and public.has_role(auth.uid(),'partner'))))
);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('partner-vehicles','partner-vehicles',false,5242880,array['application/pdf','image/jpeg','image/png','image/webp']);
create function public.partner_vehicle_upload_allowed(p_path text) returns boolean
language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists(select 1 from public.staff_applications a join auth.users u on u.id=a.user_id
    where a.user_id=auth.uid() and a.requested_role='partner' and a.status='pending'
      and a.partner_invitation_id is null and a.partner_document_path is not null and u.email_confirmed_at is not null
      and split_part(p_path,'/',1)=a.user_id::text and split_part(p_path,'/',2)=a.id::text
      and split_part(p_path,'/',3)<>'' and split_part(p_path,'/',4)='');
$$;
revoke all on function public.partner_vehicle_upload_allowed(text) from public,anon;
grant execute on function public.partner_vehicle_upload_allowed(text) to authenticated;
create policy partner_vehicle_upload on storage.objects for insert to authenticated
with check(bucket_id='partner-vehicles' and owner_id=auth.uid()::text and public.partner_vehicle_upload_allowed(name));
create policy partner_vehicle_document_read on storage.objects for select to authenticated using (
  bucket_id='partner-vehicles' and exists(select 1 from public.partner_application_vehicles v
    where name in (v.vehicle_document_path,v.licence_document_path))
);
create policy partner_vehicle_cleanup on storage.objects for delete to authenticated using (
  bucket_id='partner-vehicles' and owner_id=auth.uid()::text and public.partner_vehicle_upload_allowed(name)
  and not exists(select 1 from public.partner_application_vehicles v where name in(v.vehicle_document_path,v.licence_document_path))
);

create function public.register_partner_vehicle(p_application_id uuid,p_vehicle_type text,p_registration_number text,
  p_registered_company_name text,p_vehicle_document_path text,p_driver_full_name text,p_driver_nin text,
  p_licence_document_path text,p_opening_time time,p_closing_time time)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,auth,storage as $$
declare a public.staff_applications%rowtype; v_id uuid; v_path text;
begin
  select * into a from public.staff_applications where id=p_application_id for update;
  if not found or a.user_id is distinct from auth.uid() or a.status<>'pending' or a.requested_role<>'partner' or a.partner_invitation_id is not null then
    raise insufficient_privilege using message='A pending company application is required'; end if;
  if a.partner_document_path is null then raise check_violation using message='Upload your company verification document first'; end if;
  if nullif(btrim(p_registered_company_name),'') is null or (nullif(btrim(a.organization_name),'') is not null and lower(btrim(a.organization_name))<>lower(btrim(p_registered_company_name))) then
    raise check_violation using message='The vehicle must be registered in the applying company name'; end if;
  if (select count(*) from public.partner_application_vehicles where application_id=a.id)>=100 then
    raise check_violation using message='Contact Super Admin to register more than 100 vehicles'; end if;
  foreach v_path in array array[p_vehicle_document_path,p_licence_document_path] loop
    if v_path is null or not public.partner_vehicle_upload_allowed(v_path) or not exists(select 1 from storage.objects o
      where o.bucket_id='partner-vehicles' and o.name=v_path and o.owner_id=auth.uid()::text
        and o.metadata->>'mimetype' in ('application/pdf','image/jpeg','image/png','image/webp')
        and case when o.metadata->>'size' ~ '^[0-9]+$' then (o.metadata->>'size')::bigint between 1 and 5242880 else false end) then
      raise check_violation using message='Upload vehicle papers and a driver licence, each under 5 MB'; end if;
  end loop;
  insert into public.partner_application_vehicles(application_id,vehicle_type,registration_number,registered_company_name,
    vehicle_document_path,driver_full_name,driver_nin,licence_document_path,opening_time,closing_time)
  values(a.id,p_vehicle_type,upper(regexp_replace(btrim(p_registration_number),'\s','','g')),btrim(p_registered_company_name),
    p_vehicle_document_path,btrim(p_driver_full_name),btrim(p_driver_nin),p_licence_document_path,p_opening_time,p_closing_time) returning id into v_id;
  update public.staff_applications set organization_name=btrim(p_registered_company_name) where id=a.id and nullif(btrim(organization_name),'') is null;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('partner_vehicle',v_id,'submitted',auth.uid(),array['vehicle_type','registration_number']);
  return v_id;
end $$;
revoke all on function public.register_partner_vehicle(uuid,text,text,text,text,text,text,text,time,time) from public,anon;
grant execute on function public.register_partner_vehicle(uuid,text,text,text,text,text,text,text,time,time) to authenticated;

create function public.remove_pending_partner_vehicle(p_vehicle_id uuid) returns void language plpgsql security definer
set search_path=pg_catalog,public,auth as $$
declare v_application uuid;
begin
  select application_id into v_application from public.partner_application_vehicles where id=p_vehicle_id;
  perform 1 from public.staff_applications where id=v_application and user_id=auth.uid() and status='pending' for update;
  if not found then raise insufficient_privilege using message='Only your pending vehicles can be removed'; end if;
  delete from public.partner_application_vehicles where id=p_vehicle_id;
end $$;
revoke all on function public.remove_pending_partner_vehicle(uuid) from public,anon;
grant execute on function public.remove_pending_partner_vehicle(uuid) to authenticated;

-- Existing approval RPC retains referral attribution and invitation logic. This gate
-- runs inside that transaction, so failed fleet checks roll back role/company grants.
create function public.check_partner_vehicle_on_approval() returns trigger language plpgsql security definer
set search_path=pg_catalog,public,auth,storage as $$
declare v_partner uuid;
begin
  if new.requested_role='partner' and old.status='pending' and new.status='approved' and new.partner_invitation_id is null then
    if not exists(select 1 from public.partner_application_vehicles where application_id=new.id) then
      raise check_violation using message='Register at least one company vehicle before approval'; end if;
    select p.id into v_partner from public.logistics_partners p join public.partner_users pu on pu.partner_id=p.id
      where pu.user_id=new.user_id and p.status='active' and lower(btrim(p.partner_name))=lower(btrim(new.organization_name)) limit 1;
    if v_partner is null then raise check_violation using message='The selected company must match the vehicle registration company'; end if;
    if exists(select 1 from public.partner_application_vehicles v where v.application_id=new.id and (
      lower(btrim(v.registered_company_name))<>lower(btrim(new.organization_name)) or
      not exists(select 1 from storage.objects o where o.bucket_id='partner-vehicles' and o.name=v.vehicle_document_path and o.owner_id=new.user_id::text) or
      not exists(select 1 from storage.objects o where o.bucket_id='partner-vehicles' and o.name=v.licence_document_path and o.owner_id=new.user_id::text))) then
      raise check_violation using message='Check all vehicle ownership and licence documents before approval'; end if;
    update public.partner_application_vehicles set partner_id=v_partner where application_id=new.id;
  end if;
  return new;
end $$;
revoke all on function public.check_partner_vehicle_on_approval() from public,anon,authenticated;
create trigger check_partner_vehicle_on_approval before update of status on public.staff_applications
for each row execute function public.check_partner_vehicle_on_approval();
comment on table public.partner_application_vehicles is 'Private onboarding evidence. Approval is a manual document review, not automated NIMC/FRSC verification. Operating times are Africa/Lagos; closing earlier than opening means next day.';
