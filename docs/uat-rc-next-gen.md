# UAT — Resource Collection Next Gen

**Status: DRAFT** · Disusun 24 September 2026 · Untuk rilis migrasi Apps Script → Supabase + Vercel

Ditulis untuk: penguji UAT dari tim Depot, OSC, Supervisor, Finance dan Management, beserta
pemilik sistem yang menandatangani hasilnya. Tidak diperlukan pengetahuan teknis — setiap langkah
ditulis sebagai yang dilakukan di layar.

---

## 1. Tujuan dan batas pengujian

UAT ini memastikan sistem RC Next Gen **melakukan pekerjaan yang sama dengan sistem lama, dengan
aturan yang sudah disepakati**, sebelum dipakai sungguhan.

**Yang diuji:** seluruh alur klaim dari unggah sampai cair, seluruh modul, seluruh peran, dan
aturan kewenangan di antaranya.

**Yang TIDAK diuji di sini:** kecepatan di bawah beban tinggi (ada uji tersendiri), tampilan pada
peramban selain Chrome/Edge versi terbaru, dan pengiriman email ke alamat pelanggan sungguhan.

### Aturan penting selama UAT

> **Jangan memakai data pelanggan sungguhan untuk mencoba penolakan, penghangusan, atau
> penghapusan.** Pakai dokumen uji yang disepakati di bagian 3. Tindakan seperti Expired
> mengubah status dokumen dan tidak dapat dibatalkan sendiri oleh depot.

> **Email otomatis harus dalam keadaan nonaktif** selama UAT, kecuali pada skenario yang memang
> mengujinya (EMAIL-01 sampai EMAIL-04) dan itu pun memakai alamat penguji, bukan alamat depot.

---

## 2. Lingkungan dan persiapan

| Hal | Nilai |
|---|---|
| Alamat aplikasi | _(diisi saat UAT dimulai — lingkungan UAT, bukan produksi)_ |
| Dashboard publik | `/dashboard` — dapat dibuka tanpa login |
| Peramban | Chrome atau Edge versi terbaru |
| Basis data | Project Supabase UAT |

**Sebelum mulai, pastikan:**

1. Setiap penguji punya akun sendiri dengan peran sesuai bagian 3. Jangan berbagi akun — Log
   Aktivitas mencatat pelakunya, dan akun bersama membuat hasil UAT tidak dapat ditelusuri.
2. Data master sudah terisi: minimal 3 depot dengan Region terisi, 10 pelanggan dengan KTP/NPWP
   dan rekening lengkap, dan 3 campaign dengan Periode Campaign, Periode SO dan Periode Billing.
3. Setiap penguji menyiapkan catatan hasil memakai format di bagian 12.

---

## 3. Akun penguji dan dokumen uji

### 3.1 Peran yang harus tersedia

| Kode | Peran | Jangkauan | Disiapkan oleh |
|---|---|---|---|
| U-ADM | Admin Depot | 1 depot | System Manager |
| U-OSC1 | OSC | 2 depot (untuk menguji penyaring depot) | System Manager |
| U-OSC2 | OSC | 1 depot (untuk menguji penyaring yang dibekukan) | System Manager |
| U-SPV | Supervisor | membina U-OSC1 dan U-OSC2 | System Manager |
| U-DH | Depot Head | 1 depot | Supervisor / System Manager |
| U-MGT | Management | 1 region berisi ≥ 2 depot | Supervisor |
| U-SM | System Manager | seluruhnya | — |

### 3.2 Dokumen uji

Siapkan minimal **20 dokumen** pada depot U-OSC1, terdiri dari:

- 5 dokumen Jenis CB **Transfer**
- 5 dokumen **CN**
- 5 dokumen **Rebate**
- 5 dokumen **Rebate Manual** (dulu RA07 / RA7)

Dari 20 itu, siapkan variasi berikut agar skenario negatif dapat dijalankan:

- 2 dokumen yang pelanggannya **belum punya KTP maupun NPWP**
- 2 dokumen yang pelanggannya **belum punya nomor rekening** (untuk Jenis CB Transfer)
- 2 dokumen dengan **TOP diketik melebihi TOP Customer Master** (untuk tab Overdue)
- 2 dokumen dengan **TOP dikosongkan**

