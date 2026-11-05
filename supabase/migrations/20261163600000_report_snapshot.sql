-- ==========================================================================================
-- Report dari snapshot: tiap 2 jam di jam kerja, saat email Report dikirim, dan manual
-- ==========================================================================================
-- Pemilik, 4 November 2026 (lanjutan analisa CPU prod 30-Okt, docs/analisa-cpu-prod-20261030.md):
--   "setiap ada email ikut snapshoot, dan ada update manual baru snapshoot running tapi by
--    default akan berjalan tiap 2 jam sekali aja dan hanya disegarkan tiap jam kerja 07.00
--    sampe 17.00"
--
-- SEBELUM
--   * Report (Dashboard, Cost Center 1, Cost Center 2), email Daily / Weekly beserta PDF dan
--     grafiknya membaca view public.rc_report_rows langsung - view itu dihitung ulang dari
--     claims setiap kali dibuka, setiap filter diganti, setiap email disusun.
--   * Dashboard publik memakai snapshot JSON yang disegarkan tiap 5 menit sepanjang hari
--     (rc_dashboard_publik_segar, rata-rata 2,5 s di prod).
--
-- SESUDAH
--   * rc_private.report_rows_snap: salinan baris rc_report_rows. Seluruh pembaca di atas membaca
--     salinan ini, sehingga Report di aplikasi, dashboard publik, Excel Report dan email Report
--     selalu menunjukkan angka dari waktu yang sama ("Data per <waktu snapshot>").
--   * Snapshot disegarkan oleh rc_private.segarkan_report(sumber):
--       - jadwal: 07:00, 09:00, 11:00, 13:00, 15:00, 17:00 WIB (cron rc_report_snapshot);
--       - email: tepat sebelum email Daily / Weekly sungguhan dikirim (terjadwal, Kirim Manual
--         atau Test Email). Pratinjau tidak menyegarkan. Bila snapshot belum 2 menit, dipakai
--         apa adanya - Daily dan Weekly di jam yang sama cukup satu kali;
--       - manual: tombol "Perbarui Data" di Report (public.rc_report_segarkan). Bila snapshot
--         belum 5 menit, tidak dihitung ulang supaya tombol tidak membebani server.
--   * Tanpa filter, Report di aplikasi langsung memakai JSON snapshot yang sama dengan
--     dashboard publik; dengan filter dihitung dari salinan (bukan view), jadi tetap ringan.
--   * Dashboard publik tidak lagi membuang snapshot yang lebih tua dari 30 menit: di luar jam
--     kerja snapshot terakhir (17:00) memang dipakai sampai 07:00 esoknya.
--   * "dibuatPada" Report kini waktu snapshot berformat dd-Mmm-yyyy HH:MI, bukan waktu buka.
--
-- Tidak berubah: Not Achieved, Laporan Kesehatan, Expired, Done dan email kejadian lain tetap
-- membaca data langsung - isinya per dokumen / per kejadian, bukan angka Report.
--
-- Bila kolom rc_report_rows kelak berubah, segarkan_report membangun ulang salinannya sendiri.
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ------------------------------------------------------------------------------------------
-- 1. Salinan baris dan catatan waktunya
-- ------------------------------------------------------------------------------------------
create table if not exists rc_private.report_rows_snap as
  select * from public.rc_report_rows with no data;
do $pk$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'rc_private.report_rows_snap'::regclass and contype = 'p') then
    alter table rc_private.report_rows_snap add primary key (id); end if;
end $pk$;
revoke all on rc_private.report_rows_snap from public, anon, authenticated;
-- rc_private.report_dashboard / cost_center berjalan sebagai pemanggil (authenticated), sama
-- seperti hak mereka atas view rc_report_rows. rc_private tidak terbuka lewat API.
grant select on rc_private.report_rows_snap to authenticated;

create table if not exists rc_private.report_snap_meta(
  id boolean primary key default true check (id),
  dibuat_pada timestamptz not null,
  sumber text not null,
  oleh uuid,
  baris integer not null,
  durasi_ms integer not null
);
revoke all on rc_private.report_snap_meta from public, anon, authenticated;

