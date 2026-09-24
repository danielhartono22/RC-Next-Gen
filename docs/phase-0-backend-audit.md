# Fase 0 — Audit backend Resource Collection dan Document Center

Tanggal: 14 September 2026. Sumber baru: `ResourceCollection` (70.781 byte, 1.558 baris) dan `DocumentCenter` (23.281 byte, 502 baris), keduanya dibaca penuh. RCB = backend Resource Collection; DCB = backend Document Center; RCF/DCF = frontend `index (4).html` / `index (5).html`. Referensi `RCB:500` berarti baris 500 sumber lokal, bukan deployment yang telah diverifikasi.

**Audit sumber backend dan 26 karakterisasi offline selesai untuk cakupan di bawah. Status migrasi tetap BLOCKED_BY_SYNC_INVENTORY.** Tidak ada request ke Apps Script, perubahan Supabase PROD, atau edit empat file sumber aplikasi. Versi deployment, header aktual, data dan job eksternal belum diverifikasi.

Bukti: [inventaris sumber](phase-0-backend-evidence.json), [hasil 26 pemeriksaan](phase-0-backend-test-results.json), [harness offline](audit/characterize-backends.cjs). Laporan induk: [audit Fase 0](phase-0-audit.md).

## 1. Konfigurasi dan batas arsitektur

- `ResourceCollection:4-13,98-100` memilih `ENV="DEV"`. Konfigurasi berisi Spreadsheet DEV dan PROD berbeda. Kode lokal belum membuktikan deployment aktif memakai DEV atau PROD.
- `DocumentCenter:48-49` mempunyai `COMPILE_SS_ID` untuk `Upload`, `ListCampaign`, `Depot_ID`; `AUTH_SS_ID` untuk `Authority`, `DM-30D`, `LogActivity`.
- `AUTH_SS_ID` Document Center **sama dengan** ID Spreadsheet PROD pada konfigurasi RC. Spreadsheet upload Document Center berbeda dari keduanya; perbandingan ID dicatat tanpa menyalin credential.
- Supabase `vvojshgcduqlugngpzkj` semula disebut PROD ketika audit ini dijalankan; pemilik kemudian menetapkannya sebagai **DEV**. Acuan terkini: [lingkungan proyek](environments.md). Keputusan Supabase ini tidak mengubah atau mengonfirmasi `ENV` backend legacy.
- Tidak ditemukan fungsi copy/sync antar-Spreadsheet, pembuatan trigger 15 menit, atau implementasi pemindahan `Upload` ke `Compile` dalam dua file backend. `perbaikiGrossUpSekarang` hanya menghitung ulang satu kolom `Compile`; bukan job pemindahan data. Trigger yang dibuat melalui dashboard dan formula Spreadsheet tidak dapat diketahui dari ketiadaan kode pembuat trigger.

## 2. Rute, otorisasi dan sheet

RC memiliki 17 rute bisnis: 2 publik dan 15 yang memerlukan token. `doOptions` juga ada, tetapi bukan rute bisnis; tidak ditemukan `doGet`. Frontend memanggil `logout`, tetapi router tidak mempunyai handler tersebut.

| Rute RC | Pemeriksaan di sumber | Pembacaan / penulisan |
|---|---|---|
| login | ID/PIN plaintext dan activation approved/ok/active | Baca Authority, DepoMaster, Compile, ListCampaign, ListCust; respons dataset penuh |
| logActivity | Publik; actor/role/timestamp dari body | Append LogActivity |
| refreshDocuments | Token di router; tanpa scope depot | Baca seluruh Compile |
| getLogActivity | Token; tanpa pemeriksaan permission/role/depot handler | Baca seluruh LogActivity |
| submitData | Token; suffix batch dari token; tidak memeriksa permission/depot/customer claim | Baca/tulis Compile, ListCust, BatchLog |
| getWorkflowData | Token; role/id/depot scope dari body; Released/Claimed non-rebate lolos scope | Baca Compile, DepoMaster, ListCampaign |
| processWorkflow | Token; suffix batch dari token; tanpa permission/depot; expected stage tidak ditegakkan | Baca/tulis Compile, BatchLog |
| toggleOnHold / markExpired | Token; tanpa permission/depot | Baca/tulis Compile |
| bulkFastTrackRelease | Token; cek master/snapshot rebate dan tiga status; tanpa permission/depot | Baca/tulis Compile, BatchLog; baca ListCampaign |
| getDashboardData | Token; scope ditentukan dari body | Baca Compile dan DepoMaster |
| getManageableData | Token; role/id dari body menentukan user/depot/request yang terlihat | Baca Authority, DepoMaster, ReqProfile |
| addAccount | Token; tanpa hak admin server | Append Authority; update DepoMaster untuk mapping |
| updateUserAccess | Token; flags dan approve PIN ditulis tanpa hak admin; mapping memakai role body | Update Authority dan DepoMaster |
| requestPinChange | Token; user target berasal dari body, tidak diikat ke actor token | Tulis pending PIN Authority kolom O |
| submitProfileUpdate | Token; actor/depot dari body | Buat/append ReqProfile bila perlu |
| approveProfileRequest | Token; tanpa role approver; reqId berupa nomor baris | Tulis ReqProfile dan DepoMaster |