---

## 4. Kriteria masuk dan kriteria lulus

**Kriteria masuk (UAT boleh dimulai bila):**
- Seluruh akun pada 3.1 sudah dibuat dan dapat masuk
- Data master pada bagian 2 sudah terisi
- Tidak ada temuan Severity 1 yang masih terbuka dari pengujian internal

**Kriteria lulus (UAT dinyatakan selesai bila):**
- Seluruh skenario **Wajib** berstatus Lulus
- Tidak ada temuan Severity 1 atau 2 yang masih terbuka
- Temuan Severity 3 dan 4 sudah dicatat dan disepakati untuk ditangani setelah rilis
- Pemilik sistem menandatangani bagian 13

### Tingkat keparahan temuan

| Tingkat | Arti | Contoh |
|---|---|---|
| **S1** | Pekerjaan berhenti, tidak ada jalan lain | Tidak bisa login; dokumen tidak bisa diunggah |
| **S2** | Pekerjaan bisa jalan tapi hasilnya salah | Angka Report tidak cocok; dokumen hilang dari antrean |
| **S3** | Mengganggu, ada jalan memutar | Kolom terpotong; tombol sulit dicapai |
| **S4** | Kosmetik | Salah ketik; warna tidak konsisten |

---

## 5. Login, sesi dan hak akses

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| AUTH-01 | Login benar | Masuk dengan User ID dan PIN yang benar | Masuk ke beranda; nama, peran dan depot tampil di kanan atas | ✅ |
| AUTH-02 | PIN salah | Masukkan PIN salah 1×, lalu 2×, lalu 3× | Pesan sisa percobaan; pada percobaan ke-3 akun diblokir dengan pesan jelas | ✅ |
| AUTH-03 | Akun nonaktif | Masuk dengan akun berstatus Nonaktif | Ditolak dengan pesan "Akun dinonaktifkan administrator" | ✅ |
| AUTH-04 | **Muat ulang tetap masuk** | Setelah masuk, tekan F5 | Tetap berada di dalam aplikasi, tidak diminta PIN lagi | ✅ |
| AUTH-05 | **Tutup jendela harus masuk ulang** | Tutup seluruh jendela peramban, buka lagi alamatnya | Diminta login lagi | ✅ |
| AUTH-06 | Tab baru | Buka alamat aplikasi di tab baru | Diminta login — ini memang disengaja, bukan cacat | ✅ |
| AUTH-07 | Alamat langsung sebelum login | Buka `/report` dalam keadaan belum masuk | Formulir login tampil; setelah masuk langsung mendarat di Report | ✅ |
| AUTH-08 | Alamat bukan kewenangan | Sebagai U-ADM, ketik `/access` di bilah URL | Berakhir di beranda, tidak membuka Access Management | ✅ |
| AUTH-09 | Ganti PIN | Ajukan ganti PIN dari menu profil | Pengajuan masuk antrean persetujuan Supervisor / System Manager | |
| AUTH-10 | Logout | Tekan Logout | Kembali ke formulir login; menekan tombol Back tidak mengembalikan ke dalam aplikasi | ✅ |

---

## 6. Kartu menu dan izin per tab

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| MENU-01 | Kartu sesuai hak | Masuk sebagai tiap peran pada 3.1, catat kartu yang tampil | Hanya kartu yang memang menjadi haknya yang tampil | ✅ |
| MENU-02 | Depot Head & Management | Masuk sebagai U-DH lalu U-MGT | Keduanya melihat seluruh kartu — kedua peran memegang seluruh izin, dibatasi jangkauan depot/region | ✅ |
| MENU-03 | Izin per tab | Cabut izin satu tab (mis. `keyMaster.campaign`) lewat Access Management, lalu masuk sebagai akun itu | Tab Campaign tidak dapat dibuka; muncul "Anda tidak memiliki izin tab ini" | ✅ |
| MENU-04 | Alamat modul | Buka tiap alamat pada dokumen rute: `/upload`, `/release`, `/process`, `/analytics`, `/access`, `/log-activity`, `/bulk-process`, `/key-master`, `/document-center`, `/report`, `/timetable`, `/approval`, `/people-performance`, `/profile` | Masing-masing membuka modulnya; alamat di bilah URL ikut berubah saat berpindah modul | ✅ |
| MENU-05 | Tombol maju/mundur | Berpindah beberapa modul, lalu tekan Back dan Forward peramban | Berpindah antar modul, tidak keluar dari aplikasi | |

