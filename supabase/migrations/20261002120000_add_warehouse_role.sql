-- Warehouse operators can receive stock and fulfill orders without operations or finance access.
alter type public.app_role add value if not exists 'warehouse';
