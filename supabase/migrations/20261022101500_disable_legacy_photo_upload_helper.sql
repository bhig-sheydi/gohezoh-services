-- Keep historic proof reads, but every new delivery completes through a code or sender confirmation.
create or replace function public.can_upload_pod_job(p_job_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select false;
$$;