---

## 7. Claim Upload

### 7.1 Unggah massal

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| UPL-01 | Unduh template | Tekan Download Template pada tab Mass | Berkas Excel terunduh dengan kolom sesuai layar | ✅ |
| UPL-02 | Unggah 20 dokumen uji | Tempel/unggah 20 baris dokumen uji | Seluruhnya tampil di pratinjau dengan status valid | ✅ |
| UPL-03 | **Kolom TOP boleh kosong** | Kosongkan kolom TOP Actual pada satu baris | Baris tetap valid — tidak ada pesan "TOP wajib" | ✅ |
| UPL-04 | TOP bukan angka | Isi TOP dengan `abc` atau `-5` | Baris ditolak dengan pesan "TOP harus angka lebih dari 0, atau dikosongkan" | ✅ |
| UPL-05 | **TOP melebihi Master tetap boleh diunggah** | Isi TOP 120 pada pelanggan yang TOP Master-nya 60 | Baris **valid** dan dapat diunggah; sel TOP Actual berlatar kuning sebagai penanda | ✅ |
| UPL-06 | Dua kolom TOP terpisah | Perhatikan pratinjau | Ada kolom **TOP Setting** (dari Customer Master) dan **TOP Actual** (yang diketik), terpisah | ✅ |
| UPL-07 | KTP/NPWP kosong | Unggah dokumen yang pelanggannya belum punya keduanya | Ditolak dengan pesan yang menyebut kode pelanggannya | ✅ |
| UPL-08 | Transfer tanpa rekening | Unggah dokumen Transfer yang pelanggannya belum punya rekening | Ditolak dengan pesan yang menyebut apa yang kurang | ✅ |
| UPL-09 | **Format tanggal** | Isi Tgl Lunas dengan `15-04-2026`, `15.04.2026`, `15.04.26`, `15-04-26`, `150426`, `15042026` | Keenamnya diterima dan ditampilkan sebagai `15-Apr-2026` | ✅ |
| UPL-10 | Tanggal di luar bentuk resmi | Isi `15/04/2026` atau `April 15 2026` | Ditolak dengan pesan yang menyebut bentuk yang diterima | ✅ |
| UPL-11 | Tanggal tidak ada di kalender | Isi `31-04-2026` | Ditolak, bukan digeser ke 30 April | ✅ |
| UPL-12 | Jenis CB diketik | Isi Jenis CB dengan `RA07` | Diterima dan ditampilkan sebagai **Rebate Manual** | ✅ |
| UPL-13 | Jenis CB salah ketik | Isi Jenis CB dengan `Transferr` | Ditolak dengan pesan yang menyebut daftar resminya | ✅ |
| UPL-14 | Header centang | Centang kotak pada baris header | Seluruh baris di bawahnya ikut tercentang | ✅ |
| UPL-15 | Posting | Tekan Posting pada baris yang dipilih | Dokumen berpindah ke status Submitted; laporan hasil menampilkan nomor batch | ✅ |
| UPL-16 | Dokumen ganda | Unggah dokumen dengan No Document yang sudah ada | Ditolak, tidak membuat duplikat | ✅ |

### 7.2 Manual dan tab Open

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| UPL-20 | Input manual | Isi satu dokumen lewat tab Single | Tersimpan dengan hasil yang sama seperti lewat unggahan massal | ✅ |
| UPL-21 | Tab Open | Buka tab Open | Menampilkan dokumen berstatus Not Yet dalam jangkauan depot | ✅ |
| UPL-22 | Pilih kolom | Tekan tombol Kolom, centang/hapus beberapa kolom | Kolom tampil/hilang sesuai pilihan, dan pilihannya bertahan setelah muat ulang | |
| UPL-23 | Posting Exception — On Hold | Pilih dokumen, tekan On Hold, isi alasan | Alasan **wajib**; dokumen masuk antrean persetujuan On Hold | ✅ |
| UPL-24 | Posting Exception — Expired | Pilih dokumen uji, tekan Expired, isi alasan | Alasan **wajib**; dokumen masuk antrean persetujuan Expired | ✅ |

