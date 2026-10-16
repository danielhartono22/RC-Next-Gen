-- RC DEV snapshot intake only. No Document Center objects.
create schema if not exists staging;
revoke all on schema staging from public, anon, authenticated;
create table staging.rc_snapshots (
 id uuid primary key default gen_random_uuid(),
 source_name text not null check (length(source_name) between 1 and 200),
 sheet_name text not null check (sheet_name in ('Compile','ListCampaign','ListCust','DepoMaster','LogActivity','ReqProfile','BatchLog')),
 snapshot_at timestamptz not null,
 headers jsonb not null check (jsonb_typeof(headers) = 'array'),
 rows jsonb not null check (jsonb_typeof(rows) = 'array'),
 row_count integer not null,
 imported_at timestamptz not null default now(),
 unique(source_name, sheet_name, snapshot_at)
);
alter table staging.rc_snapshots enable row level security;
revoke all on staging.rc_snapshots from public, anon, authenticated;
grant usage on schema staging to service_role;
grant select, insert on staging.rc_snapshots to service_role;

create or replace function public.rc_import_snapshot(
 p_source text, p_sheet text, p_snapshot_at timestamptz,
 p_headers jsonb, p_rows jsonb
) returns jsonb language plpgsql security invoker set search_path = ''
as $$
declare v_id uuid; v_existing staging.rc_snapshots%rowtype; v_row jsonb;
begin
 if p_headers is null or jsonb_typeof(p_headers) <> 'array' or jsonb_array_length(p_headers) = 0
 or p_rows is null or jsonb_typeof(p_rows) <> 'array' then
   raise exception 'Headers and rows must be arrays; headers must not be empty';
 end if;
 if jsonb_array_length(p_rows) > 10000 or octet_length(p_rows::text) > 10485760 then
   raise exception 'Snapshot exceeds 10000 rows or 10 MiB';
 end if;
 if exists(select 1 from jsonb_array_elements(p_headers) h where jsonb_typeof(h) <> 'string' or btrim(h #>> '{}') = '')
 or (select count(*) from jsonb_array_elements(p_headers)) <>
    (select count(distinct h) from jsonb_array_elements(p_headers) h) then
   raise exception 'Headers must be unique nonempty strings';
 end if;
 for v_row in select value from jsonb_array_elements(p_rows) loop
   if jsonb_typeof(v_row) <> 'array' then raise exception 'Each row must be an array'; end if;
   if jsonb_array_length(v_row) <> jsonb_array_length(p_headers) then raise exception 'Row width mismatch'; end if;
   if exists(select 1 from jsonb_array_elements(v_row) v where jsonb_typeof(v) <> 'string') then
     raise exception 'All cells must be text';
   end if;
 end loop;
 insert into staging.rc_snapshots(source_name,sheet_name,snapshot_at,headers,rows,row_count)
 values(p_source,p_sheet,p_snapshot_at,p_headers,p_rows,jsonb_array_length(p_rows))
 on conflict(source_name,sheet_name,snapshot_at) do nothing returning id into v_id;
 if v_id is null then
   select * into strict v_existing from staging.rc_snapshots
   where source_name=p_source and sheet_name=p_sheet and snapshot_at=p_snapshot_at;
   if v_existing.headers <> p_headers or v_existing.rows <> p_rows then
     raise exception 'Snapshot identity already exists with different content';
   end if;
   return jsonb_build_object('id',v_existing.id,'row_count',v_existing.row_count,'replayed',true);
 end if;
 return jsonb_build_object('id',v_id,'row_count',jsonb_array_length(p_rows),'replayed',false);
end;
$$;
revoke all on function public.rc_import_snapshot(text,text,timestamptz,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.rc_import_snapshot(text,text,timestamptz,jsonb,jsonb) to service_role;

