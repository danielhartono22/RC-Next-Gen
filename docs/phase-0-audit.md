# Fase 0 — Audit Resource Collection dan Document Center

Tanggal: 14 September 2026. **Status: BLOCKED_BY_SYNC_INVENTORY.** Koneksi MCP dan audit sumber kedua backend telah dilanjutkan; mapping sinkronisasi, data dictionary produksi dan baseline operasional belum selesai.

Acuan: [System Instruction versi 1.1](../System-Instruction-Migrasi-Claim-System-ke-Supabase.md). Pemilik kini menetapkan Supabase project **vvojshgcduqlugngpzkj sebagai DEV**, menggantikan keputusan PROD sebelumnya; lihat [lingkungan proyek](environments.md). Audit membaca file lokal, menjalankan karakterisasi sintetis, dan memperbarui artefak. Tidak mengubah aplikasi, menerapkan migration, mengakses deployment Apps Script atau mengubah trigger.

## 1. Sumber dan keluaran audit

| Sumber | Status terkini | Batas bukti |
|---|---|---|
| index (4).html | 293.699 byte; baseline frontend tersedia, hash tetap | Deployment aktif belum dicocokkan |
| index (5).html | 52.215 byte; baseline frontend tersedia, hash tetap | Golden export dan runtime browser belum diuji |
| ResourceCollection | **Tersedia**, 70.781 byte / 1.558 baris; dibaca penuh | Backend RC pengganti nama lampiran Pasted text.txt; ENV lokal DEV |
| DocumentCenter | **Tersedia**, 23.281 byte / 502 baris; dibaca penuh | Backend DC pengganti nama lampiran Pasted code.js |
| Job/trigger sinkronisasi 15 menit | Belum tersedia / tidak ditemukan pada dua backend | Lokasi, versi, mapping, checkpoint, backlog dan retry UNKNOWN |
| Header/formula/data anonim Spreadsheet | Belum tersedia | Label field kode belum menjadi header produksi terkonfirmasi |
| Supabase DEV | `vvojshgcduqlugngpzkj`; ditetapkan pemilik, MCP terverifikasi | Public/migration masih kosong pada pemeriksaan ulang; bukan seluruh database kosong |
| Supabase PROD | Belum ditetapkan | Akan dipilih terpisah sebelum cutover |
| Git | Repository lokal kini tersedia; sumber/dokumen awal sudah staged oleh pengguna | Remote/deployment Pages belum diverifikasi; index tidak diubah agent |

Ketersediaan backend menggantikan status lama “file kosong”, tetapi belum membuktikan kesamaan kode dengan deployment aktif.

| Artefak | Isi |
|---|---|
| [Audit backend](phase-0-backend-audit.md) | Router, otorisasi, status, batch, upload, field mapping, risiko dan batas pengujian terkini |
| [Bukti backend](phase-0-backend-evidence.json) | SHA-256, ukuran sumber, fungsi/rute, 39 field Compile dan konfigurasi tanpa secret |
| [Hasil karakterisasi](phase-0-backend-test-results.json) | 26 hasil PASS/FAIL dan bukti lokasi kode |
| [Harness offline](audit/characterize-backends.cjs) | Pemeriksaan yang dapat dijalankan ulang tanpa layanan eksternal |
| [Baseline frontend awal](phase-0-frontend-baseline.md) | Detail UI/permission/export dan 10 pemeriksaan awal; catatan historis sebelum backend tersedia |
| [Audit Supabase](phase-0-supabase-audit.md) | MCP, grants/advisors, metadata PROD pada waktu pemeriksaan |
| [Bukti Supabase](phase-0-supabase-evidence.json) | Snapshot terdahulu; dipertahankan agar riwayat tetap utuh |
| [Lingkungan proyek](environments.md) | Keputusan DEV terkini dan registry target project |
| [Bahan yang perlu dilengkapi](phase-0-source-intake.md) | Job/trigger, header/formula, deployment dan sampel anonim |

