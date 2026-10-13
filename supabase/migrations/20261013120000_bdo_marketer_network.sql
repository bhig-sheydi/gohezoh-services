-- Marketers are invited by an approved BDO and still require Super Admin approval.
-- Referral attribution is for acquisition reporting only; it never enables commissions.

alter table public.staff_applications
  drop constraint if exists staff_applications_requested_role_check;
alter table public.staff_applications
  add column invited_by_bdo_id uuid references auth.users(id) on delete restrict,
  add constraint staff_applications_requested_role_check
    check (requested_role in ('operations','finance','bdo','warehouse','partner','management','marketer')),
  add constraint staff_applications_marketer_inviter_check
    check ((requested_role = 'marketer') = (invited_by_bdo_id is not null));

create table public.bdo_marketer_invites (
  id uuid primary key default gen_random_uuid(),
  bdo_user_id uuid not null references auth.users(id) on delete cascade,
  email text not null check (email = lower(btrim(email))),
  token_hash bytea not null unique,
  expires_at timestamptz not null default (now() + interval '14 days'),
  used_by uuid unique references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check (expires_at > created_at)
);
create index bdo_marketer_invites_owner_idx on public.bdo_marketer_invites(bdo_user_id,created_at desc);
alter table public.bdo_marketer_invites enable row level security;
revoke all on public.bdo_marketer_invites from public,anon,authenticated;

create table public.bdo_marketers (
  marketer_user_id uuid primary key references auth.users(id) on delete cascade,
  bdo_user_id uuid not null references auth.users(id) on delete restrict,
  invite_id uuid not null unique references public.bdo_marketer_invites(id) on delete restrict,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  check ((active and revoked_at is null) or (not active and revoked_at is not null))
);
create index bdo_marketers_owner_idx on public.bdo_marketers(bdo_user_id,active,created_at desc);
alter table public.bdo_marketers enable row level security;
revoke all on public.bdo_marketers from public,anon,authenticated;

create table public.marketer_referral_codes (
  id uuid primary key default gen_random_uuid(),
  marketer_user_id uuid not null unique references auth.users(id) on delete cascade,
  bdo_user_id uuid not null references auth.users(id) on delete restrict,
  code text not null unique check (code ~ '^M[A-Z0-9]{11}$'),
  created_at timestamptz not null default now()
);
alter table public.marketer_referral_codes enable row level security;
revoke all on public.marketer_referral_codes from public,anon,authenticated;

alter table public.customer_referral_intents
  add column marketer_user_id uuid references auth.users(id) on delete set null,
  add column marketer_referral_code_id uuid references public.marketer_referral_codes(id) on delete set null,
  add constraint customer_referral_intents_one_referrer
    check (not (referral_code_id is not null and marketer_referral_code_id is not null));
alter table public.customers
  add column referred_by_marketer_id uuid references auth.users(id) on delete set null;
create index customers_marketer_referral_idx on public.customers(referred_by_marketer_id,created_at desc)
  where referred_by_marketer_id is not null;

create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare
  v_role text;
  v_invite public.bdo_marketer_invites%rowtype;
  v_token text;
begin
  insert into public.profiles(user_id,full_name,email,phone)
  values(new.id,nullif(new.raw_user_meta_data->>'full_name',''),new.email,new.phone)
  on conflict(user_id) do nothing;

  if new.raw_user_meta_data->>'account_kind'='staff' then
    v_role:=new.raw_user_meta_data->>'requested_role';
    if v_role not in ('operations','finance','bdo','warehouse','partner','management','marketer') then
      raise check_violation using message='Choose a valid staff category';
    end if;
    if v_role='marketer' then
      v_token:=nullif(btrim(new.raw_user_meta_data->>'marketer_invite'),'');
      if v_token is null or length(v_token)<32 then
        raise insufficient_privilege using message='A valid BDO invitation is required to register as a marketer';
      end if;
      select * into v_invite from public.bdo_marketer_invites
      where token_hash=extensions.digest(v_token,'sha256')
        and email=lower(btrim(new.email)) and used_by is null and expires_at>now()
        and public.has_role(bdo_user_id,'bdo')
      for update;
      if not found then raise insufficient_privilege using message='This marketer invitation is invalid, expired, or for another email'; end if;
      update public.bdo_marketer_invites set used_by=new.id where id=v_invite.id;
      insert into public.staff_applications(user_id,requested_role,organization_name,invited_by_bdo_id)
      values(new.id,'marketer',nullif(btrim(new.raw_user_meta_data->>'organization_name'),''),v_invite.bdo_user_id);
    else
      insert into public.staff_applications(user_id,requested_role,organization_name)
      values(new.id,v_role::public.app_role,nullif(btrim(new.raw_user_meta_data->>'organization_name'),''));
    end if;
  else
    insert into public.user_roles(user_id,role) values(new.id,'customer') on conflict do nothing;
  end if;
  return new;
