-- Partner companies can invite their own approved portal users. New partner access
-- still requires a verified email, NIN/CAC review, and Super Admin approval.
alter table public.partner_users
  add column membership_role text not null default 'staff'
    check (membership_role in ('manager','staff','dispatcher','rider'));
with ranked as (
  select partner_id,user_id,row_number() over(partition by partner_id order by created_at,user_id) as n
  from public.partner_users
)
update public.partner_users pu set membership_role='manager'
from ranked r where r.partner_id=pu.partner_id and r.user_id=pu.user_id and r.n=1;

create table public.partner_staff_invitations (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.logistics_partners(id) on delete cascade,
  invited_email text not null check(invited_email=lower(btrim(invited_email))),
  membership_role text not null check(membership_role in ('staff','dispatcher','rider')),
  token_hash bytea not null unique,
  status text not null default 'pending' check(status in ('pending','claimed','accepted','cancelled','expired')),
  invited_by uuid not null references auth.users(id) on delete restrict,
  claimed_by uuid references auth.users(id) on delete set null,
  accepted_by uuid references auth.users(id) on delete set null,
  expires_at timestamptz not null default (now()+interval '14 days'),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  accepted_at timestamptz,
  check(expires_at>created_at)
);
create unique index partner_staff_invitation_active_email_idx
  on public.partner_staff_invitations(partner_id,invited_email) where status in ('pending','claimed');
create index partner_staff_invitation_manager_idx on public.partner_staff_invitations(partner_id,created_at desc);
alter table public.partner_staff_invitations enable row level security;
revoke all on public.partner_staff_invitations from public,anon,authenticated;
alter table public.staff_applications add column partner_invitation_id uuid references public.partner_staff_invitations(id) on delete restrict;

create or replace function public.create_partner_staff_invitation(p_partner_id uuid,p_email text,p_membership_role text default 'staff')
returns table(invitation_id uuid,invite_token text,expires_at timestamptz)
language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_actor uuid:=auth.uid();v_email text:=lower(btrim(coalesce(p_email,'')));v_token text;v_id uuid;v_expiry timestamptz;
begin
  if v_actor is null or not public.has_role(v_actor,'partner') or not exists(select 1 from public.partner_users
    where partner_id=p_partner_id and user_id=v_actor and membership_role='manager') then
    raise insufficient_privilege using message='Only a partner company manager can invite team members';end if;
  if p_membership_role is null or p_membership_role not in ('staff','dispatcher','rider')
    or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or not exists(select 1 from public.logistics_partners where id=p_partner_id and status='active') then
    raise check_violation using message='Enter a valid email and team role for an active partner company';end if;
  if exists(select 1 from public.partner_users pu join auth.users u on u.id=pu.user_id
    where pu.partner_id=p_partner_id and lower(u.email)=v_email) then
    raise unique_violation using message='This person is already on the partner team';end if;
  if exists(select 1 from public.partner_staff_invitations where partner_id=p_partner_id and invited_email=v_email and status in ('pending','claimed')) then
    raise unique_violation using message='An active invitation already exists for this email';end if;
  v_token:=encode(extensions.gen_random_bytes(32),'hex');
  insert into public.partner_staff_invitations(partner_id,invited_email,membership_role,token_hash,invited_by)
    values(p_partner_id,v_email,p_membership_role,extensions.digest(v_token,'sha256'),v_actor)
    returning id,partner_staff_invitations.expires_at into v_id,v_expiry;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('partner_staff_invitation',v_id,'created',v_actor,array['partner_id','invited_email','membership_role','expires_at']);
  return query select v_id,v_token,v_expiry;
end $$;
revoke all on function public.create_partner_staff_invitation(uuid,text,text) from public,anon;
grant execute on function public.create_partner_staff_invitation(uuid,text,text) to authenticated;

