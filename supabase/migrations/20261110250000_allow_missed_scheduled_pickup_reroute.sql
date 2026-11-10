-- The missed-rider worker must safely return an uncollected scheduled pickup
-- to the assignable state before clearing its rider. No custody handoff may exist.
do $$
declare v_definition text; v_revised text;
begin
  select pg_get_functiondef('public.guard_job_status_transition()'::regprocedure) into v_definition;
  v_revised:=replace(v_definition,
    'v_sender_approved:=new.status=',
    'if old.status=''pickup_scheduled'' and new.status=''partner_assigned'''
      ||' and old.assigned_rider_id is not null and new.assigned_rider_id is null'
      ||' and exists(select 1 from public.rider_assignment_responses r where r.job_id=old.id'
      ||' and r.rider_id=old.assigned_rider_id and r.timed_out_at is not null)'
      ||' and not exists(select 1 from public.pickup_handoff_codes h where h.job_id=old.id'
      ||' and h.verified_at is not null) then return new; end if;'
      ||E'\n  v_sender_approved:=new.status=');
  if v_revised=v_definition then raise exception 'Job transition guard insertion point was not found'; end if;
  execute v_revised;
end $$;
