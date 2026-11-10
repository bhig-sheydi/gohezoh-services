create or replace function public.claim_ride_push_deliveries(p_limit integer default 30)
returns table(delivery_id uuid,event_id uuid,device_token text,event_type text,source_id uuid,expires_at timestamptz,user_id uuid)
language plpgsql security definer set search_path=pg_catalog,public,auth as $$
begin
  if auth.role() is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_limit not between 1 and 100 then raise check_violation; end if;
  update public.ride_push_deliveries x set status='dead' where x.status in ('pending','sending') and x.expires_at<=now();
  return query with due as (
    select x.id from public.ride_push_deliveries x join public.ride_push_devices d on d.id=x.device_id
      join auth.sessions sess on sess.id=d.session_id and sess.user_id=d.user_id
    where (x.status='pending' and x.next_attempt_at<=now() or x.status='sending' and x.leased_until<now())
      and x.expires_at>now() and d.last_seen_at>now()-interval '30 days'
      and (x.event_type<>'company_invitation' or exists(
        select 1 from public.company_bid_invitations i where i.request_id=x.source_id
          and i.starts_at<=now() and i.deadline_at>now()
          and (exists(select 1 from public.partner_users pu where pu.partner_id=i.partner_id
            and pu.user_id=d.user_id and pu.membership_role='manager')
            or exists(select 1 from public.company_operations_staff s where s.partner_id=i.partner_id
              and s.user_id=d.user_id and s.can_bid and s.revoked_at is null and s.password_revoked_at is null))))
      and (x.event_type<>'rider_missed' or exists(
        select 1 from public.jobs j where j.id=x.source_id and d.kind='company'
          and (exists(select 1 from public.partner_users pu where pu.partner_id=j.partner_id
            and pu.user_id=d.user_id and pu.membership_role='manager')
            or exists(select 1 from public.company_operations_staff s where s.partner_id=j.partner_id
              and s.user_id=d.user_id and s.can_bid and s.revoked_at is null and s.password_revoked_at is null))))
      and (x.event_type<>'rider_assignment' or exists(select 1 from public.jobs j
        join public.rider_credentials rc on rc.user_id=j.assigned_rider_id and rc.revoked_at is null
          and rc.password_revoked_at is null
        where j.id=x.source_id and j.assigned_rider_id=d.user_id and j.status not in ('delivered','closed','cancelled')))
      and (x.event_type<>'customer_match' or exists(select 1 from public.service_requests r
        join public.customer_users cu on cu.customer_id=r.customer_id and cu.user_id=d.user_id
        join public.partner_quotes q on q.request_id=r.id and q.status='valid'
        where r.id=x.source_id))
    order by x.next_attempt_at,x.created_at limit p_limit for update of x skip locked
  ), claimed as (
    update public.ride_push_deliveries x set status='sending',attempts=x.attempts+1,
      leased_until=now()+interval '2 minutes' from due where x.id=due.id
    returning x.id,x.event_id,x.device_id,x.event_type,x.source_id,x.expires_at
  ) select c.id,c.event_id,d.fcm_token,c.event_type,c.source_id,c.expires_at,d.user_id
    from claimed c join public.ride_push_devices d on d.id=c.device_id;
end $$;
