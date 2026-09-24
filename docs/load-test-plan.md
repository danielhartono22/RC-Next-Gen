# Load & Stress Test Plan — Resource Collection

> **Historis — target ini digantikan 21 September 2026.** Target aktif: 1.000.000 klaim dummy,
> load sampai 1.000 VUs dan stress sampai 1.500 VUs, hanya staging terisolasi.
> Lihat [laporan dan runbook terbaru](performance-testing-2026-09-21.md).
> Skrip seed/load/provisioner lama dinonaktifkan. Angka di bawah bukan hasil run terbaru.

Ditulis untuk: Daniel dan siapa pun yang akan menjalankan pengujian serta meninjau arsitekturnya.

Disusun 20 September 2026. Seluruh angka baseline di dokumen ini adalah **hasil pengukuran
nyata** terhadap project `vvojshgcduqlugngpzkj`, bukan perkiraan. Pengukurannya hanya membaca —
tidak ada satu baris pun yang diubah.

---

## Ringkasan untuk yang tidak sempat membaca seluruhnya

**Pengujiannya belum dijalankan.** Syarat yang Anda tetapkan sendiri — "gunakan staging/test
project" — belum dapat dipenuhi: hanya ada satu project Supabase pada akun ini, dan project itu
berisi data yang dipakai depot. Menyuntikkan 275.600 dokumen palsu ke sana adalah hal yang Anda
larang, dan saya setuju itu tidak boleh dilakukan. Bagian 16 memuat langkah menyiapkan staging.

**Tetapi pengukuran baseline sudah dikerjakan, dan menemukan dua penghambat besar yang tidak
perlu menunggu load test untuk dipastikan.**

**Pertama, dan yang terbesar: ukuran balasan.** Login (`rc_legacy_bootstrap`) memindahkan
**1.148 KB** dan membuka dashboard memindahkan **1.484 KB** lagi — pada data 24 MB. Keduanya
membawa isi tabel apa adanya ke peramban: 2.756 dokumen dan 1.428 customer saat login, 2.711
baris riwayat saat dashboard. Biayanya tumbuh lurus. Pada volume 100x, **satu pengguna menarik
±266 MB hanya untuk masuk dan membuka layar pertama**; 300 pengguna di pagi hari berarti
**±78 GB**. Ini akan runtuh jauh sebelum penghambat kedua sempat terasa.

**Kedua: RLS memanggil fungsi per baris.** `count(*)` biasa atas 2.756 klaim memakan **67,7 ms**
dan menyentuh **14.385 halaman buffer** — dua puluh satu kali ukuran tabelnya. Perbaikannya sudah
diuji, diukur, dan **dibuktikan setara baris demi baris** (30 pasangan, 0 berbeda): **67,7 ms →
2,25 ms** untuk admin, **56,4 ms → 2,14 ms** untuk System Manager, dan rencananya berubah dari
Seq Scan menjadi Index Scan. Tidak perlu infrastruktur baru.

**Yang justru baik, dan layak disebut:** RPC yang ditulis untuk modul Report dan Timetable sudah
mengagregasi di server — `rc_report_dashboard` hanya 11 KB, `rc_cost_center` 24 KB,
`rc_timetable_matrix` 28 KB dalam 14 ms. Dugaan saya sebelumnya bahwa `cross join` Timetable akan
menjadi masalah **keliru**; ia justru yang tercepat. Yang berat adalah RPC kompatibilitas warisan.

**Jawaban sementara atas pertanyaan utama Anda** — apakah Supabase + Vercel sanggup 300 pengguna
dengan data 100x — adalah: **belum, dalam bentuknya sekarang; sangat mungkin, sesudah dua
perbaikan yang tidak menambah biaya infrastruktur.** Kepastiannya tetap menunggu pengujian
sungguhan. Bagian 15 menjelaskan mengapa saya tidak menyimpulkan lebih jauh dari itu.

---

## 1. Test Plan

### 1.1 Yang diuji dan tidak diuji

| Lapisan | Diuji | Catatan |
|---|---|---|
| Vercel (frontend) | Ringan | **Tidak ada serverless function sama sekali.** Isi `public/` hanya `index.html` (676 KB) dan aset 44 KB. Semuanya statis, dilayani CDN. |
| Supabase Auth | Ya | Login 300 pengguna, termasuk serentak. |
| PostgREST (RPC) | Ya | Seluruh 58 action aplikasi bermuara ke sini. |
| PostgreSQL | Ya | Inti pengujian. Di sinilah seluruh beban mendarat. |
| pg_cron + pg_net (email) | Ya, tanpa kirim | Diukur lewat antrean, bukan pengiriman. |
| Gmail API | **Tidak** | Tidak ada email sungguhan dikirim. Lihat bagian 7-G. |

Konsekuensi penting dari baris pertama: **Vercel bukan penghambat pada arsitektur ini.** Tidak
ada function timeout, tidak ada cold start, tidak ada batas eksekusi serverless — karena tidak
ada serverless. Peramban berbicara langsung ke Supabase. Seluruh risiko terkumpul di satu
tempat, dan itu memudahkan sekaligus memperberat: tidak ada lapisan yang dapat menyerap lonjakan.

### 1.2 Lingkungan

| | Produksi (diukur) | Staging (harus disiapkan) |
|---|---|---|
| Project | `vvojshgcduqlugngpzkj` | belum ada |
| Postgres | 17.6.1 | samakan |
| `max_connections` | **60** | samakan, lalu uji juga di tier lebih besar |
| `shared_buffers` | 224 MB | samakan |
| `work_mem` | 2.184 kB | samakan |
| `statement_timeout` | 120 detik | samakan |
| Region | ap-southeast-1 | samakan |
| Ukuran DB | 24 MB | ±2,4 GB sesudah seed |

### 1.3 Urutan pelaksanaan

