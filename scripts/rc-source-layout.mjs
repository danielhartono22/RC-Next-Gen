/*
 * Peta modul sumber RC: satu-satunya tempat yang menentukan berkas apa saja yang menyusun
 * halaman dan dalam urutan mana.
 *
 * Dibaca oleh dua skrip yang harus selalu sepakat:
 *   scripts/split-rc-source.mjs   memotong halaman utuh menjadi berkas-berkas ini (sekali)
 *   scripts/build-rc-frontend.mjs merakitnya kembali menjadi public/index.html (setiap build)
 *
 * MENGAPA BATASNYA BERUPA NOMOR BARIS
 * Hanya pemotongan pertama yang memakai nomor baris ini, dan hasilnya langsung dibuktikan
 * identik byte per byte dengan halaman asal. Sesudah itu berkas-berkas di src/ menjadi sumber
 * kebenaran dan nomor-nomor ini tidak dipakai lagi untuk apa pun kecuali menjelaskan asal-usul
 * tiap potongan. Karena itu menyunting src/ tidak akan membuat peta ini basi.
 *
 * URUTAN ADALAH SEGALANYA
 * Skrip halaman ini satu ruang lingkup global tanpa modul ES. Deklarasi tingkat atas dibaca
 * berurutan, jadi potongan JavaScript harus dirakit persis pada urutan aslinya. Awalan angka
 * pada nama berkas menjaga urutan itu tetap terbaca oleh manusia maupun mesin.
 */

// Setiap entri: berkas tujuan, baris awal dan akhir (1-based, inklusif) pada halaman asal,
// dan satu kalimat tentang isinya.
export const MARKUP_PARTS = [
  { file: 'head.html',                          from: 1,    to: 29,   note: 'doctype, meta, CDN dan blok style' },
  { file: 'sections/topbar.html',               from: 30,   to: 78,   note: 'body, header, navigasi utama' },
  { file: 'sections/login.html',                from: 79,   to: 95,   note: 'portal login dan tautan Daftar' },
  { file: 'sections/dashboard.html',            from: 96,   to: 115,  note: 'kartu menu modul' },
  { file: 'sections/profile.html',              from: 116,  to: 213,  note: 'Profil Depot' },
  { file: 'sections/workspace-open.html',       from: 214,  to: 216,  note: 'pembuka area modul' },
  { file: 'modules/claim-upload.html',          from: 217,  to: 345,  note: 'Claim Upload: mass, manual, preview' },
  { file: 'modules/release.html',               from: 346,  to: 383,  note: 'Release Doc' },
  { file: 'modules/claim-process.html',         from: 384,  to: 489,  note: 'Claim to Finance dan Clearing' },
  { file: 'modules/analytics.html',             from: 490,  to: 556,  note: 'Analytics: History dan Summary' },
  { file: 'modules/log-activity.html',          from: 557,  to: 582,  note: 'Log Activity' },
  { file: 'modules/bulk-process.html',          from: 583,  to: 623,  note: 'Bulk Process' },
  { file: 'modules/key-master.html',            from: 624,  to: 637,  note: 'Key Master' },
  { file: 'modules/compilation.html',           from: 638,  to: 650,  note: 'Cashback Compilation' },
  { file: 'modules/row-editor.html',            from: 651,  to: 655,  note: 'editor baris master' },
  { file: 'modules/kelola-akses.html',          from: 656,  to: 712,  note: 'Kelola Akses: list akun dan tambah akun' },
  { file: 'sections/workspace-close.html',      from: 713,  to: 714,  note: 'penutup area modul' },
  { file: 'modals/master-depot.html',           from: 715,  to: 727,  note: 'modal Master Depot' },
  { file: 'modals/hasil-eksekusi.html',         from: 728,  to: 740,  note: 'modal hasil eksekusi' },
  { file: 'modals/confirm-master.html',         from: 741,  to: 749,  note: 'modal konfirmasi master' },
  { file: 'modals/generic-confirm.html',        from: 750,  to: 764,  note: 'pengganti confirm() dan alert() bawaan' },
  { file: 'modals/edit-akses.html',             from: 765,  to: 769,  note: 'Console Otorisasi Matrix' },
  { file: 'modals/signup.html',                 from: 770,  to: 774,  note: 'modal pendaftaran akun' },
  { file: 'modals/request-pin.html',            from: 775,  to: 779,  note: 'modal permintaan ganti PIN' },
  { file: 'modals/detail-history.html',         from: 780,  to: 820,  note: 'modal detail history' }
];

// Baris <script> pembuka dan </script> penutup tetap tinggal di shell, bukan di potongan JS,
// supaya berkas .js benar-benar berisi JavaScript saja dan bisa diperiksa "node --check".
export const SCRIPT_OPEN_LINE = 821;
export const SCRIPT_CLOSE_LINE = 3211;

export const SCRIPT_PARTS = [
  { file: '10-util-dasar.js',        from: 822,  to: 864,  note: 'SCRIPT_URL, debounce, hasil eksekusi' },
  { file: '15-form-tunggal.js',      from: 865,  to: 955,  note: 'input manual satu dokumen' },
  { file: '20-template-excel.js',    from: 956,  to: 1086, note: 'template upload dan pembacaan Excel' },
  { file: '25-bootstrap.js',         from: 1087, to: 1189, note: 'state global, DOMContentLoaded, normalisasi' },
  { file: '30-ui-dasar.js',          from: 1190, to: 1270, note: 'notifikasi, overlay, modal, fetchApp' },
  { file: '35-navigasi-login.js',    from: 1271, to: 1381, note: 'navigasi modul, login, profil' },
  { file: '40-key-master.js',        from: 1382, to: 1672, note: 'Customer Master dan Campaign Master' },
  { file: '45-compilation.js',       from: 1673, to: 1810, note: 'Cashback Compilation' },
  { file: '50-modal-depot.js',       from: 1811, to: 1843, note: 'Master Depot, edit profil, multiselect' },
  { file: '55-grid-input.js',        from: 1844, to: 1996, note: 'grid input massal dan preview' },
  { file: '60-upload-submit.js',     from: 1997, to: 2064, note: 'pengiriman upload dan exception' },
  { file: '65-workflow.js',          from: 2065, to: 2401, note: 'Release, Claim Process, Bulk Process' },
  { file: '70-analytics.js',         from: 2402, to: 2619, note: 'dashboard, history, summary, ekspor' },
  { file: '75-kelola-akses.js',      from: 2620, to: 2833, note: 'konsol akses dan log activity' },
  { file: '80-signup.js',            from: 2834, to: 2900, note: 'pendaftaran akun baru' },
  { file: '85-tab-open.js',          from: 2901, to: 3023, note: 'tab Open pada Claim Upload' },
  { file: '90-format.js',            from: 3024, to: 3111, note: 'matriks izin, warna status, angka penuh' },
  { file: '95-compile-upload.js',    from: 3112, to: 3210, note: 'unggah compile dan permintaan ganti PIN' }
];

export const TAIL_FROM = 3212;
