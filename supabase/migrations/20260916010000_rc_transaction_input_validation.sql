-- PENDING: apply through Supabase MCP, then run rc_input_validation.sql.
-- Keep the tested transactional implementation behind a strict validation boundary.
alter function rc_private.mutate_claims(text,jsonb,uuid,text) rename to mutate_claims_unchecked;
revoke all on function rc_private.mutate_claims_unchecked(text,jsonb,uuid,text) from public,anon,authenticated;

create or replace function rc_private.mutate_claims(p_action text,p_items jsonb,p_request_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare item jsonb; field record; month_value jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Items must be an array'; end if;
 if octet_length(p_items::text)>262144 then raise exception 'Payload exceeds 256 KiB'; end if;
 for item in select value from jsonb_array_elements(p_items) loop
  if jsonb_typeof(item)<>'object' then raise exception 'Each item must be an object'; end if;
  if jsonb_typeof(item->'no_doc') is distinct from 'string' or btrim(item->>'no_doc')='' or length(item->>'no_doc')>200
    or jsonb_typeof(item->'version_no') is distinct from 'number' or item->>'version_no' !~ '^[1-9][0-9]{0,17}$'
  then raise exception 'Invalid document or version'; end if;
  for field in select key,value from jsonb_each(item) loop
   if field.key not in('no_doc','version_no','tax_subject','total_billing','period_start','period_end','paid_on','approval','billing_months','ktp','npwp','bank','account_number','account_name','top')
   then raise exception 'Unknown item field'; end if;
   if field.key not in('version_no','total_billing','billing_months') then
    if jsonb_typeof(field.value)<>'string' or length(field.value#>>'{}')>2000 then raise exception 'Invalid text field'; end if;
   end if;
  end loop;
  if item ? 'total_billing' and (jsonb_typeof(item->'total_billing')<>'number'
    or item->>'total_billing' !~ '^[0-9]+([.][0-9]+)?$') then raise exception 'Billing must be a finite nonnegative number'; end if;
  if item ? 'period_start' and item->>'period_start'<>'' then
   if item->>'period_start' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Use ISO dates'; end if;
   perform (item->>'period_start')::date;
  end if;
  if item ? 'period_end' and item->>'period_end'<>'' then
   if item->>'period_end' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Use ISO dates'; end if;
   perform (item->>'period_end')::date;
  end if;
  if item ? 'paid_on' and item->>'paid_on'<>'' then
   if item->>'paid_on' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Use ISO dates'; end if;
   perform (item->>'paid_on')::date;
  end if;
  if item ? 'billing_months' then
   if jsonb_typeof(item->'billing_months')<>'array' then raise exception 'Invalid billing months'; end if;
   if jsonb_array_length(item->'billing_months')>4 then raise exception 'Maximum four billing months'; end if;
   for month_value in select value from jsonb_array_elements(item->'billing_months') loop
    if jsonb_typeof(month_value)<>'string' or month_value#>>'{}' !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Use YYYY-MM billing months'; end if;
   end loop;
  end if;
 end loop;
 return rc_private.mutate_claims_unchecked(p_action,p_items,p_request_id,p_reason);
end $$;
revoke all on function rc_private.mutate_claims(text,jsonb,uuid,text) from public,anon;
grant execute on function rc_private.mutate_claims(text,jsonb,uuid,text) to authenticated;
-- Rebind explicitly in case the public wrapper has retained the old function OID.
create or replace function public.rc_process_claims(p_action text,p_items jsonb,p_request_id uuid,p_reason text default '')
returns jsonb language sql security invoker set search_path='' as $$
select rc_private.mutate_claims(p_action,p_items,p_request_id,p_reason); $$;
alter table public.claims add constraint claim_period_order check(period_start is null or period_end is null or period_end>=period_start);
