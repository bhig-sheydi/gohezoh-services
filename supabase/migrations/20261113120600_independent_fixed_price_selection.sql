-- A customer may choose an independent rider's fixed-price offer immediately,
-- under the same customer-price rule as a company motorcycle offer.
do $$
declare v_sql text; v_next text;
begin
  select pg_get_functiondef('public.select_customer_partner_bid(uuid,uuid)'::regprocedure) into v_sql;
  v_next:=replace(v_sql,
    'join public.partner_application_vehicles v on v.id=r.source_vehicle_id and v.vehicle_type=''motorcycle''',
    'left join public.partner_application_vehicles v on v.id=r.source_vehicle_id and v.vehicle_type=''motorcycle''');
  v_next:=replace(v_next,
    'where bp.request_id=p_request_id and bp.customer_price_ngn=v_bid.amount_ngn',
    'where bp.request_id=p_request_id and bp.customer_price_ngn=v_bid.amount_ngn'
      ||' and (v.id is not null or r.independent_user_id=i.rider_id)');
  if v_sql=v_next or position('r.independent_user_id=i.rider_id' in v_next)=0 then
    raise exception 'Fixed-price selection guard was not found'; end if;
  execute v_next;
end $$;
