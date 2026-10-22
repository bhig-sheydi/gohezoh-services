-- Resume requests that reached the old 30-attempt stop before persistent search.
insert into public.dispatch_match_queue(request_id,next_attempt_at)
select r.id,now() from public.service_requests r
where r.dispatch_match_status='no_nearby' and r.status in ('submitted','under_review')
  and r.pickup_latitude is not null
on conflict(request_id) do update set next_attempt_at=excluded.next_attempt_at;
update public.service_requests set dispatch_match_status='waiting'
where dispatch_match_status='no_nearby' and status in ('submitted','under_review')
  and pickup_latitude is not null;
