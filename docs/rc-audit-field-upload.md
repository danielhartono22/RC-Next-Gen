# Audit mendalam: mengapa upload menolak dengan "field tidak ditemukan"

Ditulis 20 September 2026. Seluruh angka di sini diukur langsung dari project
`vvojshgcduqlugngpzkj`, bukan perkiraan. Pembuktiannya dijalankan di dalam transaksi yang
dibatalkan, sehingga tidak ada data produksi yang berubah selama pemeriksaan.

---

## 1. Ringkasan

Upload gagal **seluruhnya** — bukan sebagian. Penyebabnya bukan data yang salah, melainkan dua
fungsi di basis data yang tidak sepakat tentang satu field: `jenis_cashback`.

Bekasnya terbaca dari riwayat sistem sendiri. Tabel `claim_status_history` hanya memuat
**2 baris** ber-`action = 'submit'` sepanjang riwayat. Untuk sistem dengan 2.754 klaim aktif,
itu bukan angka yang mungkin terjadi bila upload pernah bekerja.

Ada **dua cacat beruntun**, dan yang kedua justru lebih besar:

| | Cacat | Dampak |
|---|---|---|
| 1 | `rc_private.mutate_claims` tidak mengizinkan field `jenis_cashback` | **100%** upload gagal |
| 2 | Daftar jenis yang sah tidak mengakui `Voucher` | **421 dari 831** klaim *not_yet* akan gagal setelah cacat 1 diperbaiki |

Memperbaiki cacat 1 saja hanya akan **memindahkan** kegagalan, dari `Unknown item field` pada
semua dokumen menjadi `Jenis CB "Voucher" tidak dikenali` pada separuhnya. Keduanya sudah
diperbaiki bersama.

Di luar itu, pemeriksaan menemukan **sembilan anomali** pada hubungan antar field. Yang
menyangkut uang: dua mesin gross up hidup berdampingan dan tidak sepakat (A7), dan laporan
menghitung gross up dari kolom dokumen yang kosong alih-alih dari Key Master (A8) — menggeser KPI
Report sebesar **Rp 34.417.503**. Keduanya sudah diperbaiki atas keputusan Anda, bersama pengisian
periode dokumen dari Campaign Master.

> **Catatan koreksi.** Versi pertama laporan ini menyebut selisih Rp 8.008.082.063 pada 1.345
> klaim seolah-olah itu nilai salah yang tersimpan. Itu keliru: angka tersebut membandingkan dua
> **rumus**, bukan dua nilai tersimpan. Kenyataannya `gross_up` kosong pada 2.752 dari 2.754 klaim
> — tidak ada nilai salah yang tersimpan, hanya nilai yang belum pernah ada. Rinciannya di A7.

---

## 2. Penyebab utama

### 2.1 Cacat 1 — penjaga menolak field yang pelaksananya butuhkan

Jalur simpan klaim terdiri dari dua fungsi yang berurutan:

```
layar  ->  adapter  ->  rc_private.mutate_claims            (PENJAGA - memvalidasi)
                             |
                             v
                        rc_private.mutate_claims_unchecked  (PELAKSANA - menulis)
```

Penjaga memeriksa setiap kunci pada item terhadap sebuah daftar putih, dan menolak apa pun di
luar daftar itu dengan `Unknown item field`. Daftar itu memuat lima belas nama:

```
no_doc, version_no, tax_subject, total_billing, period_start, period_end,
paid_on, approval, billing_months, ktp, npwp, bank, account_number,
account_name, top
```

Satu nama tertinggal: **`jenis_cashback`**.

Padahal pelaksananya **membaca** field itu, dan memakainya untuk dua keputusan yang menentukan:

```sql
v_jenis_input := btrim(coalesce(item->>'jenis_cashback',''));
...
if p_action='submit' and c.status='not_yet' and jenis in('ra07','ra7') then target:='done';
...
if jenis='transfer' and (v_norek is null or v_namarek is null or v_bank is null) then ...
```

