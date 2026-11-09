-- The older polling migration unscheduled this sender. Re-arm it now that FCM is configured.
do $$
begin
  if not exists(select 1 from cron.job where jobname='kwik-parsel-admin-spike-push') then
    perform cron.schedule('kwik-parsel-admin-spike-push','* * * * *',
      'select public.invoke_due_admin_spike_push()');
  end if;
end $$;
