-- Opt-in customer referral program. Each side earns 2.5% of Kwik-Parsel's
-- 25% share, or 0.625% of eligible collected job charges.
create table public.customer_referral_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  code text not null unique check (code ~ '^KP[A-F0-9]{10}$'),
  display_name text not null check (length(btrim(display_name)) between 3 and 40),
  joined_at timestamptz not null default now(),
  active boolean not null default true
);
alter table public.customer_referral_members enable row level security;
revoke all on public.customer_referral_members from public,anon,authenticated;

create function public.join_customer_referral_program(p_display_name text default null)
returns text language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_user uuid:=auth.uid();v_code text;v_name text;
begin
  if v_user is null or not public.has_role(v_user,'customer')
    or not exists(select 1 from public.customer_users cu where cu.user_id=v_user)
    or not exists(select 1 from auth.users u where u.id=v_user and u.email_confirmed_at is not null) then
    raise insufficient_privilege using message='Confirm your email and complete your customer profile first';
  end if;
  select code into v_code from public.customer_referral_members where user_id=v_user;
  if v_code is not null then return v_code; end if;
  v_name:=nullif(btrim(p_display_name),'');
  if v_name is null then v_name:='Marketer '||upper(substr(replace(v_user::text,'-',''),1,4)); end if;
  if length(v_name) not between 3 and 40 then raise check_violation using message='Choose a leaderboard name of 3 to 40 characters'; end if;
  for i in 1..5 loop
    v_code:='KP'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
    insert into public.customer_referral_members(user_id,code,display_name) values(v_user,v_code,v_name)
      on conflict do nothing;
    if found then return v_code; end if;
    select code into v_code from public.customer_referral_members where user_id=v_user;
    if v_code is not null then return v_code; end if;
  end loop;
  raise exception 'Could not create a unique referral code. Try again.';
end $$;
revoke all on function public.join_customer_referral_program(text) from public,anon;
grant execute on function public.join_customer_referral_program(text) to authenticated;

create table public.customer_referral_signup_intents (
  referred_user_id uuid primary key references auth.users(id) on delete cascade,
  referrer_user_id uuid not null references public.customer_referral_members(user_id),
  target_kind text not null check(target_kind in ('customer','partner')),
  code_snapshot text not null,
  captured_at timestamptz not null default now(),
  check(referred_user_id<>referrer_user_id)
);
alter table public.customer_referral_signup_intents enable row level security;
revoke all on public.customer_referral_signup_intents from public,anon,authenticated;

create function public.capture_customer_program_referral() returns trigger
language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_code text;v_referrer uuid;v_kind text;
begin
  v_code:=upper(nullif(btrim(new.raw_user_meta_data->>'referral_code'),''));
  if v_code is null or v_code !~ '^KP[A-F0-9]{10}$' then return new; end if;
  v_kind:=case when new.raw_user_meta_data->>'account_kind'='staff'
    and new.raw_user_meta_data->>'requested_role'='partner' then 'partner'
    when new.raw_user_meta_data->>'account_kind'='customer' then 'customer' else null end;
  if v_kind is null then raise check_violation using message='This referral code is for customer or logistics company signup'; end if;
  select user_id into v_referrer from public.customer_referral_members where code=v_code and active;
  if v_referrer is null then raise check_violation using message='Referral code is invalid or inactive'; end if;
  insert into public.customer_referral_signup_intents(referred_user_id,referrer_user_id,target_kind,code_snapshot)
  values(new.id,v_referrer,v_kind,v_code);
  return new;
end $$;
create trigger capture_customer_program_referral after insert on auth.users
for each row execute function public.capture_customer_program_referral();
revoke all on function public.capture_customer_program_referral() from public,anon,authenticated;

create table public.customer_referral_customer_links (
  customer_id uuid primary key references public.customers(id) on delete restrict,
  referrer_user_id uuid not null references public.customer_referral_members(user_id),
  linked_at timestamptz not null default now()
);
create index customer_referral_customer_by_referrer on public.customer_referral_customer_links(referrer_user_id);
alter table public.customer_referral_customer_links enable row level security;
revoke all on public.customer_referral_customer_links from public,anon,authenticated;

create function public.link_referred_customer() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  insert into public.customer_referral_customer_links(customer_id,referrer_user_id)
  select new.id,i.referrer_user_id from public.customer_referral_signup_intents i
  where i.referred_user_id=new.created_by and i.target_kind='customer'
    and i.referrer_user_id<>new.created_by
  on conflict do nothing;
  return new;
