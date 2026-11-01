begin;
do $$
declare v_customer uuid; v_dashboard jsonb;
begin
  if has_table_privilege('authenticated','public.customer_referral_earnings','SELECT')
    or has_table_privilege('authenticated','public.customer_referral_members','INSERT')
    or has_function_privilege('authenticated','public.refresh_customer_referral_earnings(uuid)','EXECUTE') then
    raise exception 'Referral ledger or mutation RPC is directly accessible to clients';
  end if;
  if exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='customer_referral_earnings' and column_name='platform_share_ngn')
    or not exists(select 1 from information_schema.columns where table_schema='public'
      and table_name='customer_referral_earnings' and column_name='commission_base_ngn') then
    raise exception 'Referral commission still uses the platform share';
  end if;
  if pg_get_functiondef('public.refresh_customer_referral_earnings(uuid)'::regprocedure) not like '%f.partner_cost%'
    or pg_get_functiondef('public.refresh_customer_referral_earnings(uuid)'::regprocedure) not like '%v_base*0.025%' then
    raise exception 'Referral commission does not use customer or company earnings at 2.5 percent';
  end if;
  if not has_function_privilege('authenticated','public.join_customer_referral_program(text)','EXECUTE')
    or not has_function_privilege('authenticated','public.my_customer_referral_dashboard()','EXECUTE') then
    raise exception 'Customer referral RPCs are unavailable';
  end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  begin
    perform public.join_customer_referral_program('Test alias');
    raise exception 'Anonymous customer joined the referral program';
  exception when insufficient_privilege then null; end;
  begin
    perform public.my_customer_referral_dashboard();
    raise exception 'Anonymous user read the leaderboard';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.role','service_role',true);
  perform public.refresh_customer_referral_earnings(gen_random_uuid());
  select user_id into v_customer from public.customer_users limit 1;
  if v_customer is not null then
    perform set_config('request.jwt.claim.sub',v_customer::text,true);
    v_dashboard:=public.my_customer_referral_dashboard();
    if not (v_dashboard ? 'leaders') then raise exception 'Referral dashboard failed'; end if;
    if public.customer_referral_year_end_result(2025)->>'status'<>'not_final' then
      raise exception 'Prize rule accepted a pre-program year';
    end if;
  end if;
  if not exists(select 1 from pg_trigger where tgname='refresh_customer_referral_on_payment' and tgenabled='O')
    or not exists(select 1 from pg_trigger where tgname='capture_customer_program_referral' and tgenabled='O') then
    raise exception 'Referral attribution or earnings trigger is inactive';
  end if;
end $$;
rollback;
