-- An accepted pickup_scheduled job cannot have a null rider. Return it to the
-- pre-pickup state before looking for a replacement; payment stays received.
do $$
declare v_definition text; v_revised text;
begin
  select pg_get_functiondef('public.resolve_missed_rider_assignments()'::regprocedure) into v_definition;
  v_revised:=replace(v_definition,
    'update public.jobs set assigned_rider_id=null,',
    'update public.jobs set status=case when status=''pickup_scheduled'' then ''partner_assigned''::public.job_state else status end,assigned_rider_id=null,');
  if v_revised=v_definition then raise exception 'Missed-rider status transition was not found'; end if;
  execute v_revised;
end $$;
