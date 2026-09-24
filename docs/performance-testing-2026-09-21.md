# RC — laporan kesiapan load/stress testing, 21 September 2026

**Status: BLOCKED — staging belum tersedia. Tidak ada load/stress test terhadap aplikasi yang dijalankan.**

Pemilik mengonfirmasi belum ada staging. Inventaris Management API hanya mengembalikan project
`vvojshgcduqlugngpzkj`, nama `rc-next-gen-dev`, region `ap-southeast-1`. Dokumen operasional
terbaru menyatakan project ini dipakai depot. Nama DEV tidak membuktikan isolasi; project itu
diblokir di harness. Tidak ada benchmark, seed, transaksi, atau perubahan database di project itu.

Laporan ini menggantikan target 300 pengguna/100x pada [rencana lama](load-test-plan.md).
Angka latency dalam rencana lama bukan baseline pengujian ini: belum direproduksi di staging,
dataset dan revisi database berbeda, dan bukti mentahnya tidak menjadi hasil run ini.

## 1. Environment dan alat

| Komponen | Hasil pemeriksaan aktual |
|---|---|
| Target database staging | Belum ada; **0 baris dimuat oleh sesi ini** |
| Frontend Vercel staging | Belum ditetapkan/diverifikasi |
| Generator lokal | Windows x64, Intel Core i5-1235U, 12 logical CPUs |
| RAM generator | 15,73 GiB total; 4,80 GiB tersedia pada pemeriksaan awal, dapat berubah |
| Runtime | Node 24.14.0; Python 3.11.15 |
| k6 | v2.2.0; binary resmi di `.runtime/performance/tools/` |
| Verifikasi binary | SHA-256 `ceb2b1e1cf9dbe1303c6c33ec83ffda86dda5c610b4def92064d3c7ebae8d9f4` |
| Docker / PostgreSQL CLI | Tidak ditemukan di PATH; tidak ada stack Supabase lokal yang dijalankan |
| CPU/RAM/IOPS database, pool, tier, rate limits | **NOT_MEASURED**; harus dicatat dari staging |
| Lokasi fisik/bandwidth generator | Belum diukur; timezone bukan bukti lokasi jaringan |

