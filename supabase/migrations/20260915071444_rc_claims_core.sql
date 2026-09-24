-- RC DEV core. No Document Center objects.
create function rc_private.can_access(p_depot uuid, p_permission text default null)
returns boolean language sql stable security definer set search_path='' as $$
select exists(select 1 from public.profiles p
 where p.id=(select auth.uid()) and p.status='active' and not p.must_change_password
 and (p_depot is null or exists(select 1 from public.user_depot_access a where a.user_id=p.id and a.depot_id=p_depot))
 and (p_permission is null or exists(select 1 from public.user_permissions x where x.user_id=p.id and x.permission_code=p_permission)));
$$;
revoke all on function rc_private.can_access(uuid,text) from public,anon;
grant usage on schema rc_private to authenticated;
grant execute on function rc_private.can_access(uuid,text) to authenticated;

create function rc_private.source_number(v text) returns numeric
language plpgsql immutable set search_path='' as $$
declare s text:=btrim(coalesce(v,'')); begin
 if s in ('','-') then return null; end if;
 if s ~ '^-?[0-9]{1,3}(\.[0-9]{3})+(,[0-9]+)?$' then return replace(replace(s,'.',''),',','.')::numeric; end if;
 if s ~ '^-?[0-9]{1,3}(,[0-9]{3})+(\.[0-9]+)?$' then return replace(s,',','')::numeric; end if;
 if s ~ '^-?[0-9]+(,[0-9]{1,2})$' then return replace(s,',','.')::numeric; end if;
 if s ~ '^-?[0-9]+(\.[0-9]+)?$' then return s::numeric; end if;
 raise exception 'Invalid source number';
end $$;
revoke all on function rc_private.source_number(text) from public,anon,authenticated;

