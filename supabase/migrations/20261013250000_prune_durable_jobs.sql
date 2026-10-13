create or replace function public.prune_durable_jobs(p_retention interval default interval '90 days')
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_caller_role text:=auth.role();v_deleted integer;
begin
  if (v_caller_role is not null and v_caller_role<>'service_role')
    or (v_caller_role is null and session_user not in ('postgres','supabase_admin')) then
    raise insufficient_privilege using message='Durable job maintenance is restricted to trusted workers';
  end if;
  if p_retention is null or p_retention<interval '7 days' or p_retention>interval '365 days' then
    raise check_violation using message='Queue retention must be between 7 and 365 days';
  end if;
  delete from public.durable_jobs where status in ('completed','cancelled') and created_at<now()-p_retention;
  get diagnostics v_deleted=row_count;
  return v_deleted;
end $$;
revoke all on function public.prune_durable_jobs(interval) from public,anon,authenticated;
grant execute on function public.prune_durable_jobs(interval) to service_role;
select cron.schedule('gohezoh-prune-durable-jobs','30 3 * * *','select public.prune_durable_jobs(interval ''90 days'')');
