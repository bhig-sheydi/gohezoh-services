-- Past service requests are now the customer's reusable delivery history.
-- Stop writing a second, single-item copy for every new request.
drop trigger if exists catalogue_customer_delivery_item_after_insert on public.service_requests;
drop function if exists public.catalogue_customer_delivery_item();
