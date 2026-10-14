-- Versioned job contribution commission policy and deterministic role allocation.
-- Accrual is wired to this policy in the follow-up migration after attribution
-- sources and performing partner legs are normalized.

create table public.commission_role_pool_policies (
  id uuid primary key default gen_random_uuid(),
  version integer not null unique check (version > 0),
  marketer_rate numeric(7,6) not null default 0.10 check (marketer_rate between 0 and 1),
  bdo_rate_with_marketer numeric(7,6) not null default 0.05 check (bdo_rate_with_marketer between 0 and 1),
  bdo_only_rate numeric(7,6) not null default 0.10 check (bdo_only_rate between 0 and 1),
  contribution_basis text not null default 'reconciled_job_financials',
  agreement_reference text not null check (length(btrim(agreement_reference)) between 3 and 120),
  effective_from date not null,
  effective_until date,
  approved_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (effective_until is null or effective_until >= effective_from),
  check (marketer_rate + bdo_rate_with_marketer <= 1)
);
alter table public.commission_role_pool_policies enable row level security;
revoke all on public.commission_role_pool_policies from public, anon, authenticated;
grant select on public.commission_role_pool_policies to authenticated;
create policy commission_role_pool_policy_read on public.commission_role_pool_policies
  for select to authenticated using (
    public.has_role(auth.uid(),'finance') or public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')
  );

create or replace function public.approve_commission_role_pool_policy(
  p_agreement_reference text,
  p_effective_from date,
  p_reason text,
  p_marketer_rate numeric default 0.10,
  p_bdo_rate_with_marketer numeric default 0.05,
  p_bdo_only_rate numeric default 0.10
) returns uuid
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_id uuid; v_version integer;
begin
  if not (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'management')) then
    raise insufficient_privilege using message='Management approval required';
  end if;
  if nullif(btrim(p_agreement_reference),'') is null or length(btrim(p_agreement_reference))>120
    or nullif(btrim(p_reason),'') is null or length(btrim(p_reason))>500
    or p_effective_from is null or p_effective_from<current_date
    or p_marketer_rate is null or p_marketer_rate<0 or p_marketer_rate>1
    or p_bdo_rate_with_marketer is null or p_bdo_rate_with_marketer<0 or p_bdo_rate_with_marketer>1
    or p_bdo_only_rate is null or p_bdo_only_rate<0 or p_bdo_only_rate>1
    or p_marketer_rate+p_bdo_rate_with_marketer>1 then
    raise check_violation using message='Valid agreement, future/current effective date, approval reason and commission rates are required';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('commission_role_pool_policy',0));
  if exists(select 1 from public.commission_role_pool_policies where effective_from>=p_effective_from) then
    raise check_violation using message='A new commission policy must start after the existing policy';
  end if;
  update public.commission_role_pool_policies set effective_until=p_effective_from-1 where effective_until is null;
  select coalesce(max(version),0)+1 into v_version from public.commission_role_pool_policies;
  insert into public.commission_role_pool_policies(version,marketer_rate,bdo_rate_with_marketer,bdo_only_rate,
    agreement_reference,effective_from,approved_by)
  values(v_version,p_marketer_rate,p_bdo_rate_with_marketer,p_bdo_only_rate,btrim(p_agreement_reference),p_effective_from,auth.uid())
  returning id into v_id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
  values('commission_role_pool_policy',v_id,'approved:'||btrim(p_reason),auth.uid(),
    array['version','marketer_rate','bdo_rate_with_marketer','bdo_only_rate','agreement_reference','effective_from']);
  return v_id;
end $$;
revoke all on function public.approve_commission_role_pool_policy(text,date,text,numeric,numeric,numeric) from public,anon;
grant execute on function public.approve_commission_role_pool_policy(text,date,text,numeric,numeric,numeric) to authenticated;

-- Pure allocator used by the accrual service and tests. It assigns the 10%
-- marketer budget and 5% BDO budget when marketers participate; otherwise
-- unique BDOs divide 10%. Each budget is split evenly within its role, with
-- leftover kobo assigned by ascending user UUID for stable/idempotent results.
create or replace function public.calculate_commission_role_allocations(
  p_contribution numeric,
  p_marketer_users uuid[],
  p_bdo_users uuid[],
  p_marketer_rate numeric default 0.10,
  p_bdo_rate_with_marketer numeric default 0.05,
  p_bdo_only_rate numeric default 0.10
) returns table(recipient_user_id uuid,recipient_role text,allocation_ngn numeric(14,2))
language sql immutable set search_path=pg_catalog as $$
  with normalized as (
    select greatest(coalesce(p_contribution,0),0)::numeric as contribution,
      coalesce((select array_agg(distinct u order by u) from unnest(coalesce(p_marketer_users,'{}'::uuid[])) u where u is not null),'{}'::uuid[]) as marketers,
      coalesce((select array_agg(distinct u order by u) from unnest(coalesce(p_bdo_users,'{}'::uuid[])) u where u is not null),'{}'::uuid[]) as bdos
  ), role_budgets as (
    select n.*,
      case when cardinality(marketers)>0 then round(contribution*p_marketer_rate,2) else 0::numeric end as marketer_budget,
      case when cardinality(marketers)>0 then round(contribution*p_bdo_rate_with_marketer,2)
        when cardinality(bdos)>0 then round(contribution*p_bdo_only_rate,2) else 0::numeric end as bdo_budget
    from normalized n
  ), role_people as (
    select 'marketer'::text as role, unnest(marketers) as user_id, marketer_budget as budget from role_budgets
    union all
    select 'bdo'::text, unnest(bdos), bdo_budget from role_budgets
  ), split as (
    select role,user_id,budget,
      floor(budget*100 / count(*) over(partition by role))::bigint as base_cents,
      row_number() over(partition by role order by user_id) as position,
      round(budget*100)::bigint as total_cents,
      count(*) over(partition by role) as role_count
    from role_people where budget>0
  )
  select user_id,role,((base_cents + case when position <= total_cents-(base_cents*role_count) then 1 else 0 end)::numeric/100)::numeric(14,2)
  from split order by role,user_id;
$$;
revoke all on function public.calculate_commission_role_allocations(numeric,uuid[],uuid[],numeric,numeric,numeric) from public,anon,authenticated;
grant execute on function public.calculate_commission_role_allocations(numeric,uuid[],uuid[],numeric,numeric,numeric) to authenticated;
comment on function public.calculate_commission_role_allocations(numeric,uuid[],uuid[],numeric,numeric,numeric) is
  'Deterministic equal allocation within the confirmed marketer and BDO role budgets; not yet a payout/accrual entry point.';
