# Status RC DEV — 16 September 2026

## Implementasi yang sudah tercatat diterapkan

Berdasarkan hasil MCP sesi 15 September (belum diverifikasi ulang hari ini): tabel `claims` berisi 2.756 claim dengan total cashback net 10.932.331.199,25. Nilai AK historis kosong tetap NULL. Tanggal historis yang belum dinormalisasi disimpan pada `legacy_dates`; belum dianggap tanggal transaksi kanonis.

Migration remote yang telah dikonfirmasi:

| Versi | Nama |
|---|---|
| 20260915071444 | rc_claims_core |
| 20260915071632 | rc_workflow |
| 20260915071746 | rc_access_profiles |
| 20260915071855 | rc_workflow_result_fix |

Nama file lokal kini diselaraskan dengan versi remote tersebut. Fungsi meliputi workflow transaksi, idempotency key, optimistic version check, batch, history, log, analytics status, detail sensitif berizin, perubahan alamat depot dan pengelolaan akses. Edge Function `rc-admin` versi 1 tercatat ACTIVE dengan JWT verification untuk pembuatan akun.

Frontend DEV: `rc-supabase.html` + `scripts/rc-app.mjs`. `index (4).html` tetap frontend legacy sampai kesetaraan fungsi dan UAT selesai. Document Center tetap ditunda.

## Hasil uji yang benar-benar tersedia

- SQL `rc_workflow.sql` lewat MCP: PASS submit/release/claim/clearing, gross-up, retry idempotent, stale version, lintas depot, rollback seluruh batch, hold/unhold/expired, dan history. Fixture di-rollback.
- SQL akses master serta gate perubahan password: PASS pada sesi sebelumnya.
- HTTP `test_rc_http.py`: PASS login native memakai password lama, profile gate, penolakan workflow sebelum perubahan password; logout HTTP 204. Password akun nyata tidak diubah oleh test ini.
- JavaScript syntax checks: PASS untuk modul frontend.
- 16 September: `node --test scripts/test_rc_client.mjs`: 9 PASS untuk CSV, leading zero, kutipan, angka, tanggal, limit, duplikasi, dan pencegahan formula CSV.

## Yang belum dapat dinyatakan lulus

Proses `test_rc_e2e_http.py` terakhir berjalan dengan session ID 55110, tetapi sesi proses tidak lagi tersedia saat dilanjutkan. Hasil akhirnya **UNKNOWN**, bukan PASS. Test ini mencakup perubahan password akun sintetis, retry serentak dan konflik versi. Akun/data fixture mungkin masih tersimpan. Gunakan `rc_e2e_fixture_inventory.sql` untuk memeriksa, lalu cleanup yang dibatasi ke satu kode fixture terverifikasi.

Browser automation sebelumnya mengembalikan `No browser is available`; visual QA dan pengujian klik belum selesai.

Pada sesi 16 September, tool MCP Supabase tidak tersedia dalam daftar tool maupun resource server. Karena itu tidak ada perubahan remote yang dilakukan pada sesi ini; tidak ada akun uji yang diklaim telah dibersihkan.

## Perubahan lokal 16 September

- Posting massal CSV untuk dokumen RC yang sudah ada, maksimal 100 item. Preview membaca versi/status terkini melalui RLS; commit tetap divalidasi ulang server. Tidak membuat dokumen baru atau mengakses DC.
- Password login dikirim apa adanya, bukan dipangkas; perubahan password dapat mengandung spasi.
- Validasi CSV, kalender, nilai finansial, ukuran file dan header; leading zero identitas tetap teks.
- Tombol yang semula disabled tidak lagi otomatis diaktifkan oleh handler global; pengiriman ganda saat request berlangsung ditahan.
- Ekspor CSV menetralkan formula termasuk awalan whitespace.
- Migration `20260916010000_rc_transaction_input_validation.sql` **PENDING**, belum diterapkan/diuji PostgreSQL. Membatasi payload, tipe field, tanggal ISO, bulan tagih, dan urutan periode serta menutup entry point internal tanpa validasi.

## Urutan setelah MCP kembali tersedia

1. Verifikasi project DEV, migration history dan fixture sintetis yang tersisa.
2. Periksa lalu bersihkan fixture test terdahulu dengan exact code; jangan menghapus data bisnis.
3. Terapkan migration input validation dan jalankan `rc_input_validation.sql` serta ulangi workflow tests.
4. Jalankan ulang HTTP E2E dengan fixture baru, simpan hasil dan cleanup dalam alur try/finally yang terverifikasi.
5. Uji Edge Function pembuatan akun dan RPC review profil/akses termasuk penolakan non-manager.
6. Lakukan visual/browser UAT; baru setelah itu pertimbangkan mengalihkan entry point legacy.

Pekerjaan keseluruhan belum selesai: format tanggal historis, kesetaraan import/ekspor Excel legacy, detail profil depot selain alamat/link/nama, recovery akun internal, kelengkapan scope depot, pengujian browser dan cutover masih perlu dituntaskan. Jangan menyebut sistem siap produksi dari hasil unit test ini.