---

## 8. Alur persetujuan dan proses klaim

### 8.1 Management of Approval

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| APP-01 | Dokumen masuk antrean | Setelah UPL-15, buka Management of Approval | Batch unggahan tadi muncul di tab **Within Payment Term** | ✅ |
| APP-02 | Kolom daftar batch | Perhatikan tabelnya | Ada No Batch, Depot, Qty Doc, Qty Cust, Qty Campaign, Total Net CB, Submitted By, Posting Date | ✅ |
| APP-03 | **Net CB penuh** | Perhatikan kolom Total Net CB, lalu klik nomor batch | Nilai penuh tanpa desimal (`Rp 24.926.250`), bukan singkatan; di rincian juga nilai penuh | ✅ |
| APP-04 | Rincian batch | Klik nomor batch | Tampil No Doc, Kode/Nama Cust, Kode/Nama Campaign, Net CB, Jenis CB, Status Pajak | ✅ |
| APP-05 | **TOP Setting vs Actual** | Pada rincian, centang kolom TOP Setting, TOP Actual, Selisih TOP | Ketiganya tampil; selisih positif berwarna merah tebal | ✅ |
| APP-06 | **Overdue** | Buka tab Overdue | Berisi dokumen yang **TOP Actual > TOP Setting** (dari UPL-05) | ✅ |
| APP-07 | Depot Head hanya WPT | Masuk sebagai U-DH, buka modul ini | Tab Overdue **tidak tampil**; ada keterangan sebabnya | ✅ |
| APP-08 | Approve satu batch | Tekan Approve pada satu batch | Dokumen berpindah ke Approved dan hilang dari antrean; tidak diminta alasan | ✅ |
| APP-09 | Approve massal | Centang beberapa batch, tekan Posting Approve | Seluruhnya diproses sekaligus | ✅ |
| APP-10 | Approve satu dokumen | Dari rincian, tekan Approve pada satu baris | Hanya dokumen itu yang berpindah | ✅ |
| APP-11 | **Reject** | Tekan Reject pada satu dokumen | Dokumen kembali ke **Not Yet** di depot; tidak diminta alasan | ✅ |
| APP-12 | Penyaring depot — banyak depot | Masuk sebagai U-OSC1 (2 depot) | Dropdown depot dapat dipilih; memilih satu depot mempersempit daftar dan ringkasannya | ✅ |
| APP-13 | Penyaring depot — satu depot | Masuk sebagai U-OSC2 (1 depot) | Dropdown **terkunci** pada depot itu | ✅ |
| APP-14 | Pencarian | Ketik sebagian nomor batch / nama toko / campaign | Daftar menyempit seketika; ringkasan di atas ikut menyesuaikan | ✅ |
| APP-15 | Unduh Excel | Tekan Excel pada tab mana pun | Berkas berisi **apa yang sedang terlihat** — tab aktif, penyaring aktif, pencarian aktif | ✅ |
| APP-16 | Tab History | Buka tab History | Berisi riwayat Approve/Reject: waktu, No Doc, batch, depot, tindakan, dari→ke, oleh | ✅ |
| APP-17 | Pagination History | Bila riwayat > 50 baris, tekan Berikutnya / Sebelumnya | Berpindah halaman; keterangan "Menampilkan a-b dari N" benar | ✅ |
| APP-18 | **Tab On Hold & Expired** | Buka tab keempat | Berisi dokumen On Hold dan Expired yang menunggu keputusan, beserta kolom **Asal** dan **Alasan Terakhir** | ✅ |
| APP-19 | Alasan panjang | Cari baris yang alasannya panjang, tekan tombol kecil di sebelahnya | Dialog terbuka berisi alasan utuh, status, oleh, dan waktu | ✅ |
| APP-20 | Approve keputusan hold | Tekan Approve pada baris On Hold | Status **tetap** On Hold, baris hilang dari antrean (keputusan disahkan) | ✅ |
| APP-21 | Reject keputusan hold | Tekan Reject pada baris On Hold | Dokumen kembali ke status **sebelum** ditahan dan melanjutkan alurnya | ✅ |
| APP-22 | Kewenangan tab On Hold | Masuk sebagai U-DH | Antrean terlihat, tetapi tombolnya **beku** dengan keterangan sebabnya | ✅ |
| APP-23 | OSC & Supervisor | Masuk sebagai U-OSC1 lalu U-SPV | Keduanya dapat memutuskan, terbatas pada jangkauan depotnya | ✅ |

