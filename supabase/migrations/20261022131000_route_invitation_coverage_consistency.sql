-- Local companies are eligible by their active rider route, without manual
-- corridor assignments. Non-aligned riders still need to be physically near.
do $$
declare v_definition text; v_revised text;
begin
  select pg_get_functiondef('public.finalize_live_route_match(uuid)'::regprocedure) into v_definition;
  v_revised:=regexp_replace(v_definition,
    'join public\.partner_corridor_coverage pc on pc\.partner_id=p\.partner_id and pc\.corridor_id=v_window\.corridor_id[[:space:]]+and pc\.is_enabled and pc\.capacity_available',
    '', 'g');
  v_revised:=replace(v_revised,
    '(p.details->>''tier'')::integer in (1,2,3)',
    '(p.details->>''tier'')::integer in (1,2)');
  v_revised:=replace(v_revised,'v_tier<4 or extensions.st_dwithin','v_tier<3 or extensions.st_dwithin');
  if v_revised=v_definition or position('partner_corridor_coverage' in v_revised)>0 then
    raise exception 'Could not update local route invitations';
  end if;
  execute v_revised;
end $$;
