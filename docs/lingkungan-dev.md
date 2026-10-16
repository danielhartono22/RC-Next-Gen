# Lingkungan Dev — rencana dan keadaan

Terakhir diperbarui 29 September 2026.

Catatan kerja untuk menyiapkan lingkungan dev yang terpisah dari produksi. Ditulis supaya
kesepakatannya tidak tercecer di antara percakapan, dan supaya siapa pun yang melanjutkan tahu
apa yang sudah jadi dan apa yang belum.

---

## Dua lingkungan

| | Produksi | Dev |
|---|---|---|
| Situs | https://rc-next-gen.vercel.app | https://resource-collection-dev.vercel.app |
| Project Vercel | `rc-next-gen` | `resource-collection-dev` |
| Project Supabase | `vvojshgcduqlugngpzkj` | `fimjgmjjsplwgmuwzwbx` |
| Akun Supabase | akun lama | `jacipnuorjbfunhndqsy` (terpisah) |
| Variabel token | `SUPABASE_ACCESS_TOKEN` | `SUPABASE_ACCESS_TOKEN_DEV` |
| Config peramban | `config/rc-env.js` | `config/rc-env.dev.js` |
| Data | nyata | rekayasa |

Keduanya berada di **akun Supabase yang berbeda**. Itu kebetulan yang menguntungkan: token dev
secara harfiah tidak mampu menyentuh produksi, jadi pemisahannya tidak bergantung pada disiplin
maupun pada kode kita sendiri.

### Perintah

```
npm run sql -- --env dev berkas.sql     jalankan SQL ke dev
npm run sql -- --env prod berkas.sql    jalankan SQL ke prod (spanduknya menyebut PROD)
npm run deploy                          build prod, terbitkan ke rc-next-gen
npm run deploy:dev                      build dev, terbitkan ke resource-collection-dev
node scripts/siapkan-dev.mjs --env dev  pasang skema ke dev
node scripts/impor-dev.mjs --env dev --data <folder>   muat data rekayasa
```

`npm run deploy` selalu membangun ulang lebih dulu. Tanpa itu, sisa build dev di `public/`
bisa terkirim ke produksi.

---

## Kesepakatan isi dev

Ditetapkan pemilik, 28 September 2026.

| Hal | Keputusan |
|---|---|
| Jumlah data rekayasa | **10 ribu** klaim (30 September 2026; sebelumnya 100 ribu) |
| Depot | **ikut produksi** |
| Region | **ikut produksi** |
| Pengguna dan peran | **ikut produksi** |
| Transaksi (klaim, pelanggan, campaign) | rekayasa |

### Akibat yang harus ditangani

Dataset rekayasa yang sudah dibangkitkan memakai **100 depot karangan** (`PERFD001`–`PERFD100`),
dan seluruh klaimnya menggantung di sana. Karena depot kini ikut produksi, klaim-klaim itu harus
**dipetakan ulang** ke depot produksi yang sebenarnya sebelum dimuat.

Pemetaan ulang justru menguntungkan: penyaring depot, penyaring region, dan yurisdiksi OSC jadi
berperilaku seperti di lapangan, bukan di atas depot karangan yang tidak dikenal siapa pun.

### Yang dinetralkan

Menyalin pengguna produksi apa adanya berarti dev ikut membawa nama dan alamat email orang
sungguhan, sementara dev juga punya tabel `email_settings` beserta sakelarnya. Kalau sakelar itu
menyala saat seseorang menguji, staf depot sungguhan menerima email berisi data karangan.

| Disalin apa adanya | Dinetralkan |
|---|---|
| User ID / kode pengguna | Alamat email pengguna → `<kode>@dev.invalid` |
| Nama lengkap | PIN → hash PIN prod (masuk dengan PIN prod), atau satu PIN uji bila hash tidak diekspor |
| Peran | Email depot pada Depot Master → alamat uji |
| Penugasan depot dan region peran selain OSC/Supervisor | Sakelar email dev → mati sejak awal |
| | Yurisdiksi OSC dan Supervisor → dibagi ulang acak tetapi seimbang (30 September 2026) |
| Izin per modul dan per tab | |

Domain `.invalid` memang dicadangkan untuk keperluan ini dan tidak mungkin terkirim.

---

## Keadaan saat ini

Diperbarui 29 September 2026.

