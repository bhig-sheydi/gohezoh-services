create table public.commission_payout_batches (
  id uuid primary key default gen_random_uuid(),
  commission_type text not null check (commission_type in ('direct_bdo','marketer','bdo_network_share')),
  recipient_user_id uuid not null references auth.users(id) on delete restrict,
  transfer_reference text not null unique check (length(btrim(transfer_reference)) between 3 and 160),
  amount_ngn numeric(14,2) not null check (amount_ngn > 0),
  entry_count integer not null check (entry_count > 0),
  paid_by uuid not null references auth.users(id) on delete restrict,
  paid_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
alter table public.commission_ledger
  add column reviewed_at timestamptz,
  add column review_reason text,
  add column payout_reference text,
  add column payout_batch_id uuid references public.commission_payout_batches(id) on delete restrict;
alter table public.commission_ledger drop constraint commission_ledger_status_check;
alter table public.commission_ledger add constraint commission_ledger_status_check
  check(status in ('pending_eligibility','calculated','under_review','approved','declined','paid','reversed','adjusted'));
alter table public.marketer_commission_ledger
  add column reviewer_id uuid references auth.users(id) on delete restrict,
  add column reviewed_at timestamptz,
  add column review_reason text,
  add column payout_reference text,
  add column payout_batch_id uuid references public.commission_payout_batches(id) on delete restrict;
alter table public.marketer_commission_ledger drop constraint marketer_commission_ledger_status_check;
alter table public.marketer_commission_ledger add constraint marketer_commission_ledger_status_check
  check(status in ('calculated','under_review','approved','declined','paid','reversed','adjusted'));
alter table public.bdo_marketer_share_ledger
  add column reviewer_id uuid references auth.users(id) on delete restrict,
  add column reviewed_at timestamptz,
  add column review_reason text,
  add column payout_reference text,
  add column payout_batch_id uuid references public.commission_payout_batches(id) on delete restrict;
alter table public.bdo_marketer_share_ledger drop constraint bdo_marketer_share_ledger_status_check;
alter table public.bdo_marketer_share_ledger add constraint bdo_marketer_share_ledger_status_check
  check(status in ('calculated','under_review','approved','declined','paid','reversed','adjusted'));

alter table public.commission_payout_batches enable row level security;
revoke all on public.commission_payout_batches from public,anon,authenticated;
grant select on public.commission_payout_batches to authenticated;
create policy commission_payout_batch_read on public.commission_payout_batches for select to authenticated
  using ((recipient_user_id=auth.uid() and (public.has_role(auth.uid(),'bdo') or public.has_role(auth.uid(),'marketer')))
    or public.has_role(auth.uid(),'finance') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));

