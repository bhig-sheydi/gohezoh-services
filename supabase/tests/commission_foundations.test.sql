begin;
do $$
declare v_manager uuid:=gen_random_uuid();v_bdo uuid:=gen_random_uuid();v_other_bdo uuid:=gen_random_uuid();v_partner uuid:=gen_random_uuid();v_attr uuid;v_plan uuid;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values(v_manager,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','commission-manager-'||v_manager||'@example.test','',now(),'{}','{}',now(),now()),
        (v_bdo,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','commission-bdo-'||v_bdo||'@example.test','',now(),'{}','{}',now(),now()),
        (v_other_bdo,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','commission-other-'||v_other_bdo||'@example.test','',now(),'{}','{}',now(),now());
  insert into public.user_roles(user_id,role) values(v_manager,'management'),(v_bdo,'bdo'),(v_other_bdo,'bdo');
  insert into public.logistics_partners(id,partner_name,contact_person,phone,status)
    values(v_partner,'Attribution Test Partner','Contact','08000000014','active');
  perform set_config('request.jwt.claim.sub',v_bdo::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_bdo,'role','authenticated')::text,true);
  begin
    perform public.approve_partner_attribution(v_partner,v_bdo,'partner_development',current_date,'Signed partner development agreement');
    raise exception 'BDO approved own attribution';
  exception when insufficient_privilege then null;end;
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  v_attr:=public.approve_partner_attribution(v_partner,v_bdo,'partner_development',current_date,'Verified partner source');
  if not exists(select 1 from public.partner_attributions where id=v_attr and status='approved') then raise exception 'Approved attribution missing';end if;
  perform set_config('request.jwt.claim.sub',v_bdo::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_bdo,'role','authenticated')::text,true);
  if not exists(select 1 from public.list_my_bdo_partners() where partner_id=v_partner) then raise exception 'BDO cannot see own approved partner';end if;
  perform set_config('request.jwt.claim.sub',v_other_bdo::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_other_bdo,'role','authenticated')::text,true);
  if exists(select 1 from public.list_my_bdo_partners() where partner_id=v_partner) then raise exception 'Other BDO can see partner attribution';end if;
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_manager,'role','authenticated')::text,true);
  begin
    perform public.approve_partner_attribution(v_partner,v_bdo,'partner_development',current_date,'Duplicate claim');
    raise exception 'Conflicting attribution accepted';
  exception when unique_violation then null;end;
  begin
    perform public.approve_commission_plan(v_bdo,'collected_revenue',0.05,null,'{}'::jsonb,current_date,'No agreement');
    raise exception 'Plan without signed agreement reference accepted';
  exception when check_violation then null;end;
  v_plan:=public.approve_commission_plan(v_bdo,'collected_revenue',0.05,null,'{"agreement_reference":"TEST-AGREEMENT"}'::jsonb,current_date,'Signed agreement verified');
  if not exists(select 1 from public.commission_plans where id=v_plan and version=1 and rate=0.05) then raise exception 'Versioned plan missing';end if;
  perform public.approve_commission_plan(v_bdo,'collected_revenue',0.06,null,'{"agreement_reference":"TEST-AGREEMENT-V2"}'::jsonb,current_date+1,'Revised signed agreement');
  if not exists(select 1 from public.commission_plans where id=v_plan and effective_until=current_date) then raise exception 'Old plan was not retained';end if;
end $$;
rollback;
