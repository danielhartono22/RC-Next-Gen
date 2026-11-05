-- ==========================================================================================
-- Bukti Transfer di Tanda Terima PDA + mode "Arsip Bukti TF" pada Upload File Bank
-- ==========================================================================================
-- Pemilik, 5 November 2026: Tanda Terima disertai bukti transfer, susunan mirip BCA, berdasarkan
-- data file KlikBCA. Nama Penerima dicocokkan lewat No Doc (file tidak memuat nama penerima;
-- kolom Acc Name di file = pengirim). Kaki: "Digenerate otomatis oleh RC berdasarkan data
-- transaksi dari KlikBCA Bisnis". Saran yang disetujui ("buat"): halaman sesudah Tanda Terima PDA,
-- satu kartu per transfer (3 per A4), dan mode Arsip untuk file bank yang sudah lewat.
--
-- * Upload File Bank (20261163710000) kini menyimpan seluruh data untuk bukti: Channel, Trsfr
--   Service (BCA / LLG / ...), From Acc + Acc Name, SWIFT Code, Bank Name, Total Charges, Charges To.
-- * Mode upload:
--     clearing - seperti 20261163710000 (baris OK di-Clearing lewat alur lama);
--     arsip    - untuk dokumen yang SUDAH Done (mis. file 27-Oct yang di-Clearing manual): baris OK
--                = dokumen Done dengan nominal = Net CB; Proses hanya menyimpan data transfernya
--                sebagai Bukti TF, klaim tidak diubah.
--   Sidik file unik per mode (file yang sama boleh diarsip sesudah di-Clearing untuk baris yang
--   belum punya bukti); Trans ID + tanggal tetap tidak boleh tersimpan dua kali; satu dokumen
--   hanya punya satu Bukti TF.
-- * rc_docgen_generate: form PDA membawa "bukti" (Bukti TF klaim-klaimnya); layar mencetaknya
--   sebagai halaman sesudah form. rc_docgen_list: jumlah dokumen ber-Bukti TF per toko.
-- Butuh 20261163710000 dan 20261163720000. Aman dijalankan berulang.
-- ==========================================================================================

do $pra$ begin
  if to_regclass('public.rc_clearing_bank_baris') is null or to_regprocedure('rc_private.docgen_kategori(date,text)') is null then
    raise exception 'DITOLAK: jalankan 20261163710000 dan 20261163720000 lebih dulu.'; end if;
end $pra$;

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- 1. Kolom data transfer dan mode -------------------------------------------------------------
alter table public.rc_clearing_bank_baris
  add column if not exists channel text not null default '',
  add column if not exists layanan text not null default '',
  add column if not exists dari_rek text not null default '',
  add column if not exists dari_nama text not null default '',
  add column if not exists swift text not null default '',
  add column if not exists nama_bank text not null default '',
  add column if not exists biaya numeric,
  add column if not exists biaya_oleh text not null default '';
alter table public.rc_clearing_bank_upload add column if not exists mode text not null default 'clearing';
do $c$ begin
  if not exists (select 1 from pg_constraint where conname = 'rc_clearing_bank_upload_mode_check') then
    alter table public.rc_clearing_bank_upload add constraint rc_clearing_bank_upload_mode_check check (mode in ('clearing', 'arsip')); end if;
end $c$;
drop index if exists public.rc_clearing_bank_upload_sidik_diproses;
create unique index if not exists rc_clearing_bank_upload_sidik_mode_diproses on public.rc_clearing_bank_upload (sidik, mode) where status = 'diproses';
create unique index if not exists rc_clearing_bank_baris_bukti_klaim on public.rc_clearing_bank_baris (claim_id) where diproses;

-- ---- 2. Penilaian satu baris (dengan mode) -----------------------------------------------------------
drop function if exists rc_private.clearing_bank_nilai(text, date, numeric, boolean, text, text, text, boolean, uuid);
create or replace function rc_private.clearing_bank_nilai(p_remark text, p_tgl date, p_nominal numeric, p_berhasil boolean,
  p_status_bank text, p_reason text, p_trans_id text, p_dupe boolean, p_upload uuid, p_mode text default 'clearing')
