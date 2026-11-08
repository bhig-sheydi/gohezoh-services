-- A transaction can cross the 10% threshold more than once while testing or
-- reconciling costs. Give each event its actual insertion time, not the
-- transaction start time, so the latest active crossing is deterministic.
create or replace function public.admin_alarm_transition_margin(p_day date,p_margin numeric)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_state public.admin_alarm_margin_state%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise insufficient_privilege using message='Alarm worker access required';
  end if;
  if p_day is null or p_day<>(now() at time zone 'UTC')::date
      or (p_margin is not null and abs(p_margin)>100000) then
    raise check_violation using message='Invalid alarm margin sample';
  end if;
  insert into public.admin_alarm_margin_state(alarm_day,evaluated_at)
    values(p_day,'epoch'::timestamptz) on conflict(alarm_day) do nothing;
  select * into v_state from public.admin_alarm_margin_state
    where alarm_day=p_day for update;
  if p_margin is not null and p_margin<=10 and not v_state.below_threshold then
    insert into public.admin_alarm_margin_events(alarm_day,margin_percent,detected_at)
      values(p_day,round(p_margin,2),clock_timestamp());
  end if;
  update public.admin_alarm_margin_state set evaluated_at=clock_timestamp(),
    below_threshold=(p_margin is not null and p_margin<=10),
    last_margin_percent=round(p_margin,2) where alarm_day=p_day;
end $$;
revoke all on function public.admin_alarm_transition_margin(date,numeric)
  from public,anon,authenticated,service_role;