Metode: k6 HTTP VUs untuk trafik aplikasi ke Supabase, satu probe Chromium terpisah untuk
render/login/dashboard, SQL observability untuk database, serta metrics platform untuk CPU,
RAM, IOPS dan pool. HTTP GET HTML tidak membuktikan rendering atau kinerja JavaScript.
[Grafana mendukung pengujian browser dan protocol terpisah](https://grafana.com/docs/k6/latest/using-k6-browser/running-browser-tests/).

k6 sudah **berhasil memuat konfigurasi** stress: `maxVUs=1500`, durasi `52m30s` dari `k6 inspect`.
Ini bukan bukti 1.500 atau 1.000 VUs telah berjalan. Kemampuan mesin mempertahankan beban dan
bandwidth masih perlu kalibrasi; [batas load generator juga harus dipantau](https://grafana.com/docs/k6/latest/testing-guides/running-large-tests/).

## 2. Dataset satu juta baris

Target diinterpretasikan sebagai **1.000.000 baris pada tabel claims**, dengan master, history,
snapshot sensitif dummy, dan log sebagai baris tambahan. Bukan satu juta baris gabungan tabel.

Sudah dibuat **secara lokal**, tanpa membaca data aplikasi:

| CSV | Baris | Byte |
|---|---:|---:|
| claims | 1.000.000 | 336.694.921 |
| customers | 100.000 | 12.652.876 |
| customer_depots | 100.000 | 7.500.022 |
| campaigns | 1.000 | 113.981 |
| depots | 100 | 7.530 |
| Total | **1.201.100** | **356.969.330** |

Pembuatan CSV: **19,593 detik** pada mesin ini. Ini waktu generator file, **bukan waktu insert,
query, throughput database, atau kapasitas aplikasi**. Verifier membaca seluruh file: kelima
checksum cocok, jumlah baris cocok, identitas dokumen unik berurutan, relasi customer/depot/campaign
dan status/tanggal klaim sesuai generator. Sumber: `.runtime/performance/dataset-1m/manifest.json`.
Salinan metadata tanpa isi data: [bukti audit](audit/performance-2026-09-21.json).

| Status dummy | Baris |
|---|---:|
| not_yet | 299.998 |
| submitted | 150.002 |
| released | 150.001 |
| claimed | 99.999 |
| done | 250.001 |
| on_hold | 29.996 |
| expired | 20.003 |

Seed deterministik `20260921`, identifier `PERF/…`, nama toko bervariasi, nilai uang tersebar,
periode sekitar 24 bulan, dan distribusi depot miring. Depot terpadat memiliki 99.990 klaim;
yang terkecil 5.020. Distribusi ini adalah desain sintetis, bukan klaim kesetaraan distribusi produksi.
Tidak ada nama, KTP, NPWP, rekening, password, atau email produksi yang disalin.

`import-dummy.psql` menyiapkan history konsisten dengan status/version, sensitive snapshot dummy,
500.000 log dan `ANALYZE`. **SQL tersebut belum dijalankan/divalidasi PostgreSQL.** Ia menolak
tabel bisnis, Auth, profil atau snapshot yang sudah berisi data, project yang diblokir, cron aktif,
dan Vault berisi secret. Tidak ada TRUNCATE, penghapusan, atau cleanup otomatis atas data existing.

356,97 MB CSV tidak sama dengan ukuran PostgreSQL. Heap, index, history, WAL dan headroom menambah
storage; jangan menganggap Free cukup. Tetapkan kapasitas staging dan budget sebelum provisioning;
ukur `pg_database_size` sesudah seed, lalu sisakan ruang untuk log, WAL dan soak.
[Kuota bergantung paket Supabase](https://supabase.com/pricing).

## 3. Temuan analisis aplikasi dan harness lama

| Temuan dari sumber lokal | Implikasi yang perlu diuji | Bukti |
|---|---|---|
| Bootstrap menyertakan documents/customers/master | Payload login dan penggunaan memori berpotensi tumbuh | `20260917010000_rc_legacy_compat_api.sql`, `rc_legacy_bootstrap` |
| Dashboard mengagregasi JSON history dan compileData | Biaya scan, serialisasi, network dan render; jangan ekstrapolasi linear sebagai hasil uji | `20261006010000_rc_analytics_semua_status.sql` |
| History difilter/dipotong di browser | Pagination layar tidak membatasi response backend | `src/js/70-analytics.js`, `filtered.slice(...)` |
| `rc_open_claims`: COUNT + JOIN + ILIKE `%…%` + OFFSET | Search/deep pagination berpotensi membaca banyak baris; perlu EXPLAIN dengan role nyata | `20260922010000_rc_display_and_pagination_fixes.sql` |
| Posting exception/reprocessing mengunci baris menurut urutan input | Risiko deadlock pada daftar berlawanan; belum diukur frekuensinya | `20261027010000`, `20261028010000` |
| Submit juga mengunci customer master | Dokumen berbeda dengan customer sama bisa berkontensi; urutan lock claim saja belum membuktikan bebas deadlock | `20261005010000_rc_aturan_unggah_jenis_cb.sql` |
| Ada idempotency key, row lock dan expected version | Mekanisme perlu dibuktikan lewat assertion commit/history, bukan HTTP status saja | `rc_process_claims` / `mutate_claims_unchecked` |

Ini **kandidat bottleneck dan risiko**, bukan hasil pengukuran staging. Database, Auth, network,
frontend, maupun CDN belum dapat dinyatakan sebagai bottleneck aktual atau dikecualikan.

Harness lama dinonaktifkan karena masih menguji maksimal 300 VUs, mengirim submit dengan array
kosong, melabeli waktu list sebagai approve, dan mempunyai bypass target produksi. Status HTTP 0
juga tidak dihitung sebagai error oleh aturan `status>=400`. Seed lamanya menggunakan subquery
random tak berkorelasi yang perlu diperiksa distribusinya; tidak dipakai untuk dataset baru.

## 4. Skenario dan urutan eksekusi

| Mode | Target | Rencana |
|---|---|---|
| Smoke | 1 akun per role | Cek endpoint, payload, scope, side effect, saldo/status/history sebelum load |
| Baseline | 1 VU | Warmup 60 detik; ukur tanpa beban; durasi diperpanjang sampai ≥200 sampel per operasi |
| Load | 100 → 250 → 500 → 750 → 1.000 | Ramp 60 detik dan hold 300 detik per level; recovery 100 lalu 1 VU |
| Stress | 100 → 250 → 500 → 750 → 1.000 → 1.250 → 1.500 | Sama; cari kegagalan berkelanjutan, simpan hasil tiap plateau |
| Mixed | 1.000 | 100 dashboard, 200 search, 200 report, 200 transaction, 150 update, 150 upload |
| Spike | 100 → 500 → 1.000 → 500 → 100 | Transisi 10 detik, hold 180 detik; bandingkan 100 awal/akhir |
| Soak | 500 lalu 1.000 | Dua jam per level, kemudian recovery |
| Integrity | Request serentak terarah | Dua actor/key, double submit, timeout/retry, rollback batch |
| Browser probe | 1 Chromium | Dijalankan pada generator terpisah selama plateau HTTP |

Load memakai closed workload, VU menunggu response lalu think time 3–5 detik. 1.000 VUs bukan
1.000 RPS, bukan 1.000 koneksi PostgreSQL, dan bukan 1.000 Chromium. Slow response menurunkan
RPS pada model ini; setelah baseline, lakukan arrival-rate companion test bila perlu mengukur
antrian pada tingkat request tetap. Arrival-rate companion belum diimplementasikan/dijalankan.
[Perilaku ramping VUs](https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/ramping-vus/).

Login dilakukan ketika VU mulai, session dipakai ulang dan refresh token saat perlu. Rekam login
termasuk ramp secara terpisah; jangan mencampurkannya dengan latency steady-state. Login storm
harus menjadi run tersendiri setelah mencatat quota/IP/rate limit staging. HTTP 429 tetap error
Auth, bukan bukti database tidak sanggup 1.000 sesi.
[Supabase menerapkan rate limit Auth](https://supabase.com/docs/guides/auth/rate-limits).

## 5. Cakupan operasi dan batas harness

| Kebutuhan | Implementasi/pemeriksaan | Batas saat ini |
|---|---|---|
| Membuka halaman | GET frontend; probe browser login/dashboard | GET bukan render; browser belum dijalankan |
| Login | Native Auth, bootstrap, refresh token | Akun dummy belum diprovision; login storm khusus belum dibuat |
| SELECT/search/filter | `rc_open_claims`, JOIN/search/filter/paging | Payload harus lulus smoke test melawan schema staging aktual |
| Sorting/pagination | SQL order + offset 0/50/500/5.000; EXPLAIN offset 100.000 | Sort ini probe API, bukan bukti click-sort UI; UI sort masih perlu browser scenario |
| Form submit/update/transaksi | `rc_process_claims` submit/release, read-after-write | Stage claim/clearing/reject dan update master perlu tambahan fixture/journey sebelum menyatakan cakupan penuh |
| Upload RC | Batch posting dokumen dummy existing, 10 baris awal | Mengukur RPC batch, **belum parser Excel/file upload browser** |
| Upload/compile Document Center | Tidak dijalankan | Tetap ditunda sesuai instruksi awal; tidak mengakses legacy PROD |
| Report/dashboard/agregasi | RPC report/dashboard + EXPLAIN agregasi | Bukan benchmark download/render Excel/PDF; ekspor browser masih perlu golden fixture |
| INSERT | COPY seed; audit/history/request insert pada workflow | Belum ada benchmark standalone INSERT claim baru |
| Soak | Default baca saja untuk menghindari habisnya pool dokumen tulis | Tidak membuktikan ketahanan mutasi berjam-jam; `soakWrites` butuh perhitungan pool/cadence lebih dulu |

Pool dokumen harus disjoint per VU dan per run. Harness berhenti jika habis; tidak mendaur ulang
dokumen selesai lalu menghitung request invalid sebagai transaksi normal. Pada baseline, pisahkan
hasil per role/depot dan gunakan scope setara; jangan membandingkan baseline system manager
dengan load admin sebagai bukti regresi. Baseline default satu identity mencakup perjalanan campuran;
**role-specific baseline masih wajib disiapkan sebelum acceptance**.

## 6. Concurrent transaction dan integritas

`integrity.js` memakai empat dokumen submitted dummy serta dua actor yang sama-sama berizin:

1. Dua request payload/key sama: kedua response identik, status released, version +1, history +1.
2. Key yang sama dengan payload berbeda: harus ditolak.
3. Dua actor, dua request key, expected version sama: tepat satu commit, satu SQLSTATE `40001`.
4. Timeout client 1 ms, retry payload/key sama: tepat satu commit. Bila timeout tidak benar-benar
   teramati, threshold gagal; tidak diklaim telah menguji ambiguous timeout.
5. Batch valid + dokumen tidak ada: seluruh perubahan dan history harus rollback.

Test ini belum berjalan. Tambahkan reversal urutan lock exception/reprocessing dan dua dokumen
berbagi customer, cek deadlock `40P01` dan total nilai. Expected conflict hanya boleh dipisahkan
dari availability error pada run integrity yang sengaja menciptakannya; conflict tak terduga pada
pool load disjoint tetap kegagalan. Jangan mengartikan pesan error sebagai bukti idempotency sukses.

## 7. Metrics dan observability

| Metrik | Sumber dan interpretasi |
|---|---|
| Average/P50/P95/P99 | `rc_latency` wall-clock per request, per phase dan operasi; percentile nearest-rank dari sample mentah |
| API duration | k6 `http_req_duration`; pisahkan blocked/connect/TLS/waiting, bukan dianggap durasi SQL |
| RPS | Request selesai dibagi waktu plateau; tampilkan successful RPS terpisah |
| Throughput jaringan | Built-in `data_received`/`data_sent`; counter response karakter tidak dilabeli byte wire |
| Error/failed request | Network status 0, HTTP non-2xx, serta response bisnis invalid; denominator seluruh request |
| Timeout | k6 error code 1050; timeout yang dibatalkan saat ramp down dilaporkan sebagai interrupted iteration terpisah |
| SQL duration | Delta `pg_stat_statements`, nested plans/auto_explain bila tersedia; mean/max bukan SQL P95 |
| Connection/concurrency | `pg_stat_activity`, wait events, locks, Supavisor; dibandingkan `max_connections` |
| DB resource | Supabase Metrics CPU/RAM/disk/IO; belum dikumpulkan |
| Generator resource | `run.mjs`: CPU process, working set, thread count, free RAM tiap 5 detik; unavailable tidak menjadi nol |
| Leak/degradation | Bandingkan window 5 menit setelah warmup: latency, error, RSS, koneksi idle, dead tuples, queue |

Gunakan [metrics k6](https://grafana.com/docs/k6/latest/using-k6/metrics/reference/) dan
[Supabase Metrics API](https://supabase.com/docs/guides/observability/metrics).
`observe.sql` mengambil snapshot/delta tanpa reset statistik. `explain.psql` menjalankan query
dengan role authenticated dan synthetic `auth.uid()`, sehingga tidak mengabaikan biaya RLS.
Queryid boleh disimpan; query text, token, bind values dan payload sensitif tidak masuk laporan.

## 8. Threshold, breaking point, recovery

Tidak ada angka latency acceptance absolut yang dapat ditetapkan dari run ini karena baseline
staging belum ada. Proposal awal: P95 per operasi ≤2× baseline setara, P99 ≤3× baseline, error
<1%, timeout <0,1%, **0 pelanggaran integritas**, dan tidak ada kehabisan fixture.
`make-budgets.mjs` menolak baseline dengan kurang dari 200 sampel/operasi atau error berlebih.
Untuk penilaian P99 yang kuat, perlu lebih banyak sampel dan pengulangan (target ≥1.000/operasi),
ditambah absolute SLO bisnis dan resource tier yang dicatat sebelum load. Angka 2×/3× dan batas
error tersebut adalah proposal, bukan hasil kelulusan atau janji SLA.

Breaking point: plateau pertama dengan pelanggaran threshold berkelanjutan sedikitnya dua
window 60 detik, atau throughput mendatar/menurun saat concurrency meningkat disertai queue/resource
saturation. Laporkan titik awal degradasi, error pertama, timeout pertama, dan titik gagal yang
bertahan secara terpisah. Jika semua sampai 1.500 lulus, tulis **tidak ditemukan sampai 1.500**,
bukan breaking point 1.500. Jika generator jenuh, hasil **INCONCLUSIVE**, bukan server gagal.

Recovery: setelah turun ke 100, lalu 1 VU, bandingkan dengan baseline/pre-spike dengan scope sama.
Proposal recovery ≤5 menit untuk P95/error/queue kembali ke rentang baseline (misalnya latency
≤1,2× dan queue/koneksi tidak terus naik). Nilai itu harus disetujui terhadap SLO environment.

Stop manual bila integritas salah, resource generator >85% terus-menerus, database kehabisan disk,
atau error >20%/timeout >10% bertahan 60 detik. Runner saat ini merekam resource, **belum mempunyai
automatic abort berbasis sliding window resource**; operator harus memonitor dan menghentikan run.
Jangan jalankan soak tanpa pengawasan/monitoring dan kapasitas disk log yang memadai.

## 9. Tabel hasil aplikasi — belum ada pengukuran

`N/A` berarti tidak diukur, bukan 0 ms, 0 error, atau lulus.

| Users | Dataset DB | Avg | P50 | P95 | P99 | RPS | Error Rate | Timeout | Status |
|---:|---|---|---|---|---|---|---|---|---|
| 1 baseline | Target 1.000.000; belum dimuat | N/A | N/A | N/A | N/A | N/A | N/A | N/A | NOT_RUN |
| 100 | Sama | N/A | N/A | N/A | N/A | N/A | N/A | N/A | NOT_RUN |
| 250 | Sama | N/A | N/A | N/A | N/A | N/A | N/A | N/A | NOT_RUN |
| 500 | Sama | N/A | N/A | N/A | N/A | N/A | N/A | N/A | NOT_RUN |
| 750 | Sama | N/A | N/A | N/A | N/A | N/A | N/A | N/A | NOT_RUN |
| 1.000 | Sama | N/A | N/A | N/A | N/A | N/A | N/A | N/A | NOT_RUN |
| 1.250 | Sama | N/A | N/A | N/A | N/A | N/A | N/A | N/A | NOT_RUN |
| 1.500 | Sama | N/A | N/A | N/A | N/A | N/A | N/A | N/A | NOT_RUN |

**Database performance, API performance, bottleneck aktual, breaking point, dan recovery:
NOT_MEASURED.** Soak, concurrency correctness pada database, browser QA dan server utilization:
NOT_RUN. Tidak ada kesimpulan aplikasi kuat/lambat atau sanggup 1.000 pengguna.

## 10. Yang sudah diverifikasi

- Delapan unit test JS: target guard, level beban, campuran VU, spike/soak, phase tagging,
  baseline budget, dan klasifikasi timeout/semantic failure: PASS.
- Satu unit test generator (determinisme, distribusi, FK formula, overwrite rejection, tamper
  detection): PASS; dua test kalkulasi laporan/sample percentile/partial run: PASS.
- Verifikasi seluruh 1.000.000 klaim CSV dan lima checksum: PASS_OFFLINE_CSV.
- k6 binary/version dan compile/inspect stress 1.500 VUs: PASS_CONFIG_ONLY.
- Pemeriksaan syntax JS runner, workload dan integrity: PASS.
- SQL seed/EXPLAIN, workload terhadap Supabase, integritas, browser, dan profiler: **belum diuji**.

Pemeriksaan tersebut memvalidasi persiapan alat, bukan kinerja aplikasi. UI/kode aplikasi dan
database existing tidak diubah. Key server yang ditemukan di `.env.example` diganti placeholder;
private `.env` tidak diubah. Jika key tersebut aktif, rotasi melalui pengelola secret diperlukan;
key tidak dimasukkan ke fixture atau laporan ini.

## 11. Runbook setelah staging tersedia

1. Buat project khusus tanpa clone data produksi. Tentukan region/tier/storage/budget; dokumentasikan
   konfigurasi PostgreSQL, Auth limits, pool, schema hash dan source hash. Tidak membuat resource
   berbayar pada sesi ini. Untuk membandingkan kapasitas, jangan diam-diam menguji tier lebih besar
   lalu menyimpulkan produksi lebih kecil pasti mampu.
2. Deploy **schema-only yang ditinjau**; jangan replay semua migration repository secara buta:
   beberapa migration berisi import/backfill/data assertion dan bukan bootstrap schema kosong.
   PostgreSQL/Auth/RLS/function yang diuji harus sama dengan target aplikasi.
3. Matikan email/cron/webhook/integrasi luar di staging; jangan salin Vault, SMTP atau Gmail secret.
4. Verifikasi CSV, lalu dari direktori dataset jalankan `import-dummy.psql` menggunakan koneksi
   PostgreSQL staging, `ON_ERROR_STOP`, dan `-v test_ref=<ref-staging>`. Script adalah kandidat yang
   harus lulus uji seed kecil/schema check sebelum import besar. Gunakan `.pgpass`/secret manager,
   jangan credential pada argumen command atau repository. Simpan log counts, FK, history dan ukuran.
5. Provision **1.500 identity unik** melalui Auth Admin staging saja; user code `PERF_…`, email
   internal dummy, profile active/password gate selesai, permission dan depot sesuai lane. Aktifkan
   hubungan OSC/supervisor sesuai schema, bukan seluruh account menjadi System Manager. Save fixture
   private `.runtime/performance/users.json`: `id,userCode,email,password,lane,search,campaign,documents`.
   `documents.submit/release` berisi `no_doc,version_no,tax_subject` dari pool disjoint yang valid.
   **Provisioning dan allocation pool belum otomatis dibuat/diuji dalam paket ini.**
6. Siapkan empat dokumen submitted dan dua actor untuk `integrity.js`. User browser harus bisa login
   melalui User ID normal dan berizin analytics. Gunakan schema contract smoke test per role.
7. Deploy frontend staging yang sama ke Vercel dengan `dataBackend: 'supabase'`, URL/key staging,
   CSP `connect-src` staging dan tanpa fallback Apps Script. Build saat ini hardcode config/CSP
   project existing; **deployment staging perlu konfigurasi terpisah**, bukan memakai output lama.
8. Isi `staging.example.json` menjadi file private config; attestation `rc_perf_environment` harus
   mengonfirmasi dataset/ref/no-side-effect. Harness tidak menerima service-role JWT sebagai key.
9. Jalankan baseline sesuai role; review sample/payload/RLS/semantic response, resource dan budgets.
   Rekonsiliasi/reset fixture dengan recreate staging dataset, bukan menghapus data bercampur.
10. Jalankan load → integrity → stress → spike → soak. Simpan raw metrics, logs, SQL snapshots,
    plans dan platform resource. Jalankan browser probe terpisah saat hold. Jangan melanjutkan
    level bila alat ukur jenuh atau baseline tidak valid.

Contoh setelah prasyarat selesai (hanya variabel path, tanpa secret di command):

```powershell
$env:RC_TEST_CONFIG = 'D:\private\rc-staging-config.json'
$env:RC_TEST_USERS = 'D:\private\rc-dummy-users.json'
$env:RC_GENERATOR_LOCATION = 'lokasi generator yang telah diverifikasi'
$env:RC_HOLD_SECONDS = '1800'
node scripts/performance/run.mjs baseline
# Ganti <run> dengan direktori bukti aktual; baca hasil dan validasi scope/role dahulu.
python scripts/performance/report.py --raw '<run>\raw.json' --summary '<run>\result-summary.json' --out '<run>\report'
node scripts/performance/make-budgets.mjs '<run>\report.json' 'D:\private\rc-budgets.json'
$env:RC_BASELINE_BUDGETS = 'D:\private\rc-budgets.json'
$env:RC_HOLD_SECONDS = '300'
node scripts/performance/run.mjs load
```

Ganti mode untuk `stress`, `mixed`, `spike`, atau `soak` setelah verifikasi tahap sebelumnya.
Integrity memakai `RC_INTEGRITY_FIXTURE`; browser probe memakai `RC_BROWSER_USER` dan Chromium
yang tersedia. Seluruh output run masuk `.runtime/performance/runs/`; jangan commit credential,
raw response, atau credential fixture. Percentile dihitung dari sampel individual, bukan rata-rata P95.

## 12. Rekomendasi berurutan

Prioritas pertama adalah menyediakan staging dan menyelesaikan fixture/role smoke tests. Setelah
baseline terukur, uji pengurangan payload bootstrap dan server pagination analytics tanpa perubahan
UI; lalu evaluasi query plan search/deep offset dan biaya RLS. Jangan menambahkan index atau
mengganti policy hanya dari dugaan. Ukur perubahan satu per satu, termasuk biaya tulis/storage.

Koreksi urutan lock exception/reprocessing dan shared-customer contention perlu dibuktikan dengan
test balapan. Pastikan report memakai agregasi yang berizin, dan pisahkan biaya render/Excel dari
waktu database. Terakhir tentukan tier/pool atau generator tambahan dari saturation terukur.
Belum ada dasar untuk menyatakan upgrade tertentu pasti mencapai 1.000 pengguna.
