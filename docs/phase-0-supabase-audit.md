# Fase 0 — Verifikasi MCP dan inventaris Supabase PROD

> **Penetapan terbaru:** pemilik kini menetapkan project ini sebagai **DEV**. Judul, hasil dan label PROD di bawah merupakan catatan historis pemeriksaan awal. Gunakan [lingkungan proyek](environments.md) untuk memilih target aktif.

> Catatan waktu: laporan ini mempertahankan observasi pada pemeriksaan MCP awal. Kedua backend kemudian sudah tersimpan dan diaudit; lihat [audit backend terbaru](phase-0-backend-audit.md). Pernyataan backend kosong di bagian akhir berlaku pada waktu snapshot ini, bukan keadaan workspace terkini.

Waktu pencatatan: 14 September 2026, 09:29:52 UTC / 16:29:52 UTC+7. Project: `vvojshgcduqlugngpzkj`. Lingkungan: **PROD**, dikonfirmasi pemilik dalam percakapan. Dokumen induk: [audit Fase 0](phase-0-audit.md). Bukti metadata: [snapshot JSON](phase-0-supabase-evidence.json).

## Hasil koneksi

**PASS — MCP terhubung dan dapat membaca metadata project yang dimaksud.** `get_project_url` mengembalikan `https://vvojshgcduqlugngpzkj.supabase.co`. Inventaris tabel, migration, Edge Function, advisor dan SELECT katalog PostgreSQL semuanya berhasil.

PASS ini hanya membuktikan koneksi agent ke Supabase. Login pengguna aplikasi, Data API dari browser, RLS role/depot, workflow, migrasi data dan restore belum diuji. Kedua frontend tetap memakai Apps Script menurut baseline sumber yang hash-nya tidak berubah.

Konfigurasi MCP aktif tidak memakai `read_only=true`. Tool tulis tersedia, tetapi audit ini hanya menjalankan pembacaan. Tidak ada kredensial publishable/anon/secret, akun Auth, atau baris data bisnis yang diambil. Tidak ada perubahan produksi yang diterapkan.

## Inventaris yang teramati

| Pemeriksaan | Hasil | Batas kesimpulan |
|---|---|---|
| Tabel `public` | 0 | Tidak sama dengan seluruh database kosong |
| Relasi di luar daftar schema platform yang dikecualikan | 0 | Query mencakup tabel, partitioned table, view, materialized view dan foreign table; lihat batas query di bawah |
| Migration dari MCP | 0 | Tidak membuktikan tak pernah ada SQL manual atau provisioning platform |
| Edge Function dari MCP | 0 | Belum ada backend aplikasi di Edge Functions yang terdaftar |
| Fungsi di `public` | 1: `rls_auto_enable()` | Return type `event_trigger`, bukan RPC bisnis yang dirancang pada instruksi |
| Schema `staging` | Tidak ditemukan pada query nama schema | Rehearsal import belum disiapkan |
| Event trigger | 7, seluruhnya `evtenabled = O` | Trigger PostgreSQL ini berbeda dari job Apps Script 15 menit |
| PostgreSQL | 17.6 | Nilai server aktual; pembaruan versi bukan lingkup audit ini |
| Timezone database | UTC | Timezone bisnis untuk nomor batch dan tanggal masih perlu dikonfirmasi |
| `pg_database_size` | 10.431.635 byte, sekitar 9,95 MiB | Ukuran database saat pemeriksaan, bukan storage billing, egress atau proyeksi setelah import |
| Security Advisor | 2 jenis WARN pada 1 fungsi | Rincian di bawah |
| Performance Advisor | Daftar lint kosong | Belum ada workload bisnis untuk menilai indeks/latency |

Pemanggilan MCP dilakukan terpisah, sehingga bukti ini adalah catatan observasi, bukan backup atau snapshot transaksi yang konsisten. Nilai `observed_at` advisor berasal dari layanan dan tidak membuktikan pemindaian baru yang menyeluruh.

## Temuan keamanan dan kesiapan

### SB01 — Hak execute pada helper SECURITY DEFINER

Advisor mengembalikan `anon_security_definer_function_executable` dan `authenticated_security_definer_function_executable`, keduanya tingkat **WARN** dan merujuk `public.rls_auto_enable()`.

Metadata katalog mengonfirmasi:

- Function owner `postgres`; `SECURITY DEFINER = true`.
- Return type `event_trigger`; `search_path=pg_catalog`.
- Hak EXECUTE efektif diberikan kepada `anon` dan `authenticated`; ACL eksplisit juga memiliki EXECUTE untuk PUBLIC.
- Event trigger `ensure_rls` memanggilnya setelah `CREATE TABLE`, `CREATE TABLE AS`, dan `SELECT INTO`.
- Definisi fungsi berusaha mengaktifkan RLS pada tabel `public`; error ditangkap lalu dicatat sebagai log. Keberadaan helper bukan pengganti pemeriksaan RLS tabel hasil migration.

