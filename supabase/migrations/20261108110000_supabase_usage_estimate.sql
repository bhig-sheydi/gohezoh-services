-- Hourly local usage sample. Supabase bills at organization scope and on the
-- organization's own cycle; these project measurements are a labeled proxy.
create table public.admin_supabase_usage_sample (
  id integer primary key default 1 check(id=1),
  sampled_at timestamptz not null,
  database_bytes bigint not null,
  storage_bytes bigint not null,
  signed_in_users_this_utc_month bigint not null
);
alter table public.admin_supabase_usage_sample enable row level security;
revoke all on public.admin_supabase_usage_sample from public,anon,authenticated;

create function public.sample_admin_supabase_usage() returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_storage bigint;v_users bigint;v_month timestamptz;
begin
  v_month:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC';
  select coalesce(sum(case when o.metadata->>'size' ~ '^[0-9]+$'
    then (o.metadata->>'size')::bigint else 0 end),0) into v_storage from storage.objects o;
  select count(*) into v_users from auth.users u where u.last_sign_in_at>=v_month;
  insert into public.admin_supabase_usage_sample
    (id,sampled_at,database_bytes,storage_bytes,signed_in_users_this_utc_month)
    values(1,now(),pg_database_size(current_database()),v_storage,v_users)
    on conflict(id) do update set sampled_at=excluded.sampled_at,
      database_bytes=excluded.database_bytes,storage_bytes=excluded.storage_bytes,
      signed_in_users_this_utc_month=excluded.signed_in_users_this_utc_month;
end $$;
revoke all on function public.sample_admin_supabase_usage() from public,anon,authenticated;

select cron.schedule('kwik-parsel-supabase-usage-hourly','7 * * * *',
  'select public.sample_admin_supabase_usage()');
select public.sample_admin_supabase_usage();

create function public.supabase_overage_daily_estimate_ngn() returns numeric
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_settings public.admin_cost_rate_settings%rowtype;
  v_sample public.admin_supabase_usage_sample%rowtype;
  v_month date:=date_trunc('month',now() at time zone 'UTC')::date;
  v_usd numeric;
begin
  if auth.role() is distinct from 'service_role' and not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Cost estimate access required';
  end if;
  select * into v_settings from public.admin_cost_rate_settings where id=1;
  if v_settings.supabase_plan not in ('pro','team') or v_settings.usd_to_ngn is null then return null; end if;
  select * into v_sample from public.admin_supabase_usage_sample where id=1;
  if v_sample.sampled_at is null or v_sample.sampled_at<now()-interval '2 hours' then return null; end if;
  v_usd:=greatest(v_sample.database_bytes/1000000000.0-8,0)*0.125
    +greatest(v_sample.storage_bytes/1000000000.0-100,0)*0.0213
    +greatest(v_sample.signed_in_users_this_utc_month-100000,0)*0.00325;
  return round(v_usd*v_settings.usd_to_ngn /
    extract(day from (v_month+interval '1 month - 1 day')),2);
end $$;
revoke all on function public.supabase_overage_daily_estimate_ngn() from public,anon,authenticated;
grant execute on function public.supabase_overage_daily_estimate_ngn() to service_role,authenticated;

create or replace function public.admin_supabase_project_usage_snapshot() returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_sample public.admin_supabase_usage_sample%rowtype;
  v_settings public.admin_cost_rate_settings%rowtype;
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  select * into v_sample from public.admin_supabase_usage_sample where id=1;
  select * into v_settings from public.admin_cost_rate_settings where id=1;
  return jsonb_build_object('checked_at',v_sample.sampled_at,
    'database_bytes',v_sample.database_bytes,'storage_bytes',v_sample.storage_bytes,
    'signed_in_users_lower_bound',v_sample.signed_in_users_this_utc_month,
    'plan',v_settings.supabase_plan,
    'daily_overage_estimate_ngn',public.supabase_overage_daily_estimate_ngn(),
    'scope_note','This project only; organization usage, egress, Edge and Realtime are not measured here.');
end $$;