### 8.2 Release, Claim Finance, Clearing

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| FLW-01 | **Release hanya yang sudah approved** | Buka Release Doc setelah APP-08 | Hanya dokumen berstatus **Approved** yang muncul — bukan Submitted | ✅ |
| FLW-02 | Release ditolak sebelum approve | Coba Release dokumen yang masih Submitted (lewat Bulk atau alamat langsung) | Ditolak | ✅ |
| FLW-03 | Release | Pilih dokumen, tekan Release | Berpindah ke Released, nomor batch Release terbit | ✅ |
| FLW-04 | Kolom jejak di Release | Perhatikan kartu pelaku pada baris | Tampil Submitted, **Approved**, Released, Claimed — masing-masing dengan nama dan tanggal | ✅ |
| FLW-05 | Reject Release | Tekan Reject dengan alasan | Alasan **wajib**; dokumen kembali ke Not Yet | ✅ |
| FLW-06 | Claim Finance | Pilih dokumen Released, tekan Claim | Berpindah ke Claimed dengan nomor batch Claim | ✅ |
| FLW-07 | Clearing | Pilih dokumen Claimed, isi tanggal clearing, tekan Clearing | Berpindah ke Done | ✅ |
| FLW-08 | Melompati tahap | Coba Clearing atas dokumen yang masih Approved | Ditolak | ✅ |
| FLW-09 | Reject Claim | Tekan Reject pada Claim Finance | Dokumen kembali ke Approved | ✅ |
| FLW-10 | Reject Clearing | Tekan Reject pada Clearing | Dokumen kembali ke Released | ✅ |

### 8.3 Bulk Process (Rebate)

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| BLK-01 | Rebate tidak di jalur bertahap | Buka Release Doc | Dokumen Rebate **tidak** muncul di sana | ✅ |
| BLK-02 | Rebate setelah approve | Buka Bulk Process | Hanya Rebate yang **sudah melewati approval** yang tampil — tidak ada yang berstatus Submitted | ✅ |
| BLK-03 | Proses bulk | Pilih beberapa, tekan proses | Langsung menjadi Done dengan nomor batch | ✅ |
| BLK-04 | Rebate Manual | Unggah dokumen Jenis CB Rebate Manual | Langsung Done saat submit, tanpa melewati antrean | ✅ |

---

## 9. Key Master, Document Center dan Timetable

### 9.1 Key Master

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| KM-01 | Customer Master — ubah | Tekan Ubah pada satu pelanggan, ganti Contact Person, Simpan | Tersimpan; tombol Simpan **dapat dicapai** walau dialognya panjang | ✅ |
| KM-02 | Campaign Master — ubah | Tekan Ubah pada satu campaign | Dialog memuat **tiga** pasang periode: Campaign, SO, Billing | ✅ |
| KM-03 | **Periode SO & Billing tersimpan** | Isi Periode SO `05-01-2026`–`25-03-2026` dan Billing `10.02.2026`–`15042026`, Simpan | Tersimpan; tabel menampilkan kolom **Periode SO** dan **Periode Billing** | ✅ |
| KM-04 | Periode terbalik | Isi Billing Start lebih besar dari Billing End | Ditolak dengan pesan yang menyebut campaign-nya | ✅ |
| KM-05 | Template Campaign | Unduh template Campaign Master | Memuat kolom Periode SO Start/End dan Periode Billing Start/End | ✅ |
| KM-06 | Unggah massal campaign | Unggah template yang sudah diisi | Keempat periode tersimpan dan terbaca di tabel | ✅ |
| KM-07 | Depot Master — ubah | Tekan Ubah pada satu depot, ganti Region, Simpan | Tersimpan; Region berubah | ✅ |
| KM-08 | Arsip | Arsipkan satu baris pada ketiga tab, lalu buka daftar arsip dan kembalikan | Baris berpindah ke arsip dan dapat dikembalikan — **tidak terhapus permanen** | ✅ |
| KM-09 | Latar modal mati | Saat dialog Ubah terbuka, coba gulir dan klik layar di belakangnya | Layar belakang tidak bergerak dan tidak menanggapi klik | ✅ |