1. Siapkan staging (bagian 16).
2. Jalankan A (baseline) di staging **sebelum** seed — untuk membuktikan staging setara produksi.
3. Jalankan seed 100x. `ANALYZE` wajib sesudahnya.
4. Jalankan A lagi — inilah baseline sesungguhnya untuk dibandingkan.
5. B (load) → D (concurrency) → E (spike) → F (endurance).
6. Terapkan perbaikan dari bagian 11-13 **satu per satu**, ulangi B setiap kali.
   Satu perubahan per pengukuran; kalau tiga diterapkan bersamaan dan hasilnya membaik, tidak
   ada yang tahu mana yang bekerja dan mana yang justru merugikan.

---

## 2. Dataset Scaling Plan

Skrip: `scripts/loadtest/seed-100x.sql`

### 2.1 Baseline nyata (diukur 20 September 2026)

| Tabel | Baris | Ukuran |
|---|---:|---|
| claims | 2.756 | 5.368 kB |
| claim_sensitive | 2.757 | 512 kB |
| claim_status_history | 2.857 | 720 kB |
| customers | 2.067 | 1.240 kB |
| customer_depots | 1.428 | 320 kB |
| campaigns | 100 | 144 kB |
| depots | 52 | 176 kB |
| activity_logs | 185 | 160 kB |
| profiles | 6 | — |
| **Total database** | | **24 MB** |

### 2.2 Sasaran

| Tabel | Sekarang | Sasaran | Kelipatan | Alasan |
|---|---:|---:|---:|---|
| claims | 2.756 | 275.600 | 100x | transaksi |
| claim_sensitive | 2.757 | 275.600 | 100x | satu per klaim |
| claim_status_history | 2.857 | ±826.000 | ±290x | rata-rata 3 baris per dokumen |
| customers | 2.067 | 206.700 | 100x | transaksi |
| customer_depots | 1.428 | ±250.000 | 175x | pemetaan |
| activity_logs | 185 | 500.000 | — | jejak 300 pengguna berbulan-bulan |
| campaigns | 100 | 500 | 5x | **bukan 100x** |
| depots | 52 | 60 | 1,15x | **bukan 100x** |
| profiles | 6 | 300 | 50x | sesuai target concurrency |

**Depot dan campaign sengaja tidak dikalikan 100.** Depot adalah bangunan fisik; campaign adalah
program yang dirancang orang. Menjadikannya 5.200 depot akan menghasilkan basis data yang tidak
mungkin ada, dan lebih buruk lagi: matriks Timetable 5.200 × 10.000 akan runtuh karena alasan
yang tidak akan pernah terjadi di kenyataan, menyembunyikan penghambat yang nyata.

### 2.3 Mengapa distribusi, bukan penggandaan

Menggandakan baris yang sama 100 kali menghasilkan basis data yang **selalu lebih cepat daripada
kenyataan**, dan uji di atasnya akan lulus dengan gemilang lalu runtuh di hari pertama dipakai:

- Nilai yang berulang membuat statistik planner menganggap selektivitas jauh lebih tinggi
  daripada sebenarnya, sehingga rencana yang dipilih bukan rencana yang akan dipakai produksi.
- Satu depot yang sama membuat seluruh indeks memusat di beberapa halaman; di kenyataan
  barisnya tersebar dan setiap pembacaan menyentuh halaman berbeda.
- Cache menjadi sangat efektif secara palsu.

Yang ditiru skrip seed:

| Sifat | Cara |
|---|---|
| Kemiringan antardepot | Distribusi pangkat (`power(random(), 2.2)`) — sepuluh depot teratas memegang porsi terbesar, seperti sekarang |
| Sebaran status | done 42%, not_yet 30%, released 16%, claimed 11%, sisanya kecil — perbandingan produksi |
| Nilai cb_net | Lognormal kasar, bukan angka bulat berulang |
| Tanggal | Tersebar 24 bulan ke belakang |
| Kedalaman riwayat | Dokumen `done` punya 4 baris riwayat; `not_yet` hanya 0 |
| Nama toko | Kombinasi kata, supaya pencarian ILIKE benar-benar harus bekerja |

`ANALYZE` di akhir skrip **wajib**. Tanpa itu planner masih memakai statistik 2.756 baris dan
seluruh pengukuran mengukur hal yang salah.

---

## 3. Load Test Scenario

Skrip: `scripts/loadtest/rc-loadtest.js` (k6)

```
k6 run -e BASE=https://<ref-staging>.supabase.co \
       -e KEY=<anon key staging> \
       -e SKENARIO=load \
       scripts/loadtest/rc-loadtest.js
```

Skrip menolak berjalan bila `BASE` menunjuk ref produksi.

### 3.1 Tangga beban

| Tahap | VU | Naik | Tahan |
|---|---:|---|---|
| 1 | 50 | 1 menit | 4 menit |
| 2 | 100 | 1 menit | 4 menit |
| 3 | 150 | 1 menit | 4 menit |
| 4 | 200 | 1 menit | 4 menit |
| 5 | 250 | 1 menit | 4 menit |
| 6 | 300 | 1 menit | 4 menit |

Tiap anak tangga ditahan 4 menit supaya P95 dan P99-nya bukan riak sesaat. Total ±30 menit.

### 3.2 Campuran aktivitas per putaran

Bobotnya sengaja tidak rata. Di dunia nyata orang membuka layar jauh lebih sering daripada
mengunggah; membuat setiap VU mengunggah menghasilkan beban yang tidak pernah terjadi.

| Aktivitas | RPC | Peluang | Peran |
|---|---|---:|---|
| Login | `/auth/v1/token` | 100% | semua |
| Bootstrap + dashboard | `rc_legacy_bootstrap`, `rc_legacy_dashboard` | 100% | semua |
| Cari / filter | `rc_open_claims` | 100% | semua |
| Buka detail | `rc_legacy_documents` | 100% | semua |
| Upload batch | `rc_periode_dokumen`, `rc_process_claims` | 25% | admin |
| Approval list | `rc_legacy_workflow` | 100% | osc ke atas |
| Approve / reject | `rc_process_claims` | 100% | osc ke atas |
| Claim & clearing | `rc_process_claims` | 100% | osc ke atas |
| Report | `rc_report_dashboard` | 40% | yang punya izin |
| Timetable | `rc_timetable_matrix` | 20% | yang punya izin |

