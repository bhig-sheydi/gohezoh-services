-- Recheck the submitted files when approving a newly added rider.
create or replace function public.review_company_rider(p_rider_id uuid,p_approve boolean,p_reason text default null)
returns void language plpgsql security definer set search_path=pg_catalog,public,auth,storage as $$
declare v_rider public.company_riders%rowtype;
begin
  if not public.has_role(auth.uid(),'admin') then raise insufficient_privilege using message='Super Admin access required'; end if;
  if not p_approve and length(btrim(coalesce(p_reason,'')))<3 then
    raise check_violation using message='A rejection reason is required'; end if;
  select * into v_rider from public.company_riders where id=p_rider_id and status='pending' for update;
  if not found then raise no_data_found using message='Pending rider not found'; end if;
  if p_approve and (v_rider.nin_document_path is null or v_rider.licence_document_path is null
    or not exists(select 1 from storage.objects o where o.bucket_id='rider-evidence' and o.name=v_rider.nin_document_path)
    or not exists(select 1 from storage.objects o where o.bucket_id='rider-evidence' and o.name=v_rider.licence_document_path)) then
    raise check_violation using message='NIN and licence evidence must be uploaded before approval'; end if;
  update public.company_riders set status=case when p_approve then 'approved' else 'rejected' end,
    rejection_reason=case when p_approve then null else btrim(p_reason) end,reviewed_at=now()
  where id=p_rider_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
  values('company_rider',p_rider_id,case when p_approve then 'approved' else 'rejected' end,auth.uid(),array['status']);
end $$;
