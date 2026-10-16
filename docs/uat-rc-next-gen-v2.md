# UAT — Resource Collection Next Gen

**Versi 2 · DRAFT · 25 September 2026**

Dokumen ini dipakai sambil membuka aplikasi. Setiap baris adalah satu hal yang dicoba, ditulis
sebagai yang dilakukan di layar. Tidak perlu pengetahuan teknis.

---

## Cara memakai dokumen ini

1. Isi **Ringkasan Pelaksanaan** di bawah — siapa menguji tahap mana, dan siapa PIC-nya.
2. Kerjakan tahap demi tahap. Setiap tahap punya kotak isian di awalnya.
3. Centang hasil tiap baris: **L** (Lulus) / **G** (Gagal) / **T** (Terhalang).
4. Setiap **G** wajib disertai tangkapan layar dan nomor dokumen yang dipakai.
5. Kembali ke Ringkasan, isi jumlah Lulus/Gagal dan tanggal selesainya.

> **Penting:** jangan memakai data pelanggan sungguhan untuk mencoba Reject, On Hold atau
> Expired. Pakai dokumen uji pada bagian Persiapan.

> **Email:** selama UAT, tab Email Pengajuan **wajib** dalam **Mode Uji**. Dengan begitu email
> tetap terkirim sungguhan tetapi hanya ke alamat penguji — depot tidak menerima apa pun.

---

# RINGKASAN PELAKSANAAN

Diisi lebih dulu, lalu dilengkapi setelah tiap tahap selesai.

| No | Tahap | Modul | Jml Uji | User yang Diuji | PIC | Lulus | Gagal | Tanggal | Status |
|---|---|---|---|---|---|---|---|---|---|
| 0 | Akses & Sesi | Login, Menu | 14 | Semua peran | | | | | |
| 1 | Pengajuan | Claim Upload | 22 | Admin Depot / OSC | | | | | |
| 2 | Persetujuan | Management of Approval | 25 | OSC / Supervisor / Management / Depot Head | | | | | |
| 3 | Penerbitan | Release Doc | 7 | OSC / Supervisor | | | | | |
| 4 | Pencairan | Claim Process | 12 | OSC yang ditunjuk · Depot Head | | | | | |
| 5 | Rebate | Bulk Process | 5 | OSC / Supervisor | | | | | |
| 6 | Data Induk | Key Master | 14 | System Manager / Supervisor | | | | | |
| 7 | Dokumen | Document Center | 6 | OSC / Supervisor | | | | | |
| 8 | Jadwal | Timetable | 6 | Semua peran | | | | | |
| 9 | Laporan | Report & Dashboard Publik | 18 | Supervisor / Management / Umum | | | | | |
| 10 | Analisa | Analytics & People Performance | 7 | Supervisor / Management | | | | | |
| 11 | Pengguna | Access Management | 11 | Supervisor / System Manager | | | | | |
| 12 | **Email Pengajuan** | Access Management | 27 | Supervisor / System Manager | | | | | |
| 13 | Jejak | Log Aktivitas | 6 | Supervisor / System Manager | | | | | |
| | **TOTAL** | | **180** | | | | | | |

**Status:** Belum Mulai · Berjalan · Selesai · Terhalang

### Ringkasan temuan

| Tingkat | Arti | Jumlah | Sudah ditangani |
|---|---|---|---|
| S1 | Pekerjaan berhenti, tidak ada jalan lain | | |
| S2 | Pekerjaan jalan tapi hasilnya salah | | |
| S3 | Mengganggu, ada jalan memutar | | |
| S4 | Kosmetik (salah ketik, warna) | | |

**UAT dinyatakan lulus bila:** semua tahap Selesai, tidak ada S1 dan S2 yang masih terbuka,
serta S3/S4 sudah dicatat dan disepakati untuk ditangani setelah rilis.

---

# PERSIAPAN

## Akun penguji

Dibuat oleh System Manager sebelum UAT dimulai. **Jangan berbagi akun** — Log Aktivitas mencatat
pelakunya, dan akun bersama membuat hasil UAT tidak bisa ditelusuri.

| Kode | Peran | Jangkauan | Nama Penguji | Diserahkan Tgl |
|---|---|---|---|---|
| U-ADM | Admin Depot | 1 depot | | |
| U-OSC1 | OSC | **2 depot** (untuk menguji penyaring depot) | | |
| U-OSC2 | OSC | **1 depot** (untuk menguji penyaring terkunci) | | |
| U-OSC3 | OSC yang ditunjuk memegang Claim Process | sesuai penunjukan | | |
| U-SPV | Supervisor | membina U-OSC1 dan U-OSC2 | | |
| U-DH | Depot Head | 1 depot | | |
| U-MGT | Management | 1 region berisi ≥ 2 depot | | |
| U-SM | System Manager | seluruhnya | | |

