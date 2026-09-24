-- RC DEV foundation; no Document Center objects or workflow cutover.
create view staging.rc_latest_rows with (security_invoker=true) as
with latest as (
 select distinct on(source_name,sheet_name) *
 from staging.rc_snapshots
 order by source_name,sheet_name,snapshot_at desc,imported_at desc
)
select s.id as snapshot_id,s.source_name,s.sheet_name,s.snapshot_at,
r.n as source_row,
(select jsonb_object_agg(h.name,r.cells->(h.n::int-1))
 from jsonb_array_elements_text(s.headers) with ordinality h(name,n)) as data,
not exists(select 1 from jsonb_array_elements_text(r.cells) v where btrim(v)<>'') as is_blank
from latest s cross join lateral jsonb_array_elements(s.rows) with ordinality r(cells,n);
revoke all on staging.rc_latest_rows from public,anon,authenticated;
grant select on staging.rc_latest_rows to service_role;

create table public.profiles(
 id uuid primary key references auth.users(id),
 user_code text unique not null check(btrim(user_code)<>''),
 full_name text not null,
 business_email text not null,
 role text not null,
 status text not null default 'inactive' check(status in ('active','inactive')),
 suffix_num text not null check(suffix_num ~ '^[0-9]{3}$'),
 created_at timestamptz not null default now()
);
create table public.permissions(code text primary key,description text not null);
create table public.user_permissions(
 user_id uuid not null references public.profiles(id),
 permission_code text not null references public.permissions(code),
 primary key(user_id,permission_code)
);
create table public.depots(
 id uuid primary key default gen_random_uuid(),
 depot_code text unique not null check(btrim(depot_code)<>''),
 depot_name text not null,
 address text,
 master_link text,
 source_snapshot_id uuid references staging.rc_snapshots(id),
 source_row bigint,
 created_at timestamptz not null default now()
);
create table public.user_depot_access(
 user_id uuid not null references public.profiles(id),
 depot_id uuid not null references public.depots(id),
 primary key(user_id,depot_id)
);
create index user_depot_access_depot_idx on public.user_depot_access(depot_id,user_id);
create table public.customers(
 id uuid primary key default gen_random_uuid(),
 customer_code text unique not null check(btrim(customer_code)<>''),
 customer_name text not null,
 source_snapshot_id uuid references staging.rc_snapshots(id),
 source_row bigint,
 created_at timestamptz not null default now()
);
create table public.customer_depots(
 customer_id uuid not null references public.customers(id),
 depot_id uuid not null references public.depots(id),
 primary key(customer_id,depot_id)
);
create index customer_depots_depot_idx on public.customer_depots(depot_id,customer_id);
create table public.migration_runs(
 id uuid primary key default gen_random_uuid(),
 source_name text not null,
 phase text not null,
 status text not null check(status in ('needs_review','complete')),
 created_at timestamptz not null default now(),
 unique(source_name,phase)
);
create table public.migration_rejects(
 id bigint generated always as identity primary key,
 run_id uuid not null references public.migration_runs(id),
 snapshot_id uuid not null references staging.rc_snapshots(id),
 source_row bigint not null,
 issue_code text not null,
 unique(run_id,snapshot_id,source_row,issue_code)
);
-- Explicit grants and RLS for every new table; no client mutations.
alter table public.profiles enable row level security;
alter table public.permissions enable row level security;
alter table public.user_permissions enable row level security;
alter table public.depots enable row level security;
alter table public.user_depot_access enable row level security;
alter table public.customers enable row level security;
alter table public.customer_depots enable row level security;
alter table public.migration_runs enable row level security;
alter table public.migration_rejects enable row level security;
revoke all on public.profiles,public.permissions,public.user_permissions,public.depots,
 public.user_depot_access,public.customers,public.customer_depots,
 public.migration_runs,public.migration_rejects from public,anon,authenticated;
grant all on public.profiles,public.permissions,public.user_permissions,public.depots,
 public.user_depot_access,public.customers,public.customer_depots,
 public.migration_runs,public.migration_rejects to service_role;
revoke all on sequence public.migration_rejects_id_seq from public,anon,authenticated;
grant usage,select on sequence public.migration_rejects_id_seq to service_role;
grant select on public.profiles,public.permissions,public.user_permissions,public.depots,
 public.user_depot_access,public.customers,public.customer_depots to authenticated;

create policy profiles_self on public.profiles for select to authenticated
 using(id=(select auth.uid()) and status='active');
create policy permissions_active on public.permissions for select to authenticated
 using(exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.status='active'));
create policy permissions_self on public.user_permissions for select to authenticated
 using(user_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid())));
create policy access_self on public.user_depot_access for select to authenticated
 using(user_id=(select auth.uid()) and exists(select 1 from public.profiles p where p.id=(select auth.uid())));
create policy depots_scoped on public.depots for select to authenticated
 using(exists(select 1 from public.user_depot_access a where a.user_id=(select auth.uid()) and a.depot_id=depots.id));
