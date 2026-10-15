-- Let a company manager discard an abandoned upload, while retaining filed evidence.
create policy rider_evidence_cleanup on storage.objects for delete to authenticated using (
  bucket_id='rider-evidence' and owner_id=auth.uid()::text
  and public.company_rider_upload_allowed(name)
  and not exists(select 1 from public.company_riders r
    where name in (r.nin_document_path,r.licence_document_path,r.photo_path))
);
