# Menjalankan Resource Collection di lokal

Ditulis untuk: siapa pun yang mengembangkan atau menguji RC di komputernya sendiri.

## Mulai

```powershell
npm run dev
```

Buka **http://localhost:5173**.

Tidak ada dependency yang perlu dipasang. Server memakai modul bawaan Node (minimal Node 20),
dan menjalankan build lebih dulu, jadi `npm run dev` selalu menyajikan hasil build terbaru.

Port lain: `node scripts/dev-server.mjs --port 8080`.

## Jangan buka filenya langsung

Membuka `public/index.html` lewat `file://` tidak akan berfungsi. `file://` bukan secure
context, sehingga `crypto.subtle` tidak tersedia — padahal alamat login diturunkan dari
SHA-256 User ID. Import modul dan penyimpanan sesi Supabase juga gagal di sana.

Alasan yang sama berlaku untuk alamat LAN seperti `http://192.168.x.x:5173`. Browser hanya
memperlakukan `localhost` sebagai secure context di luar HTTPS. Karena itu server sengaja
hanya mengikat ke `127.0.0.1`, bukan `0.0.0.0`. Untuk menguji dari perangkat lain, pakai
deployment Vercel.

## Apa yang dilakukan server ini

- menyajikan `public/` dengan **header keamanan yang sama persis** seperti `vercel.json`,
  sehingga masalah Content-Security-Policy muncul di lokal, bukan setelah deploy;
- `index.html` dan `assets/rc-env.js` dikirim `no-store`, sama seperti di produksi, supaya
  pergantian flag `dataBackend` langsung terlihat;
- **build ulang otomatis** ketika `index (4).html`, `scripts/rc-legacy-adapter.js`,
  `scripts/rc-signup-ui.mjs` atau `config/rc-env.js` berubah. Cukup refresh browser;
- menolak method selain GET/HEAD, dan menolak path yang keluar dari `public/`.

Kalau build gagal, server menjawab HTTP 500 dengan pesan build tersebut, bukan menyajikan
halaman lama yang menyesatkan.

## Perintah lain

| Perintah | Kegunaan |
|---|---|
| `npm run dev` | server lokal di http://localhost:5173 |
| `npm run build` | tulis `public/` sekali |
| `npm run check` | verifikasi anchor build dan markup tanpa menulis apa pun |
| `npm test` | 23 test: adapter, util CSV, dan server lokal |
| `npm run deploy` | promote ke produksi Vercel |

## Kondisi backend saat ini

Diperiksa langsung terhadap `https://vvojshgcduqlugngpzkj.supabase.co` pada 17 September 2026:

| Yang diperiksa | Hasil | Arti |
|---|---|---|
| `rc_list_claims` | HTTP 401 | fungsi **ada**, ditolak untuk anon seperti seharusnya |
| `rc_legacy_bootstrap` | HTTP 404 | migration compat API **belum diterapkan** |
| `rc_legacy_documents` | HTTP 404 | belum diterapkan |
| `rc_review_request` | HTTP 404 | migration reset auth **belum diterapkan** |
| `disable_signup` | `false` | pendaftaran mandiri sudah diizinkan |
| `mailer_autoconfirm` | `false` | **konfirmasi email masih menyala** |

Artinya migration sampai `20260915071855` memang sudah hidup di project itu, sedangkan
`20260917010000_rc_legacy_compat_api.sql` dan `20260917020000_rc_auth_reset_and_signup.sql`
belum.

Jadi sampai keduanya diterapkan: halaman terbuka normal, tombol **Daftar di sini** terbuka,
tetapi login akan gagal karena `rc_legacy_bootstrap` belum ada.

`mailer_autoconfirm: false` adalah masalah tersendiri. Alamat login berakhiran `.invalid`
dan tidak pernah bisa menerima email, sehingga setiap akun baru akan tersangkut sebagai
unconfirmed. Matikan **Confirm email** di Authentication → Sign In / Providers → Email. Sampai
itu dilakukan, form pendaftaran akan mengatakan apa adanya bahwa pendaftaran tercatat tetapi
login belum bisa dilakukan, dan form login akan mengatakan akun belum terkonfirmasi — bukan
"PIN salah" yang menyesatkan.

## Menguji jalur rollback

Ubah `dataBackend` di `config/rc-env.js` menjadi `'apps_script'`, refresh browser, dan
halaman kembali memanggil deployment Apps Script lama persis seperti sebelum migrasi.

Lakukan ini hanya di lokal. Jalur itu memakai backend produksi yang mengambil identitas dari
payload browser, dan tidak boleh dipublikasikan tanpa proteksi deployment. Kembalikan ke
`'supabase'` sebelum commit.