create table public.claims(
 id uuid primary key default gen_random_uuid(), no_doc text unique not null,
 campaign_id uuid not null references public.campaigns(id),
 customer_id uuid not null references public.customers(id), depot_id uuid not null references public.depots(id),
 status text not null check(status in('not_yet','submitted','released','claimed','done','on_hold','expired')),
 previous_status text, legacy_status text,
 net_value numeric, volume numeric, cb_net numeric not null check(cb_net>=0), total_billing numeric,
 gross_up numeric, tax_subject text, period_start date,period_end date,paid_on date,
 uploaded_at timestamptz,released_at timestamptz,claimed_at timestamptz,cleared_at timestamptz,
 batch_upload text,batch_release text,batch_claim text,batch_clearing text,
 legacy_dates jsonb not null default '{}',billing_months jsonb not null default '[]',approval text,
 source_snapshot_id uuid references staging.rc_snapshots(id),source_row bigint,
 version_no bigint not null default 1,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create index claims_depot_status_idx on public.claims(depot_id,status,updated_at desc,id);
create index claims_status_idx on public.claims(status,updated_at desc,id);
create index claims_campaign_idx on public.claims(campaign_id,depot_id,status);
create index claims_customer_idx on public.claims(customer_id);
create index claims_batch_upload_idx on public.claims(batch_upload);
create index claims_batch_release_idx on public.claims(batch_release);
create index claims_batch_claim_idx on public.claims(batch_claim);
create index claims_batch_clearing_idx on public.claims(batch_clearing);
create table rc_private.claim_sensitive(
 claim_id uuid primary key references public.claims(id),ktp text,npwp text,bank text,account_number text,account_name text,top_text text
);
create table public.claim_status_history(
 id bigint generated always as identity primary key, claim_id uuid not null references public.claims(id),
 actor_id uuid references public.profiles(id),from_status text,to_status text not null,action text not null,
 batch text,reason text,created_at timestamptz not null default now()
);
create index claim_history_claim_idx on public.claim_status_history(claim_id,id desc);
create table public.activity_logs(
 id bigint generated always as identity primary key,actor_id uuid references public.profiles(id),
 depot_id uuid references public.depots(id),event_type text not null,entity_id uuid,
 details jsonb not null default '{}',created_at timestamptz not null default now()
);
create index activity_logs_depot_idx on public.activity_logs(depot_id,created_at desc,id);
create index activity_logs_actor_idx on public.activity_logs(actor_id);
create table rc_private.batch_counters(stage text not null,suffix text not null,business_date date not null,
 counter integer not null check(counter between 1 and 9999),primary key(stage,suffix,business_date));
create table rc_private.requests(actor_id uuid not null,request_id uuid not null,payload jsonb not null,result jsonb,
 primary key(actor_id,request_id));
alter table public.claims enable row level security;
alter table public.claim_status_history enable row level security;
alter table public.activity_logs enable row level security;
alter table rc_private.claim_sensitive enable row level security;
alter table rc_private.batch_counters enable row level security;
alter table rc_private.requests enable row level security;
revoke all on public.claims,public.claim_status_history,public.activity_logs from public,anon,authenticated;
revoke all on rc_private.claim_sensitive,rc_private.batch_counters,rc_private.requests from public,anon,authenticated;
revoke all on sequence public.claim_status_history_id_seq,public.activity_logs_id_seq from public,anon,authenticated;
grant select on public.claims,public.claim_status_history,public.activity_logs to authenticated;
grant all on public.claims,public.claim_status_history,public.activity_logs,rc_private.claim_sensitive,
rc_private.batch_counters,rc_private.requests to service_role;
grant usage on sequence public.claim_status_history_id_seq,public.activity_logs_id_seq to service_role;
create policy claims_scope on public.claims for select to authenticated using(rc_private.can_access(depot_id));
create policy history_scope on public.claim_status_history for select to authenticated using(
 exists(select 1 from public.claims c where c.id=claim_id));
create policy logs_scope on public.activity_logs for select to authenticated using(rc_private.can_access(depot_id,'view_logs'));
grant select on public.campaigns to authenticated;
create policy campaigns_scope on public.campaigns for select to authenticated using(
 exists(select 1 from public.claims c where c.campaign_id=campaigns.id));

-- Import the owner-approved candidate set. Invalid numerics abort, never silently coerce.
insert into public.claims(no_doc,campaign_id,customer_id,depot_id,status,legacy_status,
net_value,volume,cb_net,total_billing,gross_up,tax_subject,batch_upload,batch_release,batch_claim,batch_clearing,
legacy_dates,source_snapshot_id,source_row)
select btrim(r.no_document),ca.id,cu.id,d.id,r.proposed_status,r.legacy_status,
rc_private.source_number(s.data->>' Net Value '),rc_private.source_number(s.data->>' Value/net weight/Volume '),
rc_private.source_number(s.data->>'Hadiah Rebate/Transfer/CN After TAX'),rc_private.source_number(s.data->>'Total Tagihan'),
rc_private.source_number(r.gross_up_text),s.data->>'Subyek Pajak',
r.batch_upload,r.batch_release,r.batch_claim,r.batch_clearing,
jsonb_build_object('period_start',s.data->>'Periode Campaign','period_end',s.data->>'__column_013',
'paid_on',s.data->>'Tanggal Lunas','uploaded_at',s.data->>'Tanggal Upload','released_at',s.data->>'Tanggal Release',
'claimed_at',s.data->>'Tanggal Claim ke Finance','cleared_at',s.data->>'Tanggal Proses'),r.snapshot_id,r.source_row
from public.rc_claims_migration_candidates r join staging.rc_latest_rows s using(snapshot_id,source_row)
join public.campaigns ca on ca.campaign_code=btrim(r.campaign_code)
join public.customers cu on cu.customer_code=btrim(r.customer_code)
join public.depots d on d.depot_code=btrim(r.depot_code);
insert into rc_private.claim_sensitive(claim_id,ktp,npwp,bank,account_number,account_name,top_text)
select c.id,s.data->>'NoKTP',s.data->>'NPWP',s.data->>'Bank',s.data->>'Nomor Rekening',s.data->>'Nama pemilik Rekening',s.data->>'TOP'
from public.claims c join staging.rc_latest_rows s on s.snapshot_id=c.source_snapshot_id and s.source_row=c.source_row;
insert into public.claim_status_history(claim_id,to_status,action)
select id,status,'import_snapshot' from public.claims;

create function rc_private.next_batch(p_stage text) returns text language plpgsql security definer set search_path='' as $$
declare s text; d date:=(now() at time zone 'Asia/Jakarta')::date; n integer; b text;
begin
 select suffix_num into strict s from public.profiles where id=auth.uid() and status='active' and not must_change_password;
 -- Check old batch identifiers as well; never wrap at 9999.
 loop
 insert into rc_private.batch_counters values(p_stage,s,d,1)
 on conflict(stage,suffix,business_date) do update set counter=rc_private.batch_counters.counter+1 returning counter into n;
 b:=p_stage||s||to_char(d,'DDMMYY')||lpad(n::text,4,'0');
 exit when not exists(select 1 from public.claims where b in(batch_upload,batch_release,batch_claim,batch_clearing))
 and not exists(select 1 from staging.rc_latest_rows where sheet_name='BatchLog' and data->>'Batch Number'=b);
 end loop;
 return b;
end $$;
revoke all on function rc_private.next_batch(text) from public,anon,authenticated;
