# Menghubungkan RC ke Gmail untuk email otomatis

Dokumen ini berisi langkah sekali-jalan untuk memberi RC izin mengirim email lewat akun Gmail
Anda. Sesudah selesai, RC memperbarui izinnya sendiri dan tidak akan meminta apa pun lagi.

## Yang perlu Anda tahu lebih dulu

**App Password tidak bisa dipakai.** App Password hanya berlaku untuk SMTP, sedangkan RC
mengirim lewat Gmail API. Sebabnya teknis: RC mengirim dari dalam database Supabase, dan
PostgreSQL tidak dapat bicara SMTP sama sekali — ia hanya bisa HTTPS. Gmail API berbasis HTTPS,
jadi itu satu-satunya jalan yang tersedia, dan Gmail API mensyaratkan OAuth2.

**Batas harian Gmail.** Google Workspace sekitar 2.000 penerima per hari, Gmail biasa sekitar
500. Email Daily yang menyasar banyak depot bisa menyentuh batas itu. Kalau tersentuh, Gmail
menolak dan alasannya tersimpan apa adanya di antrean RC — tidak ada email yang hilang diam-diam.

**Alamat pengirim.** Harus akun yang memberi izin pada langkah di bawah, atau alias yang sudah
diverifikasi lewat Gmail → Settings → Accounts → "Send mail as".

## Langkah 1 — Buat project dan aktifkan Gmail API

1. Buka <https://console.cloud.google.com/> dan buat project baru, misalnya `RC Email`.
2. Masuk ke **APIs & Services → Library**, cari **Gmail API**, lalu tekan **Enable**.

## Langkah 2 — Siapkan layar persetujuan

1. **APIs & Services → OAuth consent screen**.
2. Pilih **Internal** bila akun Anda Google Workspace (`bi-nipponpaint.com`). Internal lebih
   sederhana: tidak perlu proses verifikasi Google.
   Bila memilih **External**, tambahkan akun Anda sendiri pada daftar **Test users**.
3. Pada **Scopes**, tambahkan satu scope saja:

   ```
   https://www.googleapis.com/auth/gmail.send
   ```

   Scope ini hanya mengizinkan *mengirim*. RC tidak akan bisa membaca, menghapus, atau melihat
   isi kotak masuk Anda.

## Langkah 3 — Buat OAuth client

Pilih **Desktop app**. Tipe ini tidak memerlukan Authorized redirect URI sama sekali: Google
mengizinkannya memakai alamat loopback `http://127.0.0.1` tanpa didaftarkan. Itu menghilangkan
`redirect_uri_mismatch`, penyebab kegagalan yang paling sering terjadi.

1. **APIs & Services → Credentials → Create Credentials → OAuth client ID**.
2. **Application type**: **Desktop app**.
3. **Name**: bebas, misalnya `RC Email Client`.
4. Tekan **Create**. Salin **Client ID** dan **Client Secret** yang muncul.

Tidak ada kolom lain yang perlu diisi. Bila Anda melihat kolom Authorized redirect URI, berarti
tipe yang terpilih bukan Desktop app.

## Langkah 4 — Ambil refresh token

Jalankan dari folder project, di terminal:

```
npm run gmail:token
```

Skrip akan meminta Client ID dan Client Secret, lalu membuka browser. Pilih akun Gmail yang akan
menjadi **pengirim** — akun inilah yang namanya muncul di email yang diterima depot. Setujui,
dan refresh token-nya tercetak di terminal beserta empat perintah Vault yang tinggal disalin.

Yang dilakukan skrip itu, supaya tidak ada yang tersembunyi:

- Membuka satu port lokal sementara sebagai alamat pengembalian, lalu menutupnya kembali.
- Meminta `prompt=consent` secara eksplisit, sehingga Google **selalu** menerbitkan refresh
  token — termasuk bila akun itu sudah pernah memberi izin. Ini menghilangkan jebakan "kolom
  Refresh token kosong" yang pada jalur Playground menuntut pencabutan izin manual lebih dulu.
- Memakai PKCE, sehingga kode izin yang tercuri di tengah jalan tidak dapat ditukar oleh proses
  lain.
- Client Secret hanya dipakai untuk satu penukaran ke Google, dan tidak pernah ditulis ke berkas.

### Bila browser tidak terbuka sendiri

Alamat lengkapnya tercetak di terminal. Salin dan buka manual; sisanya berjalan sama.

### Bila Anda lebih suka lewat OAuth Playground

