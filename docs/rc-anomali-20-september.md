# Daftar anomali, kejanggalan dan pencilan — 20 September 2026

Ditulis untuk Daniel. Seluruh angka diukur langsung dari project `vvojshgcduqlugngpzkj` dengan
query yang hanya membaca; tidak ada satu pun data yang berubah selama pemeriksaan.

Penyapuannya menguji 30 aturan atas seluruh tabel — rujukan yatim, status versus jejak waktu,
angka, tanggal, mutu data master, akun dan hak, nomor batch, serta duplikat. Yang tidak disebut
di sini berarti lolos bersih.

---

## 1. Yang paling mendesak: 317 dokumen akan ditolak saat diunggah

Dari **826 klaim *not_yet*** — yaitu pekerjaan yang masih akan diproses — sebanyak **317 (38%)**
akan ditolak layar Upload sebelum sempat terkirim.

Sebabnya satu: campaign-nya berjenis **Transfer** (termasuk Voucher, yang dipetakan sistem menjadi
Transfer), sedangkan customer-nya belum punya data rekening. Layar menuntut No Rekening, Nama
Rekening dan Bank untuk jenis Transfer, dan menolak barisnya bila salah satu kosong.

```
Dokumen terhalang               317
Customer unik yang perlu diisi  240
Ketiganya kosong                317   <- bukan sebagian, melainkan seluruh tiga kolom
Hanya satu kolom yang kosong      0
```

Yang melegakan: tidak ada satu pun kasus setengah terisi. Ke-317 dokumen itu berasal dari **240
customer** yang kolom rekeningnya kosong sama sekali, jadi pekerjaannya adalah pengisian data
master, bukan penelusuran satu per satu.

Customer dengan dokumen terbanyak:

| Kode | Nama | Dokumen |
|---|---|---:|
| 616967 | MAKMUR JAYA | 6 |
| 623028 | HARAPAN BARU | 6 |
| 635652 | CV.ERA BARU SENTOSA | 5 |
| 617451 | SUMATERA | 4 |
| 628901 | USAHA LUBIS 2 | 4 |
| 630416 | JAYA GIPSUM | 4 |

**Sisanya 482 dokumen siap diproses tanpa halangan yang terdeteksi.**

Dua dokumen lagi terhalang sebab lain, masing-masing satu:

- `NPC/CMP/MDN/CA42/26792` — customer-nya punya KTP **dan** NPWP sekaligus, sehingga subyek
  pajaknya tidak dapat ditentukan dan layar menandainya "Check".
- `NPC/CMP/MDN/CA08/27243` — customer 617445 tidak punya KTP maupun NPWP. Ini juga satu-satunya
  dokumen yang gross up-nya tidak dapat dihitung.

---

## 2. Kejanggalan angka

### 2.1 235 dokumen: cashback lebih besar daripada nilai penjualannya

Cashback yang melebihi nilai transaksinya sendiri secara ekonomi ganjil. Contoh
`NPC/CMP/MDN/CA33/26697`. Ada 237 dokumen seperti ini secara keseluruhan, 235 di antaranya masih
*not_yet* — artinya angka itu akan ikut terbawa ke proses berikutnya bila tidak diperiksa.

Perlu Anda pastikan: apakah memang ada campaign yang cashback-nya dihitung dari volume dan bukan
dari nilai, atau ini salah kolom saat compile.

### 2.2 52 dokumen bernilai cashback nol atau negatif

Seluruhnya masih *not_yet*. Contoh `NPC/CMP/MDN/3325/15533`. Compile yang sekarang **menolak**
cashback nol atau negatif, jadi ke-52 dokumen ini pasti masuk sebelum aturan itu berlaku.

### 2.3 1.632 dokumen bervolume nol atau negatif

Jauh lebih banyak, tetapi dampaknya lebih kecil: volume tidak dipakai untuk menghitung apa pun,
hanya ditampilkan. Dicatat sebagai petunjuk mutu impor, bukan penghalang.

### 2.4 Satu pencilan nilai