## Dokumen uji

Disiapkan pada depot U-OSC1, minimal **20 dokumen**:

| Jenis | Jumlah | Keterangan |
|---|---|---|
| Transfer | 5 | 2 di antaranya pelanggannya belum punya rekening |
| CN | 5 | |
| Rebate | 5 | untuk menguji Bulk Process |
| Rebate Manual | 5 | dulu bernama RA07 / RA7 |

Ditambah variasi berikut agar skenario negatif bisa dijalankan:

- 2 dokumen yang pelanggannya **belum punya KTP maupun NPWP**
- 2 dokumen dengan **TOP diketik melebihi TOP Customer Master**
- 2 dokumen dengan **TOP dikosongkan**

## Data master

- Minimal **3 depot** dengan Region dan alamat email terisi
- Minimal **10 pelanggan** dengan KTP/NPWP dan rekening lengkap
- Minimal **3 campaign** dengan Periode Campaign, Periode SO dan Periode Billing terisi

---

# TAHAP 0 — Akses & Sesi

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 0.1 | Masuk dengan User ID dan PIN yang benar | Masuk ke beranda; nama, peran dan depot tampil di kanan atas | | |
| 0.2 | Masukkan PIN salah 3 kali berturut-turut | Muncul sisa percobaan; pada kali ke-3 akun diblokir dengan pesan jelas | | |
| 0.3 | Masuk dengan akun berstatus Nonaktif | Ditolak: "Akun dinonaktifkan administrator" | | |
| 0.4 | Setelah masuk, tekan **F5** | Tetap di dalam aplikasi, tidak diminta PIN lagi | | |
| 0.5 | Tutup **semua** jendela peramban, buka lagi alamatnya | Diminta login lagi | | |
| 0.6 | Buka alamat aplikasi di **tab baru** | Diminta login — ini disengaja, bukan cacat | | |
| 0.7 | Belum login, ketik alamat `/report` | Formulir login muncul; setelah masuk langsung mendarat di Report | | |
| 0.8 | Sebagai U-ADM, ketik `/access` di bilah alamat | Berakhir di beranda, Access Management tidak terbuka | | |
| 0.9 | Ajukan ganti PIN dari menu profil | Pengajuan masuk antrean persetujuan Supervisor / System Manager | | |
| 0.10 | Tekan Logout, lalu tekan tombol Back peramban | Tidak kembali masuk ke aplikasi | | |
| 0.11 | Masuk sebagai tiap peran, catat kartu menu yang tampil | Hanya kartu yang menjadi haknya yang tampil | | |
| 0.12 | Masuk sebagai U-DH lalu U-MGT | Keduanya melihat semua kartu — keduanya memegang semua izin, dibatasi jangkauan depot/region | | |
| 0.13 | Buka satu per satu: `/upload` `/release` `/process` `/analytics` `/key-master` `/document-center` `/report` `/timetable` `/approval` `/people-performance` `/access` `/log-activity` `/bulk-process` `/profile` | Semuanya membuka modulnya; alamat ikut berubah saat pindah modul | | |
| 0.14 | Cabut izin satu tab lewat Access Management, lalu masuk sebagai akun itu | Tab tidak bisa dibuka; muncul "Anda tidak memiliki izin tab ini" | | |

---

# TAHAP 1 — Pengajuan (Claim Upload)

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________

