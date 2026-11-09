-- Re-enable the previously prepared push queue after polling removed its trigger.
create or replace function public.admin_unregister_spike_push_device(p_device_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  delete from public.admin_spike_push_devices
    where user_id=auth.uid() and device_id=p_device_id;
end $$;
revoke all on function public.admin_unregister_spike_push_device(uuid) from public,anon,authenticated;
grant execute on function public.admin_unregister_spike_push_device(uuid) to authenticated;

drop trigger if exists admin_spike_alert_enqueue_push on public.admin_traffic_alerts;
create trigger admin_spike_alert_enqueue_push
  after insert or update of severity on public.admin_traffic_alerts
  for each row execute function public.enqueue_admin_spike_push();
