-- Run one numbered SELECT at a time in Supabase SQL Editor.
-- Project DEV: vvojshgcduqlugngpzkj. Read-only; no schema/data mutations.
-- Latest snapshot is selected separately per source + sheet.
-- Cells remain text; these are inspection queries, not final business tables.

-- 1. Inventory: one row per imported CSV.
select source_name, sheet_name, snapshot_at, row_count,
       jsonb_array_length(rows) as actual_rows,
       jsonb_array_length(headers) as column_count
from staging.rc_snapshots
order by sheet_name, snapshot_at desc;

-- 2. Read any sheet as one JSON object per CSV record.
-- Change 'Compile' to BatchLog, DepoMaster, ListCust, or LogActivity.
with latest as (
  select distinct on (source_name, sheet_name) *
  from staging.rc_snapshots
  where source_name = 'rc-dev-anon'
  order by source_name, sheet_name, snapshot_at desc, imported_at desc
), expanded as (
  select s.sheet_name, s.snapshot_at, r.row_number,
    (select jsonb_object_agg(h.header, r.cells -> (h.col_number::integer - 1))
     from jsonb_array_elements_text(s.headers) with ordinality as h(header, col_number)
    ) as data
  from latest s
  cross join lateral jsonb_array_elements(s.rows) with ordinality as r(cells, row_number)
)
select sheet_name, row_number, data
from expanded
where sheet_name = 'Compile'
order by row_number
limit 100;

-- 3. Compile: selected source columns, with no numeric/date conversion.
with latest as (
  select distinct on (source_name, sheet_name) *
  from staging.rc_snapshots
  where source_name = 'rc-dev-anon'
  order by source_name, sheet_name, snapshot_at desc, imported_at desc
), expanded as (
  select s.sheet_name, s.snapshot_at, r.row_number,
    (select jsonb_object_agg(h.header, r.cells -> (h.col_number::integer - 1))
     from jsonb_array_elements_text(s.headers) with ordinality as h(header, col_number)
    ) as data
  from latest s
  cross join lateral jsonb_array_elements(s.rows) with ordinality as r(cells, row_number)
)
select row_number as csv_record,
       data ->> 'No Document' as no_document,
       data ->> 'Code ' as campaign_code,
       data ->> 'Campaign' as campaign,
       data ->> 'DC' as depot_code,
       data ->> 'Depot' as depot,
       data ->> 'Cust Code' as customer_code,
       data ->> 'Cust Name' as customer_name,
       data ->> ' Net Value ' as net_value_text,
       data ->> 'Status' as status,
       data ->> 'Upload' as batch_upload,
       data ->> 'Release' as batch_release,
       data ->> 'Claim' as batch_claim,
       data ->> 'Clearing' as batch_clearing
from expanded
where sheet_name = 'Compile'
order by row_number
limit 100;

-- 4. Inspect the actual imported header names and their positions.
select s.sheet_name, h.position as column_position, h.header
from staging.rc_snapshots s
cross join lateral jsonb_array_elements_text(s.headers) with ordinality as h(header, position)
where s.source_name = 'rc-dev-anon'
order by s.sheet_name, s.snapshot_at desc, h.position;