returns table(hasil text, keterangan text, claim_id uuid, no_doc_rc text, nominal_klaim numeric)
language plpgsql stable security definer set search_path to '' as $f$
declare c record; v_kandidat text; v_jenis text; v_lama record; v_doc text := btrim(coalesce(p_remark, ''));
begin
  if not coalesce(p_berhasil, false) then
    return query select 'gagal_transfer', 'Status transfer: ' || coalesce(nullif(btrim(p_status_bank), ''), '-')
      || coalesce(' - ' || nullif(btrim(p_reason), ''), ''), null::uuid, null::text, null::numeric; return;
  end if;
  if p_tgl is null then
    return query select 'tanggal_salah', 'Eff Date tidak terbaca', null::uuid, null::text, null::numeric; return;
  end if;
  if p_tgl > (now() at time zone 'Asia/Jakarta')::date then
    return query select 'tanggal_salah', 'Eff Date ' || to_char(p_tgl, 'DD-Mon-YYYY') || ' belum terjadi', null::uuid, null::text, null::numeric; return;
  end if;
  if v_doc = '' then
    return query select 'tidak_ditemukan', 'Remark 1 (No Doc) kosong', null::uuid, null::text, null::numeric; return;
  end if;
  if p_dupe then
    return query select 'duplikat', 'No Doc muncul lebih dari sekali dalam file', null::uuid, null::text, null::numeric; return;
  end if;
  if coalesce(btrim(p_trans_id), '') <> '' then
    select u.nama_file, u.batch_clearing, u.diproses_pada, u.mode into v_lama
      from public.rc_clearing_bank_baris b join public.rc_clearing_bank_upload u on u.id = b.upload_id
     where b.diproses and b.trans_id = btrim(p_trans_id) and b.tgl_transfer = p_tgl and b.upload_id <> coalesce(p_upload, gen_random_uuid())
     limit 1;
    if found then
      return query select 'sudah_diproses', 'Trans ID sudah tersimpan lewat ' || v_lama.nama_file || ' (' ||
        to_char(v_lama.diproses_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') ||
        case when v_lama.mode = 'arsip' then ', arsip Bukti TF' else coalesce(', batch ' || v_lama.batch_clearing, '') end || ')',
        null::uuid, null::text, null::numeric; return;
    end if;
  end if;

  select cl.id, cl.no_doc, cl.status, cl.cb_net, cl.cleared_actual_on, cl.cleared_at, cl.batch_clearing, cl.pending_approval,
         cl.jalur_adhoc, cl.cashback_type_override, ca.cashback_type
    into c
    from public.claims cl join public.campaigns ca on ca.id = cl.campaign_id
   where cl.archived_at is null and cl.no_doc in (v_doc, 'NPC/' || v_doc)
   order by (cl.no_doc = v_doc) desc limit 1;
  if not found then
    if length(v_doc) >= 18 then
      select string_agg(cl.no_doc || ' (Rp ' || rc_private.angka(trunc(cl.cb_net)) || ')', ', ' order by cl.no_doc) into v_kandidat
        from (select * from public.claims x where x.archived_at is null
                and (x.no_doc like 'NPC/' || replace(replace(v_doc, '%', '\%'), '_', '\_') || '%' or x.no_doc like replace(replace(v_doc, '%', '\%'), '_', '\_') || '%')
              order by x.no_doc limit 5) cl;
      if v_kandidat is not null then
        return query select 'terpotong', 'No Doc kemungkinan terpotong oleh bank (18 karakter). Kandidat: ' || v_kandidat || '. Proses manual.',
          null::uuid, null::text, null::numeric; return;
      end if;
    end if;
    return query select 'tidak_ditemukan', 'No Doc tidak ada di RC', null::uuid, null::text, null::numeric; return;
  end if;

  if coalesce(p_mode, 'clearing') = 'arsip' then
    -- 20261163730000: arsip Bukti TF - hanya dokumen yang SUDAH Done; klaim tidak diubah.
    -- Satu dokumen hanya punya satu Bukti TF (dari Clearing file bank atau arsip sebelumnya).
    select u.nama_file, u.diproses_pada into v_lama
      from public.rc_clearing_bank_baris b join public.rc_clearing_bank_upload u on u.id = b.upload_id
     where b.diproses and b.claim_id = c.id and b.upload_id <> coalesce(p_upload, gen_random_uuid()) limit 1;
    if found then
      return query select 'sudah_diproses', 'Bukti TF dokumen ini sudah tersimpan lewat ' || v_lama.nama_file || ' (' ||
        to_char(v_lama.diproses_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ')', c.id, c.no_doc, trunc(c.cb_net); return;
    end if;
    if c.status <> 'done' then
      return query select 'belum_siap', 'Belum Done (status ' || rc_private.legacy_status(c.status) || '); gunakan mode Clearing',
        c.id, c.no_doc, trunc(c.cb_net); return;
    end if;
    if trunc(c.cb_net) is distinct from trunc(p_nominal) then
      return query select 'nominal_beda', 'Nominal klaim (Net CB) Rp ' || rc_private.angka(trunc(c.cb_net)) || ', transfer Rp ' ||
        rc_private.angka(trunc(coalesce(p_nominal, 0))) || ' (selisih Rp ' || rc_private.angka(trunc(coalesce(p_nominal, 0)) - trunc(c.cb_net)) || ')',
        c.id, c.no_doc, trunc(c.cb_net); return;
    end if;
    return query select 'ok', 'Siap diarsip sebagai Bukti TF (Done ' ||
      coalesce(to_char(coalesce(c.cleared_actual_on, (c.cleared_at at time zone 'Asia/Jakarta')::date), 'DD-Mon-YYYY'), '-') || ')',
      c.id, c.no_doc, trunc(c.cb_net); return;
  end if;

  if c.status = 'done' then
    return query select 'sudah_clearing', 'Sudah Done; tanggal clearing ' ||
      coalesce(to_char(coalesce(c.cleared_actual_on, (c.cleared_at at time zone 'Asia/Jakarta')::date), 'DD-Mon-YYYY'), '-') ||
      coalesce(', batch ' || nullif(btrim(c.batch_clearing), ''), '') || '. Pakai mode Arsip Bukti TF untuk menyimpan buktinya.', c.id, c.no_doc, trunc(c.cb_net); return;
  end if;
  v_jenis := rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), c.cashback_type));
  if c.status <> 'claimed' or c.pending_approval is not null or (v_jenis = 'rebate' and not coalesce(c.jalur_adhoc, false)) then
    return query select 'belum_siap',
      case when v_jenis = 'rebate' and not coalesce(c.jalur_adhoc, false) then 'Jenis Rebate: diproses lewat Bulk Process'
           when c.pending_approval is not null then 'Sedang menunggu approval'
           else 'Status RC ' || rc_private.legacy_status(c.status) || ' (Clearing hanya untuk Pending Finance / Claimed)' end,
      c.id, c.no_doc, trunc(c.cb_net); return;
  end if;
  if trunc(c.cb_net) is distinct from trunc(p_nominal) then
    return query select 'nominal_beda', 'Nominal klaim (Net CB) Rp ' || rc_private.angka(trunc(c.cb_net)) || ', transfer Rp ' ||
      rc_private.angka(trunc(coalesce(p_nominal, 0))) || ' (selisih Rp ' || rc_private.angka(trunc(coalesce(p_nominal, 0)) - trunc(c.cb_net)) || ')',
      c.id, c.no_doc, trunc(c.cb_net); return;
  end if;
  return query select 'ok', 'Siap Clearing, Tgl Transfer ' || to_char(p_tgl, 'DD-Mon-YYYY'), c.id, c.no_doc, trunc(c.cb_net);
