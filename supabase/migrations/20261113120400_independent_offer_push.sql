alter table public.ride_push_deliveries drop constraint ride_push_deliveries_event_type_check;
alter table public.ride_push_deliveries add constraint ride_push_deliveries_event_type_check
  check(event_type in ('company_invitation','rider_assignment','customer_match','company_reassignment_offer','rider_missed','independent_offer'));

create function public.enqueue_independent_offer_push() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if exists(select 1 from public.company_riders cr where cr.independent_user_id=new.rider_id
    and cr.partner_id=new.partner_id and cr.status='approved') then
    insert into public.ride_push_deliveries(device_id,event_type,source_id,next_attempt_at,expires_at)
    select d.id,'independent_offer',new.request_id,greatest(now(),new.starts_at),new.deadline_at
    from public.ride_push_devices d
    where d.user_id=new.rider_id and d.kind='rider' and d.last_seen_at>now()-interval '30 days'
      and new.deadline_at>now()
    on conflict(device_id,event_type,source_id) do update
      set next_attempt_at=excluded.next_attempt_at,expires_at=excluded.expires_at,
        status=case when public.ride_push_deliveries.status='dead' then 'pending'
          else public.ride_push_deliveries.status end;
  end if;
  return new;
end $$;
create trigger independent_offer_push after insert or update of starts_at,deadline_at
  on public.company_bid_invitations for each row execute function public.enqueue_independent_offer_push();
revoke all on function public.enqueue_independent_offer_push() from public,anon,authenticated;
