  # Muat ulang data prod: kosongkan lalu muat data final

Panduan untuk mengganti seluruh data klaim, pelanggan, dan campaign di prod dengan data final dari
satu berkas Excel.

- **Template:** [Template_Muat_Ulang_Data_RC.xlsx](Template_Muat_Ulang_Data_RC.xlsx)
- **Alat:** [scripts/muat-ulang-data.mjs](../scripts/muat-ulang-data.mjs)

Alat ini sudah digladikan penuh di dev pada 7 Oktober 2026: 10.000 klaim dikosongkan, dimuat
ulang, lalu dipulihkan. Jumlah dan total CB Net per status cocok persis.

---

## 1. Apa yang terjadi

| Data | Perlakuan |
|---|---|
| Klaim, data sensitif klaim (KTP/NPWP/rekening), riwayat status | **dihapus**, lalu dimuat dari lembar Klaim |
| Pelanggan dan pemetaan depotnya | **dihapus**, lalu dimuat dari lembar Customer |
| Campaign | **dihapus**, lalu dimuat dari lembar Campaign |
| Depot | **tidak pernah dihapus**. Lembar Depot (opsional) hanya memperbarui atau menambah depot. |
| Tanda Exclude Campaign, Not Achieved Timetable, dan Not Participating (Campaign Master) | dipotret, lalu dipasang kembali untuk kode yang masih ada |
| Akun, peran, izin, tab, yurisdiksi, PIN, pengaturan email, log aktivitas, profil depot | **tidak disentuh** |

Ada tiga hal yang perlu diketahui sebelum menjalankan:

- **Kolom turunan tidak diisi di template.** Nilainya dihitung sistem dengan aturan yang sama
  dengan aplikasi:
  - **Gross up:** dihitung dari CB Net, Subyek Pajak pelanggan, dan Status Pajak campaign.
  - **Subyek Pajak:** ada NPWP berarti Badan; hanya KTP berarti Perorangan.
- **Jejak lama diganti.** Setiap dokumen mendapat satu baris riwayat "muat_ulang". Nama
  penyetuju, perilis, dan seterusnya kosong; yang tersisa nomor batch dan tanggal dari Excel.
- **Tiga hal tidak ikut terbawa:**
  - Klaim terarsip ikut terhapus.
  - Ajuan On Hold/Expired yang belum diputuskan harus diajukan ulang.
  - Dokumen berstatus Submitted kembali masuk antrean Management of Approval.

## 2. Mengisi template

Ada dua cara memulai.

1. **Dari template kosong:** isi `docs/Template_Muat_Ulang_Data_RC.xlsx`.
2. **Dari data prod saat ini, lalu diperbaiki:**

   ```
   node scripts/muat-ulang-data.mjs --env prod --ekspor .runtime/muat-ulang/ekspor-prod.xlsx
   ```

   Perintah ini hanya membaca prod. Tanggal peninggalan Apps Script diubah otomatis ke
   dd-mm-yyyy. Teks itu terbukti berformat Bulan/Hari: dari ±4.900 tanggal, angka pertamanya
   tidak pernah lebih dari 12.

   > Berkas ekspor berisi KTP, NPWP, dan rekening. Simpan di `.runtime/` (tidak ikut git) dan
   > jangan dikirim ke luar.

Aturan pengisian. Lembar **Petunjuk** di template memuat keterangan setiap kolom.

- **Judul kolom** di baris 1 jangan diubah. Data mulai baris 2.
- **Kolom wajib** berwarna merah.
- **Tanggal** ditulis dd-mm-yyyy (mis. `15-04-2026`); `dd.mm.yyyy`, `ddmmyyyy`, atau sel tanggal
  Excel juga diterima. Garis miring (`15/04/2026`) ditolak karena bisa terbaca sebagai bulan.
- **Format Text:** kolom kode, KTP, NPWP, No Rekening, dan nomor batch sudah berformat Text, jadi
  nol di depan tidak hilang. Kalau menempel data dari berkas lain, pakai *Paste Values* supaya
  formatnya tetap.
- **Status** dipilih dari daftar: Not Yet, Submitted, Approved, Released, Claimed, Done, On Hold,
  Expired.
- **Depot klaim** harus termasuk depot pelanggannya. Kalau belum ada, pemetaannya ditambahkan
  otomatis dan dilaporkan.
- **Campaign inactive/cleared** boleh punya klaim; statusnya diterapkan setelah klaim dimuat.

## 3. Memeriksa berkas (boleh diulang, tidak mengubah apa pun)

```
node scripts/muat-ulang-data.mjs --berkas <berkas.xlsx> --periksa --env prod
```