end $f$;
revoke all on function rc_private.clearing_bank_nilai(text, date, numeric, boolean, text, text, text, boolean, uuid, text) from public, anon, authenticated;

-- ---- 3. Bukti TF satu dokumen ---------------------------------------------------------------------
create or replace function rc_private.bukti_tf(p_claim uuid) returns jsonb
language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object(
    'noDoc', c.no_doc, 'campaign', coalesce(ca.campaign_code, ''),
    'tglEfektif', to_char(b.tgl_transfer, 'DD-Mon-YYYY'), 'transId', b.trans_id,
    'layanan', case upper(btrim(b.layanan)) when 'BCA' then 'Transfer sesama BCA' when 'LLG' then 'Transfer Antarbank (LLG)'
                    when 'RTGS' then 'Transfer Antarbank (RTGS)' when 'BIFAST' then 'Transfer Antarbank (BI-FAST)' when '' then 'Transfer'
                    else 'Transfer ' || b.layanan end || ' - KlikBCA Bisnis',
    'dariRek', b.dari_rek,
    'dariNama', case when upper(b.dari_nama) like 'NIPSEA PAINT AND CHEMICA%' then 'PT NIPSEA PAINT AND CHEMICALS' else b.dari_nama end,
    'keRek', b.to_acc,
    'bankTujuan', coalesce(nullif(btrim(b.nama_bank), ''), case when upper(btrim(b.layanan)) = 'BCA' then 'PT. BANK CENTRAL ASIA TBK' end, nullif(btrim(b.bank), ''), '-'),
    'namaPenerima', coalesce(nullif(btrim(s.account_name), ''), nullif(btrim(cu.account_name), ''), ''),
    'nominal', b.nominal, 'biaya', coalesce(b.biaya, 0),
    'biayaOleh', case upper(btrim(b.biaya_oleh)) when 'OUR' then 'ditanggung pengirim' when 'BEN' then 'ditanggung penerima'
                      when 'SHA' then 'ditanggung bersama' else lower(b.biaya_oleh) end,
    'berita', b.remark1, 'status', upper(b.status_bank))
  from public.rc_clearing_bank_baris b
  join public.claims c on c.id = b.claim_id
  left join public.campaigns ca on ca.id = c.campaign_id
  left join public.customers cu on cu.id = c.customer_id
  left join rc_private.claim_sensitive s on s.claim_id = c.id
 where b.claim_id = p_claim and b.diproses
 limit 1;
