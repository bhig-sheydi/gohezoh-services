-- Customer-owned saved destinations are shared only with accepted Parcel Pals.
create table public.customer_parcel_destinations (
  user_id uuid not null references auth.users(id) on delete cascade,
  slot smallint not null check (slot between 1 and 3),
  label text not null check (label in ('Work','Home','Other')),
  address text not null check (length(btrim(address)) between 1 and 300),
  city text not null check (length(btrim(city)) between 1 and 100),
  state text not null check (length(btrim(state)) between 1 and 100),
  secondary_phone text check (secondary_phone is null or length(btrim(secondary_phone)) between 3 and 32),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id,slot),
  constraint customer_parcel_destination_label_matches_slot check
    ((slot=1 and label='Work') or (slot=2 and label='Home') or (slot=3 and label='Other'))
);
create index customer_parcel_destinations_owner_idx on public.customer_parcel_destinations(user_id);
alter table public.customer_parcel_destinations enable row level security;
revoke all on public.customer_parcel_destinations from public,anon;
grant select,insert,update,delete on public.customer_parcel_destinations to authenticated;
create policy customer_parcel_destinations_owner on public.customer_parcel_destinations
for all to authenticated
using (user_id=auth.uid() and public.is_customer_parcel_pal_user(auth.uid()))
with check (user_id=auth.uid() and public.is_customer_parcel_pal_user(auth.uid()));

-- Expose saved addresses solely through the accepted-connection list RPC.
create or replace function public.list_my_parcel_pals()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth as $$
declare v_user uuid:=auth.uid(); v_result jsonb;
begin
  if v_user is null then raise insufficient_privilege using message='Sign in to view Parcel Pals'; end if;
  if not public.is_customer_parcel_pal_user(v_user) then raise insufficient_privilege using message='Parcel Pals are only available to customer accounts'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'code',c.code,'full_name',p.full_name,'phone',p.phone,'avatar_path',p.avatar_path,
    'address',addr.address,'city',addr.city,'state',addr.state,'destinations',coalesce(dest.items,'[]'::jsonb),
    'connected_at',x.responded_at
  ) order by p.full_name nulls last,c.code),'[]'::jsonb) into v_result
  from public.parcel_pal_connections x
  join public.parcel_pal_codes c on c.user_id=case when x.user_a=v_user then x.user_b else x.user_a end
  left join public.profiles p on p.user_id=c.user_id
  left join lateral (select cu.address,cu.city,cu.state from public.customer_users m join public.customers cu on cu.id=m.customer_id where m.user_id=c.user_id order by cu.created_at desc limit 1) addr on true
  left join lateral (select jsonb_agg(jsonb_build_object('slot',d.slot,'label',d.label,'address',d.address,'city',d.city,'state',d.state,'secondary_phone',d.secondary_phone) order by d.slot) as items from public.customer_parcel_destinations d where d.user_id=c.user_id) dest on true
  where v_user in (x.user_a,x.user_b) and x.status='accepted' and public.is_customer_parcel_pal_user(c.user_id);
  return v_result;
end;
$$;
revoke all on function public.list_my_parcel_pals() from public,anon;
grant execute on function public.list_my_parcel_pals() to authenticated;

alter table public.service_requests add column recipient_phone_secondary text;
alter table public.jobs add column recipient_phone_secondary text;

-- Existing request-to-job conversion remains unchanged; copy the optional number
-- from its request when the job is created.
create or replace function public.copy_request_recipient_secondary_phone()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if new.recipient_phone_secondary is null then
    select sr.recipient_phone_secondary into new.recipient_phone_secondary
    from public.orders o join public.service_requests sr on sr.id=o.service_request_id
    where o.id=new.order_id;
  end if;
  return new;
end;
$$;
revoke all on function public.copy_request_recipient_secondary_phone() from public,anon,authenticated;
create trigger jobs_copy_recipient_secondary_phone
before insert on public.jobs
for each row execute function public.copy_request_recipient_secondary_phone();\n