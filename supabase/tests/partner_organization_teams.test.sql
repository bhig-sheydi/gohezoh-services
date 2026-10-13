begin;
do $$
declare
  v_manager uuid:=gen_random_uuid();v_existing_partner uuid:=gen_random_uuid();v_prospect uuid:=gen_random_uuid();v_other uuid:=gen_random_uuid();
  v_partner uuid:=gen_random_uuid();v_other_partner uuid:=gen_random_uuid();v_invite record;v_first_invite record;v_result jsonb;v_application uuid;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values
    (v_manager,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','team-manager-'||v_manager||'@example.test','',now(),'{}','{}',now(),now()),
    (v_existing_partner,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','team-member-'||v_existing_partner||'@example.test','',now(),'{}','{}',now(),now()),
    (v_prospect,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','team-prospect-'||v_prospect||'@example.test','',now(),'{}','{}',now(),now()),
    (v_other,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','team-other-'||v_other||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_manager,'partner'),(v_existing_partner,'partner'),(v_prospect,'customer'),(v_other,'partner') on conflict do nothing;
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status) values
    (v_partner,'Team One Logistics','Contact','08000000001','active'),(v_other_partner,'Team Two Logistics','Contact','08000000002','active');
  insert into public.partner_users(partner_id,user_id,membership_role) values
    (v_partner,v_manager,'manager'),(v_other_partner,v_other,'manager');

  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  select * into v_invite from public.create_partner_staff_invitation(v_partner,'team-member-'||v_existing_partner||'@example.test','dispatcher');
  if v_invite.invite_token is null or not exists(select 1 from public.partner_staff_invitations where id=v_invite.invitation_id
      and token_hash=extensions.digest(v_invite.invite_token,'sha256') and invited_email='team-member-'||v_existing_partner||'@example.test') then
    raise exception 'Invitation token was not securely hashed or email-bound';end if;
  v_first_invite:=v_invite;
  select * into v_invite from public.create_partner_staff_invitation(v_partner,'team-prospect-'||v_prospect||'@example.test','rider');

  begin
    perform * from public.create_partner_staff_invitation(v_partner,'team-denied@example.test','manager');
    raise exception 'Partner manager created a privileged company-manager invitation';
  exception when check_violation then null;end;

  perform set_config('request.jwt.claim.sub',v_prospect::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_prospect,'role','authenticated')::text,true);
  v_result:=public.accept_partner_staff_invitation(v_invite.invite_token);
  if v_result->>'status'<>'application_required' or not public.has_role(v_prospect,'customer') or public.has_role(v_prospect,'partner') then
    raise exception 'Invited new staff bypassed Super Admin partner approval';end if;
  select id into v_application from public.staff_applications where user_id=v_prospect and requested_role='partner' and status='pending';
  if v_application is null or not exists(select 1 from public.staff_applications where id=v_application and partner_invitation_id=v_invite.invitation_id) then
    raise exception 'Invitation was not attached to the applicant review record';end if;

  perform set_config('request.jwt.claim.sub',v_existing_partner::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_existing_partner,'role','authenticated')::text,true);
  v_result:=public.accept_partner_staff_invitation(v_first_invite.invite_token);
  if v_result->>'status'<>'accepted' or not public.is_partner_user(v_partner)
    or not exists(select 1 from public.partner_users where partner_id=v_partner and user_id=v_existing_partner and membership_role='dispatcher') then
    raise exception 'Approved partner user did not join invited organization with scoped role';end if;
  if exists(select 1 from public.list_my_partner_team() where partner_id=v_other_partner) then raise exception 'Partner team list exposed another organization';end if;
  if exists(select 1 from public.partner_staff_invitations where id=v_first_invite.invitation_id and status<>'accepted') then
    raise exception 'Accepted invitation status was not recorded';end if;
end $$;
rollback;