$f$;
revoke all on function rc_private.bukti_tf(uuid) from public, anon, authenticated;

-- Hasil upload (layar / Excel): ditambah mode dan data transfer.
create or replace function rc_private.clearing_bank_hasil(p_upload uuid) returns jsonb
language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object('status', 'success',
    'upload', jsonb_build_object('id', u.id, 'namaFile', u.nama_file, 'tahun', u.tahun, 'tahunSumber', u.tahun_sumber, 'status', u.status,
       'mode', u.mode, 'batch', u.batch_clearing, 'jumlahDiproses', u.jumlah_diproses,
       'diunggah', to_char(u.diunggah_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
       'diproses', to_char(u.diproses_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI')),
    'ringkasan', jsonb_build_object('baris', (select count(*) from public.rc_clearing_bank_baris b where b.upload_id = u.id),
       'totalNominal', (select coalesce(sum(b.nominal), 0) from public.rc_clearing_bank_baris b where b.upload_id = u.id),
       'totalOk', (select coalesce(sum(b.nominal), 0) from public.rc_clearing_bank_baris b where b.upload_id = u.id and b.hasil = 'ok'),
       'perHasil', coalesce((select jsonb_object_agg(z.hasil, z.n) from (select b.hasil, count(*) n from public.rc_clearing_bank_baris b
                               where b.upload_id = u.id group by 1) z), '{}'::jsonb)),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('baris', b.baris_ke, 'transId', b.trans_id, 'effDate', b.eff_date_teks,
         'tglTransfer', coalesce(to_char(b.tgl_transfer, 'DD-Mon-YYYY'), ''), 'remark1', b.remark1, 'noDocRc', coalesce(b.no_doc_rc, ''),
         'bank', b.bank, 'toAcc', b.to_acc, 'nominal', b.nominal, 'nominalKlaim', b.nominal_klaim, 'statusBank', b.status_bank,
         'layanan', b.layanan, 'namaBank', b.nama_bank, 'biaya', b.biaya,
         'hasil', b.hasil, 'keterangan', b.keterangan, 'diproses', b.diproses,
         'kodeToko', coalesce(cu.customer_code, ''), 'namaToko', coalesce(cu.customer_name, ''),
         'depot', coalesce(d.depot_code, ''), 'campaign', coalesce(ca.campaign_code, ''))
       order by b.baris_ke)
       from public.rc_clearing_bank_baris b
       left join public.claims c on c.id = b.claim_id
       left join public.customers cu on cu.id = c.customer_id
       left join public.depots d on d.id = c.depot_id
       left join public.campaigns ca on ca.id = c.campaign_id
      where b.upload_id = u.id), '[]'::jsonb))
  from public.rc_clearing_bank_upload u where u.id = p_upload;
