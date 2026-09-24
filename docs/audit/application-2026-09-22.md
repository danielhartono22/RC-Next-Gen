# Audit aplikasi dan perbaikan Access Management

Tanggal: 22 September 2026. Cakupan: source frontend/adapter, kontrak RPC/Edge, fungsi database, aturan integritas lintas modul, dan konfigurasi deployment. Ini bukan sertifikasi bahwa seluruh interaksi UI atau beban produksi sudah diuji.

## 1. Hasil utama

Registrasi memang tidak sinkron antara UI, adapter, Edge, Auth, dan profil. Perbaikannya sudah diterapkan pada database Supabase dan Edge `rc-admin` versi 4; source frontend dan build lokal diperbarui tanpa perubahan tata letak. **Frontend Vercel belum dideploy ulang pada pekerjaan ini**, sehingga halaman Vercel lama belum boleh dianggap memakai perbaikan Registrasi terbaru.

Hasil validasi: **63 test Node lulus, 34 assertion database Access lulus, 41 assertion database Approval lulus, dan 15 assertion HTTP Registrasi lulus**. Uji SQL menggunakan transaksi rollback. Uji HTTP membuat akun/depot dummy sementara; cleanup terverifikasi. Tidak ada akun nyata yang diubah PIN atau permission-nya dan tidak ada email pengujian yang dikirim.

Audit data menjalankan **36 aturan**: 19 menghasilkan nol temuan dan 17 menghasilkan baris yang perlu diperiksa. Jumlah antaraturan dapat tumpang tindih; tidak boleh dijumlahkan sebagai jumlah dokumen unik yang salah.

## 2. Environment dan ukuran data

| Komponen | Kondisi terukur/diketahui |
|---|---|
| Workspace | `D:\DANIEL\RC Next Gen`, Node 24, Windows |
| Frontend | Source `src/`, adapter Supabase, build statis `public/`, Vercel |
| Supabase | `vvojshgcduqlugngpzkj`; berlabel DEV pada registry lama, telah dipakai depot |
| Dataset audit | 2.756 claims, 2.067 customers, 100 campaigns, 52 depots |
| Akun | 7 profiles; 6 aktif |
| Schema publik | 24 base tables; tidak ditemukan RLS disabled pada aturan audit |
| Staging beban | Belum tersedia; tidak ada seed 1 juta atau stress test pada project operasional |
| Migration ledger remote | Versi terakhir `20260915071855`; tidak merepresentasikan semua DDL yang telah diterapkan manual |

Bukti agregat: [environment JSON](environment-2026-09-22.json), [hasil 36 aturan](application-2026-09-22.json), dan [query audit](../../supabase/queries/audit_application.sql). Tidak menyertakan nama customer, nomor rekening, token, atau PIN.

## 3. Cacat kode yang diperbaiki

