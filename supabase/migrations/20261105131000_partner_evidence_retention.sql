create function public.list_orphan_partner_verification_files(p_limit integer default 100)
returns table(path text) language plpgsql security definer
set search_path=pg_catalog,public,auth,storage as $$
begin
  if auth.role()<>'service_role' and not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  if p_limit not between 1 and 100 then raise check_violation using message='Limit must be 1 to 100'; end if;
  return query select o.name from storage.objects o
    where o.bucket_id='partner-verification' and o.created_at<now()-interval '30 days'
      and not exists(select 1 from public.staff_applications a
        where o.name in (a.partner_document_path,a.owner_selfie_path))
    order by o.created_at limit p_limit;
end $$;
revoke all on function public.list_orphan_partner_verification_files(integer) from public,anon,authenticated;
grant execute on function public.list_orphan_partner_verification_files(integer) to service_role;