### 9.2 Document Center

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| DOC-01 | Tarik data | Pilih campaign / batch / status, tekan Tarik Data | Daftar tampil sesuai penyaring | ✅ |
| DOC-02 | **Periode SO & Billing** | Perhatikan kolomnya | Menampilkan periode SO dan Billing; dokumen tanpa perpanjangan memakai periode dari Campaign Master | ✅ |
| DOC-03 | Reprocessing Doc | Buka tab Reprocessing Doc | Berisi dokumen On Hold yang perlu direvisi, beserta periode SO dan Billing | ✅ |
| DOC-04 | **Perpanjangan menimpa master** | Ubah periode SO pada satu dokumen | Nilai dokumen yang tampil, bukan lagi periode master | ✅ |
| DOC-05 | Arsip baris | Pilih baris, isi alasan, Arsipkan | Baris terarsip dan dapat dikembalikan | |

### 9.3 Timetable

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| TT-01 | Buka Timetable | Buka modulnya | Matriks depot × campaign tampil | ✅ |
| TT-02 | **Top 10 Depot sama untuk semua** | Catat isi "Top 10 Depot dengan Not Yet Terbanyak" sebagai U-SM, lalu bandingkan sebagai U-OSC2 (1 depot) | **Isinya sama persis** — papan ini memang terbuka untuk semua | ✅ |
| TT-03 | Progres per depot | Sebagai U-ADM | Hanya progres depotnya sendiri yang terlihat per depot; progres per campaign tetap terlihat | ✅ |
| TT-04 | Tandai Not Achieved | Pilih sel, tandai | Tersimpan dan terlihat oleh peran lain | |
| TT-05 | Tombol aksi beku | Sebagai U-SPV pada depot di luar OSC binaannya | Data terlihat, tombol aksi beku | ✅ |

---

## 10. Report, Analytics, People Performance dan Dashboard publik

### 10.1 Report

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| RPT-01 | Tab Dashboard | Buka Report | KPI, Tren Volume & Nilai, Distribusi Status, Aging, Clearing Rate per Region, Top 10 Depot Outstanding, tabel per Campaign/Region/Depot | ✅ |
| RPT-02 | **Penyaring Tahun Campaign** | Pilih satu tahun | Seluruh angka menyempit; daftar tahun **tidak menyusut** sehingga masih bisa kembali ke tahun lain | ✅ |
| RPT-03 | **Penyaring Billing Start/End** | Isi rentang billing | Hanya baris yang periode billing-nya bersinggungan dengan rentang itu yang ikut | ✅ |
| RPT-04 | Kosongkan | Tekan Kosongkan | Seluruh penyaring bersih dan angkanya kembali seperti semula | ✅ |
| RPT-05 | Penyaring tanpa hasil | Isi rentang billing tahun 1900 | Tabel kosong dengan keterangan, bukan menampilkan seluruh data | ✅ |
| RPT-06 | Cost Center 1 | Buka tabnya | Depot × Campaign dengan Qty, Net CB, Net Claimed, Gross Claimed, CB Expired, Clearing | ✅ |
| RPT-07 | **Tooltip sebaran Clearing Rate** | Dekatkan kursor ke batang pada diagram Sebaran Clearing Rate | Menyebut campaign apa saja di rentang itu beserta jumlah depotnya | ✅ |
| RPT-08 | Cost Center 2 | Buka tabnya | Campaign × Bulan pencairan; penyaring bulan berfungsi | ✅ |
| RPT-09 | **Excel seluruh bagian** | Tekan Excel | Berkas berisi **sembilan sheet**: KPI, Tren Bulanan, Sebaran Status, Aging, Per Region, Per Depot, Performa per Campaign, Cost Center 1, Cost Center 2 | ✅ |
| RPT-10 | Excel tab yang belum dibuka | Tanpa membuka tab Cost Center 2, tekan Excel | Sheet Cost Center 2 **tetap ada isinya** | ✅ |
| RPT-11 | Angka tanpa desimal | Perhatikan seluruh nilai rupiah | Tidak ada `,05` atau `,053` di belakang angka | ✅ |
| RPT-12 | Perbesar kartu | Tekan tombol perbesar pada satu diagram | Diagram memenuhi layar; ditutup kembali ke ukuran semula tanpa berubah bentuk | |

