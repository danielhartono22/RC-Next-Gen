-- ==========================================================================================
-- Digit pertama nomor batch = kejadian khusus dokumen, dan klaim tertaut otomatis ke
-- Customer Master yang baru dilengkapi
-- ==========================================================================================
-- Pemilik, 16 Oktober 2026:
--  1. "2 angka = TT, saya mau angka pertama jika 1 merupakan amend, jika 2 merupakan
--     reprocessing, serta 3 merupakan hangus, 4 merupakan change cashback typed dan itu akan
--     terbawa terus sampe proses selanjutnya tapi tidak mengubah proses sebelumnya."
--  2. "perbaikan pada key master, tidak sinkron dengan analytic. Ada customer yang pada
--     awalnya tidak ada master sehingga analytics remarking sebagai tidak ada master, lalu
--     sudah diperbaiki di customer master dan belum berubah di analytics, perbaiki dan cek
--     seluruhnya."
--
-- BAGIAN A - NOMOR BATCH
-- Format tetap 15 karakter: K T SSS DDMMYY NNNN.
--   K     kejadian terakhir dokumen: 0 biasa, 1 Amend Doc, 2 Reprocessing, 3 Expired
--         (hangus), 4 Jenis CB diganti saat pengajuan
--   T     tahap: 1 Submitted, 2 Released / Bulk Process, 3 Claimed, 4 Done / Expired,
--         5 Compile
--   SSS   suffix akun, DDMMYY tanggal proses WIB, NNNN urutan hari itu
-- Kode kejadian disimpan pada claims.batch_event_code dan dibawa oleh SETIAP proses
-- berikutnya; batch yang sudah terbit tidak ditulis ulang. Bila beberapa kejadian terjadi,
-- yang berlaku adalah yang TERAKHIR. Satu proses tetap SATU nomor urut: dokumen biasa dan
-- dokumen ber-kejadian di proses yang sama hanya berbeda digit pertamanya
-- (020521610260003 dan 120521610260003). next_batch kini memastikan kelima variannya
-- belum pernah dipakai.
--   Amend Doc dan Reprocessing tidak menerbitkan batch, jadi kodenya muncul di proses
--   berikutnya. Expired dan penggantian Jenis CB terjadi DI DALAM proses yang menerbitkan
--   batch, jadi batch proses itu sudah membawa kodenya (Expired = 34...).
--
-- BAGIAN B - TAUTAN CUSTOMER MASTER
-- TEMUAN (prod, 16 Oktober 2026, hanya baca): 792 dokumen tidak tertaut ke Customer Master
-- (customer_id kosong, kode sumbernya di source_customer_code). 148 di antaranya kini sudah
-- punya Customer Master aktif dengan kode yang sama (29 Not Yet, 13 Claimed, 89 Done,
-- 17 Expired), tetapi tetap tampil "Customer Master belum ada" di Analytics, Workflow, dan
-- Document Center: tidak ada yang menautkan ulang. Ke-148 dokumen itu juga tanpa Gross Up
-- dan sebagian tanpa Subyek Pajak.
-- SEKARANG setiap simpan Customer Master (unggah, form, pemulihan arsip, pembaruan rekening
-- dari pengajuan) langsung menautkan dokumen tanpa master yang kodenya sama. Subyek Pajak
-- dan Gross Up yang KOSONG diisi dari master; nilai yang sudah ada tidak diubah. Setiap
-- dokumen mendapat jejak di riwayatnya, dan Log Activity mendapat satu baris per simpan.
-- Dokumen lama ditautkan sekali di migrasi ini.
--
-- Dipatch dengan penjaga MD5 pra-citra (definisi dev sesudah 20261163150000).
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ------------------------------------------------------------------------------------------
-- A1. Kolom kode kejadian
-- ------------------------------------------------------------------------------------------
alter table public.claims
  add column if not exists batch_event_code text not null default '0',
  add column if not exists batch_event_at timestamptz;

do $k$
begin
  if not exists(select 1 from pg_constraint where conname = 'claims_batch_event_code_check') then
    alter table public.claims add constraint claims_batch_event_code_check
      check (batch_event_code in ('0','1','2','3','4'));
  end if;
end $k$;

