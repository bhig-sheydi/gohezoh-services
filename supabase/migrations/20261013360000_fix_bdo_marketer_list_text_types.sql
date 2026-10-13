create or replace function public.list_my_bdo_marketers()
returns table(marketer_user_id uuid,email text,full_name text,active boolean,created_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
begin
  if not public.has_role(auth.uid(),'bdo') then
    raise insufficient_privilege using message='An approved BDO account is required';
  end if;
  return query
  select m.marketer_user_id,u.email::text,p.full_name::text,m.active,m.created_at
  from public.bdo_marketers m
  join auth.users u on u.id=m.marketer_user_id
  left join public.profiles p on p.user_id=m.marketer_user_id
  where m.bdo_user_id=auth.uid()
  order by m.created_at desc;
end $$;
revoke all on function public.list_my_bdo_marketers() from public,anon,authenticated;
grant execute on function public.list_my_bdo_marketers() to authenticated;
