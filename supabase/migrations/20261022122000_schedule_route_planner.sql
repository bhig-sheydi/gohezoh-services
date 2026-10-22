-- One cheap queue check per minute; invoke the worker only when work is due.
create extension if not exists pg_net with schema extensions;

create function public.invoke_due_route_planner() returns void
language plpgsql security definer set search_path=pg_catalog,public,net,vault as $$
declare v_secret text;
begin
  if not exists (
    select 1 from public.route_planner_events
    where (status='pending' and available_at<=now())
       or (status='running' and updated_at<now()-interval '2 minutes' and attempts<5)
  ) then return; end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets
    where name='route_worker_secret' order by created_at desc limit 1;
  if v_secret is null then raise exception 'Route worker credential is not configured'; end if;
  perform net.http_post(
    url:='https://yejiqfocqmdxjeajoexd.supabase.co/functions/v1/route-planner',
    headers:=jsonb_build_object('Content-Type','application/json','x-route-worker-secret',v_secret),
    body:='{}'::jsonb,
    timeout_milliseconds:=10000
  );
end $$;
revoke all on function public.invoke_due_route_planner() from public,anon,authenticated;
select cron.schedule('kwik-parsel-route-planner','* * * * *',
  'select public.invoke_due_route_planner()');