comment on column public.claims.batch_event_code is
  'Digit pertama batch berikutnya: 0 biasa, 1 Amend Doc, 2 Reprocessing, 3 Expired, 4 Jenis CB diganti (kejadian terakhir; 20261163160000).';

-- Nomor batch dasar (selalu diawali 0) diberi digit kejadian dokumen.
create or replace function rc_private.batch_kejadian(p_batch text, p_kode text)
returns text language sql immutable set search_path = '' as $f$
  select case when p_batch ~ '^0[1-5].{13}$' and p_kode in ('1','2','3','4')
              then p_kode || substr(p_batch, 2) else p_batch end;
$f$;
revoke all on function rc_private.batch_kejadian(text, text) from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- A2. next_batch: kelima varian digit pertama harus belum terpakai
-- ------------------------------------------------------------------------------------------
do $nb$
declare src text;
begin
  src := pg_get_functiondef('rc_private.next_batch(text)'::regprocedure);
  if src ~ '20261163160000' then raise notice 'next_batch sudah ditambal.'; return; end if;
  if md5(replace(src, E'\r', '')) <> '44f7a86d91e0557113016928db1eb272' then
    raise exception 'DITOLAK: definisi next_batch berbeda dari yang diukur (md5 %).', md5(replace(src, E'\r', '')); end if;
  execute $def$
create or replace function rc_private.next_batch(p_stage text)
 returns text
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare s text; d date:=(now() at time zone 'Asia/Jakarta')::date; n integer; b text; v text[];
begin
 select suffix_num into strict s from public.profiles where id=auth.uid() and status='active' and not must_change_password;
 -- Check old batch identifiers as well; never wrap at 9999.
 -- 20261163160000: digit pertama dipakai kode kejadian (0-4), jadi kelima variannya diperiksa.
 loop
 insert into rc_private.batch_counters values(p_stage,s,d,1)
 on conflict(stage,suffix,business_date) do update set counter=rc_private.batch_counters.counter+1 returning counter into n;
 b:=p_stage||s||to_char(d,'DDMMYY')||lpad(n::text,4,'0');
 v:=array[b,'1'||substr(b,2),'2'||substr(b,2),'3'||substr(b,2),'4'||substr(b,2)];
 exit when not exists(select 1 from public.claims where batch_upload=any(v) or batch_release=any(v) or batch_claim=any(v) or batch_clearing=any(v))
 and not exists(select 1 from staging.rc_latest_rows where sheet_name='BatchLog' and data->>'Batch Number'=any(v));
 end loop;
 return b;
end $function$
$def$;
end $nb$;

-- ------------------------------------------------------------------------------------------
-- A3. Penjaga dokumen tanpa master: mencatat kode kejadian saja tetap boleh
-- ------------------------------------------------------------------------------------------
do $jg$
declare src text;
begin
  src := pg_get_functiondef('rc_private.jaga_customer_master_klaim()'::regprocedure);
  if src ~ '20261163160000' then raise notice 'jaga_customer_master_klaim sudah ditambal.'; return; end if;
  if md5(replace(src, E'\r', '')) <> '0d4d5c760ea13170a18225172c7601cd' then
    raise exception 'DITOLAK: definisi jaga_customer_master_klaim berbeda dari yang diukur (md5 %).', md5(replace(src, E'\r', '')); end if;
  src := replace(src, E'\r', '');
  execute pg_temp.ganti(src,
$p$      return new;
    end if;
    raise exception using$p$,
$p$      return new;
    end if;
    -- 20261163160000: menulis kode kejadian batch saja (tanpa memproses) juga boleh.
    if (to_jsonb(new) - array['batch_event_code','batch_event_at'])
       = (to_jsonb(old) - array['batch_event_code','batch_event_at']) then
      return new;
    end if;
    raise exception using$p$, 1, 'jaga');
end $jg$;

