-- Browser requests are app-reported estimates. Shards avoid a hot daily counter row.
create table public.google_browser_usage_daily (
  usage_day date not null,
  sku text not null check (sku in ('places_text','places_nearby','geocoding','dynamic_maps','autocomplete_requests','place_details')),
  shard smallint not null check (shard between 0 and 63),
  request_count bigint not null default 0 check (request_count>=0),
  primary key (usage_day,sku,shard)
);
alter table public.google_browser_usage_daily enable row level security;
revoke all on public.google_browser_usage_daily from public,anon,authenticated;

create function public.record_google_browser_usage(p_counts jsonb) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_key text;v_count integer;v_total integer:=0;v_shard smallint;
begin
  if auth.uid() is null or auth.role()<>'authenticated' then
    raise insufficient_privilege using message='Sign in required';
  end if;
  if p_counts is null or jsonb_typeof(p_counts)<>'object'
     or (select count(*) from jsonb_object_keys(p_counts))>6 then
    raise check_violation using message='Invalid usage batch';
  end if;
  v_shard:=mod(abs(hashtext(auth.uid()::text)::bigint),64)::smallint;
  for v_key in select jsonb_object_keys(p_counts) loop
    if v_key not in ('places_text','places_nearby','geocoding','dynamic_maps','autocomplete_requests','place_details')
       or jsonb_typeof(p_counts->v_key)<>'number' then
      raise check_violation using message='Unknown Google usage category';
    end if;
    v_count:=(p_counts->>v_key)::integer;
    v_total:=v_total+v_count;
    if v_count<1 or v_count>100 or v_total>100 then
      raise check_violation using message='Usage batch is too large';
    end if;
    insert into public.google_browser_usage_daily(usage_day,sku,shard,request_count)
      values((now() at time zone 'UTC')::date,v_key,v_shard,v_count)
      on conflict (usage_day,sku,shard) do update
      set request_count=public.google_browser_usage_daily.request_count+excluded.request_count;
  end loop;
end $$;
revoke all on function public.record_google_browser_usage(jsonb) from public,anon,authenticated;
grant execute on function public.record_google_browser_usage(jsonb) to authenticated;