## 2. Arsitektur dan lineage saat ini

~~~mermaid
flowchart TD
  U[Pengguna] --> RCF[Frontend Resource Collection]
  RCF --> RCB[Backend ResourceCollection]
  RCB --> ENV{ENV lokal DEV}
  ENV --> RCDEV[Spreadsheet RC DEV]
  ENV -. konfigurasi alternatif .-> RCPROD[Spreadsheet RC PROD]
  RCF -->|menu membuka aplikasi terpisah| DCF[Frontend Document Center]
  DCF --> DCB[Backend DocumentCenter]
  DCB -->|upload dan master| UP[Spreadsheet upload: Upload / ListCampaign / Depot_ID]
  DCB -->|login / print / log| RCPROD
  XLS[Excel Upload_CB] --> DCF
  UP -. job atau formula belum tersedia .-> SYNC[Sinkronisasi 15 menit: UNKNOWN]
  SYNC -. mapping belum dikonfirmasi .-> DEST[Tujuan Resource Collection: UNKNOWN]
  AG[Agent audit] -->|MCP metadata terverifikasi| SB[Supabase DEV]
~~~

AUTH_SS_ID pada DC sama dengan ID Spreadsheet PROD pada konfigurasi RC; kode RC lokal memilih DEV. Perbedaan ini harus dicocokkan dengan deployment aktif. Sheet RC: Authority, Compile, ListCampaign, ListCust, DepoMaster, LogActivity, ReqProfile dan BatchLog. Sheet DC: Upload, ListCampaign, Depot_ID, Authority, DM-30D dan LogActivity.

Pemindahan data tidak ada di dua file backend. Fungsi koreksi gross-up RC hanya menulis ulang nilai Compile, bukan memindahkan Upload. Ketiadaan kode pembuat trigger tidak membuktikan ketiadaan trigger yang dibuat melalui dashboard.

## 3. Endpoint dan matriks otorisasi

RC: **17 rute bisnis**, terdiri atas 2 publik dan 15 bertoken, ditambah doOptions. DC: 4 action eksplisit dan default lookup yang juga menerima lookupBatch. Frontend RC memanggil logout tetapi backend tidak memiliki handler logout. Inventaris setiap rute, sheet baca/tulis dan lokasi sumber ada pada bagian 2 [audit backend](phase-0-backend-audit.md).

| Modul UI | System Manager | Supervisor | OSC | Admin/non-OSC |
|---|---|---|---|---|
| Upload / Release / Claim | Terlihat | J / K / L | J / K / L | J / K / L |
| Analytics | Terlihat | M atau D | M atau D | M atau D |
| Kelola akses | Terlihat | Terlihat | N | N |
| Log | Terlihat | Terlihat | Terlihat | Tersembunyi |
| Master Depot / Document Center / Bulk | Terlihat | P / Q / S | P / Q / S | P / Q / S |

Ini matriks visibilitas frontend. Login RC menghitung managedDepots dari Authority/DepoMaster dan subtag, tetapi tidak menegakkannya kembali pada semua handler. Token admin biasa dapat memanggil operasi admin; scope beberapa query berasal dari body, login mengirim data lintas depot, dan semua rute DC tidak memeriksa sesi aplikasi. Kontrol akses deployment Google di luar kode belum diverifikasi.

Target permission: upload_claim, release_claim, process_claim, view_analytics, manage_access, view_logs, view_master_depot, bulk_process, view_document_center, print_documents dan upload_campaign_compile. Hak per role/depot harus disahkan dan diuji allow/deny.

## 4. State transition dan batch

Target normal instruksi: Not Yet → Submitted → Released → Claimed → Done. Reject mengembalikan Submitted → Not Yet, Released → Submitted, Claimed → Released.