| ID | Prioritas | Sebab dan dampak | Perbaikan / bukti |
|---|---|---|---|
| A01 | P1 | Form hanya mengenali sebagian role; Non-OSC berubah menjadi nama departemen dan OSC dapat terpetakan sebagai Admin | Katalog delapan role dari server; role/departemen disimpan terpisah; SQL menguji seluruh role |
| A02 | P1 | Adapter membuang home depot, depot assignment, OSC, dan region; Edge lama meminta suffix yang tidak dikirim | Kontrak lengkap dikirim; suffix dialokasikan server; validasi mapping sesuai role |
| A03 | P1 | Edge lama membuat Auth tanpa metadata trigger yang diperlukan, lalu mencoba INSERT profil lagi | Provisioning melalui trigger Auth, tanpa INSERT profil terpisah dari Edge |
| A04 | P1 | Admin Auth menulis app metadata setelah INSERT; implementasi yang hanya mengandalkan INSERT menghasilkan profil Pending walau Edge sukses | Trigger UPDATE metadata melengkapi transaksi; HTTP nyata membuktikan profil aktif + mapping + ledger + audit |
| A05 | P1 | Duplikasi request berpotensi memberi respons tidak konsisten | Request UUID + ledger privat + lock transaksi per request; dua request HTTP serentak mengembalikan ID akun yang sama; satu audit create |
| A06 | P1 | Approve pendaftaran mengaktifkan akun tanpa menyinkronkan depot | Review scoped, home depot dan grant depot diperbarui, akses efektif dibangun ulang |
| A07 | P1 | Menyimpan Edit Akses dapat menghapus permission approval/status saat field tidak dikirim | Approval flag ikut kontrak; field yang tidak dikirim dipertahankan; target dikunci saat update |
| A08 | P1 | Finance/Depot Head/Management tidak konsisten dengan `set_role`; region lama bisa tertinggal setelah ganti role | Role dikenali konsisten; mapping lama dibersihkan; region dikembalikan dalam readback |
| A09 | P1 | Target tanpa depot efektif dianggap otomatis berada dalam kewenangan Supervisor | Scope harus terbukti dari effective depot atau depot asal/permintaan yang sah; SM tetap khusus |
| A10 | P1 | Jalur legacy manage user/region tidak seluruhnya memvalidasi target dan assignment | Validasi manager, target, scope, jenis mapping, dan penggunaan sumber grant kanonis |
| A11 | P2 | Viewer kehilangan fungsi baca/search, backend hanya mengizinkan manager | Read scoped tersedia untuk viewer berizin; kontrol mutasi tetap ditolak di UI dan server |
| A12 | P2 | Sesudah create, daftar tidak direfresh; respons refresh lama bisa menimpa yang terbaru | Await refresh, penanganan hasil refresh gagal, sequence untuk mengabaikan respons lama |
| A13 | P2 | Placeholder PIN 4 tidak sesuai minimum backend 8 | Form/adapter/Edge konsisten 8 karakter, maksimum 72 byte; PIN tidak dipangkas |
| A14 | P1 | Registrasi kanonis uppercase tidak cocok dengan hash login berdasarkan casing input/legacy | Coba alias persis dahulu, fallback uppercase/lowercase hanya untuk invalid credentials; tidak mengubah Auth akun lama |
| A15 | P2 | Login UI memangkas spasi PIN yang sah | PIN dikirim utuh; uji adapter membuktikan nilai tidak berubah |
| A16 | P1 | Nama/label/perubahan profil/detail log diinterpolasi sebagai HTML | Escape field pada Access Management, multiselect bersama, dan log; uji payload HTML log |

P1 berarti berpengaruh pada integritas, otorisasi, atau alur utama; P2 berarti konsistensi/operasional yang penting. Tabel ini mencatat cacat yang ditemukan, bukan bukti bahwa kerentanan pernah dieksploitasi.

Sumber utama: [frontend Access](../../src/js/75-kelola-akses.js), [adapter](../../scripts/rc-legacy-adapter.js), [handler Edge](../../supabase/functions/rc-admin/handler.mjs), [migration Access](../../supabase/migrations/20261151010000_access_registration_sync.sql), [migration metadata Auth](../../supabase/migrations/20261151020000_registration_auth_metadata.sql), [lock request](../../supabase/migrations/20261151030000_registration_request_lock.sql).

## 4. Anomali data yang memerlukan rekonsiliasi

Data berikut **tidak diubah otomatis**. Khusus D07/D08/D15/D29, aturan merupakan sinyal review, bukan vonis bahwa semua baris salah.