Rujukan router RCB:450-494; fungsi/nomor baris lengkap ada pada bukti JSON. `serverAuth` hanya dipakai untuk suffix generator batch pada tiga handler mutasi; role/id dari sesi tidak menjadi sumber otorisasi handler tersebut. Tidak ada pencatatan status history atomik.

| Jalur DC | Validasi nyata | Sheet |
|---|---|---|
| login | Membandingkan Authority E/F sebagai string; tidak memeriksa status akun | Authority di AUTH_SS_ID |
| previewCashback | Menambahkan nama campaign atau label tidak ditemukan; tetap success | ListCampaign di COMPILE_SS_ID |
| submitCashback | Dedup internal dan terhadap cache/sheet; tanpa sesi, role, depot, validasi ulang master/angka | Upload, Depot_ID; kemudian LogActivity |
| log_print | Tanpa sesi; detail caller | LogActivity |
| default, termasuk lookupBatch dan action tak dikenal | Tipe upload/claim, batch array, hasil maksimum 200/2.000; tanpa sesi/depot | DM-30D; kemudian LogActivity |

Tidak ada route DC yang memverifikasi token Resource Collection atau membuat/mewajibkan sesi hasil login DC (DCB:113-154). Akses deployment Google pada lapisan luar belum diuji; temuan di sini menyatakan tidak ada otorisasi aplikasi pada sumber yang diberikan.

## 3. Matriks role × permission × depot yang terverifikasi

Matriks UI J/K/L/M/N/P/Q/S dan role ada pada [baseline frontend](phase-0-frontend-baseline.md). Matriks tersebut **tidak ditegakkan sebagai kebijakan server**:

| Identitas pada pengujian sintetis | Hasil handler sumber | Bukti uji |
|---|---|---|
| Tanpa token RC | Rute privat RC ditolak; logActivity diterima | B02, B05 |
| Admin RC depot A | Login mengirim dokumen/customer depot lain; seluruh log dapat dibaca | B03, B04 |
| Admin RC depot A, body jujur | Workflow Released depot B ikut diterima | B06 |
| Admin RC, role body diganti System Manager | Dashboard scope melebar | B07 |
| Admin RC | Bisa membuat akun System Manager dan mengubah permission user lain | B08, B09 |
| Pemegang token RC yang sudah diterbitkan, akun kemudian inactive | Refresh masih berhasil; logout tidak mencabut token | B10 |
| Admin RC depot A | Bisa mengubah claim depot B | B11–B14 |
| Tanpa login aplikasi DC | Submit dan lookup diterima | B19, B20 |
| Akun inactive pada Authority | Login DC diterima | B20 |

Login RC memang menghitung `managedDepots` dari DepoMaster: Supervisor/System Manager memperoleh seluruh depot, admin mendapat depot terkait Authority/admin slots, OSC/non-OSC menggunakan daftar mapping; subtag diperluas (RCB:552-588). Masalahnya adalah hasil tersebut tidak digunakan kembali sebagai sumber otorisasi pada semua request. Tidak ada kebijakan allow/deny produksi yang dinyatakan sudah aman.

## 4. State machine aktual dan side effect