Jalur itu masih bisa dipakai, tetapi menuntut satu langkah tambahan yang mudah salah: OAuth
client harus bertipe **Web application**, dan alamat `https://developers.google.com/oauthplayground`
harus didaftarkan sebagai Authorized redirect URI — persis, tanpa garis miring di akhir. Scope
`gmail.send` diketik sendiri pada kotak *"Input your own scopes"* di bawah daftar API, bukan
dipilih dari daftarnya. Bila menemui galat, lihat tabel di bawah.

## Langkah 5 — Simpan kredensialnya di RC

Buka Supabase Dashboard → SQL Editor pada project `vvojshgcduqlugngpzkj`, lalu jalankan empat
perintah berikut dengan nilai Anda sendiri:

```sql
select vault.create_secret('<CLIENT_ID>',     'rc_gmail_client_id',     'Gmail OAuth client id');
select vault.create_secret('<CLIENT_SECRET>', 'rc_gmail_client_secret', 'Gmail OAuth client secret');
select vault.create_secret('<REFRESH_TOKEN>', 'rc_gmail_refresh_token', 'Gmail refresh token');
select vault.create_secret('RC Reporting <akun.anda@bi-nipponpaint.com>', 'rc_email_from', 'Alamat pengirim');
```

Nilainya disimpan terenkripsi di Vault, bukan sebagai teks biasa di tabel. Itu penting: sebuah
kunci yang tersimpan sebagai teks akan ikut terbawa setiap kali tabelnya dibaca, ikut masuk ke
backup, dan ikut terlihat di log.

Bila suatu saat perlu diganti, pakai `vault.update_secret` dengan nama yang sama.

## Langkah 6 — Uji

Jalankan di SQL Editor:

```sql
select public.rc_email_uji_koneksi();
```

Jawaban yang diharapkan memuat `"gmailSiap": true` dan pesan *"Gmail siap. Access token berhasil
diperoleh."*

Bila masih `false`, pesan galatnya menyebutkan sebabnya — biasanya salah satu dari: scope belum
ditambahkan, refresh token tersalin tidak lengkap, atau akun belum masuk daftar Test users pada
mode External.

## Langkah 7 — Nyalakan jadwalnya

Jadwal email seluruhnya **nonaktif** sejak awal, dan memang disengaja: tidak ada email yang
terkirim sebelum Anda menyalakannya dengan sadar. Nyalakan lewat layar Report di RC, atau
langsung:

```sql
select public.rc_email_settings_simpan('[
  {"jenis":"daily",     "aktif":true, "jam":7},
  {"jenis":"weekly",    "aktif":true, "jam":8, "hari":5},
  {"jenis":"timetable", "aktif":true, "jam":8, "hari":1}
]'::jsonb);
```

`hari` memakai 0 untuk Minggu sampai 6 untuk Sabtu. Jam memakai waktu Asia/Jakarta.

Sebelum menyalakan, pastikan kolom **Email TO** pada Key Master → Depot Master sudah terisi.
Tanpa itu email tetap tersusun tetapi tidak dikirim, dan tercatat sebagai `skipped` dengan
alasan yang jelas.

## Cara memantau

```sql
select public.rc_email_status();
```

Mengembalikan pengaturan jadwal, lima puluh baris terakhir antrean beserta statusnya, dan
jumlah depot yang sudah punya alamat. Status yang mungkin muncul:

| Status | Artinya |
|---|---|
| `pending` | Sudah disusun, menunggu dikirim |
| `sent` | Sudah diserahkan ke Gmail |
| `failed` | Gmail menolak; kolom galat memuat alasannya |
| `skipped` | Sengaja tidak dikirim, misalnya tidak ada depot outstanding atau belum ada alamat |

Pengiriman dijalankan otomatis setiap jam oleh `pg_cron`. Untuk menjalankannya segera tanpa
menunggu:

```sql
select public.rc_email_jalankan_antrean(50);
select public.rc_email_periksa();
```

`rc_email_periksa` membaca jawaban Gmail dan menandai baris yang benar-benar gagal. Tanpa
langkah itu, status `sent` hanya berarti permintaannya berhasil dititipkan, belum tentu
diterima.

## Mencabut izin

Kapan pun, buka <https://myaccount.google.com/permissions> dan cabut akses aplikasi tersebut.
RC akan berhenti mengirim, dan email menumpuk di antrean dengan status `pending` — tidak ada
yang hilang.