## 1A. Unggah massal

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 1.1 | Tekan Download Template pada tab Mass | Excel terunduh dengan kolom sesuai layar | | |
| 1.2 | Tempel/unggah 20 dokumen uji | Semuanya tampil di pratinjau, berstatus valid | | |
| 1.3 | **Kosongkan** kolom TOP Actual pada satu baris | Baris tetap valid — tidak ada pesan "TOP wajib" | | |
| 1.4 | Isi TOP dengan `abc` lalu `-5` | Ditolak: "TOP harus angka lebih dari 0, atau dikosongkan" | | |
| 1.5 | Isi TOP **120** pada pelanggan yang TOP Master-nya 60 | Baris tetap **valid**; sel TOP Actual berlatar kuning sebagai penanda | | |
| 1.6 | Perhatikan kolom pratinjau | Ada **TOP Setting** (dari Customer Master) dan **TOP Actual** (yang diketik), terpisah | | |
| 1.7 | Unggah dokumen yang pelanggannya belum punya KTP maupun NPWP | Ditolak, pesannya menyebut kode pelanggannya | | |
| 1.8 | Unggah dokumen Transfer yang pelanggannya belum punya rekening | Ditolak, pesannya menyebut apa yang kurang | | |
| 1.9 | Isi Tgl Lunas dengan keenam bentuk: `15-04-2026` `15.04.2026` `15.04.26` `15-04-26` `150426` `15042026` | Keenamnya diterima dan ditampilkan `15-Apr-2026` | | |
| 1.10 | Isi `15/04/2026` atau `April 15 2026` | Ditolak, pesannya menyebut bentuk yang diterima | | |
| 1.11 | Isi `31-04-2026` | Ditolak — bukan digeser ke 30 April | | |
| 1.12 | Isi Jenis CB dengan `RA07` | Diterima, ditampilkan sebagai **Rebate Manual** | | |
| 1.13 | Isi Jenis CB dengan `Transferr` | Ditolak, pesannya menyebut daftar resminya | | |
| 1.14 | Centang kotak pada baris header | Semua baris di bawahnya ikut tercentang | | |
| 1.15 | Tekan Posting pada baris terpilih | Dokumen jadi Submitted; laporan hasil menampilkan nomor batch | | |
| 1.16 | Unggah dokumen dengan No Document yang sudah ada | Ditolak, tidak membuat duplikat | | |

## 1B. Input manual dan tab Open

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 1.17 | Isi satu dokumen lewat tab Single | Tersimpan, hasilnya sama seperti lewat unggahan massal | | |
| 1.18 | Buka tab Open | Menampilkan dokumen Not Yet dalam jangkauan depot | | |
| 1.19 | Tekan tombol Kolom, ubah centangnya, lalu muat ulang halaman | Pilihan kolom bertahan setelah muat ulang | | |
| 1.20 | Pilih dokumen, tekan **On Hold**, isi alasan | Alasan **wajib**; dokumen masuk antrean persetujuan On Hold | | |
| 1.21 | Pilih dokumen uji, tekan **Expired**, isi alasan | Alasan **wajib**; dokumen masuk antrean persetujuan Expired | | |
| 1.22 | Coba On Hold tanpa mengisi alasan | Ditolak | | |

---

# TAHAP 2 — Persetujuan (Management of Approval)

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________

## 2A. Daftar dan rincian

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 2.1 | Setelah 1.15, buka Management of Approval | Batch unggahan tadi muncul di tab **Within Payment Term** | | |
| 2.2 | Perhatikan kolom tabelnya | Ada No Batch, Depot, Qty Doc, Qty Cust, Qty Campaign, Total Net CB, Submitted By, Posting Date | | |
| 2.3 | Perhatikan kolom Total Net CB | Nilai **penuh tanpa koma di belakang** (`Rp 24.926.250`), bukan singkatan | | |
| 2.4 | Klik nomor batch | Tampil No Doc, Kode/Nama Cust, Kode/Nama Campaign, Net CB, Jenis CB, Status Pajak | | |
| 2.5 | Pada rincian, centang kolom TOP Setting, TOP Actual, Selisih TOP | Ketiganya tampil; selisih positif merah tebal | | |
| 2.6 | Buka tab **Overdue** | Berisi dokumen yang **TOP Actual lebih besar dari TOP Setting** (dari 1.5) | | |
| 2.7 | Masuk sebagai U-DH, buka modul ini | Tab Overdue **tidak tampil**; ada keterangan sebabnya | | |

## 2B. Tindakan

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 2.8 | Tekan Approve pada satu batch | Dokumen jadi Approved dan hilang dari antrean; **tidak** diminta alasan | | |
| 2.9 | Centang beberapa batch, tekan Posting Approve | Semuanya diproses sekaligus | | |
| 2.10 | Dari rincian, tekan Approve pada satu baris | Hanya dokumen itu yang berpindah | | |
| 2.11 | Tekan Reject pada satu dokumen | Dokumen kembali ke **Not Yet** di depot; tidak diminta alasan | | |
| 2.12 | Masuk sebagai U-OSC1 (2 depot) | Dropdown depot bisa dipilih; memilih satu depot mempersempit daftar dan ringkasannya | | |
| 2.13 | Masuk sebagai U-OSC2 (1 depot) | Dropdown **terkunci** pada depot itu | | |
| 2.14 | Ketik sebagian nomor batch / nama toko / campaign di kotak cari | Daftar menyempit seketika; ringkasan di atas ikut menyesuaikan | | |
| 2.15 | Tekan Excel pada tab mana pun | Berkas berisi **apa yang sedang terlihat** — tab, penyaring dan pencarian yang aktif | | |

