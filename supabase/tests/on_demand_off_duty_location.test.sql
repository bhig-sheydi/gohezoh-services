begin;
do $$
declare v_partner uuid:=gen_random_uuid();v_roster uuid:=gen_random_uuid();
begin
  if has_table_privilege('authenticated','public.rider_location_requests','SELECT')
    or has_table_privilege('authenticated','public.customer_rider_location_requests','SELECT') then
    raise exception 'Location request queues are exposed'; end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  begin
    perform public.request_company_rider_location(v_partner,v_roster);
    raise exception 'Unrelated company requested rider location';
  exception when insufficient_privilege then null; end;
  begin
    perform public.request_customer_rider_location(gen_random_uuid());
    raise exception 'Unpaid customer requested rider location';
  exception when insufficient_privilege then null; end;
  begin
    perform public.poll_native_rider_location_request(repeat('0',64));
    raise exception 'Invalid rider token polled requests';
  exception when insufficient_privilege then null; end;
  begin
    perform public.report_native_requested_position(repeat('0',64),gen_random_uuid(),4.88,7.01,20,clock_timestamp());
    raise exception 'Invalid rider token reported position';
  exception when insufficient_privilege then null; end;
  if pg_get_functiondef('public.report_native_off_duty_position(text,double precision,double precision,double precision,timestamptz)'::regprocedure)
    not like '%Update the Kwik-Parsel Android app%' then
    raise exception 'Old continuous off-duty reporting remains active'; end if;
end $$;
rollback;