| Jalur | Perilaku sumber | Field yang berubah / masalah |
|---|---|---|
| submitData | Not Yet → Submitted; **Released → Submitted juga diterima** | Isi L:AI, gross-up AK, rekening AN:AP; master customer bisa berubah |
| approve release | Submitted → Released; generic validator juga menerima Claimed → Released | Status, tanggal release AC, batch release AG; `expectStatus` tidak dipakai |
| approve claim | Released → Claimed | Status, tanggal claim AD, batch claim AH |
| approve clearing | Claimed → Done; **Submitted → Done juga diterima**, termasuk non-rebate | Status, tanggal clearing AE, batch clearing AI; B11 |
| reject release | Submitted → Not Yet | Kosongkan tanggal upload AB dan batch upload AF |
| reject claim | Released → Submitted | Kosongkan tanggal release AC dan batch release AG |
| reject clearing | Claimed → Released | Kosongkan tanggal claim AD dan batch claim AH |
| Hold | Semua nilai selain Done/Expired/On Hold → On Hold | Simpan previous_status AJ; termasuk Released, Claimed, RA7 dan nilai tak dikenal |
| Unhold | On Hold → previous_status, fallback Not Yet | Kosongkan previous_status; tidak memvalidasi ulang nilai sebelumnya |
| markExpired | Semua nilai selain Done/Expired → Expired | Termasuk On Hold dan RA07/RA7 |
| processWorkflow expired | Mengikuti generic validator | Berbeda dari markExpired; misalnya On Hold → Expired tidak ada di validator |
| bulk rebate | Submitted/Released/Claimed → Done jika jenis rebate | Batch tahap 02 di AG; tanggal release/claim/clearing dan batch claim/clearing diisi literal `x` |
| RA07 / RA7 | Analytics memetakan menjadi Done | Handler exception tidak menormalisasi alias tersebut |

RCB:140-160,655-795,862-1181. `expectStatus` pada RCB:880 didefinisikan tetapi tidak diperiksa. Transisi normal target harus divalidasi terhadap tahap, permission, depot dan status saat transaksi; tabel validator generik saja tidak cukup. Perubahan perilaku harus diputuskan sebagai koreksi yang eksplisit, bukan dianggap paritas yang wajib dipertahankan.

Counter batch sumber memakai tahap + tanggal sebagai kunci cache/fallback scan, **tanpa suffix**. Nomor tetap memuat suffix tiga digit, timezone Asia/Jakarta, dan counter empat digit. Setelah 9999, `slice(-4)` membungkus ke 0000 lalu dapat mengulang 0001; alokasi dapat terjadi walaupun tidak ada row valid (RCB:278-325,681,875-877,1128). Target instruksi memakai counter per tahap+suffix+tanggal; perbedaan ini memerlukan keputusan migrasi, termasuk kebijakan overflow.

## 5. Pemetaan upload yang kini dapat dibuktikan

Frontend membaca delapan posisi file dan meneruskan payload. Backend menulis **mulai baris 3** pada sheet Upload, berdasarkan last row di kolom C:

| Payload | Kolom Upload | Perlakuan commit backend |
|---|---|---|
| kodeCampaign | C | String + trim |
| dc | E | Diteruskan dari body |
| custCode | G | String + trim |
| custName | H | Diteruskan dari body |
| netValue | I | Diteruskan; tidak divalidasi sebagai numeric |
| total | K | Diteruskan; Number hanya dipakai untuk ringkasan |
| jenisCb | N | Diteruskan dari body |
| beforeTaxVal | O | Diteruskan dari file/body; tidak dihitung ulang |
| waktu server | T | Menggunakan timezone project Apps Script yang belum diketahui nilainya |
| username | U | Actor dari browser; bukan identitas sesi |

Kolom A,B,D,F,J,L,M,P,Q,R,S tidak ditulis oleh fungsi commit. Komentar menyebut rumus pada kolom tersebut, tetapi formula aktual tidak disertakan dan tidak dibuat oleh kode ini. Secara khusus, No Document tidak dibuat pada handler upload ini. Rujukan DCB:393-465.

Dedup memakai string `trim(campaign) + '_' + trim(customer)`, peka huruf besar/kecil, tidak menyertakan depot/periode/jenis CB. Internal batch mengambil baris pertama dan menolak duplikat berikutnya; duplikat terhadap indeks juga ditolak. Hasil **partial accept** adalah fakta implementasi sekarang (B22), bukan persetujuan bahwa target bisnis harus sama. Kunci bertabrakan bila komponen mengandung underscore (B23).

