# RC authentication: reset, self registration, approval

Written for: the System Manager who will run the first sign-up, and the engineer who applies
the migration.

Supersedes [rc-auth-deployment.md](rc-auth-deployment.md). The imported-PIN model described
there is removed in full.

## What changes

The owner asked for every existing account to be deleted and replaced by a portal where
people register themselves and a System Manager approves them. That is what
`supabase/migrations/20260917020000_rc_auth_reset_and_signup.sql` does. It has **not been
applied**: this session had no permission on project `vvojshgcduqlugngpzkj`.

The target project is `vvojshgcduqlugngpzkj`. It is not one of the projects in the
`NP-Sales-Analytics` organisation, and `config/rc-env.js` already points at it.

## The account lifecycle

```
sign up  ->  pending  ->  System Manager approves  ->  active, no scope yet
                      \                                      |
                       ->  rejected                          v
                                              Otorisasi Matrix grants
                                              permissions and depots
```

Approval and authorisation are deliberately two steps. Approving says "this is a real
colleague". It does not hand over any module or any depot. The System Manager then opens
**Kelola Akses → Otorisasi Matrix** and grants permissions and depot scope explicitly, so an
approval can never accidentally expose another depot's claims. An account that is approved
but not yet scoped can sign in and sees an empty portal.

A pending account fails every access check, so RLS hides all claims, customers, campaigns
and logs from it. The login form tells the person their registration is waiting.

## The first System Manager

Owner decision, 17 September 2026: **the first account to register becomes the System
Manager.** There is no allow-list, no seeded user code and no password anywhere in Git. The
first person to open the portal after the reset registers normally and is created active,
with the System Manager role, every permission, every depot and batch suffix `001`. Every
registration after that is `pending`.

The trigger takes an exclusive lock on `public.profiles` before deciding, so two people
registering at the same instant cannot both become manager.

**Understand the window.** Between applying the migration and that first registration,
whoever reaches the sign-up form first gets full access to every depot. Keep it short:
register immediately after applying. Both entry points are already restricted while you do
it — the Vercel deployment sits behind Vercel Authentication, and the local server binds to
`127.0.0.1` only. Do not publish an unprotected URL before the first account exists.

Once one profile exists the window closes by itself.

## Sign up

The login portal now carries **Belum punya akun? Daftar di sini**, which opens a dialog
asking for User ID, nama lengkap, email kantor, depot, role yang diminta and a PIN of at
least eight characters, entered twice.

Role and depot are recorded as a *request*, shown to the System Manager, and never used to
grant anything. Depot is free text on purpose: reading the depot master requires a session,
and adding an endpoint that anonymous visitors can read was not worth four depot names.

The password is verified by Supabase Auth. The login identifier stays the user ID: the
account's Auth address is `sha256(trimmed user ID)@rc-login.invalid`, the same derivation the
previous model used. Business email is stored on the profile but is not the login identity,
because the source data has 42 unique business emails across 63 people and using a shared
address as an identity would merge two colleagues into one account.

Batch suffixes are assigned at approval by `rc_private.next_suffix()`, which skips any suffix
already held by an active profile or already used by a batch counter, so two active accounts
can never produce colliding batch numbers. A pending account carries `000`, which is the
unassigned marker.

## Approving

Pending registrations appear in **Kelola Akses → Request**, the inbox that already exists,
alongside depot profile change requests. Each card shows the requested name, email, role and
depot with Approve and Reject buttons. No new screen was added for this; the request id
carries a `signup:` or `profile:` prefix and `rc_review_request` routes it.

A System Manager cannot approve their own account, cannot approve the same registration
twice, and cannot open the Otorisasi Matrix for an account that is still pending.

## Project settings that must be changed by hand

**Email confirmation must be off.** Sign-up addresses end in `.invalid` and can never receive
mail, so with "Confirm email" enabled every new account would be stuck unconfirmed. In the
Supabase dashboard: Authentication → Sign In / Providers → Email → turn off *Confirm email*.

**Leave sign-ups enabled.** Authentication → Sign In / Providers → *Allow new users to sign
up* must stay on, or the portal's Daftar button returns "Signups not allowed".

**Check the minimum password length.** The UI and the adapter both require eight characters.
If the project is set higher, raise the UI limit to match rather than letting the server
reject what the form accepted.

