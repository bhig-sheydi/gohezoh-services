-- Durable, idempotent job queue. Quote-window expiry is the first job type;
-- delivery is transactional with publication/reopening of the quote window.
create table public.durable_jobs (
  id uuid primary key default gen_random_uuid(),
  job_type text not null check (length(btrim(job_type)) between 1 and 100),
  payload jsonb not null default '{}'::jsonb,
  idempotency_key text not null unique check (length(btrim(idempotency_key)) between 1 and 240),
  status text not null default 'pending' check (status in ('pending','running','completed','dead','cancelled')),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 8 check (max_attempts between 1 and 20),
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  locked_by text,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);
create index durable_jobs_due_idx on public.durable_jobs(available_at,created_at)
  where status='pending';
alter table public.durable_jobs enable row level security;
revoke all on public.durable_jobs from public,anon,authenticated;
grant all on public.durable_jobs to service_role;

create or replace function public.enqueue_durable_job(
  p_job_type text,p_payload jsonb,p_idempotency_key text,p_available_at timestamptz default now()
)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_id uuid;
begin
  if nullif(btrim(p_job_type),'') is null or nullif(btrim(p_idempotency_key),'') is null then
    raise check_violation using message='Job type and idempotency key are required';
  end if;
  insert into public.durable_jobs(job_type,payload,idempotency_key,available_at)
  values(btrim(p_job_type),coalesce(p_payload,'{}'::jsonb),btrim(p_idempotency_key),coalesce(p_available_at,now()))
  on conflict(idempotency_key) do update set id=durable_jobs.id
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.enqueue_durable_job(text,jsonb,text,timestamptz) from public,anon,authenticated;
grant execute on function public.enqueue_durable_job(text,jsonb,text,timestamptz) to service_role;

create or replace function public.enqueue_quote_window_expiry()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.status='open' and (tg_op='INSERT' or old.status is distinct from new.status or old.deadline_at is distinct from new.deadline_at) then
    update public.durable_jobs set status='cancelled',updated_at=now(),last_error='Superseded by a newer quote-window deadline'
      where job_type='quote_window_expiry' and payload->>'request_id'=new.request_id::text and status='pending';
    perform public.enqueue_durable_job(
      'quote_window_expiry',
      jsonb_build_object('request_id',new.request_id,'deadline_at',new.deadline_at),
      'quote-window-expiry:'||new.request_id::text||':'||extract(epoch from new.deadline_at)::bigint::text,
      new.deadline_at
    );
  elsif new.status<>'open' then
    update public.durable_jobs set status='cancelled',updated_at=now(),last_error='Quote window is no longer open'
      where job_type='quote_window_expiry' and payload->>'request_id'=new.request_id::text and status='pending';
  end if;
  return new;
end $$;
revoke all on function public.enqueue_quote_window_expiry() from public,anon,authenticated;
create trigger delivery_quote_window_enqueue_expiry
  after insert or update of status,deadline_at on public.delivery_quote_windows
  for each row execute function public.enqueue_quote_window_expiry();

create or replace function public.process_due_durable_jobs(p_limit integer default 100)
returns table(processed integer,retried integer,dead_lettered integer)
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.durable_jobs%rowtype;v_request_id uuid;v_status text;v_deadline timestamptz;v_attempt integer;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user not in ('postgres','supabase_admin') then
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

do $$
declare v_job_id bigint;
begin
  select jobid into v_job_id from cron.job where jobname='gohezoh-close-delivery-quotes';
  if v_job_id is not null then perform cron.unschedule(v_job_id);end if;
end $$;
select cron.schedule('gohezoh-process-durable-jobs','* * * * *','select * from public.process_due_durable_jobs(100)');

comment on table public.durable_jobs is 'Private idempotent retry queue for scheduled backend work. External messages are not considered sent until a provider-backed handler confirms delivery.';
