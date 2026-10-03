-- Private POD object storage with customer read access and delivered-job writes.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proof-of-delivery', 'proof-of-delivery', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set
  name = excluded.name,
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.pod_job_id_from_path(p_name text)
returns uuid
language plpgsql
immutable
set search_path = pg_catalog
as $$
begin
  return split_part(p_name, '/', 1)::uuid;
exception when invalid_text_representation then
  return null;
end;
$$;

create or replace function public.can_read_pod_job(p_job_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.jobs j
    where j.id = p_job_id and (
      public.is_customer_user(j.customer_id)
      or (j.partner_id is not null and public.is_partner_user(j.partner_id))
      or public.has_role(auth.uid(), 'operations')
      or public.has_role(auth.uid(), 'admin')
      or public.has_role(auth.uid(), 'management')
    )
  );
$$;

create or replace function public.can_upload_pod_job(p_job_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.jobs j
    where j.id = p_job_id and j.status = 'delivered' and (
      public.has_role(auth.uid(), 'operations')
      or public.has_role(auth.uid(), 'admin')
      or public.has_role(auth.uid(), 'management')
      or exists (
        select 1 from public.partner_assignments pa
        join public.partner_users pu on pu.partner_id = pa.partner_id
        where pa.job_id = j.id and pa.partner_id = j.partner_id
          and pa.status = 'completed' and pu.user_id = auth.uid()
      )
    )
  );
$$;

create or replace function public.pod_object_exists_for_job(
  p_job_id uuid, p_path text, p_recorded_by uuid, p_content_type text,
  p_file_size_bytes bigint, p_recipient_name text
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, storage
as $$
  select public.can_upload_pod_job(p_job_id)
    and p_recorded_by = auth.uid()
    and p_content_type in ('image/jpeg', 'image/png', 'image/webp')
    and p_file_size_bytes between 1 and 5242880
    and exists (select 1 from public.jobs j where j.id = p_job_id and j.recipient_name = p_recipient_name)
    and p_path like p_job_id::text || '/%'
    and exists (
      select 1 from storage.objects o
      where o.bucket_id = 'proof-of-delivery' and o.name = p_path
        and o.metadata->>'mimetype' = p_content_type
        and case when o.metadata->>'size' ~ '^[0-9]+$' then (o.metadata->>'size')::bigint else null end = p_file_size_bytes
    );
$$;

revoke all on function public.pod_job_id_from_path(text) from public, anon;
grant execute on function public.pod_job_id_from_path(text) to authenticated;
revoke all on function public.can_read_pod_job(uuid) from public, anon;
grant execute on function public.can_read_pod_job(uuid) to authenticated;
revoke all on function public.can_upload_pod_job(uuid) from public, anon;
grant execute on function public.can_upload_pod_job(uuid) to authenticated;
revoke all on function public.pod_object_exists_for_job(uuid, text, uuid, text, bigint, text) from public, anon;
grant execute on function public.pod_object_exists_for_job(uuid, text, uuid, text, bigint, text) to authenticated;

drop policy if exists pod_read_via_job on public.proof_of_delivery;
drop policy if exists pod_add_operations_or_assigned_partner on public.proof_of_delivery;
create policy pod_read_authorized_job on public.proof_of_delivery
  for select to authenticated
  using (public.can_read_pod_job(job_id));
create policy pod_add_after_delivery on public.proof_of_delivery
  for insert to authenticated
  with check (public.pod_object_exists_for_job(job_id, storage_path, recorded_by, content_type, file_size_bytes, recipient_name));

create policy pod_objects_read_with_metadata on storage.objects
  for select to authenticated
  using (
    bucket_id = 'proof-of-delivery'
    and public.can_read_pod_job(public.pod_job_id_from_path(name))
    and exists (
      select 1 from public.proof_of_delivery pod
      where pod.storage_path = name
    )
  );
create policy pod_objects_upload_after_delivery on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'proof-of-delivery'
    and public.can_upload_pod_job(public.pod_job_id_from_path(name))
  );
create policy pod_objects_cleanup_unlinked on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'proof-of-delivery'
    and owner_id = auth.uid()::text
    and not exists (select 1 from public.proof_of_delivery pod where pod.storage_path = name)
  );

comment on function public.can_upload_pod_job(uuid) is 'Allows Gohezoh staff or the completed assigned partner to upload proof after the job is delivered.';
