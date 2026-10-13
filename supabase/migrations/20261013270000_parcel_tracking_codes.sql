-- Give each physical parcel row a stable, printable identifier for handoffs.
create sequence public.job_parcel_tracking_code_seq start 1;

alter table public.job_parcels add column tracking_code text;

update public.job_parcels
set tracking_code = 'KWP-P-' || lpad(nextval('public.job_parcel_tracking_code_seq')::text, 8, '0');

alter table public.job_parcels
  alter column tracking_code set default ('KWP-P-' || lpad(nextval('public.job_parcel_tracking_code_seq')::text, 8, '0')),
  alter column tracking_code set not null;

create unique index job_parcels_tracking_code_uidx on public.job_parcels(tracking_code);
grant usage on sequence public.job_parcel_tracking_code_seq to authenticated;

create or replace function public.prevent_job_parcel_tracking_code_change()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if new.tracking_code is distinct from old.tracking_code then
    raise check_violation using message='Parcel tracking codes are permanent';
  end if;
  return new;
end;
$$;

revoke all on function public.prevent_job_parcel_tracking_code_change() from public,anon,authenticated;
create trigger job_parcel_tracking_code_immutable
  before update of tracking_code on public.job_parcels
  for each row execute function public.prevent_job_parcel_tracking_code_change();

comment on column public.job_parcels.tracking_code is
  'Permanent human-readable parcel identifier; printed as a Code 39 barcode for warehouse and delivery handoffs.';
