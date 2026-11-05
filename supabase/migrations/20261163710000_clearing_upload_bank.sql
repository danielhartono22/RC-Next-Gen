-- ==========================================================================================
-- Claim Process > Clearing: jalur Upload File Bank (KlikBCA Bisnis, MultiTransactionAutoTransfer)
-- ==========================================================================================
-- Pemilik, 5 November 2026: Clearing bisa diisi dengan upload file bank
-- "MultiTransactionAutoTransferDownload_DDMMYYYYHHMMSS.txt". Keputusan pemilik:
--   1. Jalur lama (centang + Tgl Transfer + Posting Done, Mass Process) TETAP ada; ini jalur tambahan.
--   2. No Doc terpotong (Remark 1 dipotong bank di 18 karakter) DITOLAK, diproses manual.
--   3. Nominal transfer dibandingkan dengan Net CB (cb_net tanpa desimal); beda = ditolak + keterangan.
--
-- * File dibaca di browser (src/js/57-clearing-bank.js, kolom dipotong menurut posisi judul kolom
--   header). Server menerima baris hasil baca, menilai setiap baris, dan menyimpan log upload.
-- * rc_clearing_bank_preview: menilai TANPA mengubah klaim. Hasil per baris:
--     ok              No Doc ketemu, Claimed (Pending Finance), nominal = Net CB
--     nominal_beda    nominal klaim vs transfer berbeda
--     tidak_ditemukan No Doc tidak ada di RC (mis. CB/..., CBCN/...)
--     terpotong       Remark 1 penuh 18 karakter dan cocok dengan awalan No Doc RC - proses manual
--     sudah_clearing  klaim sudah Done (tanggal clearing sebelumnya ditampilkan)
--     belum_siap      klaim ada tetapi bukan Claimed / menunggu approval / Rebate (Bulk Process)
--     sudah_diproses  Trans ID + tanggal yang sama sudah pernah di-Clearing lewat file lain
--     gagal_transfer  Status di file bukan "Berhasil"
--     duplikat        No Doc sama muncul lebih dari sekali dalam file
--     tanggal_salah   Eff Date tidak terbaca atau belum terjadi
--   Remark 1 dicocokkan persis, lalu dengan awalan "NPC/" (Remark 1 bank tidak memuat "NPC/").
-- * rc_clearing_bank_proses: menilai ulang baris OK (data bisa berubah sejak pratinjau), lalu
--   memanggil ALUR CLEARING LAMA rc_private.mutate_claims('clearing') dengan Tgl Transfer = Eff
--   Date tiap baris: status Done, batch Clearing 04, cleared_actual_on, email Done - tanpa perubahan.
-- * File dengan isi sama (sidik SHA-256) tidak bisa diproses dua kali, walau namanya diganti.
-- * Log: rc_clearing_bank_upload (nama file, sidik, user, waktu, batch) dan rc_clearing_bank_baris
--   (Trans ID, hasil per baris). Log Activity satu baris per proses.
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ---- 1. Tabel log ---------------------------------------------------------------------------------
create table if not exists public.rc_clearing_bank_upload (
  id uuid primary key default gen_random_uuid(),
  nama_file text not null,
  sidik text not null,
  tahun integer not null,
  tahun_sumber text not null check (tahun_sumber in ('nama_file', 'form')),
  jumlah_baris integer not null default 0,
  jumlah_berhasil integer not null default 0,
  total_nominal numeric not null default 0,
  ringkasan jsonb not null default '{}',
  status text not null default 'pratinjau' check (status in ('pratinjau', 'diproses')),
  jumlah_diproses integer,
  batch_clearing text,
  diunggah_oleh uuid references public.profiles(id),
  diunggah_pada timestamptz not null default now(),
  diproses_oleh uuid references public.profiles(id),
  diproses_pada timestamptz
);
create unique index if not exists rc_clearing_bank_upload_sidik_diproses on public.rc_clearing_bank_upload (sidik) where status = 'diproses';

