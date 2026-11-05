create or replace function public.clear_owner_identity_on_reapplication()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if new.status='pending' and old.status in ('rejected','revoked') then
    new.owner_nin:=null;
    new.owner_selfie_path:=null;
    new.owner_identity_submitted_at:=null;
  end if;
  return new;
end $$;
revoke all on function public.clear_owner_identity_on_reapplication() from public,anon,authenticated;
drop trigger if exists clear_owner_identity_on_reapplication on public.staff_applications;
create trigger clear_owner_identity_on_reapplication before update of status
on public.staff_applications for each row execute function public.clear_owner_identity_on_reapplication();