-- ------------------------------------------------------------------------------------------
-- A4. mutate_claims_unchecked: batch per dokumen membawa kode kejadiannya
-- ------------------------------------------------------------------------------------------
do $mu$
declare src text;
begin
  src := pg_get_functiondef('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)'::regprocedure);
  if src ~ '20261163160000' then raise notice 'mutate_claims_unchecked sudah ditambal.'; return; end if;
  if md5(replace(src, E'\r', '')) <> '4aff821c80846715f56d18278b67f165' then
    raise exception 'DITOLAK: definisi mutate_claims_unchecked berbeda dari yang diukur (md5 %).', md5(replace(src, E'\r', '')); end if;
  src := replace(src, E'\r', '');

  src := pg_temp.ganti(src, $p$ v_master_ubah jsonb := '[]'; -- 20261163150000$p$,
$p$ v_master_ubah jsonb := '[]'; -- 20261163150000
 v_kejadian text; v_kode text; v_batch_dok text; v_batches text[] := '{}'; -- 20261163160000$p$, 1, 'mutate deklarasi');

  src := pg_temp.ganti(src, $p$ if p_action in('approve','reject_approval') then batch:=c.batch_upload; end if;$p$,
$p$ if p_action in('approve','reject_approval') then batch:=c.batch_upload; end if;
 -- 20261163160000: digit pertama batch = kejadian terakhir dokumen (1 Amend Doc, 2 Reprocessing,
 -- 3 Expired, 4 Jenis CB diganti). Expired dan penggantian Jenis CB terjadi di proses ini;
 -- selain itu kode yang tersimpan dibawa. Nomor urutnya tetap satu untuk seluruh proses.
 v_kejadian:=case when p_action='expire_claim_process' or (p_action='approve_hold' and target='expired') then '3'
   when p_action='submit' and v_jenis_input<>'' and rc_private.jenis_efektif(v_jenis_input)<>rc_private.jenis_efektif(camp.cashback_type) then '4' end;
 v_kode:=coalesce(v_kejadian,c.batch_event_code,'0');
 v_batch_dok:=case when p_action in('approve','reject_approval') then batch else rc_private.batch_kejadian(batch,v_kode) end;
 if v_batch_dok is not null and not (v_batch_dok=any(v_batches)) then v_batches:=v_batches||v_batch_dok; end if;$p$, 1, 'mutate kode');

  src := pg_temp.ganti(src,
$p$ batch_upload=case when p_action='submit' then batch when p_action in('reject_release','reject_bulk') then null else batch_upload end,
 batch_release=case when p_action in('release','bulk_rebate') then batch when p_action in('reject_claim','reject_bulk') then null else batch_release end,
 batch_claim=case when p_action in('claim','bulk_rebate') then batch when p_action in('reject_clearing','reject_bulk') then null else batch_claim end,
 batch_clearing=case when p_action in('clearing','bulk_rebate','expire_claim_process') or (p_action='approve_hold' and target='expired') then batch
   when p_action='approve' and target='done' then c.batch_upload when v_langsung and target='done' then batch else batch_clearing end,
 version_no=version_no+1,updated_at=stamp where id=c.id;$p$,
$p$ batch_upload=case when p_action='submit' then v_batch_dok when p_action in('reject_release','reject_bulk') then null else batch_upload end,
 batch_release=case when p_action in('release','bulk_rebate') then v_batch_dok when p_action in('reject_claim','reject_bulk') then null else batch_release end,
 batch_claim=case when p_action in('claim','bulk_rebate') then v_batch_dok when p_action in('reject_clearing','reject_bulk') then null else batch_claim end,
 batch_clearing=case when p_action in('clearing','bulk_rebate','expire_claim_process') or (p_action='approve_hold' and target='expired') then v_batch_dok
   when p_action='approve' and target='done' then c.batch_upload when v_langsung and target='done' then v_batch_dok else batch_clearing end,
 batch_event_code=v_kode,batch_event_at=case when v_kejadian is not null then stamp else batch_event_at end, -- 20261163160000
 version_no=version_no+1,updated_at=stamp where id=c.id;$p$, 1, 'mutate batch kolom');

  src := pg_temp.ganti(src, $p$,batch,p_reason)$p$, $p$,v_batch_dok,p_reason)$p$, 5, 'mutate riwayat 1');
  src := pg_temp.ganti(src, $p$,batch,'Approval dimatikan')$p$, $p$,v_batch_dok,'Approval dimatikan')$p$, 1, 'mutate riwayat 2');
  src := pg_temp.ganti(src, $p$,batch,rc_private.cb_label(jenis))$p$, $p$,v_batch_dok,rc_private.cb_label(jenis))$p$, 2, 'mutate riwayat 3');

  src := pg_temp.ganti(src, $p$'pending_approval',p_action in('submit','hold','expire') and not v_langsung,$p$,
    $p$'pending_approval',p_action in('submit','hold','expire') and not v_langsung,'batch',v_batch_dok,$p$, 1, 'mutate processed');

  src := pg_temp.ganti(src, $p$ if jsonb_array_length(v_master_ubah) > 0 then -- 20261163150000$p$,
$p$ -- 20261163160000: batch proses = daftar batch dokumen (biasanya satu; lebih bila digit kejadiannya berbeda).
 batch:=coalesce((select string_agg(x,', ' order by x) from unnest(v_batches) x),batch);
 if jsonb_array_length(v_master_ubah) > 0 then -- 20261163150000$p$, 1, 'mutate daftar batch');

  execute src;
