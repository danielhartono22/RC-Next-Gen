-- ==========================================================================================
-- USULAN optimasi RLS - BELUM DITERAPKAN KE PRODUKSI
-- ==========================================================================================
-- Berkas ini sengaja TIDAK diletakkan di supabase/migrations/, supaya tidak ikut terpasang
-- tanpa keputusan sadar. Ia menjawab temuan nomor satu dari pengukuran 20 September 2026.
--
-- BUKTI YANG MELAHIRKANNYA
-- Sebuah count(*) sederhana atas 2.756 klaim, sebagai pengguna admin:
--
--   Seq Scan on claims ... (actual time=1.078..67.045 rows=2754)
--     Filter: ((archived_at IS NULL) AND rc_private.can_access(depot_id, NULL::text))
--     Buffers: shared hit=14385
--   Execution Time: 67.714 ms
--
-- Tabel claims hanya berukuran 5.368 kB (sekitar 671 halaman), tetapi query ini menyentuh
-- 14.385 halaman - dua puluh satu kali lipat ukuran tabelnya. Sebabnya: can_access() dipanggil
-- SEKALI UNTUK SETIAP BARIS, dan tiap panggilan melakukan pencariannya sendiri ke profiles,
-- user_depot_access dan user_permissions.
--
-- Bekasnya terbaca di pg_stat_user_tables: user_permissions - tabel berisi 19 baris -
-- ter-seq-scan 239.810.352 kali dan membaca 51.319.268.378 baris.
--
-- Biayanya tumbuh LURUS terhadap jumlah baris. Pada 100x volume (275.600 klaim) count(*) yang
-- sama diperkirakan memakan sekitar 6,8 detik, sebelum satu pun join atau agregasi ditambahkan.
--
-- SESUDAH PERBAIKAN (diukur, lalu dibatalkan):
--
--   Index Scan using claims_campaign_idx on claims ... (actual time=0.452..2.051 rows=2754)
--     Index Cond: (depot_id = ANY (rc_private.depot_saya()))
--     Buffers: shared hit=619
--   Execution Time: 2.251 ms
--
--   67,714 ms -> 2,251 ms  (30x lebih cepat)
--   14.385 -> 619 halaman  (23x lebih sedikit)
--   Seq Scan -> Index Scan (biayanya tidak lagi tumbuh lurus terhadap jumlah baris)
--
-- MENGAPA INI BEKERJA
-- depot_saya() bersifat STABLE dan tidak menerima argumen dari baris. Planner memanggilnya
-- SEKALI per query, lalu hasilnya - sebuah larik uuid - dipakai sebagai kondisi indeks. Yang
-- tersisa per baris hanyalah uji keanggotaan larik. Tidak ada lagi panggilan fungsi per baris,
-- tidak ada lagi subquery per baris.
--
-- Ini juga sebabnya trik (select fn()) yang biasa disarankan TIDAK cukup di sini: trik itu
-- hanya bekerja bila argumennya tetap. can_access(depot_id) menerima nilai dari baris, jadi ia
-- akan tetap dipanggil per baris betapapun dibungkus.
--
-- DIUKUR PADA KEDUA JALUR PERAN (20 September 2026, lalu dibatalkan)
--
--   Admin, 4 depot        : 67,714 ms -> 2,251 ms  (30x)   14.385 -> 619 halaman
--   System Manager, 52    : 56,354 ms -> 2,139 ms  (26x)    6.123 -> 617 halaman
--
--   Keduanya berubah dari Seq Scan menjadi Index Scan.
--
-- KESETARAAN SUDAH DIBUKTIKAN
-- scripts/loadtest/bukti-setara-rls.sql membandingkan HIMPUNAN id yang terlihat - lewat sidik
-- md5 atas daftar id terurut, bukan sekadar jumlah baris - antara kebijakan lama dan kebijakan
-- di berkas ini, untuk 6 akun x 5 tabel berkebijakan. Hasil terakhir: 30 setara, 0 berbeda.
--
-- Tiga keadaan tepi ikut diuji, dan ketiganya melihat NOL baris sebagaimana seharusnya:
--   pengguna tanpa depot (IQBAL), pengguna nonaktif, pengguna yang wajib ganti PIN.
--
-- Bukti itu MENANGKAP satu cacat pada rancangan awal berkas ini: activity_logs kehilangan 40
-- baris berdepot NULL. Perbaikannya ada pada kebijakan logs_scope di bawah. Itulah sebabnya
-- langkah pembuktian tidak boleh dilewati - selisihnya tidak akan terlihat dari membaca saja.
--
-- YANG MASIH HARUS DIPERIKSA SEBELUM DITERAPKAN
--   1. Ulangi bukti-setara-rls.sql di staging dengan dataset 100x.
--   2. Setelah diterapkan, jalankan sekali lagi di produksi sebagai pemeriksaan akhir.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Daftar depot milik pemanggil, dihitung sekali per query
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.depot_saya() returns uuid[]
language sql stable security definer set search_path='' as $fn$
  select case
    when exists(select 1 from public.profiles p
                 where p.id = (select auth.uid())
                   and p.status = 'active' and not p.must_change_password
                   and p.role = 'system manager')
    then array(select id from public.depots)
    else coalesce(array(
      select a.depot_id from public.user_depot_access a
        join public.profiles p on p.id = a.user_id
       where a.user_id = (select auth.uid())
         and p.status = 'active' and not p.must_change_password), '{}'::uuid[])
  end;
$fn$;
revoke all on function rc_private.depot_saya() from public,anon;
grant execute on function rc_private.depot_saya() to authenticated;