create policy customer_depots_scoped on public.customer_depots for select to authenticated
 using(exists(select 1 from public.user_depot_access a where a.user_id=(select auth.uid()) and a.depot_id=customer_depots.depot_id));
create policy customers_scoped on public.customers for select to authenticated
 using(exists(select 1 from public.customer_depots d where d.customer_id=customers.id));

insert into public.permissions(code,description) values
 ('upload_claim','Submit RC claims'),('release_claim','Release RC claims'),
 ('process_claim','Process RC claims'),('view_analytics','Read RC aggregates'),
 ('manage_access','Manage RC access'),('view_logs','Read scoped RC logs'),
 ('view_master_depot','Read depot master'),('bulk_process','Process rebate batches');

-- Refuse ambiguous nonempty master keys, instead of arbitrarily keeping a row.
do $$ begin
 if exists(select 1 from staging.rc_latest_rows where source_name='rc-dev-anon' and sheet_name='DepoMaster'
 and btrim(data->>'Kode Depot')<>'' group by btrim(data->>'Kode Depot') having count(*)>1)
 or exists(select 1 from staging.rc_latest_rows where source_name='rc-dev-anon' and sheet_name='ListCust'
 and btrim(data->>'Payer')<>'' group by btrim(data->>'Payer') having count(*)>1)
 then raise exception 'Duplicate master keys require review'; end if;
end $$;
insert into public.depots(depot_code,depot_name,address,master_link,source_snapshot_id,source_row)
select btrim(data->>'Kode Depot'),data->>'Depot Name',
 data->>'Depot Address',data->>'Link Master',snapshot_id,source_row
from staging.rc_latest_rows
where source_name='rc-dev-anon' and sheet_name='DepoMaster' and btrim(data->>'Kode Depot')<>'';
insert into public.customers(customer_code,customer_name,source_snapshot_id,source_row)
select btrim(data->>'Payer'),data->>'Payer Name',snapshot_id,source_row
from staging.rc_latest_rows
where source_name='rc-dev-anon' and sheet_name='ListCust' and btrim(data->>'Payer')<>'';
-- Scope only from the explicit customer master DC field.
insert into public.customer_depots(customer_id,depot_id)
select c.id,d.id from staging.rc_latest_rows r
join public.customers c on c.customer_code=btrim(r.data->>'Payer')
join public.depots d on d.depot_code=btrim(r.data->>'DC')
where r.source_name='rc-dev-anon' and r.sheet_name='ListCust';

insert into public.migration_runs(source_name,phase,status)
values('rc-dev-anon','master_import_and_claim_review','needs_review');
insert into public.migration_rejects(run_id,snapshot_id,source_row,issue_code)
select m.id,r.snapshot_id,r.source_row,
case when r.is_blank then 'EMPTY_SOURCE_ROW' else 'MISSING_BUSINESS_KEY' end
from staging.rc_latest_rows r cross join public.migration_runs m
where m.source_name=r.source_name and m.phase='master_import_and_claim_review'
and ((r.sheet_name='Compile' and btrim(r.data->>'No Document')='')
 or (r.sheet_name='ListCust' and btrim(r.data->>'Payer')='')
 or (r.sheet_name='DepoMaster' and btrim(r.data->>'Kode Depot')=''));
insert into public.migration_rejects(run_id,snapshot_id,source_row,issue_code)
select m.id,r.snapshot_id,r.source_row,'CUSTOMER_NOT_IN_MASTER'
from staging.rc_latest_rows r cross join public.migration_runs m
where m.source_name=r.source_name and m.phase='master_import_and_claim_review'
and r.sheet_name='Compile' and btrim(r.data->>'No Document')<>''
and not exists(select 1 from public.customers c where c.customer_code=btrim(r.data->>'Cust Code'));

-- Operator-only review. Financial values stay unchanged and explicitly text.
create view public.rc_claims_review with (security_invoker=true) as
select snapshot_id,source_row,
data->>'No Document' as no_document,
data->>'Code ' as campaign_code,
data->>'DC' as depot_code,
data->>'Cust Code' as customer_code,
data->>'Status' as legacy_status,
case lower(btrim(data->>'Status'))
 when '' then 'not_yet' when 'not yet' then 'not_yet'
 when 'submitted' then 'submitted' when 'released' then 'released'
 when 'claimed' then 'claimed' when 'done' then 'done'
 when 'on hold' then 'on_hold' when 'expired' then 'expired'
 when 'ra7' then 'done' when 'ra07' then 'done' else null end as proposed_status,
data->>' Net Value ' as net_value_text,
data->>'DMD30 USED' as ak_dmd30_used_text,
data->>'Gross Up Disc' as al_gross_up_disc_text,
data->>'Upload' as batch_upload,
data->>'Release' as batch_release,
data->>'Claim' as batch_claim,
data->>'Clearing' as batch_clearing
from staging.rc_latest_rows
where source_name='rc-dev-anon' and sheet_name='Compile';
revoke all on public.rc_claims_review from public,anon,authenticated;
grant select on public.rc_claims_review to service_role;

