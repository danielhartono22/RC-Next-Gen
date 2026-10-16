-- Klaim dari sumber tetap harus tersimpan ketika Customer Master belum tersedia.
-- Dokumen tetap dapat dilihat, tetapi setiap UPDATE/proses diblokir sampai customer_id ditautkan.

alter table public.claims
  alter column customer_id drop not null;

alter table public.claims
  add column if not exists source_customer_code text,
  add column if not exists master_data_issue text;

update public.claims c
   set source_customer_code = cu.customer_code
  from public.customers cu
 where cu.id = c.customer_id
   and c.source_customer_code is null;

create index if not exists claims_source_customer_code_idx
  on public.claims(source_customer_code);

create or replace function rc_private.jaga_customer_master_klaim()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if old.customer_id is null and new.customer_id is null then
    raise exception using
      errcode = '23503',
      message = format('Customer Master %s belum tersedia; klaim tidak dapat diproses.',
        coalesce(new.source_customer_code, '(kode tidak tersedia)'));
  end if;
  return new;
end
$$;

revoke all on function rc_private.jaga_customer_master_klaim() from public, anon, authenticated;

drop trigger if exists jaga_customer_master_klaim on public.claims;
create trigger jaga_customer_master_klaim
before update on public.claims
for each row execute function rc_private.jaga_customer_master_klaim();

-- RPC pembaca harus tetap menampilkan dokumen walaupun nama/kode dari Customer Master kosong.
-- Fungsi proses tetap akan ditolak oleh trigger di atas ketika mencoba mengubah klaimnya.
do $migrasi$
declare
  r record;
  sumber text;
  baru text;
begin
  for r in
    select p.oid
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public','rc_private')
       and p.prokind = 'f'
       and p.proname in (
         'rc_approval_hold','rc_archived_list','rc_compilation_list','rc_legacy_dashboard',
         'rc_legacy_workflow','rc_open_claims','rc_open_claims_filtered','rc_periode_dokumen',
         'rc_reprocessing_list','legacy_documents'
       )
  loop
    sumber := pg_get_functiondef(r.oid);
    baru := regexp_replace(
      sumber,
      '([[:space:]])(?<!left )(?<!right )(?<!full )(?<!cross )join[[:space:]]+public\.customers[[:space:]]+cu[[:space:]]+on[[:space:]]+cu\.id[[:space:]]*=[[:space:]]*c\.customer_id',
      E'\\1left join public.customers cu on cu.id=c.customer_id',
      'gi'
    );
    if baru <> sumber then
      baru := replace(baru, 'cu.customer_code', 'coalesce(cu.customer_code,c.source_customer_code)');
      baru := replace(baru, 'cu.customer_name', 'coalesce(cu.customer_name,''Customer Master belum ada'')');
      execute baru;
    end if;
  end loop;
end
$migrasi$;
