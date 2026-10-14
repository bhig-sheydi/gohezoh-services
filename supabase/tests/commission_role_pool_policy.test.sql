begin;

do $$
declare
  v_count integer;
  v_total numeric;
  v_bdo_total numeric;
  v_marketer_a constant uuid:='00000000-0000-0000-0000-000000000001';
  v_marketer_b constant uuid:='00000000-0000-0000-0000-000000000002';
  v_bdo_a constant uuid:='00000000-0000-0000-0000-000000000011';
  v_bdo_b constant uuid:='00000000-0000-0000-0000-000000000012';
begin
  -- A single marketer and sponsor BDO receive the confirmed 10% / 5% shares.
  select count(*),sum(allocation_ngn) filter(where recipient_role='marketer'),
    sum(allocation_ngn) filter(where recipient_role='bdo')
    into v_count,v_total,v_bdo_total
    from public.calculate_commission_role_allocations(10000,array[v_marketer_a],array[v_bdo_a]);
  if v_count<>2 or v_total<>1000 or v_bdo_total<>500 then
    raise exception 'Expected marketer 1000 and BDO 500 from 10000 contribution';
  end if;

  -- Each role budget is split equally among unique people, even if a referral
  -- source appears repeatedly across customer and partner legs.
  if (select count(*) from public.calculate_commission_role_allocations(10000,
      array[v_marketer_a,v_marketer_a,v_marketer_b],array[v_bdo_a,v_bdo_b,v_bdo_a]))<>4 then
    raise exception 'Duplicate referrers were not deduplicated';
  end if;
  if (select sum(allocation_ngn) from public.calculate_commission_role_allocations(10000,
      array[v_marketer_a,v_marketer_a,v_marketer_b],array[v_bdo_a,v_bdo_b,v_bdo_a]
      ) where recipient_role='marketer')<>1000
    or (select sum(allocation_ngn) from public.calculate_commission_role_allocations(10000,
      array[v_marketer_a,v_marketer_a,v_marketer_b],array[v_bdo_a,v_bdo_b,v_bdo_a]
      ) where recipient_role='bdo')<>500 then
    raise exception 'Multi-person role shares did not reconcile to their budgets';
  end if;

  -- BDO-only jobs use 10%, split equally among unique BDOs.
  if (select sum(allocation_ngn) from public.calculate_commission_role_allocations(10000,
      '{}'::uuid[],array[v_bdo_a,v_bdo_b,v_bdo_a]))<>1000
    or (select min(allocation_ngn) from public.calculate_commission_role_allocations(10000,
      '{}'::uuid[],array[v_bdo_a,v_bdo_b,v_bdo_a]))<>500 then
    raise exception 'BDO-only allocation must split the 10%% budget equally';
  end if;

  -- No marketer sponsor means the marketer's 5% BDO budget remains unreleased.
  if (select sum(allocation_ngn) from public.calculate_commission_role_allocations(10000,
      array[v_marketer_a],'{}'::uuid[]))<>1000 then
    raise exception 'An unverified BDO share was released';
  end if;

  -- Deterministic kobo allocation: the 1001-kobo marketer budget splits as
  -- 334,334,333 and the BDO budget rounds to 501 kobo.
  select count(*),sum(allocation_ngn) into v_count,v_total
    from public.calculate_commission_role_allocations(100.10,
      array[v_marketer_a,v_marketer_b,'00000000-0000-0000-0000-000000000003'::uuid],array[v_bdo_a]);
  if v_count<>4 or v_total<>15.02 then
    raise exception 'Cent/kobo remainder did not reconcile across role budgets';
  end if;

  if exists(select 1 from public.calculate_commission_role_allocations(-500,
      array[v_marketer_a],array[v_bdo_a]) where allocation_ngn>0) then
    raise exception 'Negative contribution generated positive commission';
  end if;
end $$;

rollback;