Indeks cache dapat menjadi usang ketika baris lama diedit, dihapus, atau key berubah dengan lastRow sama/berkurang. Kode hanya membaca delta ketika lastRow bertambah; label komentar “self-healing” tidak membuktikan konsistensi sebelum cache hilang (DCB:334-363, B24). Cache bersifat sementara menurut [dokumentasi Google](https://developers.google.com/apps-script/reference/cache/cache); jaminan keunikan target harus berasal dari constraint database.

Commit memakai enam `setValues` terpisah, kemudian flush, cache dan log setelah lock dilepas. Tidak ada rollback. B25 menginjeksi kegagalan setelah kolom C ditulis di fixture sehingga baris parsial tertinggal; persistensi aktual dan retry pada Google Sheets belum diukur. Retry sukses normal menolak row lama sebagai duplikat, bukan mengembalikan hasil commit semula berdasarkan idempotency key.

**Masih UNKNOWN:** formula sumber, pembentukan No Document, tujuan/materialisasi Upload → Compile, checkpoint, trigger owner, overlap/retry dan backlog. Sparse write yang sudah dipetakan belum menyelesaikan jalur sinkronisasi.

## 6. Gross-up dan data dictionary

Backend `calcGrossUpCB` mengabaikan parameter status pajak campaign dan menghitung semua campaign berdasarkan Badan/perseorangan (RCB:245-273). Frontend ekspor mengembalikan nol untuk status yang mengandung NIPSEA/ditanggung perusahaan/ditanggung PT (RCF:1737-1756). B15 mereproduksi net 85.000 Badan NIPSEA: backend 100.000, frontend 0, serta empat batas progresif backend. Ini perbandingan kode, bukan penilaian kebenaran tarif pajak.

`COL_COMPILE` berisi **indeks array zero-based**. Contoh No Document index 1 = kolom B; status index 26 = AA; previous_status index 35 = AJ; gross_up index 36 = AK; rekening 39–41 = AN:AP. Seluruh 39 field beserta huruf kolom ada pada `compile_mapping_from_code_only` di [bukti JSON](phase-0-backend-evidence.json). Nama tersebut adalah label kode, bukan header produksi yang dikonfirmasi.

| Sheet | Mapping yang dibuktikan dari kode | Yang belum tersedia |
|---|---|---|
| Authority | A region, B nama, C/D depot, E ID, F PIN, G email, H role, I activation, J:N permission, O pending PIN, P/Q permission, R suffix, S bulk | Header aktual, kebijakan retensi credential dan data anonim |
| ListCampaign RC | A code, B nama, C/D periode, F status pajak, G jenis CB, V/W master code/nama | Header/formula/master yang aktif |
| ListCampaign DC | A code, B nama pada Spreadsheet upload | Rekonsiliasi dengan master RC yang terpisah |
| ListCust | B code, D rekening, E nama rekening, F bank, G NPWP, H KTP, I subjek, K TOP | Header, leading zero, relasi, validasi update master |
| DepoMaster | A region, B code, C nama, H:J admin, K OSC, L non-OSC, M masterLink, N subtag, R:X jumlah karyawan saat update | **M juga ditulis sebagai alamat** oleh approveProfileRequest; harus dikonfirmasi dari header |
| ReqProfile | Header dibuat kode: Timestamp, Role Requester, Kode Depot, Nama Depot, Requester ID, Payload JSON, Status | Versi sheet aktif; id stabil pengganti nomor baris |
| BatchLog | Header dibuat kode: Batch Number, Stage, Timestamp | Rekonsiliasi counter dan uniqueness historis |
| Upload | C/E/G:I/K/N:O/T:U seperti tabel di atas | Seluruh header dan formula kolom lain |
| DM-30D | B:AH dibaca; AF batch upload, AH batch claim; 17 properti respons | Header aktual, formula/join dari Compile, format ekspor |
| Depot_ID | A code, B nama | Relasi dengan DepoMaster RC |
| LogActivity | Empat posisi timestamp/actor/role/detail; DC mengosongkan actor/role | Writer lain, retensi, integritas log |

`handleSubmitData` memilih master customer berdasarkan `d.custCode` body, tidak mencocokkan dengan customer pada claim, kemudian memperbarui rekening/NPWP/KTP/subjek/TOP. B12 mengonfirmasi customer sintetis lain dapat berubah. Profil approval menulis `changes.alamat` ke index 12 yang dibaca sebagai `masterLink` pada login (B18). Header aktual wajib mendasari koreksi mapping.

## 7. Risiko, bukti dan prioritas

| ID | Tingkat audit | Temuan | Bukti |
|---|---|---|---|
| BK01 | Kritis pada sumber | DC submit/lookup tanpa otorisasi aplikasi; actor browser | DCB:113-154,369-502; B19–B21 |
| BK02 | Kritis pada sumber | Token admin biasa cukup untuk membuat akun berprivilege/ubah akses | RCB:1321-1447; B08–B09 |
| BK03 | Tinggi | Full bootstrap PII, log tak dibatasi, workflow/analytics bocor scope | RCB:508-652,797-859,1183-1239; B03–B07 |
| BK04 | Tinggi | Transisi tahap dapat dilewati dan dokumen lintas depot berubah | RCB:880-920; B11–B14 |
| BK05 | Tinggi | Secret HMAC tertanam pada sumber; PIN plaintext; sesi 12 jam tanpa recheck akun/logout | RCB:27,112-135,538,1378,1457; B10. Nilai secret tidak disalin ke laporan/test |
| BK06 | Tinggi | Perbedaan gross-up, customer master tak terikat claim, alamat menimpa link | B12, B15, B18 |
| BK07 | Tinggi | Sparse write/kolom dan multi-sheet bukan transaksi; idempotency tidak tersedia | RCB:756-784; DCB:458-493; B25 |
| BK08 | Tinggi | Batch overflow, shared counter; lock internal dilepas sebelum handler selesai | RCB:278-325,659-660,869-877; B16–B17 |
| BK09 | Sedang–tinggi | Dedup beda depot/underscore dan indeks stale | DCB:334-363,381,422; B22–B24 |
| BK10 | Sedang–tinggi | Unknown campaign/nilai negatif diterima; formula/ukuran upload tidak divalidasi server | DCB:257-263,419-445; B21 |

Tingkat di atas adalah triase kode. Eksploitasi deployment produksi tidak dilakukan. Secret terdeteksi dalam file aplikasi yang sudah berada di staging Git pengguna saat inspeksi; agent tidak mengubah index Git dan tidak melakukan commit/push. Kelak pindahkan secret ke konfigurasi privat dan rotasi melalui prosedur pemilik sebelum publikasi; nilai lama tidak digunakan oleh harness.

**Lock:** handler RC mengambil script lock lalu generator batch mengambil lock yang sama dan melepasnya di `finally`. Model offline menunjukkan penulisan Compile berikutnya terjadi ketika lock sudah dilepas. [Dokumentasi Google Lock](https://developers.google.com/apps-script/reference/lock/lock) menyatakan akuisisi ulang pada lock yang sudah dimiliki tidak berefek dan release membuka akses pemanggil lain; flush direkomendasikan sebelum release. B17 adalah reproduksi dengan model ini, bukan load test concurrency Apps Script. Tidak menyimpulkan deadlock dari pemanggilan lock bertingkat.

## 8. Performa yang kini terbukti dari sumber

- `readSheet` membaca semua baris/kolom setelah header; login memuat Compile/campaign/customer penuh. Refresh tetap full scan meski komentar menyebut “ringan”.
- Workflow membaca seluruh Compile dan master campaign; dashboard mengirim history dan compileData; log dibaca penuh lalu dibalik urutannya.
- DepoMaster memakai cache 300 detik; generator batch memakai cache enam jam per tahap/tanggal dan fallback scan BatchLog; DC cache master 300 detik dan indeks upload enam jam/delta. Optimalisasi ini memang ada, sehingga baseline tidak boleh menyatakan setiap request selalu full scan master/indeks tanpa pengecualian.
- DC print membaca seluruh B:AH sebelum filter; batas hasil 200/2.000 memang ditegakkan backend, tetapi tidak mengurangi rentang sumber yang dibaca (B26). Pagination preview tetap di browser.
- DC submit mengirim seluruh row; RC menulis blok baris/kolom. Durasi, p50/p95, payload produksi, cache hit rate dan beban 60 user belum diukur. Klaim komentar peningkatan 70% tidak diperlakukan sebagai hasil benchmark.

## 9. Verifikasi dan kelanjutan

Jalankan dari root workspace:

```text
node docs/audit/characterize-backends.cjs
```

Hasil aktual: **26 PASS, 0 FAIL**. PASS berarti perilaku legacy direproduksi, termasuk defect. Harness menjalankan fungsi asli dengan layanan Apps Script tiruan, data sintetis, tanggal format fixture, cache in-memory, dan secret sintetis; tidak membuka network. Tidak memvalidasi efek deployment, formula Google Sheets, commit persistence, cache eviction/TTL, concurrency nyata, RLS atau aturan bisnis target.

Mapping sumber/backend sekarang tersedia, tetapi fungsi/trigger sinkronisasi, header/formula dan metadata deployment masih diperlukan. Keputusan D01/D02/D04/D05/D06/D09/D12 kini memiliki bukti kode yang lebih kuat; pemilik tetap perlu menetapkan perilaku target. Tidak membuat schema final atau mengganti job dengan asumsi.

**BLOCKED_BY_SYNC_INVENTORY** — audit backend maju; jalur Upload → tujuan RC belum dapat dipetakan end-to-end.
