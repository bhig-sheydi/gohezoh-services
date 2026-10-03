-- A shared row trigger must only reference columns belonging to its table.
create or replace function public.require_assigned_bdo_role()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not public.has_role(new.assigned_bdo_id,'bdo') then
    raise check_violation using message='Records must be assigned to a user with the BDO role';
  end if;

  if tg_op='INSERT' then
    if tg_table_name='leads_opportunities' then
      if new.stage<>'lead' or new.converted_customer_id is not null then
        raise check_violation using message='New leads must start in the lead stage';
      end if;
    elsif tg_table_name='partner_prospects' then
      if new.status<>'identified' or new.converted_partner_id is not null then
        raise check_violation using message='New partner prospects must start as identified';
      end if;
    end if;
  end if;

  return new;
end $$;