`NPC/CMP/MDN/326B/22021` cashback-nya melebihi Rp 1 miliar — satu-satunya di seluruh basis data.
Bukan berarti salah, tetapi pantas dilihat sekali.

### 2.5 Kolom Volume tercemar nilai rupiah — 172 dokumen

Ditemukan saat membangun diagram tren mingguan. Sebagian baris memuat **nilai rupiah** di kolom
Volume, bukan kuantitas:

```
134  volume PERSIS SAMA dengan net_value      - Net Value tersalin ke kolom Volume
172  nisbah net_value/volume di bawah 100     - mustahil sebagai harga satuan
703  nisbahnya wajar                          - jelas kuantitas
```

Yang terbesar `NPC/CMP/MDN/326B/22021` bervolume **24.651.571.597**, sama persis dengan
net_value-nya. Ada pula yang dibulatkan: `NPC/CMP/PST/326A/23805` bervolume 1.800.000.000
sementara net_value-nya 1.822.313.193.

Perlu dicatat bahwa **ambang mutlak tidak dapat dipakai** untuk memisahkannya, dan saya sempat
salah menduga begitu. Dokumen `NPC/CMP/MDN/3025/23272` bervolume 10.795 — terlihat besar, tetapi
net_value-nya Rp 781 juta sehingga harga satuannya sekitar Rp 72.000. Itu kuantitas yang sah.
Yang membedakan adalah **nisbah** net_value terhadap volume: pada baris yang sah nisbah itu adalah
harga satuan dan selalu di atas seratus rupiah, sedangkan pada baris tercemar volume kira-kira
sebesar net_value sendiri sehingga nisbahnya mendekati satu.

Diagram tren mingguan **tidak lagi memakai kolom ini**: atas permintaan pemilik, deretnya diganti
menjadi Qty (banyaknya dokumen) dan Value, sehingga diagram itu terlepas sama sekali dari cacat
ini. Cacatnya sendiri tetap ada di data dan tetap perlu dibereskan, karena kolom Volume masih
ditampilkan di layar dan masih ikut terekspor.

---

## 3. Status yang tidak cocok dengan jejak waktunya

| Temuan | Jumlah | Contoh |
|---|---:|---|
| Status `claimed`/`released` tetapi `uploaded_at` kosong | 737 | `NPC/CBCN/PSN/2725/147` |
| Status `done` tetapi `cleared_at` kosong | 53 | `NPC/CMP/MDN/3025/21735` |
| Status `done` tetapi tanpa nomor batch clearing | 590 | `NPC/CBCN/MDN/2125/113` |

Ketiganya berpola sama: dokumen yang **diimpor** dari sistem lama membawa status akhirnya tetapi
tidak membawa jejak waktu dan nomor batch yang seharusnya menyertainya. Dokumen yang lahir di
sistem ini selalu mendapat keduanya.

Tidak menghalangi apa pun hari ini. Tetapi laporan yang menghitung durasi antar tahap — berapa
lama sebuah klaim dari upload sampai cair — akan salah pada 737 dokumen itu, karena titik awalnya
tidak ada.

Hal yang sama membatasi diagram tren mingguan pada email Weekly. Dari empat tanggal pada klaim,
hanya satu yang tersebar cukup untuk dijadikan sumbu waktu:

```
created_at    2.754 terisi, TETAPI seluruhnya 15-Sep-2026 - tanggal impor, bukan kejadian
uploaded_at     171 terisi  - 94% dokumen tidak punya
paid_on          33 terisi  - jauh terlalu sedikit
cleared_at    1.111 terisi, tersebar 23-Agu-2025 sampai 20-Sep-2026
```

Karena itu trennya disusun menurut **minggu pencairan**, dan judulnya menyebutkan itu
terang-terangan. Begitu `uploaded_at` terisi untuk sebagian besar dokumen, sumbunya dapat
dipindahkan ke minggu pengajuan dengan satu baris perubahan.

---

## 4. Mutu data master