Jeda berpikir 3–9 detik antar putaran. Tanpa jeda, tiap VU menjadi mesin pemukul, bukan tiruan
orang, dan hasilnya tidak dapat dibandingkan dengan apa pun.

### 3.3 Ukuran batch

Diuji terpisah lewat `-e BATCH=<n>` pada beban tetap 100 VU: **10, 25, 50, 100, 500**.
Yang dicari: apakah waktunya tumbuh lurus, atau ada titik patah.

---

## 4. Concurrency Matrix

Dijalankan dengan `SKENARIO=concurrency` (`constant-arrival-rate`, 120 permintaan/detik selama
5 menit). Yang diuji laju permintaan, bukan jumlah orang.

| # | Kondisi | Yang diintai | Cara mendeteksi |
|---|---|---|---|
| C1 | 300 login serentak | Batas laju Auth, kelelahan koneksi | HTTP 429, 503 |
| C2 | 300 dashboard serentak | Saturasi CPU database | P99 dashboard, `pg_stat_activity` |
| C3 | 300 pencarian serentak | Seq scan pada customers | `seq_tup_read` melonjak |
| C4 | 20–50 upload hampir serentak | **Race condition nomor dokumen** | duplikat `no_doc`, galat unique |
| C5 | 50 approver membuka approval list | Baca berat berulang | P95 `rc_legacy_workflow` |
| C6 | Dua pengguna meng-claim dokumen yang sama | **Lost update / double approval** | `version_no` dan `claim_status_history` |
| C7 | Submit ganda dokumen yang sama | **Duplicate submission** | tabel `rc_private.requests` (idempotensi) |
| C8 | Report + Timetable serentak | Agregasi mahal bersamaan | P99, `temp_blks_written` |

### 4.1 Audit jalur tulis — sudah dikerjakan

Seluruh fungsi yang menulis ke `public.claims` sudah diperiksa kodenya. Hasilnya **jauh lebih
baik daripada dugaan awal saya**, dengan satu celah nyata.

| Risiko | Penjagaan yang ada | Penilaian |
|---|---|---|
| Duplicate submission | `rc_private.requests` PK `(actor_id, request_id)`, lalu `select … for update` dan mengembalikan hasil yang tersimpan | **Benar.** Permintaan kedua memblokir pada kunci baris, lalu menerima jawaban yang sama — bukan galat, bukan pemrosesan ganda. Payload yang berbeda dengan request_id sama pun ditolak |
| Lost update | `select … for update` + `version_no <> …` → SQLSTATE **40001** | **Benar**, termasuk kode SQLSTATE-nya, yang dikenali klien sebagai layak diulang |
| Double approval | Kunci baris yang sama | **Benar.** Approver kedua memblokir, lalu gagal pada pemeriksaan versi |
| Nomor batch/dokumen ganda | `INSERT … ON CONFLICT DO UPDATE … RETURNING` pada `batch_counters` dan `document_counters` | **Benar, dan atomik.** Penghitungnya pun **per pengguna** (suffix dari profil), jadi antarpengguna tidak berebut baris. Terukur 19,66 ms per panggilan, sekali per batch |
| Deadlock urutan kunci | `mutate_claims_unchecked` memakai `order by value->>'no_doc'` | **Benar di jalur utama** — dan inilah yang justru menunjukkan celahnya |

**Celah yang ditemukan.** Dua fungsi yang ditambahkan belakangan mengunci per baris **tanpa
urutan**:

```
rc_posting_exception     for r in select value from jsonb_array_elements(p_rows) loop
rc_reprocessing_upload   for r in select value from jsonb_array_elements(p_rows) loop
```

Pola pengamannya sudah ada di sebelahnya, hanya tidak ikut terbawa. Dua transaksi yang menyentuh
dokumen sama dengan urutan berbeda dapat saling menunggu; Postgres mematikan salah satunya dengan
SQLSTATE 40P01. Tidak ada data yang rusak, tetapi satu pengguna melihat kegagalan yang tidak
dapat ia jelaskan.

Perbaikannya **satu baris untuk masing-masing**: `scripts/loadtest/usulan-urutan-kunci.sql`.

Yang masih harus dibuktikan lewat beban sungguhan — karena tidak dapat dibuktikan dari membaca
kode — adalah **perilakunya di bawah tekanan**: seberapa sering 40001 terjadi, dan apakah kunci
pada `rc_private.requests` menjadi antrean ketika banyak orang mengirim bersamaan.
| Pendaftaran serentak | `handle_new_user()` melakukan `lock table public.profiles in exclusive mode` | Pendaftaran **terserialisasi sepenuhnya** — satu per satu, menunggu giliran. Untuk pendaftaran nyata yang jarang ini tidak masalah, tetapi pembuatan 300 akun uji akan berjalan berurutan, dan itu perlu diketahui agar tidak disalahartikan sebagai sistem yang lambat |
| Duplicate claim | `no_doc` UNIQUE | Sudah kuat; yang diuji pesannya, bukan pencegahannya |

Kesimpulan audit ini pantas dinyatakan terang-terangan: **masalah sistem ini ada pada kinerja
dan ukuran balasan, bukan pada kebenaran jalur tulisnya.** Rancangan penulisannya benar, dan satu
celah yang ditemukan pun sudah punya polanya sendiri di dalam kode yang sama.

---

## 5. Metrics to Monitor

### 5.1 Dari k6

| Metrik | Arti |
|---|---|
| `rc_login`, `rc_dashboard`, `rc_cari`, … | P50/P95/P99 **per aktivitas** |
| `rc_error_rate` | Kegagalan sungguhan |
| `rc_konflik_versi` | Lost update tertangkap — **bukan** kegagalan |
| `rc_duplikat_ditolak` | Idempotensi bekerja — **bukan** kegagalan |
| `rc_http_429`, `rc_http_5xx` | Batas laju dan kegagalan server |

Konflik versi dan duplikat dihitung terpisah dari error rate. Keduanya justru **tanda sistem
bekerja benar**; mencampurnya ke error rate akan membuat perlindungan yang berhasil terlihat
seperti kerusakan.

