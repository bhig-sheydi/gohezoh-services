begin;
do $$
declare
  v_id uuid;v_duplicate uuid;v_job public.durable_jobs%rowtype;v_processed integer;v_retried integer;v_dead integer;v_deleted integer;
  v_user uuid:=gen_random_uuid();v_customer uuid;v_service uuid;v_request uuid;v_expiry_request uuid;v_corridor uuid;v_deadline timestamptz;
begin
  if not exists(select 1 from cron.job where jobname='gohezoh-process-durable-jobs' and schedule='* * * * *') then
    raise exception 'The durable job scheduler is not configured';
  end if;
  if not exists(select 1 from cron.job where jobname='gohezoh-prune-durable-jobs' and schedule='30 3 * * *') then
    raise exception 'Durable job retention cleanup is not scheduled';
  end if;
  if has_table_privilege('authenticated','public.durable_jobs','select') then
    raise exception 'Authenticated users can read the private durable job queue';
  end if;
  v_id:=public.enqueue_durable_job('test_transient_failure','{}'::jsonb,'durable-test-idempotency',now()-interval '1 second');
  v_duplicate:=public.enqueue_durable_job('test_transient_failure','{"changed":true}'::jsonb,'durable-test-idempotency',now());
  if v_id is distinct from v_duplicate or (select count(*) from public.durable_jobs where idempotency_key='durable-test-idempotency')<>1 then
    raise exception 'Idempotency key did not prevent duplicate work';
  end if;
  insert into public.durable_jobs(job_type,payload,idempotency_key,status,created_at)
    values('test_retention','{}','durable-test-expired','completed',now()-interval '120 days');
  v_deleted:=public.prune_durable_jobs();
  if v_deleted<>1 or exists(select 1 from public.durable_jobs where idempotency_key='durable-test-expired') then
    raise exception 'Expired completed jobs were not pruned (deleted %, still exists %)',v_deleted,exists(select 1 from public.durable_jobs where idempotency_key='durable-test-expired');
  end if;

  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values(v_user,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','durable-queue-'||v_user||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.customers(company_name,contact_person,phone,status) values('Durable Queue Test','Test Contact','08000000001','active') returning id into v_customer;
  select id into v_service from public.services where code='SRV-0001';
  select c.id into v_corridor from public.coverage_corridors c
    join public.coverage_locations origin on origin.id=c.origin_id
    join public.coverage_locations destination on destination.id=c.destination_id
    where c.service_code='SRV-0001' and origin.name='Lagos' and destination.name='Lagos';
  if v_service is null or v_corridor is null then raise exception 'Local delivery test fixtures are missing';end if;
  insert into public.service_requests(customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,
    delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_customer,v_service,v_user,'Pickup','Lagos','Sender','08000000002','Delivery','Lagos','Recipient','08000000003') returning id into v_request;
  v_deadline:=now()+interval '1 hour';
  insert into public.delivery_quote_windows(request_id,corridor_id,published_at,deadline_at)
    values(v_request,v_corridor,now(),v_deadline);
  if not exists(select 1 from public.durable_jobs where job_type='quote_window_expiry' and status='pending'
      and payload->>'request_id'=v_request::text and available_at=v_deadline) then
    raise exception 'Publishing a quote window did not enqueue its durable expiry job';
  end if;
  update public.delivery_quote_windows set deadline_at=v_deadline+interval '1 hour' where request_id=v_request;
  if (select count(*) from public.durable_jobs where job_type='quote_window_expiry' and payload->>'request_id'=v_request::text and status='pending')<>1
    or not exists(select 1 from public.durable_jobs where job_type='quote_window_expiry' and payload->>'request_id'=v_request::text and status='cancelled') then
    raise exception 'Reopening a quote window did not replace its pending expiry job';
  end if;
  update public.delivery_quote_windows set status='no_bids' where request_id=v_request;
  if exists(select 1 from public.durable_jobs where job_type='quote_window_expiry' and payload->>'request_id'=v_request::text and status='pending') then
    raise exception 'A closed quote window retained a pending expiry job';
  end if;

  insert into public.service_requests(customer_id,service_id,created_by,pickup_address,pickup_city,sender_name,sender_phone,
    delivery_address,delivery_city,recipient_name,recipient_phone)
    values(v_customer,v_service,v_user,'Pickup','Lagos','Sender','08000000002','Delivery','Lagos','Recipient','08000000003') returning id into v_expiry_request;
  insert into public.delivery_quote_windows(request_id,corridor_id,published_at,deadline_at)
    values(v_expiry_request,v_corridor,now()-interval '3 hours',now()-interval '1 hour');

  select processed,retried,dead_lettered into v_processed,v_retried,v_dead from public.process_due_durable_jobs(10);
  select * into v_job from public.durable_jobs where id=v_id;
  if v_processed<>1 or v_retried<>1 or v_dead<>0 or v_job.status<>'pending' or v_job.attempts<>1
    or v_job.last_error not like 'Unsupported durable job type:%' or v_job.available_at<=now() then
    raise exception 'Retryable job failure did not receive a delayed retry';
  end if;
  if not exists(select 1 from public.delivery_quote_windows where request_id=v_expiry_request and status='no_bids')
    or not exists(select 1 from public.durable_jobs where job_type='quote_window_expiry' and payload->>'request_id'=v_expiry_request::text and status='completed') then
    raise exception 'Durable quote expiry did not close its due window';
  end if;

  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claims','{"role":"authenticated"}',true);
  begin
    perform * from public.process_due_durable_jobs(10);
    raise exception 'Authenticated caller processed backend jobs';
  exception when insufficient_privilege then null;
  end;
end $$;
rollback;