create or replace function public.accept_partner_staff_invitation(p_token text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_actor uuid:=auth.uid();v_inv public.partner_staff_invitations%rowtype;v_email text;v_partner_name text;v_app_id uuid;
begin
  if v_actor is null or nullif(btrim(p_token),'') is null then raise insufficient_privilege using message='Sign in to accept this partner invitation';end if;
  select lower(email) into v_email from auth.users where id=v_actor and email_confirmed_at is not null;
  if v_email is null then raise insufficient_privilege using message='Confirm your email before accepting a partner invitation';end if;
  select * into v_inv from public.partner_staff_invitations where token_hash=extensions.digest(btrim(p_token),'sha256') for update;
  if not found or v_inv.invited_email<>v_email or v_inv.status not in ('pending','claimed') or v_inv.expires_at<=now() then
    raise insufficient_privilege using message='This invitation is invalid, expired, or addressed to another email';end if;
  select partner_name into v_partner_name from public.logistics_partners where id=v_inv.partner_id and status='active';
  if v_partner_name is null then raise object_not_in_prerequisite_state using message='This partner company is inactive';end if;
  if public.has_role(v_actor,'partner') then
    insert into public.partner_users(partner_id,user_id,membership_role) values(v_inv.partner_id,v_actor,v_inv.membership_role) on conflict(partner_id,user_id) do nothing;
    update public.partner_staff_invitations set status='accepted',claimed_by=v_actor,accepted_by=v_actor,claimed_at=coalesce(claimed_at,now()),accepted_at=now() where id=v_inv.id;
    insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
      values('partner_staff_invitation',v_inv.id,'accepted_by_existing_partner_user',v_actor,array['status','accepted_by','accepted_at']);
    return jsonb_build_object('status','accepted','partner_name',v_partner_name,'membership_role',v_inv.membership_role);
  end if;
  if exists(select 1 from public.user_roles where user_id=v_actor and role<>'customer') then
    raise insufficient_privilege using message='This account cannot request partner access';end if;
  insert into public.staff_applications(user_id,requested_role,organization_name,partner_invitation_id)
    values(v_actor,'partner',v_partner_name,v_inv.id)
    on conflict(user_id,requested_role) do update set organization_name=excluded.organization_name,
      partner_invitation_id=excluded.partner_invitation_id,status='pending',reviewed_by=null,reviewed_at=null,
      partner_document_type=null,partner_document_path=null,partner_document_submitted_at=null
      where staff_applications.status in ('rejected','revoked') or staff_applications.status='pending'
    returning id into v_app_id;
  if v_app_id is null then raise unique_violation using message='A partner access request has already been reviewed';end if;
  update public.partner_staff_invitations set status='claimed',claimed_by=v_actor,claimed_at=now() where id=v_inv.id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('partner_staff_invitation',v_inv.id,'claimed_for_super_admin_review',v_actor,array['status','claimed_by','claimed_at']);
  return jsonb_build_object('status','application_required','partner_name',v_partner_name,'application_id',v_app_id);
end $$;
revoke all on function public.accept_partner_staff_invitation(text) from public,anon;
grant execute on function public.accept_partner_staff_invitation(text) to authenticated;

create or replace function public.cancel_partner_staff_invitation(p_invitation_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_partner uuid;
begin
  select partner_id into v_partner from public.partner_staff_invitations where id=p_invitation_id and status='pending' for update;
  if not found or not exists(select 1 from public.partner_users where partner_id=v_partner and user_id=v_actor and membership_role='manager') then
    raise insufficient_privilege using message='Only the partner company manager can cancel a pending invitation';end if;
  update public.partner_staff_invitations set status='cancelled' where id=p_invitation_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('partner_staff_invitation',p_invitation_id,'cancelled',v_actor,array['status']);
end $$;
revoke all on function public.cancel_partner_staff_invitation(uuid) from public,anon;
grant execute on function public.cancel_partner_staff_invitation(uuid) to authenticated;

create or replace function public.list_my_partner_team()
returns table(partner_id uuid,partner_name text,user_id uuid,email text,full_name text,membership_role text,is_manager boolean)
language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
begin
  if not public.has_role(auth.uid(),'partner') then raise insufficient_privilege using message='Partner account required';end if;
  return query select pu.partner_id,lp.partner_name,pu.user_id,u.email::text,p.full_name,pu.membership_role,pu.membership_role='manager'
    from public.partner_users mine join public.partner_users pu on pu.partner_id=mine.partner_id
      join public.logistics_partners lp on lp.id=pu.partner_id join auth.users u on u.id=pu.user_id
      left join public.profiles p on p.user_id=pu.user_id
    where mine.user_id=auth.uid() order by lp.partner_name,pu.membership_role,u.email;
end $$;
revoke all on function public.list_my_partner_team() from public,anon;
grant execute on function public.list_my_partner_team() to authenticated;

create or replace function public.list_partner_staff_invitations()
returns table(invitation_id uuid,partner_id uuid,partner_name text,invited_email text,membership_role text,status text,expires_at timestamptz,created_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.has_role(auth.uid(),'partner') then raise insufficient_privilege using message='Partner account required';end if;
  return query select i.id,i.partner_id,p.partner_name,i.invited_email,i.membership_role,
    case when i.status in ('pending','claimed') and i.expires_at<=now() then 'expired' else i.status end,i.expires_at,i.created_at
    from public.partner_staff_invitations i join public.partner_users pu on pu.partner_id=i.partner_id and pu.user_id=auth.uid()
      join public.logistics_partners p on p.id=i.partner_id
    where pu.membership_role='manager' order by i.created_at desc limit 250;
end $$;
revoke all on function public.list_partner_staff_invitations() from public,anon;
grant execute on function public.list_partner_staff_invitations() to authenticated;

create or replace function public.review_staff_application(p_application_id uuid,p_approve boolean,p_partner_id uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,storage as $$
declare
  v_admin uuid:=auth.uid();v_request public.staff_applications%rowtype;v_email text;v_partner_id uuid;v_membership_role text;
  v_inv public.partner_staff_invitations%rowtype;v_partner_name text;
begin
  if not public.has_role(v_admin,'admin') then raise insufficient_privilege using message='Super Admin access is required';end if;
  select * into v_request from public.staff_applications where id=p_application_id for update;
  if not found then raise no_data_found using message='Staff request was not found';end if;
  if v_request.status<>'pending' then raise object_not_in_prerequisite_state using message='This request has already been reviewed';end if;
  select email into v_email from auth.users where id=v_request.user_id and email_confirmed_at is not null;
  if p_approve and v_email is null then raise object_not_in_prerequisite_state using message='Applicant must confirm their email first';end if;
  if p_approve and v_request.requested_role='partner' then
    if v_request.partner_document_type is null or v_request.partner_document_path is null or not exists(
      select 1 from storage.objects o where o.bucket_id='partner-verification' and o.name=v_request.partner_document_path and o.owner_id=v_request.user_id::text
    ) then raise check_violation using message='Partner must submit a NIN or CAC document before approval';end if;
    if v_request.partner_invitation_id is not null then
      select * into v_inv from public.partner_staff_invitations where id=v_request.partner_invitation_id for update;
      if not found or v_inv.status<>'claimed' or v_inv.claimed_by<>v_request.user_id or v_inv.invited_email<>lower(v_email) or v_inv.expires_at<=now() then
        raise check_violation using message='The partner invitation is no longer valid';end if;
      v_partner_id:=v_inv.partner_id;v_membership_role:=v_inv.membership_role;
      if p_partner_id is not null and p_partner_id<>v_partner_id then raise check_violation using message='Applicant must be linked to the invited partner company';end if;
    else
      v_partner_id:=p_partner_id;
      if v_partner_id is null then raise check_violation using message='Choose an active logistics partner';end if;
      select case when exists(select 1 from public.partner_users where partner_id=v_partner_id and membership_role='manager') then 'staff' else 'manager' end into v_membership_role;
    end if;
    select partner_name into v_partner_name from public.logistics_partners where id=v_partner_id and status='active';
    if v_partner_name is null then raise check_violation using message='Choose an active logistics partner';end if;
    insert into public.partner_users(partner_id,user_id,membership_role) values(v_partner_id,v_request.user_id,v_membership_role)
      on conflict(partner_id,user_id) do update set membership_role=excluded.membership_role;
    if v_request.partner_invitation_id is not null then
      update public.partner_staff_invitations set status='accepted',accepted_by=v_request.user_id,accepted_at=now() where id=v_inv.id;
    end if;
  elsif p_partner_id is not null then raise check_violation using message='A partner can only be selected for Partner access';
  end if;
  if p_approve and v_request.requested_role='marketer' then
    if v_request.invited_by_bdo_id is null or not public.has_role(v_request.invited_by_bdo_id,'bdo') or not exists(
      select 1 from public.bdo_marketer_invites i where i.used_by=v_request.user_id and i.bdo_user_id=v_request.invited_by_bdo_id and i.expires_at>v_request.created_at
    ) then raise check_violation using message='The BDO invitation is no longer valid';end if;
    insert into public.bdo_marketers(marketer_user_id,bdo_user_id,invite_id)
      select v_request.user_id,v_request.invited_by_bdo_id,i.id from public.bdo_marketer_invites i where i.used_by=v_request.user_id;
  end if;
  if p_approve then insert into public.user_roles(user_id,role) values(v_request.user_id,v_request.requested_role) on conflict do nothing;end if;
  update public.staff_applications set status=case when p_approve then 'approved' else 'rejected' end,reviewed_by=v_admin,reviewed_at=now() where id=v_request.id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('staff_application',v_request.id,case when p_approve then 'approved' else 'rejected' end,v_admin,array['status','requested_role','partner_invitation_id']);
  return jsonb_build_object('user_id',v_request.user_id,'role',v_request.requested_role,'status',case when p_approve then 'approved' else 'rejected' end,
    'partner_id',v_partner_id,'partner_membership_role',v_membership_role);
end $$;
revoke all on function public.review_staff_application(uuid,boolean,uuid) from public,anon,authenticated;
grant execute on function public.review_staff_application(uuid,boolean,uuid) to authenticated;

drop function public.list_staff_applications();
create function public.list_staff_applications()
returns table(id uuid,user_id uuid,email text,full_name text,requested_role public.app_role,organization_name text,status text,
  email_confirmed boolean,created_at timestamptz,invited_partner_id uuid,invited_partner_name text)
language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select sa.id,sa.user_id,u.email,p.full_name,sa.requested_role,sa.organization_name,sa.status,
    u.email_confirmed_at is not null,sa.created_at,inv.partner_id,lp.partner_name
  from public.staff_applications sa join auth.users u on u.id=sa.user_id
  left join public.profiles p on p.user_id=sa.user_id
  left join public.partner_staff_invitations inv on inv.id=sa.partner_invitation_id
  left join public.logistics_partners lp on lp.id=inv.partner_id
  where public.has_role(auth.uid(),'admin') order by (sa.status='pending') desc,sa.created_at desc;
$$;
revoke all on function public.list_staff_applications() from public,anon,authenticated;
grant execute on function public.list_staff_applications() to authenticated;

create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_role text;v_marketer_invite public.bdo_marketer_invites%rowtype;v_partner_invite public.partner_staff_invitations%rowtype;v_token text;v_org text;
begin
  insert into public.profiles(user_id,full_name,email,phone) values(new.id,nullif(new.raw_user_meta_data->>'full_name',''),new.email,new.phone) on conflict(user_id) do nothing;
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
revoke all on function public.handle_new_auth_user() from public,anon,authenticated;