### 5.2 Dari Postgres

```sql
-- Query termahal, diurutkan menurut total waktu
select calls, round(mean_exec_time::numeric,2) rata_ms,
       round(max_exec_time::numeric,1) max_ms, rows,
       left(regexp_replace(query,'\s+',' ','g'),120) q
from pg_stat_statements order by total_exec_time desc limit 20;

-- Seq scan yang seharusnya tidak terjadi
select relname, seq_scan, seq_tup_read, idx_scan, n_live_tup
from pg_stat_user_tables where seq_tup_read > 0 order by seq_tup_read desc;

-- Kelelahan koneksi
select state, count(*) from pg_stat_activity group by state;
select count(*) dipakai, current_setting('max_connections') maks from pg_stat_activity;

-- Antrean kunci
select bl.pid, a.query, now()-a.query_start lama
from pg_locks bl join pg_stat_activity a on a.pid=bl.pid
where not bl.granted;

-- Cache hit ratio — di bawah 0,99 berarti shared_buffers kekecilan untuk volumenya
select sum(heap_blks_hit)/nullif(sum(heap_blks_hit+heap_blks_read),0) from pg_statio_user_tables;
```

Jalankan `select pg_stat_statements_reset();` **sebelum** tiap tahap, supaya angkanya milik
tahap itu saja.

### 5.3 Dari Supabase Dashboard

CPU, memori, IOPS, jumlah koneksi, dan statistik Supavisor. Tangkap layarnya di puncak tiap
anak tangga — angka-angka ini tidak tersimpan lama.

---

## 6. Bottleneck Detection — temuan yang SUDAH ADA

Ini bukan dugaan. Ketiganya terukur pada produksi hari ini, pada volume 24 MB.

### 6.0 Balasan RPC warisan membawa seluruh tabel — **penghambat nomor satu**

Terukur, bukan dugaan (rincian angka di bagian 7.1):

| | Sekarang | Proyeksi 100x |
|---|---:|---:|
| Login | 1.148 KB | ±122 MB |
| Dashboard | 1.484 KB | ±145 MB |
| Satu pengguna | 2,6 MB | **±266 MB** |

Sebabnya bentuk kontraknya, bukan query-nya: `rc_legacy_bootstrap` dan `rc_legacy_dashboard`
mengembalikan isi tabel apa adanya karena itulah yang dilakukan backend Apps Script lama, dan
migrasinya sengaja meniru kontrak itu field demi field supaya tidak ada layar yang perlu diubah.
Keputusan itu benar untuk migrasinya, dan sekarang menjadi batas pertumbuhannya.

Pemisahnya jelas terlihat: RPC yang ditulis baru untuk Report dan Timetable mengagregasi di
server dan balasannya 11-28 KB. Yang warisan membawa 678-1.484 KB. Yang perlu diubah hanya
kelompok kedua, dan hanya empat fungsi.

Perbaikannya di bagian 13. Ini **tidak** menuntut infrastruktur baru; ia menuntut perubahan pada
layar yang memanggilnya, jadi lebih besar pekerjaannya daripada 6.1 — tetapi dampaknya lebih besar.

### 6.1 RLS memanggil fungsi per baris — **penghambat nomor dua**

```
Seq Scan on claims  (actual time=1.078..67.045 rows=2754)
  Filter: ((archived_at IS NULL) AND rc_private.can_access(depot_id, NULL::text))
  Buffers: shared hit=14385
Execution Time: 67.714 ms
```

Tabel `claims` berukuran 5.368 kB (±671 halaman). Query ini menyentuh **14.385 halaman** — dua
puluh satu kali ukuran tabelnya. Sebabnya `can_access()` dipanggil sekali per baris, dan setiap
panggilan melakukan pencariannya sendiri.

Bekasnya terbaca jelas:

```
user_permissions   seq_scan = 239.810.352   baris dibaca = 51.319.268.378   (tabel 19 baris)
profiles           idx_scan = 242.142.951
claims             idx_scan = 120.008.808
```

**Sebuah tabel berisi 19 baris di-scan 240 juta kali.**

Biayanya tumbuh lurus: 67,7 ms ÷ 2.754 baris = 24,6 µs per baris. Pada 275.600 baris,
`count(*)` yang sama diperkirakan **±6,8 detik** — sebelum satu pun join atau agregasi.

**Sudah diuji perbaikannya** (lalu dibatalkan, produksi tidak berubah):

```
Index Scan using claims_campaign_idx on claims  (actual time=0.452..2.051 rows=2754)
  Index Cond: (depot_id = ANY (rc_private.depot_saya()))
  Buffers: shared hit=619
Execution Time: 2.251 ms
```

| | Sebelum | Sesudah | |
|---|---:|---:|---|
| Waktu | 67,714 ms | **2,251 ms** | 30x |
| Halaman | 14.385 | **619** | 23x |
| Rencana | Seq Scan | **Index Scan** | tidak lagi tumbuh lurus |

Perbaikan lengkap: `scripts/loadtest/usulan-optimasi-rls.sql` — **belum diterapkan**.

### 6.2 Indeks pencarian salah jenis

`customers_name_idx` adalah GIN **tsvector**. Tujuh RPC mencari dengan `ILIKE '%kata%'`:
`rc_campaign_list`, `rc_compilation_list`, `rc_customer_list`, `rc_depot_list`, `rc_list_claims`,
`rc_open_claims`, `rc_reprocessing_list`.

Indeks tsvector **tidak dapat melayani pola itu**. Buktinya di `pg_stat_user_indexes`: dipakai
**0 kali** sejak dibuat, sementara `customers` tetap ter-seq-scan. Pada 206.800 baris setiap
pencarian akan membaca seluruh tabel. `pg_trgm` **belum terpasang**.

### 6.3 `max_connections = 60`

Ini yang menentukan batas atas concurrency, bukan CPU.

