-- Preserve rider/company and custody guards, but let riders declare box space.
-- A fixed number of jobs does not tell us whether another parcel fits.
create or replace function public.guard_rider_active_pickup_limit()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_partner_accepted boolean; v_new_assignment boolean; v_load_state text;
begin
  select exists(select 1 from public.partner_assignments pa
    where pa.job_id=new.id and pa.partner_id=new.partner_id and pa.status='accepted') into v_partner_accepted;
  if new.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery')
    and v_partner_accepted and new.assigned_rider_id is null then
    raise check_violation using message='Assign a partner-company rider before scheduling or progressing this pickup';
  end if;
  if tg_op='UPDATE' and new.status='exception'
    and old.status in ('pickup_scheduled','picked_up','in_transit','out_for_delivery')
    and v_partner_accepted and new.assigned_rider_id is null then
    raise check_violation using message='Keep the assigned rider on an active delivery exception until it is resolved';
  end if;
  if new.assigned_rider_id is null then return new; end if;
  if new.partner_id is null or not exists(select 1 from public.partner_users pu
    where pu.partner_id=new.partner_id and pu.user_id=new.assigned_rider_id
      and pu.membership_role='rider') then
    raise check_violation using message='Choose a rider who belongs to the assigned partner company';
  end if;
  perform 1 from auth.users u where u.id=new.assigned_rider_id for update;
  v_new_assignment:=tg_op='INSERT';
  if tg_op='UPDATE' then v_new_assignment:=new.assigned_rider_id is distinct from old.assigned_rider_id; end if;
  if v_new_assignment then
    select rc.load_state into v_load_state from public.rider_credentials rc
      where rc.user_id=new.assigned_rider_id for update;
    if v_load_state='full' then
      raise check_violation using message='This rider marked their box Full. Choose another rider.';
    end if;
  end if;
  return new;
end $$;
