begin;

-- Read-only integration checks: do not send a ride alert from a test.
do $$
begin
  if not exists(select 1 from cron.job where jobname='kwik-parsel-ride-event-push' and active) then
    raise exception 'Ride push worker is not scheduled';
  end if;
  if not exists(select 1 from pg_trigger where tgname='company_ride_push' and tgenabled='O')
    or not exists(select 1 from pg_trigger where tgname='customer_match_push' and tgenabled='O')
    or not exists(select 1 from pg_trigger where tgname='rider_assignment_push' and tgenabled='O') then
    raise exception 'A ride alert event trigger is missing';
  end if;
  if not (select relrowsecurity from pg_class where oid='public.ride_push_devices'::regclass)
    or not (select relrowsecurity from pg_class where oid='public.ride_push_deliveries'::regclass) then
    raise exception 'Ride push private tables require RLS';
  end if;
  if to_regprocedure('public.register_ride_push_device(uuid,text,text)') is null
    or to_regprocedure('public.claim_ride_push_deliveries(integer)') is null then
    raise exception 'Ride push registration or delivery claim is missing';
  end if;
end $$;

-- Anonymous clients cannot register a phone or pull the private FCM queue.
do $$
begin
  perform set_config('request.jwt.claim.role','anon',true);
  begin
    perform public.register_ride_push_device(gen_random_uuid(),repeat('a',100),'rider');
    raise exception 'Anonymous phone registration unexpectedly succeeded';
  exception when check_violation or insufficient_privilege then null;
  end;
  begin
    perform public.claim_ride_push_deliveries(1);
    raise exception 'Anonymous queue claim unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;
end $$;

rollback;