create or replace function public.review_commission_entry(p_commission_type text,p_entry_id uuid,p_approve boolean,p_reason text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_status text;v_table text;
begin
  if v_actor is null or not (public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    raise insufficient_privilege using message='Management approval required'; end if;
  if p_commission_type is null or p_commission_type not in ('direct_bdo','marketer','bdo_network_share')
    or p_approve is null or nullif(btrim(p_reason),'') is null then
    raise check_violation using message='Commission type and review reason are required'; end if;
  if p_commission_type='direct_bdo' then
    select status into v_status from public.commission_ledger where id=p_entry_id for update;
    if not found then raise no_data_found using message='Commission entry was not found'; end if;
    if v_status not in ('calculated','under_review') then raise object_not_in_prerequisite_state using message='Only calculated entries can be reviewed'; end if;
    update public.commission_ledger set status=case when p_approve then 'approved' else 'declined' end,
      reviewer_id=v_actor,reviewed_at=now(),review_reason=btrim(p_reason) where id=p_entry_id;
    v_table:='commission_ledger';
  elsif p_commission_type='marketer' then
    select status into v_status from public.marketer_commission_ledger where id=p_entry_id for update;
    if not found then raise no_data_found using message='Commission entry was not found'; end if;
    if v_status not in ('calculated','under_review') then raise object_not_in_prerequisite_state using message='Only calculated entries can be reviewed'; end if;
    update public.marketer_commission_ledger set status=case when p_approve then 'approved' else 'declined' end,
      reviewer_id=v_actor,reviewed_at=now(),review_reason=btrim(p_reason) where id=p_entry_id;
    v_table:='marketer_commission_ledger';
  else
    select status into v_status from public.bdo_marketer_share_ledger where id=p_entry_id for update;
    if not found then raise no_data_found using message='Commission entry was not found'; end if;
    if v_status not in ('calculated','under_review') then raise object_not_in_prerequisite_state using message='Only calculated entries can be reviewed'; end if;
    update public.bdo_marketer_share_ledger set status=case when p_approve then 'approved' else 'declined' end,
      reviewer_id=v_actor,reviewed_at=now(),review_reason=btrim(p_reason) where id=p_entry_id;
    v_table:='bdo_marketer_share_ledger';
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values(v_table,p_entry_id,case when p_approve then 'commission_approved' else 'commission_declined' end,v_actor,array['status','reviewer_id','reviewed_at','review_reason']);
end $$;
revoke all on function public.review_commission_entry(text,uuid,boolean,text) from public,anon;
grant execute on function public.review_commission_entry(text,uuid,boolean,text) to authenticated;

create or replace function public.record_commission_payout(p_commission_type text,p_entry_ids uuid[],p_transfer_reference text)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_recipient uuid;v_amount numeric(14,2);v_count integer;v_batch uuid;
begin
  if v_actor is null or not (public.has_role(v_actor,'finance') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    raise insufficient_privilege using message='Finance access required to record a payout'; end if;
  if p_commission_type is null or p_commission_type not in ('direct_bdo','marketer','bdo_network_share') or coalesce(cardinality(p_entry_ids),0)=0
    or nullif(btrim(p_transfer_reference),'') is null or length(btrim(p_transfer_reference))>160 then
    raise check_violation using message='Choose approved commission entries and enter the actual transfer reference'; end if;
  if (select count(distinct id) from unnest(p_entry_ids) x(id))<>cardinality(p_entry_ids) then
    raise check_violation using message='Duplicate commission entries are not allowed'; end if;
  if p_commission_type='direct_bdo' then
    perform 1 from public.commission_ledger where id=any(p_entry_ids) order by id for update;
    select count(*),(array_agg(bdo_id))[1],sum(calculated_amount_ngn) into v_count,v_recipient,v_amount from public.commission_ledger
      where id=any(p_entry_ids) and status='approved' and calculated_amount_ngn>0 and reviewer_id<>v_actor and payout_batch_id is null;
  elsif p_commission_type='marketer' then
    perform 1 from public.marketer_commission_ledger where id=any(p_entry_ids) order by id for update;
    select count(*),(array_agg(marketer_user_id))[1],sum(calculated_amount_ngn) into v_count,v_recipient,v_amount from public.marketer_commission_ledger
      where id=any(p_entry_ids) and status='approved' and calculated_amount_ngn>0 and reviewer_id<>v_actor and payout_batch_id is null;
  else
    perform 1 from public.bdo_marketer_share_ledger where id=any(p_entry_ids) order by id for update;
    select count(*),(array_agg(bdo_user_id))[1],sum(calculated_amount_ngn) into v_count,v_recipient,v_amount from public.bdo_marketer_share_ledger
      where id=any(p_entry_ids) and status='approved' and calculated_amount_ngn>0 and reviewer_id<>v_actor and payout_batch_id is null;
  end if;
  if v_count<>cardinality(p_entry_ids) or v_recipient is null or v_amount<=0 then
    raise object_not_in_prerequisite_state using message='All entries must be approved, positive, unpaid, and reviewed by another user'; end if;
  if p_commission_type='direct_bdo' and exists(select 1 from public.commission_ledger where id=any(p_entry_ids) and bdo_id<>v_recipient)
    or p_commission_type='marketer' and exists(select 1 from public.marketer_commission_ledger where id=any(p_entry_ids) and marketer_user_id<>v_recipient)
    or p_commission_type='bdo_network_share' and exists(select 1 from public.bdo_marketer_share_ledger where id=any(p_entry_ids) and bdo_user_id<>v_recipient) then
    raise check_violation using message='A payout batch must contain one recipient only'; end if;
  insert into public.commission_payout_batches(commission_type,recipient_user_id,transfer_reference,amount_ngn,entry_count,paid_by)
    values(p_commission_type,v_recipient,btrim(p_transfer_reference),v_amount,cardinality(p_entry_ids),v_actor) returning id into v_batch;
  if p_commission_type='direct_bdo' then
    update public.commission_ledger set status='paid',payout_batch_id=v_batch,payout_reference=btrim(p_transfer_reference) where id=any(p_entry_ids);
  elsif p_commission_type='marketer' then
    update public.marketer_commission_ledger set status='paid',payout_batch_id=v_batch,payout_reference=btrim(p_transfer_reference) where id=any(p_entry_ids);
  else
    update public.bdo_marketer_share_ledger set status='paid',payout_batch_id=v_batch,payout_reference=btrim(p_transfer_reference) where id=any(p_entry_ids);
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('commission_payout_batch',v_batch,'commission_payout_recorded',v_actor,array['commission_type','recipient_user_id','transfer_reference','amount_ngn','entry_count','paid_by']);
  return v_batch;
end $$;
revoke all on function public.record_commission_payout(text,uuid[],text) from public,anon;
grant execute on function public.record_commission_payout(text,uuid[],text) to authenticated;

create or replace function public.list_commission_work_queue()
returns table(entry_id uuid,commission_type text,recipient_user_id uuid,recipient_name text,recipient_email text,
  job_number text,amount_ngn numeric,status text,receipt_reference text,payout_reference text,reviewer_id uuid,created_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
begin
  if not (public.has_role(auth.uid(),'finance') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')) then
    raise insufficient_privilege using message='Finance access required'; end if;
  return query
    select l.id,'direct_bdo'::text,l.bdo_id,p.full_name,u.email,j.job_number,l.calculated_amount_ngn,l.status,l.payment_reference,l.payout_reference,l.reviewer_id,l.created_at
      from public.commission_ledger l join public.jobs j on j.id=l.job_id join auth.users u on u.id=l.bdo_id left join public.profiles p on p.user_id=l.bdo_id
      where l.status in ('calculated','under_review','approved','declined','paid','adjusted','reversed')
    union all
    select l.id,'marketer'::text,l.marketer_user_id,p.full_name,u.email,j.job_number,l.calculated_amount_ngn,l.status,l.payment_reference,l.payout_reference,l.reviewer_id,l.created_at
      from public.marketer_commission_ledger l join public.jobs j on j.id=l.job_id join auth.users u on u.id=l.marketer_user_id left join public.profiles p on p.user_id=l.marketer_user_id
      where l.status in ('calculated','under_review','approved','declined','paid','adjusted','reversed')
    union all
    select l.id,'bdo_network_share'::text,l.bdo_user_id,p.full_name,u.email,j.job_number,l.calculated_amount_ngn,l.status,l.payment_reference,l.payout_reference,l.reviewer_id,l.created_at
      from public.bdo_marketer_share_ledger l join public.jobs j on j.id=l.job_id join auth.users u on u.id=l.bdo_user_id left join public.profiles p on p.user_id=l.bdo_user_id
      where l.status in ('calculated','under_review','approved','declined','paid','adjusted','reversed')
    order by created_at desc limit 1000;
end $$;
revoke all on function public.list_commission_work_queue() from public,anon;
grant execute on function public.list_commission_work_queue() to authenticated;

create or replace function public.list_my_commission_payouts()
returns table(id uuid,commission_type text,amount_ngn numeric,entry_count integer,transfer_reference text,paid_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if auth.uid() is null or not (public.has_role(auth.uid(),'bdo') or public.has_role(auth.uid(),'marketer')) then
    raise insufficient_privilege using message='BDO or marketer account required'; end if;
  return query select b.id,b.commission_type,b.amount_ngn,b.entry_count,b.transfer_reference,b.paid_at
    from public.commission_payout_batches b where b.recipient_user_id=auth.uid() order by b.paid_at desc limit 200;
end $$;
revoke all on function public.list_my_commission_payouts() from public,anon;
grant execute on function public.list_my_commission_payouts() to authenticated;
