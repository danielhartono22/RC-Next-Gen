# Analisa CPU Prod RC Next Gen — 30-Okt-2026

Project prod: `vvojshgcduqlugngpzkj`. Pemeriksaan ini hanya membaca data (pg_stat_statements, pg_stat_activity, log edge/postgres). Tidak ada perubahan apa pun di prod.

## 1. Jawaban singkat

**CPU 100% bukan semata karena admin mengunduh Tanda Terima.** Document Generator memang sekarang modul yang paling sering dipanggil, tetapi setiap panggilannya ringan. CPU penuh datang dari **lonjakan di jam kerja**: beberapa layar berat dibuka bersamaan oleh banyak user, yaitu Dashboard, Compilation, Log Activity dan Workflow/Analytics. Di atasnya ada beban latar dari cron email (tiap menit) dan snapshot dashboard publik (tiap 5 menit). Server prod kecil (`max_connections` = 60, kemungkinan compute Nano/Micro), jadi 5–10 kueri berat yang jalan bersamaan sudah cukup membuat CPU penuh.

Buktinya: semua 14 kueri yang kena *statement timeout* hari ini berasal dari Dashboard, Compilation, Logs dan Email. **Tidak ada satu pun dari Document Generator.**

## 2. Bukti

### 2.1 Lalu lintas RPC 1 jam terakhir (07:08–08:08 UTC, total 632 panggilan)

| RPC | Panggilan | Catatan |
|---|---:|---|
| `rc_docgen_list` | 151 | daftar Tanda Terima, sekitar 1 s per panggilan |
| `rc_lookup_master` | 83 | cek Customer Master saat upload |
| `rc_log_context` | 51 | pencatat aktivitas, sangat ringan (25 ms) |
| `rc_docgen_generate` | 49 | unduh PDF, 200 toko sekitar 0,7 s |
| `rc_compilation_list` | 46 | Document Center |
| `rc_legacy_bootstrap` | 27 | login / muat awal |
| `rc_legacy_dashboard` | 27 | Dashboard, sekitar 1 s, pernah timeout |

Document Generator (list + generate) menyumbang sekitar 30% jumlah panggilan, tetapi hanya sekitar 6% waktu CPU satu core. Hitungannya: 151 × ±1,5 s = ±225 s per jam.

### 2.2 Pemakai waktu DB terbesar (kumulatif sejak reset statistik 14-Sep-2026, 46 hari)

| Kueri / fungsi | Total (detik) | Panggilan | Rata-rata | Maks |
|---|---:|---:|---:|---:|
| `rc_email_proses` (cron antrean email, tiap menit) | 39.089 | 57.150 | 684 ms | 32 s |
| `segarkan_dashboard_publik` (cron, tiap 5 menit) | 17.185 | 6.985 | 2.460 ms | 38 s |
| overhead PostgREST `set_config` | 7.758 | 431 jt | – | – |
| `rc_legacy_workflow` (halaman lanjutan, kursor) | 5.059 | 5.519 | 917 ms | 7,7 s |
| `rc_lookup_master` | 3.626 | 10.379 | 349 ms | 7,4 s |
| `rc_compilation_list` | 1.875 | 3.664 | 512 ms | 7,8 s |
| Workflow/Analytics halaman pertama (`p_limit` saja) | 1.363 | 1.043 | 1.307 ms | 6,7 s |
| `rc_docgen_list` (signature baru sejak 29-Okt) | 171 | 171 | 1.000 ms | 6,7 s |
| `rc_legacy_dashboard` | 136 | 130 | 1.043 ms | 4,7 s |
| `rc_docgen_generate` | – | – | – | tidak masuk 20 besar |

Rata-rata seluruh beban hanya sekitar 2% dari satu core. Jadi masalahnya bukan beban harian yang tinggi, tetapi **puncak sesaat** ketika banyak orang bekerja bersamaan.

### 2.3 Statement timeout hari ini (8 jam terakhir, 14 kejadian)

| Waktu (WIB) | RPC |
|---|---|
| 09:58, 10:04, 14:07 | `rc_legacy_logs` (Log Activity) |
| 10:52–10:54 (7 kejadian dalam 2 menit) | `rc_legacy_dashboard` ×4, `rc_compilation_list` ×2 |
| 11:01–11:02 | `rc_email_susun` ×2 (kirim email manual) |
| 11:30 | `rc_legacy_dashboard` |
| 12:37 | `rc_compilation_list` |
| 14:11 | `rc_dashboard_publik` |

Kumpulan pukul 10:52–10:54 WIB adalah tanda CPU jenuh. Kueri yang biasanya selesai dalam 1 s terantre sampai melewati batas 20 s.

### 2.4 Kondisi saat diperiksa

