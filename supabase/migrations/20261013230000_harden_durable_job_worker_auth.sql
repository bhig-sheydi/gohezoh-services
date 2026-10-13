-- Explicit JWT roles must be honored even when SQL tests connect as a database owner.
create or replace function public.process_due_durable_jobs(p_limit integer default 100)
returns table(processed integer,retried integer,dead_lettered integer)
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.durable_jobs%rowtype;v_request_id uuid;v_status text;v_deadline timestamptz;v_attempt integer;v_caller_role text:=auth.role();
begin
  if (v_caller_role is not null and v_caller_role<>'service_role')
    or (v_caller_role is null and session_user not in ('postgres','supabase_admin')) then
    raise insufficient_privilege using message='Durable job processing is restricted to trusted workers';
  end if;
  if p_limit is null or p_limit<1 or p_limit>500 then
    raise check_violation using message='Batch size must be between 1 and 500';
  end if;
  processed:=0;retried:=0;dead_lettered:=0;
  for v_job in
    select * from public.durable_jobs where status='pending' and available_at<=now()
    order by available_at,created_at for update skip locked limit p_limit
  loop
    v_attempt:=v_job.attempts+1;
    update public.durable_jobs set status='running',attempts=v_attempt,locked_at=now(),locked_by='pg_cron',updated_at=now()
      where id=v_job.id;
    begin
      if v_job.job_type='quote_window_expiry' then
        v_request_id:=nullif(v_job.payload->>'request_id','')::uuid;
        select status,deadline_at into v_status,v_deadline from public.delivery_quote_windows where request_id=v_request_id for update;
        if found and v_status='open' and v_deadline<=now() then
          perform set_config('gohezoh.quote_worker','on',true);
          perform public.close_delivery_quote_window(v_request_id);
        end if;
      else
        raise exception 'Unsupported durable job type: %',v_job.job_type using errcode='0A000';
      end if;
      update public.durable_jobs set status='completed',locked_at=null,locked_by=null,last_error=null,
        completed_at=now(),updated_at=now() where id=v_job.id;
      processed:=processed+1;
    exception when others then
      update public.durable_jobs set
        status=case when v_attempt>=max_attempts then 'dead' else 'pending' end,
        available_at=case when v_attempt>=max_attempts then available_at else now()+make_interval(secs=>least(21600,30*(2^least(v_attempt,10))::integer)) end,
        locked_at=null,locked_by=null,last_error=left(sqlerrm,1000),updated_at=now()
        where id=v_job.id;
      if v_attempt>=v_job.max_attempts then dead_lettered:=dead_lettered+1;else retried:=retried+1;end if;
    end;
  end loop;
  return next;
end $$;
revoke all on function public.process_due_durable_jobs(integer) from public,anon,authenticated;
grant execute on function public.process_due_durable_jobs(integer) to service_role;