Perhitungan kasar: 300 pengguna dengan jeda 5 detik ≈ 60 permintaan/detik. Bila tiap permintaan
memakan 400 ms di database, dibutuhkan ±24 koneksi serentak — masih di bawah 60. **Tetapi bila
satu permintaan naik menjadi 3 detik** (yang akan terjadi pada volume 100x tanpa perbaikan 6.1),
kebutuhannya menjadi ±180 koneksi. Koneksi habis, dan yang terlihat di layar adalah timeout,
bukan "lambat".

Jadi 6.1 dan 6.3 adalah masalah yang sama dilihat dari dua sisi: **memperbaiki durasi query
adalah cara termurah menaikkan batas concurrency.**

---

## 7. Database Query Analysis

Dari `pg_stat_statements` produksi (bukan sintetis):

| RPC | Panggil | Rata-rata | Puncak | Catatan |
|---|---:|---:|---:|---|
| `rc_legacy_bootstrap` | 87 | **341,8 ms** | 925,8 ms | Login. Gerbang pertama 300 pengguna. |
| `rc_legacy_dashboard` | 70 | **403,3 ms** | 1.075,9 ms | Terberat. |
| `rc_legacy_workflow` | 44 | 222,1 ms | 482,7 ms | Approval list. |
| RPC tulis (submit/release/claim) | 55 | 248,9 ms | 523,3 ms | |
| `rc_email_tick` | 38 | 72,2 ms | 143,6 ms | pg_cron, tiap jam |

**Pada 24 MB data, login sudah memakan 342 ms rata-rata.** Itu titik awal yang sempit. Dengan
300 orang masuk dalam satu menit pagi hari — pola yang sangat mungkin terjadi — inilah yang
pertama menyerah.

### 7.1 Ukuran balasan — diukur, dan inilah penghambat terbesar

Waktu saja menyesatkan. Yang menentukan pada arsitektur ini adalah **berapa besar yang dikirim**:

| RPC | Waktu | Balasan | Isi |
|---|---:|---:|---|
| `rc_legacy_bootstrap` | 316 ms | **1.148 KB** | documents 839 KB (2.756 baris) + customers 280 KB (1.428) + campaigns 24 KB |
| `rc_legacy_dashboard` | 337 ms | **1.484 KB** | history 1.070 KB (2.711 baris) + compileData 414 KB |
| `rc_legacy_workflow` | 220 ms | 678 KB | antrean approval |
| `rc_legacy_documents` | 119 ms | 839 KB | seluruh dokumen |
| `rc_report_dashboard` | 191 ms | **11 KB** | sudah diagregasi server |
| `rc_cost_center` | 141 ms | 24 KB | sudah diagregasi server |
| `rc_timetable_matrix` | **14 ms** | 28 KB | sudah diagregasi server |

Proyeksi 100x, dihitung dari biaya per baris yang terukur:

| | Sekarang | 100x |
|---|---:|---:|
| Login (`bootstrap`) | 1,1 MB | **±122 MB** |
| Dashboard | 1,5 MB | **±145 MB** |
| **Satu pengguna, login + layar pertama** | 2,6 MB | **±266 MB** |
| **300 pengguna** | 0,8 GB | **±78 GB** |

Angka terakhir bukan sekadar soal bandwidth. Postgres harus **menyusun dokumen JSON 122 MB di
memori** dengan `work_mem` 2.184 kB — ia akan tumpah ke disk — lalu PostgREST harus menampungnya
sebelum mengirim. Pada 300 pengguna serentak, inilah yang menyerah lebih dulu, bukan CPU dan
bukan RLS.

### 7.2 Yang perlu di-`EXPLAIN` di staging

1. `rc_legacy_dashboard` dan `rc_legacy_bootstrap` — keduanya karena ukuran, bukan waktu
2. `rc_report_dashboard` dan `rc_cost_center` — agregasi lintas seluruh klaim; kecil balasannya,
   tetapi kerjanya menyentuh seluruh tabel

`rc_timetable_matrix` **tidak** masuk daftar. Dugaan awal saya bahwa `cross join`-nya akan
bermasalah terbantah oleh pengukuran: 14 ms dan 28 KB, yang tercepat dari semuanya.

---

## 8. API / Edge Function Analysis

Tidak ada Edge Function dan tidak ada API route. Seluruh 58 action aplikasi adalah RPC PostgREST
ke fungsi Postgres. Karena itu:

- Tidak ada cold start.
- Tidak ada batas waktu eksekusi function.
- **Latensi API = latensi database + perjalanan jaringan.** Tidak ada tempat lain untuk
  disalahkan, dan tidak ada tempat lain untuk memperbaiki.

Yang perlu diperhatikan pada PostgREST:

| Hal | Keadaan | Risiko |
|---|---|---|
| `statement_timeout` | 120 detik | Terlalu longgar. Query 120 detik menahan koneksi selama itu; pada 300 pengguna, beberapa query seperti itu cukup untuk menghabiskan kolam koneksi. |
| Ukuran balasan | `rc_legacy_documents` mengembalikan hingga 20.000 dokumen sekaligus | Pada 100x ini menjadi balasan JSON puluhan MB **per pemanggilan** |
| Kolam koneksi | Default Supavisor | Perlu diperiksa di dashboard; inilah pengali sesungguhnya dari `max_connections` |

Baris kedua adalah masalah tersendiri dan dibahas di bagian 13.

---

## 9. Vercel Performance Analysis

**Vercel bukan penghambat pada arsitektur ini, dan tidak perlu diuji berat.**

| | |
|---|---|
| Serverless function | **Tidak ada** — tidak ada folder `api/`, tidak ada konfigurasi `functions` |
| Yang dilayani | `index.html` 676 KB + aset 44 KB, seluruhnya statis |
| Pelayanan | CDN, di-cache di tepi |
| Batas yang berlaku | Bandwidth, bukan eksekusi |

300 pengguna × 676 KB muat pertama ≈ 200 MB — dan hanya untuk muat pertama; sesudahnya dari
cache. Ini sepele bagi CDN mana pun.

