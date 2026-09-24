# Cakupan aktif — Resource Collection di DEV

## Keputusan pemilik

Pada 14 September 2026, pemilik meminta **“doc center dikesampingkan dulu karena masih all prod”**. Tahap aktif sekarang adalah **Resource Collection saja**, pada Supabase DEV `vvojshgcduqlugngpzkj`. Document Center tetap merupakan sistem legacy PROD dan integrasinya ditunda.

Keputusan ini mempersempit tahap aktif dari [instruksi migrasi](../System-Instruction-Migrasi-Claim-System-ke-Supabase.md). Sasaran integrasi kedua aplikasi tetap menjadi pekerjaan lanjutan, bukan syarat untuk memulai pengembangan RC DEV.

## Pekerjaan sekarang

Pembaruan 15 September 2026: atas permintaan melanjutkan push dan menyediakan cara sinkronisasi, penerimaan snapshot RC manual sudah diterapkan ke DEV. Lihat [read.md](../read.md). Alur ini menerima CSV anonim ke staging privat; tidak memasang job atau dual-write pada sistem legacy. Schema final tetap menunggu mapping.

- Sumber RC: `index (4).html` dan `ResourceCollection`.
- Login Supabase Auth, profil pengguna, role/permission dan scope depot RC.
- Master campaign/customer/depot, pemisahan data sensitif, dan query dokumen.
- Posting/submit claim yang sudah tersedia, release, claim, clearing, exception dan bulk rebate.
- Analytics, log, kelola akses dan request perubahan profil RC.
- Schema/RLS/RPC RC dan karakterisasi/test sesuai aturan yang sudah diputuskan.
- Rehearsal dengan data sintetis atau snapshot anonim RC, setelah header/mapping bagian tersebut tersedia.

## Pekerjaan yang ditunda

- Backend `DocumentCenter` dan frontend `index (5).html`.
- Print Document, Compile Cashback, parser Upload_CB dan login Document Center.
- Tabel/RPC `campaign_upload_batches`, `campaign_upload_rows`, preview/commit campaign serta lookup/ekspor Document Center.
- Integrasi satu shell/sesi dengan Document Center dan pemindahan data langsung pengganti job 15 menit.
- Inventaris/cutover trigger dan sumber `Upload`, `DM-30D`, `Depot_ID` untuk alur Document Center.

File dan laporan DC dipertahankan sebagai referensi historis. Penundaan ini tidak mengubah deployment, data, URL atau trigger PROD. Menu DC yang masih ada di frontend legacy bukan target pengujian DEV; saat adapter RC dibuat, akses dari shell DEV ke modul DC PROD perlu dikecualikan dari alur uji.

## Data dan keputusan yang diperlukan untuk RC

Siapkan header lengkap, formula yang relevan dan sampel anonim dari:

1. `Compile`;
2. `Authority` tanpa PIN/token;
3. `ListCampaign`;
4. `ListCust` dengan pengenal pribadi/rekening diganti data sintetis;
5. `DepoMaster`;
6. `LogActivity`;
7. `ReqProfile`;
8. `BatchLog`.

Konfirmasikan sumber RC DEV yang dipakai dan snapshot waktunya. Untuk pengembangan awal, data `Compile` dapat diperlakukan sebagai snapshot masukan yang sudah tersedia; tidak perlu menebak proses pembentukannya dari Document Center. Ini belum menjamin aliran dokumen baru ketika RC kelak dipakai di produksi.

Keputusan RC yang tetap aktif dari audit: D01 Hold/Expired, D02 gross-up/rounding, D09 customer master/snapshot dan alamat/masterLink, D10 analytics, D11 role/status/sesi, serta bagian RC dari D12 locale/tanggal/batch/limit posting. D03–D08 yang khusus Document Center ditunda; ketentuan scope depot RC tetap aktif.

## Batas gerbang berikutnya

**Job 15 menit tidak menghalangi pekerjaan RC DEV.** Infrastruktur dasar, audit RC, dan persiapan implementasi yang tidak bergantung pada mapping DC dapat diteruskan. Schema final untuk data RC, transformasi import dan aturan workflow tetap memerlukan header/sampel serta keputusan RC terkait.

Cutover RC produksi kelak harus menentukan bagaimana dokumen baru masuk ketika Document Center masih PROD. Keputusan alur masuk tersebut diperlukan sebelum cutover, bukan sebelum pengembangan RC DEV. Tidak membuat sync baru, dual-write atau menonaktifkan job existing dalam tahap ini.

Registry aktif: [config/environments.json](../config/environments.json). Bukti audit awal berstatus `BLOCKED_BY_SYNC_INVENTORY` tetap berlaku untuk integrasi penuh RC + DC yang kini ditunda; label itu bukan penghalang global untuk cakupan RC DEV sekarang.