end $mu$;

-- ------------------------------------------------------------------------------------------
-- A5. Posting Exception tanpa approval: Expired langsung = 34...
-- ------------------------------------------------------------------------------------------
do $pe$
declare src text;
begin
  src := pg_get_functiondef('public.rc_posting_exception(text,jsonb,text)'::regprocedure);
  if src ~ '20261163160000' then raise notice 'rc_posting_exception sudah ditambal.'; return; end if;
  if md5(replace(src, E'\r', '')) <> '2dac70b8af7b8a080765d30d889d9914' then
    raise exception 'DITOLAK: definisi rc_posting_exception berbeda dari yang diukur (md5 %).', md5(replace(src, E'\r', '')); end if;
  src := replace(src, E'\r', '');
  src := pg_temp.ganti(src, $p$if v_batch_exp is null then v_batch_exp := rc_private.next_batch('04'); end if;$p$,
    $p$if v_batch_exp is null then v_batch_exp := rc_private.batch_kejadian(rc_private.next_batch('04'), '3'); /* 20261163160000 */ end if;$p$, 1, 'pe batch');
  src := pg_temp.ganti(src, $p$        batch_clearing = case when v_target = 'expired' then batch else batch_clearing end,$p$,
$p$        batch_clearing = case when v_target = 'expired' then batch else batch_clearing end,
        batch_event_code = case when v_target = 'expired' then '3' else batch_event_code end, -- 20261163160000
        batch_event_at = case when v_target = 'expired' then now() else batch_event_at end,$p$, 1, 'pe kode');
  execute src;
end $pe$;

-- ------------------------------------------------------------------------------------------
-- A6. Amend Doc = 1, Reprocessing = 2
-- ------------------------------------------------------------------------------------------
do $am$
declare src text;
begin
  src := pg_get_functiondef('public.rc_amend_doc(jsonb,text)'::regprocedure);
  if src ~ '20261163160000' then raise notice 'rc_amend_doc sudah ditambal.'; return; end if;
  if md5(replace(src, E'\r', '')) <> '935ca4aa6d3879ef49b53af986a75c40' then
    raise exception 'DITOLAK: definisi rc_amend_doc berbeda dari yang diukur (md5 %).', md5(replace(src, E'\r', '')); end if;
  src := replace(src, E'\r', '');
  execute pg_temp.ganti(src, $p$amended_at = now(), amended_by = actor, version_no = version_no + 1, updated_at = now()$p$,
    $p$amended_at = now(), amended_by = actor, version_no = version_no + 1, updated_at = now(),
      batch_event_code = '1', batch_event_at = now() /* 20261163160000 */$p$, 1, 'amend');
end $am$;

do $rp$
declare src text;
begin
  src := pg_get_functiondef('public.rc_reprocessing_upload(jsonb,text)'::regprocedure);
  if src ~ '20261163160000' then raise notice 'rc_reprocessing_upload sudah ditambal.'; return; end if;
  if md5(replace(src, E'\r', '')) <> 'fa8e909d0cea261f2e8b158f2b658a97' then
    raise exception 'DITOLAK: definisi rc_reprocessing_upload berbeda dari yang diukur (md5 %).', md5(replace(src, E'\r', '')); end if;
  src := replace(src, E'\r', '');
  execute pg_temp.ganti(src, $p$      extend_billing_start = null, extend_billing_end = null,
      version_no = version_no + 1,$p$,
$p$      extend_billing_start = null, extend_billing_end = null,
      batch_event_code = '2', batch_event_at = now(), -- 20261163160000
      version_no = version_no + 1,$p$, 1, 'reprocessing');