Jadi satu fungsi **menuntut** field yang fungsi di depannya **larang**. Adapter selalu
mengirimkannya, karena layar mengisi Jenis CB otomatis dari Campaign Master. Hasilnya: tidak ada
satu pun dokumen yang bisa lewat.

**Bukti.** Dokumen `NPC/CMP/PSN/CA10/27886` v1, muatan sama persis, satu-satunya beda ada
tidaknya `jenis_cashback`:

```
DENGAN jenis_cashback : GAGAL -> Unknown item field
TANPA  jenis_cashback : LOLOS
```

### 2.2 Cacat 2 — `Voucher` dikenali di satu tempat, ditolak di tempat lain

Pelaksana menolak jenis apa pun di luar `Transfer`, `CN`, `Rebate`, `RA07`, `RA7`. Tetapi
`rc_private.jenis_efektif()` — fungsi milik sistem ini sendiri — justru **memetakan** Voucher
menjadi transfer:

```sql
when 'voucher' then 'transfer'
```

Selama `jenis_cashback` tidak pernah sampai ke sana, ketidakcocokan ini tidak terlihat. Begitu
cacat 1 diperbaiki, ia langsung mengenai dokumen yang paling banyak:

| Jenis di Campaign Master | Campaign | Klaim *not_yet* | Sebelum perbaikan |
|---|---:|---:|---|
| Transfer | 55 | 217 | diterima |
| CN | 12 | 121 | diterima |
| Rebate | 31 | 72 | diterima |
| **Voucher** | **2** | **421** | **DITOLAK** |

421 dari 831 klaim *not_yet* — lebih banyak daripada ketiga jenis lain digabung. Dua campaign
saja, tetapi keduanya besar.

### 2.3 Bukti perbaikan

Uji kering pada dokumen nyata dari keempat jenis, dijalankan dua kali dalam satu transaksi —
sebelum migration dan sesudahnya — lalu dibatalkan seluruhnya:

```
SEBELUM  CN        NPC/CBCN/MDN/2725/250     GAGAL -> Unknown item field
SEBELUM  Rebate    NPC/CMP/MDN/CM05/30118    GAGAL -> Unknown item field
SEBELUM  Transfer  NPC/CMP/MDN/3025/24054    GAGAL -> Unknown item field
SEBELUM  Voucher   NPC/CMP/MDN/CA08/27238    GAGAL -> Unknown item field

SESUDAH  CN        NPC/CBCN/MDN/2725/250     LOLOS
SESUDAH  Rebate    NPC/CMP/MDN/CM05/30118    LOLOS
SESUDAH  Transfer  NPC/CMP/MDN/3025/24054    LOLOS
SESUDAH  Voucher   NPC/CMP/MDN/CA08/27238    LOLOS

RINGKASAN: sebelum 0 lolos, sesudah 4 lolos, dari 4 dokumen.
```

---

## 3. Peta relasi antar field

Inilah yang Anda minta: apa yang terjadi pada setiap field dari layar sampai ke kolom basis data.

Layar menghasilkan **24 field** per baris. Adapter mengirim **paling banyak 14**. Selebihnya
memang tidak perlu dikirim — dokumen sudah ada di basis data, jadi kode depot, nama campaign,
nilai net dan volume tidak perlu diulang. Yang menarik justru yang **seharusnya** dikirim tetapi
tidak.

### 3.1 Field yang dikirim dan dipakai — benar

| Layar | Dikirim sebagai | Ditulis ke | Catatan |
|---|---|---|---|
| `noDoc` | `no_doc` | kunci pencarian | |
| *(dari cache versi)* | `version_no` | penjagaan versi | menolak bila dokumen berubah |
| `subyekPajak` | `tax_subject` | `claims.tax_subject` | lihat anomali A4 |
| `jenisCashbackInput` | `jenis_cashback` | *tidak disimpan* | hanya penentu alur — lihat A6 |
| `tglLunas` | `paid_on` | `claims.paid_on` | DD-MM-YYYY diubah ke ISO |
| `approval` | `approval` | `claims.approval` | wajib bila TOP > TOP master |
| `ktp` | `ktp` | `claim_sensitive.ktp` | master menang atas isian |
| `npwp` | `npwp` | `claim_sensitive.npwp` | master menang atas isian |
| `bankCust` | `bank` | `claim_sensitive.bank` | isian menang, master diperbarui |
| `noRekening` | `account_number` | `claim_sensitive.account_number` | idem |
| `pemilikRekening` | `account_name` | `claim_sensitive.account_name` | idem |
| `top` | `top` | `claim_sensitive.top_text` | angka di layar, teks di basis data |

