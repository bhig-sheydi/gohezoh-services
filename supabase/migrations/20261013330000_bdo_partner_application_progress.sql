create or replace function public.list_my_partner_prospect_progress()
returns table(
  partner_prospect_id uuid,
  application_status text,
  email_confirmed boolean,
  verification_document_submitted boolean
)
language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
begin
  if auth.uid() is null or not (
    public.has_role(auth.uid(),'bdo') or
    public.has_role(auth.uid(),'management') or
    public.has_role(auth.uid(),'admin')
  ) then
    raise insufficient_privilege using message='Business Development access is required';
  end if;

  return query
  select p.id,sa.status,u.email_confirmed_at is not null,
    sa.partner_document_type is not null and sa.partner_document_path is not null
  from public.partner_prospects p
  left join lateral (
    select application.user_id,application.status,application.partner_document_type,application.partner_document_path
    from public.staff_applications application
    where application.partner_prospect_id=p.id
    order by application.created_at desc
    limit 1
  ) sa on true
  left join auth.users u on u.id=sa.user_id
  where p.assigned_bdo_id=auth.uid() or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')
  order by p.updated_at desc;
end $$;
revoke all on function public.list_my_partner_prospect_progress() from public,anon,authenticated;
grant execute on function public.list_my_partner_prospect_progress() to authenticated;

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
  if v_prospect.status='declined' or v_prospect.converted_partner_id is not null then
    raise object_not_in_prerequisite_state using message='This partner opportunity is closed';
  end if;
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

create or replace function public.notify_bdo_partner_application_review()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_prospect_name text;
  v_title text;
  v_body text;
begin
  if old.status is distinct from new.status
     and old.status='pending'
     and new.status in ('approved','rejected')
     and new.partner_prospect_id is not null
     and new.invited_by_bdo_id is not null then
    select partner_name into v_prospect_name
    from public.partner_prospects where id=new.partner_prospect_id;

    v_title:=case when new.status='approved' then 'Partner application approved' else 'Partner application declined' end;
    v_body:=coalesce(v_prospect_name,'Your referred partner') || case
      when new.status='approved' then ' has been approved and linked to the partner network.'
      else ' was not approved. Contact Management if you need more information.'
    end;

    insert into public.notifications(user_id,event_type,channel,title,body,payload,status,sent_at)
    values(new.invited_by_bdo_id,'bdo_partner_application_review','in_app',v_title,v_body,
      jsonb_build_object('partner_prospect_id',new.partner_prospect_id,'application_status',new.status),
      'delivered',now());
  end if;
  return new;
end $$;
revoke all on function public.notify_bdo_partner_application_review() from public,anon,authenticated;
drop trigger if exists staff_application_bdo_partner_review_notification on public.staff_applications;
create trigger staff_application_bdo_partner_review_notification
after update of status on public.staff_applications
for each row execute function public.notify_bdo_partner_application_review();
