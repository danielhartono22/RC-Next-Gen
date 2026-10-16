-- ==========================================================================================
-- Dashboard publik: ringkasan tanpa penyaring dihitung berkala, bukan pada setiap kunjungan
-- ==========================================================================================
-- Disetujui pemilik, 29 September 2026.
--
-- rc_dashboard_publik dipanggil pengunjung tanpa login (peran anon), yang dibatasi 3 detik
-- per kueri. Setiap kunjungan menghitung ulang Report Dashboard, Cost Center 1 dan Cost
-- Center 2 atas seluruh klaim. Di dev (100 ribu klaim) perhitungan itu makan belasan detik:
-- halaman publik selalu gagal "statement timeout".
--
-- PERUBAHAN
--   * Tampilan TANPA PENYARING - bawaan halaman publik - diambil dari snapshot yang dihitung
--     ulang tiap 5 menit oleh pg_cron. Angkanya bisa tertinggal paling lama beberapa menit;
--     halaman sudah menampilkan "Data per <waktu>", dan waktu itu kini waktu snapshot.
--   * Snapshot yang lebih tua dari 30 menit tidak dipakai (misalnya bila cron berhenti):
--     perhitungan langsung diambil alih, supaya angka lama tidak tampil diam-diam berhari-hari.
--   * Bila ADA penyaring apa pun, hasilnya tetap dihitung langsung persis seperti sekarang.
--     "Tanpa penyaring" berarti SEMUA nilai filter kosong - termasuk kunci yang kelak
--     ditambahkan - jadi tidak ada penyaring yang terabaikan oleh snapshot.
--   * Badan perhitungannya dipindah apa adanya ke rc_private.dashboard_publik_hitung; dipakai
--     oleh perhitungan langsung maupun oleh pembuat snapshot, jadi keduanya tidak mungkin
--     berbeda isi.
--
-- Snapshot disimpan di rc_private (tidak terbuka lewat API) dan hanya dibaca lewat
-- rc_dashboard_publik, yang tetap SECURITY DEFINER dengan hak eksekusi yang sama.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 0. Penjaga pra-citra
-- ------------------------------------------------------------------------------------------
do $pra$
declare md5_kini text;
begin
  md5_kini := md5(pg_get_functiondef('public.rc_dashboard_publik(jsonb)'::regprocedure));
  if md5_kini = '38a124c407502df6c5b4e000f5cfd861' then return; end if;
  if pg_get_functiondef('public.rc_dashboard_publik(jsonb)'::regprocedure) ~ 'dashboard_publik_hitung' then
    raise notice 'rc_dashboard_publik sudah memakai snapshot.'; return; end if;
  raise exception 'DITOLAK: definisi rc_dashboard_publik berbeda dari yang diukur (md5 %). '
    'Bandingkan dulu definisinya sebelum menerapkan migrasi ini.', md5_kini;
end
$pra$;

-- ------------------------------------------------------------------------------------------
-- 1. Perhitungan, satu tempat
-- ------------------------------------------------------------------------------------------
-- Isinya persis badan rc_dashboard_publik yang lama.
create or replace function rc_private.dashboard_publik_hitung(p_filter jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select jsonb_build_object(
    'status','success',
    'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'),
    'dashboard', rc_private.report_dashboard(coalesce(p_filter,'{}'::jsonb)),
    'cc1',       rc_private.cost_center(coalesce(p_filter,'{}'::jsonb)),
    'cc2',       rc_private.cost_center_2(coalesce(p_filter,'{}'::jsonb))
  );
$fn$;
revoke all on function rc_private.dashboard_publik_hitung(jsonb) from public, anon, authenticated;

-- Pembuktian: badan yang dipindah menghasilkan keluaran yang sama dengan fungsi lama. Memakai
-- penyaring satu depot supaya cepat; badannya sama untuk penyaring apa pun, dan di dalam satu
-- transaksi now() sama, jadi "dibuatPada" pun harus identik.
do $setara$
declare f jsonb; lama jsonb; baru jsonb;
begin
  if pg_get_functiondef('public.rc_dashboard_publik(jsonb)'::regprocedure) ~ 'dashboard_publik_hitung' then
    return; end if;
  select jsonb_build_object('depot', d.depot_code) into f
    from public.depots d order by d.depot_code limit 1;
  f := coalesce(f, '{}'::jsonb);
  lama := public.rc_dashboard_publik(f);
  baru := rc_private.dashboard_publik_hitung(f);
  if lama is distinct from baru then
    raise exception 'GAGAL: badan perhitungan yang dipindah tidak menghasilkan keluaran yang sama.'; end if;
  raise notice 'Badan perhitungan identik (penyaring %).', f;