-- Izin pemanggil, juga sekali per query. Inilah yang menghentikan 240 juta seq scan atas
-- user_permissions: daftarnya diambil satu kali, bukan ditanyakan ulang untuk tiap baris.
create or replace function rc_private.izin_saya() returns text[]
language sql stable security definer set search_path='' as $fn$
  select case
    when exists(select 1 from public.profiles p
                 where p.id = (select auth.uid()) and p.status = 'active'
                   and not p.must_change_password and p.role = 'system manager')
    then array(select code from public.permissions)
    else coalesce(array(
      -- Status akun ikut diperiksa di sini, bukan hanya di depot_saya(). Tanpa ini, akun
      -- nonaktif atau yang wajib ganti PIN tetap "memegang" izinnya, dan pada activity_logs -
      -- yang depot_id-nya boleh NULL - ia akan tetap melihat baris lintas depot meski
      -- depot_saya()-nya kosong.
      select x.permission_code from public.user_permissions x
        join public.profiles p on p.id = x.user_id
       where x.user_id = (select auth.uid())
         and p.status = 'active' and not p.must_change_password), '{}'::text[])
  end;
$fn$;
revoke all on function rc_private.izin_saya() from public,anon;
grant execute on function rc_private.izin_saya() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Kebijakan yang menyaring per baris
-- ------------------------------------------------------------------------------------------
alter policy claims_scope on public.claims
  using (archived_at is null and depot_id = any(rc_private.depot_saya()));

alter policy depots_scoped on public.depots
  using (id = any(rc_private.depot_saya()));

alter policy depot_profiles_baca on public.depot_profiles
  using (depot_id = any(rc_private.depot_saya()));

alter policy depot_profile_requests_baca on public.depot_profile_requests
  using (depot_id = any(rc_private.depot_saya()));

-- depot_id BOLEH NULL pada activity_logs - satu-satunya kolom depot_id di seluruh skema yang
-- begitu. Empat puluh baris memuat kejadian lintas depot: access_changed, akun_dihapus,
-- role_changed, campaign_master_upsert dan sejenisnya.
--
-- Tanpa cabang "depot_id is null", baris-baris itu HILANG dari pandangan semua orang, karena
-- NULL = apa pun bernilai NULL, bukan true. Kebijakan lama tidak kehilangan baris itu:
-- can_access(NULL, 'view_logs') melewati cabang depot dan hanya memeriksa izinnya. Bukti
-- kesetaraan menangkap tepat selisih 40 baris ini pada akun System Manager.
alter policy logs_scope on public.activity_logs
  using ((depot_id is null or depot_id = any(rc_private.depot_saya()))
         and 'view_logs' = any(rc_private.izin_saya()));

alter policy claim_sensitive_scoped on rc_private.claim_sensitive
  using (exists(select 1 from public.claims c
                 where c.id = claim_sensitive.claim_id
                   and c.depot_id = any(rc_private.depot_saya())));

-- ------------------------------------------------------------------------------------------
-- 3. Kebijakan tanpa argumen baris: cukup dibungkus (select ...)
-- ------------------------------------------------------------------------------------------
-- can_access(NULL) tidak bergantung pada baris mana pun, jadi membungkusnya membuat planner
-- memperlakukannya sebagai InitPlan - dihitung sekali, bukan sekali per baris campaign.
alter policy campaigns_scope on public.campaigns
  using ((select rc_private.can_access(null::uuid)));

-- ------------------------------------------------------------------------------------------
-- 4. Indeks penopang
-- ------------------------------------------------------------------------------------------
-- Pencarian di tujuh RPC memakai ILIKE '%kata%'. Indeks GIN tsvector yang ada sekarang
-- (customers_name_idx) TIDAK DAPAT melayani pola itu - terbukti dari pg_stat_user_indexes:
-- dipakai 0 kali sejak dibuat, sementara customers tetap ter-seq-scan. Pada 206.800 baris,
-- setiap pencarian akan membaca seluruh tabel.
create extension if not exists pg_trgm with schema extensions;

create index concurrently if not exists customers_nama_trgm_idx
  on public.customers using gin (customer_name extensions.gin_trgm_ops);
create index concurrently if not exists customers_kode_trgm_idx
  on public.customers using gin (customer_code extensions.gin_trgm_ops);
create index concurrently if not exists claims_no_doc_trgm_idx
  on public.claims using gin (no_doc extensions.gin_trgm_ops);
create index concurrently if not exists campaigns_nama_trgm_idx
  on public.campaigns using gin (campaign_name extensions.gin_trgm_ops);

-- Indeks parsial untuk antrean yang selalu disaring status. Pada 275.600 klaim, antrean
-- Not Yet hanya sekitar 30% - indeks parsial membuatnya sepertiga ukuran dan tetap di cache.
create index concurrently if not exists claims_not_yet_idx
  on public.claims (depot_id, campaign_id) where status = 'not_yet' and archived_at is null;
create index concurrently if not exists claims_antrean_idx
  on public.claims (status, depot_id, updated_at desc) where archived_at is null;

-- Indeks tsvector lama dapat dilepas setelah trigram terpasang dan terbukti dipakai.
-- drop index if exists public.customers_name_idx;

-- ------------------------------------------------------------------------------------------
-- 5. Setelah diterapkan
-- ------------------------------------------------------------------------------------------
-- analyze public.claims; analyze public.customers; analyze public.campaigns;
-- select pg_stat_statements_reset();   -- supaya pengukuran berikutnya bersih