**Sudah jalan**

- Project dev hidup; seluruh migrasi terpasang dan tercatat di `public._migrasi_dev`
- 10 ribu klaim rekayasa (dikurangi dari 100 ribu dengan sampel bertingkat status x depot,
  sebaran tetap sama; `supabase/queries/kurangi-data-dev.sql`). Database 37 MB, seluruhnya
  muat di memori, sehingga setiap modul terbuka dalam 0,1 - 1,5 detik
- 52 depot, sama dengan prod (7A - Tegal ditambahkan 30 September 2026)
- Localhost untuk pengujian: `npm run dev:dev` lalu buka http://localhost:5173 — menunjuk
  database **dev**, bukan prod
- Setiap halaman dev menampilkan pita kuning **LINGKUNGAN DEV** di paling atas; produksi tidak.
  Situs dev (resource-collection-dev.vercel.app) dan produksi (rc-next-gen.vercel.app) tampak
  identik selain pita itu, dan akun dev **tidak ada** di produksi
- Setiap modul yang dibuka setelah login berhasil dimuat pada 100 ribu klaim; tidak ada lagi
  batas waktu 8 detik yang terlewati (rincian di bagian berikut)

**Akun dev**

| User ID | Peran | Keterangan |
|---|---|---|
| 67 user prod | sesuai prod | disalin 30 September 2026: User ID, nama, peran, status, izin, dan **PIN prod** (hash identik, diperiksa 67/67). Email bisnis menjadi `<kode>@dev.invalid` |
| `DANIEL` | System Manager | **akun bawaan dev**, PIN ditetapkan pemilik. User DANIEL milik prod sengaja tidak disalin supaya akun ini tidak tertimpa |
| `SMDEV` | System Manager | akun uji |
| `OSCDEV`, `SPVDEV`, `OFFDEV` | — | akun uji, dinonaktifkan supaya tidak ikut pembagian yurisdiksi |

Yurisdiksi OSC dan Supervisor dibagi acak seimbang (benih 0.803095): 52 depot ke 5 OSC,
10-11 depot per OSC; 5 OSC ke 2 Supervisor, 3 dan 2 OSC (32 dan 20 depot). Peran lain
mengikuti prod.

Login menerima User ID huruf kecil maupun besar. Akun baru dibuat dengan
`node scripts/buat-akun-dev.mjs` (tanpa email konfirmasi, jadi tidak terkena batas email).

**Belum jalan**


---

## Menduplikasi user prod

Tiga berkas, diuji ujung ke ujung dengan ekspor tiruan (11 user) lalu dibersihkan:

| Berkas | Guna |
|---|---|
| `supabase/queries/ekspor-user-prod.sql` | dijalankan di SQL Editor **prod**, HANYA membaca; hasilnya satu JSON |
| `scripts/salin-user-prod-ke-dev.mjs` | membuat akun dev dari JSON itu (atau langsung dari prod dengan `--langsung` bila token prod ada) |
| `supabase/queries/bagi-yurisdiksi-dev.sql` | membagi depot ke OSC dan OSC ke Supervisor, acak tetapi seimbang |

```
node scripts/salin-user-prod-ke-dev.mjs --berkas .runtime/user-prod.json --kering
node scripts/salin-user-prod-ke-dev.mjs --berkas .runtime/user-prod.json
```

- Akun dibuat dengan alamat login internal dan hash PIN yang sama seperti prod; tanpa hash
  dipakai `--pin-uji <PIN>`. Email bisnis menjadi `<kode>@dev.invalid`.
- OSC: setiap depot tepat satu OSC, selisih jumlah depot antar-OSC paling banyak satu.
  Supervisor: selisih jumlah OSC binaan paling banyak satu; depotnya diwarisi dari OSC binaan
  (`rc_private.effective_depots`). Benih acaknya dicetak dan dapat diulang (`--benih`).
- DANIEL, SMDEV, OSCDEV, SPVDEV dan OFFDEV tidak pernah ditimpa. OSCDEV dan SPVDEV
  dinonaktifkan supaya tidak ikut pembagian.

---

## Performa pada 100 ribu klaim (29 September 2026)

Diukur di dev, 29 September 2026. Setiap perubahan dibuktikan menghasilkan keluaran yang
sama persis dengan sebelumnya di dalam migrasinya sendiri; migrasi berhenti bila tidak.

