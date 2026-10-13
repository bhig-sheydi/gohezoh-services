create table public.partner_prospect_invites (
  id uuid primary key default gen_random_uuid(),
  partner_prospect_id uuid not null unique references public.partner_prospects(id) on delete restrict,
  token uuid not null unique default gen_random_uuid(),
  created_by uuid not null references auth.users(id) on delete restrict,
  used_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days'),
  check (expires_at > created_at)
);
alter table public.partner_prospect_invites enable row level security;
revoke all on public.partner_prospect_invites from public,anon,authenticated;

alter table public.staff_applications
  add column partner_prospect_id uuid references public.partner_prospects(id) on delete restrict,
  add column partner_prospect_invite_id uuid references public.partner_prospect_invites(id) on delete restrict;

create or replace function public.create_partner_prospect_invite(p_prospect_id uuid)
returns text language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_prospect public.partner_prospects%rowtype;v_token uuid;
begin
  if auth.uid() is null or not (public.has_role(auth.uid(),'bdo') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')) then
    raise insufficient_privilege using message='Business Development access is required';
  end if;
  select * into v_prospect from public.partner_prospects where id=p_prospect_id for update;
  if not found then raise no_data_found using message='Partner prospect was not found'; end if;
  if v_prospect.assigned_bdo_id<>auth.uid() and not (public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')) then
    raise insufficient_privilege using message='This prospect is assigned to another BDO';
  end if;
  if v_prospect.status='declined' then raise object_not_in_prerequisite_state using message='A declined prospect cannot be invited'; end if;
  select token into v_token from public.partner_prospect_invites
    where partner_prospect_id=p_prospect_id and used_by is null and expires_at>now();
  if v_token is null then
    insert into public.partner_prospect_invites(partner_prospect_id,token,created_by,expires_at)
      values(p_prospect_id,gen_random_uuid(),auth.uid(),now()+interval '30 days')
      on conflict(partner_prospect_id) do update set token=excluded.token,created_by=excluded.created_by,
        used_by=null,created_at=now(),expires_at=excluded.expires_at
      returning token into v_token;
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('partner_prospect',p_prospect_id,'partner_signup_invite_created',auth.uid(),array['invite_created']);
  return v_token::text;
end $$;
revoke all on function public.create_partner_prospect_invite(uuid) from public,anon;
grant execute on function public.create_partner_prospect_invite(uuid) to authenticated;

create or replace function public.attach_partner_prospect_invite()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_token uuid;v_invite public.partner_prospect_invites%rowtype;v_prospect public.partner_prospects%rowtype;
begin
  if nullif(btrim(new.raw_user_meta_data->>'partner_prospect_invite'),'') is null then return new; end if;
  begin v_token:=(new.raw_user_meta_data->>'partner_prospect_invite')::uuid;
  exception when invalid_text_representation then raise insufficient_privilege using message='Partner referral link is invalid'; end;
  select i.* into v_invite from public.partner_prospect_invites i
    where i.token=v_token and i.used_by is null and i.expires_at>now() for update;
  if not found then raise insufficient_privilege using message='Partner referral link is invalid or expired'; end if;
  select * into v_prospect from public.partner_prospects where id=v_invite.partner_prospect_id for update;
  if not found or v_prospect.status='declined' then raise object_not_in_prerequisite_state using message='This partner opportunity is no longer open'; end if;
  if v_prospect.email is not null and lower(v_prospect.email)<>lower(new.email) then
    raise insufficient_privilege using message='Register using the email address recorded by your Gohezo contact';
  end if;
  if new.raw_user_meta_data->>'account_kind' is distinct from 'staff' or new.raw_user_meta_data->>'requested_role' is distinct from 'partner' then
    raise check_violation using message='This link is for a logistics partner application';
  end if;
  update public.partner_prospect_invites set used_by=new.id where id=v_invite.id;
  update public.staff_applications set organization_name=v_prospect.partner_name,
    invited_by_bdo_id=v_prospect.assigned_bdo_id,partner_prospect_id=v_prospect.id,partner_prospect_invite_id=v_invite.id
    where user_id=new.id and requested_role='partner' and status='pending';
  if not found then raise object_not_in_prerequisite_state using message='Partner access request was not created'; end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('staff_application',new.id,'partner_prospect_attributed',new.id,array['partner_prospect_id','invited_by_bdo_id']);
  return new;
end $$;
revoke all on function public.attach_partner_prospect_invite() from public,anon,authenticated;
create trigger on_auth_user_partner_prospect_invite
after insert on auth.users for each row execute function public.attach_partner_prospect_invite();

drop function public.list_staff_applications();
create function public.list_staff_applications()
returns table(id uuid,user_id uuid,email text,full_name text,requested_role public.app_role,organization_name text,status text,
  email_confirmed boolean,created_at timestamptz,invited_partner_id uuid,invited_partner_name text,partner_prospect_id uuid)
language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select sa.id,sa.user_id,u.email,p.full_name,sa.requested_role,sa.organization_name,sa.status,
    u.email_confirmed_at is not null,sa.created_at,coalesce(inv.partner_id,prospect.converted_partner_id),
    coalesce(lp.partner_name,prospect.partner_name),sa.partner_prospect_id
  from public.staff_applications sa join auth.users u on u.id=sa.user_id
  left join public.profiles p on p.user_id=sa.user_id
  left join public.partner_staff_invitations inv on inv.id=sa.partner_invitation_id
  left join public.partner_prospects prospect on prospect.id=sa.partner_prospect_id
  left join public.logistics_partners lp on lp.id=coalesce(inv.partner_id,prospect.converted_partner_id)
  where public.has_role(auth.uid(),'admin') order by (sa.status='pending') desc,sa.created_at desc;
$$;
revoke all on function public.list_staff_applications() from public,anon,authenticated;
grant execute on function public.list_staff_applications() to authenticated;

create or replace function public.review_staff_application(p_application_id uuid,p_approve boolean,p_partner_id uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,storage as $$
declare
  v_admin uuid:=auth.uid();v_request public.staff_applications%rowtype;v_email text;v_partner_id uuid;v_membership_role text;
  v_inv public.partner_staff_invitations%rowtype;v_partner_name text;v_prospect public.partner_prospects%rowtype;
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
    elsif v_request.partner_prospect_id is not null then
      select * into v_prospect from public.partner_prospects where id=v_request.partner_prospect_id for update;
      if not found or v_prospect.assigned_bdo_id is distinct from v_request.invited_by_bdo_id or v_prospect.status='declined' then
        raise check_violation using message='The BDO partner referral is no longer valid';end if;
      v_partner_id:=v_prospect.converted_partner_id;
      if v_partner_id is null then
        insert into public.logistics_partners(partner_name,contact_person,phone,email,base_city,base_state,partner_type,service_areas,status,notes)
          values(v_prospect.partner_name,v_prospect.contact_person,v_prospect.phone,v_prospect.email,v_prospect.city,v_prospect.state,
            coalesce(nullif(v_prospect.service_type,''),'logistics'),v_prospect.coverage_areas,'active',v_prospect.capacity_notes)
          returning id into v_partner_id;
      else
        update public.logistics_partners set status='active' where id=v_partner_id and status in ('pending','active');
        if not found then raise check_violation using message='The referred partner company cannot be activated';end if;
      end if;
      update public.partner_prospects set status='converted',converted_partner_id=v_partner_id,updated_at=now() where id=v_prospect.id;
      insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
        values('partner_prospect',v_prospect.id,'partner_application_approved',v_admin,array['status','converted_partner_id']);
      select case when exists(select 1 from public.partner_users where partner_id=v_partner_id and membership_role='manager') then 'staff' else 'manager' end into v_membership_role;
    else
      v_partner_id:=p_partner_id;
      if v_partner_id is null then raise check_violation using message='Choose an active logistics partner';end if;
      select case when exists(select 1 from public.partner_users where partner_id=v_partner_id and membership_role='manager') then 'staff' else 'manager' end into v_membership_role;
    end if;
    select partner_name into v_partner_name from public.logistics_partners where id=v_partner_id and status='active';
    if v_partner_name is null then raise check_violation using message='Choose an active logistics partner';end if;
    if p_partner_id is not null and p_partner_id<>v_partner_id then raise check_violation using message='Applicant must be linked to the referred partner company';end if;
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
    values('staff_application',v_request.id,case when p_approve then 'approved' else 'rejected' end,v_admin,array['status','requested_role','partner_invitation_id','partner_prospect_id']);
  return jsonb_build_object('user_id',v_request.user_id,'role',v_request.requested_role,'status',case when p_approve then 'approved' else 'rejected' end,
    'partner_id',v_partner_id,'partner_membership_role',v_membership_role,'partner_prospect_id',v_request.partner_prospect_id);
end $$;
revoke all on function public.review_staff_application(uuid,boolean,uuid) from public,anon,authenticated;
grant execute on function public.review_staff_application(uuid,boolean,uuid) to authenticated;
