-- ==========================================================================================
-- Upload Debtor cukup satu kali sehari: dokumen baru dinilai otomatis; baris lama dibersihkan
-- ==========================================================================================
-- Pemilik, 14 November 2026:
--   "yang tagihan ketika ada compile baru harus reupload tagihan debtor lagi, bisakah ... hanya
--    1x upload per hari ketika yang baru tetep masuk record nya tanpa harus reupload?"
--   Baris upload lama: "no 3" (simpan 7 hari terakhir).
--
-- Sebelumnya penilaian lunas (Open / Restricted) hanya berjalan saat Apply. Dokumen Not Yet yang
-- muncul sesudahnya (compile baru, Expired yang dikembalikan, dokumen yang baru tertaut ke
-- Customer Master, tanggal SO / Billing yang diperbaiki) tidak pernah dinilai, sehingga berkas
-- yang sama diunggah ulang 2-3 kali sehari.
--
-- 1. rc_private.zdage_nilai_baru(): untuk setiap depot yang masih punya dokumen "perlu dinilai",
--    menjalankan penerapan yang SAMA dengan Apply (rc_private.zdage_terapkan_depot) memakai data
--    debtor yang sedang berlaku untuk depot itu. Hasilnya sama persis dengan mengunggah ulang
--    berkas yang sama: toko lunas masuk Open (batas 7 hari, Tgl Lunas = tanggal tarikan), lainnya
--    Restricted beserta alasannya. Dokumen perlu dinilai bila:
--      - belum punya hasil penilaian, atau hasilnya dari upload lain daripada yang berlaku;
--      - dulu tanpa Customer Master dan sekarang sudah tertaut;
--      - hasil terakhirnya lunas tetapi tawarannya sudah tidak aktif (dokumen kembali ke Not Yet
--        sesudah ditolak saat Release, dikembalikan lewat Change Status, atau dikembalikan depot);
--      - bulan SO / Billing yang dipakai saat dinilai berbeda dari yang sekarang.
--    Dipanggil di akhir compile (langsung) dan oleh cron rc_zdage_nilai tiap 10 menit 07-19 WIB.
--    Depot tanpa data debtor tetap tidak dinilai. Saklar ZDAGE mati = tidak berbuat apa-apa.
-- 2. rc_private.bersih_harian() (cron 03:40 WIB): baris rc_zdage_rows milik upload yang berumur
--    lebih dari 7 hari dan tidak sedang berlaku dihapus; ringkasannya (rc_zdage_uploads) tetap.
--    Upload yang tidak pernah diterapkan dan sudah lewat 7 hari ditandai discarded, supaya tidak
--    bisa diterapkan tanpa barisnya. rc_private.requests (kunci anti dobel proses) mendapat
--    kolom waktu dan dibersihkan sesudah 30 hari.
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- 1. Penilaian otomatis -------------------------------------------------------------------
create or replace function rc_private.zdage_nilai_baru()
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare g record; r jsonb; v_hari date := (now() at time zone 'Asia/Jakarta')::date;
  n_depot integer := 0; n_perlu integer := 0; n_tawar integer := 0; n_batal integer := 0;
begin
  if not rc_private.zdage_aktif() then return jsonb_build_object('lewati', 'ZDAGE Integration mati'); end if;
  -- Dua penilaian sekaligus (cron dan compile) tidak ada gunanya: yang kedua dilewati.
  if not pg_try_advisory_xact_lock(hashtext('rc_zdage_nilai_baru')) then
    return jsonb_build_object('lewati', 'sedang berjalan'); end if;

  for g in
    select dd.depot_id, dd.upload_id, dd.kosong, d.depot_code, dd.updated_at, dd.updated_by,
           coalesce(u.toleransi, rc_private.zdage_toleransi()) tol, coalesce(u.mode, rc_private.zdage_mode()) mode, count(*) n
      from public.rc_zdage_depot_data dd
      join public.depots d on d.id = dd.depot_id
      join public.rc_zdage_uploads u on u.id = dd.upload_id
      join public.claims c on c.depot_id = dd.depot_id
      join public.campaigns ca on ca.id = c.campaign_id
      left join public.rc_zdage_hasil h on h.claim_id = c.id
     where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null and d.archived_at is null
       and (h.claim_id is null
            or h.upload_id is distinct from dd.upload_id
            or (h.hasil = 'TANPA_MASTER' and c.customer_id is not null)
            or (h.hasil in ('LUNAS', 'SUDAH_DITAWARKAN')
                and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = c.id and o.status in ('offered', 'overdue')))
            or h.alasan->>'bulanSo' is distinct from to_char(date_trunc('month', coalesce(c.extend_so_start, ca.so_start)), 'YYYY-MM')
            or h.alasan->>'bulanBill' is distinct from to_char(date_trunc('month', coalesce(c.extend_billing_end, ca.billing_end, ca.so_end)), 'YYYY-MM'))
     group by dd.depot_id, dd.upload_id, dd.kosong, d.depot_code, dd.updated_at, dd.updated_by, u.toleransi, u.mode
     order by d.depot_code
  loop
    r := rc_private.zdage_terapkan_depot(g.upload_id, g.depot_id,
           case when g.kosong then array[g.depot_code] else '{}'::text[] end, g.tol, g.mode, v_hari);
    -- Data yang berlaku tidak berubah: catatan "kapan dan oleh siapa diterapkan" dikembalikan.
    update public.rc_zdage_depot_data set updated_at = g.updated_at, updated_by = g.updated_by where depot_id = g.depot_id;
    n_depot := n_depot + 1; n_perlu := n_perlu + g.n;
    n_tawar := n_tawar + coalesce((r->>'tawaranBaru')::integer, 0);
    n_batal := n_batal + coalesce((r->>'kembaliRestricted')::integer, 0);
  end loop;

  if n_perlu > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'zdage_nilai_otomatis', jsonb_build_object(
      'detail', n_perlu || ' dokumen baru dinilai otomatis dengan data debtor yang berlaku (' || n_depot || ' depot): '
                || n_tawar || ' masuk Open, ' || n_batal || ' kembali ke Restricted',
      'jumlah', n_perlu, 'depot', n_depot, 'tawaranBaru', n_tawar, 'kembaliRestricted', n_batal),
      'compilation', 'debtor', 'debtor');
  end if;
  return jsonb_build_object('dinilai', n_perlu, 'depot', n_depot, 'tawaranBaru', n_tawar, 'kembaliRestricted', n_batal);