Perbedaan sumber yang perlu ditangani:
- submitData juga menerima Released → Submitted.
- approve clearing menerima Submitted → Done, termasuk non-rebate; expected status per tahap tidak dipakai.
- approve release dapat menerima Claimed → Released melalui validator generik yang sama.
- Hold menerima semua nilai selain Done/Expired/On Hold; unhold mengembalikan previous_status tanpa validasi ulang.
- markExpired menerima semua nilai selain Done/Expired, termasuk alias RA07/RA7 yang dianggap Done di analytics.
- Bulk memakai master jenis CB dengan fallback snapshot; menulis Done, batch tahap 02 dan sejumlah penanda tanggal/batch literal x.

Seluruh tabel transisi dan field yang dihapus saat reject ada pada bagian 4 audit backend. Counter sumber berlaku per tahap+tanggal, tanpa suffix; nomor tetap memuat suffix tiga digit dan tanggal Asia/Jakarta. Counter empat digit dapat membungkus setelah 9999. Target per tahap+suffix+tanggal berbeda dan memerlukan keputusan paritas/overflow.

## 5. Upload_CB, deduplikasi dan print

Jalur yang kini faktual:

~~~text
Excel A:H
  → kodeCampaign, dc, custCode, custName, netValue, total, jenisCb, beforeTaxVal
  → preview menambahkan nama campaign
  → commit menulis Upload C, E, G:I, K, N:O, T:U mulai baris 3
  → [formula dan job sinkronisasi UNKNOWN]
  → [record kanonis tujuan Resource Collection UNKNOWN]
~~~

Backend mempertahankan kolom yang disebut sebagai formula; rumus aktual belum tersedia. Nomor dokumen tidak dibuat handler upload. Actor kolom U berasal dari username body.

Dedup sumber: campaign + underscore + customer, trim tanpa normalisasi case, tanpa depot/periode. Submit **partial accept**; cached index tidak mendeteksi edit key baris lama. Campaign/depot/angka tidak divalidasi ulang. Enam penulisan kolom terpisah tidak menyediakan rollback/idempotency.

Print membaca DM-30D B:AH dan mencari AF/AH untuk batch upload/claim. Backend membatasi hasil 200/2.000 **setelah** membaca range penuh; pagination preview tetap di browser. Ini memperbarui audit awal yang hanya membuktikan limit frontend. Ekspor frontend mengisi A:I dari 17 header; PDF yang tersedia adalah summary upload. Generator template memakai sheet Template, importer mensyaratkan Upload_CB. Paritas cetak memerlukan golden files.

## 6. Data dictionary

[Bukti backend](phase-0-backend-evidence.json) memuat 39 field COL_COMPILE dengan indeks array dan huruf kolom. Indeks bersifat zero-based: NO_DOC=1 berarti B, STATUS=26 berarti AA, GROSS_UP=36 berarti AK, rekening 39–41 berarti AN:AP.

Mapping setiap sheet dari kode ada pada bagian 6 audit backend. Header yang dibuat kode untuk ReqProfile/BatchLog belum membuktikan header sheet aktif. Konflik penting: DepoMaster M dibaca sebagai masterLink dan ditulis sebagai alamat.

Masih diperlukan per sheet: header berurutan, formula/range, locale/timezone, snapshot, jumlah row, null/duplikat, relasi, status, total nilai per depot/campaign dan 20–50 sampel anonim. Identifier tetap text; precision/scale dan tipe tanggal target belum disahkan.

## 7. Performa dan threat model

Batas kepercayaan: file/input/sessionStorage browser → Apps Script → Spreadsheet; Upload/formula → job → tujuan RC; CDN → browser. Aset: sesi, identitas, depot, PII, rekening, nilai claim, batch dan audit.

