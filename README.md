# Resource Collection Next Gen

Aplikasi pengelolaan klaim dengan Supabase Auth/PostgreSQL/Edge Functions dan frontend statis di Vercel. Source aktif berada di `src/`; `ResourceCollection`, `DocumentCenter`, dan `index (4)/(5).html` dipertahankan sebagai referensi legacy.

**Status 24 September 2026:** backend workflow, izin tab, profil depot dan People Performance sudah diterapkan di Supabase. Frontend terbaru berjalan pada localhost dan belum dideploy ulang ke Vercel. Lihat [spesifikasi dan hasil verifikasi 23-24 September](docs/rc-release-2026-09-24.md).

## Dokumen utama

- [Upload user dan approval](docs/rc-user-upload-approval.md): template tujuh kolom, area menggunakan kode depot, seluruh upload menunggu approval.

- [PRD lengkap](docs/PRD-Resource-Collection.md): tujuan, cakupan, role, workflow, persyaratan per modul, acceptance criteria, arsitektur, kapasitas, dan roadmap.
- [Bukti verifikasi 24 September](docs/audit/verification-2026-09-24.json): 71 regression test, 105 assertion database, dan 20 smoke check fungsi.
- [Audit aplikasi 22 September](docs/audit/application-2026-09-22.md): perbaikan Registrasi, 36 aturan data, bukti pengujian dan pekerjaan terbuka.
- [Aturan Management of Approval](docs/rc-approval-fix.md): status sebelum approval dan Expired langsung dari Claim Process.
- [Pengembangan lokal](docs/rc-local-development.md), [rute](docs/rc-rute.md), [deployment Vercel](docs/rc-vercel-deployment.md).
- [Rencana load test](docs/load-test-plan.md): staging, dummy dataset, concurrency dan pengukuran.
- [Instruksi migrasi](System-Instruction-Migrasi-Claim-System-ke-Supabase.md) dan [cakupan Document Center](docs/scope.md).

## Menjalankan dan memeriksa

```powershell
npm run dev
npm run build
npm run check
npm test
```

Dev server menggunakan port 5173. Jangan menjalankan server kedua bila localhost sudah aktif. Build menghasilkan `public/`; sunting source, bukan file hasil build.

Pemeriksaan Supabase yang membutuhkan token lokal:

```powershell
npm run test:access:db
node scripts/test_rc_2309.mjs --applied
npm run audit:application
```

Dua suite SQL memakai fixture dummy yang di-rollback. `node scripts/test_registration_http.mjs` adalah smoke test terbatas: membuat akun/depot dummy sementara, melakukan login/create/retry/ganti PIN, lalu membersihkannya. Ini bukan load test.

## Environment dan deployment

Project `vvojshgcduqlugngpzkj` berlabel DEV pada dokumen lama tetapi telah digunakan depot. Localhost menunjuk project tersebut; tidak otomatis menjadi staging terisolasi. Belum ada klaim lulus 1.000 concurrent users atau 1.000.000 rows.

Simpan token di `.env` yang diabaikan Git. Jangan memasukkan service key/PAT/PIN ke frontend atau dokumentasi. Konfigurasi publik hanya memuat URL dan publishable/anon key.

`npm run deploy` menerbitkan frontend ke **production Vercel**, sesuai scope pada package.json; perintah itu bukan preview. Perbaikan backend tidak otomatis memperbarui frontend Vercel.

**Migration ledger perlu rekonsiliasi.** Banyak DDL baru diterapkan melalui SQL API, sedangkan ledger remote terakhir masih September 15. Jangan menjalankan `supabase db push` atau bundle seluruh migration tanpa membandingkan schema yang sudah berjalan.

Riwayat panduan awal tersedia pada [arsip README](docs/archive/README-2026-09-15.md) dan [panduan snapshot historis](read.md). Pernyataan bahwa tabel/Auth/backend belum ada di dokumen lama tidak berlaku untuk kondisi sekarang.