### 10.2 Analytics dan People Performance

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| ANL-01 | History | Buka tab History | Daftar klaim dengan penyaring OSC/Depot/Campaign/Tahun | ✅ |
| ANL-02 | **Detail customer rapi** | Klik nama toko | Dialog terbuka; kode dan nama toko terbaca utuh, tidak terpotong | ✅ |
| ANL-03 | Summary | Buka tab Summary | Ringkasan per Master Code; klik satu baris membuka rinciannya | ✅ |
| PPL-01 | People Performance — OSC | Buka tab OSC | Kinerja per OSC tampil | ✅ |
| PPL-02 | People Performance — Supervisor | Buka tab Supervisor | Kinerja per Supervisor tampil | ✅ |

### 10.3 Dashboard publik

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| PUB-01 | Buka tanpa login | Buka `/dashboard` di jendela penyamaran | Terbuka tanpa diminta login | ✅ |
| PUB-02 | **Sama dengan Report** | Bandingkan angka dan diagram dengan modul Report untuk penyaring yang sama | **Sama persis** | ✅ |
| PUB-03 | Alamat per panel | Buka `/dashboard/cost-center-1` dan `/dashboard/cost-center-2` | Masing-masing membuka panelnya | ✅ |
| PUB-04 | **Tidak ada data pribadi** | Telusuri seluruh halaman | Tidak ada nama toko, KTP, NPWP, maupun nomor rekening | ✅ |
| PUB-05 | Penyaring | Pakai penyaring Region/Depot/Campaign/Tahun/Billing | Berfungsi sama seperti di dalam aplikasi | ✅ |

---

## 11. Access Management, Log Aktivitas dan Email

| ID | Skenario | Langkah | Hasil yang diharapkan | Wajib |
|---|---|---|---|---|
| ACC-01 | Daftar akun | Sebagai U-SM, buka Access Management | Daftar akun beserta peran, depot dan region | ✅ |
| ACC-02 | Ubah peran | Ubah peran satu akun uji menjadi Depot Head | Tersimpan; yurisdiksi lama ter-reset, tidak ada dua yurisdiksi sekaligus | ✅ |
| ACC-03 | **Assignment Region** | Ubah peran satu akun menjadi Management | Muncul kotak Assignment Region berisi region dari Depot Master beserta jumlah depotnya | ✅ |
| ACC-04 | Region tidak sah | Coba simpan region yang tidak ada di Depot Master | Ditolak | ✅ |
| ACC-05 | **Viewer** | Masuk sebagai akun yang punya akses Access Management tetapi bukan Supervisor/System Manager | Isinya terlihat, seluruh tombol pengubah **beku**, ada keterangan sebabnya | ✅ |
| ACC-06 | Matriks izin | Buka dialog Edit satu akun | Daftar modul memuat **Document Center** (bukan "Cashback Compilation") dan **Management of Approval** | ✅ |
| ACC-07 | Persetujuan akun baru | Daftarkan akun baru, setujui dari tab Approval Request | Akun dapat masuk setelah disetujui | ✅ |
| ACC-08 | Hapus akun | Sebagai U-SM, hapus akun uji | Terhapus/terarsip sesuai aturan | |
| LOG-01 | Log Aktivitas terisi | Buka Log Aktivitas setelah menjalankan bagian 7–8 | Setiap tindakan tercatat dengan waktu, User ID, peran dan keterangan | ✅ |
| LOG-02 | **Keterangan Approve batch** | Cari baris approve batch | Keterangannya menyebut **nomor batch dan jumlah dokumen** | ✅ |
| LOG-03 | **Keterangan satu dokumen** | Cari baris approve satu dokumen | Keterangannya menyebut **nomor dokumennya** | ✅ |
| LOG-04 | Riwayat approval sejalan | Bandingkan tab History pada modul Approval dengan Log Aktivitas | Keduanya menceritakan kejadian yang sama | ✅ |
| EMAIL-01 | Pratinjau | Buka panel Email Otomatis, tekan Pratinjau | Isi email tampil lengkap dengan diagram | ✅ |
| EMAIL-02 | Kirim uji | Tekan Kirim Uji ke alamat penguji | Email diterima; **diagram tampil**, bukan kotak kosong | ✅ |
| EMAIL-03 | Lampiran PDF | Periksa email Daily | PDF terlampir dan dapat dibuka | ✅ |
| EMAIL-04 | Tautan dashboard | Tekan tautan Claim Dashboard di email | Membuka `/dashboard` tanpa diminta login | ✅ |
| EMAIL-05 | Menonaktifkan | Hapus centang hari pada jadwal | Jadwal tidak berjalan pada hari itu | |