Prioritas audit kode:
- Kritis: DC tanpa otorisasi aplikasi; token admin biasa dapat membuat akun System Manager/mengubah akses RC.
- Tinggi: bootstrap/log/workflow melampaui depot; role body memengaruhi query; status dapat melewati tahap.
- Tinggi: secret HMAC tertanam, PIN plaintext, token tanpa logout/recheck akun.
- Tinggi: perbedaan gross-up, customer master tak terikat claim, konflik kolom alamat/masterLink.
- Tinggi: penulisan tidak atomik, retry tanpa idempotency, batch overflow dan pelepasan lock internal sebelum handler selesai pada model.
- Sedang–tinggi: kunci dedup bertabrakan, cache stale, campaign/angka tidak divalidasi.

Ini triase sumber, bukan penetrasi deployment produksi. Bukti BK01–BK10 dan batas model ada pada audit backend; secret tidak ditampilkan pada artefak.

Full scan login/Compile/workflow/dashboard/log terbukti. Cache DepoMaster, counter batch, master DC dan indeks upload juga tersedia, sehingga tidak setiap request selalu full scan semua master. Ukuran payload, cache hit, concurrency, p50/p95 dan lag job belum diukur. Klaim peningkatan 70% pada komentar kode bukan benchmark yang telah diverifikasi.

## 8. Keputusan pemilik

| ID | Keputusan | Bukti terkini |
|---|---|---|
| D01 | Hold/Expired hanya Not Yet atau seluruh non-final; perlakuan alias RA7/RA07 | UI lebih sempit dari handler; B13–B14 |
| D02 | Gross-up NIPSEA/ditanggung perusahaan dan rounding | Backend 100.000 vs frontend 0 untuk net 85.000 Badan; B15 |
| D03 | Job: sumber/tujuan, formula, No Document, status, checkpoint/retry | Masih belum tersedia |
| D04 | Unique key upload, termasuk depot/periode/jenis CB dan normalisasi | campaign_customer tanpa depot, dapat collision; B22–B24 |
| D05 | All-or-nothing atau partial accept dan hasil retry | Partial accept terkonfirmasi di sumber; target belum disahkan |
| D06 | beforeTaxVal dari file atau fungsi server kanonis | Nilai file diteruskan tanpa hitung ulang |
| D07 | Hak role/depot untuk DC/print/upload/review | Q hanya UI; handler belum memadai |
| D08 | Print PDF dan kolom J:Q | Frontend mengisi A:I; PDF summary upload |
| D09 | Customer master/snapshot serta mapping alamat/link | Customer body tidak diikat claim; DepoMaster M punya dua makna |
| D10 | Status/filter OSC analytics | Backend menggabungkan status proses; beberapa filter frontend berbeda |
| D11 | Role non-OSC, flag D/Q, status akun/sesi | Login RC cek activation; DC tidak; token tanpa recheck |
| D12 | Locale angka/tanggal, batas file/row, counter suffix/overflow | Kebijakan batch target berbeda dari sumber |

ENV RC lokal DEV belum dicocokkan dengan versi produksi aktif. Perubahan keamanan yang diperlukan dibedakan dari aturan bisnis yang belum diputuskan.

## 9. Target, benchmark dan rekonsiliasi

Target tetap satu shell GitHub Pages dengan Document Center internal, satu sesi Supabase Auth, satu PostgreSQL, grants+RLS role/depot, RPC transaksi/idempotency dan audit server-side. Auth Admin melalui Edge Function bila perlu secret. Bootstrap kecil, lookup terarah, list server terpaginate dan analytics SQL. Upload langsung menghasilkan data kanonis dalam transaksi yang sama, tanpa cron pengganti.

Ini rancangan, bukan schema final. Entitas tujuan, business unique key, formula dan permission belum cukup untuk diterapkan.

