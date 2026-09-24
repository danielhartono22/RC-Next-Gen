# Bahan untuk melengkapi audit Fase 0

Project Supabase `vvojshgcduqlugngpzkj` sudah terhubung melalui MCP dan kini ditetapkan sebagai **DEV** oleh pemilik; lihat [keputusan lingkungan](environments.md). Kedua backend sekarang sudah tersimpan dan diaudit; kekurangan job/trigger serta header/formula masih menghalangi pemetaan upload. Acuan: [instruksi migrasi](../System-Instruction-Migrasi-Claim-System-ke-Supabase.md) bagian 2 dan 12; [audit beserta keputusan D01–D12](phase-0-audit.md).

## 1. Backend sudah diterima; lengkapi metadata deployment

Kode berikut sudah tersedia di folder `D:\DANIEL\RC Next Gen` dan dibaca penuh. Tidak perlu membuat duplikat hanya untuk menyamakan nama lampiran:

| Backend | File yang diterima | Status |
|---|---|---|
| Resource Collection | `ResourceCollection`, pengganti `Pasted text.txt` | 70.781 byte, 1.558 baris; diaudit |
| Document Center | `DocumentCenter`, pengganti `Pasted code.js` | 23.281 byte, 502 baris; diaudit |

Kode RC lokal memilih `ENV="DEV"`; DC memakai Spreadsheet yang tercantum sebagai RC PROD untuk login/print/log. Konfirmasikan apakah sumber tersebut sama dengan versi deployment aktif. Jika ada file pendukung atau versi produksi yang berbeda, simpan sebagai sumber terpisah dengan nama project/versinya.

Buka project Apps Script yang melayani masing-masing frontend. Sertakan seluruh file `.gs`/`.js` yang dipanggil handler, nama file asal, manifest `appsscript.json`, dan informasi library/dependensi. Jika satu project memiliki banyak file, simpan per file dalam folder terpisah agar asal kode jelas. Catat apakah kode editor sama dengan versi deployment aktif; perbedaan versi perlu disimpan sebagai sumber terpisah.

Ganti nilai PIN/password, JWT secret, API secret, token dan kredensial tertanam dengan penanda `[REDACTED]`, dengan nama variabel dan struktur kode tetap terlihat. Jangan mengekspor isi Script Properties yang mengandung secret. Catat nama properti yang diperlukan tanpa nilainya.

## 2. Temukan pemindahan data setiap 15 menit

Periksa project Apps Script RC, Document Center, dan project terpisah yang digunakan untuk sinkronisasi. Cari fungsi yang membaca sheet `Upload` dan menulis ke tujuan Resource Collection. Sertakan semua helper, formula dan library yang dipanggil. Jika pemindahan ternyata dijalankan layanan lain, catat pelaksana dan kode/konfigurasinya; jangan mengasumsikan selalu Apps Script.

Lengkapi satu salinan formulir ini per job, memakai `UNKNOWN` bila belum ditemukan:

| Informasi | Nilai/bukti |
|---|---|
| Project/script ID dan pemilik | UNKNOWN |
| Versi kode/deployment yang aktif | UNKNOWN |
| Nama fungsi pemindahan dan file sumber | UNKNOWN |
| Trigger ID, pembuat/pemilik, fungsi target | UNKNOWN |
| Jadwal, interval, timezone, status aktif | UNKNOWN |
| Source Spreadsheet ID, sheet dan range | UNKNOWN |
| Sheet staging/perantara | UNKNOWN |
| Destination Spreadsheet ID, sheet dan range | UNKNOWN |
| Filter baris yang eligible | UNKNOWN |
| Checkpoint/watermark dan lokasi penyimpanan | UNKNOWN |
| Pembuatan No Document dan batch | UNKNOWN |
| Status awal, formula dan perhitungan angka | UNKNOWN |
| Kunci duplikasi dan update/append | UNKNOWN |
| Lock, overlap, timeout dan retry | UNKNOWN |
| Penanganan row gagal/invalid dan replay | UNKNOWN |
| Eksekusi terakhir berhasil/gagal, durasi, ringkasan error | UNKNOWN |
| Backlog dan timestamp pengukurannya | UNKNOWN |