Account recovery stays administrative. `.invalid` addresses cannot receive a reset mail, and
a shared business email must never become an automatic recovery identity, so a forgotten PIN
is reset by a System Manager after verifying the person out of band.

## What the reset destroys

Running the migration deletes all 63 Auth users with their identities, sessions and refresh
tokens, all profiles, all permission and depot grants, all pending profile change requests,
and the stored idempotency records.

Claims, campaigns, customers, depots, batch counters and snapshots are not touched. Audit
rows in `claim_status_history` and `activity_logs` are kept, but their `actor_id` is cleared
because the profile it referenced no longer exists. The user code is copied into the row
first, into `activity_logs.details.former_actor_user_code` and into the history `reason`
field, so the trail stays readable.

**Take a `pg_dump` before running it.** The Free plan has no automatic backup, and this step
cannot be undone from inside the database.

## Cara membuat akun: langkah konkret

Anda punya akses Dashboard ke project `vvojshgcduqlugngpzkj`, jadi seluruh langkah di bawah
bisa dikerjakan sendiri tanpa menunggu connector.

### Langkah 0 — backup

Dashboard → Database → Backups tidak tersedia pada paket Free. Ambil dump manual lebih dulu,
karena reset auth tidak bisa dibatalkan:

```powershell
npx supabase db dump --db-url "postgresql://postgres:<PASSWORD>@db.vvojshgcduqlugngpzkj.supabase.co:5432/postgres" -f backup-sebelum-reset-auth.sql
```

Password database ada di Dashboard → Project Settings → Database. Simpan dump di luar
repository; isinya data pelanggan.

### Langkah 1 — periksa kondisi project

Dashboard → SQL Editor → tempel isi `supabase/queries/rc_check_migration_state.sql` → Run.

Query itu hanya membaca. Hasilnya memberi tahu migration mana yang sudah ada, berapa akun
yang akan terhapus, dan berapa baris data bisnis yang harus tetap sama sesudahnya. Catat
angka `claims`, `customers` dan `campaigns` untuk dibandingkan nanti.

### Langkah 2 — terapkan migration yang belum ada

Cara tercepat: buka `supabase/apply-pending.sql`, salin seluruh isinya ke SQL Editor, Run.
File itu dihasilkan oleh `npm run bundle` dan sudah berisi migration yang belum ada dengan
urutan yang benar, dibungkus satu transaksi.

Di depannya ada penjaga. Kalau salah satu migration ternyata sudah pernah diterapkan, dia
berhenti dengan pesan yang menyebut nama filenya dan **tidak ada** yang tersimpan. Kalau itu
terjadi, buat ulang bundle tanpa file tersebut:

```powershell
npm run bundle -- --skip <versi yang sudah ada>
```

Contoh nyata pada 17 September 2026: `20260916010000` ternyata sudah ada di project, jadi
bundle dibuat ulang dengan `--skip 20260916010000` dan sekarang hanya berisi dua migration.

Kalau lebih suka manual, jalankan file aslinya satu per satu dengan urutan ini:

1. `supabase/migrations/20260916010000_rc_transaction_input_validation.sql`
2. `supabase/migrations/20260917010000_rc_legacy_compat_api.sql`
3. `supabase/migrations/20260917020000_rc_auth_reset_and_signup.sql`

Migration ini tidak idempotent; jangan menjalankan ulang yang sudah ada.

Sesudahnya jalankan ulang query langkah 1. `auth_users` dan `profiles` harus 0, dan angka
data bisnis harus sama persis seperti sebelumnya.

### Langkah 3 — matikan konfirmasi email

Dashboard → Authentication → Sign In / Providers → Email → matikan **Confirm email** → Save.

Ini wajib. Alamat login berakhiran `.invalid` dan tidak pernah bisa menerima email, jadi
selama setting ini menyala setiap akun baru tersangkut sebagai unconfirmed dan tidak bisa
login walaupun sudah disetujui.

Sudah diperiksa pada 17 September 2026: `disable_signup` sudah `false` (benar), tetapi
`mailer_autoconfirm` masih `false`, artinya konfirmasi email masih menyala.

### Langkah 4 — daftar sebagai orang pertama

Buka portalnya, lokal lewat `npm run dev` di http://localhost:5173 atau
https://rc-next-gen.vercel.app, lalu klik **Belum punya akun? Daftar di sini**.

Isi User ID yang Anda mau, nama, email kantor, depot, role, dan PIN minimal delapan
karakter. Karena ini pendaftaran pertama sesudah reset, akun langsung aktif sebagai System
Manager dengan seluruh permission dan seluruh depot.