| Temuan | Jumlah | Akibatnya |
|---|---:|---|
| Customer tanpa depot mana pun | **639** | tidak muncul di layar Upload siapa pun |
| Customer tanpa rekening lengkap | 1.684 | menghalangi campaign berjenis Transfer |
| Customer tanpa KTP maupun NPWP | 168 | subyek pajak dan gross up tidak terhitung |
| Customer punya KTP **dan** NPWP | 4 | layar menandainya "Check" dan menolak |
| Campaign tanpa periode sama sekali | 20 | periode dokumennya ikut kosong |
| Campaign tanpa status pajak | 1 | `CMPGNNAS2026021` — gross up dihitung penuh |
| Campaign periodenya terbalik | 1 | `CMPGNWEST26002`, mulai 01-Feb-2026 selesai 28-Jan-2026 |
| Depot tanpa region | 1 | `HO` — wajar untuk Head Office |

**639 customer tanpa depot** adalah yang paling perlu diperhatikan. Layar Upload hanya menampilkan
customer yang terhubung ke depot dalam yurisdiksi penggunanya; customer tanpa depot tidak terlihat
oleh siapa pun, termasuk System Manager. Mereka ada di basis data tetapi tidak dapat dipakai.

---

## 5. Akun

| Temuan | Jumlah | Keterangan |
|---|---:|---|
| Akun aktif tanpa satu pun hak modul | 1 | `ANNA_MDN` — dapat masuk, tetapi tidak ada layar yang terbuka |
| Akun memegang dua yurisdiksi | 0 | sudah bersih sesudah perbaikan hari ini |

Keadaan yurisdiksi sesudah perbaikan, dan kini setiap angka efektif **sama persis** dengan yang
dicentang:

```
ANIADMPTI   admin            rp=2  efektif=2     (sebelumnya efektif 3)
ANNA_MDN    admin            rp=1  efektif=1
AYI         admin            rp=0  efektif=0     (depotnya Anda kosongkan saat menguji)
IQBAL       supervisor       -     efektif=0     (belum membina OSC - lihat 7.1)
DANIEL      system manager   -     efektif=52    (sebelumnya efektif 51)
```

Angka AYI dan IQBAL bergerak selama pemeriksaan karena Anda sedang menyunting akunnya. Yang
penting bukan angkanya, melainkan bahwa setiap angka efektif kini **sama persis** dengan sumber
yurisdiksi perannya — tidak ada lagi selisih yang tidak dapat dijelaskan.

---

## 6. Duplikat

**123 pasangan campaign + customer muncul lebih dari sekali.** Compile yang sekarang **menolak**
kombinasi yang sudah ada dengan pesan "Kombinasi campaign dan customer sudah ada", jadi ke-123
pasangan ini pasti terbentuk sebelum aturan itu berlaku.

Perlu Anda putuskan apakah ini sah — satu toko memang boleh menerima dua cashback dari campaign
yang sama — atau hasil compile ganda. Bila sah, aturan compile-nya yang terlalu ketat; bila tidak,
salah satu dari tiap pasangan perlu diarsipkan.

---

## 7. Anomali rancangan yang ditemukan, bukan pada data

### 7.1 Supervisor punya dua ukuran yurisdiksi *(sebagian masih terbuka)*

`rc_private.is_manager()` memasukkan supervisor, dan fungsi itu dipakai Timetable. Tetapi
`rc_private.can_access()` hanya mengistimewakan System Manager, dan `effective_depots` pun begitu.
Akibatnya seorang supervisor melihat **seluruh depot di Timetable** tetapi nyaris **tidak melihat
apa pun** di layar yang bersandar pada `user_depot_access`.

**Koreksi atas versi sebelumnya laporan ini.** Saya sempat menyatukan keduanya dengan memberi
supervisor seluruh depot lewat perannya, sama seperti System Manager. Itu keliru, dan pemilik
meluruskannya: *"untuk supervisor yuridiksinya ke osc tidak bisa ke depot langsung."* Jangkauan
seorang supervisor datang dari **OSC yang ia bina**, bukan dari daftar depot yang ditempelkan
langsung kepadanya — sehingga ia bertambah dan menyusut mengikuti binaannya.