create or replace function rc_private.report_snap_waktu()
returns timestamptz language sql stable security definer set search_path to '' as $fn$
  select coalesce((select m.dibuat_pada from rc_private.report_snap_meta m where m.id), now());
$fn$;
revoke all on function rc_private.report_snap_waktu() from public, anon;
grant execute on function rc_private.report_snap_waktu() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Penyegar
-- ------------------------------------------------------------------------------------------
-- p_jeda: bila snapshot lebih muda dari ini, tidak dihitung ulang. NULL = selalu (jadwal).
-- Kunci advisory membuat dua penyegaran tidak berjalan bersamaan; yang menunggu membaca waktu
-- terbaru sesudah kunci didapat, sehingga dua klik bersamaan hanya menghitung sekali.
create or replace function rc_private.segarkan_report(p_sumber text, p_jeda interval default null)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_mulai timestamptz; v_lama timestamptz; v_n integer; v_ms integer; v_kol_v text; v_kol_t text;
begin
  perform pg_advisory_xact_lock(hashtext('rc_report_snapshot'));
  select m.dibuat_pada into v_lama from rc_private.report_snap_meta m where m.id;
  if p_jeda is not null and v_lama is not null and v_lama > clock_timestamp() - p_jeda then
    return jsonb_build_object('status', 'success', 'diperbarui', false,
      'dibuatPada', to_char(v_lama at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'));
  end if;

  v_mulai := clock_timestamp();
  select string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum) into v_kol_v
    from pg_attribute a where a.attrelid = 'public.rc_report_rows'::regclass and a.attnum > 0 and not a.attisdropped;
  select string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ',' order by a.attnum) into v_kol_t
    from pg_attribute a where a.attrelid = 'rc_private.report_rows_snap'::regclass and a.attnum > 0 and not a.attisdropped;
  if v_kol_v is distinct from v_kol_t then
    drop table rc_private.report_rows_snap;
    create table rc_private.report_rows_snap as select * from public.rc_report_rows with no data;
    alter table rc_private.report_rows_snap add primary key (id);
    revoke all on rc_private.report_rows_snap from public, anon, authenticated;
    grant select on rc_private.report_rows_snap to authenticated;
  else
    -- DELETE, bukan TRUNCATE: pembaca lain tetap melihat salinan lama sampai transaksi ini selesai.
    -- "where true": panggilan lewat API (tombol, Kirim Manual) dijaga pg-safeupdate, yang menolak
    -- DELETE tanpa WHERE.
    delete from rc_private.report_rows_snap where true;
  end if;
  insert into rc_private.report_rows_snap select * from public.rc_report_rows;
  get diagnostics v_n = row_count;
  v_ms := (extract(epoch from clock_timestamp() - v_mulai) * 1000)::integer;

  insert into rc_private.report_snap_meta(id, dibuat_pada, sumber, oleh, baris, durasi_ms)
  values (true, v_mulai, coalesce(nullif(btrim(p_sumber), ''), '-'), auth.uid(), v_n, v_ms)
  on conflict (id) do update set dibuat_pada = excluded.dibuat_pada, sumber = excluded.sumber,
    oleh = excluded.oleh, baris = excluded.baris, durasi_ms = excluded.durasi_ms;

  -- JSON tanpa filter (dashboard publik + Report tanpa filter) dari salinan yang sama.
  perform rc_private.segarkan_dashboard_publik();
  v_ms := (extract(epoch from clock_timestamp() - v_mulai) * 1000)::integer;
  update rc_private.report_snap_meta set durasi_ms = v_ms where id;

  return jsonb_build_object('status', 'success', 'diperbarui', true, 'baris', v_n, 'durasiMs', v_ms,
    'dibuatPada', to_char(v_mulai at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'));
end
$fn$;
revoke all on function rc_private.segarkan_report(text, interval) from public, anon, authenticated;

-- JSON snapshot satu bagian ('dashboard', 'cc1', 'cc2') bila filter kosong; selain itu NULL.
create or replace function rc_private.report_cache_ambil(p_bagian text, p_filter jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select case when rc_private.filter_publik_kosong(p_filter) then
    (select c.isi -> p_bagian from rc_private.dashboard_publik_cache c where c.kunci = 'semua') end;
$fn$;
revoke all on function rc_private.report_cache_ambil(text, jsonb) from public, anon;
grant execute on function rc_private.report_cache_ambil(text, jsonb) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Pembaca rc_report_rows beralih ke salinan
-- ------------------------------------------------------------------------------------------
do $tambal$
declare src text; f text; p record;
begin
  for p in select * from (values
      ('rc_private.report_dashboard(jsonb)', 2),
      ('rc_private.cost_center(jsonb)', 2),
      ('rc_private.cost_center_2(jsonb)', 1),
      ('rc_private.email_chart_status()', 1),
      ('rc_private.email_chart_region()', 1),
      ('rc_private.pdf_detail_html(text)', 4),
      ('public.rc_email_susun(text,boolean,text)', 7)) v(fn, n) loop
    f := p.fn;
    src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
    if src ~ 'rc_private\.report_rows_snap' then raise notice '% sudah membaca salinan.', f; continue; end if;
    src := pg_temp.ganti(src, 'public.rc_report_rows', 'rc_private.report_rows_snap', p.n, f);
    if f = 'rc_private.report_dashboard(jsonb)' then
      src := pg_temp.ganti(src,
        $p$'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')$p$,
        $p$'dibuatPada', to_char(rc_private.report_snap_waktu() at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI') /* 20261163600000 */$p$,
        1, f || ' dibuatPada');
    elsif f = 'public.rc_email_susun(text,boolean,text)' then
      src := pg_temp.ganti(src,
        $p$  -- Ringkasan menyeluruh, dipakai kedua jenis email.$p$,
        $p$  -- 20261163600000: email Report sungguhan (bukan pratinjau) menyegarkan snapshot lebih
  -- dulu, kecuali snapshot belum 2 menit; isi email, PDF dan grafiknya membaca salinan itu.
  if coalesce(p_kirim, false) and v_jenis in ('daily', 'weekly') then
    perform rc_private.segarkan_report('email ' || v_jenis, interval '2 minutes');
  end if;

  -- Ringkasan menyeluruh, dipakai kedua jenis email.$p$, 1, f || ' segarkan');
    end if;
    execute src;
  end loop;
end $tambal$;

do $tambal2$
declare src text; f text;
begin
  -- Dashboard publik: waktu data = waktu snapshot.
  f := 'rc_private.dashboard_publik_hitung(jsonb)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ 'report_snap_waktu' then
    src := pg_temp.ganti(src,
      $p$'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS')$p$,
      $p$'dibuatPada', to_char(rc_private.report_snap_waktu() at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI') /* 20261163600000 */$p$,
      1, f);
    execute src;
  end if;

  -- Dashboard publik: snapshot dipakai berapa pun umurnya; dihitung langsung hanya bila belum ada.
  f := 'public.rc_dashboard_publik(jsonb)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src ~ '30 minutes' then
    src := pg_temp.ganti(src,
      $p$  -- Tanpa penyaring: snapshot berkala (rc_private.segarkan_dashboard_publik, tiap 5 menit),
  -- selama belum lebih tua dari 30 menit.$p$,
      $p$  -- Tanpa penyaring: snapshot Report (20261163600000: tiap 2 jam 07:00-17:00 WIB, saat email
  -- Report dikirim, dan tombol Perbarui Data), berapa pun umurnya.$p$, 1, f || ' komentar');
    src := pg_temp.ganti(src,
      $p$ where c.kunci = 'semua' and c.dibuat_pada > now() - interval '30 minutes';$p$,
      $p$ where c.kunci = 'semua';$p$, 1, f || ' umur');
    execute src;
  end if;

  -- Report di aplikasi tanpa filter: JSON snapshot yang sama dengan dashboard publik.
  for f, src in select x.fn, x.bagian from (values
      ('public.rc_report_dashboard(jsonb)', 'dashboard:report_dashboard'),
      ('public.rc_cost_center(jsonb)', 'cc1:cost_center'),
      ('public.rc_cost_center_2(jsonb)', 'cc2:cost_center_2')) x(fn, bagian) loop
    declare b text := split_part(src, ':', 1); h text := split_part(src, ':', 2); d text;
    begin
      d := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
      if d ~ 'report_cache_ambil' then continue; end if;
      d := pg_temp.ganti(d,
        format('return rc_private.%s(p_filter);', h),
        format('return coalesce(rc_private.report_cache_ambil(%L, p_filter), rc_private.%s(p_filter)); /* 20261163600000 */', b, h),
        1, f);
      execute d;
    end;
  end loop;
end $tambal2$;

-- ------------------------------------------------------------------------------------------
-- 4. Tombol Perbarui Data
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_report_segarkan()
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare r jsonb;
begin
  if not (rc_private.can_tab('report.dashboard') or rc_private.can_tab('report.cc1') or rc_private.can_tab('report.cc2')) then
    raise exception 'Akses tab Report tidak diizinkan' using errcode = '42501'; end if;
  if not rc_private.can_access(null, 'view_report') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat modul Report' using errcode = '42501'; end if;
  r := rc_private.segarkan_report('manual', interval '5 minutes');
  if (r->>'diperbarui')::boolean then
    insert into public.activity_logs(actor_id, event_type, module, tab, details)
    values (auth.uid(), 'report_snapshot_manual', 'Report', 'Dashboard',
            jsonb_build_object('baris', r->'baris', 'durasiMs', r->'durasiMs', 'dibuatPada', r->'dibuatPada'));
  end if;
  return r;
end
$fn$;
revoke all on function public.rc_report_segarkan() from public, anon;
grant execute on function public.rc_report_segarkan() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 5. Jadwal: 07, 09, 11, 13, 15, 17 WIB = 00, 02, 04, 06, 08, 10 UTC
-- ------------------------------------------------------------------------------------------
do $jadwal$ begin
  if exists (select 1 from cron.job where jobname = 'rc_dashboard_publik_segar') then
    perform cron.unschedule('rc_dashboard_publik_segar'); end if;
end $jadwal$;
select cron.schedule('rc_report_snapshot', '0 0,2,4,6,8,10 * * *',
                     $$select rc_private.segarkan_report('jadwal')$$);

-- Snapshot pertama sekarang.
select rc_private.segarkan_report('migrasi');

-- ------------------------------------------------------------------------------------------
-- 6. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $cek$
declare f text;
begin
  if (select count(*) from rc_private.report_rows_snap) <> (select count(*) from public.rc_report_rows) then
    raise exception 'GAGAL: jumlah baris salinan berbeda dari rc_report_rows'; end if;
  foreach f in array array['rc_private.report_dashboard(jsonb)', 'rc_private.cost_center(jsonb)', 'rc_private.cost_center_2(jsonb)',
      'rc_private.email_chart_status()', 'rc_private.email_chart_region()', 'rc_private.pdf_detail_html(text)',
      'public.rc_email_susun(text,boolean,text)'] loop
    if pg_get_functiondef(f::regprocedure) ~ 'public\.rc_report_rows' then
      raise exception 'GAGAL: % masih membaca view langsung', f; end if;
  end loop;
  if (select isi->'dashboard' from rc_private.dashboard_publik_cache where kunci = 'semua') is distinct from rc_private.report_dashboard('{}') then
    raise exception 'GAGAL: JSON snapshot berbeda dari perhitungan atas salinan'; end if;
  if exists (select 1 from cron.job where jobname = 'rc_dashboard_publik_segar') then
    raise exception 'GAGAL: jadwal 5 menit lama masih ada'; end if;
  if not exists (select 1 from cron.job where jobname = 'rc_report_snapshot' and schedule = '0 0,2,4,6,8,10 * * *') then
    raise exception 'GAGAL: jadwal rc_report_snapshot tidak terpasang'; end if;
  raise notice 'Report snapshot terpasang.';
end
$cek$;