## 2C. Riwayat

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 2.16 | Buka tab History | Berisi waktu, No Doc, batch, depot, tindakan, dari→ke, oleh | | |
| 2.17 | Bila riwayat lebih dari 50 baris, tekan Berikutnya / Sebelumnya | Berpindah halaman; keterangan "Menampilkan a-b dari N" benar | | |

## 2D. Tab On Hold & Expired

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 2.18 | Buka tab keempat | Berisi dokumen On Hold dan Expired yang menunggu keputusan, dengan kolom **Asal** dan **Alasan Terakhir** | | |
| 2.19 | Cari baris beralasan panjang, tekan tombol kecil di sebelahnya | Dialog terbuka berisi alasan utuh, status, oleh, dan waktu | | |
| 2.20 | Tekan Approve pada baris On Hold | Status **tetap** On Hold, baris hilang dari antrean (keputusannya disahkan) | | |
| 2.21 | Tekan Reject pada baris On Hold | Dokumen kembali ke status **sebelum** ditahan dan melanjutkan alurnya | | |
| 2.22 | Masuk sebagai U-DH | Antrean terlihat, tombolnya **beku**, ada keterangan sebabnya | | |
| 2.23 | Masuk sebagai U-OSC1 lalu U-SPV | Keduanya bisa memutuskan, terbatas pada jangkauan depotnya | | |
| 2.24 | Buka Release Doc setelah 2.8 | Hanya dokumen **Approved** yang muncul — bukan Submitted | | |
| 2.25 | Coba Release dokumen yang masih Submitted | Ditolak | | |

---

# TAHAP 3 — Penerbitan (Release Doc)

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 3.1 | Pilih dokumen Approved, tekan Release | Jadi Released, nomor batch Release terbit | | |
| 3.2 | Perhatikan kartu pelaku pada baris | Tampil Submitted, **Approved**, Released, Claimed — masing-masing dengan nama dan tanggal | | |
| 3.3 | Tekan Reject dengan alasan | Alasan **wajib**; dokumen kembali ke Not Yet | | |
| 3.4 | Tekan Reject tanpa mengisi alasan | Ditolak | | |
| 3.5 | Buka Release Doc, cari dokumen Rebate | Dokumen Rebate **tidak** muncul di sini | | |
| 3.6 | Gunakan penyaring depot / campaign | Daftar menyempit sesuai penyaring | | |
| 3.7 | Tekan Excel | Berkas berisi baris yang sedang terlihat | | |

---

# TAHAP 4 — Pencairan (Claim Process)

> **User yang diuji:** OSC yang ditunjuk (U-OSC3) · Depot Head (U-DH)
> **PIC:** _______________  **Tanggal:** ___________
>
> Tahap ini dipegang **OSC yang ditunjuk**, bukan Finance. Depot Head ikut diuji di sini untuk
> memastikan jangkauan depotnya benar-benar membatasi apa yang bisa ia proses.

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 4.1 | Pilih dokumen Released, tekan Claim | Jadi Claimed dengan nomor batch Claim | | |
| 4.2 | Pilih dokumen Claimed, isi tanggal clearing, tekan Clearing | Jadi Done | | |
| 4.3 | Coba Clearing atas dokumen yang masih Approved | Ditolak | | |
| 4.4 | Tekan Reject pada tab Claim to Finance | Dokumen kembali ke Approved | | |
| 4.5 | Tekan Reject pada Clearing | Dokumen kembali ke Released | | |
| 4.6 | Tandai satu dokumen Released sebagai Expired dari modul ini | Jadi Expired, nomor batch terbit di kolom Clearing | | |
| 4.7 | Perhatikan nilai rupiah di seluruh tabel | Tidak ada koma desimal di belakang angka | | |
| 4.8 | Isi tanggal clearing dengan bentuk `15042026` | Diterima dan ditampilkan `15-Apr-2026` | | |
| 4.9 | Tekan Excel | Berkas berisi baris yang sedang terlihat | | |
| 4.10 | Masuk sebagai **U-DH**, buka Claim Process | Hanya dokumen depotnya sendiri yang terlihat | | |
| 4.11 | Sebagai **U-DH**, coba proses dokumen depot lain lewat alamat langsung | Ditolak | | |
| 4.12 | Masuk sebagai **U-OSC3**, jalankan 4.1 sampai 4.5 | Semuanya bisa dikerjakan dalam jangkauan depotnya | | |

---

# TAHAP 5 — Rebate (Bulk Process)

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 5.1 | Buka Bulk Process | Hanya Rebate yang **sudah melewati approval** yang tampil — tidak ada yang Submitted | | |
| 5.2 | Pilih beberapa, tekan proses | Langsung jadi Done dengan nomor batch | | |
| 5.3 | Unggah dokumen Jenis CB **Rebate Manual**, lalu setujui | Langsung Done setelah disetujui, tanpa lewat Release | | |
| 5.4 | Coba proses dokumen non-Rebate lewat Bulk Process | Ditolak | | |
| 5.5 | Tekan Excel | Berkas berisi baris yang sedang terlihat | | |