$f$;

-- ---- 4. Pratinjau (dengan mode) ------------------------------------------------------------------------
drop function if exists public.rc_clearing_bank_preview(text, text, integer, text, jsonb);
create or replace function public.rc_clearing_bank_preview(p_nama_file text, p_sidik text, p_tahun integer, p_tahun_sumber text, p_baris jsonb,
  p_mode text default 'clearing')
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v_id uuid; v_lama record; e jsonb; v_tgl date; n_baris integer; v jsonb; v_mode text := coalesce(nullif(btrim(p_mode), ''), 'clearing');
begin
  perform rc_private.require_tab('process.clearing');
  if v_mode not in ('clearing', 'arsip') then raise exception 'Mode upload tidak dikenal'; end if;
  if btrim(coalesce(p_nama_file, '')) = '' then raise exception 'Nama file wajib'; end if;
  if coalesce(p_sidik, '') !~ '^[0-9a-f]{64}$' then raise exception 'Sidik file tidak valid'; end if;
  if p_tahun is null or p_tahun < 2020 or p_tahun > 2100 then raise exception 'Tahun file tidak valid (isi tahun transfer)'; end if;
  if coalesce(p_tahun_sumber, '') not in ('nama_file', 'form') then raise exception 'Sumber tahun tidak dikenal'; end if;
  if jsonb_typeof(p_baris) is distinct from 'array' or jsonb_array_length(p_baris) = 0 then raise exception 'File tidak berisi baris transaksi'; end if;
  if jsonb_array_length(p_baris) > 5000 then raise exception 'Maksimal 5.000 baris per file'; end if;

  select u.nama_file, u.diproses_pada, u.batch_clearing, coalesce(nullif(p.full_name, ''), p.user_code, '-') oleh into v_lama
    from public.rc_clearing_bank_upload u left join public.profiles p on p.id = u.diproses_oleh
   where u.sidik = p_sidik and u.status = 'diproses' and u.mode = v_mode limit 1;
  if found then
    raise exception 'File ini sudah diproses (mode %) pada % oleh % (%, batch %). File yang sama tidak bisa diproses dua kali.',
      case when v_mode = 'arsip' then 'Arsip Bukti TF' else 'Clearing' end,
      to_char(v_lama.diproses_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), v_lama.oleh, v_lama.nama_file, coalesce(v_lama.batch_clearing, '-');
  end if;

  insert into public.rc_clearing_bank_upload(nama_file, sidik, tahun, tahun_sumber, diunggah_oleh, mode)
  values (left(btrim(p_nama_file), 300), p_sidik, p_tahun, p_tahun_sumber, auth.uid(), v_mode) returning id into v_id;

  for e in select value from jsonb_array_elements(p_baris) loop
    begin v_tgl := nullif(btrim(coalesce(e->>'tglTransfer', '')), '')::date; exception when others then v_tgl := null; end;
    insert into public.rc_clearing_bank_baris(upload_id, baris_ke, trans_id, eff_date_teks, tgl_transfer, remark1, bank, to_acc, nominal, status_bank, reason, hasil,
                                              channel, layanan, dari_rek, dari_nama, swift, nama_bank, biaya, biaya_oleh)
    values (v_id, (e->>'baris')::integer, left(btrim(coalesce(e->>'transId', '')), 100), left(btrim(coalesce(e->>'effDate', '')), 40), v_tgl,
            left(btrim(coalesce(e->>'remark1', '')), 100), left(btrim(coalesce(e->>'bank', '')), 100), left(btrim(coalesce(e->>'toAcc', '')), 60),
            case when coalesce(e->>'nominal', '') ~ '^[0-9]+(\.[0-9]+)?$' then trunc((e->>'nominal')::numeric) end,
            left(btrim(coalesce(e->>'status', '')), 60), left(btrim(coalesce(e->>'reason', '')), 300), 'baru',
            left(btrim(coalesce(e->>'channel', '')), 30), left(btrim(coalesce(e->>'layanan', '')), 30), left(btrim(coalesce(e->>'dariRek', '')), 40),
            left(btrim(coalesce(e->>'dariNama', '')), 120), left(btrim(coalesce(e->>'swift', '')), 20), left(btrim(coalesce(e->>'namaBank', '')), 120),
            case when coalesce(e->>'biaya', '') ~ '^[0-9]+(\.[0-9]+)?$' then trunc((e->>'biaya')::numeric) end,
            left(btrim(coalesce(e->>'biayaOleh', '')), 10));
  end loop;

  update public.rc_clearing_bank_baris b set
    hasil = n.hasil, keterangan = n.keterangan, claim_id = n.claim_id, no_doc_rc = n.no_doc_rc, nominal_klaim = n.nominal_klaim
    from (select b2.baris_ke, z.* from public.rc_clearing_bank_baris b2
            cross join lateral rc_private.clearing_bank_nilai(b2.remark1, b2.tgl_transfer, b2.nominal, lower(b2.status_bank) = 'berhasil',
              b2.status_bank, b2.reason, b2.trans_id,
              (select count(*) from public.rc_clearing_bank_baris b3
                where b3.upload_id = b2.upload_id and lower(b3.status_bank) = 'berhasil' and b3.remark1 <> ''
                  and regexp_replace(upper(b3.remark1), '^NPC/', '') = regexp_replace(upper(b2.remark1), '^NPC/', '')) > 1, b2.upload_id, v_mode) z
           where b2.upload_id = v_id) n
   where b.upload_id = v_id and b.baris_ke = n.baris_ke;

  select count(*) into n_baris from public.rc_clearing_bank_baris where upload_id = v_id;
  update public.rc_clearing_bank_upload u set
    jumlah_baris = n_baris,
    jumlah_berhasil = (select count(*) from public.rc_clearing_bank_baris b where b.upload_id = v_id and lower(b.status_bank) = 'berhasil'),
    total_nominal = (select coalesce(sum(b.nominal), 0) from public.rc_clearing_bank_baris b where b.upload_id = v_id),
    ringkasan = (select coalesce(jsonb_object_agg(z.hasil, z.n), '{}'::jsonb) from (select b.hasil, count(*) n from public.rc_clearing_bank_baris b
                  where b.upload_id = v_id group by 1) z)
   where u.id = v_id;

  v := rc_private.clearing_bank_hasil(v_id);
  return v || jsonb_build_object('message', 'Pratinjau ' || n_baris || ' baris: ' || coalesce((v->'ringkasan'->'perHasil'->>'ok'), '0')
                                 || case when v_mode = 'arsip' then ' siap diarsip sebagai Bukti TF.' else ' siap Clearing.' end || ' Belum ada yang disimpan.');