end $$;
revoke all on function public.handle_new_auth_user() from public,anon,authenticated;

create or replace function public.request_staff_access(p_role public.app_role,p_organization_name text default null)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_user uuid:=auth.uid();v_id uuid;
begin
  if v_user is null or not exists(select 1 from auth.users where id=v_user and email_confirmed_at is not null) then
    raise insufficient_privilege using message='Confirm your email before requesting staff access';
  end if;
  if p_role not in ('operations','finance','bdo','warehouse','partner','management') then
    raise check_violation using message='Marketer access is available only through a BDO invitation';
  end if;
  insert into public.staff_applications(user_id,requested_role,organization_name)
  values(v_user,p_role,nullif(btrim(p_organization_name),''))
  on conflict(user_id,requested_role) do update
    set organization_name=excluded.organization_name,status='pending',reviewed_by=null,reviewed_at=null,
      partner_document_type=null,partner_document_path=null,partner_document_submitted_at=null
  where staff_applications.status in ('rejected','revoked')
  returning id into v_id;
  if v_id is null then raise unique_violation using message='This staff request already exists';end if;
  return v_id;
end $$;

create or replace function public.create_bdo_marketer_invite(p_email text)
returns text language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_bdo uuid:=auth.uid();v_email text:=lower(btrim(p_email));v_token text;v_hash bytea;
begin
  if v_bdo is null or not public.has_role(v_bdo,'bdo') then
    raise insufficient_privilege using message='An approved BDO account is required';
  end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise check_violation using message='Enter a valid marketer email address';
  end if;
  if exists(select 1 from auth.users where lower(email)=v_email) then
    raise unique_violation using message='An account already exists for this email';
  end if;
  if exists(select 1 from public.bdo_marketer_invites where email=v_email and used_by is null and expires_at>now()) then
    raise unique_violation using message='An active invitation already exists for this email';
  end if;
  v_token:=encode(extensions.gen_random_bytes(32),'hex');
  v_hash:=extensions.digest(v_token,'sha256');
  insert into public.bdo_marketer_invites(bdo_user_id,email,token_hash) values(v_bdo,v_email,v_hash);
  return v_token;
end $$;
revoke all on function public.create_bdo_marketer_invite(text) from public,anon;
grant execute on function public.create_bdo_marketer_invite(text) to authenticated;