---

# TAHAP 6 — Data Induk (Key Master)

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 6.1 | Tekan Ubah pada satu pelanggan, ganti Contact Person, Simpan | Tersimpan; tombol Simpan **bisa dijangkau** walau dialognya panjang | | |
| 6.2 | Saat dialog Ubah terbuka, coba gulir dan klik layar di belakangnya | Layar belakang **tidak** bergerak dan **tidak** menanggapi klik | | |
| 6.3 | Tekan Ubah pada satu campaign | Dialog memuat **tiga** pasang periode: Campaign, SO, dan Billing | | |
| 6.4 | Isi Periode SO `05-01-2026`–`25-03-2026`, **kosongkan** Billing, Simpan | Periode Billing otomatis **mengikuti SO** | | |
| 6.5 | Isi Periode Billing `01-09-2026`–`30-09-2026`, Simpan | Billing yang diisi **menang**, tidak tertimpa SO | | |
| 6.6 | Isi Billing Start lebih besar dari Billing End | Ditolak, pesannya menyebut campaign-nya | | |
| 6.7 | Perhatikan tabel Campaign | Ada kolom **Periode SO** dan **Periode Billing** | | |
| 6.8 | Unduh template Campaign Master | Memuat kolom Periode SO Start/End dan Periode Billing Start/End | | |
| 6.9 | Unggah template yang sudah diisi | Keempat periode tersimpan dan terbaca di tabel | | |
| 6.10 | Tekan Ubah pada satu depot, ganti Region, Simpan | Tersimpan; Region berubah | | |
| 6.11 | Isi alamat email depot pada Depot Master, Simpan | Tersimpan — ini yang dipakai email pengajuan | | |
| 6.12 | Arsipkan satu baris pada ketiga tab | Baris pindah ke arsip, **tidak** terhapus permanen | | |
| 6.13 | Buka daftar arsip, kembalikan baris tadi | Baris kembali seperti semula | | |
| 6.14 | Masuk sebagai U-ADM, buka Key Master | Data terlihat, tombol pengubah beku | | |

---

# TAHAP 7 — Dokumen (Document Center)

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 7.1 | Pilih campaign / batch / status, tekan Tarik Data | Daftar tampil sesuai penyaring | | |
| 7.2 | Perhatikan kolom periodenya | Menampilkan Periode SO dan Periode Billing | | |
| 7.3 | Lihat dokumen yang tidak punya perpanjangan | Memakai periode dari Campaign Master | | |
| 7.4 | Ubah periode SO pada satu dokumen | Nilai dokumen yang tampil, **menimpa** periode master | | |
| 7.5 | Buka tab Reprocessing Doc | Berisi dokumen On Hold yang perlu direvisi, beserta periode SO dan Billing | | |
| 7.6 | Pilih baris, isi alasan, Arsipkan | Baris terarsip dan bisa dikembalikan | | |

---

# TAHAP 8 — Jadwal (Timetable)

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 8.1 | Buka Timetable | Matriks depot × campaign tampil; filter memakai **Tahun Campaign**, bukan tanggal acuan | | |
| 8.2 | Pilih Tahun Campaign yang berbeda | Campaign mengikuti tahun **Periode Start** pada Campaign Master (Periode End hanya fallback); daftar tahun tidak menyusut | | |
| 8.3 | Catat isi "Top 10 Depot dengan Not Yet Terbanyak" sebagai U-SM, lalu bandingkan sebagai U-OSC2 pada tahun yang sama | **Isinya sama persis** — papan ini memang terbuka untuk semua dan angkanya sama dengan status Not Yet pada matriks | | |
| 8.4 | Masuk sebagai U-ADM | Hanya progres depotnya sendiri yang terlihat per depot; progres per campaign tetap terlihat | | |
| 8.5 | Pilih sel, tandai Not Achieved | Tersimpan dan terlihat oleh peran lain | | |
| 8.6 | Masuk sebagai U-SPV pada depot di luar OSC binaannya | Data terlihat, tombol aksi beku | | |
| 8.7 | Periksa campaign yang sudah di-Exclude | Tidak ikut dihitung di Timetable | | |

---

# TAHAP 9 — Laporan (Report & Dashboard Publik)

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________