---

## 12. Format pencatatan hasil

Satu baris per skenario. Simpan sebagai lembar bersama agar dapat dilihat semua penguji.

| ID | Penguji | Tanggal | Hasil | Severity | Catatan / bukti |
|---|---|---|---|---|---|
| UPL-05 | Budi (U-OSC1) | 25-Sep-2026 | Lulus | — | Tangkapan layar `upl-05.png` |
| APP-06 | Sari (U-MGT) | 25-Sep-2026 | Gagal | S2 | Dokumen TOP 120 muncul di WPT, bukan Overdue |

**Aturan mencatat:**
- **Lulus / Gagal / Terhalang** — "Terhalang" bila tidak dapat diuji karena hal lain rusak
- Setiap Gagal **wajib** disertai tangkapan layar dan nomor dokumen yang dipakai
- Jangan memperbaiki data lalu mencoba ulang tanpa mencatat percobaan pertamanya

---

## 13. Persetujuan

UAT dinyatakan selesai bila seluruh kriteria pada bagian 4 terpenuhi.

| Peran | Nama | Tanda tangan | Tanggal |
|---|---|---|---|
| Pemilik sistem | | | |
| Perwakilan Depot | | | |
| Perwakilan OSC | | | |
| Perwakilan Finance | | | |
| Perwakilan Management | | | |

---

## Lampiran A — Ringkasan alur status

```
Not Yet ──submit──> Submitted ──approve──> Approved ──release──> Released
                         │                     │                     │
                    reject_approval        (Rebate)              claim
                         │                     │                     │
                         v                     v                     v
                     Not Yet             Bulk Process ──> Done    Claimed
                                                                     │
                                                                 clearing
                                                                     v
                                                                   Done

On Hold / Expired ──approve──> tetap (keputusan sah)
                  ──reject───> kembali ke status sebelumnya
```

## Lampiran B — Hal yang sering disalahpahami

| Yang terlihat | Bukan cacat, melainkan aturan |
|---|---|
| Tab baru meminta login lagi | Sesi berumur satu tab, sesuai permintaan pemilik |
| Dokumen TOP 120 masuk Overdue | Overdue = TOP Actual melebihi TOP Setting, bukan soal umur dokumen |
| Release kosong | Dokumen harus disetujui dulu di Management of Approval |
| Depot Head tidak melihat tab Overdue | Depot Head menangani Within Payment Term saja |
| Top 10 Depot memuat depot orang lain | Papan itu memang terbuka untuk semua, berisi jumlah saja |
| Angka rupiah tanpa koma di belakang | Tampilan dibulatkan; nilai aslinya tetap utuh di basis data |
