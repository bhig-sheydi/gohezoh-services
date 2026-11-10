begin;

do $$
begin
  if not exists(select 1 from cron.job where jobname='kwik-parsel-rider-response' and active) then
    raise exception 'Rider response timeout worker is not scheduled';
  end if;
  if not exists(select 1 from pg_trigger where tgname='track_rider_assignment_response' and tgenabled='O')
    or not exists(select 1 from pg_trigger where tgname='require_rider_response_before_pickup' and tgenabled='O') then
    raise exception 'Rider response guards are missing';
  end if;
  if not (select relrowsecurity from pg_class where oid='public.rider_assignment_responses'::regclass) then
    raise exception 'Rider responses must be private';
  end if;
  if to_regprocedure('public.accept_rider_assignment(uuid)') is null
    or to_regprocedure('public.resolve_missed_rider_assignments()') is null
    or to_regprocedure('public.my_current_delivery_rider(uuid)') is null then
    raise exception 'Rider response, reroute, or customer tracking function missing';
  end if;
  perform set_config('request.jwt.claim.role','anon',true);
  begin
    perform public.accept_rider_assignment(gen_random_uuid());
    raise exception 'Anonymous rider acceptance unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;
end $$;

rollback;
