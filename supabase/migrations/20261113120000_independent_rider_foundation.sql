-- Independent riders have their own Supabase email/password, while remaining
-- affiliated with one active logistics company. No NIN or licence is collected
-- in this test-onboarding phase.
alter table public.company_riders alter column nin drop not null;
alter table public.company_riders alter column licence_document_path drop not null;
alter table public.company_riders add column independent_user_id uuid unique references auth.users(id) on delete set null;
alter table public.company_riders add constraint independent_rider_identity_check check (
  (independent_user_id is null and nin is not null and licence_document_path is not null)
  or (independent_user_id is not null and phone is not null)
);

create or replace function public.register_independent_rider(p_partner_id uuid, p_phone text)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_user uuid:=auth.uid(); v_rider uuid; v_name text; v_seed text;
begin
  if v_user is null or auth.role()<>'authenticated' or not exists (
    select 1 from auth.users u where u.id=v_user and u.email_confirmed_at is not null
      and u.raw_user_meta_data->>'account_kind'='independent_rider'
  ) then raise insufficient_privilege using message='Confirm your independent rider email first'; end if;
  if p_phone !~ '^\+?[0-9]{10,15}$' then raise check_violation using message='Enter a valid phone number'; end if;
  if not exists(select 1 from public.logistics_partners p where p.id=p_partner_id and p.status='active') then
    raise check_violation using message='Choose an active logistics company'; end if;
  if exists(select 1 from public.company_riders where independent_user_id=v_user) then
    raise unique_violation using message='This rider account is already registered'; end if;
  select nullif(btrim(full_name),'') into v_name from public.profiles where user_id=v_user;
  if length(coalesce(v_name,''))<3 then raise check_violation using message='Enter your full name'; end if;
  insert into public.company_riders(partner_id,full_name,phone,status,reviewed_at,independent_user_id)
    values(p_partner_id,v_name,p_phone,'approved',now(),v_user) returning id into v_rider;
  insert into public.partner_users(partner_id,user_id,membership_role)
    values(p_partner_id,v_user,'rider') on conflict(partner_id,user_id) do update set membership_role='rider';
  insert into public.user_roles(user_id,role) values(v_user,'rider') on conflict do nothing;
  delete from public.user_roles where user_id=v_user and role='customer';
  v_seed:=encode(extensions.gen_random_bytes(32),'hex');
  insert into public.rider_credentials(user_id,partner_id,rider_name,roster_id,auth_secret_seed,
    link_hash,password_salt,password_hash,password_fingerprint)
    values(v_user,p_partner_id,v_name,v_rider,v_seed,encode(extensions.digest(v_seed||'link','sha256'),'hex'),
      encode(extensions.gen_random_bytes(16),'hex'),encode(extensions.digest(v_seed||'password','sha256'),'hex'),
      encode(extensions.digest(v_seed||'fingerprint','sha256'),'hex'));
  update public.profiles set phone=p_phone where user_id=v_user;
  return v_rider;
end $$;
revoke all on function public.register_independent_rider(uuid,text) from public,anon;
grant execute on function public.register_independent_rider(uuid,text) to authenticated;

create or replace function public.list_independent_rider_companies()
returns table(id uuid, name text) language sql stable security definer set search_path=pg_catalog,public as $$
  select p.id,p.partner_name from public.logistics_partners p
  where p.status='active' order by p.partner_name limit 200;
$$;
revoke all on function public.list_independent_rider_companies() from public,anon;
grant execute on function public.list_independent_rider_companies() to authenticated;

create policy independent_rider_own_roster on public.company_riders for select to authenticated
  using (independent_user_id=auth.uid());

-- Existing company rider sign-in remains device-bound. Independent riders sign
-- in through Supabase Auth; a live session is still required for rider RPCs.
create or replace function public.rider_session_active()
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select public.has_role(auth.uid(),'rider') and exists (
    select 1 from public.rider_credentials c join public.company_riders r on r.id=c.roster_id
    where c.user_id=auth.uid() and c.revoked_at is null and c.password_revoked_at is null
      and r.status='approved' and (r.independent_user_id is null or r.independent_user_id=auth.uid())
  ) and exists(select 1 from auth.sessions s where s.user_id=auth.uid()
    and s.id=(auth.jwt()->>'session_id')::uuid);
$$;
