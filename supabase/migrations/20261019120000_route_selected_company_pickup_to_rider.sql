-- The rider invited for the chosen company can prepare for pickup, but may not
-- start work or see the customer's contact details until the paid award is accepted.
create function public.list_my_selected_pickups()
returns table(request_id uuid, request_number text, pickup_city text,
  delivery_city text, parcel_summary text, company_name text, selected_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.rider_session_active() then
    raise insufficient_privilege using message='Rider access required';
  end if;
  return query
    select r.id,r.request_number,r.pickup_city,r.delivery_city,r.parcel_summary,
      p.partner_name,cq.created_at
    from public.customer_delivery_quotes cq
    join public.partner_quotes q on q.id=cq.winning_bid_id and q.request_id=cq.request_id and q.status='selected'
    join public.company_bid_invitations i on i.request_id=cq.request_id
      and i.partner_id=q.partner_id and i.rider_id=auth.uid()
    join public.service_requests r on r.id=cq.request_id
    join public.logistics_partners p on p.id=q.partner_id and p.status='active'
    join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=q.partner_id
      and rc.revoked_at is null and rc.password_revoked_at is null
    join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
    where cq.status in ('pending_price','sent','accepted')
      and r.status not in ('rejected','cancelled')
      and not exists (
        select 1 from public.jobs j join public.orders o on o.id=j.order_id
        join public.partner_assignments pa on pa.job_id=j.id and pa.status in ('accepted','completed')
        where o.service_request_id=r.id
      )
    order by cq.created_at desc limit 50;
end $$;
revoke all on function public.list_my_selected_pickups() from public,anon;
grant execute on function public.list_my_selected_pickups() to authenticated;

-- When the selected company accepts the funded award, assign its invited rider
-- automatically if still approved. The ordinary job guard checks capacity.
create function public.assign_selected_pickup_rider_on_acceptance()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_rider uuid;
begin
  if new.status<>'accepted' or (tg_op='UPDATE' and old.status='accepted') then return new; end if;
  select i.rider_id into v_rider
  from public.jobs j
  join public.orders o on o.id=j.order_id
  join public.customer_delivery_quotes cq on cq.request_id=o.service_request_id and cq.status='accepted'
  join public.partner_quotes q on q.id=cq.winning_bid_id and q.partner_id=new.partner_id
  join public.company_bid_invitations i on i.request_id=o.service_request_id and i.partner_id=new.partner_id
  join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=new.partner_id
    and rc.revoked_at is null and rc.password_revoked_at is null
  join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
  join public.partner_users pu on pu.user_id=i.rider_id and pu.partner_id=new.partner_id and pu.membership_role='rider'
  where j.id=new.job_id and j.partner_id=new.partner_id and j.assigned_rider_id is null
    and j.status in ('partner_assigned','pickup_scheduled');
  if v_rider is not null then
    update public.jobs set assigned_rider_id=v_rider
      where id=new.job_id and assigned_rider_id is null;
  end if;
  return new;
exception when check_violation then
  -- A rider may have reached their pickup limit since bidding. The company
  -- can assign another approved rider in its existing dispatch workspace.
  return new;
end $$;
revoke all on function public.assign_selected_pickup_rider_on_acceptance() from public,anon,authenticated;
create trigger route_selected_pickup_rider_on_acceptance
after insert or update of status on public.partner_assignments
for each row execute function public.assign_selected_pickup_rider_on_acceptance();