Satu hal yang pantas diperbaiki, meski bukan soal beban: **676 KB dalam satu berkas HTML**.
Dengan gzip menjadi ±120 KB, masih besar untuk jaringan depot yang lambat. Ini soal waktu muat
pertama bagi satu orang, bukan soal kemampuan menahan 300 orang — jadi jangan dicampur ke
dalam hasil load test.

Yang tetap perlu diperiksa saat pengujian: header `Cache-Control` pada `index.html`. Bila
halamannya ikut ter-cache lama, pembaruan tidak sampai ke depot; bila tidak ter-cache sama
sekali, 300 pengguna menariknya berulang kali.

---

## 10. Supabase Performance Analysis

| Parameter | Nilai terukur | Penilaian |
|---|---|---|
| `max_connections` | 60 | **Batas nyata concurrency.** Lihat 6.3 |
| `shared_buffers` | 224 MB | Cukup untuk 24 MB; **pada 2,4 GB tidak lagi muat** |
| `effective_cache_size` | 384 MB | Idem |
| `work_mem` | 2.184 kB | Kecil untuk agregasi laporan; akan tumpah ke disk |
| `statement_timeout` | 120 detik | Terlalu longgar (lihat bagian 8) |
| Postgres | 17.6.1 | Mutakhir |
| Region | ap-southeast-1 | Tepat untuk Indonesia |

Ukuran `shared_buffers` 224 MB menunjukkan instance compute kecil. **Pada dataset 2,4 GB, hanya
sekitar sepersepuluh yang muat di cache.** Cache hit ratio akan turun, dan pembacaan disk
menjadi penentu — inilah yang tidak akan terlihat pada pengujian dengan data 24 MB, dan alasan
utama mengapa seed 100x tidak boleh dilewati.

Urutan yang saya sarankan: **perbaiki query dulu, ukur lagi, baru pertimbangkan menaikkan
compute.** Menaikkan compute lebih dulu akan menutupi 6.1, dan biayanya berjalan tiap bulan
sementara perbaikan query hanya sekali.

---

## 11. Recommended Indexes

Semuanya ada di `scripts/loadtest/usulan-optimasi-rls.sql`, bagian 4. Terapkan dengan
`CREATE INDEX CONCURRENTLY` supaya tidak mengunci tabel.

| Indeks | Menolong | Dasar |
|---|---|---|
| `customers_nama_trgm_idx` (GIN trgm) | Pencarian toko | `customers_name_idx` terbukti dipakai 0 kali |
| `customers_kode_trgm_idx` | Pencarian kode toko | idem |
| `claims_no_doc_trgm_idx` | Pencarian No Doc | dipakai 7 RPC |
| `campaigns_nama_trgm_idx` | Pencarian campaign | idem |
| `claims_not_yet_idx` (parsial) | Tab Open, compile | Not Yet hanya ±30% baris |
| `claims_antrean_idx` (parsial) | Release, Claim, Clearing | menghindari baris terarsip |

Yang dapat **dilepas** sesudah trigram terbukti dipakai: `customers_name_idx` (200 kB, 0 kali
dipakai). Juga pantas ditinjau: `claim_status_history_claim_aksi_idx` (160 kB, 0 kali) — indeks
yang saya tambahkan 19 September dan ternyata belum pernah terpakai.

Semua indeks trigram berbiaya tulis. Pada volume upload 50 dokumen per batch biayanya kecil,
tetapi ukurlah kembali waktu upload sesudah memasangnya — jangan diandaikan.

---

## 12. Recommended RLS Optimization

Inti perbaikannya sudah dijelaskan di 6.1 dan diukur. Ringkasnya:

**Jangan** memanggil fungsi yang menerima nilai dari baris di dalam kebijakan RLS. Panggilan
seperti itu berjalan sekali per baris, selamanya, dan biayanya tumbuh lurus terhadap data.

**Sebagai gantinya**, hitung sekali apa yang boleh dilihat pemanggil, lalu uji keanggotaan:

```sql
-- sebelum: dipanggil sekali per baris
using (archived_at is null and rc_private.can_access(depot_id))

-- sesudah: dipanggil sekali per query, sisanya uji keanggotaan larik
using (archived_at is null and depot_id = any(rc_private.depot_saya()))
```

Perlu ditegaskan karena sering disalahpahami: trik `(select fn())` yang biasa disarankan
**tidak cukup di sini**. Trik itu hanya bekerja bila argumennya tetap. `can_access(depot_id)`
menerima nilai dari baris, jadi ia tetap dipanggil per baris betapapun dibungkus. Yang berhasil
adalah menghilangkan ketergantungannya pada baris — itulah yang dilakukan `depot_saya()`.

Untuk kebijakan yang argumennya memang tetap, `(select ...)` sudah memadai:

```sql
alter policy campaigns_scope on public.campaigns
  using ((select rc_private.can_access(null::uuid)));
```

### Kesetaraan sudah dibuktikan

`scripts/loadtest/bukti-setara-rls.sql` membandingkan **himpunan id yang terlihat** — lewat sidik
md5 atas daftar id terurut, bukan sekadar jumlah baris, karena dua himpunan berbeda bisa
berjumlah sama — antara kebijakan lama dan kebijakan usulan, untuk **6 akun × 5 tabel**.

Hasil terakhir: **30 setara, 0 berbeda.**

Tiga keadaan tepi ikut diuji dan ketiganya melihat nol baris sebagaimana seharusnya: pengguna
tanpa depot (IQBAL), pengguna nonaktif, dan pengguna yang wajib ganti PIN.

Pengukuran pada kedua jalur peran:

| Peran | Sebelum | Sesudah | Halaman |
|---|---:|---:|---|
| Admin, 4 depot | 67,714 ms | **2,251 ms** (30×) | 14.385 → 619 |
| System Manager, 52 depot | 56,354 ms | **2,139 ms** (26×) | 6.123 → 617 |

