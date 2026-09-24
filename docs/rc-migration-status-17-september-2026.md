# Status migrasi RC — 17 September 2026

Ringkasan sesi ini: pekerjaan frontend dan konfigurasi Vercel selesai dan terverifikasi
secara lokal. Seluruh pekerjaan database terhenti karena akses, bukan karena desain.

## Pemeriksaan langsung terhadap project DEV

Diperiksa lewat HTTPS dengan publishable key, tanpa akses tulis:

| Yang diperiksa | Hasil | Arti |
|---|---|---|
| `rc_list_claims` | HTTP 401 | fungsi ada, ditolak untuk anon |
| `rc_legacy_bootstrap` | HTTP 404 | compat API belum diterapkan |
| `rc_legacy_documents` | HTTP 404 | belum diterapkan |
| `rc_review_request` | HTTP 404 | reset auth belum diterapkan |
| `disable_signup` | `false` | pendaftaran mandiri sudah diizinkan |
| `mailer_autoconfirm` | `false` | konfirmasi email masih menyala, harus dimatikan |

Jadi migration sampai `20260915071855` memang hidup di `vvojshgcduqlugngpzkj`, dan dua
migration baru sesi ini belum. Satu dari tiga setting Auth yang perlu diubah manual sudah
benar; yang wajib diubah tinggal *Confirm email*.

## Yang menghalangi

Supabase MCP pada sesi ini terhubung ke organisasi `NP-Sales-Analytics's Org`, yang hanya
berisi dua project: `gmlnoqghnkkgbgixkpvv` (Pylox) dan `wnvscsrrjpqytydcejvq`. Project DEV
RC `vvojshgcduqlugngpzkj` tidak ada dalam daftar, dan `get_project` terhadapnya menjawab
`You do not have permission to perform this action`.

Project DEV itu sendiri masih hidup. `GET /auth/v1/settings` dengan publishable key pada
`config/rc-auth-dev.js` menjawab HTTP 200. Jadi masalahnya adalah otorisasi connector, bukan
project yang hilang atau dihapus.

Akibatnya, pada sesi ini **tidak ada** migration yang diterapkan, tidak ada SQL yang
dijalankan, dan tidak ada hasil test database yang boleh disebut PASS. Fixture sintetis dari
sesi 16 September juga belum diperiksa maupun dibersihkan.

Untuk melanjutkan diperlukan salah satu dari: connector Supabase yang diotorisasi pada akun
pemilik `vvojshgcduqlugngpzkj`, atau Supabase CLI dengan personal access token pada mesin
operator (`supabase link --project-ref vvojshgcduqlugngpzkj` lalu `supabase db push`).

## Yang selesai pada sesi ini

### Frontend RC berjalan di atas Supabase tanpa perubahan UI

`index (4).html` tidak diubah. `scripts/build-rc-frontend.mjs` menghasilkan `public/` dari
file itu dengan tiga penyuntingan yang di-anchor persis, seluruhnya di dalam blok `<script>`
inline: menyisipkan dua tag script, dan mengalihkan dua pemanggilan `fetch(SCRIPT_URL)` ke
`window.RCBackend.call()`. Build menolak berjalan bila sebuah anchor tidak cocok tepat satu
kali, dan membandingkan halaman dengan seluruh elemen `<script>` dihapus terhadap file lama.
Build yang sukses adalah bukti markup tidak berubah.

`scripts/rc-legacy-adapter.js` memetakan 18 action lama ke RPC Supabase, mengembalikan
bentuk respons yang sama persis sehingga tidak ada handler atau fungsi render yang perlu
disentuh. Identitas, role dan scope depot selalu diambil dari sesi Supabase; `userData`,
`requesterId`, `requesterRole`, `managedDepots` dan `token` yang dikirim browser diterima
lalu diabaikan. Adapter menyimpan `version_no` per dokumen dari setiap respons server,
sehingga optimistic locking tetap berlaku walaupun UI lama hanya mengirim nomor dokumen.
Request id untuk mutasi diturunkan dari payload dan dipakai ulang sampai sukses, sehingga
retry setelah timeout tidak membuat batch kedua.

`supabase/migrations/20260917010000_rc_legacy_compat_api.sql` (**PENDING**) menyediakan sisi
servernya: `rc_legacy_bootstrap`, `rc_legacy_documents`, `rc_legacy_workflow`,
`rc_legacy_dashboard`, `rc_legacy_logs`, `rc_legacy_manageable`, `rc_legacy_update_access`,
`rc_legacy_depot_id` dan `rc_log_activity`. Seluruhnya di atas tabel ber-RLS yang sudah ada.

### Vercel