end $$;
create trigger link_referred_customer after insert on public.customers
for each row execute function public.link_referred_customer();
revoke all on function public.link_referred_customer() from public,anon,authenticated;

create table public.customer_referral_partner_links (
  partner_id uuid primary key references public.logistics_partners(id) on delete restrict,
  referrer_user_id uuid not null references public.customer_referral_members(user_id),
  linked_at timestamptz not null default now()
);
create index customer_referral_partner_by_referrer on public.customer_referral_partner_links(referrer_user_id);
alter table public.customer_referral_partner_links enable row level security;
revoke all on public.customer_referral_partner_links from public,anon,authenticated;

create function public.link_referred_partner() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.membership_role='manager'
    and not exists(select 1 from public.partner_users pu where pu.partner_id=new.partner_id
      and pu.user_id<>new.user_id and pu.membership_role='manager')
    and exists(select 1 from public.staff_applications a where a.user_id=new.user_id
      and a.requested_role='partner' and a.partner_invitation_id is null and a.partner_prospect_id is null) then
    insert into public.customer_referral_partner_links(partner_id,referrer_user_id)
    select new.partner_id,i.referrer_user_id from public.customer_referral_signup_intents i
    where i.referred_user_id=new.user_id and i.target_kind='partner'
    on conflict do nothing;
  end if;
  return new;
end $$;
create trigger link_referred_partner after insert on public.partner_users
for each row execute function public.link_referred_partner();
revoke all on function public.link_referred_partner() from public,anon,authenticated;

create table public.customer_referral_earnings (
  job_id uuid not null references public.jobs(id) on delete restrict,
  side text not null check(side in ('customer','partner')),
  referrer_user_id uuid not null references public.customer_referral_members(user_id),
  eligible_charge_ngn numeric(14,2) not null check(eligible_charge_ngn>=0),
  platform_share_ngn numeric(14,2) not null check(platform_share_ngn>=0),
  earned_ngn numeric(14,2) not null check(earned_ngn>=0),
  completed_at timestamptz not null,
  updated_at timestamptz not null default now(),
  primary key(job_id,side),
  check(earned_ngn<=platform_share_ngn)
);
create index customer_referral_earnings_rank on public.customer_referral_earnings(referrer_user_id,completed_at);
alter table public.customer_referral_earnings enable row level security;
revoke all on public.customer_referral_earnings from public,anon,authenticated;

create function public.refresh_customer_referral_earnings(p_job_id uuid) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_job public.jobs%rowtype;v_completed timestamptz;v_charge numeric;v_referrer uuid;v_side text;
begin
  select * into v_job from public.jobs where id=p_job_id for update;
  if not found then return; end if;
  select min(h.changed_at) into v_completed from public.job_status_history h
    where h.job_id=p_job_id and h.new_status='delivered';
  if v_job.status not in ('delivered','closed') then v_charge:=0;
  else
    v_completed:=coalesce(v_completed,now());
    select least(f.customer_revenue,coalesce(sum(cp.amount) filter(where cp.status='received' and cp.currency='NGN'),0))
      into v_charge from public.job_financials f left join public.customer_payments cp on cp.job_id=f.job_id
      where f.job_id=p_job_id and f.currency='NGN' group by f.customer_revenue;
    v_charge:=coalesce(v_charge,0);
  end if;
  for v_side,v_referrer in
    select 'customer'::text,l.referrer_user_id from public.customer_referral_customer_links l where l.customer_id=v_job.customer_id
    union all
    select 'partner'::text,l.referrer_user_id from public.customer_referral_partner_links l where l.partner_id=v_job.partner_id
  loop
    insert into public.customer_referral_earnings(job_id,side,referrer_user_id,eligible_charge_ngn,
      platform_share_ngn,earned_ngn,completed_at)
    values(p_job_id,v_side,v_referrer,v_charge,round(v_charge*0.25,2),round(v_charge*0.25*0.025,2),coalesce(v_completed,now()))
    on conflict(job_id,side) do update set eligible_charge_ngn=excluded.eligible_charge_ngn,
      platform_share_ngn=excluded.platform_share_ngn,earned_ngn=excluded.earned_ngn,updated_at=now();
  end loop;
end $$;
revoke all on function public.refresh_customer_referral_earnings(uuid) from public,anon,authenticated;

create function public.refresh_customer_referral_on_job() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  perform public.refresh_customer_referral_earnings(new.id); return new;
end $$;
create trigger refresh_customer_referral_on_job after update of status on public.jobs
for each row when (old.status is distinct from new.status) execute function public.refresh_customer_referral_on_job();

