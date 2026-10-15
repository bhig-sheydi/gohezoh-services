create or replace function public.reopen_delivery_quote_window(p_request_id uuid,p_reason text)
returns timestamptz language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_deadline timestamptz;
begin
  if not (public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Only Operations can reopen bidding'; end if;
  if length(btrim(p_reason))<10 then raise check_violation using message='Reopening reason is required'; end if;
  v_deadline:=now()+interval '1 minute';
  update public.delivery_quote_windows set status='open',published_at=now(),deadline_at=v_deadline,closed_at=null
  where request_id=p_request_id and status='no_bids';
  if not found then raise object_not_in_prerequisite_state using message='Only no-bid windows can be reopened'; end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,changed_fields)
  values(auth.uid(),'delivery_bids_reopened:'||btrim(p_reason),'service_request',p_request_id,array['published_at','deadline_at']);
  return v_deadline;
end $$;
