-- Owner-confirmed outbound interstate corridor. The reverse direction remains unchanged.
with enabled_corridor as (
  insert into public.coverage_corridors
    (origin_id, destination_id, service_code, is_enabled, change_reason)
  select origin.id, destination.id, 'SRV-0002', true,
    'Owner confirmed Umuahia to Port Harcourt goods movement'
  from public.coverage_locations origin
  cross join public.coverage_locations destination
  where origin.name = 'Umuahia' and destination.name = 'Port Harcourt'
  on conflict (origin_id, destination_id, service_code) do update
    set is_enabled = true,
        change_reason = excluded.change_reason,
        effective_at = now(),
        updated_at = now()
  returning id
)
insert into public.audit_logs (entity_type, entity_id, action, changed_fields)
select 'coverage_corridor', id, 'owner_confirmed_umuahia_to_port_harcourt',
       array['origin_id', 'destination_id', 'service_code', 'is_enabled']
from enabled_corridor;
