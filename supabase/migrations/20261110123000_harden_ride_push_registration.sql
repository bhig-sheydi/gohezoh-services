-- Keep pending deliveries when the same phone refreshes its token on app open.
create or replace function public.register_ride_push_device(p_device_id uuid,p_token text,p_kind text)
returns void language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_session uuid;v_token text:=btrim(p_token);
begin
  if auth.uid() is null or p_device_id is null or length(v_token) not between 30 and 4096
    or p_kind not in ('customer','company','rider') then
    raise check_violation using message='Invalid ride alert registration';
  end if;
  v_session:=(auth.jwt()->>'session_id')::uuid;
  if v_session is null or not exists(select 1 from auth.sessions where id=v_session and user_id=auth.uid()) then
    raise insufficient_privilege using message='An active session is required';
  end if;
  if p_kind='customer' and not exists(select 1 from public.customer_users where user_id=auth.uid()) then
    raise insufficient_privilege using message='Customer access is required';
  elsif p_kind='rider' and not public.rider_session_active() then
    raise insufficient_privilege using message='Rider access is required';
  elsif p_kind='company' and not exists(
    select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
      where pu.user_id=auth.uid() and pu.membership_role='manager' and p.status='active'
    union all
    select 1 from public.company_operations_staff s join public.logistics_partners p on p.id=s.partner_id
      where s.user_id=auth.uid() and s.revoked_at is null and s.password_revoked_at is null
        and s.can_bid and p.status='active'
  ) then raise insufficient_privilege using message='Company bidding access is required';
  end if;
  delete from public.ride_push_devices where fcm_token=v_token
    and (user_id<>auth.uid() or device_id<>p_device_id);
  insert into public.ride_push_devices(user_id,device_id,fcm_token,kind,session_id)
    values(auth.uid(),p_device_id,v_token,p_kind,v_session)
  on conflict(user_id,device_id) do update set fcm_token=excluded.fcm_token,
    kind=excluded.kind,session_id=excluded.session_id,last_seen_at=now();
end $$;
