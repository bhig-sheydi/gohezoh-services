-- Partners receive row-level-secured bid window events as soon as Operations publishes them.
do $$
begin
  if not exists (select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='delivery_quote_windows') then
    alter publication supabase_realtime add table public.delivery_quote_windows;
  end if;
end $$;
