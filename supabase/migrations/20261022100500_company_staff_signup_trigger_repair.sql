-- Preserve existing marketer and partner invite handling while excluding internal company staff identities.
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_role text;v_marketer_invite public.bdo_marketer_invites%rowtype;v_partner_invite public.partner_staff_invitations%rowtype;v_token text;v_org text;
begin
  insert into public.profiles(user_id,full_name,email,phone) values(new.id,nullif(new.raw_user_meta_data->>'full_name',''),new.email,new.phone) on conflict(user_id) do nothing;
  if new.raw_user_meta_data->>'account_kind' in ('company_rider','company_operator') then return new; end if;
  if new.raw_user_meta_data->>'account_kind'='staff' then
    v_role:=new.raw_user_meta_data->>'requested_role';
    if v_role not in ('operations','finance','bdo','warehouse','partner','management','marketer') then raise check_violation using message='Choose a valid staff category';end if;
    if v_role='marketer' then
      v_token:=nullif(btrim(new.raw_user_meta_data->>'marketer_invite'),'');
      if v_token is null or length(v_token)<32 then raise insufficient_privilege using message='A valid BDO invitation is required to register as a marketer';end if;
      select * into v_marketer_invite from public.bdo_marketer_invites where token_hash=extensions.digest(v_token,'sha256') and email=lower(btrim(new.email))
        and used_by is null and expires_at>now() and public.has_role(bdo_user_id,'bdo') for update;
      if not found then raise insufficient_privilege using message='This marketer invitation is invalid, expired, or for another email';end if;
      update public.bdo_marketer_invites set used_by=new.id where id=v_marketer_invite.id;
      insert into public.staff_applications(user_id,requested_role,organization_name,invited_by_bdo_id)
        values(new.id,'marketer',nullif(btrim(new.raw_user_meta_data->>'organization_name'),''),v_marketer_invite.bdo_user_id);
    elsif v_role='partner' and nullif(btrim(new.raw_user_meta_data->>'partner_invite'),'') is not null then
      v_token:=btrim(new.raw_user_meta_data->>'partner_invite');
      select * into v_partner_invite from public.partner_staff_invitations where token_hash=extensions.digest(v_token,'sha256')
        and invited_email=lower(btrim(new.email)) and status='pending' and expires_at>now() for update;
      if not found then raise insufficient_privilege using message='This partner invitation is invalid, expired, or for another email';end if;
      select partner_name into v_org from public.logistics_partners where id=v_partner_invite.partner_id and status='active';
      if v_org is null then raise object_not_in_prerequisite_state using message='This partner company is inactive';end if;
      update public.partner_staff_invitations set status='claimed',claimed_by=new.id,claimed_at=now() where id=v_partner_invite.id;
      insert into public.staff_applications(user_id,requested_role,organization_name,partner_invitation_id)
        values(new.id,'partner',v_org,v_partner_invite.id);
    else
      insert into public.staff_applications(user_id,requested_role,organization_name)
        values(new.id,v_role::public.app_role,nullif(btrim(new.raw_user_meta_data->>'organization_name'),''));
    end if;
  else insert into public.user_roles(user_id,role) values(new.id,'customer') on conflict do nothing;
  end if;
  return new;
end $$;