`vercel.json` dan `package.json` mengunci build, output directory, header keamanan, dan
`no-store` untuk `index.html` serta `rc-env.js`. `config/rc-env.js` memuat flag rollback
`dataBackend` sesuai bagian 13 instruksi migrasi. Rincian: [rc-vercel-deployment.md](rc-vercel-deployment.md).

Produksi `https://rc-next-gen.vercel.app` kini menyajikan build terbaru berisi portal sign
up, identik byte per byte dengan hasil build lokal, tanpa sisa `fetch(SCRIPT_URL)`, di balik
Vercel Authentication (`ssoProtection.deploymentType = all`). Injeksi Vercel toolbar
dimatikan karena itu script pihak ketiga pada halaman yang menampilkan data pelanggan.

Dua catatan penting. Pertama, Vercel CLI pada mesin ini masuk sebagai akun
`01021282025121-8675` dengan satu tim `niel17`, bukan tim `sales-analytics` yang dipakai
connector. Project berada di tim yang salah untuk sistem internal dan perlu dipindahkan.
Kedua, deployment pertama otomatis dipromosikan ke produksi dengan proteksi
`all_except_custom_domains`, sehingga alias publik sempat menjawab HTTP 200. Nilai itu
langsung diubah menjadi `all` dan kedua URL kini menjawab 302 ke login Vercel. Periksa ulang
`ssoProtection` setiap kali project dipindah atau paket berubah.

### Server lokal

`npm run dev` menyajikan `public/` di http://localhost:5173 tanpa dependency apa pun, dengan
header keamanan yang sama persis seperti `vercel.json`, dan membangun ulang otomatis ketika
halaman legacy, adapter, markup sign-up atau config berubah. Server mengikat hanya ke
`127.0.0.1` karena `file://` dan alamat LAN bukan secure context, sehingga `crypto.subtle`
tidak tersedia di sana dan login mustahil berfungsi. Rincian:
[rc-local-development.md](rc-local-development.md).

Pesan kegagalan login dan pendaftaran kini membedakan akun belum terkonfirmasi, rate limit,
User ID sudah terpakai dan pendaftaran dinonaktifkan, alih-alih selalu mengatakan PIN salah.

### Test yang benar-benar dijalankan

- `npm test`: 23 PASS. Termasuk lima test server lokal yang menjalankan server sungguhan
  pada port acak lalu memeriksa header keamanan, penyajian aset, `no-store`, penolakan
  method tulis, dan penolakan path traversal keluar dari `public/`.
- `node --test scripts/test_rc_legacy_adapter.mjs` bersama `test_rc_client.mjs`. Mencakup konversi tanggal
  DD-MM-YYYY ke ISO, penolakan format yang tidak dikenali, konversi bulan tagih `Mon-YY` ke
  `YYYY-MM`, vektor tetap untuk alamat login SHA-256, pemetaan satu baris upload ke item RPC
  termasuk leading zero rekening, penolakan dokumen yang belum dimuat, penolakan nilai
  tagihan negatif, penolakan PIN pendek dan konfirmasi tidak sama pada sign up sebelum ada
  request jaringan, serta keberadaan handler untuk seluruh 19 action.
- `node scripts/build-rc-frontend.mjs`: sukses, markup identik dengan halaman lama.
- `node --check scripts/rc-legacy-adapter.js`: lolos.

`supabase/tests/rc_legacy_compat.sql` dan `supabase/tests/rc_signup_approval.sql` sudah
ditulis tetapi **belum dijalankan**. Yang kedua memeriksa bootstrap manager, pendaftaran
pending tanpa hak akses, penolakan user code ganda dan role tak dikenal, isolasi RLS untuk
akun pending, kotak masuk gabungan, penetapan suffix unik saat approve, penolakan approve
dua kali dan approve diri sendiri, serta penolakan anonim. Yang pertama berisi Isinya
pemeriksaan bentuk bootstrap, isolasi depot antar dua admin, penolakan analytics tanpa
permission, penolakan konsol akses untuk non-manager, round-trip flag huruf legacy, atribusi
log ke aktor sesi, dan penolakan anonim.

### Reset autentikasi dan portal pendaftaran

Atas instruksi pemilik, seluruh akun lama dihapus dan diganti pendaftaran mandiri dengan
persetujuan System Manager. `supabase/migrations/20260917020000_rc_auth_reset_and_signup.sql`
(**PENDING**) menghapus 63 Auth user beserta identity, session, profil, permission dan scope
depot; menambah status `pending` dan `rejected`; memasang trigger pada `auth.users` yang
membuat profil berstatus `pending` tanpa hak akses apa pun; serta menyediakan
`rc_review_registration` dan `rc_review_request`.