Untuk setiap kolom tujuan, lengkapi mapping berikut dengan nama header aktual:

| Sheet/header sumber | Sheet/header tujuan | Transformasi/formula | Kondisi/null/duplikat | Lokasi fungsi/baris |
|---|---|---|---|---|
| UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN |

Metadata trigger dan execution logs diperlukan untuk mencocokkan kode dengan job yang benar-benar berjalan. Jangan menjalankan final sync, mengganti jadwal, atau menonaktifkan trigger saat pengumpulan bahan.

## 3. Header, formula dan sampel anonim

Inventaris wajib: `Compile`, `Authority`, `ListCampaign`, `ListCust`, `DepoMaster`, `LogActivity`, `ReqProfile`, `BatchLog`, `Upload`, `DM-30D`, `Depot_ID`, dan setiap sheet tambahan pada jalur sinkronisasi.

Untuk setiap sheet, sertakan nama file/tab, header sesuai urutan, contoh formula beserta posisi kolom, locale/timezone, tanggal snapshot, jumlah row, serta 20–50 contoh anonim lintas status/depot/campaign. Bila statistik null/duplikat/total belum tersedia, tandai belum diukur agar bisa dihitung dari sumber yang diizinkan.

Simpan identifier sebagai teks. Contoh anonim harus mempertahankan leading zero, tipe data, relasi antarsheet, null, serta kasus batas yang diperlukan untuk menguji aturan bisnis. Jangan menyertakan KTP/NPWP/rekening/nama pribadi asli atau PIN dalam bahan audit yang akan masuk repository. Data produksi penuh untuk migrasi kelak membutuhkan penyimpanan privat terpisah sesuai instruksi.

Sertakan juga contoh anonim file `Upload_CB`, hasil preview/submit, Excel cetak, dan PDF yang memang digunakan. Ini diperlukan untuk memeriksa perbedaan template sheet `Template` versus importer `Upload_CB`, kolom cetak yang kosong, dan paritas format.

## 4. Lingkungan dan keputusan pemilik

| Item | Status |
|---|---|
| Project Supabase DEV | `vvojshgcduqlugngpzkj`, terverifikasi dan ditetapkan pemilik |
| Project Supabase PROD | Belum ditetapkan; dipilih terpisah sebelum cutover |
| Repository/branch dan deployment GitHub Pages aktif | Belum tersedia |
| Backend RC dan DC lokal | Tersedia dan diaudit; paritas deployment aktif belum terverifikasi |
| Job sinkronisasi dan metadata | Belum tersedia |
| Header/data dictionary produksi | Belum tersedia |
| Backup/restore: owner, lokasi privat, RPO/RTO | Belum ditentukan |

Audit backend sudah memberi bukti untuk beberapa keputusan: partial accept dan key campaign/customer memang dipakai; nilai before-tax diteruskan dari file; gross-up backend berbeda dari frontend; Hold/Expired lebih luas di backend. Putuskan D01–D12 untuk perilaku target berdasarkan [audit backend](phase-0-backend-audit.md), header/formula dan job yang masih perlu dilengkapi. Jangan menggantikan bukti job yang hilang dengan tebakan.

## Kriteria bahan siap diperiksa

- File backend tersimpan dan berisi kode lengkap beserta dependensinya.
- Versi sumber dapat dicocokkan dengan deployment aktif.
- Job memiliki kode, mapping, trigger dan bukti eksekusi yang dapat dicocokkan.
- Header dan contoh anonim mempertahankan tipe/relasi yang diperlukan.
- Item yang belum diketahui tetap ditandai, tanpa keputusan implisit.

Prioritas berikutnya adalah kode job/trigger 15 menit, metadata deployment, header/formula dan sampel anonim. Sesudah bahan tersimpan, lanjutkan audit job serta rekonsiliasi mapping, lalu nilai kembali gerbang Fase 1. **Status saat ini: BLOCKED_BY_SYNC_INVENTORY.**
