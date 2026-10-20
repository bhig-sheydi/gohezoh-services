-- Revalidate freshness after waiting for the quota row lock, before disclosure.
create or replace function public.claim_my_rider_location_check(p_job_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public,extensions as $$
declare v_job public.jobs%rowtype; v_presence public.rider_presence%rowtype;
  v_checks public.customer_rider_location_checks%rowtype; v_recent timestamptz[];
  v_now timestamptz;
begin
  if auth.uid() is null then raise insufficient_privilege using message='Sign in required'; end if;
  select j.* into v_job from public.jobs j
    join public.orders o on o.id=j.order_id
    where j.id=p_job_id and public.is_customer_user(j.customer_id)
      and (exists (select 1 from public.customer_payment_holds h where h.request_id=o.service_request_id and h.status='paid')
        or exists (select 1 from public.customer_payments cp where cp.job_id=j.id and cp.status='received'));
  if not found then raise insufficient_privilege using message='Paid delivery access required'; end if;
  if v_job.status in ('delivered','closed','cancelled') then return jsonb_build_object('state','completed'); end if;
  if v_job.assigned_rider_id is null then return jsonb_build_object('state','awaiting_rider'); end if;
  insert into public.customer_rider_location_checks(user_id) values(auth.uid()) on conflict do nothing;
  select * into v_checks from public.customer_rider_location_checks where user_id=auth.uid() for update;
  v_now := clock_timestamp();
  select j.* into v_job from public.jobs j
    join public.orders o on o.id=j.order_id
    where j.id=p_job_id and public.is_customer_user(j.customer_id)
      and (exists (select 1 from public.customer_payment_holds h where h.request_id=o.service_request_id and h.status='paid')
        or exists (select 1 from public.customer_payments cp where cp.job_id=j.id and cp.status='received'));
  if not found then raise insufficient_privilege using message='Paid delivery access required'; end if;
  if v_job.status in ('delivered','closed','cancelled') then return jsonb_build_object('state','completed'); end if;
  if v_job.assigned_rider_id is null then return jsonb_build_object('state','awaiting_rider'); end if;
  select * into v_presence from public.rider_presence rp
    where rp.user_id=v_job.assigned_rider_id and rp.partner_id=v_job.partner_id
      and rp.captured_at>v_now-interval '2 minutes' and rp.received_at>v_now-interval '2 minutes';
  if not found then return jsonb_build_object('state','offline'); end if;
  select coalesce(array_agg(t.checked_at order by t.checked_at),'{}'::timestamptz[]) into v_recent
    from unnest(v_checks.checked_at) t(checked_at) where t.checked_at>v_now-interval '1 hour';
  if cardinality(v_recent)>=2 then
    return jsonb_build_object('state','limited','checks_remaining',0,'retry_at',v_recent[1]+interval '1 hour');
  end if;
  update public.customer_rider_location_checks set checked_at=array_append(v_recent,v_now) where user_id=auth.uid();
  return jsonb_build_object('state','live','checks_remaining',1-cardinality(v_recent),
    'latitude',extensions.st_y(v_presence.position::extensions.geometry),
    'longitude',extensions.st_x(v_presence.position::extensions.geometry),
    'accuracy_metres',v_presence.accuracy_metres,'captured_at',v_presence.captured_at);
end $$;