## 9A. Modul Report

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 9.1 | Buka Report, tab Dashboard | KPI, Tren Volume & Nilai, Distribusi Status, Aging, Clearing Rate per Region, Top 10 Depot Outstanding, tabel per Campaign/Region/Depot | | |
| 9.2 | Pilih satu **Tahun Campaign** | Semua angka menyempit; daftar tahun **tidak menyusut** sehingga masih bisa kembali ke tahun lain | | |
| 9.3 | Isi **Billing Start** dan **Billing End** | Hanya baris yang periode billing-nya bersinggungan dengan rentang itu yang ikut | | |
| 9.4 | Tekan Kosongkan | Semua penyaring bersih, angkanya kembali seperti semula | | |
| 9.5 | Isi rentang billing tahun 1900 | Tabel kosong dengan keterangan — bukan menampilkan seluruh data | | |
| 9.6 | Buka tab Cost Center 1 | Depot × Campaign dengan Qty, Net CB, Net Claimed, Gross Claimed, CB Expired, Clearing | | |
| 9.7 | Dekatkan kursor ke batang pada diagram Sebaran Clearing Rate | Menyebut **nama campaign** di rentang itu beserta jumlah depotnya | | |
| 9.8 | Buka tab Cost Center 2 | Campaign × Bulan pencairan; penyaring bulan berfungsi | | |
| 9.9 | Tekan Excel | Berkas berisi **sembilan sheet**: KPI, Tren Bulanan, Sebaran Status, Aging, Per Region, Per Depot, Performa per Campaign, Cost Center 1, Cost Center 2 | | |
| 9.10 | Tanpa membuka tab Cost Center 2, tekan Excel | Sheet Cost Center 2 **tetap ada isinya** | | |
| 9.11 | Perhatikan seluruh nilai rupiah | Tidak ada koma desimal di belakang angka | | |
| 9.12 | Tekan tombol perbesar pada satu diagram, lalu tutup | Memenuhi layar, lalu kembali ke ukuran semula tanpa berubah bentuk | | |

## 9B. Dashboard publik

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 9.13 | Buka `/dashboard` di jendela penyamaran | Terbuka **tanpa** diminta login | | |
| 9.14 | Bandingkan angka dan diagramnya dengan modul Report untuk penyaring yang sama | **Sama persis** | | |
| 9.15 | Buka `/dashboard/cost-center-1` dan `/dashboard/cost-center-2` | Masing-masing membuka panelnya | | |
| 9.16 | Telusuri seluruh halaman | **Tidak ada** nama toko, KTP, NPWP, maupun nomor rekening | | |
| 9.17 | Pakai penyaring Region/Depot/Campaign/Tahun/Billing | Berfungsi sama seperti di dalam aplikasi | | |
| 9.18 | Buka di layar ponsel | Tetap terbaca, tidak ada gulir mendatar | | |

---

# TAHAP 10 — Analisa (Analytics & People Performance)

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 10.1 | Buka tab History | Daftar klaim dengan penyaring OSC/Depot/Campaign/Tahun | | |
| 10.2 | Klik nama toko | Dialog terbuka; kode dan nama toko terbaca utuh, tidak terpotong | | |
| 10.3 | Buka tab Summary | Ringkasan per Master Code | | |
| 10.4 | Klik satu baris Summary | Rinciannya terbuka | | |
| 10.5 | Tekan Excel | Berkas berisi baris yang sedang terlihat | | |
| 10.6 | Buka People Performance tab OSC | Kinerja per OSC tampil | | |
| 10.7 | Buka People Performance tab Supervisor | Kinerja per Supervisor tampil | | |

---

# TAHAP 11 — Pengguna (Access Management)

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 11.1 | Sebagai U-SM, buka Access Management | Daftar akun beserta peran, depot dan region | | |
| 11.2 | Ubah peran satu akun uji menjadi **Depot Head** | Tersimpan; yurisdiksi lama ter-reset, tidak ada dua yurisdiksi sekaligus | | |
| 11.3 | Ubah peran satu akun menjadi **Management** | Muncul kotak Assignment Region berisi region dari Depot Master beserta jumlah depotnya | | |
| 11.4 | Coba simpan region yang tidak ada di Depot Master | Ditolak | | |
| 11.5 | Tugaskan satu OSC ke satu depot | Tersimpan — ini yang menentukan CC email pengajuan | | |
| 11.6 | Masuk sebagai akun yang punya akses modul ini tetapi **bukan** Supervisor/System Manager | Isinya terlihat, semua tombol pengubah **beku**, ada keterangan sebabnya | | |
| 11.7 | Buka dialog Edit satu akun | Daftar modul memuat **Document Center** (bukan "Cashback Compilation") dan **Management of Approval** | | |
| 11.8 | Periksa daftar tab pada dialog Edit | Memuat tab **Email Pengajuan** | | |
| 11.9 | Daftarkan akun baru, setujui dari tab Approval Request | Akun bisa masuk setelah disetujui | | |
| 11.10 | Sebagai U-SM, hapus akun uji | Terhapus/terarsip sesuai aturan | | |
| 11.11 | Buka tab Arsip Hapus, kembalikan akun tadi | Akun kembali | | |