### 3.2 Field yang dibaca adapter tetapi TIDAK PERNAH dihasilkan layar

Tujuh nama. Semuanya selalu `undefined`, jadi kodenya tidak pernah berjalan:

```
totTagih, blnTagih1, blnTagih2, blnTagih3, blnTagih4, bank, namaRekening
```

### 3.3 Field yang dihasilkan layar tetapi tidak dikirim

```
dcCode, depotName, codeCampaign, campaignName, custCode, custName,
netValue, volume, cbNet, statusPajakCampaign     <- wajar, sudah ada di basis data
periodStart, campaignEnd                          <- TIDAK wajar, lihat anomali A3
```

---

## 4. Anomali yang ditemukan

### A1 — `claims` tidak punya kolom `jenis_cashback`

Bukan kesalahan, tetapi perlu Anda ketahui supaya tidak salah menduga. Jenis CB **tidak pernah
disimpan pada dokumen**. Ia dipakai sesaat untuk memutuskan dua hal — apakah dokumen langsung
`done` (RA07/RA7) dan apakah rekening wajib diisi (Transfer) — lalu dibuang.

Sumber kebenarannya tetap Campaign Master. Artinya: **bila jenis CB sebuah campaign diubah
setelah dokumennya diunggah, dokumen lama tidak menyimpan jejak jenis lamanya.** Bila Anda
memerlukan jejak itu untuk audit, kolomnya harus ditambahkan — sekarang belum ada.

### A2 — `billing_months` kosong pada **seluruh** 2.754 klaim

Adapter membaca `blnTagih1` sampai `blnTagih4`, tetapi kolom Bulan Tagih sudah dihapus dari layar
atas permintaan Anda. Akibatnya larik itu tidak pernah terisi.

Tidak ada satu pun RPC lain yang membacanya — hanya kedua fungsi mutasi. Jadi kolom ini
**sepenuhnya mati**: tidak diisi, tidak dibaca, tidak ditampilkan.

> Tidak berbahaya, tetapi kodenya menyesatkan siapa pun yang membacanya nanti. Ada baiknya
> dibersihkan bersama `totTagih`.

### A3 — Periode dokumen tersedia di layar, tetapi tidak pernah dikirim

Layar sudah menghitung `periodStart` dan `campaignEnd` dari Campaign Master, dan daftar putih
penjaga **mengizinkan** `period_start` dan `period_end`. Adapter tetap tidak mengirimkannya.

Akibatnya pada data sekarang:

```
claims.period_start NULL : 1.427 dari 2.754
claims.period_end   NULL :   812 dari 2.754
```

Dari klaim *not_yet* saja, **57 dokumen** periode awalnya kosong padahal campaign-nya punya
periode, dan **10 dokumen** untuk periode akhir. Kolom ini dibaca oleh `rc_periode_dokumen` dan
`rc_posting_exception` — yaitu layar Posting Exception dan Reprocessing. Di sanalah periodenya
tampil kosong.

> **Sudah diperbaiki** atas keputusan Anda: *"by default dokumen itu memiliki periode sesuai
> campaign start dan campaign end."*
>
> `rc_private.compile_upload` kini mengisi `period_start` dan `period_end` dari Campaign Master
> saat dokumen dibuat, dan `mutate_claims_unchecked` memakai periode campaign sebagai cadangan
> terakhir — isian pengguna menang, lalu nilai lama, baru kemudian master. Dokumen yang sudah ada
> ikut diisi.
>
> Aturan penimpaannya tidak diubah, karena sudah benar: layar On Hold mengirim
> `soStart`/`soEnd`/`billingStart`/`billingEnd`, `rc_posting_exception` mensyaratkan sedikitnya
> satu berbeda dari periode campaign, lalu menuliskannya ke `extend_so_start/end` dan
> `extend_billing_start/end`. `rc_reprocessing_upload` mengosongkan keempatnya kembali saat
> dokumen kembali ke Not Yet — perpanjangan hanya berlaku selama dokumen tertahan.
>
> Hasilnya: `period_start` kosong turun dari **1.427 menjadi 125**, `period_end` dari **812
> menjadi 619**. Sisanya bukan cacat program — lihat bagian 8.

