-- Recipient OTP or the existing sender confirmation completes delivery.
-- Preserve historical proof records and files, but stop collecting new photos.
drop policy if exists pod_add_after_delivery on public.proof_of_delivery;
revoke insert on public.proof_of_delivery from authenticated;

drop policy if exists pod_objects_upload_after_delivery on storage.objects;
