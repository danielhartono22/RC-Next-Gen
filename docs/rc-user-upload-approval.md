# Upload user dan approval — 24 September 2026

Download template terbaru melalui **Access Management → Registrasi → Template Upload User**.
Sheet Users hanya memiliki tujuh kolom, dengan urutan berikut:

| Kolom | Isi |
|---|---|
| User ID | ID unik; disimpan dalam huruf besar |
| Nama Lengkap | Nama pengguna, maksimal 200 karakter |
| Kode Depot | Satu kode depot asal, bukan nama |
| Email | Email korespondensi |
| Role | admin, depot head, osc, supervisor, finance, others, management, atau system manager sesuai izin pengunggah |
| PIN | Minimal 8 karakter, maksimal 72 byte; nol di depan dipertahankan |
| Resource Partner / Area | Kode depot yurisdiksi, misalnya 001,002,003 |

Template tidak meminta Department, OSC Codes, Regions, maupun suffix. Gunakan kode depot di kolom Resource Partner / Area, bukan nama region atau user ID OSC. Kolom kode dan PIN menggunakan format teks. Maksimal 500 user per file; PIN tidak ditampilkan pada preview.

## Alur

1. Pilih file dan periksa identitas, role, depot asal, serta seluruh depot Resource Partner / Area pada preview.
2. Klik **Ajukan Approval / Retry Gagal**. Akun Auth dan proposal tersimpan sebagai **Pending** tanpa grant modul atau depot efektif.
3. Buka **Access Management → Approval Request**. Reviewer melihat User ID, nama, email, role yang diminta, depot asal, dan seluruh kode area.
4. Approve mengaktifkan role, membuat suffix otomatis, dan menerapkan area yang disetujui. User tetap wajib mengganti PIN awal. Izin modul mengikuti role dan pengaturan Edit Akses.
5. Reject membuat akun tetap tidak aktif. Edit Akses tidak dapat melompati approval atau mengaktifkan proposal upload yang ditolak.

Resource Partner menjadi grant RP untuk Admin; role lain memperoleh area depot langsung. Supervisor dapat tetap memiliki OSC binaan, dan Management dapat tetap memiliki region tambahan melalui Edit Akses. Upload kode depot tidak menebak mapping OSC atau memperluas area ke seluruh region. System Manager memperoleh scope global setelah approval oleh System Manager; kolom area boleh kosong untuk role ini.

Uploader dan reviewer harus berwenang atas seluruh depot proposal. Supervisor tidak dapat mengajukan atau menyetujui System Manager. Suffix baru dialokasikan pada approval. Pembuatan akun satu per satu lewat form manual mempertahankan alur yang sudah ada.

Retry atas request yang sama mengembalikan akun dan status yang sama; tidak mengganti PIN atau membuat duplikat. Baris yang sudah diajukan dilewati saat retry. PIN hanya dikirim ke Supabase Auth, tidak disimpan dalam proposal, audit log, atau preview.

## Verifikasi

- 75 regression test Node lulus.
- 71 assertion database lulus, termasuk 34 assertion registrasi lama dan 37 assertion upload/approval. Fixture di-rollback.
- 21 assertion HTTP lulus, termasuk dua request create bersamaan, login Pending, approval, area setelah approval, retry, dan PIN gate. Semua fixture HTTP dibersihkan.
- Build dan pemeriksaan struktur/JavaScript lulus.
- Migration 20261153010000 dan rc-admin versi 5 telah diterapkan di Supabase.
- Frontend tersedia di localhost; belum dipublikasikan ulang ke Vercel.

Reproduksi:

~~~powershell
npm test
npm run check
npm run test:user-upload:db
npm run test:user-upload:http
~~~

Bukti terstruktur tersimpan pada [verification-2026-09-24.json](audit/verification-2026-09-24.json).
