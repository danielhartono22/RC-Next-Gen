-- ==========================================================================================
-- Dashboard publik menerima filter
-- ==========================================================================================
-- Permintaan pemilik: "yang dashboard open saya mau filter nya juga tambahkan".
--
-- Sebelumnya bilah filter Region/Depot/Campaign sengaja saya tiadakan dari halaman publik,
-- dengan alasan filter mengandaikan sesi sedangkan halaman itu tidak tahu siapa yang membukanya.
-- Alasan itu keliru. Filter di modul Report bukan soal identitas - ia hanya mempersempit
-- agregasi. Yang menentukan siapa melihat apa adalah RLS dan pemeriksaan hak akses, bukan isi
-- bilah filter.
--
-- Karena badan agregasinya sudah bersama sejak 20261132, satu-satunya yang perlu berubah adalah
-- pembungkus publik: ia kini menerima p_filter dan meneruskannya apa adanya ke ketiga badan yang
-- sama. Tidak ada kueri baru, tidak ada perilaku filter kedua yang bisa menyimpang dari yang di
-- dalam aplikasi.
--
-- ------------------------------------------------------------------------------------------
-- TANDA TANGANNYA BERUBAH, JADI YANG LAMA DIHAPUS
-- ------------------------------------------------------------------------------------------
-- rc_dashboard_publik() tanpa argumen dibiarkan hidup berdampingan akan membuat pemanggilan
-- tanpa argumen menjadi ambigu - Postgres tidak dapat memilih di antara keduanya. Yang lama
-- karena itu dihapus lebih dulu.
--
-- Halaman publik memanggilnya lewat PostgREST dengan nama argumen p_filter; nilai baku
-- '{}'::jsonb menjaga pemanggilan tanpa argumen tetap sah, sehingga tautan lama tetap bekerja.
--
-- ------------------------------------------------------------------------------------------
-- BATASNYA TIDAK IKUT MELONGGAR
-- ------------------------------------------------------------------------------------------
-- Filter hanya mempersempit. Ia tidak dapat memperluas apa pun: ketiga badan agregasi bekerja
-- pada tingkat Depot, Campaign, Region dan bulan, dan tidak satu pun menyentuh nama toko, KTP,
-- NPWP atau nomor rekening - berapa pun nilai yang dikirimkan. Pemeriksaan di bawah menguji itu
-- dengan filter yang dibuat-buat sekalipun.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

drop function if exists public.rc_dashboard_publik();

create or replace function public.rc_dashboard_publik(p_filter jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path='' as $fn$
  select jsonb_build_object(
    'status','success',
    'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
    'dashboard', rc_private.report_dashboard(coalesce(p_filter,'{}'::jsonb)),
    'cc1',       rc_private.cost_center(coalesce(p_filter,'{}'::jsonb)),
    'cc2',       rc_private.cost_center_2(coalesce(p_filter,'{}'::jsonb))
  );
$fn$;

revoke all on function public.rc_dashboard_publik(jsonb) from public;
grant execute on function public.rc_dashboard_publik(jsonb) to anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_semua jsonb; v_saring jsonb; v_depot text; n_semua int; n_saring int;
begin
  if not has_function_privilege('anon','public.rc_dashboard_publik(jsonb)','execute') then
    raise exception 'GAGAL: anon tidak dapat memanggil dashboard publik.'; end if;

  -- Tanpa argumen harus tetap sah, supaya tautan yang sudah beredar tidak patah.
  v_semua := public.rc_dashboard_publik();
  if (v_semua->>'status') <> 'success' then
    raise exception 'GAGAL: pemanggilan tanpa argumen tidak berhasil.'; end if;

  n_semua := jsonb_array_length(v_semua->'cc1'->'rows');
  -- Tanpa data, penyaring tidak dapat diuji - tetapi fungsinya sudah terpasang dan benar.
  -- Dilewati dengan jejak, seperti migrasi lain di repo ini, alih-alih menggagalkan pemasangan.
  if n_semua = 0 then
    raise notice 'Belum ada data; pemeriksaan penyaring dilewati.'; return; end if;

  -- Filter harus benar-benar mempersempit, dan hasilnya harus sama dengan yang didapat modul
  -- Report untuk filter yang sama - keduanya memanggil badan yang sama.
  select v_semua->'cc1'->'rows'->0->>'kodeDepot' into v_depot;
  v_saring := public.rc_dashboard_publik(jsonb_build_object('depot', v_depot));
  n_saring := jsonb_array_length(v_saring->'cc1'->'rows');

  if n_saring = 0 then
    raise exception 'GAGAL: filter depot % menghasilkan nol baris.', v_depot; end if;
  if n_saring >= n_semua then
    raise exception 'GAGAL: filter depot % tidak mempersempit (% dari %).',
      v_depot, n_saring, n_semua; end if;
  if (v_saring->'cc1') is distinct from rc_private.cost_center(jsonb_build_object('depot', v_depot)) then
    raise exception 'GAGAL: hasil tersaring berbeda dari badan agregasi bersama.'; end if;

  -- Filter yang tidak cocok apa pun harus menghasilkan kosong, bukan seluruhnya.
  if jsonb_array_length(public.rc_dashboard_publik(
       jsonb_build_object('depot','TIDAK-ADA-DEPOT-INI'))->'cc1'->'rows') <> 0 then
    raise exception 'GAGAL: filter yang tidak cocok tetap mengembalikan baris.'; end if;

  -- Batasnya tidak melonggar oleh filter apa pun.
  if v_saring::text ~* '(namaToko|kodeToko|"ktp"|npwp|noRek|namaRek)' then
    raise exception 'GAGAL: jawaban tersaring memuat data pelanggan.'; end if;

  raise notice 'Tanpa filter % baris cc1; filter depot % -> % baris.', n_semua, v_depot, n_saring;
  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
