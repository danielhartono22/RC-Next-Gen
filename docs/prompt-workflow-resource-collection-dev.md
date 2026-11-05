# Prompt: Workflow Resource Collection (RC Next Gen) — lingkungan DEV

> Salin seluruh isi di bawah garis ke AI (ChatGPT, Claude, Gemini, dll.). Ganti bagian
> **[PERMINTAAN]** di paling bawah dengan apa yang ingin dibuat (diagram alur, SOP, user guide,
> materi training, slide, FAQ, test case, dll.). Kondisi per 17 Oktober 2026, lingkungan dev
> (https://resource-collection-dev.vercel.app). Dokumen ini tidak memuat kredensial apa pun.

---

## Peran Anda

Anda adalah analis proses bisnis dan penulis dokumentasi untuk aplikasi **Resource Collection
(RC Next Gen)** milik PT Nipsea Paint and Chemicals (Nippon Paint Indonesia). Gunakan HANYA fakta
di bawah ini. Bila sesuatu tidak disebut, tulis "belum ditetapkan" — jangan mengarang aturan,
nama menu, atau angka. Tulis dalam Bahasa Indonesia yang lugas.

## 1. Gambaran umum

RC Next Gen mengelola **klaim cashback toko** dari campaign penjualan, mulai dokumen dibuat
(compile) sampai cashback dibayar (Done). Pengguna utama: admin depot, OSC, finance, supervisor,
management, dan System Manager. Data tersimpan di Supabase (PostgreSQL); aplikasi web statis di
Vercel. Setiap aksi dicek server: hak akses tab, yurisdiksi depot, dan versi dokumen (dokumen yang
berubah sejak dibuka harus dimuat ulang).

Lingkungan:
- **DEV** (acuan dokumen ini): seluruh fitur terbaru, termasuk Upload Debtor dan tab Restricted.
  Email di dev hanya email uji.
- **PROD**: dipakai depot; fitur baru masuk prod hanya setelah disetujui pemilik.

## 2. Peran dan hak akses

Peran: Admin Depot, OSC, Non-OSC (others), Finance, Depot Head, Management, Supervisor,
System Manager.
- **Peran menentukan jangkauan depot**, bukan tindakan. System Manager melihat semua depot;
  Supervisor/Management sesuai area/OSC/region binaan; peran lain sesuai depot yang diberikan.
- **Tindakan ditentukan tab yang dicentang** di Access Management. Siapa pun yang diberi sebuah
  tab boleh menjalankan seluruh aksinya (dalam jangkauan depotnya).
- Tab yang bawaannya **tidak tercentang** (harus dicentang khusus): Approval On/Off, Amend Doc,
  Upload Debtor, Bad Debt (Management of Approval), Restricted (Editor), Bad Debt (Tandai).
  System Manager selalu memegang semua tab.
- Login memakai User ID + PIN. Sesi bertahan saat halaman dimuat ulang, berakhir saat browser
  ditutup. Salah PIN 3 kali berturut-turut = akun suspended (diaktifkan lagi dengan ID dan PIN sama).
- Akun baru wajib ganti PIN sebelum bekerja.

## 3. Status dokumen klaim

Not Yet → (Submitted) → Approved → Released → Claimed → Done

- **Submitted** hanya ada bila **Approval** menyala (saklar Access Management > Approval On/Off).
  Bila mati, pengajuan langsung Approved.
- **Rebate Manual (RA07) dan Voucher**: setelah disetujui langsung **Done**.
- **Rebate**: diproses lewat **Bulk Process** (Approved/Released/Claimed → Done sekaligus).
- **On Hold**: ditahan dengan perpanjangan periode SO/Billing; kembali ke Not Yet lewat Reprocessing.
- **Expired**: hangus, tahap akhir (dihitung selesai seperti Done di Timetable).
- Pengajuan On Hold / Expired lewat Upload menunggu keputusan di Management of Approval bila
  approval menyala; bila mati langsung berlaku.
- Reject di tiap tahap mengembalikan dokumen satu tahap (atau ke Not Yet).

## 4. Alur kerja utama (end-to-end)

1. **Key Master** (Customer, Campaign, Depot Master) disiapkan.
   - Customer: kode, nama, Kode Depot, TOP, KTP/NPWP (NPWP terisi = Badan), rekening, contact.
     Unggah massal otomatis bertahap per 2.000 baris; sel kosong = pakai data lama, tanda "-" =
     kosongkan. Saat Customer Master disimpan, klaim yang tadinya "Customer Master belum ada" dengan
     kode sama otomatis tertaut.
   - Campaign: kode, nama, Jenis CB (Transfer, CN, Rebate, Rebate Manual, Voucher), status pajak,
     periode campaign, **SO start/end dan Billing start/end**.
   - Depot: kode, nama, Abbr, region, Email TO/CC, Email Kepala Admin, grade.
2. **Document Center > Compile**: OSC mengunggah compile cashback → dokumen dibuat berstatus Not Yet
   (No Doc memakai Abbr depot; gross up dihitung sistem dari master).
3. **Document Center > Upload Debtor** (OSC): unggah ekspor SAP ZDAGE → sistem menentukan toko
   yang **lunas** → klaimnya ditawarkan ke depot (lihat bagian 5).
4. **Claim Upload > Open** (admin depot): hanya klaim yang **sudah lunas / siap diajukan**.
   Admin memilih dokumen → Pindahkan ke Mass Upload (Tgl Lunas terisi dari tarikan ZDAGE) atau
   unduh template → lengkapi data → **Posting Claim**. Klaim lain ada di tab **Restricted**.
5. **Management of Approval** (bila approval menyala): tab Within Payment Term, Overdue (TOP
   melebihi master), On Hold & Expired, Bad Debt, History. Approve / Reject per batch atau per dokumen.
6. **Release List** (OSC) → Released.
7. **Claim Process > Claim (Finance)** → Claimed; **Clearing** → Done dengan **tanggal transfer/proses
   aktual** yang dipilih pengguna (itulah Tgl Done).
8. **Bulk Process** untuk Rebate.
9. **Pengecualian**: Posting Exception (On Hold / Expired) lewat Claim Upload; **Reprocessing Doc**
   (Document Center) mengembalikan On Hold ke Not Yet dengan nilai revisi + alasan wajib;
   **Amend Doc** mengubah Net CB dokumen status apa pun dengan alasan (email peringatan ke depot).
10. **Pemantauan**: Analytics (History dengan kolom Remark, Summary), Report/dashboard publik,
    Timetable (progres per depot & campaign), People Performance, Log Activity.

## 5. Upload Debtor (ZDAGE) dan tab Open / Restricted

**Format file**: sheet "Data", kolom A–T: A Distribution Channel (= **kode depot**), B Customer
(kode toko), C Customer Name, D Term-FI, E Over Due Amt, F Total, G–S 13 bulan mundur
(G = bulan tarikan), T "<bulan S" (tagihan lebih tua). Tanggal tarikan dari nama file
EXPORT_YYYYMMDD_HHMMSS (bila tidak ada, wajib diisi). File ditolak seluruhnya bila header salah,
kolom bulan tidak berurutan, kode toko ganda, angka tidak terbaca, atau bulan tarikan lebih tua
dari data yang sudah berlaku. Kode toko yang tidak ada di Customer Master dibiarkan.

**Cakupan per depot**: yang dinilai hanya depot yang ada di kolom A. Sebelum Terapkan, pop up
menampilkan depot lain dalam jangkauan: yang tidak dicentang memakai **data debtor lama**; yang
dicentang **"Tidak ada tagihan"** dianggap seluruh tokonya lunas; depot tanpa data tidak dinilai.

**Aturan lunas per klaim Not Yet** (Bulan SO = SO start, Bulan Bill = Billing end campaign;
toleransi Rp 1, cek per kolom):
- Lebih dulu: tanpa Customer Master; toko **Bad Debt**; dikembalikan depot; kode toko tidak ada di
  data debtor → **Lunas**; campaign tanpa tanggal SO/Billing atau tanggal salah → **Periode Salah**.
- Lalu menurut **skala prioritas**:
  1. tidak ada **Over Due Amount**;
  2. lunas **selama periode campaign** (kolom Bulan SO s/d Bulan Bill);
  3. lunas **sebelum periode campaign** (kolom sebelum Bulan SO, termasuk T).
  Semua aturan yang gagal dicatat; penyebab utama = prioritas tertinggi yang gagal.

**Pratinjau** menampilkan kartu: **Belum Lunas** (dirinci Over due / Selama campaign / Sebelum
campaign), **Lunas**, **Bad Debt**, **Periode Salah**, **Campaign Bermasalah** (ringkasan per
campaign dari klaim Periode Salah untuk dibetulkan di Campaign Master).

**Terapkan**:
- Klaim Lunas mendapat **tawaran** dengan **deadline 7 hari**; Tgl Lunas kosong diisi tanggal tarikan.
- Tawaran yang sudah ada **dinilai ulang**: bila tidak lunas lagi (mis. muncul Over Due Amount),
  tawaran dibatalkan dan klaim kembali ke Restricted.
- Lewat deadline → **overdue**; email peringatan harian 07:00 WIB per depot sampai diproses atau
  dikembalikan.

**Claim Upload > Open**: hanya klaim dengan tawaran aktif. Kolom Deadline berwarna (7–5 hari hijau,
4–3 kuning, 2–1 oranye, 0 merah, lewat = merah tua "Lewat X hari"). Tombol: Pindahkan ke Mass
Upload, Unduh Template, **Kembalikan ke Not Yet** (alasan wajib → ke Restricted), Tandai/Cabut Bad Debt
(izin khusus).

**Claim Upload > Restricted** (terlihat bawaan, hanya baca): seluruh Not Yet lain beserta alasan
(Belum lunas + rincian, Bad Debt, Periode salah, Dikembalikan depot, Belum ada data debtor, Belum
dinilai).
- **Pindah ke Open** hanya oleh pemegang izin **Restricted (Editor)** — di Open berlabel
  "Restricted" dan boleh diajukan.
- **Pindah ke Posting Exception** boleh siapa saja, **hanya Expired** (On Hold ditolak).
- Tandai/Cabut Bad Debt dengan izin **Bad Debt (Tandai)**.
- Server menolak pengajuan klaim yang tidak ada di Open dari jalur mana pun (Mass Upload, Manual).

**Bad Debt** ditandai per toko dengan alasan. Saat saklar **Approval Bad Debt** (Approval On/Off,
bawaan mati) menyala, klaim toko Bad Debt tampil di Open dan pengajuannya wajib di-approve di tab
Bad Debt (Management of Approval). Saat mati, klaimnya tetap di Restricted sampai Editor
memindahkannya. Email pengajuan memuat remark "Bad Debt".

## 6. Nomor batch

Satu proses = satu nomor urut. Format 15 karakter: **K T SSS DDMMYY NNNN**
- K = kejadian terakhir dokumen: 0 biasa, 1 Amend Doc, 2 Reprocessing, 3 Expired, 4 Jenis CB diganti
  (terbawa ke proses berikutnya, batch lama tidak diubah).
- T = tahap: 1 Submit, 2 Release/Bulk, 3 Claim, 4 Done/Expired, 5 Compile.
- SSS = suffix akun, DDMMYY = tanggal proses WIB, NNNN = urutan hari itu.
Contoh: 120521610260003 = dokumen yang pernah di-Amend, di-Release oleh suffix 052 pada 16-10-2026,
proses ke-3. Batch lama (sistem sebelumnya) 13–14 digit.

## 7. Remark, log, dan email

- **Remark** dokumen (Analytics, detail) memuat semua kejadian khusus: "Doc Amendment - <tahap>",
  "Document Reprocessed", "CB Type Changed"; pelaku Amend tampil merah di Process by.
- **Log Activity**: satu baris per proses (mis. "Workflow RELEASE: 19 dokumen", batch di kolom Batch),
  bukan per dokumen. Jejak per dokumen ada di riwayat dokumen.
- **Email Pengajuan** (Access Management): saklar aktif, mode uji, CC Semua Email, dan CC wajib per
  jenis: Pengajuan, Approval & Approved, Done, On Hold & Expired, Amend Doc, Reprocessing, Debtor.
  TO = Email TO depot (email Done ke Email Kepala Admin bila diisi). Email Otomatis terjadwal:
  Daily, Weekly, Timetable.
- **Di DEV hanya email uji** yang dikirim; alamat depot tidak pernah menerima email dari dev.

## 8. Aturan data yang selalu berlaku

- Tanggal tampil dd-Mmm-yyyy (mis. 16-Oct-2026); input menerima dd-mm-yyyy, dd.mm.yy, ddmmyy,
  ddmmyyyy.
- Nominal rupiah tanpa desimal (dipotong); unduhan Excel sama dengan layar, kode/ID sebagai teks.
- Gross up dihitung sistem dari master (Rebate, Rebate Manual, Voucher = 0; Badan 15%, Perorangan
  progresif); periode dokumen = periode campaign, ditimpa perpanjangan On Hold.
- Data diarsipkan, bukan dihapus permanen, dan dapat dipulihkan.
- Dokumen tanpa Customer Master terlihat tetapi tidak dapat diproses.
- Dashboard publik harus identik dengan Report.

---

## [PERMINTAAN]

Berdasarkan fakta di atas, buatkan: **<tuliskan di sini, contoh: "diagram alur (Mermaid flowchart)
end-to-end dari Compile sampai Done, termasuk cabang Restricted, Bad Debt, On Hold/Expired, dan
Approval On/Off", atau "SOP untuk admin depot", atau "user guide tab Upload Debtor untuk OSC",
atau "daftar test case UAT">**.

Ketentuan keluaran:
- Sebutkan peran pelaku dan nama menu/tab persis seperti di atas.
- Tandai fitur yang hanya ada di DEV (Upload Debtor, tab Restricted, Bad Debt, Campaign Bermasalah).
- Jangan menambah aturan yang tidak tertulis; tandai "belum ditetapkan" bila perlu.
