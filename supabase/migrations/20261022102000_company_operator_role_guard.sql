-- A revoked partner role also disables password-only company operators.
create or replace function public.company_staff_allowed(p_partner_id uuid,p_permission text)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists(select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
    where pu.partner_id=p_partner_id and pu.user_id=auth.uid() and pu.membership_role='manager' and p.status='active')
  or (p_permission='bid' and public.has_role(auth.uid(),'partner') and exists(
    select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
    where pu.partner_id=p_partner_id and pu.user_id=auth.uid() and p.status='active'
      and not exists(select 1 from public.company_operations_staff s where s.user_id=auth.uid())))
  or exists(select 1 from public.company_operations_staff s join public.logistics_partners p on p.id=s.partner_id
    join auth.sessions sess on sess.user_id=s.user_id and sess.id=(auth.jwt()->>'session_id')::uuid
      and sess.created_at>=s.session_not_before
    where s.partner_id=p_partner_id and s.user_id=auth.uid() and p.status='active'
      and public.has_role(s.user_id,'partner') and s.revoked_at is null and s.password_revoked_at is null
      and case p_permission when 'bid' then s.can_bid when 'riders' then s.can_manage_riders
        when 'withdraw' then s.can_withdraw when 'overview' then (s.can_bid or s.can_manage_riders or s.can_withdraw) else false end);
$$;

create or replace function public.company_staff_actor_allowed(p_partner_id uuid,p_actor_id uuid,p_session_id uuid,p_permission text)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select exists(select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
    where pu.partner_id=p_partner_id and pu.user_id=p_actor_id and pu.membership_role='manager' and p.status='active')
  or exists(select 1 from public.company_operations_staff s join public.logistics_partners p on p.id=s.partner_id
    join auth.sessions sess on sess.user_id=s.user_id and sess.id=p_session_id
      and sess.created_at>=s.session_not_before
    where s.partner_id=p_partner_id and s.user_id=p_actor_id and p.status='active'
      and public.has_role(s.user_id,'partner') and s.revoked_at is null and s.password_revoked_at is null
      and case p_permission when 'bid' then s.can_bid when 'riders' then s.can_manage_riders
        when 'withdraw' then s.can_withdraw when 'overview' then (s.can_bid or s.can_manage_riders or s.can_withdraw) else false end);
$$;

create or replace function public.company_staff_actor_permission(p_partner_id uuid,p_actor_id uuid,p_permission text)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select exists(select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
    where pu.partner_id=p_partner_id and pu.user_id=p_actor_id and pu.membership_role='manager' and p.status='active')
  or exists(select 1 from public.company_operations_staff s join public.logistics_partners p on p.id=s.partner_id
    where s.partner_id=p_partner_id and s.user_id=p_actor_id and p.status='active'
      and public.has_role(s.user_id,'partner') and s.revoked_at is null and s.password_revoked_at is null
      and case p_permission when 'bid' then s.can_bid when 'riders' then s.can_manage_riders
        when 'withdraw' then s.can_withdraw when 'overview' then (s.can_bid or s.can_manage_riders or s.can_withdraw) else false end);
$$;

create or replace function public.my_company_operations_staff()
returns table(staff_id uuid,partner_id uuid,full_name text,can_bid boolean,can_manage_riders boolean,can_withdraw boolean)
language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select s.id,s.partner_id,s.full_name,s.can_bid,s.can_manage_riders,s.can_withdraw
  from public.company_operations_staff s join public.logistics_partners p on p.id=s.partner_id and p.status='active'
    join auth.sessions sess on sess.user_id=s.user_id
    and sess.id=(auth.jwt()->>'session_id')::uuid and sess.created_at>=s.session_not_before
  where s.user_id=auth.uid() and public.has_role(s.user_id,'partner') and s.revoked_at is null and s.password_revoked_at is null;
$$;