**Bukti itu menangkap satu cacat pada rancangan awal.** Kebijakan `logs_scope` versi pertama
kehilangan 40 baris `activity_logs` yang `depot_id`-nya NULL — kejadian lintas depot seperti
`access_changed`, `akun_dihapus`, `role_changed`. Sebabnya `NULL = apa pun` bernilai NULL, bukan
true. `activity_logs.depot_id` adalah satu-satunya kolom `depot_id` di seluruh skema yang boleh
NULL. Selisih itu **tidak akan terlihat dari membaca kebijakannya**, dan itulah gunanya
membuktikan alih-alih menalar.

Skrip pembuktinya membaca teks kebijakan **langsung dari berkas usulan**, sehingga yang diuji
selalu berkas yang akan diterapkan, bukan salinan yang dapat menyimpang.

---

## 13. Recommended Pagination / Filtering Strategy

Ini penghambat yang belum terlihat sekarang dan pasti terlihat pada 100x.

Inilah perbaikan berdampak terbesar. Angka "sekarang" di bawah terukur, "100x" dihitung dari
biaya per baris yang terukur itu.

| RPC | Sekarang | 100x | Usul |
|---|---:|---:|---|
| `rc_legacy_bootstrap` | 1.148 KB | **±122 MB** | Login cukup identitas, hak akses, dan daftar depot (±30 KB). Customers dan documents dimuat saat modulnya dibuka, berhalaman |
| `rc_legacy_dashboard` | 1.484 KB | **±145 MB** | Kembalikan ringkasan teragregasi seperti `rc_report_dashboard` (11 KB), bukan 2.711 baris mentah |
| `rc_legacy_documents` | 839 KB | **±82 MB** | Hanya dokumen Not Yet milik depot pemanggil; sisanya lewat pencarian |
| `rc_legacy_workflow` | 678 KB | **±66 MB** | Halaman 50 baris + filter di server |
| `rc_open_claims` | berhalaman ✓ | aman | `keyset` bila offset melewati 10.000 |
| `rc_timetable_matrix` | 28 KB ✓ | aman | tidak perlu diubah |

**Urutan pengerjaan yang saya sarankan**, dari yang paling murah:

1. `rc_legacy_dashboard` — ubah menjadi agregat. Layar yang memakainya sudah punya padanan yang
   terbukti bekerja (`rc_report_dashboard`), jadi bentuknya sudah diketahui.
2. `rc_legacy_workflow` — tambahkan halaman; antrean approval memang tidak pernah dibaca 5.000
   baris sekaligus.
3. `rc_legacy_bootstrap` — paling berdampak, tetapi menyentuh alur login, jadi paling perlu
   kehati-hatian.
4. `rc_legacy_documents` — dipakai autofill grid; perlu diganti pencarian per dokumen.

Nomor 3 pantas ditekankan: **login memuat seluruh master**. Itulah sebabnya ia sudah 316 ms pada
24 MB. Pada 206.700 customers ia menjadi operasi paling mahal di seluruh sistem, dan ia terjadi
300 kali dalam satu menit pagi hari.

Pola `offset` juga perlu diperhatikan: `offset 10000` memaksa Postgres membaca lalu membuang
10.000 baris. Untuk daftar panjang, pindah ke keyset (`where (updated_at, id) < (?, ?)`).


---

## 14. Recommended Caching Strategy

Urutannya sengaja: yang paling murah dan paling tidak berisiko lebih dulu.

1. **Jangan tambahkan cache dulu.** Perbaikan 6.1 dan 6.2 menghilangkan sebagian besar beban
   tanpa menambah komponen apa pun, dan cache di atas query yang salah hanya menyembunyikan
   masalahnya sampai cache-nya meleset.
2. **Cache di peramban untuk master yang jarang berubah.** Daftar depot dan campaign berubah
   beberapa kali sebulan; sekarang ditarik ulang setiap login. Simpan di `sessionStorage`
   dengan penanda versi.
3. **Materialized view untuk agregasi laporan.** `rc_report_dashboard` dan `rc_cost_center`
   menghitung ulang seluruh riwayat setiap kali dibuka. Laporan tidak perlu seketika —
   perbarui tiap 15 menit lewat `pg_cron` yang sudah terpasang.
4. **Baru pertimbangkan menaikkan compute**, sesudah ketiganya diukur.

---

## 15. Final Findings

Sesuai permintaan Anda, saya tidak menyimpulkan sistem ini aman atau tidak aman. Yang dapat
dinyatakan dengan dasar:

**Yang sudah pasti, karena terukur:**

1. **Balasan RPC warisan membawa isi tabel apa adanya.** Login 1.148 KB, dashboard 1.484 KB pada
   data 24 MB. Proyeksi 100x: ±266 MB per pengguna untuk login dan layar pertama, ±78 GB untuk
   300 pengguna. Inilah batas yang akan tercapai lebih dulu.
2. **Kebijakan RLS memanggil fungsi per baris.** 67,7 ms untuk `count(*)` biasa; 14.385 halaman
   untuk tabel 671 halaman; `user_permissions` (19 baris) ter-seq-scan 240 juta kali.
3. **Perbaikan RLS bekerja dan setara.** 30x untuk admin, 26x untuk System Manager, Seq Scan →
   Index Scan, dan dibuktikan setara baris demi baris (30 pasangan, 0 berbeda). Pembuktiannya
   sekaligus menangkap satu cacat pada rancangan awalnya — 40 baris log berdepot NULL.
4. Indeks pencarian salah jenis (`customers_name_idx`, GIN tsvector untuk pola ILIKE) dan
   terbukti dipakai **0 kali**.
5. `max_connections = 60`. Pada 300 pengguna, batas ini ditentukan oleh durasi query — bukan
   sebaliknya.
6. Vercel bukan penghambat: tidak ada serverless sama sekali.
7. **RPC yang ditulis baru sudah benar.** Report 11 KB, Cost Center 24 KB, Timetable 28 KB dalam
   14 ms. Dugaan saya bahwa `cross join` Timetable akan bermasalah terbantah oleh pengukuran.
   Yang perlu diperbaiki hanya empat RPC kompatibilitas warisan.

**Yang belum dapat dinyatakan, dan mengapa:**