| ID | Aturan | Terdampak | Dampak dan tindak lanjut |
|---|---|---:|---|
| D06 | Cashback net <= 0 | 52 klaim | Cek sumber compile dan kelayakan transaksi; jangan mengganti nominal dengan tebakan |
| D07 | Cashback > net value positif | 236 klaim | Konfirmasi formula campaign/sumber kolom; mungkin pengecualian bisnis |
| D08 | Volume = net value positif | 134 klaim | Indikasi tercampurnya satuan uang/volume; pemeriksaan ini spesifik kesamaan persis |
| D09 | Released/Claimed/Done tanpa uploaded_at | 1.733 klaim | Timeline dan aging historis tidak lengkap; rekonstruksi hanya dari bukti sumber |
| D10 | Done tanpa cleared_at | 57 klaim | Report per bulan clearing dapat kehilangan klasifikasi |
| D11 | Done tanpa batch clearing | 592 klaim | Telusuri penyelesaian historis; pisahkan RA07/penyelesaian khusus sebelum menganggap semua error |
| D13 | Customer aktif tanpa mapping depot | 637 customer | Tidak terlihat pada scope depot; pemilik master harus menetapkan hubungan yang benar |
| D14 | Customer aktif tanpa KTP maupun NPWP | 168 customer | Penentuan subyek pajak/kelengkapan upload dapat terhalang |
| D15 | Customer aktif memiliki KTP dan NPWP | 4 customer | Perlu aturan pemilihan subyek pajak; dua identitas bukan otomatis data palsu |
| D16 | Klaim Transfer Not Yet, tidak pending/arsip, rekening master belum lengkap | 318 klaim | Dapat tertahan validasi upload sampai bank/nomor/nama rekening dilengkapi |
| D17 | Campaign aktif period_end < period_start | 1 campaign | Koreksi berdasarkan periode sumber yang sah |
| D18 | Campaign aktif tanpa satu/dua batas periode | 22 campaign | Lookup periode dan laporan tidak lengkap |
| D19 | Campaign aktif tanpa status pajak | 1 campaign | Resolver perhitungan tidak memiliki input master lengkap |
| D23 | Akun aktif non-SM tanpa depot efektif | 2 akun | Dapat login tetapi modul scoped kosong; pengelola melengkapi mapping sesuai kewenangan |
| D24 | Akun aktif role nonintrinsik tanpa permission eksplisit | 1 akun | Bisa merupakan akun baru yang belum dikonfigurasi; jangan grant semua modul otomatis |
| D29 | Alias Auth berbeda dari hash User ID pada profil | 6 akun aktif | Fallback casing telah ditambahkan; alias impor yang tidak sesuai upper/lower tetap perlu rekonsiliasi |
| D36 | Email outbox berstatus gagal | 2 pesan | Tinjau error/provider/tujuan; tidak dikirim ulang dalam audit ini |

Jumlah ini adalah snapshot 22 September. Perbedaan dari laporan 20 September dapat berasal dari perubahan data, normalisasi status, atau definisi aturan. Contohnya D09 memasukkan Done; D08 hanya menguji kesamaan persis volume dan nilai. Jangan membandingkan dua angka yang definisinya berbeda sebagai tren mutu data.

## 5. Aturan tanpa temuan

| ID | Pemeriksaan | Temuan |
|---|---|---:|
| D01 | Status klaim di luar daftar kanonis/legacy yang diakui | 0 |
| D02 | Nomor dokumen duplikat setelah trim/uppercase | 0 kelompok |
| D03 | Pending submit tetapi status bukan Not Yet | 0 |
| D04 | Pending Hold/Expired sudah memakai status yang diminta | 0 |
| D05 | Pending aktif tidak memiliki requester | 0 |
| D12 | Periode klaim terbalik | 0 |
| D20 | Profil aktif tanpa Auth | 0 |
| D21 | Profil Pending sudah memiliki permission | 0 |
| D22 | Profil Pending sudah memiliki akses depot efektif | 0 |
| D25 | Suffix aktif duplikat | 0 kelompok |
| D26 | Materialisasi akses berbeda dari effective_depots | 0 akun |
| D27 | Relasi supervision memiliki role yang salah | 0 |
| D28 | Grant region tersisa pada role non-Management | 0 |
| D30 | Base table publik tanpa RLS | 0 tabel |
| D31 | Foreign key public/private yang belum tervalidasi | 0 constraint |
| D32 | Grant tulis anonymous pada tabel inti yang diaudit | 0 grant |
| D33 | Grant tulis langsung authenticated pada claims | 0 grant |
| D34 | Security definer public/private tanpa fixed search_path | 0 fungsi |
| D35 | Outbox Pending lebih dari satu hari | 0 pesan |

Nol pada pemeriksaan grant/RLS tidak membuktikan seluruh policy bebas kelemahan. Cakupan tiap query tercantum eksplisit dalam SQL; audit tidak mengklaim penetration test menyeluruh.

## 6. Anomali arsitektur/operasional yang masih terbuka

