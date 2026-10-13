-- Partner prospects carry their own BDO attribution. invited_by_bdo_id is reserved
-- by the existing schema for marketer applications.
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
  if not found or v_prospect.status='declined' or v_prospect.converted_partner_id is not null then
    raise object_not_in_prerequisite_state using message='This partner opportunity is no longer open';
  end if;
  if v_prospect.email is not null and lower(v_prospect.email)<>lower(new.email) then
    raise insufficient_privilege using message='Register using the email address recorded by your Gohezo contact';
  end if;
  if new.raw_user_meta_data->>'account_kind' is distinct from 'staff' or new.raw_user_meta_data->>'requested_role' is distinct from 'partner' then
    raise check_violation using message='This link is for a logistics partner application';
  end if;
  update public.partner_prospect_invites set used_by=new.id where id=v_invite.id;
  update public.staff_applications set organization_name=v_prospect.partner_name,
    partner_prospect_id=v_prospect.id,partner_prospect_invite_id=v_invite.id
    where user_id=new.id and requested_role='partner' and status='pending';
  if not found then raise object_not_in_prerequisite_state using message='Partner access request was not created'; end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('staff_application',new.id,'partner_prospect_attributed',new.id,array['partner_prospect_id','partner_prospect_invite_id']);
  return new;
end $$;
revoke all on function public.attach_partner_prospect_invite() from public,anon,authenticated;

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
      if not found or v_prospect.status='declined' or v_prospect.converted_partner_id is not null then
        raise check_violation using message='The BDO partner referral is no longer valid';end if;
      if v_request.partner_prospect_invite_id is null or not exists(
        select 1 from public.partner_prospect_invites i
        where i.id=v_request.partner_prospect_invite_id and i.partner_prospect_id=v_prospect.id and i.used_by=v_request.user_id
      ) then raise check_violation using message='The BDO partner invitation is no longer valid';end if;
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

create or replace function public.notify_bdo_partner_application_review()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_prospect_name text;v_bdo_id uuid;v_title text;v_body text;
begin
  if old.status is distinct from new.status and old.status='pending' and new.status in ('approved','rejected')
     and new.partner_prospect_id is not null then
    select partner_name,assigned_bdo_id into v_prospect_name,v_bdo_id
    from public.partner_prospects where id=new.partner_prospect_id;
    if v_bdo_id is not null then
      v_title:=case when new.status='approved' then 'Partner application approved' else 'Partner application declined' end;
      v_body:=coalesce(v_prospect_name,'Your referred partner') || case
        when new.status='approved' then ' has been approved and linked to the partner network.'
        else ' was not approved. Contact Management if you need more information.'
      end;
      insert into public.notifications(user_id,event_type,channel,title,body,payload,status,sent_at)
      values(v_bdo_id,'bdo_partner_application_review','in_app',v_title,v_body,
        jsonb_build_object('partner_prospect_id',new.partner_prospect_id,'application_status',new.status),'delivered',now());
    end if;
  end if;
  return new;
end $$;
revoke all on function public.notify_bdo_partner_application_review() from public,anon,authenticated;
