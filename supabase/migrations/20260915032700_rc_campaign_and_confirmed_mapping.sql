-- Owner decision: AK is gross-up, AL unused. Original CSV headers retained for audit.
create table public.campaigns(
 id uuid primary key default gen_random_uuid(),
 campaign_code text unique not null check(btrim(campaign_code)<>''),
 campaign_name text not null,
 period_start_text text,
 period_end_text text,
 tax_status text,
 cashback_type text,
 source_snapshot_id uuid references staging.rc_snapshots(id),
 source_row bigint
);
alter table public.campaigns enable row level security;
revoke all on public.campaigns from public,anon,authenticated;
grant all on public.campaigns to service_role;
-- Client access will be assigned together with claims scope; not global master access.
insert into public.campaigns(campaign_code,campaign_name,period_start_text,period_end_text,
 tax_status,cashback_type,source_snapshot_id,source_row)
select btrim(data->>'Code'),data->>'Name',data->>'Periode Start',data->>'End',
data->>'Status Pajak',data->>'Jenis CB',snapshot_id,source_row
from staging.rc_latest_rows where source_name='rc-dev-anon' and sheet_name='ListCampaign'
and btrim(data->>'Code')<>'';

create view public.rc_claims_migration_candidates with (security_invoker=true) as
select r.snapshot_id,r.source_row,r.no_document,r.campaign_code,
r.depot_code,r.customer_code,r.legacy_status,r.proposed_status,
r.net_value_text,r.ak_dmd30_used_text as gross_up_text,
r.batch_upload,r.batch_release,r.batch_claim,r.batch_clearing
from public.rc_claims_review r
where btrim(r.no_document)<>''
and exists(select 1 from public.customers c where c.customer_code=btrim(r.customer_code))
and exists(select 1 from public.depots d where d.depot_code=btrim(r.depot_code));
revoke all on public.rc_claims_migration_candidates from public,anon,authenticated;
grant select on public.rc_claims_migration_candidates to service_role;
comment on view public.rc_claims_migration_candidates is
'Owner approved exclusion of missing business keys/customer references; AK is gross-up, AL unused. Financial/date validation still required; not operational claims.';

