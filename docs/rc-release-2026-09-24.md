# RC Next Gen — perubahan 23–24 September 2026

Spesifikasi ini melengkapi [PRD utama](PRD-Resource-Collection.md). Keputusan 23–24 September menggantikan aturan 22 September yang mempertahankan Not Yet setelah submit.

## Workflow dan tampilan

| Jenis | Alur |
|---|---|
| Transfer / CN | Not Yet → Submitted → Approved → Released → Claimed → Done |
| Rebate | Not Yet → Submitted → Approved → Bulk Process → Done |
| Rebate Manual, termasuk alias RA07/RA7 | Not Yet → Submitted → Approved → Done |

Blank ditampilkan sebagai Not Yet. Reject pengajuan mengembalikan Not Yet. Permohonan Hold/Expired dari Upload mempertahankan kondisi efektif sampai approval; posting Expired pada Claim Process tetap langsung efektif dan tidak masuk Management of Approval.

Approved berwarna merah jambu. Bulk Process dan penyelesaian Rebate Manual mencatat masing-masing tahap di history meskipun diselesaikan dalam satu transaksi. Compile selalu membuat Not Yet, termasuk Rebate Manual. Jenis CB pilihan pengguna disimpan pada klaim sehingga tidak hilang ketika berpindah modul.

Label Pending Depot/OSC/Finance digunakan pada laporan pengelompokan, bukan mengganti status dokumen di Analytics:

- Pending Depot: Not Yet dan Submitted.
- Pending OSC: Approved dan Released.
- Pending Finance: Claimed.
- Report mempertahankan perlakuan sebelumnya untuk On Hold pada Pending Depot dan Expired pada kelompok selesai.

Tanggal tampilan memakai dd-Mmm-yyyy, contoh 22-Jan-2026. Timestamp menyertakan jam, menit, detik dalam Asia/Jakarta (UTC+7). Input kalender tetap memakai nilai ISO. Total CB/Gross Up pada rincian, tabel detail, dan ekspor nominal membuang pecahan, bukan membulatkan naik: 100,99 → 100. Kartu ringkasan Report/dashboard publik, Release, Claim Process, dan Bulk Process memakai satuan juta (jt), misalnya Rp 10.923,4 jt, dengan maksimal dua desimal satuan juta. Nilai sangat kecil tetap ditampilkan cukup presisi agar tidak menjadi nol. Nominal penuh tersedia pada Details dan tooltip kartu. Nilai tersimpan dan perhitungan pajak tidak diubah; persentase tetap boleh desimal.

## Persyaratan per modul

| Modul | Perilaku yang ditambahkan |
|---|---|
| Claim Upload | Maksimal 500 toko/baris; file atau paste berlebih ditolak, tidak dipotong diam-diam. Open memiliki filter Jenis CB di server sebelum pagination. |
| Release | Kolom dan filter Jenis CB; remark pada rincian; label Process by. |
| Claim Process | Gross Up Value pada baris, filter Jenis CB, filter tahun awal SO campaign. |
| Analytics — Cashback List | Customer/campaign code dan name dibungkus; chronology Submitted, Approved, Released, Claimed, Bulk, Done dengan timestamp; satu kartu batch; kartu SO/Billing start-end; remark Reprocessing/CB Type Changed; Process by. |
| Customer Master | Depot code di depan, nama depot dan region hasil lookup dari penugasan yang berada dalam yurisdiksi pengguna. |
| Document Center | Maksimal 2.000 baris per compile; replay request tidak membuat dokumen kedua. |
| Access Management | Satu katalog server dengan 37 izin tab/operasi, checkbox seluruh tab, pilih semua per modul, penyimpanan dan read-back server. |
| Registrasi | Template XLSX tujuh kolom, preview, validasi area depot, dan semua upload masuk Approval Request. Suffix dibuat saat approval. Lihat [alur upload user](rc-user-upload-approval.md). PIN tidak ditampilkan dalam preview atau log. |
| Profil Depot | Data terbaru dari server; semua field profil bisnis dapat diajukan, termasuk grade dan alamat email. Nilai efektif berubah setelah reviewer lain menyetujui. Total karyawan dihitung. Identitas kode depot dan mapping pengawas/akun tetap dikelola sebagai relasi. |
| Log Activity | Timestamp, modul, tab, stage, dan batch; data lama tanpa konteks diberi penanda legacy/tidak tercatat. |
| Master Depot | Kartu modul lama di beranda dihapus. Depot Master dalam Key Master tetap menjadi sumber lookup. |

