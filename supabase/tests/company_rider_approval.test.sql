begin;
do $$
declare v_admin uuid; v_partner uuid; v_rider uuid;
begin
  select ur.user_id into v_admin from public.user_roles ur join auth.users u on u.id=ur.user_id
  where ur.role='admin' and lower(u.email) in
    ('admin@gohezohservices.org','info@gohezohservices.org','vevakporgodsanointed@gmail.com') limit 1;
  if v_admin is null then raise exception 'No allowlisted Super Admin is available for this test'; end if;
  insert into public.logistics_partners(partner_name,contact_person,phone,status)
    values('Rollback Rider Review Test','Test Manager','+2348010000977','active') returning id into v_partner;
  insert into public.company_riders(partner_id,full_name,nin,nin_document_path,licence_document_path)
    values(v_partner,'Rollback Test Rider','12345678901','test/nin.png','test/licence.png') returning id into v_rider;
  insert into storage.objects(bucket_id,name,owner_id,metadata) values
    ('rider-evidence','test/nin.png',v_admin::text,'{"size":100,"mimetype":"image/png"}'::jsonb),
    ('rider-evidence','test/licence.png',v_admin::text,'{"size":100,"mimetype":"image/png"}'::jsonb);
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  if not public.has_role(v_admin,'admin') then raise exception 'Allowlisted Super Admin role was not recognized'; end if;
  execute 'set local role authenticated';
  perform 1 from public.company_riders where id=v_rider;
  if not found then raise exception 'Super Admin cannot read pending company rider'; end if;
  perform public.review_company_rider(v_rider,true,null);
  if not exists(select 1 from public.company_riders where id=v_rider and status='approved') then
    raise exception 'Super Admin approval did not activate rider roster entry'; end if;
end $$;
rollback;