### A4 — `tax_subject` dikirim, tetapi hampir selalu diabaikan

Adapter mengirim `tax_subject` dari layar. Server menghitungnya ulang sendiri:

```sql
subject := case when v_npwp is not null then 'Badan'
                when v_ktp  is not null then 'Perorangan'
                else nullif(btrim(coalesce(item->>'tax_subject', c.tax_subject,'')),'') end;
```

Nilai dari layar hanya dipakai bila customer **tidak punya KTP maupun NPWP** — dan keadaan itu
sudah ditolak lebih dulu oleh layar ("KTP/NPWP Kosong (Update DB)"). Jadi praktis tidak pernah
terpakai.

Tidak berbahaya — keduanya menghitung dari sumber yang sama dan selalu sepakat. Tetapi field ini
memberi kesan layar bisa menentukan subyek pajak, padahal tidak.

### A5 — Nama `statusPajakCust` dipakai untuk dua arti

Di baris upload, `statusPajakCust` berisi **subyek pajak** (`Badan` / `Perorangan`). Di layar
Workflow, nama yang sama berisi nilai dari `claims.tax_subject` — kebetulan sama artinya.
Sementara `statusPajakCampaign` berisi hal yang sepenuhnya berbeda: **siapa yang menanggung
pajak** (`PT Nipsea Paint and Chemicals`, `Rebate Non Tax`, `Customer`).

Saya periksa pemakaiannya di `calcGrossUp(netCB, r.statusPajakCust, r.statusPajakCamp)` —
**urutannya benar**, tidak ada yang tertukar. Dicatat di sini semata karena penamaan seperti ini
adalah undangan untuk tertukar di kemudian hari.

### A6 — Layar mengirim nilai Campaign Master, bukan pilihan pengguna *(sudah diperbaiki)*

Ini yang membuat cacat 2 menjadi fatal. Layar mengisi Jenis CB otomatis dari Campaign Master,
lalu **nilai hasil isian otomatis itu** yang dikirim ke server — seolah-olah pengguna yang
mengetiknya.

Padahal komentar di kedua sisi menyatakan maksud yang sebaliknya. Di layar:

> *"Yang divalidasi ketat hanyalah nilai yang DIKETIK pengguna. Nilai warisan dari Campaign Master
> diterima apa adanya, karena master memang masih memuat jenis lama seperti Voucher."*

Maksud itu benar; pelaksanaannya yang tidak mengikuti. Sekarang hanya nilai yang benar-benar
**diketik** yang dikirim. Bila pengguna tidak mengetik apa pun, field-nya tidak dikirim sama
sekali dan server memakai Campaign Master sendiri lewat `jenis_efektif()` — yang memang mengenali
nama-nama lama.

### A7 — Dua mesin gross up yang tidak sepakat *(sudah diperbaiki)*

Ada dua fungsi gross up di basis data, dan keduanya tidak sepakat:

| Fungsi | Melihat status pajak campaign? | Dipakai oleh |
|---|---|---|
| `public.rc_gross_up_legacy(net, subject)` | **tidak** | `compile_upload`, `mutate_claims_unchecked` — **jalur TULIS** |
| `rc_private.gross_claimed(net, subyek, status_campaign)` | ya | view `rc_report_rows`, `rc_cost_center` — **jalur BACA** |

`gross_claimed` mengembalikan **0** bila pajak ditanggung perusahaan atau campaign-nya Rebate Non
Tax. `rc_gross_up_legacy` tetap menghitung `net / 0.85`. Fungsi `calcGrossUp` di layar mengikuti
yang kedua.