| Sebab | Perbaikan | Migrasi |
|---|---|---|
| Kebijakan RLS memanggil fungsi jangkauan untuk setiap baris | dihitung sekali per kueri | 20261162020000, 040000, 060000 |
| Fungsi pembantu per baris tidak bisa di-inline karena `SET search_path` | klausa SET dilepas dari 7 fungsi murni | 20261162030000 |
| View laporan menggabungkan klaim dan campaign ke dirinya sendiri | gabung-diri dibuang | 20261162030000 |
| Depot Master gagal "permission denied" untuk semua pengguna | hitungan pengajuan lewat fungsi SECURITY DEFINER | 20261162030000 |
| Workflow hanya pernah memuat 1000 dari 30 ribu baris antrean; Analytics memuat 100 ribu baris sekaligus | muat bertahap dengan kursor, halaman pertama langsung tampil | 20261162050000 |
| Approval History dan People Performance memeriksa izin per baris | dihitung sekali | 20261162060000 |
| Pencarian master per kode memindai seluruh tabel | memakai indeks | 20261162070000 |
| Management of Approval memeriksa izin per baris | dihitung sekali | 20261162080000 |
| Dashboard publik menghitung ulang seluruh laporan pada setiap kunjungan, melewati batas 3 detik pengunjung tanpa login | tanpa penyaring: snapshot tiap 5 menit (pg_cron `rc_dashboard_publik_segar`); dengan penyaring: dihitung langsung seperti dulu | 20261162090000 |

Contoh hasil, lewat HTTP sebagai pengguna: Analytics dan Approval History dari *timeout*
menjadi berhasil; Report Dashboard 7 detik → sekitar 3 detik; pencarian 300 dokumen 5,6 detik
→ di bawah 15 milidetik (cache hangat); dashboard publik dari *timeout* menjadi sekitar 2 detik.
Di browser, antrean Workflow 30.142 baris termuat utuh dalam ±1,5 menit dan Analytics
100.000 baris dalam ±1,5 menit, baris pertama tampil dalam beberapa detik.

**Browser membeku pada tabel besar.** Tailwind dimuat dari CDN versi "Play", yang memindai
SEMUA elemen berkelas di dokumen setiap kali isi elemen mana pun berubah. Dengan puluhan ribu
baris tabel, satu pemindaian memakan detik, dan jam sesi (berubah tiap detik) membuat browser
sibuk terus. Jam sesi dan indikator muat kini ditulis ke atribut `data-teks` yang ditampilkan
lewat CSS, sehingga tidak memicunya. Setiap klik yang mengubah isi halaman tetap memicu satu
pemindaian; penyelesaian tuntasnya adalah mengganti Tailwind CDN dengan CSS yang dirakit saat
build.

**Keterbatasan project dev.** Project dev memakai komputasi terkecil (tanpa add-on). Data
100 ribu klaim (±400 MB beserta indeks) tidak muat seluruhnya di memori, jadi modul yang
pertama dibuka setelah modul berat lain bisa beberapa kali lebih lambat daripada saat dibuka
kedua kalinya. Angka dev karena itu lebih pesimis daripada produksi.

**Status di produksi.** Migrasi 20261162010000 sampai 20261162130000 **diterapkan ke produksi
6 Oktober 2026** atas persetujuan pemilik ("transport ke prod"), berurutan, masing-masing dengan
penjaga dan pembuktiannya sendiri; frontend diterbitkan sesudahnya (deployment
`dpl_75io7txWyThk6iK3vDnYDqxtH8M1`). Snapshot seluruh definisi fungsi, kebijakan, view, indeks,
constraint dan cron prod SEBELUM transport tersimpan di `.runtime/prod-snapshot-20261006/` sebagai
bahan rollback. Setelah transport, 282 fungsi yang ada di kedua lingkungan identik (MD5 dengan
akhir baris dinormalkan).

Dua pembuktian lolos di dev tetapi menolak berjalan di prod, dan diperbaiki sebelum diulang -
pelajarannya: data dev yang besar dan "bersih" tidak menguji cabang untuk data kecil atau data
dengan arsip.

