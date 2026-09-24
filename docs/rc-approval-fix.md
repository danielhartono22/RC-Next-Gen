> Catatan 24 September: aturan submit dalam dokumen historis ini sudah digantikan oleh [workflow terbaru](rc-release-2026-09-24.md): Not Yet -> Submitted -> Approved. Aturan Expired langsung dari Claim Process tetap berlaku.

# Perbaikan status Management of Approval — 22 September 2026

Migration: `supabase/migrations/20261150010000_pending_approval_status.sql`.
Sudah diterapkan ke Supabase `vvojshgcduqlugngpzkj`. Frontend hasil build tersedia di
`http://localhost:5173`. Perubahan frontend ini belum dipublikasikan ulang ke Vercel.

## Perilaku

| Tindakan | Sebelum keputusan | Setelah disetujui |
| --- | --- | --- |
| Upload biasa, WPT/Overdue | Not Yet; pengajuan tersimpan terpisah | Approved |
| Upload RA07/RA7 | Not Yet; menunggu approval | Done |
| On Hold melalui Upload | Status efektif tetap; tanggal perpanjangan belum berlaku | On Hold, tanggal perpanjangan berlaku |
| Expired melalui Upload | Status efektif tetap; belum mendapat batch Clearing | Expired, batch Clearing diterbitkan |
| Expired melalui Claim Process, tahap Claim/Clearing | Langsung Expired | Tidak memerlukan approval dan tidak masuk antrean approval |

Blank/null pada penyajian status disamakan dengan Not Yet. Untuk pengajuan dari dokumen
yang sudah berada pada tahap lain, status efektif sebelumnya dipertahankan. Reject
menghapus pengajuan, tanpa menerapkan status yang ditolak. Antrean On Hold/Expired
menampilkan **Status Pengajuan**, terpisah dari status efektif dokumen.

Status menunggu keputusan disimpan pada `claims.pending_approval`, bukan menggunakan
status akhir dokumen. Pengajuan yang masih menunggu tidak dapat ditimpa melalui submit
ulang, Release, Bulk Process, atau reprocessing. Expired langsung memakai aksi
`expire_claim_process`: izin `process_claim`, scope depot, dan status Released/Claimed
divalidasi di server. Teks alasan tidak menentukan hak bypass approval.

Versi dokumen diperbarui dari hasil lookup approval. Mutasi mengunci baris, memeriksa versi,
dan menggunakan request ID untuk mencegah pengulangan mutasi workflow saat retry.
Frontend memakai status dari respons server; dokumen yang gagal pada Posting Exception
tidak ikut ditandai berhasil.

## Koreksi data lama

Riwayat mengidentifikasi **29 pengajuan** yang terkena perilaku lama: 2 Submit,
10 On Hold, dan 17 Expired dari Upload. Semuanya berasal dari Not Yet dan dikembalikan
ke Not Yet sambil mempertahankan pengajuannya untuk diputuskan.

Koreksi hanya menyasar dokumen belum diarsipkan dengan audit asal yang cocok.
Dokumen yang sudah disetujui atau Expired melalui Claim Process tidak dipulihkan secara
massal. Riwayat asli tetap ada; koreksi menambahkan event `repair_pending_approval`.
Snapshot field yang dikoreksi tersimpan privat di
`rc_private.approval_status_repair_20261150`. Migration aman dijalankan ulang.

## Verifikasi

- **41 skenario integrasi database lulus** sebelum penerapan versi akhir dan setelahnya.
  Data uji, akun, customer, campaign, dan depot dibuat sintetis dalam transaksi lalu
  di-rollback. Pengujian menggunakan role PostgreSQL `authenticated` dan klaim identitas
  akun dummy; ini bukan tes login melalui browser ataupun uji beban/concurrency nyata.
- **7 tes alur frontend/adapter lulus**, termasuk handler submit dan keberhasilan parsial.
- Tes regresi adapter/client/dashboard: **24 lulus**. Tes server lokal: **12 lulus**.
  Tes server sempat diblokir sandbox Windows (`spawn EPERM`), lalu lulus ketika diulang
  dengan izin menjalankan subprocess lokal.
- `npm run check` dan `node scripts/check-system.mjs --db` lulus.
- Halaman localhost dan aset adapter menjawab HTTP 200 dengan kode baru.
- Layout/CSS dipertahankan; teks konfirmasi dan label status pengajuan disesuaikan.

Jalankan `node scripts/test_pending_approval.mjs --candidate` untuk menguji migration
di dalam transaksi rollback, atau `npm run test:approval:db` untuk backend terpasang.
Hasil lengkap tersedia di `.runtime/approval-fix/test-applied.json`.

Definisi fungsi sebelum perubahan dan rollback terjaga tersimpan di
`.runtime/approval-fix/rollback.sql`. Rollback ini menolak berjalan jika dokumen sudah
berubah atau ada pengajuan baru setelah migration; kondisi tersebut memerlukan
rekonsiliasi dahulu agar keputusan baru tidak hilang.