**Koreksi atas laporan saya sebelumnya.** Saya menyebut angka Rp 8.008.082.063 pada 1.345 klaim
seolah-olah itu nilai salah yang sudah tersimpan. Itu keliru — angka itu membandingkan dua
**rumus**, bukan dua nilai tersimpan. Kenyataannya:

```
gross_up NULL : 2.752 dari 2.754 klaim aktif
gross_up > 0  : 2
```

Hanya **dua** klaim yang gross_up-nya pernah terisi — persis dua dokumen yang berhasil submit
sebelum cacat `jenis_cashback` memblokir semuanya. Keduanya sudah cocok dengan hitungan master.
Jadi **tidak ada satu pun nilai salah yang tersimpan**; yang ada hanyalah nilai yang belum pernah
ada. Tidak ada 1.345 baris yang perlu Anda putuskan nasibnya.

Yang tetap penting: begitu upload berjalan kembali, jalur tulis akan mulai menyimpan nilai yang
mengabaikan Campaign Master. Karena itu jalur tulisnya dibetulkan lebih dulu, sebelum dokumen
baru masuk.

### A8 — Laporan memakai subyek pajak dokumen, yang kosong *(sudah diperbaiki)*

Ditemukan saat mengerjakan A7, dan ini yang benar-benar menggeser angka laporan.

View `public.rc_report_rows` menghitung:

```sql
rc_private.gross_claimed(c.cb_net, c.tax_subject, ca.tax_status)
```

memakai `tax_subject` **dokumen**, bukan Key Master. Pada **1.016 klaim** kolom itu kosong — dan
ketika kosong, rumusnya jatuh ke tangga progresif Perorangan. **167** di antaranya sebenarnya
**Badan** di Key Master, yang seharusnya flat 15%.

Dampaknya pada angka yang Anda baca:

```
baris yang berubah                          : 78
selisih seluruh klaim aktif                 : Rp 79.735.356
selisih pada status done (yang masuk KPI)   : Rp 34.417.503
```

Perbaikannya mengikuti acuan yang Anda tetapkan — **Key Master** — dengan mengisi `tax_subject`
dokumen dari master. View-nya sendiri tidak perlu diubah.

### Hasil sesudah perbaikan A7 dan A8

Diukur sebelum dan sesudah, di dalam transaksi yang dibatalkan, lalu diterapkan dan diperiksa
ulang. Angka akhirnya sama persis dengan uji keringnya:

| | Sebelum | Sesudah |
|---|---:|---:|
| `gross_up` kosong | 2.752 | **1** |
| `tax_subject` kosong | 1.017 | **1** |
| `period_start` kosong | 1.427 | **125** |
| `period_end` kosong | 812 | **619** |
| KPI Report *grossClaimed* (done) | Rp 2.656.861.705 | **Rp 2.691.279.208** |
| `version_no` (jumlah) | 2.862 | 2.862 — tidak berubah |
| jumlah klaim aktif | 2.754 | 2.754 — tidak berubah |

`version_no` sengaja tidak dinaikkan. Kolom itu penjaga tabrakan antar pengguna; menaikkannya
pada 2.754 baris sekaligus akan membuat setiap layar yang sedang terbuka menolak dengan
*"Document changed; refresh first"* tanpa ada yang benar-benar berubah bagi penggunanya.

Dokumen yang sudah diarsipkan tidak disentuh — arsip adalah catatan yang sengaja dibekukan.

### A9 — Satu dokumen berperiode di luar periode campaign-nya

Ditemukan oleh uji kering, bukan oleh pembacaan. Pengisian periode sempat ditolak basis data:

```
new row for relation "claims" violates check constraint "claim_period_order"
```

Penyebabnya satu dokumen:

```
NPC/CBCN/MDN/2225/027   dokumen: mulai 2025-10-01, selesai kosong
                        campaign 222025: 2025-08-01 .. 2025-09-30
```

Tanggal mulai dokumen ini jatuh **sesudah** campaign-nya berakhir. Mengisi sisi yang kosong dari
campaign akan membuat tanggal selesai lebih awal daripada tanggal mulai, dan batasan
`claim_period_order` menolaknya — dengan benar.

