-- Operations can review a request and atomically create its order and job.
-- Direct client writes are restricted so the linked records cannot be bypassed.

drop policy if exists requests_update_staff on public.service_requests;
revoke update on public.service_requests from authenticated;
grant select, insert on public.service_requests to authenticated;

revoke insert on public.orders, public.jobs from authenticated;
grant select, update on public.orders, public.jobs to authenticated;

create or replace function public.process_service_request(
  p_request_id uuid,
  p_action text,
  p_customer_price numeric default null,
  p_operations_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_request public.service_requests%rowtype;
  v_order public.orders%rowtype;
  v_job public.jobs%rowtype;
begin
  if v_user_id is null then
    raise insufficient_privilege using message = 'Sign in is required to process service requests';
  end if;

  if not (
    public.has_role(v_user_id, 'operations')
    or public.has_role(v_user_id, 'admin')
    or public.has_role(v_user_id, 'management')
  ) then
    raise insufficient_privilege using message = 'Only Gohezoh operations staff can process service requests';
  end if;

  if p_action is null or p_action not in ('start_review', 'reject', 'approve') then
    raise invalid_parameter_value using message = 'Action must be start_review, reject, or approve';
  end if;

  select * into v_request
  from public.service_requests
  where id = p_request_id
  for update;

  if not found then
    raise no_data_found using message = 'Service request was not found';
  end if;

  if v_request.status not in ('submitted', 'under_review') then
    raise object_not_in_prerequisite_state using message = 'Request is not awaiting operations review';
  end if;

  if p_action = 'start_review' then
    update public.service_requests
    set status = 'under_review',
        operations_note = coalesce(nullif(btrim(p_operations_note), ''), operations_note)
    where id = v_request.id;

    return jsonb_build_object('request_id', v_request.id, 'status', 'under_review');
  end if;

  if p_action = 'reject' then
    update public.service_requests
    set status = 'rejected',
        operations_note = coalesce(nullif(btrim(p_operations_note), ''), operations_note),
        reviewed_by = v_user_id,
        reviewed_at = now()
    where id = v_request.id;

    return jsonb_build_object('request_id', v_request.id, 'status', 'rejected');
  end if;

  if p_customer_price is null or p_customer_price < 0 then
    raise check_violation using message = 'A non-negative customer price is required to confirm the request';
  end if;

  insert into public.orders (
    service_request_id, customer_id, service_id, status,
    customer_price, confirmed_by, confirmed_at
  ) values (
    v_request.id, v_request.customer_id, v_request.service_id, 'confirmed',
    p_customer_price, v_user_id, now()
  ) returning * into v_order;

  insert into public.jobs (
    order_id, customer_id, service_id, assigned_operations_user_id, status,
    pickup_address, pickup_city, pickup_state, sender_name, sender_phone,
    delivery_address, delivery_city, delivery_state, recipient_name, recipient_phone,
    preferred_pickup_at
  ) values (
    v_order.id, v_request.customer_id, v_request.service_id, v_user_id, 'order_confirmed',
    v_request.pickup_address, v_request.pickup_city, v_request.pickup_state,
    v_request.sender_name, v_request.sender_phone,
    v_request.delivery_address, v_request.delivery_city, v_request.delivery_state,
    v_request.recipient_name, v_request.recipient_phone, v_request.preferred_pickup_at
  ) returning * into v_job;

  update public.service_requests
  set status = 'converted',
      operations_note = coalesce(nullif(btrim(p_operations_note), ''), operations_note),
      reviewed_by = v_user_id,
      reviewed_at = now()
  where id = v_request.id;

  return jsonb_build_object(
    'request_id', v_request.id,
    'status', 'converted',
    'order_id', v_order.id,
    'order_number', v_order.order_number,
    'job_id', v_job.id,
    'job_number', v_job.job_number
  );
end;
$$;

revoke all on function public.process_service_request(uuid, text, numeric, text)
  from public, anon, authenticated;
grant execute on function public.process_service_request(uuid, text, numeric, text)
  to authenticated;

comment on function public.process_service_request(uuid, text, numeric, text)
  is 'Operations-only request review. Approval creates a matching order and job atomically.';
