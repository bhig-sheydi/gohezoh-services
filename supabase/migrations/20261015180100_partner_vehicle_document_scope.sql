-- Restrict sensitive vehicle and driver evidence to its company and Super Admin.
drop policy if exists partner_vehicle_document_read on storage.objects;
create policy partner_vehicle_document_read on storage.objects for select to authenticated using (
  bucket_id='partner-vehicles' and exists(select 1 from public.partner_application_vehicles v
    join public.staff_applications a on a.id=v.application_id
    where name in (v.vehicle_document_path,v.licence_document_path)
      and (public.has_role(auth.uid(),'admin') or a.user_id=auth.uid() or exists(
        select 1 from public.partner_users pu where pu.partner_id=v.partner_id
          and pu.user_id=auth.uid() and pu.membership_role='manager')))
);