create table if not exists public.rc_clearing_bank_baris (
  upload_id uuid not null references public.rc_clearing_bank_upload(id) on delete cascade,
  baris_ke integer not null,
  trans_id text not null default '',
  eff_date_teks text not null default '',
  tgl_transfer date,
  remark1 text not null default '',
  no_doc_rc text,
  claim_id uuid references public.claims(id),
  bank text not null default '',
  to_acc text not null default '',
  nominal numeric,
  nominal_klaim numeric,
  status_bank text not null default '',
  reason text not null default '',
  hasil text not null,
  keterangan text not null default '',
  diproses boolean not null default false,
  primary key (upload_id, baris_ke)
);
create unique index if not exists rc_clearing_bank_baris_trans_diproses on public.rc_clearing_bank_baris (trans_id, tgl_transfer)
  where diproses and trans_id <> '';
create index if not exists rc_clearing_bank_baris_claim on public.rc_clearing_bank_baris (claim_id);

alter table public.rc_clearing_bank_upload enable row level security;
alter table public.rc_clearing_bank_baris enable row level security;
revoke all on public.rc_clearing_bank_upload, public.rc_clearing_bank_baris from public, anon, authenticated;

-- ---- 2. Penilaian satu baris -------------------------------------------------------------------
-- Dipakai pratinjau dan dinilai ulang saat proses. p_dupe = No Doc ini muncul > 1 kali di file.
create or replace function rc_private.clearing_bank_nilai(p_remark text, p_tgl date, p_nominal numeric, p_berhasil boolean,
  p_status_bank text, p_reason text, p_trans_id text, p_dupe boolean, p_upload uuid)
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
    select u.nama_file, u.batch_clearing, u.diproses_pada into v_lama
      from public.rc_clearing_bank_baris b join public.rc_clearing_bank_upload u on u.id = b.upload_id
     where b.diproses and b.trans_id = btrim(p_trans_id) and b.tgl_transfer = p_tgl and b.upload_id <> coalesce(p_upload, gen_random_uuid())
     limit 1;
    if found then
      return query select 'sudah_diproses', 'Trans ID sudah di-Clearing lewat ' || v_lama.nama_file || ' (' ||
        to_char(v_lama.diproses_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || coalesce(', batch ' || v_lama.batch_clearing, '') || ')',
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
    -- Remark 1 dipotong bank di 18 karakter: cocok awalan = terpotong (ditolak, proses manual).
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

  if c.status = 'done' then
    return query select 'sudah_clearing', 'Sudah Done; tanggal clearing ' ||
      coalesce(to_char(coalesce(c.cleared_actual_on, (c.cleared_at at time zone 'Asia/Jakarta')::date), 'DD-Mon-YYYY'), '-') ||
      coalesce(', batch ' || nullif(btrim(c.batch_clearing), ''), ''), c.id, c.no_doc, trunc(c.cb_net); return;
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
revoke all on function rc_private.clearing_bank_nilai(text, date, numeric, boolean, text, text, text, boolean, uuid) from public, anon, authenticated;

-- Hasil satu upload untuk layar / Excel.
create or replace function rc_private.clearing_bank_hasil(p_upload uuid) returns jsonb
language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object('status', 'success',
    'upload', jsonb_build_object('id', u.id, 'namaFile', u.nama_file, 'tahun', u.tahun, 'tahunSumber', u.tahun_sumber, 'status', u.status,
       'batch', u.batch_clearing, 'jumlahDiproses', u.jumlah_diproses,
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
revoke all on function rc_private.clearing_bank_hasil(uuid) from public, anon, authenticated;

-- ---- 3. Pratinjau ---------------------------------------------------------------------------------
-- p_baris: [{baris, transId, effDate, tglTransfer (YYYY-MM-DD|null), nominal, remark1, bank, toAcc, status, reason}]
create or replace function public.rc_clearing_bank_preview(p_nama_file text, p_sidik text, p_tahun integer, p_tahun_sumber text, p_baris jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v_id uuid; v_lama record; e jsonb; v_tgl date; n_baris integer; v jsonb;
begin
  perform rc_private.require_tab('process.clearing');
  if btrim(coalesce(p_nama_file, '')) = '' then raise exception 'Nama file wajib'; end if;
  if coalesce(p_sidik, '') !~ '^[0-9a-f]{64}$' then raise exception 'Sidik file tidak valid'; end if;
  if p_tahun is null or p_tahun < 2020 or p_tahun > 2100 then raise exception 'Tahun file tidak valid (isi tahun transfer)'; end if;
  if coalesce(p_tahun_sumber, '') not in ('nama_file', 'form') then raise exception 'Sumber tahun tidak dikenal'; end if;
  if jsonb_typeof(p_baris) is distinct from 'array' or jsonb_array_length(p_baris) = 0 then raise exception 'File tidak berisi baris transaksi'; end if;
  if jsonb_array_length(p_baris) > 5000 then raise exception 'Maksimal 5.000 baris per file'; end if;

  select u.nama_file, u.diproses_pada, u.batch_clearing, coalesce(nullif(p.full_name, ''), p.user_code, '-') oleh into v_lama
    from public.rc_clearing_bank_upload u left join public.profiles p on p.id = u.diproses_oleh
   where u.sidik = p_sidik and u.status = 'diproses' limit 1;
  if found then
    raise exception 'File ini sudah diproses pada % oleh % (%, batch %). File yang sama tidak bisa diproses dua kali.',
      to_char(v_lama.diproses_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), v_lama.oleh, v_lama.nama_file, coalesce(v_lama.batch_clearing, '-');
  end if;

  insert into public.rc_clearing_bank_upload(nama_file, sidik, tahun, tahun_sumber, diunggah_oleh)
  values (left(btrim(p_nama_file), 300), p_sidik, p_tahun, p_tahun_sumber, auth.uid()) returning id into v_id;

  for e in select value from jsonb_array_elements(p_baris) loop
    begin v_tgl := nullif(btrim(coalesce(e->>'tglTransfer', '')), '')::date; exception when others then v_tgl := null; end;
    insert into public.rc_clearing_bank_baris(upload_id, baris_ke, trans_id, eff_date_teks, tgl_transfer, remark1, bank, to_acc, nominal, status_bank, reason, hasil)
    values (v_id, (e->>'baris')::integer, left(btrim(coalesce(e->>'transId', '')), 100), left(btrim(coalesce(e->>'effDate', '')), 40), v_tgl,
            left(btrim(coalesce(e->>'remark1', '')), 100), left(btrim(coalesce(e->>'bank', '')), 100), left(btrim(coalesce(e->>'toAcc', '')), 60),
            case when coalesce(e->>'nominal', '') ~ '^[0-9]+(\.[0-9]+)?$' then trunc((e->>'nominal')::numeric) end,
            left(btrim(coalesce(e->>'status', '')), 60), left(btrim(coalesce(e->>'reason', '')), 300), 'baru');
  end loop;

  -- Duplikat: No Doc (setelah awalan NPC/) yang muncul > 1 kali di antara baris berhasil.
  update public.rc_clearing_bank_baris b set
    hasil = n.hasil, keterangan = n.keterangan, claim_id = n.claim_id, no_doc_rc = n.no_doc_rc, nominal_klaim = n.nominal_klaim
    from (select b2.baris_ke, z.* from public.rc_clearing_bank_baris b2
            cross join lateral rc_private.clearing_bank_nilai(b2.remark1, b2.tgl_transfer, b2.nominal, lower(b2.status_bank) = 'berhasil',
              b2.status_bank, b2.reason, b2.trans_id,
              (select count(*) from public.rc_clearing_bank_baris b3
                where b3.upload_id = b2.upload_id and lower(b3.status_bank) = 'berhasil' and b3.remark1 <> ''
                  and regexp_replace(upper(b3.remark1), '^NPC/', '') = regexp_replace(upper(b2.remark1), '^NPC/', '')) > 1, b2.upload_id) z
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
                                 || ' siap Clearing. Belum ada klaim yang diubah.');
end $f$;

-- ---- 4. Proses Clearing ------------------------------------------------------------------------------
create or replace function public.rc_clearing_bank_proses(p_upload uuid)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare u public.rc_clearing_bank_upload; v_items jsonb; v_hasil jsonb; v_batch text; n integer; n_berubah integer := 0; v jsonb;
begin
  perform rc_private.require_tab('process.clearing');
  select * into u from public.rc_clearing_bank_upload where id = p_upload for update;
  if not found then raise exception 'Upload tidak ditemukan'; end if;
  if u.status = 'diproses' then raise exception 'Upload ini sudah diproses (batch %).', coalesce(u.batch_clearing, '-'); end if;
  if exists (select 1 from public.rc_clearing_bank_upload x where x.sidik = u.sidik and x.status = 'diproses') then
    raise exception 'File dengan isi yang sama sudah diproses sebelumnya. File yang sama tidak bisa diproses dua kali.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('rc_clearing_bank', 0));

  -- Nilai ulang baris OK: klaim bisa berubah sejak pratinjau.
  with nilai as (
    select b.baris_ke, z.* from public.rc_clearing_bank_baris b
      cross join lateral rc_private.clearing_bank_nilai(b.remark1, b.tgl_transfer, b.nominal, true, b.status_bank, b.reason, b.trans_id, false, b.upload_id) z
     where b.upload_id = u.id and b.hasil = 'ok')
  update public.rc_clearing_bank_baris b set hasil = n.hasil, claim_id = n.claim_id, no_doc_rc = n.no_doc_rc, nominal_klaim = n.nominal_klaim,
         keterangan = case when n.hasil = 'ok' then b.keterangan else 'Berubah sejak pratinjau: ' || n.keterangan end
    from nilai n where b.upload_id = u.id and b.baris_ke = n.baris_ke;
  get diagnostics n = row_count;
  select count(*) into n_berubah from public.rc_clearing_bank_baris b where b.upload_id = u.id and b.keterangan like 'Berubah sejak pratinjau:%';

  select jsonb_agg(jsonb_build_object('no_doc', c.no_doc, 'version_no', c.version_no, 'tgl_aktual', to_char(b.tgl_transfer, 'YYYY-MM-DD')) order by c.no_doc)
    into v_items
    from public.rc_clearing_bank_baris b join public.claims c on c.id = b.claim_id
   where b.upload_id = u.id and b.hasil = 'ok';
  if v_items is null then
    raise exception 'Tidak ada baris berstatus OK untuk diproses%.', case when n_berubah > 0 then ' (' || n_berubah || ' baris berubah sejak pratinjau)' else '' end;
  end if;

  -- Alur Clearing lama, apa adanya: Done, batch Clearing 04, Tgl Transfer aktual per dokumen, email Done.
  v_hasil := rc_private.mutate_claims('clearing', v_items, gen_random_uuid(), '');
  v_batch := v_hasil->>'batch';

  update public.rc_clearing_bank_baris b set diproses = true,
         keterangan = 'Clearing selesai, Tgl Transfer ' || to_char(b.tgl_transfer, 'DD-Mon-YYYY') || coalesce(', batch ' || v_batch, '')
   where b.upload_id = u.id and b.hasil = 'ok';
  update public.rc_clearing_bank_upload set status = 'diproses', batch_clearing = v_batch, jumlah_diproses = jsonb_array_length(v_items),
         diproses_oleh = auth.uid(), diproses_pada = now(),
         ringkasan = (select coalesce(jsonb_object_agg(z.hasil, z.n), '{}'::jsonb) from (select b.hasil, count(*) n from public.rc_clearing_bank_baris b
                       where b.upload_id = u.id group by 1) z)
   where id = u.id;

  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage, batch_no)
  values (auth.uid(), 'clearing_upload_bank',
    jsonb_build_object('detail', 'Clearing dari file bank ' || u.nama_file || ': ' || jsonb_array_length(v_items) || ' dokumen Done'
                         || case when n_berubah > 0 then ' (' || n_berubah || ' baris berubah sejak pratinjau, tidak diproses)' else '' end,
                       'upload', u.id, 'file', u.nama_file, 'jumlah', jsonb_array_length(v_items), 'berubah', n_berubah, 'batch', v_batch),
    'process', 'clearing', 'clearing', v_batch);

  v := rc_private.clearing_bank_hasil(u.id);
  return v || jsonb_build_object('batch', v_batch, 'diproses', jsonb_array_length(v_items), 'berubah', n_berubah,
    'message', jsonb_array_length(v_items) || ' dokumen di-Clearing (Done), batch ' || coalesce(v_batch, '-')
      || case when n_berubah > 0 then '; ' || n_berubah || ' baris berubah sejak pratinjau dan tidak diproses' else '' end || '.');
end $f$;

revoke all on function public.rc_clearing_bank_preview(text, text, integer, text, jsonb), public.rc_clearing_bank_proses(uuid) from public, anon;
grant execute on function public.rc_clearing_bank_preview(text, text, integer, text, jsonb), public.rc_clearing_bank_proses(uuid) to authenticated;
