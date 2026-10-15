-- Enforce the minimum on partner bids, customer quotes, and manually confirmed orders.
create or replace function public.enforce_dispatch_minimum_charge()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare
  v_service_code text;
  v_amount numeric;
begin
  if tg_table_name = 'partner_quotes' then
    v_amount := new.amount_ngn;
    select s.code into v_service_code from public.service_requests r
      join public.services s on s.id = r.service_id where r.id = new.request_id;
  elsif tg_table_name = 'customer_delivery_quotes' then
    v_amount := new.customer_price_ngn;
    select s.code into v_service_code from public.service_requests r
      join public.services s on s.id = r.service_id where r.id = new.request_id;
  else
    v_amount := new.customer_price;
    select s.code into v_service_code from public.services s where s.id = new.service_id;
  end if;
  if v_service_code in ('SRV-0001', 'SRV-0002') and v_amount is not null and v_amount < 1000 then
    raise exception 'Minimum delivery charge is NGN 1,000' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger partner_quote_dispatch_minimum before insert or update of amount_ngn, request_id
on public.partner_quotes for each row execute function public.enforce_dispatch_minimum_charge();
create trigger customer_quote_dispatch_minimum before insert or update of customer_price_ngn, request_id
on public.customer_delivery_quotes for each row execute function public.enforce_dispatch_minimum_charge();
create trigger order_dispatch_minimum before insert or update of customer_price, service_id
on public.orders for each row execute function public.enforce_dispatch_minimum_charge();
