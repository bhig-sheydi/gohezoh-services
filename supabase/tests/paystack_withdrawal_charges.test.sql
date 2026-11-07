begin;
do $$
declare v jsonb;
begin
  v:=public.quote_paystack_withdrawal(60);
  if (v->>'net_amount_ngn')::numeric<>50 or (v->>'gross_amount_ngn')::numeric<>60
    or (v->>'transfer_fee_ngn')::numeric<>10 or (v->>'stamp_duty_ngn')::numeric<>0 then
    raise exception 'Minimum transfer quote is wrong: %',v; end if;

  v:=public.quote_paystack_withdrawal(5011);
  if (v->>'net_amount_ngn')::numeric<>5000 or (v->>'gross_amount_ngn')::numeric<>5010
    or (v->>'remainder_ngn')::numeric<>1 then
    raise exception 'NGN 5,000 fee threshold overcharged: %',v; end if;
  v:=public.quote_paystack_withdrawal(5011.75);
  if (v->>'net_amount_ngn')::numeric<>5000 or (v->>'remainder_ngn')::numeric<>1.75 then
    raise exception 'Fractional available earnings were not preserved: %',v; end if;
  v:=public.quote_paystack_withdrawal(5026);
  if (v->>'net_amount_ngn')::numeric<>5001 or (v->>'transfer_fee_ngn')::numeric<>25
    or (v->>'gross_amount_ngn')::numeric<>5026 then
    raise exception 'Second fee band quote is wrong: %',v; end if;

  v:=public.quote_paystack_withdrawal(10074);
  if (v->>'net_amount_ngn')::numeric<>9999 or (v->>'gross_amount_ngn')::numeric<>10024
    or (v->>'remainder_ngn')::numeric<>50 or (v->>'stamp_duty_ngn')::numeric<>0 then
    raise exception 'Stamp-duty boundary quote overcharged: %',v; end if;
  v:=public.quote_paystack_withdrawal(10075);
  if (v->>'net_amount_ngn')::numeric<>10000 or (v->>'transfer_fee_ngn')::numeric<>25
    or (v->>'stamp_duty_ngn')::numeric<>50 or (v->>'gross_amount_ngn')::numeric<>10075 then
    raise exception 'Stamp-duty boundary quote is wrong: %',v; end if;

  v:=public.quote_paystack_withdrawal(50100);
  if (v->>'net_amount_ngn')::numeric<>50000 or (v->>'gross_amount_ngn')::numeric<>50075
    or (v->>'remainder_ngn')::numeric<>25 then
    raise exception 'NGN 50,000 fee threshold overcharged: %',v; end if;
  v:=public.quote_paystack_withdrawal(50101);
  if (v->>'net_amount_ngn')::numeric<>50001 or (v->>'transfer_fee_ngn')::numeric<>50
    or (v->>'gross_amount_ngn')::numeric<>50101 then
    raise exception 'Third fee band quote is wrong: %',v; end if;

  v:=public.quote_paystack_withdrawal(10000100);
  if (v->>'net_amount_ngn')::numeric<>10000000 or (v->>'gross_amount_ngn')::numeric<>10000100 then
    raise exception 'Maximum transfer quote is wrong: %',v; end if;

  begin
    perform public.paystack_withdrawal_charges(49);
    raise exception 'Below-minimum transfer was accepted';
  exception when check_violation then null; end;
  begin
    perform public.paystack_withdrawal_charges(10000001);
    raise exception 'Above-maximum transfer was accepted';
  exception when check_violation then null; end;
  begin
    perform public.paystack_withdrawal_charges(100.5);
    raise exception 'Fractional transfer was accepted';
  exception when check_violation then null; end;
end $$;
rollback;