- **GALAT** wajib diperbaiki. Selama masih ada galat, pemuatan tidak bisa dijalankan.
- **PERINGATAN** boleh dibiarkan, tetapi baca dulu.
- Daftar lengkapnya ada di `.runtime/muat-ulang/prod-<waktu>/temuan.csv` (bisa dibuka di Excel,
  dengan nomor baris).
- Ulangi sampai muncul **BERKAS SIAP DIMUAT**, lalu catat jumlah dan total CB Net per status
  yang ditampilkan. Angka itu yang dicocokkan setelah pemuatan.

### Memisahkan baris bermasalah sebagai temuan

Untuk sumber gabungan, baris bergalat dapat dipisahkan alih-alih menghentikan pemuatan:

```
node scripts/muat-ulang-data.mjs --berkas <berkas.xlsx> --env prod --normalisasi-impor --lewati-galat \
  --izinkan-customer-tidak-ada --temuan-duplikat --temuan-xlsx outputs/<folder>/Temuan_<tanggal>.xlsx
```

- `--temuan-duplikat` menahan **semua salinan** klaim duplikat, bukan hanya salinan kedua:
  - No Document ganda;
  - Code Campaign + Cust Code + Cashback After Tax sama.

  Tambahkan flag ini bila yang benar tidak bisa ditentukan dari urutan baris.
- `--temuan-xlsx` menulis setiap baris yang tidak dimuat. Kolomnya sama dengan template,
  ditambah Remark yang memuat baris sumber dan alasannya.
- Dengan `--normalisasi-impor`, Abbr bergaris miring memakai bagian depannya, mis.
  `JKT/TU` → `JKT`.

Sebagai gambaran, data prod saat ini (7 Oktober 2026) menghasilkan 74 galat:

- Sel tanggal berisi `x`, `Maret-26`, dan `29-02-2026`.
- Email TO depot baris 20 berisi nama orang dan 5 alamat (maksimal 4).

## 4. Gladi di dev (disarankan sebelum prod)

```
node scripts/muat-ulang-data.mjs --berkas <berkas.xlsx> --env dev --jalankan --konfirmasi MUAT-ULANG-DEV
```

Buka http://localhost:5173 dan cek layar-layar utama:

- Document Center
- Management of Approval (dokumen Submitted)
- Release / Claim Process
- Report

Untuk mengembalikan dev ke isi sebelumnya:

```
node scripts/muat-ulang-data.mjs --env dev --pulihkan "<folder cadangan yang dicetak>" --konfirmasi PULIHKAN-DEV
```

## 5. Hari pelaksanaan di prod

1. **Umumkan jeda sekitar 15 menit.** Minta semua pengguna menyelesaikan pekerjaan dan keluar.
   Pertukaran memakan beberapa detik, tetapi aksi yang sedang berjalan akan tertahan.
2. **Periksa terakhir** dengan langkah 3 pada berkas final. Hasilnya harus BERKAS SIAP DIMUAT.
3. **Jalankan.** Kalimat konfirmasi memuat tanggal hari itu (WIB), mis. 7 Oktober 2026 →
   `MUAT-ULANG-PROD-20261007`:

   ```
   node scripts/muat-ulang-data.mjs --berkas <berkas.xlsx> --env prod --jalankan --konfirmasi MUAT-ULANG-PROD-<yyyymmdd>
   ```

   Urutan yang dikerjakan alat:
   1. Mencadangkan seluruh isi lama ke `.runtime/muat-ulang/prod-<waktu>/cadangan/`.
   2. Mengirim data ke tempat penampungan sementara.
   3. Mengosongkan dan memuat dalam **satu transaksi** yang memeriksa dirinya sendiri: jumlah
      dokumen, customer, dan campaign; total CB Net; jumlah per status; pemetaan depot; dan
      antrean Submitted. Kalau satu saja tidak cocok, seluruhnya dibatalkan dan data lama utuh.
   4. Menyegarkan dashboard publik.
4. **Cocokkan** angka per status yang dicetak di akhir dengan angka dari langkah 3.
5. **Cek di aplikasi** sebagai System Manager:
   - Document Center: jumlah per status.
   - Management of Approval: dokumen Submitted.
   - Release dan Claim Process.
   - Report Dashboard, dan dashboard publik (`/dashboard`).
6. **Minta pengguna memuat ulang halaman** (F5) sebelum bekerja lagi.

## 6. Kalau ada masalah

- **Pemuatan gagal** (pesan *DIBATALKAN - data lama utuh*): tidak ada yang berubah. Baca
  pesannya, perbaiki berkas, lalu ulangi.
