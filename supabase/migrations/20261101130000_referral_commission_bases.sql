-- Customer referrals earn on collected customer charges; partner referrals earn
-- on the approved company payable. Neither calculation exposes the platform cut.
alter table public.customer_referral_earnings
  add column commission_base_ngn numeric(14,2) not null default 0 check(commission_base_ngn>=0);
alter table public.customer_referral_earnings drop column platform_share_ngn;

create or replace function public.refresh_customer_referral_earnings(p_job_id uuid) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype;v_completed timestamptz;v_charge numeric:=0;v_partner_payable numeric:=0;v_referrer uuid;v_side text;v_base numeric;
begin
  select * into v_job from public.jobs where id=p_job_id for update;
  if not found then return; end if;
  select min(h.changed_at) into v_completed from public.job_status_history h
    where h.job_id=p_job_id and h.new_status='delivered';
  if v_job.status in ('delivered','closed') then
    v_completed:=coalesce(v_completed,now());
    select least(f.customer_revenue,coalesce(sum(cp.amount) filter(where cp.status='received' and cp.currency='NGN'),0)),
      case when f.customer_revenue>0 then
        round(f.partner_cost * least(f.customer_revenue,coalesce(sum(cp.amount) filter(where cp.status='received' and cp.currency='NGN'),0)) / f.customer_revenue,2)
      else 0 end into v_charge,v_partner_payable
      from public.job_financials f left join public.customer_payments cp on cp.job_id=f.job_id
      where f.job_id=p_job_id and f.currency='NGN'
      group by f.customer_revenue,f.partner_cost;
    v_charge:=coalesce(v_charge,0);
    -- A company referral earns only when the customer actually paid.
    v_partner_payable:=case when v_charge>0 then coalesce(v_partner_payable,0) else 0 end;
  end if;
  for v_side,v_referrer in
    select 'customer'::text,l.referrer_user_id from public.customer_referral_customer_links l where l.customer_id=v_job.customer_id
    union all
    select 'partner'::text,l.referrer_user_id from public.customer_referral_partner_links l where l.partner_id=v_job.partner_id
  loop
    v_base:=case when v_side='customer' then v_charge else v_partner_payable end;
    insert into public.customer_referral_earnings(job_id,side,referrer_user_id,eligible_charge_ngn,
      commission_base_ngn,earned_ngn,completed_at)
    values(p_job_id,v_side,v_referrer,v_charge,v_base,round(v_base*0.025,2),coalesce(v_completed,now()))
    on conflict(job_id,side) do update set eligible_charge_ngn=excluded.eligible_charge_ngn,
      commission_base_ngn=excluded.commission_base_ngn,earned_ngn=excluded.earned_ngn,updated_at=now();
  end loop;
end $$;

drop trigger refresh_customer_referral_on_financials on public.job_financials;
create trigger refresh_customer_referral_on_financials after insert or update of customer_revenue,partner_cost,currency on public.job_financials
for each row execute function public.refresh_customer_referral_on_financials();

do $$ declare v_id uuid; begin
  for v_id in select distinct job_id from public.customer_referral_earnings loop
    perform public.refresh_customer_referral_earnings(v_id);
  end loop;
end $$;