Sudah diperbaiki di `20261112010000`: `effective_depots` mengembalikan gabungan depot milik OSC
binaan, supervisor tidak boleh memegang grant depot langsung, dan grant apa pun dilepas begitu
perannya berpindah.

**Yang masih terbuka:** `rc_timetable_matrix` menyaring depot dengan
`is_manager() or can_access(d.id)`, dan `is_manager()` bernilai benar untuk supervisor. Jadi di
layar Timetable seorang supervisor tetap melihat seluruh depot, termasuk yang di luar binaannya.
Itu bertentangan dengan aturan di atas. Saya tidak mengubahnya karena Anda belum memintanya, dan
mengubah perilaku satu layar tanpa diminta persis kesalahan yang baru saja saya lakukan. Satu
baris perubahan bila Anda menghendaki: `is_manager()` diganti `is_system_manager()`.

**Akibat yang perlu Anda kerjakan:** IQBAL satu-satunya supervisor aktif dan belum membina satu
pun OSC, sehingga jangkauannya kini **nol depot**. Itu benar menurut aturan ini, bukan kegagalan —
yang perlu dilakukan adalah menetapkan OSC binaannya di Access Management.

### 7.2 Depot rumah diam-diam menjadi yurisdiksi *(sudah diperbaiki)*

Ini jawaban atas pertanyaan Anda "kok akun yang tidak saya tick tetap muncul". Rinciannya ada di
migration `20261111010000_rc_yurisdiksi_tunggal.sql`.

Ada jebakan kedua yang lebih halus pada rancangan lama dan ikut hilang: karena kunci unik
`user_depot_grants` adalah (user, depot), menyetel depot rumah ke depot yang **juga** dicentang
akan mengubah baris centang itu menjadi baris rumah — sehingga depotnya justru **hilang** dari
yurisdiksi tanpa ada yang menyentuh centangnya.

### 7.3 Pratinjau email memblokir gambarnya sendiri *(sudah diperbaiki)*

Diagram email adalah `<img>` ke quickchart.io, sedangkan Content-Security-Policy aplikasi
membatasi `img-src` pada `'self' data: blob:`. Jadi browser memblokirnya **di layar pratinjau**,
sementara email yang benar-benar terkirim tetap bergambar — mail client tidak memakai CSP
halaman ini. Gejalanya menyesatkan: tampak seperti diagramnya tidak terbuat, padahal hanya tidak
boleh ditampilkan.

`quickchart.io` kini diizinkan pada `img-src`, di `vercel.json` maupun di server pengembangan.

---

## 8. Yang perlu Anda kerjakan, berurutan menurut dampak

1. **Isi rekening 240 customer** — membuka 317 dokumen, 38% dari seluruh antrean *not_yet*.
2. **Periksa 235 dokumen yang cashback-nya melebihi nilai penjualan** — apakah memang begitu
   aturannya, atau salah kolom saat compile.
3. **Putuskan 123 pasangan campaign+customer ganda** — sah, atau compile ganda yang perlu diarsipkan.
4. **Lengkapi 20 campaign tanpa periode** — membuka periode 38 dokumen yang masih kosong.
5. **Tetapkan OSC binaan IQBAL** di Access Management — tanpa itu jangkauannya nol depot,
   karena yurisdiksi supervisor mengalir lewat OSC.
6. **Beri hak modul ke ANNA_MDN**, atau nonaktifkan akunnya bila memang belum dipakai.
7. **Perbaiki `CMPGNWEST26002`** yang periodenya terbalik, dan **`CMPGNNAS2026021`** yang belum
   punya status pajak.
8. **Bersihkan kolom Volume pada 172 dokumen** yang memuat nilai rupiah. Tidak lagi mendesak
   untuk diagram tren, tetapi kolomnya masih tampil di layar dan ikut terekspor.
9. **Lengkapi KTP/NPWP customer 617445**, dan **periksa 4 customer** yang punya keduanya sekaligus.
10. **639 customer tanpa depot** — hubungkan ke depotnya, atau arsipkan bila memang sudah tidak
   dipakai. Sekarang sudah ada fitur arsip di Key Master untuk itu.
