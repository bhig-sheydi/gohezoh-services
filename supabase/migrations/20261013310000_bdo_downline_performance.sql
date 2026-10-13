create or replace function public.list_my_bdo_marketer_performance()
returns table(
  marketer_user_id uuid,
  email text,
  full_name text,
  active boolean,
  customer_count bigint,
  active_customer_count bigint,
  qualifying_transactions bigint,
  qualifying_volume_ngn numeric,
  commission_earned_ngn numeric,
  pending_commission_ngn numeric,
  approved_commission_ngn numeric,
  paid_commission_ngn numeric
)
language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
begin
  if not public.has_role(auth.uid(),'bdo') then
    raise insufficient_privilege using message='Approved BDO access required';
  end if;

  return query
  select bm.marketer_user_id,u.email,p.full_name,bm.active,
    coalesce(c.customer_count,0),coalesce(c.active_customer_count,0),
    coalesce(l.qualifying_transactions,0),coalesce(l.qualifying_volume_ngn,0),
    coalesce(l.commission_earned_ngn,0),coalesce(l.pending_commission_ngn,0),
    coalesce(l.approved_commission_ngn,0),coalesce(l.paid_commission_ngn,0)
  from public.bdo_marketers bm
  join auth.users u on u.id=bm.marketer_user_id
  left join public.profiles p on p.user_id=bm.marketer_user_id
  left join lateral (
    select count(*) as customer_count,
      count(*) filter (where c.status='active') as active_customer_count
    from public.customers c where c.referred_by_marketer_id=bm.marketer_user_id
  ) c on true
  left join lateral (
    select count(distinct l.payment_id) filter (where l.status in ('calculated','under_review','approved','paid')) as qualifying_transactions,
      coalesce(sum(l.eligible_amount_ngn) filter (where l.status in ('calculated','under_review','approved','paid')),0) as qualifying_volume_ngn,
      coalesce(sum(l.calculated_amount_ngn) filter (where l.status in ('calculated','under_review','approved','paid','adjusted')),0) as commission_earned_ngn,
      coalesce(sum(l.calculated_amount_ngn) filter (where l.status in ('calculated','under_review')),0) as pending_commission_ngn,
      coalesce(sum(l.calculated_amount_ngn) filter (where l.status='approved'),0) as approved_commission_ngn,
      coalesce(sum(l.calculated_amount_ngn) filter (where l.status='paid'),0) as paid_commission_ngn
    from public.marketer_commission_ledger l where l.marketer_user_id=bm.marketer_user_id
  ) l on true
  where bm.bdo_user_id=auth.uid()
  order by bm.active desc,coalesce(p.full_name,u.email);
end $$;
revoke all on function public.list_my_bdo_marketer_performance() from public,anon,authenticated;
grant execute on function public.list_my_bdo_marketer_performance() to authenticated;