## People Performance

Dua tab: **OSC** dan **Supervisor**. Tab OSC menampilkan supervisor terkait dan depot yang ditangani; tab Supervisor menampilkan OSC binaan beserta jumlah depot. Data selalu merupakan irisan penugasan user dengan yurisdiksi pembaca. Ringkasan memakai depot unik agar satu depot tidak dihitung dua kali.

Diagram mengikuti Chart.js dan pola kartu Report: batang bertumpuk untuk claim, doughnut untuk status timetable, serta garis pada popup history. Tabel menjadi pendamping angka pada diagram.

Popup Details / History memuat depot, jumlah dan persentase claim, status asli claim, timetable Not Yet / Compiled / Completed / Not Achieved, aktivitas per periode, dan histori harian/mingguan/bulanan dengan tanggal awal/akhir custom. Rentang maksimal 366 hari.

~~~mermaid
flowchart TD
  S[Supervisor] --> O1[OSC A]
  S --> O2[OSC B]
  O1 --> D1[Depot 1]
  O1 --> D2[Depot 2]
  O2 --> D3[Depot 3]
  D1 --> T[Timetable dan claim]
  D2 --> T
  D3 --> T
  T --> H[Popup history: hari / minggu / bulan / custom]
~~~

Histori menggunakan claim_status_history sampai akhir hari bisnis. Status historis yang belum tercatat ditandai **Unknown**, tidak diasumsikan Not Yet. Mapping depot, campaign, dan status arsip mengikuti master saat ini; laporan ini belum merupakan snapshot historis organisasi.

## Otorisasi dan integritas

Permission modul, role intrinsik, izin tab, dan yurisdiksi diperiksa bersama. Pembatasan tab diterapkan pada navigasi dan RPC operasi, termasuk jalur alternatif untuk profil, memo campaign, pemulihan akun, dan penandaan timetable. System Manager mempertahankan akses penuh; aturan approval khusus role tetap berlaku. Akses yang dikirim browser tidak dipercaya sebagai identitas.

Supervisor tidak lagi mendapat seluruh matrix depot hanya karena berstatus manager. Top 10 depot belum compile merupakan pengecualian agregat publik; detail dokumen dan identitas tetap mengikuti scope.

Idempotency request dan version check tetap berlaku. UI memakai status hasil server dan tidak mengubah status secara optimistis pada baris yang gagal.

## Verifikasi dan kondisi deployment

- Supabase: delapan migration seri 20261152 serta migration upload user 20261153010000 telah diterapkan; satu pengajuan lama diselaraskan dari Not Yet ke Submitted.
- Jumlah data sebelum/sesudah penerapan utama: 2.756 klaim, 2.067 customer, 7 profil. Semua profil memiliki suffix.
- 75 regression test Node lulus, termasuk escaping Analytics, nominal integer, tanggal di batas pergantian hari, pemetaan tab dan adapter.
- 71 assertion SQL fitur/workflow dan 34 assertion Access/Registrasi lulus memakai fixture dummy dalam transaksi rollback.
- Uji batas menggunakan 500 klaim berbeda dan 2.000 hubungan customer/campaign berbeda. Batas 501 dan 2.001 ditolak.
- 20 smoke check fungsi utama pada level SQL dengan konteks authenticated berhasil; build, JavaScript parser, RPC mapping, struktur dan pemeriksaan modal lulus.
- Localhost: http://localhost:5173. Frontend perubahan ini belum dipublikasikan ulang ke Vercel.
- Sesi tool tidak menyediakan browser; belum ada bukti screenshot atau pengujian klik pada browser nyata. Pengujian UI menggunakan render harness dan pemeriksaan struktur.
- Ini bukan hasil load/stress test 1.000 concurrent users. Staging khusus tetap belum tersedia.

Bukti terstruktur: [verification-2026-09-24.json](audit/verification-2026-09-24.json). Rute portal termasuk /people-performance diuji melalui request HTTP langsung dan mendukung refresh. Belum ada OSC aktif pada data saat verifikasi; tab OSC dapat kosong sampai akun serta penugasannya diaktifkan. Alur OSC sudah lulus menggunakan fixture dummy.

Reproduksi: npm run check, npm test, node scripts/test_rc_2309.mjs --applied, npm run test:access:db, node scripts/smoke_rc_2309.mjs. Semua credential tetap dibaca dari environment lokal, tidak disimpan dalam dokumen.
