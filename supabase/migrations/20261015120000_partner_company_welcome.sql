-- Company identity and confirmed earnings for partner managers.
alter table public.logistics_partners add column if not exists logo_path text;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('partner-logos','partner-logos',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create policy partner_logo_read on storage.objects for select to authenticated
using (bucket_id='partner-logos' and exists (
  select 1 from public.partner_users pu where pu.partner_id::text=(storage.foldername(name))[1] and pu.user_id=auth.uid()
));
create policy partner_logo_upload on storage.objects for insert to authenticated
with check (bucket_id='partner-logos' and array_length(storage.foldername(name),1)=1 and exists (
  select 1 from public.partner_users pu where pu.partner_id::text=(storage.foldername(name))[1]
  and pu.user_id=auth.uid() and pu.membership_role='manager'
));
create policy partner_logo_cleanup on storage.objects for delete to authenticated
using (bucket_id='partner-logos' and exists (
  select 1 from public.partner_users pu where pu.partner_id::text=(storage.foldername(name))[1]
  and pu.user_id=auth.uid() and pu.membership_role='manager'
));

create or replace function public.set_my_partner_logo(p_partner_id uuid,p_path text)
returns text language plpgsql security definer set search_path=pg_catalog,public,storage,auth as $$
begin
  if not exists (select 1 from public.partner_users where partner_id=p_partner_id and user_id=auth.uid() and membership_role='manager') then
    raise insufficient_privilege using message='Only a company manager can change its logo';
  end if;
  if p_path is null or p_path !~ ('^'||p_partner_id::text||'/[^/]+[.](jpg|png|webp)$')
     or not exists (select 1 from storage.objects where bucket_id='partner-logos' and name=p_path and owner_id=auth.uid()::text) then
    raise check_violation using message='Upload a valid company logo first';
  end if;
  update public.logistics_partners set logo_path=p_path where id=p_partner_id;
  return p_path;
end $$;
revoke all on function public.set_my_partner_logo(uuid,text) from public,anon;
grant execute on function public.set_my_partner_logo(uuid,text) to authenticated;

create or replace function public.my_partner_company_welcome(p_day_start timestamptz,p_day_end timestamptz)
returns table(partner_id uuid,partner_name text,ceo_name text,logo_path text,earnings_ngn numeric)
language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
begin
  if auth.uid() is null or p_day_start is null or p_day_end is null or p_day_end<=p_day_start
     or p_day_end-p_day_start>interval '26 hours' then
    raise invalid_parameter_value using message='Invalid local day';
  end if;
  return query
  select p.id,p.partner_name,p.contact_person,p.logo_path,
    coalesce((select sum(s.amount) from public.partner_settlements s
      where s.partner_id=p.id and s.status in ('approved','paid') and s.currency='NGN'
      and exists (select 1 from public.job_status_history h where h.job_id=s.job_id
        and h.new_status='delivered' and h.changed_at>=p_day_start and h.changed_at<p_day_end)),0)::numeric
  from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
  where pu.user_id=auth.uid() and pu.membership_role='manager'
  order by p.partner_name;
end $$;
revoke all on function public.my_partner_company_welcome(timestamptz,timestamptz) from public,anon;
grant execute on function public.my_partner_company_welcome(timestamptz,timestamptz) to authenticated;