**Interpretasi audit:** izin execute memang luas, tetapi teks advisor yang menyebut jalur `/rest/v1/rpc/rls_auto_enable` belum menjadi bukti fungsi berhasil dipanggil melalui HTTP atau bahwa data bocor. Fungsi bertipe `event_trigger` memiliki konteks eksekusi khusus; lihat [dokumentasi event trigger PostgreSQL](https://www.postgresql.org/docs/17/plpgsql-trigger.html#PLPGSQL-EVENT-TRIGGER). Audit ini tidak memanggil fungsi atau mencoba request RPC di PROD.

Tindak lanjut pada DEV: verifikasi kebutuhan ACL helper, rancang pembatasan execute yang tetap mempertahankan `ensure_rls`, lalu uji perilaku DDL dan advisor. Setiap perbaikan kelak dicatat sebagai migration dengan validasi/rollback sebelum penerapan PROD. Tidak menonaktifkan atau menghapus `ensure_rls` hanya untuk menghilangkan lint. Asal provisioning fungsi belum diverifikasi.

### SB02 — Default grant luas untuk objek baru

`pg_default_acl` menunjukkan pembuat objek `postgres` dan `supabase_admin` memiliki default privileges di schema `public` yang memberi `anon` dan `authenticated` hak luas untuk tabel, sequence dan fungsi. Metadata schema mengonfirmasi kedua role mempunyai USAGE tetapi tidak CREATE pada `public`.

Ini adalah fakta konfigurasi, bukan bukti data bisnis saat ini terbuka: belum ada tabel bisnis yang ditemukan. Sebelum schema aplikasi dibuat, migration harus mengatur default privileges bagi role pembuat objek yang benar, grant per objek, dan RLS sesuai instruksi bagian 8. RLS dan grants harus diuji bersama; [dokumentasi Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security) menjelaskan pembatasan baris untuk akses API. Hak fungsi perlu diperiksa terpisah.

### SB03 — PROD tersedia, DEV belum ditentukan

Pemilik telah mengonfirmasi project ini sebagai PROD. Belum ada project DEV atau local Supabase yang terverifikasi. Implementasi schema/RLS dan uji concurrency memerlukan lingkungan terpisah sesuai Fase 1. Project PROD tidak otomatis dianggap lingkungan pengujian hanya karena tabel `public` belum ada.

## Cakupan SELECT yang dijalankan

Seluruh statement audit adalah SELECT katalog/metadata. Nama query berikut memetakan bukti JSON; perintah DDL yang tampak di `function_definition` adalah teks definisi yang dibaca, bukan SQL yang dijalankan.

| Bukti JSON | Sumber metadata |
|---|---|
| `database_metadata` | `current_database()`, `pg_database_size`, `current_setting('server_version')`, `current_setting('TimeZone')` |
| `non_platform_relations` | `pg_class` JOIN `pg_namespace`; filter relkind dan pengecualian schema berikut |
| `public_functions` | `pg_proc` JOIN `pg_namespace`; `pg_get_function_result`, `pg_get_functiondef`, ACL dan `has_function_privilege` untuk fungsi/prosedur public |
| `event_triggers` | `pg_event_trigger`, nama event, enable state, tags dan referensi fungsi |
| `default_privileges` | `pg_default_acl`, scope global atau public, owner, object type dan ACL |
| `schema_privileges` | `pg_namespace` untuk public/staging dan `has_schema_privilege` |

Filter relasi yang digunakan:

```sql
SELECT n.nspname AS schema_name, c.relname AS relation_name,
       c.relkind AS relation_kind, c.relrowsecurity AS rls_enabled,
       c.relforcerowsecurity AS rls_forced
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p','v','m','f')
  AND n.nspname NOT IN (
    'pg_catalog','information_schema','auth','storage','realtime',
    'extensions','graphql','graphql_public','supabase_functions',
    'supabase_migrations','vault','pgbouncer','net','cron',
    '_realtime','_analytics'
  )
  AND n.nspname NOT LIKE 'pg_toast%'
  AND n.nspname NOT LIKE 'pg_temp_%'
ORDER BY n.nspname,c.relname;
```

Tidak dilakukan inventaris data di schema platform yang dikecualikan. Query awal berisi SELECT schema dan SELECT default privileges dalam satu pemanggilan, tetapi MCP hanya mengembalikan hasil terakhir; schema privileges kemudian diperiksa lewat SELECT terpisah. Tidak ada hasil yang diasumsikan dari response yang tidak tersedia.

## Kelanjutan audit dan batas fase

Hash SHA-256 kedua frontend dan instruksi sama dengan audit awal. `ResourceCollection` dan `DocumentCenter` tetap berukuran 0 byte. Hasil 10 karakterisasi frontend di laporan awal tidak dijalankan ulang pada kelanjutan ini. Tidak ada test integrasi aplikasi, RLS, benchmark, rekonsiliasi, atau restore yang dinyatakan PASS.

Validasi artefak lokal berhasil: JSON bukti dapat diparse, hash kelima file sumber cocok setelah penulisan laporan, dan sembilan tautan lokal pada ketiga dokumen audit/bahan mengarah ke file yang tersedia. Perubahan lokal hanya pada empat file dokumentasi/bukti di `docs`.

Fase 0 masih membutuhkan kedua backend Apps Script, kode/metadata job 15 menit, header/formula/data anonim, serta keputusan D01–D12 pada dokumen induk. Rincian bahan dan format pengumpulannya ada di [daftar bahan](phase-0-source-intake.md).

Instruksi bagian 12 menyatakan: “Jika kode atau akses trigger 15-menit belum tersedia, hentikan desain mapping upload pada status `BLOCKED_BY_SYNC_INVENTORY`.” Karena sumber tersebut belum ada, audit koneksi selesai tetapi mapping upload dan gerbang Fase 1 belum selesai. Tidak ada schema, migration, adapter frontend, atau perubahan produksi yang dibuat pada fase ini.

**Status: BLOCKED_BY_SYNC_INVENTORY.**
