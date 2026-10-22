begin;
do $$
declare v_rider uuid:=gen_random_uuid();v_partner uuid:=gen_random_uuid();v_version bigint;
begin
  -- A public session cannot inspect candidate locations or reserve API spend.
  perform set_config('request.jwt.claim.role','authenticated',true);
  begin
    perform public.route_planner_candidates(gen_random_uuid());
    raise exception 'Candidate discovery leaked to an authenticated client';
  exception when insufficient_privilege then null; end;
  begin
    perform public.reserve_route_matrix_credits(1);
    raise exception 'Client reserved routing budget';
  exception when insufficient_privilege then null; end;
  begin
    perform public.commit_rider_route_plan(v_rider,0,'[]'::jsonb,'road');
    raise exception 'Client committed a route';
  exception when insufficient_privilege then null; end;
  begin
    perform public.claim_route_planner_events(1);
    raise exception 'Client claimed route queue work';
  exception when insufficient_privilege then null; end;
  begin
    perform public.upsert_dispatch_route_proposal(gen_random_uuid(),v_partner,v_rider,
      'available','test',0,'{}'::jsonb,now()+interval '1 minute');
    raise exception 'Client stored a route proposal';
  exception when insufficient_privilege then null; end;

  perform set_config('request.jwt.claim.role','service_role',true);
  if public.reserve_route_matrix_credits(1490) then
    raise exception 'Oversized single reservation was accepted';
  end if;
exception when check_violation then
  -- p_credits >100 must fail closed.
  null;
end $$;

do $$
declare v_i integer;
begin
  perform set_config('request.jwt.claim.role','service_role',true);
  insert into public.route_matrix_daily_budget(budget_day,credits_reserved)
    values((now() at time zone 'UTC')::date,0)
    on conflict(budget_day) do update set credits_reserved=0;
  for v_i in 1..15 loop
    if not public.reserve_route_matrix_credits(100) then
      raise exception 'Expected reservation % to succeed',v_i;
    end if;
  end loop;
  if public.reserve_route_matrix_credits(1) then
    raise exception 'Routing daily cap was exceeded';
  end if;
  if (select credits_reserved from public.route_matrix_daily_budget
      where budget_day=(now() at time zone 'UTC')::date)<>1500 then
    raise exception 'Unexpected routing budget total';
  end if;
end $$;

do $$
begin
  if not exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='jobs'
        and t.tgname='jobs_enqueue_route_replan' and t.tgenabled='O') then
    raise exception 'Job changes do not enqueue route replans';
  end if;
  if not exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='rider_presence'
        and t.tgname='rider_presence_enqueue_material_replan' and t.tgenabled='O') then
    raise exception 'Material rider movement does not enqueue route replans';
  end if;
  if has_function_privilege('authenticated',
      'public.claim_route_planner_events(integer)','EXECUTE')
    or has_function_privilege('authenticated',
      'public.rider_route_context(uuid)','EXECUTE') then
    raise exception 'Routing worker RPC leaked to clients';
  end if;
  if not exists(select 1 from cron.job where jobname='kwik-parsel-route-planner' and active) then
    raise exception 'Route planner retry schedule is not active';
  end if;
end $$;
rollback;
