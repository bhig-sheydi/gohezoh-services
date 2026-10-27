-- Keep external Flutterwave calls bounded even when clients retry or overlap.
alter table public.customer_payment_holds
  add column if not exists account_creation_claimed_at timestamptz,
  add column if not exists last_provider_check_at timestamptz;

create or replace function public.claim_flutterwave_account_creation(p_request_id uuid, p_reference text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role() <> 'service_role' then raise insufficient_privilege; end if;
  update public.customer_payment_holds
     set account_creation_claimed_at=clock_timestamp(), updated_at=clock_timestamp()
   where request_id=p_request_id and reference=p_reference and status='initializing'
     and account_creation_claimed_at is null and expires_at>clock_timestamp();
  return found;
end $$;

-- A company screen needs one scoped snapshot rather than five HTTP RPCs.
create or replace function public.list_company_bid_display()
returns jsonb language sql stable security invoker set search_path=pg_catalog,public as $$
  select pg_catalog.jsonb_build_object(
    'jobs',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x)) from public.list_partner_bid_screen() x),'[]'::jsonb),
    'pickups',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x)) from public.list_company_bid_pickups() x),'[]'::jsonb),
    'deliveries',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x)) from public.list_company_bid_delivery_locations() x),'[]'::jsonb),
    'routes',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x)) from public.list_partner_bid_route_addresses() x),'[]'::jsonb),
    'loads',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(x)) from public.list_company_bid_rider_loads() x),'[]'::jsonb));
$$;
revoke all on function public.list_company_bid_display() from public,anon;
grant execute on function public.list_company_bid_display() to authenticated;

create or replace function public.list_customer_bid_state(p_request_ids uuid[])
returns jsonb language sql stable security invoker set search_path=pg_catalog,public as $$
  select pg_catalog.jsonb_build_object(
    'windows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(w)) from public.delivery_quote_windows w
      where w.request_id=any(p_request_ids)),'[]'::jsonb),
    'quotes',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(q)) from public.customer_delivery_quotes q
      where q.request_id=any(p_request_ids)),'[]'::jsonb),
    'holds',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(h)) from public.list_my_flutterwave_holds() h
      where h.request_id=any(p_request_ids)),'[]'::jsonb));
$$;
revoke all on function public.list_customer_bid_state(uuid[]) from public,anon;
grant execute on function public.list_customer_bid_state(uuid[]) to authenticated;
revoke all on function public.claim_flutterwave_account_creation(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_flutterwave_account_creation(uuid,text) to service_role;

create or replace function public.claim_flutterwave_provider_check(p_request_id uuid, p_reference text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role() <> 'service_role' then raise insufficient_privilege; end if;
  update public.customer_payment_holds
     set last_provider_check_at=clock_timestamp()
   where request_id=p_request_id and reference=p_reference and status in ('pending','expired')
     and created_at>clock_timestamp()-interval '1 day'
     and (last_provider_check_at is null or last_provider_check_at<=clock_timestamp()
       - case when status='expired' then interval '1 minute' else interval '15 seconds' end);
  return found;
end $$;
revoke all on function public.claim_flutterwave_provider_check(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_flutterwave_provider_check(uuid,text) to service_role;

-- Wrong passwords are slowed, not allowed to revoke a staff member's access.
-- Four attempts with the correct password from a different device still revoke it.
alter table public.company_operations_staff
  add column if not exists password_retry_after timestamptz;

create or replace function public.record_company_staff_auth_failure(p_staff_id uuid,p_device_mismatch boolean)
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_staff public.company_operations_staff%rowtype;v_count integer;
begin
  if auth.role()<>'service_role' then raise insufficient_privilege; end if;
  select * into v_staff from public.company_operations_staff where id=p_staff_id for update;
  if not found or v_staff.revoked_at is not null or v_staff.password_revoked_at is not null then return 4; end if;
  if not p_device_mismatch then
    if v_staff.password_retry_after>clock_timestamp() then return -1; end if;
    v_count:=v_staff.failed_attempts+1;
    update public.company_operations_staff set
      failed_attempts=case when v_count>=4 then 0 else v_count end,
      password_retry_after=case when v_count>=4 then clock_timestamp()+interval '15 minutes' else null end,
      updated_at=now() where id=p_staff_id;
    return case when v_count>=4 then -1 else v_count end;
  end if;
  v_count:=v_staff.device_mismatch_attempts+1;
  update public.company_operations_staff set device_mismatch_attempts=v_count,
    password_revoked_at=case when v_count>3 then now() else password_revoked_at end,
    updated_at=now() where id=p_staff_id;
  if v_count>3 then
    insert into public.company_operations_staff_alerts(partner_id,staff_id,message)
    values(v_staff.partner_id,p_staff_id,
      'Possible unauthorized device access to '||v_staff.full_name||'. Password revoked after four device attempts.');
  end if;
  return v_count;
end $$;
