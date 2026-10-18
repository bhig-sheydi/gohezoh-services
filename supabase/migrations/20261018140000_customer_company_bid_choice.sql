-- Customers choose among valid company bids after the one-minute window.
-- The partner bid remains a direct cost; Management still approves the customer price.
alter table public.delivery_quote_windows drop constraint delivery_quote_windows_status_check;
alter table public.delivery_quote_windows add constraint delivery_quote_windows_status_check
  check (status in ('open','awaiting_customer_selection','quoted','tie_review','no_bids','cancelled'));

alter table public.company_riders add column phone text
  check (phone is null or phone ~ '^\+?[0-9]{10,15}$');

create function public.set_company_rider_phone(p_rider_id uuid,p_phone text) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if p_phone !~ '^\+?[0-9]{10,15}$' then
    raise check_violation using message='Enter a valid rider phone number';
  end if;
  update public.company_riders r set phone=p_phone
  where r.id=p_rider_id and r.status<>'archived' and exists (
    select 1 from public.partner_users pu join public.logistics_partners p on p.id=pu.partner_id
    where pu.partner_id=r.partner_id and pu.user_id=auth.uid()
      and pu.membership_role='manager' and p.status='active');
  if not found then raise insufficient_privilege using message='Company manager access required'; end if;
end $$;
revoke all on function public.set_company_rider_phone(uuid,text) from public,anon;
grant execute on function public.set_company_rider_phone(uuid,text) to authenticated;

create or replace function public.close_delivery_quote_window(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_window public.delivery_quote_windows%rowtype; v_count integer;
begin
  if not (public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management'))
    and current_setting('gohezoh.quote_worker',true) is distinct from 'on' then
    raise insufficient_privilege using message='Only authorized staff can close bids'; end if;
  select * into v_window from public.delivery_quote_windows where request_id=p_request_id for update;
  if not found or v_window.status<>'open' then raise object_not_in_prerequisite_state using message='Window is not open'; end if;
  if now()<v_window.deadline_at then raise object_not_in_prerequisite_state using message='Quote deadline has not passed'; end if;
  select count(*) into v_count from public.partner_quotes q
  where q.request_id=p_request_id and q.status='valid' and q.submitted_at<v_window.deadline_at;
  if v_count=0 then
    update public.delivery_quote_windows set status='no_bids',closed_at=now() where request_id=p_request_id;
    return jsonb_build_object('status','no_bids');
  end if;
  update public.delivery_quote_windows set status='awaiting_customer_selection',closed_at=now()
  where request_id=p_request_id;
  return jsonb_build_object('status','awaiting_customer_selection','company_count',v_count);
end $$;

create function public.list_customer_bid_offers(p_request_id uuid)
returns table(bid_id uuid,partner_name text,partner_phone text,rider_name text,
  rider_phone text,rider_photo_path text,bid_amount_ngn numeric,eta_hours integer)
language sql stable security definer set search_path=pg_catalog,public as $$
  select q.id,p.partner_name,p.phone,cr.full_name,cr.phone,
    case when cr.photo_path ~* '[.](jpg|jpeg|png|webp)$' then cr.photo_path else null end,
    q.amount_ngn,q.eta_hours
  from public.service_requests r
  join public.delivery_quote_windows w on w.request_id=r.id and now()>=w.deadline_at
    and w.status in ('open','awaiting_customer_selection','quoted')
  join public.partner_quotes q on q.request_id=r.id and q.status in ('valid','selected')
    and q.submitted_at<w.deadline_at
  join public.logistics_partners p on p.id=q.partner_id and p.status='active'
  left join public.company_bid_invitations i on i.request_id=r.id and i.partner_id=q.partner_id
  left join public.rider_credentials rc on rc.user_id=i.rider_id and rc.partner_id=q.partner_id
    and rc.revoked_at is null and rc.password_revoked_at is null
  left join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
  where r.id=p_request_id and public.is_customer_user(r.customer_id)
  order by q.amount_ngn,q.submitted_at,q.id;
$$;
revoke all on function public.list_customer_bid_offers(uuid) from public,anon;
grant execute on function public.list_customer_bid_offers(uuid) to authenticated;

create function public.select_customer_partner_bid(p_request_id uuid,p_bid_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_window public.delivery_quote_windows%rowtype; v_bid public.partner_quotes%rowtype;
begin
  select * into v_window from public.delivery_quote_windows where request_id=p_request_id for update;
  if not found or v_window.status not in ('open','awaiting_customer_selection')
    or now()<v_window.deadline_at then
    raise object_not_in_prerequisite_state using message='Company selection is not available yet'; end if;
  if not exists(select 1 from public.service_requests r where r.id=p_request_id
    and public.is_customer_user(r.customer_id)) then raise insufficient_privilege; end if;
  select q.* into v_bid from public.partner_quotes q
    join public.logistics_partners p on p.id=q.partner_id and p.status='active'
    where q.id=p_bid_id and q.request_id=p_request_id and q.status='valid'
      and q.submitted_at<v_window.deadline_at for update of q;
  if not found then raise check_violation using message='Choose an available company bid'; end if;
  if exists(select 1 from public.customer_delivery_quotes where request_id=p_request_id) then
    raise object_not_in_prerequisite_state using message='A company has already been chosen'; end if;
  update public.partner_quotes set status='selected' where id=v_bid.id;
  update public.delivery_quote_windows set status='quoted',closed_at=now() where request_id=p_request_id;
  insert into public.customer_delivery_quotes(request_id,winning_bid_id,total_direct_cost_ngn,unrounded_price_ngn)
  values(p_request_id,v_bid.id,v_bid.amount_ngn,round(v_bid.amount_ngn/0.75,4));
end $$;
revoke all on function public.select_customer_partner_bid(uuid,uuid) from public,anon;
grant execute on function public.select_customer_partner_bid(uuid,uuid) to authenticated;

create policy rider_photo_customer_bid_read on storage.objects for select to authenticated using (
  bucket_id='rider-evidence' and exists (
    select 1 from public.company_riders cr
    join public.rider_credentials rc on rc.roster_id=cr.id and rc.partner_id=cr.partner_id
    join public.company_bid_invitations i on i.rider_id=rc.user_id and i.partner_id=cr.partner_id
    join public.delivery_quote_windows w on w.request_id=i.request_id and now()>=w.deadline_at
      and w.status in ('open','awaiting_customer_selection','quoted')
    join public.service_requests r on r.id=w.request_id
    join public.partner_quotes q on q.request_id=r.id and q.partner_id=cr.partner_id
      and q.status in ('valid','selected') and q.submitted_at<w.deadline_at
    where cr.photo_path=name and cr.status='approved' and public.is_customer_user(r.customer_id)
  )
);