Satu user code di-allow-list sebagai bootstrap System Manager, karena tidak ada manager yang
bisa menyetujui manager pertama. Saat ini terisi `DHARTONO` / Daniel Hartono / suffix `001`
sebagai placeholder yang **harus Anda konfirmasi** sebelum migration diterapkan. Password
tidak ada di Git; Daniel memilihnya sendiri saat mendaftar.

Persetujuan dan pemberian hak akses sengaja dipisah. Approve berarti "ini memang rekan
kerja"; modul dan depot tetap ditetapkan terpisah lewat Otorisasi Matrix, sehingga approve
tidak pernah membuka depot orang lain. Baris `claim_status_history` dan `activity_logs`
dipertahankan, tetapi `actor_id` dikosongkan dan user code disalin ke dalam baris lebih dulu
supaya jejak audit tetap terbaca.

Tiga setting Auth di dashboard harus diubah manual sebelum portal berfungsi: matikan
*Confirm email*, biarkan *Allow new users to sign up* menyala, dan samakan panjang minimum
password dengan delapan karakter. Rincian: [rc-auth-signup.md](rc-auth-signup.md).

### Portal sign up di halaman login

Ini satu-satunya perubahan UI yang disengaja, dan diminta langsung oleh pemilik. Build kini
memisahkan penyuntingan *transport* (tidak boleh mengubah markup sama sekali) dari
penyuntingan *sign-up* (menambah markup). Markup tambahan disimpan terpusat di
`scripts/rc-signup-ui.mjs` sehingga build dapat menguranginya kembali dan tetap membuktikan
sisa halaman identik byte per byte dengan file lama.

Kotak masuk persetujuan tidak memerlukan layar baru: pendaftaran pending muncul di daftar
**Kelola Akses → Request** yang sudah ada, bersama permintaan perubahan profil depot,
dibedakan lewat awalan `signup:` dan `profile:` pada id.

## Keputusan yang menunggu pemilik sistem

1. **User ID dan suffix Daniel Hartono.** Placeholder `DHARTONO` / `001` perlu dikonfirmasi
   atau diganti pada satu baris `insert` di awal migration reset auth.
2. **Payload bootstrap.** Layar lama memfilter dan mempaginasi di browser, sehingga
   `rc_legacy_bootstrap` mengirim claim, customer dan campaign dalam scope depot pengguna.
   Ini bertentangan dengan bagian 10.1 instruksi, yang melarang memuat dataset saat login.
   Menggantinya dengan agregat SQL berarti mengubah layar tersebut, yang saat ini dikecualikan.
   Ukuran payload nyata belum diukur; pengukuran memerlukan akses database.
3. **Alasan pada exception dan reject.** Server mewajibkan alasan untuk hold, unhold,
   expire dan seluruh reject. UI lama tidak memintanya. Adapter mengisi kalimat deskriptif
   yang menyebutkan aksi dan tahapnya. Bila alasan harus diisi operator, UI perlu diubah.
4. **Ganti PIN pertama kali.** 63 profil masih `must_change_password=true`. Adapter membuka
   modal "Ganti PIN" yang sudah ada di halaman ketika bootstrap ditolak karena alasan itu,
   lalu memanggil Supabase Auth `updateUser`. Alur ini belum diuji di browser.
5. **Kontak pelanggan.** KTP, NPWP dan rekening kini tersimpan per claim, bukan pada master
   pelanggan. `rc_legacy_customers` mengambil nilai dari claim terbaru per pelanggan dalam
   scope depot, dan hanya untuk akun yang memiliki `upload_claim`.
6. **Pemilik project Vercel.** Project `rc-next-gen` kini berada di tim pribadi `niel17`.
   Untuk sistem internal Nippon Paint, project seharusnya berada di tim `sales-analytics`.
7. **Menu Document Center.** `applyRoleBasedUI` menampilkan kartu Print Document dari flag
   `auth.q`. Karena modul itu ditunda, `rc_legacy_auth_flags` selalu mengembalikan `No`,
   sehingga menu tersebut tidak muncul. Ini konsekuensi permission, bukan perubahan markup,
   tetapi pengguna akan melihat bedanya dan perlu diberi tahu sebelum UAT.

## Yang belum dikerjakan

Document Center tetap ditunda sesuai instruksi pemilik: upload compile, Print Document dan
job sinkronisasi 15 menit tidak disentuh pada sesi ini. Selain itu masih terbuka: penerapan
dan pengujian seluruh migration PENDING, pembersihan fixture E2E 16 September, pengukuran
p50/p95 dan ukuran payload, UAT per role di browser, normalisasi tanggal historis, paritas
ekspor Excel, serta rehearsal cutover dan restore.

Dokumen ini bukan pernyataan bahwa migrasi selesai.