end $f$;

-- ---- 5. Proses (Clearing atau Arsip) -------------------------------------------------------------------
create or replace function public.rc_clearing_bank_proses(p_upload uuid)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare u public.rc_clearing_bank_upload; v_items jsonb; v_hasil jsonb; v_batch text; n_ok integer; n_berubah integer := 0; v jsonb;
begin
  perform rc_private.require_tab('process.clearing');
  select * into u from public.rc_clearing_bank_upload where id = p_upload for update;
  if not found then raise exception 'Upload tidak ditemukan'; end if;
  if u.status = 'diproses' then raise exception 'Upload ini sudah diproses (%).', coalesce('batch ' || u.batch_clearing, 'arsip Bukti TF'); end if;
  if exists (select 1 from public.rc_clearing_bank_upload x where x.sidik = u.sidik and x.mode = u.mode and x.status = 'diproses') then
    raise exception 'File dengan isi yang sama sudah diproses sebelumnya. File yang sama tidak bisa diproses dua kali.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('rc_clearing_bank', 0));

  -- Nilai ulang baris OK: klaim bisa berubah sejak pratinjau.
  with nilai as (
    select b.baris_ke, z.* from public.rc_clearing_bank_baris b
      cross join lateral rc_private.clearing_bank_nilai(b.remark1, b.tgl_transfer, b.nominal, true, b.status_bank, b.reason, b.trans_id, false, b.upload_id, u.mode) z
     where b.upload_id = u.id and b.hasil = 'ok')
  update public.rc_clearing_bank_baris b set hasil = n.hasil, claim_id = n.claim_id, no_doc_rc = n.no_doc_rc, nominal_klaim = n.nominal_klaim,
         keterangan = case when n.hasil = 'ok' then b.keterangan else 'Berubah sejak pratinjau: ' || n.keterangan end
    from nilai n where b.upload_id = u.id and b.baris_ke = n.baris_ke;
  select count(*) into n_berubah from public.rc_clearing_bank_baris b where b.upload_id = u.id and b.keterangan like 'Berubah sejak pratinjau:%';
  select count(*) into n_ok from public.rc_clearing_bank_baris b where b.upload_id = u.id and b.hasil = 'ok';
  if n_ok = 0 then
    raise exception 'Tidak ada baris berstatus OK untuk diproses%.', case when n_berubah > 0 then ' (' || n_berubah || ' baris berubah sejak pratinjau)' else '' end;
  end if;

  if u.mode = 'clearing' then
    select jsonb_agg(jsonb_build_object('no_doc', c.no_doc, 'version_no', c.version_no, 'tgl_aktual', to_char(b.tgl_transfer, 'YYYY-MM-DD')) order by c.no_doc)
      into v_items
      from public.rc_clearing_bank_baris b join public.claims c on c.id = b.claim_id
     where b.upload_id = u.id and b.hasil = 'ok';
    -- Alur Clearing lama, apa adanya: Done, batch Clearing 04, Tgl Transfer aktual per dokumen, email Done.
    v_hasil := rc_private.mutate_claims('clearing', v_items, gen_random_uuid(), '');
    v_batch := v_hasil->>'batch';
  end if;

  update public.rc_clearing_bank_baris b set diproses = true,
         keterangan = case when u.mode = 'arsip' then 'Bukti TF tersimpan (Tgl Transfer ' || to_char(b.tgl_transfer, 'DD-Mon-YYYY') || ')'
                           else 'Clearing selesai, Tgl Transfer ' || to_char(b.tgl_transfer, 'DD-Mon-YYYY') || coalesce(', batch ' || v_batch, '') end
   where b.upload_id = u.id and b.hasil = 'ok';
  update public.rc_clearing_bank_upload set status = 'diproses', batch_clearing = v_batch, jumlah_diproses = n_ok,
         diproses_oleh = auth.uid(), diproses_pada = now(),
         ringkasan = (select coalesce(jsonb_object_agg(z.hasil, z.n), '{}'::jsonb) from (select b.hasil, count(*) n from public.rc_clearing_bank_baris b
                       where b.upload_id = u.id group by 1) z)
   where id = u.id;

  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage, batch_no)
  values (auth.uid(), case when u.mode = 'arsip' then 'bukti_tf_arsip' else 'clearing_upload_bank' end,
    jsonb_build_object('detail', case when u.mode = 'arsip' then 'Arsip Bukti TF dari file bank ' || u.nama_file || ': ' || n_ok || ' dokumen'
                                      else 'Clearing dari file bank ' || u.nama_file || ': ' || n_ok || ' dokumen Done' end
                         || case when n_berubah > 0 then ' (' || n_berubah || ' baris berubah sejak pratinjau, tidak diproses)' else '' end,
                       'upload', u.id, 'file', u.nama_file, 'mode', u.mode, 'jumlah', n_ok, 'berubah', n_berubah, 'batch', v_batch),
    'process', 'clearing', 'clearing', v_batch);

  v := rc_private.clearing_bank_hasil(u.id);
  return v || jsonb_build_object('batch', v_batch, 'diproses', n_ok, 'berubah', n_berubah,
    'message', case when u.mode = 'arsip' then n_ok || ' Bukti TF tersimpan (klaim tidak diubah)'
                    else n_ok || ' dokumen di-Clearing (Done), batch ' || coalesce(v_batch, '-') end
      || case when n_berubah > 0 then '; ' || n_berubah || ' baris berubah sejak pratinjau dan tidak diproses' else '' end || '.');
