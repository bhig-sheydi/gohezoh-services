-- The project owner invited this exact account through the Supabase Admin API.
do $$
declare v_user uuid:='4789f804-4218-46b9-a352-56e40ae6ca81';
begin
  if not exists (
    select 1 from auth.users where id=v_user
      and lower(email)='admin@gohezohservices.org' and invited_at is not null
  ) then
    raise exception 'Expected invited Super Admin account is missing';
  end if;
  insert into public.user_roles(user_id,role) values(v_user,'admin') on conflict do nothing;
  delete from public.user_roles where user_id=v_user and role='customer';
end $$;