- 18 koneksi, 3 aktif, tidak ada kueri yang macet lama.
- Ukuran DB 191 MB, kecil.
- Cron aktif: `rc_email_antrean` (tiap menit), `rc_dashboard_publik_segar` (tiap 5 menit), `rc_email_tick` (menit ke-5 setiap jam).

## 3. Rekomendasi perubahan

Diurutkan dari dampak terbesar dengan risiko terkecil. Semua ke dev dulu, prod hanya setelah "transport".

### A. Beban latar yang selalu jalan (cepat, risiko rendah)

1. **`rc_email_proses` jangan bekerja kalau antrean kosong.** Sekarang rata-rata 684 ms tiap menit meskipun tidak ada email.
   - Tambahkan cek murah di awal fungsi: `if not exists (select 1 from antrean where status='menunggu' limit 1) then return`, didukung index parsial pada status menunggu.
   - Alternatif: jalankan tiap 2–5 menit, bukan tiap menit.
   - Perkiraan hemat: ~850 s CPU per hari.
2. **Snapshot dashboard publik.** Sekarang 2,46 s tiap 5 menit, sepanjang hari, termasuk malam dan hari libur.
   - Segarkan hanya di jam kerja (misal 07:00–19:00 WIB, Senin–Sabtu), atau naikkan intervalnya ke 10–15 menit.
   - Lebih baik lagi: segarkan hanya bila ada perubahan klaim sejak snapshot terakhir (bandingkan `max(updated_at)`).
   - Perkiraan hemat: 50–70% dari ~700 s per hari.

### B. Layar berat yang kena timeout

3. **Dashboard (`rc_legacy_dashboard`), sekitar 1 s, timeout saat ramai.**
   - Pakai pola yang sama dengan dashboard publik: snapshot per depot/region yang disegarkan berkala, lalu layar internal membaca snapshot itu.
   - Ini sejalan dengan aturan bahwa dashboard publik dan Report harus identik.
4. **Compilation (`rc_compilation_list`)**
   - Cek rencana kuerinya dengan `EXPLAIN ANALYZE` untuk filter campaign/batch/status/search yang paling sering dipakai.
   - Tambah index yang cocok (misal `claims(campaign_id, status)`, trigram untuk pencarian).
5. **Log Activity (`rc_legacy_logs`)**
   - Batasi rentang default (misal 7 hari terakhir) dan pakai paging berbasis kursor seperti `rc_legacy_workflow`.
   - Pastikan ada index pada `(created_at desc)`.
6. **Workflow / Analytics halaman pertama**, 1,3 s rata-rata.
   - Hitung `total` dari snapshot atau perkiraan, jangan `count(*)` penuh tiap kali halaman pertama dibuka.

### C. Document Generator (ringan per panggilan, tapi sering dipanggil)

7. **Kurangi panggilan list yang berulang.** 151 list berbanding 49 unduhan berarti setiap ketikan cari, ganti filter atau pindah halaman memanggil ulang server.
   - Tunda pencarian (debounce) 400–500 ms.
   - Simpan hasil halaman yang sama selama ±60 detik di browser.
   - Jangan memuat ulang daftar otomatis sesudah unduh. Cukup tandai baris yang sudah diunduh.
8. **Cache jumlah total / ringkasan per depot** selama beberapa menit, karena data Done/Not Yet tidak berubah tiap detik.

### D. Kapasitas

9. **Naikkan compute Supabase satu tingkat** (misal Micro → Small) bila puncak jam kerja tetap jenuh setelah poin A–C.
   - Biayanya bertambah, tetapi ini satu-satunya solusi yang langsung terasa tanpa perubahan kode.
   - Cek ukuran compute saat ini di Dashboard Supabase → Settings → Compute.
10. **Pantau puncak.** Lihat grafik CPU di Supabase → Reports → Database pada jam 10:00–12:00 WIB. Bandingkan sebelum dan sesudah perubahan A–C.

## 4. Usulan urutan kerja

| Tahap | Isi | Perkiraan dampak |
|---|---|---|
| 1 | A1 + A2 (cron email dan snapshot publik) | beban latar turun ±60% |
| 2 | C7 + C8 (Document Generator di sisi browser) | panggilan docgen turun ±50% |
| 3 | B3–B6 (index dan snapshot untuk Dashboard, Compilation, Logs, Workflow) | menghilangkan timeout saat ramai |
| 4 | D9 bila masih jenuh | – |

Setiap tahap: kerjakan di dev, uji (gladi + rollback di prod), lalu transport ke prod setelah disetujui.

## 5. Catatan

- Statistik pg_stat_statements bersifat kumulatif sejak 14-Sep-2026. Setelah perubahan, statistik bisa di-reset supaya perbandingan sebelum/sesudah lebih bersih.
- Token akses Supabase sempat ditempel di chat. Sebaiknya token itu diganti (rotate) di Supabase → Account → Access Tokens.