end $rp$;

-- ------------------------------------------------------------------------------------------
-- B1. Tautkan dokumen tanpa master ke Customer Master yang kodenya sama
-- ------------------------------------------------------------------------------------------
create index if not exists claims_tanpa_master_idx
  on public.claims (upper(btrim(source_customer_code))) where customer_id is null;

create or replace function rc_private.tautkan_klaim_ke_master(p_kode text[])
returns integer
language plpgsql
security definer
set search_path = ''
as $f$
declare v_n integer := 0; v_dok jsonb; v_depot uuid; v_aktor uuid := auth.uid();
begin
  if coalesce(array_length(p_kode, 1), 0) = 0 then return 0; end if;
  with kandidat as (
    select distinct on (c.id) c.id, cu.id cust_id, cu.customer_code,
           coalesce(c.tax_subject, cu.tax_subject) subjek, ca.tax_status,
           coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type) jenis
      from public.claims c
      join public.customers cu on upper(btrim(cu.customer_code)) = upper(btrim(c.source_customer_code))
                              and cu.archived_at is null
      left join public.campaigns ca on ca.id = c.campaign_id
     where c.customer_id is null
       and upper(btrim(c.source_customer_code)) = any(array(select upper(btrim(x)) from unnest(p_kode) x))
     order by c.id, (cu.customer_code = c.source_customer_code) desc
  ), ubah as (
    update public.claims c set
      customer_id = k.cust_id,
      master_data_issue = null,
      tax_subject = k.subjek,
      gross_up = coalesce(c.gross_up, case when k.subjek is not null
                   then rc_private.gross_up_klaim(c.cb_net, k.subjek, k.tax_status, k.jenis) end),
      version_no = c.version_no + 1,
      updated_at = now()
      from kandidat k
     where c.id = k.id
    returning c.id, c.no_doc, c.status, c.depot_id, k.customer_code
  ), riwayat as (
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    select u.id, v_aktor, u.status, u.status, 'customer_master_linked',
           'Customer Master ' || u.customer_code || ' ditautkan'
      from ubah u
    returning claim_id
  )
  select count(*),
         (select jsonb_agg(jsonb_build_object('noDoc', z.no_doc, 'custCode', z.customer_code) order by z.no_doc)
            from (select * from ubah order by no_doc limit 500) z),
         case when count(distinct u.depot_id) = 1 then min(u.depot_id::text)::uuid end
    into v_n, v_dok, v_depot
    from ubah u;

  if v_n > 0 then
    insert into public.activity_logs(actor_id, depot_id, event_type, details, module, tab, process_stage)
    values (v_aktor, v_depot, 'customer_master_linked',
      jsonb_build_object('detail', 'Customer Master ditautkan ke ' || v_n || ' dokumen yang sebelumnya tanpa master',
        'jumlah', v_n, 'dokumen', coalesce(v_dok, '[]'::jsonb)),
      'Key Master', 'Key Master', 'customer');
  end if;
  return v_n;
end $f$;
revoke all on function rc_private.tautkan_klaim_ke_master(text[]) from public, anon, authenticated;

-- Pemicu per pernyataan: satu kali per INSERT/UPDATE, berapa pun barisnya. Kegagalan menautkan
-- tidak boleh menggagalkan penyimpanan Customer Master; jejaknya dicatat.
create or replace function rc_private.tautkan_klaim_customer_master()
returns trigger
language plpgsql
security definer
set search_path = ''
as $f$
begin
  -- Pemeriksaan murah lebih dulu (indeks parsial dokumen tanpa master): unggahan besar
  -- yang tidak menyangkut dokumen tanpa master tidak membayar apa-apa.
  if not exists(select 1 from baru b join public.claims c
                  on c.customer_id is null and upper(btrim(c.source_customer_code)) = upper(btrim(b.customer_code))
                 where b.archived_at is null) then
    return null;
  end if;
  begin
    perform rc_private.tautkan_klaim_ke_master(array(select b.customer_code from baru b where b.archived_at is null));
  exception when others then
    insert into public.activity_logs(actor_id, event_type, details)
    values (auth.uid(), 'customer_master_link_gagal', jsonb_build_object('sebab', left(sqlerrm, 300)));
  end;
  return null;