- **Pemuatan sukses tetapi isinya ternyata salah:** kembalikan isi lama dari cadangan. Kalimat
  konfirmasi memakai tanggal hari pemulihan.

  ```
  node scripts/muat-ulang-data.mjs --env prod --pulihkan "<folder cadangan>" --konfirmasi PULIHKAN-PROD-<yyyymmdd>
  ```

  Pemulihan juga satu transaksi dan mengembalikan klaim, pelanggan, campaign, riwayat status,
  data sensitif, Exclude/Not Achieved, dan penghitung batch. Depot baru hasil muat ulang dibiarkan
  ada.
- **Cadangan manual saja**, tanpa memuat apa pun:

  ```
  node scripts/muat-ulang-data.mjs --env prod --cadangkan
  ```

## 7. Ganti klaim per depot saja

Untuk memperbaiki klaim beberapa depot tanpa mengosongkan seluruh database, pakai
[scripts/ganti-klaim-depot.mjs](../scripts/ganti-klaim-depot.mjs). Alat ini dipakai pertama kali
14 Oktober 2026 untuk depot 1P, 1Q, dan 1Y.

| Lembar | Perlakuan |
|---|---|
| **Ganti** (bawaan `Perbaikan nominal`) | Seluruh klaim depot yang muncul di lembar ini dihapus, lalu dimuat dari lembar ini. |
| **Tambah** (bawaan `Klaim`) | Baris depot lain dimuat sebagai dokumen baru. |

Kolom kedua lembar sama dengan lembar Klaim di template. Customer, campaign, dan depot tidak
disentuh.

Aturan pemuatannya:

- **Dokumen di dua lembar.** Baris lembar Tambah untuk depot Ganti dianggap versi perbaikan.
  Versi ini dipakai bila No Document, depot, customer, campaign, Cashback, dan Status-nya sama
  dengan baris di lembar Ganti. Kalau ada yang berbeda, kedua baris ditahan.
- **Jenis CB.** `Voucher` dimuat sebagai Voucher dan `Voucher Transfer` sebagai Transfer.
- **Customer belum ada di master.** Dokumen tetap dimuat sebagai *Customer Master belum ada*.
  Baris dengan galat lain ditulis ke Excel temuan.
- **Dokumen lama.** ID dan Created On-nya dipertahankan, riwayatnya diganti satu baris
  `muat_ulang`, dan dokumen Submitted kembali ke Management of Approval.
- **Dokumen yang akan hilang.** Pemuatan ditolak bila ada dokumen depot Ganti yang tidak dimuat
  kembali.

```
node scripts/ganti-klaim-depot.mjs --berkas <xlsx> --env prod --periksa --temuan-xlsx outputs/<folder>/Temuan.xlsx
node scripts/ganti-klaim-depot.mjs --berkas <xlsx> --env prod --uji
node scripts/ganti-klaim-depot.mjs --berkas <xlsx> --env prod --jalankan --konfirmasi GANTI-KLAIM-PROD-<yyyymmdd>
node scripts/ganti-klaim-depot.mjs --env prod --pulihkan "<folder hasil>" --konfirmasi PULIHKAN-KLAIM-PROD-<yyyymmdd>
```

- **`--periksa`** hanya membaca database.
- **`--uji`** menjalankan transaksi lengkap beserta seluruh pemeriksaannya, lalu
  membatalkannya. Tidak ada yang berubah.
- **`--jalankan`** mencadangkan seluruh isi lama ke `.runtime/ganti-klaim/<env>-<waktu>/cadangan/`
  lebih dulu.
- **`--pulihkan`** mengembalikan klaim depot Ganti dari cadangan, mencabut dokumen hasil pemuatan,
  dan mencabut pemetaan depot yang ditambahkan.

Gladi di dev pada 14 Oktober 2026 menjalankan muat → ganti → pulihkan → pulihkan. Hasil akhirnya
identik dengan dev semula (md5 klaim, data sensitif, riwayat, dan pemetaan).

## 8. Catatan teknis

- **Kebutuhan:** Node 18+, Python 3 dengan openpyxl (untuk membuat template/ekspor), dan
  `SUPABASE_ACCESS_TOKEN` di `.env`.
- **Target prod dikunci** ke `vvojshgcduqlugngpzkj`; alat berhenti kalau config menunjuk project
  lain.
- **Tempat penampungan sementara:** skema `rc_muat_ulang`, tanpa akses untuk pengguna aplikasi.
  Isinya dibersihkan setiap kali selesai.
- **Penghitung nomor batch** dinaikkan setinggi nomor yang dimuat, supaya batch yang terbit
  sesudahnya tidak bentrok.
- **Pembaca Excel:** SheetJS 0.18.5, versi yang sama dengan aplikasi, disimpan di
  `scripts/vendor/` dan diverifikasi dengan hash SRI resmi cdnjs.