| Migrasi | Yang terjadi di prod | Perbaikan |
|---|---|---|
| 20261162020000 | angka harapan data sensitif tidak memperhitungkan 8 klaim terarsip (RLS `claims` ikut berlaku di dalam kebijakan `claim_sensitive`; dev tidak punya klaim terarsip) | harapan memodelkan RLS bersarang, ditambah potret lewat kebijakan LAMA per profil jangkauan (71 pengguna = 6 profil) yang harus sama persis dengan kebijakan baru |
| 20261162050000 | data prod di bawah 3000 baris menjalankan cabang pembuktian yang memanggil `rc_legacy_dashboard()` lama - ambigu, karena versi baru seluruh argumennya ber-default | fungsi lama diberi nama sementara selama pembuktian, lalu dibuang |

20261162150000 (Exclude Campaign cukup dengan tab-nya) diterapkan ke dev dan prod pada hari yang
sama, setelah uji sinkronisasi per modul: admin yang HANYA diberi satu modul memanggil setiap RPC
layar modul itu (13 modul jalur baca, 17 aksi) - hanya tab Exclude Campaign yang masih menuntut
izin modul lain. Skrip ujinya: scratchpad `uji-sinkron.sql` dan `uji-aksi.sql` (pola yang sama
dapat dipakai ulang setiap kali modul baru ditambahkan).

20261162140000 (versi tiga argumen `periksa_email_maks`, yang dibuat langsung di prod dan tidak
pernah ada di berkas migrasi) hanya diterapkan ke dev: tanpa itu menyimpan Depot Master di dev
gagal. Definisinya salinan persis dari prod.

---

## Penghalang

**Teratasi 30 September 2026:** token akun pemilik `vvojshgcduqlugngpzkj` tersimpan di `.env`
(`SUPABASE_ACCESS_TOKEN`). Dipakai membaca prod (ekspor user) dan, sejak 6 Oktober 2026 atas
persetujuan pemilik, untuk transport migrasi 20261162010000 - 20261162130000.

Temuan saat membaca prod: di prod, peran `authenticated` boleh membaca
`depot_profile_requests`, lewat grant yang tidak ada di riwayat migrasi. Karena itu Depot Master
di prod tidak pernah rusak; kerusakan hanya muncul pada database yang dibangun dari migrasi
(dev), dan sudah diperbaiki di 20261162030000.

Catatan lama:

Seluruh sisanya menunggu **satu hal: token Supabase dari akun pemilik `vvojshgcduqlugngpzkj`.**

Diperlukan untuk menyalin skema produksi, menyalin daftar depot dan region, dan menyalin
pengguna beserta perannya. Tanpa itu ketiganya hanya bisa ditebak.

Token itu juga menutup hal yang lebih mendesak: saat ini **tidak ada akses sama sekali ke
database produksi**, termasuk bila ada yang perlu diperbaiki.

---

## Temuan sampingan: migrasi tidak dapat diputar ulang

Menyiapkan dev membongkar sesuatu yang berlaku di luar urusan dev: **rangkaian migrasi di repo
ini tidak bisa membangun ulang database dari nol.** Artinya kalau produksi hilang, repo ini
belum cukup untuk memulihkannya.

Tiga jenis cacat ditemukan:

| Cacat | Contoh | Status |
|---|---|---|
| `create function` telanjang, bentrok saat fungsi dibuat dua kali | `rc_open_claims`, `rc_permission_catalog` | **diperbaiki** — 62 pernyataan di 10 berkas jadi `create or replace` |
| Kolom dipakai sebelum dibuat | `depots.abbr` dipakai migrasi 20260923, dibuat 20260926 | **diperbaiki** — `add column if not exists` |
| Fungsi ditambal padahal tak pernah dibuat migrasi mana pun | `rc_private.compile_upload` ditambal 20261108, hanya dibuat 20261152 | **belum** — sekitar 20 kasus |

Dua perbaikan pertama menaikkan hasil dari 15 menjadi 65 migrasi. Keduanya aman untuk produksi:
`create or replace` identik dengan `create` untuk pembuatan pertama, dan kolomnya memang sudah
ada di sana.

Jenis ketiga menunjukkan sebagian objek produksi lahir **di luar** riwayat migrasi. Menambalnya
satu per satu tetap berupa tebakan tentang bentuk produksi sebenarnya; menyalin skema langsung
dari produksi adalah satu-satunya cara yang pasti benar.