---

# TAHAP 12 — Email Pengajuan

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________
>
> **Alamat email uji yang dipakai:** _______________________________

> Selama seluruh tahap ini, **Mode Uji wajib menyala**. Email tetap terkirim sungguhan, tetapi
> hanya ke alamat uji di atas. Depot tidak menerima apa pun.

## 12A. Pengaturan

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 12.1 | Buka Access Management, tab **Email Pengajuan** | Tab terbuka; sakelar menunjukkan NONAKTIF pada awalnya | | |
| 12.2 | Perhatikan kotak Contoh Penerima | **TO** berisi alamat depot; **CC** berisi OSC & Supervisor sesuai yurisdiksi dan email tambahan | | |
| 12.3 | Periksa apakah alamat CC dari Depot Master ikut | **Tidak boleh ikut** — CC hanya dari yurisdiksi dan daftar di tab ini | | |
| 12.4 | Isi daftar Email Tambahan dengan 2 alamat, Simpan | Tersimpan; kedua alamat muncul di Contoh Penerima bagian CC | | |
| 12.5 | Isi Email Tambahan dengan `bukan-email`, Simpan | Ditolak, pesannya menyebut alamat yang salah | | |
| 12.6 | Centang **Mode Uji** tanpa mengisi alamat uji, Simpan | Ditolak: "Mode Uji memerlukan alamat email uji" | | |
| 12.7 | Isi alamat uji, centang Mode Uji, nyalakan sakelar, Simpan | Tersimpan; keterangan berubah jadi "Seluruh email dari action akan masuk ke ..." | | |
| 12.8 | Muat ulang halaman, buka tab ini lagi | Sakelar tetap **AKTIF** dan Mode Uji tetap tercentang | | |
| 12.9 | Tekan **Kirim Contoh** | Email contoh masuk ke alamat uji dalam beberapa detik | | |
| 12.10 | Masuk sebagai OSC atau Admin, buka tab ini | Isinya terlihat, semua kendali **beku** | | |

## 12B. Email dari action sungguhan

Lakukan action seperti biasa, lalu periksa kotak masuk alamat uji. Email datang dalam **≤ 1 menit**.

| # | Action yang dilakukan | Subjek yang harus muncul | L/G/T | Catatan |
|---|---|---|---|---|
| 12.11 | Posting 2 dokumen di Claim Upload | `[UJI] Approval - Pengajuan Claim Cashback <nama depo>` | | |
| 12.12 | Approve 2 dokumen di Management of Approval | `[UJI] Approved - Pengajuan Claim Cashback Depo <nama depo>` | | |
| 12.13 | Clearing 2 dokumen | `[UJI] Done - Pengajuan Claim Cashback` | | |
| 12.14 | On Hold 2 dokumen | `[UJI] On Hold - Pengajuan Claim Cashback <nama depo>` | | |
| 12.15 | Expired 2 dokumen | `[UJI] Expired - Pengajuan Claim Cashback <nama depo>` | | |
| 12.16 | Release dan Claim to Finance 2 dokumen | **Tidak ada email** — kedua tahap ini memang tidak mengabari | | |

## 12C. Isi email — periksa pada salah satu email di atas

| # | Yang diperiksa | Yang harus terlihat | L/G/T | Catatan |
|---|---|---|---|---|
| 12.17 | Kop surat | Berlatar **merah**, ada **logo Nippon** di kiri dan **maskot RC** di kanan, keduanya tampil tanpa harus menekan "tampilkan gambar" | | |
| 12.18 | Spanduk hitam di paling atas | "MODE UJI — surat ini TIDAK dikirim ke depot", beserta daftar TO dan CC yang seharusnya | | |
| 12.19 | Kalimat pembuka | Diawali "Dear All," | | |
| 12.20 | Tabel | Kolom NO BATCH, NAMA CAMPAIGN, JUMLAH TOKO, TOTAL CB | | |
| 12.21 | Baris terakhir tabel | **GRAND TOTAL** dengan jumlah toko dan total CB | | |
| 12.22 | Nilai rupiah | Pemisah **titik**, tanpa koma desimal (`Rp 1.100.000`) | | |
| 12.23 | Kalimat permintaan | Sesuai tahapnya: Management approve / OSC proses / Depo cek list toko | | |
| 12.24 | Penutup | "Regards, SA & SD Operations" dan keterangan kecil `sa_sd1@nipponpaint-indonesia.com` | | |
| 12.25 | Lampiran | **Tidak ada lampiran PDF** | | |
| 12.26 | Email On Hold dan Expired | Memuat kotak kuning berisi **Alasan** yang diketik saat aksi | | |

