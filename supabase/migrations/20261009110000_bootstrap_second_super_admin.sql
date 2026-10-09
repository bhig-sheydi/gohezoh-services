-- The project owner invited this exact account through the Supabase Admin API.
do $$
declare v_user uuid:='be0d0dfa-5075-407d-9b1f-b04e547889b5';
begin
  if not exists (
    select 1 from auth.users where id=v_user
      and lower(email)='info@gohezohservices.org' and invited_at is not null
  ) then
    raise exception 'Expected invited second Super Admin account is missing';
  end if;
  insert into public.user_roles(user_id,role) values(v_user,'admin') on conflict do nothing;
  delete from public.user_roles where user_id=v_user and role='customer';
end $$;
