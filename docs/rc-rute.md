# Alamat (route) Resource Collection

Ditulis untuk: pemilik sistem dan siapa pun yang membagikan tautan ke modul RC.

Sebelumnya seluruh aplikasi hidup di satu alamat, sehingga bilah URL menampilkan hal yang sama
entah orang sedang berada di Claim Upload atau di Timetable, dan tautan ke sebuah modul tidak
mungkin dikirim kepada siapa pun. Sekarang setiap modul punya alamatnya sendiri.

## Dashboard publik — tanpa login

Ketiganya dapat dibuka siapa saja yang memegang tautannya, tanpa masuk ke aplikasi. Isinya
agregat: tidak ada nama toko, KTP, NPWP maupun nomor rekening.

| Alamat | Isi |
|---|---|
| `https://rc-next-gen.vercel.app/dashboard` | Panel Dashboard: KPI, Tren Volume & Nilai, Distribusi Status, Aging, Clearing Rate per Region, Top 10 Depot Outstanding %, tabel per Campaign, Region dan Depot |
| `https://rc-next-gen.vercel.app/dashboard/cost-center-1` | Panel Cost Center 1: Depot × Campaign, empat diagram |
| `https://rc-next-gen.vercel.app/dashboard/cost-center-2` | Panel Cost Center 2: Campaign × Bulan pencairan, dua diagram |

Ketiganya adalah panel yang sama persis dengan tab Dashboard, Cost Center 1 dan Cost Center 2 di
modul Report — markup, diagram, warna dan rumusnya satu sumber, bukan salinan. Lihat bagian
"Satu sumber" di bawah. Alamat `/dashboard/` lain yang tidak dikenal membuka panel Dashboard,
bukan halaman galat.

Bilah tab dan bilah filter Region/Depot/Campaign — beserta tombol Muat Ulang dan Excel — sama
dengan yang ada di modul Report, dari potongan yang sama. Penyaringannya dikerjakan di server oleh
badan agregasi yang sama, bukan disaring di browser, sehingga angkanya tidak dapat berbeda dari
angka di dalam aplikasi untuk filter yang sama.

Tautan pada email Weekly menunjuk `/dashboard`.

## Aplikasi — perlu login

| Alamat | Modul |
|---|---|
| `/` | Beranda (pilihan modul) |
| `/upload` | Claim Upload |
| `/release` | Release Doc |
| `/process` | Claim Process |
| `/analytics` | Analytics |
| `/access` | Access Management |
| `/log-activity` | Log Aktivitas |
| `/bulk-process` | Bulk Process |
| `/key-master` | Key Master |
| `/document-center` | Document Center |
| `/report` | Report |
| `/timetable` | Timetable |
| `/profile` | Profil depot |
| `/approval` | Management of Approval |
| `/people-performance` | People Performance: OSC dan Supervisor |

Alamat bukan sumber kewenangan. Rute hanya menekan kartu menu yang memang sudah terlihat bagi
akun yang sedang masuk; bila hak aksesnya tidak ada, alamatnya berakhir di beranda. Mengetik
`/access` karena itu tidak memberi hak apa pun.

Membuka salah satu alamat itu dalam keadaan belum masuk akan menampilkan formulir login, dan
sesudah berhasil masuk pengguna langsung mendarat di modul yang diminta. Jadi tautan ke
`/timetable` tetap berguna meski penerimanya belum masuk.

## Sesi login

Sesi disimpan di `sessionStorage`, bukan `localStorage`. Akibatnya:

* **Memuat ulang halaman tetap masuk** — tidak perlu PIN lagi.
* **Menutup tab atau jendela menghapus sesi** — membuka aplikasi lagi harus masuk ulang.
* **Tab kedua adalah sesi tersendiri** — membuka aplikasi di tab baru meminta login lagi. Itu
  harga dari aturan di atas, dan lebih aman pada komputer bersama.

Sesi lama yang terlanjur tersimpan di `localStorage` dibersihkan sekali saat halaman dimuat,
sehingga orang yang sudah masuk sebelum perubahan ini tidak tertinggal masuk selamanya.

## Cara kerjanya

`vercel.json` memegang `cleanUrls` dan daftar `rewrites`; seluruh alamat di atas menunjuk satu
halaman, dan halaman itu memilih isinya dari `location.pathname`. Dev server lokal membaca
`vercel.json` yang sama, bukan menyalin aturannya, supaya sebuah rute tidak mungkin bekerja di
`localhost` tetapi 404 setelah deploy.

Catatan bagi yang menyunting `vercel.json`: ketika `cleanUrls` aktif, tujuan `rewrites` harus
berupa alamat bersih (`/`, `/dashboard`), bukan nama berkas (`/index.html`). Menunjuk nama berkas
menghasilkan 404 di Vercel meski berkasnya ada.

## Satu sumber

Pemilik meminta dashboard publik sama dengan modul Report **termasuk jika ada perubahan ke
depan**. Salinan memenuhi "sama hari ini" lalu menyimpang pada suntingan berikutnya, jadi yang
dipakai bukan salinan:

| Lapis | Berkas bersama | Dipakai oleh |
|---|---|---|
| Bilah tab, bilah filter, markup panel | `src/view/parts/report-panes.html` | modul Report dan halaman publik |
| Dialog perbesar kartu | `src/view/parts/card-expand.html` | keduanya |
| Gaya | `src/view/parts/style.html` | keduanya |
| Bilah notifikasi | `src/view/parts/notifikasi.html` | keduanya |
| Penggambar, diagram, filter, ekspor | `src/view/js/*.js` | disisipkan ke `index.html`, dipancarkan sebagai `/assets/rc-report-view.js` untuk halaman publik |
| Agregasi | `rc_private.report_dashboard`, `rc_private.cost_center`, `rc_private.cost_center_2` | `public.rc_report_dashboard` dkk (memeriksa hak akses) dan `public.rc_dashboard_publik(p_filter)` (SECURITY DEFINER) — keduanya meneruskan filter yang sama |

Menambah sebuah diagram karena itu dikerjakan **sekali**: satu `<canvas>` di
`report-panes.html`, satu `rtGambarChart()` di `src/view/js/20-report.js`, lalu naikkan
`JUMLAH_GRAFIK` pada `scripts/test_dashboard_publik.mjs`. Diagramnya langsung muncul di kedua
tempat.

Satu-satunya yang memang berbeda adalah `loadReport()`: dari mana datanya datang. Portal memanggil
satu RPC per tab dengan hak akses pemakainya; halaman publik memanggil satu RPC untuk ketiga panel.
Masing-masing halaman menyediakannya sendiri, dan itulah satu-satunya sambungan yang boleh berbeda.

Dua penjaga membuat hal ini tidak bergantung pada ingatan siapa pun:

* **Build menolak** bila sebuah berkas di `src/view/` berhenti dipakai salah satu halaman —
  misalnya karena seseorang menempelkan salinan panel ke halaman publik.
* **`npm test`** menjalankan skrip halaman publik itu sendiri terhadap data asli di DOM tiruan —
  alamat → `switchReportTab` → `loadReport` → `filterReport` → penggambar — lalu memastikan setiap
  panel terisi, jumlah diagramnya tepat, filter benar-benar mempersempit di sisi server, dan tidak
  ada data pribadi yang ikut tergambar.
