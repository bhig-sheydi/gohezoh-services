-- Create private in-app customer notifications from request and delivery events.

alter table public.notifications
  add column read_at timestamptz;

create index notifications_unread_user_created_idx
  on public.notifications(user_id, created_at desc)
  where read_at is null;

create or replace function public.notify_customer_users(
  p_customer_id uuid,
  p_job_id uuid,
  p_event_type text,
  p_title text,
  p_body text,
  p_payload jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  insert into public.notifications(user_id, job_id, event_type, channel, title, body, payload, status, sent_at)
  select cu.user_id, p_job_id, p_event_type, 'in_app', p_title, p_body,
         coalesce(p_payload, '{}'::jsonb), 'delivered', now()
  from public.customer_users cu
  where cu.customer_id = p_customer_id;
$$;

revoke all on function public.notify_customer_users(uuid, uuid, text, text, text, jsonb)
  from public, anon, authenticated;

create or replace function public.notify_service_request_event()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' and new.status = 'submitted' then
    perform public.notify_customer_users(
      new.customer_id, null, 'service_request_received', 'Request received',
      format('Request %s was sent to Gohezoh Operations for review.', new.request_number),
      jsonb_build_object('request_id', new.id, 'request_number', new.request_number)
    );
  elsif (tg_op = 'INSERT' or new.status is distinct from old.status) and new.status = 'under_review' then
    perform public.notify_customer_users(
      new.customer_id, null, 'service_request_under_review', 'Request under review',
      format('Gohezoh Operations is reviewing request %s.', new.request_number),
      jsonb_build_object('request_id', new.id, 'request_number', new.request_number)
    );
  elsif (tg_op = 'INSERT' or new.status is distinct from old.status) and new.status = 'rejected' then
    perform public.notify_customer_users(
      new.customer_id, null, 'service_request_rejected', 'Request not accepted',
      format('Request %s could not be accepted. Sign in to review the request details.', new.request_number),
      jsonb_build_object('request_id', new.id, 'request_number', new.request_number)
    );
  elsif (tg_op = 'INSERT' or new.status is distinct from old.status) and new.status = 'cancelled' then
    perform public.notify_customer_users(
      new.customer_id, null, 'service_request_cancelled', 'Request cancelled',
      format('Request %s has been cancelled.', new.request_number),
      jsonb_build_object('request_id', new.id, 'request_number', new.request_number)
    );
  end if;
  return new;
end;
$$;

create trigger service_request_customer_notification_insert
  after insert on public.service_requests
  for each row execute function public.notify_service_request_event();
create trigger service_request_customer_notification_update
  after update of status on public.service_requests
  for each row execute function public.notify_service_request_event();

create or replace function public.notify_job_customer_event()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_title text;
  v_event_type text;
  v_body text;
begin
  if tg_op = 'INSERT' and new.status = 'order_confirmed' then
    v_event_type := 'job_order_confirmed';
    v_title := 'Order confirmed';
    v_body := format('Your delivery job %s is confirmed.', new.job_number);
  elsif tg_op = 'INSERT' or new.status is distinct from old.status then
    v_event_type := 'job_status_' || new.status::text;
    v_title := case new.status
      when 'partner_assigned' then 'Delivery partner assigned'
      when 'pickup_scheduled' then 'Pickup scheduled'
      when 'picked_up' then 'Parcel picked up'
      when 'in_transit' then 'Parcel in transit'
      when 'out_for_delivery' then 'Out for delivery'
      when 'delivered' then 'Parcel delivered'
      when 'exception' then 'Delivery needs attention'
      when 'closed' then 'Delivery completed'
      when 'cancelled' then 'Delivery cancelled'
      else 'Delivery status updated'
    end;
    v_body := format('Job %s: %s.', new.job_number, lower(v_title));
  else
    return new;
  end if;

  perform public.notify_customer_users(
    new.customer_id, new.id, v_event_type, v_title, v_body,
    jsonb_build_object('job_id', new.id, 'job_number', new.job_number, 'status', new.status)
  );
  return new;
end;
$$;

create trigger job_customer_notification_insert
  after insert on public.jobs
  for each row execute function public.notify_job_customer_event();
create trigger job_customer_notification_status_update
  after update of status on public.jobs
  for each row execute function public.notify_job_customer_event();

create or replace function public.notify_customer_pod_event()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_job public.jobs%rowtype;
begin
  select * into v_job from public.jobs where id = new.job_id;
  if not found then return new; end if;
  perform public.notify_customer_users(
    v_job.customer_id, v_job.id, 'proof_of_delivery_added', 'Delivery proof available',
    format('Proof of delivery for job %s is available in your Gohezoh account.', v_job.job_number),
    jsonb_build_object('job_id', v_job.id, 'job_number', v_job.job_number)
  );
  return new;
end;
$$;

create trigger proof_of_delivery_customer_notification
  after insert on public.proof_of_delivery
  for each row execute function public.notify_customer_pod_event();

revoke all on function public.notify_service_request_event() from public, anon, authenticated;
revoke all on function public.notify_job_customer_event() from public, anon, authenticated;
revoke all on function public.notify_customer_pod_event() from public, anon, authenticated;

create or replace function public.mark_customer_notification_read(p_notification_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_read_at timestamptz;
begin
  if auth.uid() is null then
    raise insufficient_privilege using message = 'Sign in is required to update notifications';
  end if;
  update public.notifications
  set read_at = coalesce(read_at, now())
  where id = p_notification_id and user_id = auth.uid()
  returning read_at into v_read_at;
  if v_read_at is null then
    raise no_data_found using message = 'Notification was not found';
  end if;
  return v_read_at;
end;
$$;

revoke all on function public.mark_customer_notification_read(uuid) from public, anon, authenticated;
grant execute on function public.mark_customer_notification_read(uuid) to authenticated;

comment on table public.notifications is 'Private customer inbox events created transactionally from service request, job status, and delivery proof changes.';