Layar akan menampilkan kotak hijau **Pendaftaran Berhasil** beserta User ID yang tercatat.
Kalau kotak itu tidak muncul, pendaftaran gagal dan pesan merahnya menjelaskan sebabnya.

Lalu login dengan User ID dan PIN yang sama.

Verifikasi di SQL Editor:

```sql
select user_code, full_name, role, status, suffix_num from public.profiles;
```

Harus ada satu profil `active` dengan role `system manager` dan suffix `001`.

### Kalau akun Anda malah berstatus "menunggu persetujuan"

Artinya sudah ada profil lain yang terdaftar lebih dulu, jadi akun itulah yang menjadi
System Manager. Penyebab paling umum: mencoba mendaftar dua kali, sehingga pendaftaran
pertama yang mengambil peran manager.

Lihat dulu apa yang ada:

```
supabase/queries/rc_lihat_akun.sql
```

Tempel ke SQL Editor lalu Run. Baris teratas adalah akun yang terdaftar lebih dulu.

Kalau akun itu memang milik Anda, cukup login memakai User ID tersebut. Kalau itu sisa
percobaan yang tidak terpakai, jadikan akun Anda sebagai System Manager:

```
supabase/queries/rc_jadikan_system_manager.sql
```

Ganti `ISI_USER_ID_ANDA_DI_SINI` dengan User ID Anda, lalu Run. Skrip menolak berjalan bila
placeholder itu belum diganti, dan menetapkan suffix batch yang belum dipakai supaya nomor
batch tidak bentrok.

Ini tindakan administratif sekali jalan. Sesudah ada satu System Manager aktif, seluruh
persetujuan berikutnya dilakukan lewat aplikasi di menu Kelola Akses, bukan lewat SQL.

### Langkah 5 — akun berikutnya

Semua orang lain mendaftar lewat portal yang sama dan masuk antrean `pending`. Anda buka
**Kelola Akses → Request**, klik Approve, lalu buka **Otorisasi Matrix** untuk menetapkan
modul dan depotnya. Approve saja tidak memberi akses apa pun.

### Kenapa tombol "Add user" di Dashboard tidak bisa dipakai

Tombol itu hanya mengirim email dan password, tanpa User ID, nama, atau role. Akun seperti
itu tidak akan pernah bisa login karena RC mencari profil berdasarkan User ID. Trigger
pendaftaran menolaknya dengan pesan yang menjelaskan hal ini.

Kalau memang perlu membuat akun tanpa portal, misalnya untuk pemulihan, sertakan metadatanya
lewat Admin API:

```
POST https://vvojshgcduqlugngpzkj.supabase.co/auth/v1/admin/users
Authorization: Bearer <service_role key>
apikey: <service_role key>

{
  "email": "<sha256 dari User ID>@rc-login.invalid",
  "password": "<pilih password>",
  "email_confirm": true,
  "user_metadata": {
    "user_code": "NAMAUSER",
    "full_name": "Nama Lengkap",
    "business_email": "nama@bi-nipponpaint.com",
    "requested_role": "admin",
    "requested_depot": "Nama Depot"
  }
}
```

Alamat emailnya harus SHA-256 heksadesimal dari User ID yang sudah di-trim, karena itulah
yang dicari halaman login. Jalankan hanya dari komputer operator; service_role key tidak
boleh masuk browser, repository, atau chat.

## Order of work once database access is restored

1. `pg_dump` the DEV project and verify the dump restores somewhere else.
2. Apply `20260916010000_rc_transaction_input_validation.sql` (still pending) and run
   `supabase/tests/rc_input_validation.sql`.
3. Apply `20260917010000_rc_legacy_compat_api.sql`, run `supabase/tests/rc_legacy_compat.sql`.
4. Change the three Auth project settings above.
5. Apply `20260917020000_rc_auth_reset_and_signup.sql`.
6. Run `supabase/tests/rc_signup_approval.sql` in a rolled back transaction.
7. Daniel registers first through the portal and confirms he lands in the dashboard as
   System Manager.
8. A second person registers, Daniel approves them, grants scope in the Otorisasi Matrix,
   and that person confirms they see only their own depot.
9. Only then run the browser UAT per role described in the migration instruction.

Nothing in steps 2 to 9 has been done. No result in this document may be reported as tested.