create function public.refresh_customer_referral_on_payment() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  perform public.refresh_customer_referral_earnings(new.job_id); return new;
end $$;
create trigger refresh_customer_referral_on_payment after insert or update of status,amount,currency on public.customer_payments
for each row execute function public.refresh_customer_referral_on_payment();

create function public.refresh_customer_referral_on_financials() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  perform public.refresh_customer_referral_earnings(new.job_id); return new;
end $$;
create trigger refresh_customer_referral_on_financials after insert or update of customer_revenue on public.job_financials
for each row execute function public.refresh_customer_referral_on_financials();

create function public.my_customer_referral_dashboard()
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_user uuid:=auth.uid();v_year integer;v_result jsonb;
begin
  if v_user is null or not public.has_role(v_user,'customer') then raise insufficient_privilege; end if;
  v_year:=extract(year from now() at time zone 'Africa/Lagos')::integer;
  with totals as (
    select m.user_id,m.display_name,m.code,
      coalesce(sum(e.earned_ngn) filter(where extract(year from e.completed_at at time zone 'Africa/Lagos')=v_year),0) as earned,
      coalesce(sum(x.charge_ngn),0) as job_value
    from public.customer_referral_members m
    left join public.customer_referral_earnings e on e.referrer_user_id=m.user_id
    left join lateral (
      select case when e.side='customer' or not exists(select 1 from public.customer_referral_earnings other
        where other.job_id=e.job_id and other.referrer_user_id=e.referrer_user_id and other.side='customer')
        then e.eligible_charge_ngn else 0 end as charge_ngn
      where extract(year from e.completed_at at time zone 'Africa/Lagos')=v_year
    ) x on true
    where m.active
    group by m.user_id,m.display_name,m.code
  ), ranked as (
    select *,row_number() over(order by job_value desc,earned desc,user_id) as rank from totals
  )
  select jsonb_build_object('year',v_year,'member',
    (select jsonb_build_object('code',r.code,'display_name',r.display_name,'rank',r.rank,
      'earned_ngn',r.earned,'completed_job_value_ngn',r.job_value) from ranked r where r.user_id=v_user),
    'leaders',coalesce((select jsonb_agg(jsonb_build_object('rank',r.rank,'display_name',r.display_name,
      'earned_ngn',r.earned,'completed_job_value_ngn',r.job_value) order by r.rank)
      from ranked r where r.rank<=10),'[]'::jsonb)) into v_result;
  return v_result;
end $$;
revoke all on function public.my_customer_referral_dashboard() from public,anon;
grant execute on function public.my_customer_referral_dashboard() to authenticated;

create function public.customer_referral_year_end_result(p_year integer)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_current integer:=extract(year from now() at time zone 'Africa/Lagos')::integer;v_result jsonb;
begin
  if auth.uid() is null or not public.has_role(auth.uid(),'customer') then raise insufficient_privilege; end if;
  if p_year is null or p_year<2026 or p_year>=v_current then
    return jsonb_build_object('status','not_final','year',p_year);
  end if;
  with job_values as (
    select e.referrer_user_id,e.job_id,max(e.eligible_charge_ngn) charge_ngn
    from public.customer_referral_earnings e
    where extract(year from e.completed_at at time zone 'Africa/Lagos')=p_year
    group by e.referrer_user_id,e.job_id
  ), scores as (
    select j.referrer_user_id,sum(j.charge_ngn) job_value_ngn,count(*) filter(where j.charge_ngn>0) job_count
    from job_values j group by j.referrer_user_id
  )
  select jsonb_build_object('status',case when s.referrer_user_id is null then 'no_qualifier' else 'provisional_winner' end,
    'year',p_year,'prize_ngn',1000000,'minimum_job_value_ngn',500000,
    'winner',case when s.referrer_user_id is null then null else jsonb_build_object(
      'display_name',m.display_name,'completed_job_value_ngn',s.job_value_ngn,'completed_jobs',s.job_count) end)
  into v_result from (select 1) x left join lateral (
    select * from scores where job_value_ngn>=500000
    order by job_value_ngn desc,job_count desc,referrer_user_id limit 1
  ) s on true left join public.customer_referral_members m on m.user_id=s.referrer_user_id;
  return v_result;
end $$;
revoke all on function public.customer_referral_year_end_result(integer) from public,anon;
grant execute on function public.customer_referral_year_end_result(integer) to authenticated;