end
$setara$;

-- ------------------------------------------------------------------------------------------
-- 2. Snapshot
-- ------------------------------------------------------------------------------------------
create table if not exists rc_private.dashboard_publik_cache(
  kunci text primary key,
  isi jsonb not null,
  dibuat_pada timestamptz not null default now()
);
revoke all on rc_private.dashboard_publik_cache from public, anon, authenticated;

-- Benar bila tidak ada satu pun nilai penyaring yang terisi. Bukan objek (null, larik) berarti
-- tanpa penyaring - persis cara ketiga perhitungan membacanya lewat ->>.
create or replace function rc_private.filter_publik_kosong(p_filter jsonb)
returns boolean language sql immutable set search_path to '' as $fn$
  select case
    when p_filter is null or jsonb_typeof(p_filter) <> 'object' then true
    else not exists (select 1 from jsonb_each_text(p_filter) e
                      where nullif(btrim(e.value), '') is not null)
  end;
$fn$;
revoke all on function rc_private.filter_publik_kosong(jsonb) from public, anon, authenticated;

create or replace function rc_private.segarkan_dashboard_publik()
returns void language plpgsql security definer set search_path to '' as $fn$
begin
  insert into rc_private.dashboard_publik_cache(kunci, isi, dibuat_pada)
  values ('semua', rc_private.dashboard_publik_hitung('{}'::jsonb), now())
  on conflict (kunci) do update set isi = excluded.isi, dibuat_pada = excluded.dibuat_pada;
end
$fn$;
revoke all on function rc_private.segarkan_dashboard_publik() from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. rc_dashboard_publik memakai snapshot bila tanpa penyaring
-- ------------------------------------------------------------------------------------------
-- LANGUAGE berubah dari sql ke plpgsql; tanda tangan, SECURITY DEFINER, search_path dan hak
-- eksekusi (anon, authenticated) tetap.
create or replace function public.rc_dashboard_publik(p_filter jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_isi jsonb;
begin
  -- Tanpa penyaring: snapshot berkala (rc_private.segarkan_dashboard_publik, tiap 5 menit),
  -- selama belum lebih tua dari 30 menit.
  if rc_private.filter_publik_kosong(p_filter) then
    select c.isi into v_isi from rc_private.dashboard_publik_cache c
     where c.kunci = 'semua' and c.dibuat_pada > now() - interval '30 minutes';
    if v_isi is not null then return v_isi; end if;
  end if;
  -- Dengan penyaring, atau snapshot tidak tersedia: dihitung langsung seperti dulu.
  return rc_private.dashboard_publik_hitung(p_filter);
end
$fn$;

-- Snapshot pertama dibuat sekarang, supaya halaman publik langsung terlayani.
select rc_private.segarkan_dashboard_publik();

-- Pemeriksaan: tanpa penyaring - dalam beberapa bentuk - mendapat snapshot; dengan penyaring
-- mendapat perhitungan langsung yang sama dengan badan perhitungannya.
do $periksa$
declare cache jsonb; f jsonb; b text;
begin
  select isi into cache from rc_private.dashboard_publik_cache where kunci = 'semua';
  foreach b in array array['{}', '{"region":"","depot":" ","campaign":"","tahunCampaign":"","billingStart":"","billingEnd":"","tahun":""}', 'null'] loop
    if public.rc_dashboard_publik(b::jsonb) is distinct from cache then
      raise exception 'GAGAL: filter kosong % tidak dilayani snapshot.', b; end if;
  end loop;
  if public.rc_dashboard_publik(null) is distinct from cache then
    raise exception 'GAGAL: filter null tidak dilayani snapshot.'; end if;

  select jsonb_build_object('depot', d.depot_code) into f
    from public.depots d order by d.depot_code limit 1;
  if f is not null and public.rc_dashboard_publik(f) is distinct from rc_private.dashboard_publik_hitung(f) then
    raise exception 'GAGAL: dengan penyaring, hasilnya bukan perhitungan langsung.'; end if;
  raise notice 'Dashboard publik: snapshot dan perhitungan langsung terpasang benar.';
end
$periksa$;

-- ------------------------------------------------------------------------------------------
-- 4. Jadwal
-- ------------------------------------------------------------------------------------------
-- cron.schedule dengan nama yang sudah ada memperbarui jadwalnya, jadi aman diulang.
select cron.schedule('rc_dashboard_publik_segar', '*/5 * * * *',
                     'select rc_private.segarkan_dashboard_publik()');
