-- Company owners should not be asked to respond to an offer sent directly to
-- an independent rider. Keep the established company screens otherwise intact.
do $$
declare v_sql text; v_next text;
begin
  select pg_get_functiondef('public.list_partner_bid_screen()'::regprocedure) into v_sql;
  v_next:=replace(v_sql,'where public.company_staff_allowed(pc.partner_id,''bid'')',
    'where not exists(select 1 from public.company_bid_invitations direct_i'
    ||' join public.company_riders direct_r on direct_r.independent_user_id=direct_i.rider_id'
    ||' where direct_i.request_id=r.id and direct_i.partner_id=pc.partner_id)'
    ||' and public.company_staff_allowed(pc.partner_id,''bid'')');
  if v_sql=v_next then raise exception 'Company bid screen filter was not found'; end if;
  execute v_next;

  select pg_get_functiondef('public.list_company_bike_prices()'::regprocedure) into v_sql;
  v_next:=replace(v_sql,'where public.company_staff_allowed(i.partner_id,''bid'')',
    'where not exists(select 1 from public.company_riders direct_r'
    ||' where direct_r.independent_user_id=i.rider_id and direct_r.partner_id=i.partner_id)'
    ||' and public.company_staff_allowed(i.partner_id,''bid'')');
  if v_sql=v_next then raise exception 'Company bike price filter was not found'; end if;
  execute v_next;
end $$;

create or replace function public.enqueue_company_ride_push() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if exists(select 1 from public.company_riders cr where cr.independent_user_id=new.rider_id
    and cr.partner_id=new.partner_id) then return new; end if;
  insert into public.ride_push_deliveries(device_id,event_type,source_id,next_attempt_at,expires_at)
  select d.id,'company_invitation',new.request_id,greatest(now(),new.starts_at),new.deadline_at
  from public.ride_push_devices d
  where d.kind='company' and d.last_seen_at>now()-interval '30 days'
    and (exists(select 1 from public.partner_users pu where pu.user_id=d.user_id
      and pu.partner_id=new.partner_id and pu.membership_role='manager')
      or exists(select 1 from public.company_operations_staff s where s.user_id=d.user_id
        and s.partner_id=new.partner_id and s.can_bid and s.revoked_at is null and s.password_revoked_at is null))
    and new.deadline_at>now()
  on conflict(device_id,event_type,source_id) do update
    set next_attempt_at=excluded.next_attempt_at,expires_at=excluded.expires_at,
      status=case when public.ride_push_deliveries.status='dead' then 'pending'
        else public.ride_push_deliveries.status end;
  return new;
end $$;
