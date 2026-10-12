-- One-shot proximity only. Coordinates submitted by the client are never stored.
create table public.proximity_sites (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 2 and 120),
  kind text not null check (kind in ('pickup','delivery','hub')),
  job_id uuid references public.jobs(id) on delete cascade,
  warehouse_id uuid references public.warehouses(id) on delete restrict,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  radius_metres integer not null check (radius_metres between 20 and 1000),
  is_active boolean not null default true,
  configured_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((kind='hub' and warehouse_id is not null and job_id is null)
    or (kind in ('pickup','delivery') and job_id is not null and warehouse_id is null))
);
create unique index proximity_sites_job_kind on public.proximity_sites(job_id,kind) where job_id is not null;
create unique index proximity_sites_warehouse_hub on public.proximity_sites(warehouse_id) where warehouse_id is not null;

create or replace function public.can_use_proximity_site(p_site_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select exists (
    select 1 from public.proximity_sites s where s.id=p_site_id and s.is_active and (
      public.has_role(auth.uid(),'operations') or public.has_role(auth.uid(),'admin')
      or public.has_role(auth.uid(),'management')
      or (s.kind='hub' and public.has_role(auth.uid(),'warehouse'))
      or (s.job_id is not null and exists (
        select 1 from public.jobs j where j.id=s.job_id and j.partner_id is not null
          and public.is_partner_user(j.partner_id)
          and exists(select 1 from public.partner_assignments pa where pa.job_id=j.id and pa.partner_id=j.partner_id and pa.status='accepted')
      ))
    )
  );
$$;
revoke all on function public.can_use_proximity_site(uuid) from public,anon;
grant execute on function public.can_use_proximity_site(uuid) to authenticated;

alter table public.proximity_sites enable row level security;
grant select on public.proximity_sites to authenticated;
create policy proximity_sites_read on public.proximity_sites for select to authenticated
  using(public.can_use_proximity_site(id));

create or replace function public.configure_proximity_site(
  p_name text,p_kind text,p_job_id uuid,p_warehouse_id uuid,
  p_latitude double precision,p_longitude double precision,p_radius_metres integer,
  p_site_id uuid default null
) returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_id uuid;
begin
  if not (public.has_role(v_actor,'operations') or public.has_role(v_actor,'admin') or public.has_role(v_actor,'management')) then
    raise insufficient_privilege using message='Operations access is required';
  end if;
  if p_kind='hub' and not (public.has_role(v_actor,'admin') or public.has_role(v_actor,'management')) then
    raise insufficient_privilege using message='Admin access is required to configure a hub';
  end if;
  if p_name is null or length(btrim(p_name)) not between 2 and 120 or p_kind not in ('pickup','delivery','hub')
    or p_kind is null or p_latitude is null or p_latitude not between -90 and 90
    or p_longitude is null or p_longitude not between -180 and 180
    or p_radius_metres is null or p_radius_metres not between 20 and 1000 then
    raise check_violation using message='Enter a valid proximity site and radius';
  end if;
  if p_kind='hub' then
    if p_job_id is not null or not exists(select 1 from public.warehouses where id=p_warehouse_id and is_active) then
      raise check_violation using message='Choose an active Gohezoh warehouse for the hub';end if;
  elsif p_warehouse_id is not null or not exists(select 1 from public.jobs where id=p_job_id) then
    raise check_violation using message='Choose a delivery job for this stop';
  end if;
  if p_site_id is null then
    insert into public.proximity_sites(name,kind,job_id,warehouse_id,latitude,longitude,radius_metres,configured_by)
      values(btrim(p_name),p_kind,p_job_id,p_warehouse_id,p_latitude,p_longitude,p_radius_metres,v_actor)
      returning id into v_id;
  else
    update public.proximity_sites set name=btrim(p_name),latitude=p_latitude,longitude=p_longitude,
      radius_metres=p_radius_metres,configured_by=v_actor,updated_at=now()
      where id=p_site_id and kind=p_kind and job_id is not distinct from p_job_id
        and warehouse_id is not distinct from p_warehouse_id returning id into v_id;
    if v_id is null then raise no_data_found using message='Proximity site was not found';end if;
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
    values('proximity_site',v_id,case when p_site_id is null then 'configured' else 'updated' end,v_actor,
      array['latitude','longitude','radius_metres']);
  return v_id;
end $$;
revoke all on function public.configure_proximity_site(text,text,uuid,uuid,double precision,double precision,integer,uuid) from public,anon,authenticated;
grant execute on function public.configure_proximity_site(text,text,uuid,uuid,double precision,double precision,integer,uuid) to authenticated;

create or replace function public.verify_proximity(
  p_site_id uuid,p_latitude double precision,p_longitude double precision,
  p_accuracy_metres double precision,p_captured_at timestamptz
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_site public.proximity_sites%rowtype;v_distance double precision;v_a double precision;v_status text;
begin
  if not public.can_use_proximity_site(p_site_id) then
    raise insufficient_privilege using message='This proximity site is not available to your account';
  end if;
  if p_latitude is null or p_latitude not between -90 and 90 or p_longitude is null or p_longitude not between -180 and 180
    or p_accuracy_metres is null or p_accuracy_metres <= 0 or p_accuracy_metres > 1000
    or p_captured_at is null or p_captured_at < now()-interval '2 minutes' or p_captured_at > now()+interval '1 minute' then
    raise check_violation using message='Request a fresh, accurate location reading';
  end if;
  select * into v_site from public.proximity_sites where id=p_site_id and is_active;
  v_a:=power(sin(radians(p_latitude-v_site.latitude)/2),2)
    +cos(radians(v_site.latitude))*cos(radians(p_latitude))
    *power(sin(radians(p_longitude-v_site.longitude)/2),2);
  v_distance:=6371000*2*asin(sqrt(least(1,greatest(0,v_a))));
  v_status:=case when v_distance+p_accuracy_metres<=v_site.radius_metres then 'in_range'
    when v_distance-p_accuracy_metres>v_site.radius_metres then 'out_of_range' else 'uncertain' end;
  return jsonb_build_object('status',v_status,'distance_metres',round(v_distance::numeric,0),
    'radius_metres',v_site.radius_metres,'accuracy_metres',round(p_accuracy_metres::numeric,0));
end $$;
revoke all on function public.verify_proximity(uuid,double precision,double precision,double precision,timestamptz) from public,anon,authenticated;
grant execute on function public.verify_proximity(uuid,double precision,double precision,double precision,timestamptz) to authenticated;
