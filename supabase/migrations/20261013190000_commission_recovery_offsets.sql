-- Receipt reversals after commission payment create a negative adjustment.
-- Management must approve a future-commission offset before Finance can apply it.
alter table public.commission_ledger
  add column recovery_review_status text not null default 'pending' check (recovery_review_status in ('pending','approved','declined')),
  add column recovery_reviewer_id uuid references auth.users(id) on delete restrict,
  add column recovery_reviewed_at timestamptz,
  add column recovery_review_reason text;
alter table public.marketer_commission_ledger
  add column recovery_review_status text not null default 'pending' check (recovery_review_status in ('pending','approved','declined')),
  add column recovery_reviewer_id uuid references auth.users(id) on delete restrict,
  add column recovery_reviewed_at timestamptz,
  add column recovery_review_reason text;
alter table public.bdo_marketer_share_ledger
  add column recovery_review_status text not null default 'pending' check (recovery_review_status in ('pending','approved','declined')),
  add column recovery_reviewer_id uuid references auth.users(id) on delete restrict,
  add column recovery_reviewed_at timestamptz,
  add column recovery_review_reason text;

alter table public.commission_payout_batches
  alter column transfer_reference drop not null,
  add column gross_amount_ngn numeric(14,2) not null default 0 check (gross_amount_ngn >= 0),
  add column offset_amount_ngn numeric(14,2) not null default 0 check (offset_amount_ngn >= 0);
update public.commission_payout_batches set gross_amount_ngn=amount_ngn;
alter table public.commission_payout_batches
  drop constraint commission_payout_batches_amount_ngn_check,
  add constraint commission_payout_batches_amount_ngn_check check (amount_ngn >= 0),
  add constraint commission_payout_batch_amounts_check check (amount_ngn + offset_amount_ngn = gross_amount_ngn),
  add constraint commission_payout_batch_reference_check check (amount_ngn = 0 or transfer_reference is not null);