| ID | Prioritas | Bukti/kondisi | Rekomendasi konkret |
|---|---|---|---|
| O01 | P1 sebelum scale | `rc_private.legacy_documents` mengambil maksimum 20.000 dokumen; `rc_legacy_logs` maksimum 2.000 log; sebagian pagination/filter memakai array browser | Pindahkan list/search/sort/page ke endpoint server dengan count/continuation eksplisit. Dataset di atas batas berisiko terpotong tanpa disadari |
| O02 | P1 sebelum 1.000 akun | `next_suffix` mencari 001–999; suffix yang dipakai batch counter juga tidak dipakai ulang | Putuskan format batch/suffix lebih besar dengan pemilik sebelum menguji 1.000 akun unik. Virtual users tidak sama dengan akun unik |
| O03 | P1 | Registry menyebut DEV, tetapi project sudah dipakai depot; staging belum dibuat | Pisahkan staging, key, frontend, dataset dummy, dan observabilitas sebelum uji beban |
| O04 | P1 | Ledger remote berhenti 15 September, banyak migration berikutnya diterapkan melalui SQL API | Rekonsiliasi schema/function hash dan ledger sebelum db push; jangan menjalankan bundle lama secara buta |
| O05 | P2 | README/read.md/dokumen migrasi lama menyatakan Auth/backend belum ada | README diperbarui sebagai pintu masuk; dokumen lama diberi konteks historis dan tautan PRD/audit terbaru |
| O06 | P2 | CSP masih `unsafe-inline`/`unsafe-eval`; banyak modul menggunakan template HTML | Escape diperbaiki pada sink yang diperiksa. Audit sink modul lain dan pindahkan inline handler bertahap; belum dinyatakan seluruh DOM aman |
| O07 | P2 | Dependensi frontend CDN dan import Supabase `@2` bukan lock versi patch lengkap | Pin versi/hash yang teruji dan tetapkan jadwal update; jangan upgrade paket sebagai bagian audit bisnis tanpa regresi |
| O08 | P2 | Script HTTP E2E lama menganggap submit langsung boleh release | Tidak digunakan sebagai bukti versi sekarang; gate legacy ditambahkan agar tidak memberi hasil menyesatkan. Gunakan suite approval terkini |
| O09 | P2 | Vercel belum menerima frontend perubahan ini | Build sudah diuji lokal; deploy frontend dan verifikasi Registrasi setelah release. Backend baru menolak payload lama yang tidak lengkap |
| O10 | P2 | Kontrol percobaan PIN di browser bukan batas keamanan server | Verifikasi konfigurasi rate limit Auth pada staging; fallback casing dibatasi dan berhenti saat Auth throttling |

## 7. Cakupan pemeriksaan per modul

| Area | Bukti yang dijalankan/diperiksa | Batas |
|---|---|---|
| Registrasi/Access | 34 SQL assertions, kontrak/UI VM, 13 HTTP assertions | HTTP role utama Non-OSC; variasi seluruh role diuji SQL, bukan klik browser semua role |
| Login/PIN | Native HTTP login/ganti PIN; tes casing dan preservasi spasi | Tidak mencoba password akun nyata; tidak mengubah alias lama |
| Management Approval | 41 SQL assertions + regresi frontend | Fixture sintetis rollback; bukan UAT semua dokumen operasional |
| Upload/parser | Suite CSV, angka/tanggal/header/versi; aturan mutu master | Tidak mengunggah file bisnis nyata pada audit ini |
| Release/Claim/Clearing | Regresi transisi normal dan Expired langsung | Tidak mengirim pembayaran atau menjalankan transaksi real |
| Bulk/Reprocessing/Arsip | Referensi action/RPC, penolakan bypass pending, schema | UAT bisnis tiap kombinasi masih perlu |
| Key Master/depot | Relasi/schema, angka/tanggal, scope dan mapping akun | Data master anomali tidak dikoreksi tanpa sumber |
| Report/dashboard | Tes render/data/filter publik, source komponen bersama | Tidak memverifikasi seluruh file Excel secara visual atau mengukur performa 1 juta baris |
| Timetable | Pemeriksaan structural action/RPC/ID markup | Alur kalender pengguna nyata belum diuji klik |
| Profil/PIN request | Pembatasan reviewer/scope, inbox dan kontrak akses | Tidak mengirim notifikasi ke pengguna nyata |
| Log/email | Agregat outbox, escaping render log, grant/privilege | Tidak mengirim/retry email; deliverability belum diuji |
| Compile RC / Document Center | Inventaris source, relasi kontrak, batas cakupan | Integrasi Document Center legacy masih ditunda |
| Deployment | Build, syntax, header/rute lewat suite lokal, backend HTTP | Tidak ada deployment frontend Vercel baru atau visual browser penuh |

Pemeriksa sistem mencocokkan 68 action dan 68 RPC pada adapter serta referensi markup/fungsi; tidak ditemukan referensi hilang pada pemeriksaan tersebut. Pemeriksa SQL bundle tidak dijadikan bukti lulus seluruh migration karena `supabase/apply-pending.sql` tidak tersedia.