Apakah 300 pengguna serentak pada data 100x berjalan tanpa degradasi — ini **belum diuji**, dan
saya tidak akan menyimpulkannya dari perhitungan saja. Perhitungan tidak memperlihatkan
antrean kunci, tidak memperlihatkan perilaku Supavisor saat koneksi menipis, tidak
memperlihatkan apa yang terjadi pada cache hit ratio ketika dataset sepuluh kali lebih besar
daripada `shared_buffers`, dan tidak memperlihatkan race condition pada penghitung nomor
dokumen. Keempat hal itu hanya muncul di bawah beban sungguhan.

**Perkiraan yang dapat saya pertanggungjawabkan:** dengan perbaikan 11, 12 dan **terutama 13**
diterapkan, arsitektur Supabase + Vercel ini **masuk akal untuk 300 pengguna pada volume 100x**.
Urutan kepentingannya sekarang terbalik dari dugaan awal saya: yang paling menentukan adalah
memperkecil balasan (13), bukan mempercepat query (12) — meski 12 jauh lebih murah dikerjakan
dan tetap layak dikerjakan lebih dulu.

Tanpa perbaikan 13, saya memperkirakan sistem **tidak akan mencapai 100 pengguna** pada volume
100x, dan kegagalannya bukan berupa lambat melainkan gagal: menyusun dokumen JSON 122 MB dengan
`work_mem` 2 MB akan tumpah ke disk, menahan koneksi selama itu, dan 60 koneksi habis dalam
hitungan belasan pengguna.

Angka-angka perkiraan itu **bukan hasil pengukuran**, dan justru itulah yang harus dibuktikan
lewat pengujian sungguhnya.

---

## 16. Yang diperlukan agar pengujian dapat dijalankan

Ini satu-satunya hal yang menghalangi, dan hanya Anda yang dapat mengerjakannya.

**Keadaan sekarang:** hanya ada satu project Supabase pada akun ini — `rc-next-gen-dev`
(`vvojshgcduqlugngpzkj`). Namanya "dev", tetapi isinya data yang dipakai depot: 2.756 dokumen
nyata, 52 depot nyata, alamat email staf yang nyata. Daftar branch kosong. Docker tidak
terpasang di mesin ini, jadi Supabase lokal juga tidak dapat dijalankan.

**Tiga pilihan, dari yang paling sederhana:**

| Pilihan | Cara | Catatan |
|---|---|---|
| **A. Project staging baru** | Buat project Supabase baru di region yang sama | Paling bersih. Skema dipasang dari `supabase/migrations/`, lalu seed |
| **B. Supabase Branch** | Perlu paket Pro | Menyalin skema otomatis; hemat langkah |
| **C. Postgres lokal** | Pasang Docker, `supabase start` | Tidak menguji Supavisor, Auth, maupun jaringan — hasilnya tidak sebanding |

Bila memilih A, urutannya:

```bash
# 1. Pasang skema ke staging (tanpa data)
#    Salin seluruh isi supabase/migrations/ ke SQL Editor staging, berurutan.

# 2. Seed 100x
psql "<connection string staging>" -f scripts/loadtest/seed-100x.sql

# 3. Buat 300 akun uji + berkas pengguna-uji.json
export SUPABASE_SERVICE_ROLE_KEY=<service role key staging>
node scripts/loadtest/buat-pengguna-uji.mjs --url https://<ref>.supabase.co --jumlah 300
#    Lalu jalankan blok SQL yang dicetak skrip itu, untuk memberi depot dan izin.

# 4. Pasang k6, lalu jalankan tangga bebannya
k6 run -e BASE=https://<ref>.supabase.co -e KEY=<anon> -e SKENARIO=load \
       scripts/loadtest/rc-loadtest.js
```

**Yang saya perlukan dari Anda:** ref, anon key, dan service role key project staging. Seluruh
perkakasnya sudah siap:

| Berkas | Kegunaan |
|---|---|
| `scripts/loadtest/seed-100x.sql` | Dataset 100x, distribusi realistis |
| `scripts/loadtest/buat-pengguna-uji.mjs` | 300 akun uji + `pengguna-uji.json` |
| `scripts/loadtest/rc-loadtest.js` | k6: baseline, load, concurrency, spike, endurance |
| `scripts/loadtest/usulan-optimasi-rls.sql` | Perbaikan RLS, sudah dibuktikan setara |
| `scripts/loadtest/jalankan-bukti.mjs` | Pembukti kesetaraan, dapat diulang kapan saja |

Sesudah itu saya kerjakan sisanya — seed, akun uji, eksekusi skenario A sampai G, dan pengisian
hasil nyata ke bagian 15 dokumen ini.

---

## Lampiran — Acceptance Criteria yang diusulkan

Angka di bawah adalah **usulan**, dan uji beban inilah yang menguji usulan itu sendiri. Bila
kenyataannya jauh berbeda, yang diperbaiki bisa jadi angkanya, bukan sistemnya.

| Ukuran | Usul | Dasar |
|---|---|---|
| P50 semua aktivitas | < 400 ms | Terasa seketika |
| P95 login | < 1,5 detik | Sekarang puncaknya 926 ms pada beban ringan |
| P95 dashboard | < 2 detik | Sekarang puncaknya 1.076 ms pada beban ringan |
| P95 pencarian | < 1 detik | Dipakai berulang kali dalam satu sesi |
| P95 upload batch 50 | < 5 detik | Pekerjaan besar, orang bersedia menunggu |
| P99 semua aktivitas | < 2× P95 | Ekor yang lebih panjang menandakan antrean |
| Error rate | < 1% | Di luar konflik versi dan duplikat, yang dihitung terpisah |
| Durasi query database | P95 < 500 ms | Di atas ini koneksi menumpuk |
| Concurrent users | 300 tanpa 429/5xx | Sasaran Anda |
| Ukuran batch | 50 normal, 500 tetap selesai | 500 boleh lambat, tidak boleh gagal |
| Cache hit ratio | > 0,99 | Di bawah ini `shared_buffers` kekecilan |
| Koneksi terpakai | < 70% dari 60 | Sisakan ruang untuk cron dan pemeliharaan |