end $f$;

revoke all on function public.rc_clearing_bank_preview(text, text, integer, text, jsonb, text), public.rc_clearing_bank_proses(uuid) from public, anon;
grant execute on function public.rc_clearing_bank_preview(text, text, integer, text, jsonb, text), public.rc_clearing_bank_proses(uuid) to authenticated;

-- ---- 6. Document Generator: Bukti TF di form PDA ----------------------------------------------------
do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('public.rc_docgen_generate(jsonb,text,jsonb)'::regprocedure), E'\r', '');
  if src !~ 'bukti_tf' then
    src := pg_temp.ganti(src,
      $p$  v_bt date := rc_private.docgen_batas_pda(); v_kat text; v_ada boolean; n_pda integer := 0; n_pdh integer := 0;$p$,
      $p$  v_bt date := rc_private.docgen_batas_pda(); v_kat text; v_ada boolean; n_pda integer := 0; n_pdh integer := 0;
  v_bukti jsonb; -- 20261163730000: Bukti TF klaim form PDA$p$, 1, 'generate declare');
    src := pg_temp.ganti(src,
      $p$      select array_agg(x::uuid order by x::uuid) into v_ids from jsonb_array_elements_text(v_satu_isi->'ids') x;
$p$,
      $p$      select array_agg(x::uuid order by x::uuid) into v_ids from jsonb_array_elements_text(v_satu_isi->'ids') x;
      v_bukti := case when v_kat = 'PDA' then (select jsonb_agg(z.j order by z.j->>'tglEfektif', z.j->>'noDoc') from
                   (select rc_private.bukti_tf(x) j from unnest(v_ids) x) z where z.j is not null) end;
$p$, 1, 'generate bukti');
    src := pg_temp.ganti(src,
      $p$        'campaigns', v_rows, 'total', v_total, 'halaman', ceil(v_n / 4.0)::integer, 'jumlahKlaim', cardinality(v_ids));$p$,
      $p$        'campaigns', v_rows, 'total', v_total, 'halaman', ceil(v_n / 4.0)::integer, 'jumlahKlaim', cardinality(v_ids),
        'bukti', coalesce(v_bukti, '[]'::jsonb));$p$, 1, 'generate form');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_docgen_list(text,jsonb,integer,integer,boolean)'::regprocedure), E'\r', '');
  if src !~ 'n_bukti' then
    src := pg_temp.ganti(src,
      $p$           bool_or(rc_private.docgen_kategori(k.tgl_done, k.jenis_cb) = 'PDH') ada_pdh$p$,
      $p$           bool_or(rc_private.docgen_kategori(k.tgl_done, k.jenis_cb) = 'PDH') ada_pdh,
           -- 20261163730000: dokumen ber-Bukti TF (Clearing / arsip file bank).
           count(*) filter (where exists (select 1 from public.rc_clearing_bank_baris bb where bb.claim_id = k.claim_id and bb.diproses)) n_bukti$p$,
      1, 'list t');
    src := pg_temp.ganti(src,
      $p$t.done_awal, t.done_akhir, t.ada_pda, t.ada_pdh,$p$,
      $p$t.done_awal, t.done_akhir, t.ada_pda, t.ada_pdh, t.n_bukti,$p$, 1, 'list s');
    src := pg_temp.ganti(src,
      $p$'remark', concat_ws(' + ', case when h.ada_pda then 'PDA' end, case when h.ada_pdh then 'PDH' end) /* 20261163700000 */)$p$,
      $p$'remark', concat_ws(' + ', case when h.ada_pda then 'PDA' end, case when h.ada_pdh then 'PDH' end) /* 20261163700000 */,
             'buktiTf', h.n_bukti /* 20261163730000 */)$p$, 1, 'list out');
    execute src;
  end if;
end $tambal$;

do $cek$ begin
  if pg_get_functiondef('public.rc_docgen_generate(jsonb,text,jsonb)'::regprocedure) !~ 'bukti_tf' then raise exception 'GAGAL: generate'; end if;
  if pg_get_functiondef('public.rc_docgen_list(text,jsonb,integer,integer,boolean)'::regprocedure) !~ 'n_bukti' then raise exception 'GAGAL: list'; end if;
end $cek$;
