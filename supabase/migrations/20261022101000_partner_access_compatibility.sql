-- Preserve existing approved partner-team bidding while keeping password-only operators scoped.
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
      and s.revoked_at is null and s.password_revoked_at is null
      and case p_permission when 'bid' then s.can_bid when 'riders' then s.can_manage_riders
        when 'withdraw' then s.can_withdraw when 'overview' then (s.can_bid or s.can_manage_riders or s.can_withdraw) else false end);
$$;

create or replace function public.is_partner_user(_partner_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public,auth as $$
  select public.has_role(auth.uid(),'partner') and exists (
    select 1 from public.partner_users pu where pu.partner_id=_partner_id and pu.user_id=auth.uid()
      and not exists(select 1 from public.company_operations_staff s where s.user_id=auth.uid())
  );
$$;
