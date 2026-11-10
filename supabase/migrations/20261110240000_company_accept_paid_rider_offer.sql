-- A company actor may accept an offer, but service-role-only route-planner
-- functions must remain inaccessible to that actor. Recheck the paid job,
-- fresh rider presence, roster and capacity directly at the acceptance point.
create or replace function public.respond_paid_reassignment_offer(p_offer uuid,p_accept boolean) returns boolean
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_offer public.paid_reassignment_offers%rowtype; v_job public.jobs%rowtype;
  v_request uuid; v_previous uuid;
begin
  select * into v_offer from public.paid_reassignment_offers where id=p_offer for update;
  if not found or not public.company_staff_allowed(v_offer.partner_id,'bid') then
    raise insufficient_privilege using message='Company bidding access required'; end if;
  if v_offer.status<>'pending' or v_offer.expires_at<=now() then return false; end if;
  select * into v_job from public.jobs where id=v_offer.job_id for update;
  if not found or v_job.assigned_rider_id is not null
    or v_job.status not in ('partner_assigned','pickup_scheduled') then return false; end if;
  select o.service_request_id into v_request from public.orders o where o.id=v_job.order_id;
  if not p_accept then
    update public.paid_reassignment_offers set status='declined',responded_at=now() where id=p_offer;
    insert into public.route_planner_events(request_id,event_kind,idempotency_key)
      values(v_request,'paid_reassignment','paid-declined:'||p_offer::text)
      on conflict(idempotency_key) do nothing;
    return true;
  end if;
  if not exists(select 1 from public.customer_payments cp where cp.job_id=v_job.id
      and cp.status='received' and cp.currency='NGN')
    or exists(select 1 from public.pickup_handoff_codes h where h.job_id=v_job.id and h.verified_at is not null)
    or exists(select 1 from public.rider_assignment_responses r
      where r.job_id=v_job.id and r.rider_id=v_offer.rider_id)
    or not exists(select 1 from public.partner_corridor_coverage c
      join public.delivery_quote_windows w on w.corridor_id=c.corridor_id
      where w.request_id=v_request and c.partner_id=v_offer.partner_id and c.is_enabled and c.capacity_available)
    or not exists(select 1 from public.rider_presence rp
      join public.rider_credentials rc on rc.user_id=rp.user_id and rc.partner_id=rp.partner_id
      join public.company_riders cr on cr.id=rc.roster_id and cr.status='approved'
      join public.partner_users pu on pu.user_id=rp.user_id and pu.partner_id=rp.partner_id and pu.membership_role='rider'
      where rp.user_id=v_offer.rider_id and rp.partner_id=v_offer.partner_id
        and rp.received_at>now()-interval '2 minutes' and rp.captured_at>now()-interval '2 minutes'
        and rp.accuracy_metres<=100 and rc.revoked_at is null and rc.password_revoked_at is null
        and rc.load_state<>'full' and public.rider_has_parcel_slot(rp.user_id)) then return false; end if;
  v_previous:=v_job.partner_id;
  update public.paid_reassignment_offers set status='accepted',responded_at=now() where id=p_offer;
  update public.partner_assignments set status='cancelled',response_note='Rider did not respond; paid job reoffered'
    where job_id=v_job.id and status='accepted';
  insert into public.partner_assignments(job_id,partner_id,status,responded_at,response_note)
    values(v_job.id,v_offer.partner_id,'accepted',now(),'Accepted paid replacement at fixed payout');
  update public.jobs set partner_id=v_offer.partner_id,assigned_rider_id=v_offer.rider_id,
    status='partner_assigned',route_assignment_issue=null where id=v_job.id;
  perform public.notify_customer_users(v_job.customer_id,v_job.id,
    'rider_assignment_changed','New company and rider assigned',
    'Another company accepted your paid pickup. Open tracking to see your new rider.',
    jsonb_build_object('replacement_rider_id',v_offer.rider_id,'partner_id',v_offer.partner_id));
  insert into public.notifications(user_id,job_id,event_type,channel,title,body,payload,status,sent_at)
    select pu.user_id,v_job.id,'rider_reassigned','in_app','Paid job moved to another company',
      'No rider responded in time. Another company accepted the same paid pickup; this job is no longer in your pending balance.',
      jsonb_build_object('new_partner_id',v_offer.partner_id),'delivered',now()
    from public.partner_users pu where pu.partner_id=v_previous and pu.membership_role='manager';
  return true;
end $$;
