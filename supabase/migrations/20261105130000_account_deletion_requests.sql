create table public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  requested_at timestamptz not null default now(),
  status text not null default 'pending' check (status in ('pending','in_review')),
  unique(user_id)
);
create index account_deletion_requests_pending_idx on public.account_deletion_requests(requested_at) where status='pending';
alter table public.account_deletion_requests enable row level security;
revoke all on public.account_deletion_requests from anon,authenticated;
grant select on public.account_deletion_requests to authenticated;
create policy account_deletion_request_read on public.account_deletion_requests for select to authenticated
using (user_id=auth.uid() or public.has_role(auth.uid(),'admin'));

create function public.request_account_deletion() returns timestamptz
language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_user uuid:=auth.uid(); v_at timestamptz;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to request account deletion'; end if;
  insert into public.account_deletion_requests(user_id) values(v_user)
    on conflict(user_id) do update set status='pending'
    returning requested_at into v_at;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('account_deletion_request',v_user,'requested',v_user,array['status']);
  insert into public.notifications(user_id,event_type,channel,title,body,payload,status,sent_at)
    select ur.user_id,'account_deletion_requested','in_app','Account deletion requested',
      'Review the account deletion queue and resolve this request.',
      jsonb_build_object('user_id',v_user),'delivered',now()
    from public.user_roles ur where ur.role='admin' and public.has_role(ur.user_id,'admin');
  return v_at;
end $$;
revoke all on function public.request_account_deletion() from public,anon,authenticated;
grant execute on function public.request_account_deletion() to authenticated;

create function public.list_account_deletion_requests()
returns table(request_id uuid,user_id uuid,email text,requested_at timestamptz,status text)
language plpgsql security definer set search_path=pg_catalog,public,auth as $$
begin
  if not public.has_role(auth.uid(),'admin') then
    raise insufficient_privilege using message='Super Admin access is required';
  end if;
  return query select r.id,r.user_id,u.email::text,r.requested_at,r.status
    from public.account_deletion_requests r join auth.users u on u.id=r.user_id
    order by r.requested_at;
end $$;
revoke all on function public.list_account_deletion_requests() from public,anon,authenticated;
grant execute on function public.list_account_deletion_requests() to authenticated;
