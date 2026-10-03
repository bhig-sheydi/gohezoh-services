-- Introduce the Business Development Officer role before any migration uses it.
alter type public.app_role add value if not exists 'bdo';
