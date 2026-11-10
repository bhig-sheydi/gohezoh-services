-- A fixed-price bike offer is visible immediately; other bids become visible at window close.
create or replace function public.enqueue_customer_match_push() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.status<>'valid' then return new; end if;
  insert into public.ride_push_deliveries(device_id,event_type,source_id,next_attempt_at,expires_at)
  select d.id,'customer_match',new.request_id,
    case when bp.request_id is not null then now() else greatest(now(),w.deadline_at) end,
    greatest(now(),w.deadline_at)+interval '24 hours'
  from public.ride_push_devices d join public.customer_users cu on cu.user_id=d.user_id
    join public.service_requests r on r.customer_id=cu.customer_id and r.id=new.request_id
    join public.delivery_quote_windows w on w.request_id=r.id
    left join public.bike_route_prices bp on bp.request_id=r.id
  where d.kind='customer' and d.last_seen_at>now()-interval '30 days'
    and w.status in ('open','awaiting_customer_selection','quoted')
    and not exists(select 1 from public.customer_delivery_quotes q where q.request_id=new.request_id)
  on conflict(device_id,event_type,source_id) do update
    set next_attempt_at=least(public.ride_push_deliveries.next_attempt_at,excluded.next_attempt_at),
      expires_at=greatest(public.ride_push_deliveries.expires_at,excluded.expires_at);
  return new;
end $$;
