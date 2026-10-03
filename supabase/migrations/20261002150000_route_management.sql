-- Operations routes are tied to a job's actual cities and assigned partner.
create or replace function public.guard_job_route_consistency()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_route public.routes%rowtype;
begin
  if new.route_id is null then return new; end if;
  select * into v_route from public.routes where id=new.route_id;
  if not found or not v_route.is_active then
    raise check_violation using message='Choose an active route';
  end if;
  if lower(btrim(v_route.origin_city))<>lower(btrim(new.pickup_city))
     or lower(btrim(v_route.destination_city))<>lower(btrim(new.delivery_city)) then
    raise check_violation using message='Route cities must match the job pickup and delivery cities';
  end if;
  if v_route.partner_id is not null and new.partner_id is not null and v_route.partner_id<>new.partner_id then
    raise check_violation using message='The route is assigned to a different logistics partner';
  end if;
  return new;
end $$;
create trigger jobs_guard_route_consistency
  before insert or update of route_id,partner_id,pickup_city,delivery_city on public.jobs
  for each row execute function public.guard_job_route_consistency();
revoke all on function public.guard_job_route_consistency() from public,anon,authenticated;

create or replace function public.prevent_referenced_route_changes()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if exists(select 1 from public.jobs where route_id=old.id) then
    raise object_not_in_prerequisite_state using message='A route assigned to a job cannot be changed';
  end if;
  return new;
end $$;
create trigger routes_prevent_referenced_changes
  before update of origin_city,destination_city,partner_id,is_active on public.routes
  for each row execute function public.prevent_referenced_route_changes();
revoke all on function public.prevent_referenced_route_changes() from public,anon,authenticated;
revoke delete on public.routes from authenticated;

create or replace function public.create_delivery_route(
  p_route_name text,p_origin_city text,p_destination_city text,
  p_origin_state text default null,p_destination_state text default null,p_partner_id uuid default null
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_route public.routes%rowtype;
begin
  if v_actor is null or not(public.has_role(v_actor,'operations') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    raise insufficient_privilege using message='Operations access is required to manage routes';
  end if;
  if length(btrim(coalesce(p_route_name,''))) not between 2 and 120
     or length(btrim(coalesce(p_origin_city,''))) not between 2 and 100
     or length(btrim(coalesce(p_destination_city,''))) not between 2 and 100 then
    raise check_violation using message='Enter a route name and both cities';
  end if;
  if p_partner_id is not null and not exists(select 1 from public.logistics_partners where id=p_partner_id and status='active') then
    raise check_violation using message='A route partner must be active';
  end if;
  insert into public.routes(route_name,origin_city,origin_state,destination_city,destination_state,partner_id)
  values(btrim(p_route_name),btrim(p_origin_city),nullif(btrim(p_origin_state),''),btrim(p_destination_city),nullif(btrim(p_destination_state),''),p_partner_id)
  returning * into v_route;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
  values('route',v_route.id,'created',v_actor,array['route_name','origin_city','destination_city','partner_id']);
  return jsonb_build_object('route_id',v_route.id,'route_number',v_route.route_number);
end $$;
revoke all on function public.create_delivery_route(text,text,text,text,text,uuid) from public,anon,authenticated;
grant execute on function public.create_delivery_route(text,text,text,text,text,uuid) to authenticated;

create or replace function public.assign_job_route(p_job_id uuid,p_route_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_actor uuid:=auth.uid();v_job public.jobs%rowtype;v_route public.routes%rowtype;
begin
  if v_actor is null or not(public.has_role(v_actor,'operations') or public.has_role(v_actor,'management') or public.has_role(v_actor,'admin')) then
    raise insufficient_privilege using message='Operations access is required to assign a route';
  end if;
  select * into v_job from public.jobs where id=p_job_id for update;
  if not found then raise no_data_found using message='Delivery job was not found'; end if;
  if v_job.status in ('delivered','closed','cancelled') then
    raise object_not_in_prerequisite_state using message='A completed job cannot change route';
  end if;
  select * into v_route from public.routes where id=p_route_id;
  if not found or not v_route.is_active then raise check_violation using message='Choose an active route'; end if;
  update public.jobs set route_id=v_route.id where id=v_job.id;
  insert into public.audit_logs(entity_type,entity_id,action,actor_id,changed_fields)
  values('job',v_job.id,'route_assigned',v_actor,array['route_id']);
  return jsonb_build_object('job_id',v_job.id,'route_id',v_route.id,'route_number',v_route.route_number);
end $$;
revoke all on function public.assign_job_route(uuid,uuid) from public,anon,authenticated;
grant execute on function public.assign_job_route(uuid,uuid) to authenticated;