end $f$;
revoke all on function rc_private.zdage_nilai_baru() from public, anon, authenticated;

-- Compile: dokumen baru langsung dinilai. Kegagalannya tidak pernah membatalkan compile.
do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.compile_upload(jsonb,uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163950000' then
    src := pg_temp.ganti(src, $p$ v_payload:=jsonb_build_object('status','success','dibuat',dibuat,'batch',v_batch_hasil,$p$,
      $p$ -- 20261163950000: dokumen baru dinilai dengan data debtor yang berlaku, tanpa upload ulang.
 if dibuat > 0 then
  begin
   perform rc_private.zdage_nilai_baru();
  exception when others then
   insert into public.activity_logs(actor_id,event_type,details)
   values(actor,'zdage_nilai_gagal',jsonb_build_object('sebab',left(sqlerrm,300)));
  end;
 end if;

 v_payload:=jsonb_build_object('status','success','dibuat',dibuat,'batch',v_batch_hasil,$p$, 1, 'compile nilai otomatis');
    execute src;
  end if;
end $tambal$;

-- ---- 2. Pembersihan harian -------------------------------------------------------------------
alter table rc_private.requests add column if not exists dibuat_pada timestamptz not null default now();

create or replace function rc_private.bersih_harian()
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare n_baris bigint := 0; n_upload integer := 0; n_batal integer := 0; n_req bigint := 0;
begin
  -- Upload yang tidak pernah diterapkan dan sudah lewat 7 hari: dibatalkan, supaya tidak dapat
  -- diterapkan sesudah barisnya dihapus (tanpa baris, semua toko akan terbaca lunas).
  update public.rc_zdage_uploads u set status = 'discarded'
   where u.status in ('preview', 'menerapkan') and u.created_at < now() - interval '7 days';
  get diagnostics n_batal = row_count;

  with h as (
    delete from public.rc_zdage_rows r using public.rc_zdage_uploads u
     where u.id = r.upload_id and u.created_at < now() - interval '7 days'
       and u.status in ('applied', 'discarded')
       and not exists (select 1 from public.rc_zdage_depot_data dd where dd.upload_id = u.id)
    returning r.upload_id)
  select count(*), count(distinct upload_id) into n_baris, n_upload from h;

  delete from rc_private.requests where dibuat_pada < now() - interval '30 days';
  get diagnostics n_req = row_count;

  if n_baris > 0 or n_batal > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (null, 'zdage_bersih', jsonb_build_object(
      'detail', n_baris || ' baris debtor dari ' || n_upload || ' upload lama (lebih dari 7 hari, tidak berlaku) dihapus; ringkasan upload tetap ada'
                || case when n_batal > 0 then '; ' || n_batal || ' upload yang tidak pernah diterapkan dibatalkan' else '' end,
      'jumlah', n_baris, 'upload', n_upload, 'dibatalkan', n_batal), 'compilation', 'debtor', 'debtor');
  end if;
  return jsonb_build_object('barisDebtor', n_baris, 'upload', n_upload, 'dibatalkan', n_batal, 'kunciProses', n_req);
end $f$;
revoke all on function rc_private.bersih_harian() from public, anon, authenticated;

-- ---- 3. Jadwal ---------------------------------------------------------------------------------
-- 07:00-19:50 WIB tiap 10 menit (00-12 UTC); pembersihan 03:40 WIB (20:40 UTC).
select cron.schedule('rc_zdage_nilai', '*/10 0-12 * * *', 'select rc_private.zdage_nilai_baru()');
select cron.schedule('rc_bersih_harian', '40 20 * * *', 'select rc_private.bersih_harian()');

do $cek$
begin
  if pg_get_functiondef('rc_private.compile_upload(jsonb,uuid)'::regprocedure) !~ 'zdage_nilai_baru' then raise exception 'GAGAL: compile belum memanggil penilaian'; end if;
  if (select count(*) from cron.job where jobname in ('rc_zdage_nilai', 'rc_bersih_harian')) <> 2 then raise exception 'GAGAL: jadwal'; end if;
  if has_function_privilege('authenticated', 'rc_private.zdage_nilai_baru()', 'execute') then raise exception 'GAGAL: hak penilaian terbuka'; end if;
end $cek$;