end $f$;
revoke all on function rc_private.tautkan_klaim_customer_master() from public, anon, authenticated;

drop trigger if exists tautkan_klaim_master_tambah on public.customers;
create trigger tautkan_klaim_master_tambah after insert on public.customers
  referencing new table as baru for each statement execute function rc_private.tautkan_klaim_customer_master();
drop trigger if exists tautkan_klaim_master_ubah on public.customers;
create trigger tautkan_klaim_master_ubah after update on public.customers
  referencing new table as baru for each statement execute function rc_private.tautkan_klaim_customer_master();

-- ------------------------------------------------------------------------------------------
-- B2. Data lama: tautkan sekarang
-- ------------------------------------------------------------------------------------------
select rc_private.tautkan_klaim_ke_master(array(
  select distinct source_customer_code from public.claims where customer_id is null and source_customer_code is not null));

-- ------------------------------------------------------------------------------------------
-- A7. Data lama: kode kejadian terakhir tiap dokumen (batch yang sudah terbit tidak diubah)
-- ------------------------------------------------------------------------------------------
with kandidat as (
  select c.* from public.claims c
   where c.amended_at is not null or c.reprocessed_at is not null or c.status = 'expired' or c.cashback_type_changed
      or exists(select 1 from public.claim_status_history h where h.claim_id = c.id and h.action like '%reprocess%')
), ev as (
  select distinct on (c.id) c.id, e.kode, e.waktu
    from kandidat c
    cross join lateral (values
      ('1', c.amended_at),
      ('2', greatest(c.reprocessed_at, (select max(h.created_at) from public.claim_status_history h
                                         where h.claim_id = c.id and h.action like '%reprocess%'))),
      ('3', case when c.status = 'expired' then coalesce((select max(h.created_at) from public.claim_status_history h
                                                           where h.claim_id = c.id and h.to_status = 'expired'),
                                                          c.cleared_at, c.updated_at) end),
      ('4', case when c.cashback_type_changed then coalesce(c.uploaded_at, c.created_at) end)
    ) e(kode, waktu)
   where e.waktu is not null
   -- Waktu seri (data muat ulang: stempel pengajuan = stempel Expired): urutan logisnya
   -- Jenis CB diganti saat pengajuan, lalu dokumen hangus - jadi 3 menang, lalu 1, 2, 4.
   order by c.id, e.waktu desc, array_position(array['4','2','1','3'], e.kode) desc
)
update public.claims c set batch_event_code = ev.kode, batch_event_at = ev.waktu
  from ev
 where c.id = ev.id and (c.batch_event_code, c.batch_event_at) is distinct from (ev.kode, ev.waktu);

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $cek$
declare e text := ''; n integer;
begin
  select count(*) into n from public.claims c
   where c.customer_id is null
     and exists(select 1 from public.customers cu where upper(btrim(cu.customer_code)) = upper(btrim(c.source_customer_code)) and cu.archived_at is null);
  if n > 0 then e := e || format(' %s dokumen masih tanpa master padahal masternya ada;', n); end if;
  select count(*) into n from public.claims where status = 'expired' and batch_event_code not in ('3', '1');
  if n > 0 then e := e || format(' %s dokumen Expired tanpa kode 3 (dan tidak di-Amend sesudahnya);', n); end if;
  select count(*) into n from public.claims where amended_at is not null and batch_event_code = '0';
  if n > 0 then e := e || format(' %s dokumen Amend tanpa kode;', n); end if;
  if rc_private.batch_kejadian('020521610260003', '1') <> '120521610260003'
     or rc_private.batch_kejadian('020521610260003', '0') <> '020521610260003'
     or rc_private.batch_kejadian('40230110260001', '1') <> '40230110260001'
     or rc_private.batch_kejadian(null, '1') is not null then
    e := e || ' batch_kejadian salah;'; end if;
  if pg_get_functiondef('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)'::regprocedure) ~ ',batch,p_reason\)' then
    e := e || ' riwayat mutate masih memakai batch dasar;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