## 8. Bukti dan perintah reproduksi

```powershell
npm run build
npm run check
npm test
node scripts/check-system.mjs --db
node scripts/test_access_registration.mjs --candidate  # rollback seluruh DDL + fixture
npm run test:access:db                                 # rollback fixture
npm run test:approval:db                               # rollback fixture
npm run audit:application                             # SELECT aggregate, read-only
node scripts/test_registration_http.mjs                # dummy sementara + cleanup
```

Script HTTP memakai Admin API hanya untuk fixture dummy dan tidak boleh dijalankan sebagai load generator. Secret dibaca dari environment/Management API ke memori, tidak dicetak. Semua code akun/depot menggunakan prefix UUID; cleanup membatasi target ke fixture eksekusi itu. Awal pengujian HTTP menemukan pending-profile bug; hasil tersebut gagal dan **tidak** dihitung sebagai PASS. Setelah trigger dan lock per request diperbaiki, run terakhir lulus 15 assertion dengan `cleanup=true`. Lock menyelaraskan pembacaan ledger/profil saat request bersamaan; tanpa lock, snapshot READ COMMITTED dapat melihat profil baru sebelum pembacaan ledger diulang.

Artefak lokal yang sengaja tidak dipublikasikan sebagai data bisnis:

- `.runtime/access-audit/test-applied.json`: hasil 34 pemeriksaan Access.
- `.runtime/approval-fix/test-applied.json`: hasil 41 pemeriksaan Approval.
- `.runtime/access-audit/http-smoke.json`: hasil HTTP dan bukti cleanup.
- `.runtime/access-audit/edge-deployed.json`: Edge v4, ACTIVE, verify_jwt=true, hash bundle.
- `.runtime/access-audit/applied*.json`: waktu/hash migration yang diterapkan.
- `.runtime/access-audit/before-apply-functions.json`: definisi fungsi sebelum perbaikan.
- [verification JSON](verification-2026-09-22.json): ringkasan bukti tanpa secret/data personal.

## 9. Kinerja dan klaim pengujian

**Tidak ada uji 1.000 concurrent users atau 1.000.000 rows pada pekerjaan ini.** Dua request registrasi serentak merupakan uji race/idempotensi terbatas, bukan load test. Latency percentile, RPS, breaking point, resource utilization, dan recovery belum diukur pada environment staging target.

| Users | Dataset | Avg | P95 | P99 | RPS | Error Rate | Timeout | Status |
|---:|---|---|---|---|---|---|---|---|
| 100 | Target 1.000.000 dummy | — | — | — | — | — | — | Belum dijalankan |
| 250 | Target 1.000.000 dummy | — | — | — | — | — | — | Belum dijalankan |
| 500 | Target 1.000.000 dummy | — | — | — | — | — | — | Belum dijalankan |
| 750 | Target 1.000.000 dummy | — | — | — | — | — | — | Belum dijalankan |
| 1.000 | Target 1.000.000 dummy | — | — | — | — | — | — | Belum dijalankan |
| 1.250–1.500 | Target stress | — | — | — | — | — | — | Belum dijalankan |

Bottleneck yang **diprediksi dari kode**, belum dibuktikan dengan beban: transfer dataset saat bootstrap, pagination client, batas query legacy, dan batas suffix. Breaking point/recovery: belum diketahui. Lihat [PRD](../PRD-Resource-Collection.md) dan [rencana load test](../load-test-plan.md) untuk syarat pengujian berikutnya.

## 10. Urutan tindakan

1. Gunakan frontend terbaru di localhost untuk UAT Registrasi; release frontend Vercel diperlukan agar perbaikan UI tersedia di URL publik.
2. Pengelola menyelesaikan 2 akun tanpa depot dan 1 tanpa permission sesuai tanggung jawab aktual, bukan grant semua.
3. Pemilik master/Finance merekonsiliasi rekening, periode, pajak dan nilai sumber; jalankan ulang audit setelah koreksi.
4. Rekonsiliasi migration ledger, siapkan staging terpisah, lalu selesaikan pagination dan kapasitas suffix.
5. Lakukan UAT semua modul/role dan pengujian beban terukur. Jangan menyatakan aplikasi siap 1 juta baris sebelum bukti tersebut tersedia.