## 12D. Setelah UAT selesai

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 12.27 | Hapus centang Mode Uji, Simpan | Muncul konfirmasi yang menyebutkan email akan mulai ke alamat depot sungguhan | | |

---

# TAHAP 13 — Jejak (Log Aktivitas)

> **User yang diuji:** _______________  **PIC:** _______________  **Tanggal:** ___________

| # | Yang dilakukan | Yang harus terjadi | L/G/T | Catatan |
|---|---|---|---|---|
| 13.1 | Buka Log Aktivitas setelah menjalankan Tahap 1–5 | Setiap tindakan tercatat dengan waktu, User ID, peran dan keterangan | | |
| 13.2 | Cari baris approve batch | Keterangannya menyebut **nomor batch dan jumlah dokumen** | | |
| 13.3 | Cari baris approve satu dokumen | Keterangannya menyebut **nomor dokumennya** | | |
| 13.4 | Bandingkan tab History pada Management of Approval dengan Log Aktivitas | Keduanya menceritakan kejadian yang sama | | |
| 13.5 | Pakai penyaring tanggal dan pengguna | Daftar menyempit sesuai penyaring | | |
| 13.6 | Tekan Excel | Berkas berisi baris yang sedang terlihat | | |

---

# PERSETUJUAN

UAT dinyatakan selesai bila seluruh syarat pada Ringkasan Pelaksanaan terpenuhi.

| Peran | Nama | Tanda tangan | Tanggal |
|---|---|---|---|
| Pemilik sistem | | | |
| Perwakilan Depot | | | |
| Perwakilan OSC | | | |
| Perwakilan Supervisor | | | |
| Perwakilan Management | | | |

---

# Lampiran A — Alur status

```
Not Yet ──submit──> Submitted ──approve──> Approved ──release──> Released
   ^                     │                     │                     │
   │                reject (kembali)      (Rebate)                claim
   │                     │                     │                     │
   └─────────────────────┘                     v                     v
                                       Bulk Process ──> Done       Claimed
                                                                     │
                                                                 clearing
                                                                     v
                                                                   Done

On Hold / Expired ──approve──> keputusan disahkan
                  ──reject───> kembali ke status sebelumnya
```

**Email dikirim pada:** Submitted · On Hold · Expired · Approved · Done (Clearing)
**Tidak dikirim pada:** Release · Claim to Finance · Reject · Bulk Process

---

# Lampiran B — Sering disalahpahami

Hal-hal berikut **bukan cacat**. Dicantumkan agar tidak dilaporkan berulang.

| Yang terlihat | Penjelasan |
|---|---|
| Tab baru meminta login lagi | Sesi berumur satu tab, sesuai permintaan pemilik |
| Dokumen TOP 120 masuk Overdue | Overdue = TOP Actual melebihi TOP Setting, bukan soal umur dokumen |
| Release kosong | Dokumen harus disetujui dulu di Management of Approval |
| Depot Head tidak melihat tab Overdue | Depot Head menangani Within Payment Term saja |
| Top 10 Depot memuat depot orang lain | Papan itu memang terbuka untuk semua, isinya jumlah saja |
| Angka rupiah tanpa koma di belakang | Tampilan dibulatkan; nilai aslinya tetap utuh di basis data |
| Periode Billing sama dengan Periode SO | Selama Billing dibiarkan kosong, ia memang mengikuti SO |
| Email tidak berlampiran PDF | Disengaja — angkanya sudah lengkap di badan surat |
| CC email kosong di sebagian depot | Depot itu belum punya OSC/Supervisor yang ditugaskan. Isi di Access Management atau pakai Email Tambahan |
| Release dan Claim tidak mengirim email | Hanya lima tahap yang mengabari; keduanya bukan bagian dari lima itu |

---

# Lampiran C — Catatan temuan

Salin baris ini sebanyak yang diperlukan.

| No | ID Uji | Tingkat | Ringkasan temuan | Dokumen/batch yang dipakai | Bukti | Dilaporkan oleh | Tanggal | Status |
|---|---|---|---|---|---|---|---|---|
| 1 | | | | | | | | |
| 2 | | | | | | | | |
| 3 | | | | | | | | |
| 4 | | | | | | | | |
| 5 | | | | | | | | |

**Status temuan:** Baru · Sedang diperbaiki · Sudah diperbaiki · Perlu diuji ulang · Ditutup