create table public.commission_offset_applications (
  id uuid primary key default gen_random_uuid(),
  commission_type text not null check (commission_type in ('direct_bdo','marketer','bdo_network_share')),
  adjustment_entry_id uuid not null,
  payout_batch_id uuid not null references public.commission_payout_batches(id) on delete restrict,
  amount_ngn numeric(14,2) not null check (amount_ngn > 0),
  applied_by uuid not null references auth.users(id) on delete restrict,
  applied_at timestamptz not null default now()
);
create index commission_offset_application_entry_idx on public.commission_offset_applications(commission_type,adjustment_entry_id);
alter table public.commission_offset_applications enable row level security;
revoke all on public.commission_offset_applications from public,anon,authenticated;
grant select on public.commission_offset_applications to authenticated;
create policy commission_offset_application_read on public.commission_offset_applications for select to authenticated
  using (public.has_role(auth.uid(),'finance') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin'));

create or replace function public.review_commission_recovery(p_commission_type text,p_entry_id uuid,p_approve boolean,p_reason text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_status text;v_amount numeric;
begin
  if v_actor is null or not (public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    raise insufficient_privilege using message='Management approval required'; end if;
  if p_commission_type is null or p_commission_type not in ('direct_bdo','marketer','bdo_network_share') or p_approve is null
    or nullif(btrim(p_reason),'') is null then raise check_violation using message='Recovery decision and reason are required'; end if;
  if p_commission_type='direct_bdo' then
    select status,calculated_amount_ngn into v_status,v_amount from public.commission_ledger where id=p_entry_id and adjustment_of is not null for update;
    if not found then raise no_data_found using message='Recovery adjustment was not found'; end if;
    if v_status<>'adjusted' or v_amount>=0 or not exists(select 1 from public.commission_ledger original
      where original.id=(select adjustment_of from public.commission_ledger where id=p_entry_id) and original.status='paid') then
      raise object_not_in_prerequisite_state using message='Only adjustments for previously paid commissions can be reviewed'; end if;
    update public.commission_ledger set recovery_review_status=case when p_approve then 'approved' else 'declined' end,
      recovery_reviewer_id=v_actor,recovery_reviewed_at=now(),recovery_review_reason=btrim(p_reason) where id=p_entry_id;
  elsif p_commission_type='marketer' then
    select status,calculated_amount_ngn into v_status,v_amount from public.marketer_commission_ledger where id=p_entry_id and adjustment_of is not null for update;
    if not found then raise no_data_found using message='Recovery adjustment was not found'; end if;
    if v_status<>'adjusted' or v_amount>=0 or not exists(select 1 from public.marketer_commission_ledger original
      where original.id=(select adjustment_of from public.marketer_commission_ledger where id=p_entry_id) and original.status='paid') then
      raise object_not_in_prerequisite_state using message='Only adjustments for previously paid commissions can be reviewed'; end if;
    update public.marketer_commission_ledger set recovery_review_status=case when p_approve then 'approved' else 'declined' end,
      recovery_reviewer_id=v_actor,recovery_reviewed_at=now(),recovery_review_reason=btrim(p_reason) where id=p_entry_id;
  else
    select status,calculated_amount_ngn into v_status,v_amount from public.bdo_marketer_share_ledger where id=p_entry_id and adjustment_of is not null for update;
    if not found then raise no_data_found using message='Recovery adjustment was not found'; end if;
    if v_status<>'adjusted' or v_amount>=0 or not exists(select 1 from public.bdo_marketer_share_ledger original
      where original.id=(select adjustment_of from public.bdo_marketer_share_ledger where id=p_entry_id) and original.status='paid') then
      raise object_not_in_prerequisite_state using message='Only adjustments for previously paid commissions can be reviewed'; end if;
    update public.bdo_marketer_share_ledger set recovery_review_status=case when p_approve then 'approved' else 'declined' end,
      recovery_reviewer_id=v_actor,recovery_reviewed_at=now(),recovery_review_reason=btrim(p_reason) where id=p_entry_id;
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('commission_recovery',p_entry_id,case when p_approve then 'commission_recovery_offset_approved' else 'commission_recovery_offset_declined' end,
      v_actor,array['recovery_review_status','recovery_reviewer_id','recovery_reviewed_at','recovery_review_reason']);
end $$;
revoke all on function public.review_commission_recovery(text,uuid,boolean,text) from public,anon;
grant execute on function public.review_commission_recovery(text,uuid,boolean,text) to authenticated;

create or replace function public.record_commission_payout(p_commission_type text,p_entry_ids uuid[],p_transfer_reference text)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_actor uuid:=auth.uid();v_recipient uuid;v_amount numeric(14,2);v_gross numeric(14,2);v_offset numeric(14,2):=0;
  v_count integer;v_batch uuid;v_entry record;v_due numeric(14,2);v_apply numeric(14,2);v_pending_offsets jsonb:='[]'::jsonb;v_offset_record jsonb;
begin
  if v_actor is null or not (public.has_role(v_actor,'finance') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    raise insufficient_privilege using message='Finance access required to record a payout or offset'; end if;
  if p_commission_type is null or p_commission_type not in ('direct_bdo','marketer','bdo_network_share') or coalesce(cardinality(p_entry_ids),0)=0
    or length(btrim(coalesce(p_transfer_reference,'')))>160 then
    raise check_violation using message='Choose approved commission entries and enter a transfer reference when a cash payment is due'; end if;
  if (select count(distinct id) from unnest(p_entry_ids) x(id))<>cardinality(p_entry_ids) then
    raise check_violation using message='Duplicate commission entries are not allowed'; end if;
  if p_commission_type='direct_bdo' then
    perform 1 from public.commission_ledger where id=any(p_entry_ids) order by id for update;
    select count(*),(array_agg(bdo_id))[1],sum(calculated_amount_ngn) into v_count,v_recipient,v_gross from public.commission_ledger
      where id=any(p_entry_ids) and status='approved' and calculated_amount_ngn>0 and reviewer_id<>v_actor and payout_batch_id is null;
  elsif p_commission_type='marketer' then
    perform 1 from public.marketer_commission_ledger where id=any(p_entry_ids) order by id for update;
    select count(*),(array_agg(marketer_user_id))[1],sum(calculated_amount_ngn) into v_count,v_recipient,v_gross from public.marketer_commission_ledger
      where id=any(p_entry_ids) and status='approved' and calculated_amount_ngn>0 and reviewer_id<>v_actor and payout_batch_id is null;
  else
    perform 1 from public.bdo_marketer_share_ledger where id=any(p_entry_ids) order by id for update;
    select count(*),(array_agg(bdo_user_id))[1],sum(calculated_amount_ngn) into v_count,v_recipient,v_gross from public.bdo_marketer_share_ledger
      where id=any(p_entry_ids) and status='approved' and calculated_amount_ngn>0 and reviewer_id<>v_actor and payout_batch_id is null;
  end if;
  if v_count<>cardinality(p_entry_ids) or v_recipient is null or v_gross<=0 then
    raise object_not_in_prerequisite_state using message='All entries must be approved, positive, unpaid, and reviewed by another user'; end if;
  if (p_commission_type='direct_bdo' and exists(select 1 from public.commission_ledger where id=any(p_entry_ids) and bdo_id<>v_recipient))
    or (p_commission_type='marketer' and exists(select 1 from public.marketer_commission_ledger where id=any(p_entry_ids) and marketer_user_id<>v_recipient))
    or (p_commission_type='bdo_network_share' and exists(select 1 from public.bdo_marketer_share_ledger where id=any(p_entry_ids) and bdo_user_id<>v_recipient)) then
    raise check_violation using message='A payout batch must contain one recipient only'; end if;

  -- Serialize offsets for this recipient and commission class against concurrent payouts.
  perform pg_advisory_xact_lock(hashtextextended(p_commission_type||':'||v_recipient::text,91));
  if p_commission_type='direct_bdo' then
    for v_entry in select id,(-calculated_amount_ngn - coalesce((select sum(a.amount_ngn) from public.commission_offset_applications a
      where a.commission_type='direct_bdo' and a.adjustment_entry_id=l.id),0)) due from public.commission_ledger l
      where bdo_id=v_recipient and adjustment_of is not null and calculated_amount_ngn<0 and recovery_review_status='approved'
        and not (recovery_reviewer_id=v_actor) order by created_at,id for update loop
      v_due:=greatest(v_entry.due,0);v_apply:=least(v_due,v_gross-v_offset);
      if v_apply>0 then v_pending_offsets:=v_pending_offsets||jsonb_build_array(jsonb_build_object('id',v_entry.id,'amount',v_apply));v_offset:=v_offset+v_apply;end if;
      exit when v_offset>=v_gross;
    end loop;
  elsif p_commission_type='marketer' then
    for v_entry in select id,(-calculated_amount_ngn - coalesce((select sum(a.amount_ngn) from public.commission_offset_applications a
      where a.commission_type='marketer' and a.adjustment_entry_id=l.id),0)) due from public.marketer_commission_ledger l
      where marketer_user_id=v_recipient and adjustment_of is not null and calculated_amount_ngn<0 and recovery_review_status='approved'
        and recovery_reviewer_id<>v_actor order by created_at,id for update loop
      v_due:=greatest(v_entry.due,0);v_apply:=least(v_due,v_gross-v_offset);
      if v_apply>0 then v_pending_offsets:=v_pending_offsets||jsonb_build_array(jsonb_build_object('id',v_entry.id,'amount',v_apply));v_offset:=v_offset+v_apply;end if;
      exit when v_offset>=v_gross;
    end loop;
  else
    for v_entry in select id,(-calculated_amount_ngn - coalesce((select sum(a.amount_ngn) from public.commission_offset_applications a
      where a.commission_type='bdo_network_share' and a.adjustment_entry_id=l.id),0)) due from public.bdo_marketer_share_ledger l
      where bdo_user_id=v_recipient and adjustment_of is not null and calculated_amount_ngn<0 and recovery_review_status='approved'
        and recovery_reviewer_id<>v_actor order by created_at,id for update loop
      v_due:=greatest(v_entry.due,0);v_apply:=least(v_due,v_gross-v_offset);
      if v_apply>0 then v_pending_offsets:=v_pending_offsets||jsonb_build_array(jsonb_build_object('id',v_entry.id,'amount',v_apply));v_offset:=v_offset+v_apply;end if;
      exit when v_offset>=v_gross;
    end loop;
  end if;
  v_amount:=v_gross-v_offset;
  if v_amount>0 and nullif(btrim(p_transfer_reference),'') is null then
    raise check_violation using message='Enter the actual transfer reference for the remaining cash payment'; end if;
  if v_amount=0 and nullif(btrim(p_transfer_reference),'') is not null then
    raise check_violation using message='No bank transfer is due because the approved offset covers this payout'; end if;
  insert into public.commission_payout_batches(commission_type,recipient_user_id,transfer_reference,amount_ngn,gross_amount_ngn,
    offset_amount_ngn,entry_count,paid_by)
    values(p_commission_type,v_recipient,case when v_amount=0 then null else btrim(p_transfer_reference) end,v_amount,v_gross,v_offset,cardinality(p_entry_ids),v_actor)
    returning id into v_batch;
  for v_offset_record in select value from jsonb_array_elements(v_pending_offsets) loop
    insert into public.commission_offset_applications(commission_type,adjustment_entry_id,payout_batch_id,amount_ngn,applied_by)
      values(p_commission_type,(v_offset_record->>'id')::uuid,v_batch,(v_offset_record->>'amount')::numeric,v_actor);
  end loop;
  if p_commission_type='direct_bdo' then
    update public.commission_ledger set status='paid',payout_batch_id=v_batch,payout_reference=case when v_amount=0 then null else btrim(p_transfer_reference) end where id=any(p_entry_ids);
  elsif p_commission_type='marketer' then
    update public.marketer_commission_ledger set status='paid',payout_batch_id=v_batch,payout_reference=case when v_amount=0 then null else btrim(p_transfer_reference) end where id=any(p_entry_ids);
  else
    update public.bdo_marketer_share_ledger set status='paid',payout_batch_id=v_batch,payout_reference=case when v_amount=0 then null else btrim(p_transfer_reference) end where id=any(p_entry_ids);
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('commission_payout_batch',v_batch,case when v_amount=0 then 'commission_offset_applied' else 'commission_payout_recorded_with_offset' end,
      v_actor,array['commission_type','recipient_user_id','transfer_reference','amount_ngn','gross_amount_ngn','offset_amount_ngn','entry_count','paid_by']);
  return v_batch;
end $$;
revoke all on function public.record_commission_payout(text,uuid[],text) from public,anon;
grant execute on function public.record_commission_payout(text,uuid[],text) to authenticated;

drop function public.list_commission_work_queue();
create function public.list_commission_work_queue()
returns table(entry_id uuid,commission_type text,recipient_user_id uuid,recipient_name text,recipient_email text,
  job_number text,amount_ngn numeric,status text,receipt_reference text,payout_reference text,reviewer_id uuid,created_at timestamptz,
  recovery_review_status text,recovery_reviewer_id uuid,offset_applied_ngn numeric,recovery_eligible boolean)
language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
begin
  if not (public.has_role(auth.uid(),'finance') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')) then
    raise insufficient_privilege using message='Finance access required'; end if;
  return query
    select l.id,'direct_bdo'::text,l.bdo_id,p.full_name,u.email,j.job_number,l.calculated_amount_ngn,l.status,l.payment_reference,l.payout_reference,l.reviewer_id,l.created_at,
      l.recovery_review_status,l.recovery_reviewer_id,coalesce((select sum(a.amount_ngn) from public.commission_offset_applications a where a.commission_type='direct_bdo' and a.adjustment_entry_id=l.id),0),
      l.adjustment_of is not null and exists(select 1 from public.commission_ledger original where original.id=l.adjustment_of and original.status='paid')
      from public.commission_ledger l join public.jobs j on j.id=l.job_id join auth.users u on u.id=l.bdo_id left join public.profiles p on p.user_id=l.bdo_id
      where l.status in ('calculated','under_review','approved','declined','paid','adjusted','reversed')
    union all
    select l.id,'marketer'::text,l.marketer_user_id,p.full_name,u.email,j.job_number,l.calculated_amount_ngn,l.status,l.payment_reference,l.payout_reference,l.reviewer_id,l.created_at,
      l.recovery_review_status,l.recovery_reviewer_id,coalesce((select sum(a.amount_ngn) from public.commission_offset_applications a where a.commission_type='marketer' and a.adjustment_entry_id=l.id),0),
      l.adjustment_of is not null and exists(select 1 from public.marketer_commission_ledger original where original.id=l.adjustment_of and original.status='paid')
      from public.marketer_commission_ledger l join public.jobs j on j.id=l.job_id join auth.users u on u.id=l.marketer_user_id left join public.profiles p on p.user_id=l.marketer_user_id
      where l.status in ('calculated','under_review','approved','declined','paid','adjusted','reversed')
    union all
    select l.id,'bdo_network_share'::text,l.bdo_user_id,p.full_name,u.email,j.job_number,l.calculated_amount_ngn,l.status,l.payment_reference,l.payout_reference,l.reviewer_id,l.created_at,
      l.recovery_review_status,l.recovery_reviewer_id,coalesce((select sum(a.amount_ngn) from public.commission_offset_applications a where a.commission_type='bdo_network_share' and a.adjustment_entry_id=l.id),0),
      l.adjustment_of is not null and exists(select 1 from public.bdo_marketer_share_ledger original where original.id=l.adjustment_of and original.status='paid')
      from public.bdo_marketer_share_ledger l join public.jobs j on j.id=l.job_id join auth.users u on u.id=l.bdo_user_id left join public.profiles p on p.user_id=l.bdo_user_id
      where l.status in ('calculated','under_review','approved','declined','paid','adjusted','reversed')
    order by created_at desc limit 1000;
end $$;
revoke all on function public.list_commission_work_queue() from public,anon;
grant execute on function public.list_commission_work_queue() to authenticated;

drop function public.list_my_commission_payouts();
create function public.list_my_commission_payouts()
returns table(id uuid,commission_type text,amount_ngn numeric,entry_count integer,transfer_reference text,paid_at timestamptz,
  gross_amount_ngn numeric,offset_amount_ngn numeric)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if auth.uid() is null or not (public.has_role(auth.uid(),'bdo') or public.has_role(auth.uid(),'marketer')) then
    raise insufficient_privilege using message='BDO or marketer account required'; end if;
  return query select b.id,b.commission_type,b.amount_ngn,b.entry_count,b.transfer_reference,b.paid_at,b.gross_amount_ngn,b.offset_amount_ngn
    from public.commission_payout_batches b where b.recipient_user_id=auth.uid() order by b.paid_at desc limit 200;
end $$;
revoke all on function public.list_my_commission_payouts() from public,anon;
grant execute on function public.list_my_commission_payouts() to authenticated;