create or replace function public.list_my_bdo_marketers()
returns table(marketer_user_id uuid,email text,full_name text,active boolean,created_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
begin
  if not public.has_role(auth.uid(),'bdo') then raise insufficient_privilege using message='An approved BDO account is required';end if;
  return query select m.marketer_user_id,u.email,p.full_name,m.active,m.created_at
    from public.bdo_marketers m join auth.users u on u.id=m.marketer_user_id
    left join public.profiles p on p.user_id=m.marketer_user_id
    where m.bdo_user_id=auth.uid() order by m.created_at desc;
end $$;
revoke all on function public.list_my_bdo_marketers() from public,anon;
grant execute on function public.list_my_bdo_marketers() to authenticated;

create or replace function public.get_my_marketer_referral_code()
returns text language plpgsql security definer set search_path=pg_catalog,public,auth,extensions as $$
declare v_user uuid:=auth.uid();v_bdo uuid;v_code text;
begin
  select bdo_user_id into v_bdo from public.bdo_marketers
    where marketer_user_id=v_user and active and public.has_role(v_user,'marketer') and public.has_role(bdo_user_id,'bdo');
  if v_bdo is null then raise insufficient_privilege using message='An active, approved marketer account is required';end if;
  select code into v_code from public.marketer_referral_codes where marketer_user_id=v_user;
  if v_code is null then
    loop
      v_code:='M'||upper(substr(encode(extensions.gen_random_bytes(8),'hex'),1,11));
      insert into public.marketer_referral_codes(marketer_user_id,bdo_user_id,code) values(v_user,v_bdo,v_code)
        on conflict do nothing returning code into v_code;
      if v_code is null then select code into v_code from public.marketer_referral_codes where marketer_user_id=v_user; end if;
      exit when v_code is not null;
    end loop;
  end if;
  return v_code;
end $$;
revoke all on function public.get_my_marketer_referral_code() from public,anon;
grant execute on function public.get_my_marketer_referral_code() to authenticated;

create or replace function public.get_my_marketer_referral_count()
returns bigint language plpgsql stable security definer set search_path=pg_catalog,public,auth as $$
begin
  if not exists(select 1 from public.bdo_marketers where marketer_user_id=auth.uid() and active and public.has_role(auth.uid(),'marketer')) then
    raise insufficient_privilege using message='An active marketer account is required';
  end if;
  return (select count(*) from public.customers where referred_by_marketer_id=auth.uid());
end $$;
revoke all on function public.get_my_marketer_referral_count() from public,anon;
grant execute on function public.get_my_marketer_referral_count() to authenticated;

create or replace function public.review_staff_application(p_application_id uuid,p_approve boolean,p_partner_id uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,storage as $$
declare v_admin uuid:=auth.uid();v_request public.staff_applications%rowtype;v_email text;
begin
  if not public.has_role(v_admin,'admin') then raise insufficient_privilege using message='Super Admin access is required';end if;
  select * into v_request from public.staff_applications where id=p_application_id for update;
  if not found then raise no_data_found using message='Staff request was not found';end if;
  if v_request.status<>'pending' then raise object_not_in_prerequisite_state using message='This request has already been reviewed';end if;
  select email into v_email from auth.users where id=v_request.user_id and email_confirmed_at is not null;
  if p_approve and v_email is null then raise object_not_in_prerequisite_state using message='Applicant must confirm their email first';end if;
  if p_approve and v_request.requested_role='partner' then
    if v_request.partner_document_type is null or v_request.partner_document_path is null or not exists(
      select 1 from storage.objects o where o.bucket_id='partner-verification'
        and o.name=v_request.partner_document_path and o.owner_id=v_request.user_id::text
    ) then raise check_violation using message='Partner must submit a NIN or CAC document before approval';end if;
    if p_partner_id is null or not exists(select 1 from public.logistics_partners where id=p_partner_id and status='active') then
      raise check_violation using message='Choose an active logistics partner';
    end if;
    insert into public.partner_users(partner_id,user_id) values(p_partner_id,v_request.user_id) on conflict do nothing;
  elsif p_partner_id is not null then
    raise check_violation using message='A partner can only be selected for Partner access';
  end if;
  if p_approve and v_request.requested_role='marketer' then
    if v_request.invited_by_bdo_id is null or not public.has_role(v_request.invited_by_bdo_id,'bdo') or not exists(
      select 1 from public.bdo_marketer_invites i where i.used_by=v_request.user_id and i.bdo_user_id=v_request.invited_by_bdo_id
        and i.expires_at>v_request.created_at
    ) then raise check_violation using message='The BDO invitation is no longer valid';end if;
    insert into public.bdo_marketers(marketer_user_id,bdo_user_id,invite_id)
      select v_request.user_id,v_request.invited_by_bdo_id,i.id from public.bdo_marketer_invites i where i.used_by=v_request.user_id;
  end if;
  if p_approve then insert into public.user_roles(user_id,role) values(v_request.user_id,v_request.requested_role) on conflict do nothing;end if;
  update public.staff_applications set status=case when p_approve then 'approved' else 'rejected' end,
    reviewed_by=v_admin,reviewed_at=now() where id=v_request.id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('staff_application',v_request.id,case when p_approve then 'approved' else 'rejected' end,v_admin,array['status','requested_role']);
  return jsonb_build_object('user_id',v_request.user_id,'role',v_request.requested_role,'status',case when p_approve then 'approved' else 'rejected' end);
end $$;

create or replace function public.revoke_staff_access(p_user_id uuid,p_role public.app_role)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_admin uuid:=auth.uid();
begin
  if not public.has_role(v_admin,'admin') then raise insufficient_privilege using message='Super Admin access is required';end if;
  if p_role in ('admin','customer') then raise check_violation using message='Use the dedicated account process for this role';end if;
  delete from public.user_roles where user_id=p_user_id and role=p_role;
  if not found then raise no_data_found using message='This user does not have that role';end if;
  if p_role='partner' then delete from public.partner_users where user_id=p_user_id;end if;
  if p_role='marketer' then update public.bdo_marketers set active=false,revoked_at=now() where marketer_user_id=p_user_id and active;end if;
  update public.staff_applications set status='revoked',reviewed_by=v_admin,reviewed_at=now()
    where user_id=p_user_id and requested_role=p_role and status='approved';
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('user_role',p_user_id,'revoked',v_admin,array[p_role::text]);
end $$;

create or replace function public.capture_customer_referral_intent()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_code text;v_code_id uuid;v_marketer uuid;v_bdo uuid;
begin
  v_code:=upper(nullif(btrim(new.raw_user_meta_data->>'referral_code'),''));
  if new.raw_user_meta_data->>'account_kind' is distinct from 'staff' and v_code ~ '^[A-Z0-9]{8,16}$' then
    select rc.id,rc.marketer_user_id,rc.bdo_user_id into v_code_id,v_marketer,v_bdo
      from public.marketer_referral_codes rc join public.bdo_marketers bm on bm.marketer_user_id=rc.marketer_user_id
      where rc.code=v_code and bm.active and public.has_role(rc.marketer_user_id,'marketer') and public.has_role(rc.bdo_user_id,'bdo');
    if v_marketer is null then
      select c.id,c.bdo_user_id into v_code_id,v_bdo from public.bdo_referral_codes c
        where c.code=v_code and c.bdo_user_id<>new.id and public.has_role(c.bdo_user_id,'bdo');
    end if;
  end if;
  insert into public.customer_referral_intents(user_id,referral_code_id,marketer_user_id,marketer_referral_code_id)
    values(new.id,case when v_marketer is null then v_code_id else null end,v_marketer,
      case when v_marketer is not null then v_code_id else null end);
  return new;
end $$;

create or replace function public.register_customer_profile(
  p_company_name text,p_customer_type text,p_contact_person text,p_email text,p_phone text,
  p_address text default null,p_city text default null,p_state text default null
) returns uuid language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_user_id uuid:=auth.uid();v_customer_id uuid;v_referral_id uuid;v_bdo_id uuid;v_marketer_id uuid;
begin
  if v_user_id is null then raise exception 'Sign in is required to create a customer profile';end if;
  if not (public.has_role(v_user_id,'customer') or public.has_role(v_user_id,'operations') or public.has_role(v_user_id,'admin') or public.has_role(v_user_id,'management')) then
    raise exception 'This account cannot create a customer profile';
  end if;
  if nullif(btrim(p_company_name),'') is null or nullif(btrim(p_contact_person),'') is null or nullif(btrim(p_phone),'') is null then
    raise exception 'Customer name, contact name, and phone are required';
  end if;
  select customer_id into v_customer_id from public.customer_users where user_id=v_user_id order by created_at limit 1;
  if v_customer_id is not null then return v_customer_id;end if;
  select i.marketer_user_id,rc.bdo_user_id into v_marketer_id,v_bdo_id
    from public.customer_referral_intents i join public.marketer_referral_codes rc on rc.id=i.marketer_referral_code_id
    join public.bdo_marketers bm on bm.marketer_user_id=i.marketer_user_id and bm.active
    where i.user_id=v_user_id and public.has_role(i.marketer_user_id,'marketer') and public.has_role(rc.bdo_user_id,'bdo');
  if v_marketer_id is null then
    select c.id,c.bdo_user_id into v_referral_id,v_bdo_id from public.customer_referral_intents i
      join public.bdo_referral_codes c on c.id=i.referral_code_id where i.user_id=v_user_id and public.has_role(c.bdo_user_id,'bdo');
  end if;
  insert into public.customers(company_name,customer_type,contact_person,email,phone,address,city,state,status,created_by,assigned_bdo_id,referral_code_id,referred_by_marketer_id)
    values(btrim(p_company_name),coalesce(nullif(btrim(p_customer_type),''),'individual'),btrim(p_contact_person),nullif(btrim(p_email),''),btrim(p_phone),
      nullif(btrim(p_address),''),nullif(btrim(p_city),''),nullif(btrim(p_state),''),'pending',v_user_id,v_bdo_id,v_referral_id,v_marketer_id)
    returning id into v_customer_id;
  insert into public.customer_users(customer_id,user_id) values(v_customer_id,v_user_id);
  update public.profiles set full_name=btrim(p_contact_person),email=nullif(btrim(p_email),''),phone=btrim(p_phone) where user_id=v_user_id;
  if v_bdo_id is not null then insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('customer_referral',v_customer_id,'attributed_on_signup',v_user_id,array['assigned_bdo_id','referral_code_id','referred_by_marketer_id']);end if;
  return v_customer_id;
end $$;

create or replace function public.guard_customer_referral_attribution()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if current_user in ('anon','authenticated') then
    if tg_op='INSERT' and (new.assigned_bdo_id is not null or new.referral_code_id is not null or new.referred_by_marketer_id is not null) then
      if not (public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')) then raise insufficient_privilege using message='Customer referral attribution is system managed';end if;
    elsif tg_op='UPDATE' and (new.assigned_bdo_id is distinct from old.assigned_bdo_id or new.referral_code_id is distinct from old.referral_code_id or new.referred_by_marketer_id is distinct from old.referred_by_marketer_id) then
      if not (public.has_role(auth.uid(),'management') or public.has_role(auth.uid(),'admin')) then raise insufficient_privilege using message='Customer referral attribution is system managed';end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists customers_guard_referral_attribution on public.customers;
create trigger customers_guard_referral_attribution before insert or update of assigned_bdo_id,referral_code_id,referred_by_marketer_id
  on public.customers for each row execute function public.guard_customer_referral_attribution();
