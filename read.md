> **Pembaruan 22 September 2026:** panduan snapshot di bawah merupakan arsip tahap awal. Auth, workflow, RPC, adapter frontend Supabase, dan hosting Vercel sudah tersedia. Baca [PRD lengkap](docs/PRD-Resource-Collection.md), [audit terbaru](docs/audit/application-2026-09-22.md), dan [README aktif](README.md). Project yang disebut DEV telah dipakai depot; bukan target stress test. Document Center legacy tetap ditunda.

# RC — push Supabase dan sinkronisasi

## Status 15 September 2026

Migration `rc_snapshot_intake` sudah diterapkan pada **DEV** `vvojshgcduqlugngpzkj` melalui MCP. SQL yang sama disimpan di `supabase/migrations/20260915004131_rc_snapshot_intake.sql`.

Tersedia tabel privat `staging.rc_snapshots` dan RPC `public.rc_import_snapshot`. RLS aktif; `anon` dan `authenticated` tidak dapat mengakses snapshot atau menjalankan RPC. Import hanya melalui `service_role` di komputer operator/backend.

Ini adalah penerimaan snapshot RC, belum migrasi aplikasi penuh. Data Spreadsheet belum dikirim karena ekspor sumber belum tersedia. Login dan workflow frontend masih memakai Apps Script. Tabel final, mapping, Auth dan adapter frontend belum diterapkan.

Document Center, `Upload`, `DM-30D`, dan job legacy tidak termasuk. `Authority` sengaja tidak diterima karena memuat PIN; akun akan dibuat melalui Supabase Auth setelah mapping profil ditentukan.

## 1. Siapkan snapshot RC DEV

Ekspor CSV UTF-8 dari sheet RC DEV yang diperlukan: `Compile`, `ListCampaign`, `ListCust`, `DepoMaster`, `LogActivity`, `ReqProfile`, `BatchLog`. Gunakan data anonim/sintetis; hapus token dan samarkan identitas/rekening pada ekspor sebelum import. Simpan file di luar repository.

Baris pertama harus berisi header unik dan tidak kosong. Semua baris harus memiliki jumlah kolom yang sama. Semua sel diterima sebagai teks; verifikasi leading zero kode, rekening dan dokumen pada CSV. Tidak ada konversi tanggal, angka, formula atau status secara otomatis. Formula diekspor sebagai nilai snapshot.

Catat waktu snapshot dengan timezone. Gunakan waktu yang sama saat mengulang pengiriman file yang sama. Maksimum 10.000 baris dan 10 MiB isi baris per snapshot; jika lebih besar, ekspor bagian terpisah dengan nama sumber stabil seperti `rc-dev-anon-part-001`.

## 2. Validasi tanpa mengirim

Dari folder repository, gunakan Python 3.10+:

```powershell
python scripts/sync_rc.py 'D:\DANIEL\Compile.csv' --sheet Compile --source rc-dev-anon --snapshot-at '2026-09-15T08:00:00+07:00'
```

Default adalah dry-run. Periksa jumlah baris dan kolom yang dicetak. File invalid ditolak sebelum request jaringan; perbaiki ekspor lalu ulangi.

## 3. Kirim ke Supabase

```powershell
python scripts/sync_rc.py 'D:\DANIEL\RC Next Gen\data-rc\Compile.csv' --sheet Compile --source rc-dev-anon --snapshot-at '2026-09-15T08:00:00+07:00' --push
```

Skrip meminta **legacy service_role JWT** project DEV melalui input tersembunyi. Ambil dari Dashboard → Project Settings → API Keys → Legacy keys. Jangan memakai anon/publishable key atau menaruh service_role di HTML, Git, chat maupun Document Center. Untuk proses backend, skrip juga membaca environment variable `SUPABASE_SERVICE_ROLE_KEY` yang disediakan secret manager.

Ulangi untuk setiap sheet dengan `--sheet` yang sesuai. Respons berisi `id`, `row_count`, dan `replayed`. Pengiriman identik dengan kombinasi sumber + sheet + waktu yang sama mengembalikan `replayed: true`, tanpa menggandakan snapshot. Isi berbeda pada identitas snapshot yang sama ditolak. Untuk ekspor baru gunakan waktu snapshot baru.

Setiap request masuk secara atomik: seluruh snapshot berhasil atau dibatalkan. Timeout dapat terjadi sesudah server berhasil; ulangi dengan timestamp yang sama. Sinkronisasi lintas beberapa sheet belum satu transaksi: ekspor dari snapshot sumber yang konsisten dan bandingkan seluruh sheet sebelum transformasi.

## 4. Verifikasi di SQL Editor DEV

```sql
select id, source_name, sheet_name, snapshot_at, row_count, imported_at
from staging.rc_snapshots
order by imported_at desc;
```

Cocokkan `row_count` dengan jumlah record CSV tanpa header. Snapshot lama tetap tersimpan; tidak ada penghapusan, merge berdasarkan No Document, perubahan status atau penimpaan tabel workflow. Total nilai dan relasi bisnis baru dapat direkonsiliasi setelah mapping header disetujui.

## 5. Arti sinkronisasi saat ini

Alur tersedia: **ekspor RC DEV → validasi CSV → RPC → staging privat**. Jalankan manual setelah ekspor baru; belum ada jadwal otomatis, akses langsung Google Sheets, atau sinkronisasi dua arah. Jangan memasang trigger 15 menit pada Document Center untuk alur ini.

Tahap berikutnya membutuhkan header/formula dan sampel anonim untuk menyusun transformasi ke tabel RC final, validasi/reject, aturan status/pajak, scope depot dan akun Auth. Setelah itu baru adapter RC diarahkan ke Supabase dan workflow diuji. Detail kebutuhan: [scope](docs/scope.md).

## Migration berikutnya

Migration di atas sudah berada di remote; jangan menjalankan ulang SQL CREATE secara manual. Lihat riwayat di Dashboard atau MCP `list_migrations`. Untuk perubahan berikutnya buat file SQL baru, inspeksi target DEV, terapkan lewat MCP `apply_migration`, lalu catat versi remote dan hasil uji. Jika beralih ke CLI, cocokkan versi riwayat lokal dengan remote lebih dahulu sebelum `db push`.

Referensi: [hak akses fungsi](https://supabase.com/docs/guides/database/functions), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security), [migration](https://supabase.com/docs/guides/deployment/database-migrations).

