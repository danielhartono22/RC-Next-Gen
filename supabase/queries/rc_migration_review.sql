-- Run as postgres in the DEV SQL Editor. Operator-only reports.
-- Imported masters (customer PII remains only in private source snapshots).
select depot_code, depot_name from public.depots order by depot_code;
select customer_code, customer_name from public.customers order by customer_code limit 100;

-- Active candidates: missing document/customer/depot references excluded.
-- Gross-up is AK by owner decision; AL is unused. Values remain source text.
select * from public.rc_claims_migration_candidates order by source_row limit 100;

select campaign_code,campaign_name,cashback_type from public.campaigns order by campaign_code;

-- Reconciliation: source records and issues.
select s.sheet_name, r.issue_code, count(*) as affected_rows
from public.migration_rejects r
join staging.rc_snapshots s on s.id=r.snapshot_id
group by s.sheet_name,r.issue_code order by 1,2;

-- Locate affected source records. source_row 1 corresponds to CSV record 2,
-- after the header (not necessarily physical line 2 if CSV contains newlines).
select s.sheet_name,r.source_row,r.source_row+1 as csv_record,r.issue_code
from public.migration_rejects r join staging.rc_snapshots s on s.id=r.snapshot_id
order by s.sheet_name,r.source_row,r.issue_code;

-- Customers without a known depot are hidden from app users until corrected.
select c.customer_code,c.source_row
from public.customers c
where not exists(select 1 from public.customer_depots d where d.customer_id=c.id)
order by c.source_row;

-- All source sheets are available for private inspection as named JSON fields.
select sheet_name,source_row,data from staging.rc_latest_rows
where source_name='rc-dev-anon' and sheet_name='BatchLog'
order by source_row limit 100;