Dokumen seperti ini **dilewati dan dicatat**, bukan dipaksakan. Hanya ada satu. Perlu diperiksa
tangan: apakah tanggal mulainya yang salah, atau campaign-nya yang seharusnya lebih panjang.

## 5. Dua fungsi Timetable yang dipanggil tetapi tidak pernah ada

Ditemukan saat memeriksa keluhan Timetable, dan sebabnya sama sekali berbeda dari dugaan awal.

`loadTimetable()` memanggil dua fungsi yang **tidak didefinisikan di mana pun** — tidak di
`src/`, tidak di halaman hasil build:

```js
const perDepot = ttBolehLihatPerDepot();   // baris 70  -> ReferenceError
...
renderTimetableCampaignTabel();            // baris 76  -> ReferenceError
```

Keduanya berada di dalam `try`, dan `catch`-nya menampilkan `"Gagal memuat Timetable."` —
kalimat yang sama persis dengan kegagalan jaringan. Jadi modulnya gagal dibuka untuk **semua
orang, termasuk System Manager**, dengan pesan yang tidak menyebut sebab apa pun.

Markup tabel "Progres per Campaign" sudah lengkap di halaman (`ttCardCampaignTabel`,
`ttCampaignBody`) — hanya tidak pernah ada yang mengisinya.

Keduanya sudah ditulis. Aturan visibilitasnya sesuai permintaan Anda:

| Peran | Progres per campaign | Progres per depot |
|---|---|---|
| System Manager, Supervisor | ya | ya, seluruh depot |
| Admin/OSC **dengan** tagging > 1 depot | ya | ya, **hanya depot taggingnya** |
| Admin/OSC tanpa tagging (1 depot atau 0) | ya | tidak |

Batas taggingnya sendiri dipasang di **server**, bukan di layar: `rc_timetable_matrix` hanya
mengembalikan depot yang lolos `rc_private.can_access()`. Yang diputuskan di layar hanyalah
apakah kartunya ditampilkan. Menaruh kedua keputusan di layar berarti siapa pun yang membuka
konsol browser dapat melewatinya.

Keadaan tagging akun Anda sekarang:

```
ANIADMPTI  admin            4 depot   4A,4C,4D,4F   -> per depot TAMPIL (4 depot itu saja)
AYI        admin            4 depot   4A,4C,4D,4F   -> per depot TAMPIL (4 depot itu saja)
ANNA_MDN   admin            1 depot   4D            -> hanya per campaign
IQBAL      admin            0 depot   -             -> hanya per campaign
DANIEL     system manager  51 depot                 -> seluruhnya
```

---

## 6. Penjaga baru supaya ini tidak terulang

Kerusakan Timetable lolos karena `scripts/check-system.mjs` hanya memeriksa fungsi yang dipanggil
dari **atribut markup** (`onclick="..."`). Panggilan dari dalam kode sendiri — justru yang paling
sunyi — tidak diperiksa sama sekali.

Pemeriksaan **4b** kini menutup celah itu: seluruh panggilan `nama(...)` di dalam JavaScript hasil
build dibandingkan dengan daftar fungsi yang benar-benar ada.

Supaya tidak berisik, kode dikupas lebih dulu dari komentar dan isi string — tanpa itu, kalimat
Indonesia di dalam komentar terbaca sebagai panggilan fungsi (`penghapusan()`, `Rupiah()`), dan
`rgba(15,23,42,.08)` di dalam string CSS terbaca sebagai `rgba()`. Isi `${...}` pada template
literal tetap diperiksa, karena di halaman ini justru di sanalah sebagian besar pemanggilan
berada.

Penjaganya sudah dibuktikan dua arah: bersih pada halaman yang benar, dan menangkap panggilan
palsu yang sengaja disisipkan.

---

## 7. Yang sudah dikerjakan