| Pengukuran | Status | Target instruksi |
|---|---|---|
| Login/bootstrap p95 | NOT_MEASURED | ≤2 detik |
| Lookup No Document p95 | NOT_MEASURED | ≤500 ms |
| Workflow page/filter p95 | NOT_MEASURED | ≤1 detik |
| Submit 100 dokumen p95 | NOT_MEASURED | ≤3 detik |
| Dashboard p95 | NOT_MEASURED | ≤2 detik |
| Preview/commit campaign p95 | NOT_MEASURED | ≤2/3 detik; batas row perlu keputusan |
| Print lookup p95 | NOT_MEASURED | ≤1 detik, di luar ekspor |
| Lag/backlog/duplicate/error job | NOT_MEASURED | Nol mismatch sebelum cutover |

Benchmark kelak memakai DEV dan data anonim representatif, beban bertahap sampai sekitar 60 sesi, jumlah sampel/p50/p95/payload/error/cold-warm yang tercatat. Tidak load-test PROD pada Fase 0.

Rekonsiliasi source → tujuan legacy → Supabase dengan watermark sama: count/distinct/null/orphan/status/batch, total cb_net/gross_up/total_billing per depot/campaign/tahun, accepted/rejected dan upload belum termaterialisasi. Hasil harus PASS/FAIL dengan delta; saat ini **NOT_RUN**. Invalid tidak dibuang diam-diam.

## 10. Rollback dan rencana Fase 1–3

Tidak ada perubahan aplikasi/produksi pada audit ini. Cutover kelak membutuhkan backup privat terenkripsi, restore rehearsal, maintenance, final sync terkontrol, delta import, rekonsiliasi dan satu writer. Jika Supabase sudah menerima write, rollback memerlukan ekspor/replay delta dan rekonsiliasi; mengembalikan flag saja tidak cukup. Trigger lama dinonaktifkan setelah syarat cutover dipenuhi dan dipertahankan selama stabilisasi 14 hari.

| Fase | File rencana, belum dibuat | Prasyarat |
|---|---|---|
| 1 | .gitignore, .env.example, supabase/config.toml | Sumber/mapping cukup; registry DEV dan docs/environments.md sudah dibuat |
| 1–2 | supabase/migrations/*_core.sql, *_grants_rls.sql | Dictionary dan matriks akses disahkan |
| 2 | *_workflow_rpc.sql, *_campaign_upload.sql, *_document_lookup.sql | State/gross-up/batch/job/unique key/format disahkan |
| 2 | supabase/functions/admin-users/index.ts | Kebijakan Auth Admin dan secret |
| 2 | supabase/tests/database/*, tests/concurrency/* | Allow/deny, scope, idempotency, row/batch races |
| 3 | scripts/migration/*, sql/reconciliation/*, restore/benchmark reports | Ekspor, staging, transform dan rehearsal |

Harness audit yang tersedia merupakan karakterisasi Fase 0, bukan implementasi Supabase. Detail rancangan awal juga dipertahankan dalam baseline frontend.

## 11. Verifikasi aktual dan gerbang kelanjutan

Perintah:

~~~text
node docs/audit/characterize-backends.cjs
~~~

Hasil aktual: **26 PASS, 0 FAIL**. PASS berarti perilaku sumber direproduksi, termasuk cacat. Model tidak menguji Apps Script live, formula, persistensi saat kegagalan, concurrency nyata, RLS atau penerimaan bisnis. Sepuluh pemeriksaan frontend awal tetap hasil historis, bukan 10 pengujian baru.

SHA-256 empat sumber dicatat pada hasil/evidence. Source aplikasi dan staging Git pengguna dipertahankan. Bukti Supabase terdahulu tetap snapshot historis; status backend terkini menggunakan bukti backend baru.

Kedua backend tidak perlu dikirim ulang selama sumber tersimpan sudah lengkap. Lengkapi job/trigger, header/formula, metadata deployment dan keputusan bisnis sesuai [daftar bahan terbaru](phase-0-source-intake.md).

**BLOCKED_BY_SYNC_INVENTORY** — koneksi MCP dan audit kedua backend telah maju; mapping Upload → tujuan RC dan baseline produksi masih belum lengkap. Belum READY FOR PHASE 1.
