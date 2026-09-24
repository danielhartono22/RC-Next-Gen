-- Corrected Compile header and credential-free Authority review.
create table staging.rc_authority_review(
 user_code text primary key,
 source_row integer not null,
 full_name text not null,
 email text not null,
 legacy_role text not null,
 legacy_status text not null,
 depot_code text not null,
 suffix_num text not null,
 permissions jsonb not null,
 reviewed_at timestamptz not null default now()
);
alter table staging.rc_authority_review enable row level security;
revoke all on staging.rc_authority_review from public,anon,authenticated;
grant select,insert,update on staging.rc_authority_review to service_role;
-- Replace positional legacy label with the corrected source header.
create or replace view public.rc_claims_migration_candidates with (security_invoker=true) as
select r.snapshot_id,r.source_row,r.no_document,r.campaign_code,r.depot_code,r.customer_code,
r.legacy_status,r.proposed_status,r.net_value_text,
nullif(btrim(s.data->>'Gross UP'),'') as gross_up_text,
r.batch_upload,r.batch_release,r.batch_claim,r.batch_clearing
from public.rc_claims_review r join staging.rc_latest_rows s
 on s.snapshot_id=r.snapshot_id and s.source_row=r.source_row
where btrim(r.no_document)<>''
and exists(select 1 from public.customers c where c.customer_code=btrim(r.customer_code))
and exists(select 1 from public.depots d where d.depot_code=btrim(r.depot_code));
revoke all on public.rc_claims_migration_candidates from public,anon,authenticated;
grant select on public.rc_claims_migration_candidates to service_role;