| | Perubahan | Berkas |
|---|---|---|
| 1 | `jenis_cashback` masuk daftar putih penjaga | `supabase/migrations/20261107010000_rc_field_jenis_cashback.sql` — **sudah diterapkan** |
| 2 | `Voucher` diakui sebagai nama lama dari Transfer | migration yang sama — **sudah diterapkan** |
| 3 | Layar mengirim hanya Jenis CB yang **diketik** | `src/js/55-grid-input.js`, `scripts/rc-legacy-adapter.js` |
| 4 | Uji yang mengunci perilaku itu | `scripts/test_rc_legacy_adapter.mjs` |
| 5 | `ttBolehLihatPerDepot()` ditulis, sesuai aturan Anda | `src/js/97-timetable.js` |
| 6 | `renderTimetableCampaignTabel()` ditulis | `src/js/97-timetable.js` |
| 7 | Pemeriksaan 4b pada penjaga sistem | `scripts/check-system.mjs` |
| 8 | Gross up jalur tulis mengikuti Campaign Master | `supabase/migrations/20261108010000_rc_gross_up_dan_periode_dari_master.sql` — **sudah diterapkan** |
| 9 | `tax_subject` dokumen diisi dari Key Master | migration yang sama |
| 10 | Periode dokumen diisi dari Campaign Master | migration yang sama |
| 11 | `compile_upload` mengisi periode dan subyek pajak sejak awal | migration yang sama |

Migration-nya membaca definisi yang sedang terpasang lalu mengubah satu pola di dalamnya,
alih-alih menyalin badan fungsi ke dalam berkas. Salinan yang menyimpang pada fungsi penjaga
adalah cara paling halus sebuah perbaikan berubah menjadi kemunduran. Ia idempoten, dan berhenti
dengan galat bila polanya tidak ditemukan — bukan diam-diam tidak melakukan apa pun.

Sesudah diterapkan, jumlah klaim tidak berubah sama sekali: `not_yet` 831, `submitted` 6 — sama
seperti sebelumnya. Yang berubah hanya kedua fungsi itu.

`npm run check` bersih, `npm run test` 31/31 lolos.

## 8. Yang tersisa — celah data master, bukan cacat program

Sesudah semua perbaikan di atas, yang masih kosong hanya kosong karena **master-nya memang belum
diisi**. Program sudah mengambil semua yang tersedia. Begitu master dilengkapi, sisanya terisi
sendiri pada dokumen berikutnya — dan untuk dokumen lama cukup menjalankan ulang bagian pengisian.

| Yang kosong | Jumlah | Sebabnya |
|---|---:|---|
| `period_start` dokumen | 125 | **20 campaign** belum punya tanggal mulai di Campaign Master |
| `period_end` dokumen | 619 | **22 campaign** belum punya tanggal selesai — ditambah 1 dokumen A9 |
| `gross_up` dan `tax_subject` | 1 | customer **617445** tidak punya KTP maupun NPWP di Key Master |

Tiga hal yang perlu Anda putuskan atau perbaiki di master:

1. **Lengkapi periode 20–22 campaign** di Campaign Master. Ini yang membuka 744 dokumen sisanya.
2. **Lengkapi KTP atau NPWP customer 617445** di Key Master, supaya subyek pajak dan gross up
   dokumennya dapat dihitung.
3. **Periksa `NPC/CBCN/MDN/2225/027`** (A9) — tanggal mulainya jatuh sesudah campaign-nya
   berakhir. Salah satu dari keduanya perlu dibetulkan.

Selain itu, tiga hal dari audit yang belum diputuskan dan tidak mendesak:

4. **Bersih-bersih (A2)** — buang `totTagih` dan `blnTagih1..4` dari adapter, atau kembalikan
   kolomnya ke layar bila memang masih diperlukan. Sekarang `billing_months` kosong pada seluruh
   2.754 klaim dan tidak dibaca oleh siapa pun.
5. **Jejak jenis CB (A1)** — perlukah dokumen menyimpan jenis CB-nya sendiri untuk audit?
6. **Satu campaign berperiode terbalik** — `CMPGNWEST26002` (CCM NON PCC 02.2026) mulai
   2026-02-01 tetapi selesai 2026-01-28. Belum berdampak karena klaimnya nol, tetapi akan
   menolak dokumen pertama yang masuk ke sana.
