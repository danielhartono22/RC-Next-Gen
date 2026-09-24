/*
 * Mengambil refresh token Gmail tanpa OAuth Playground.
 *
 * MENGAPA ADA SKRIP INI
 * Jalur Playground menuntut alamat https://developers.google.com/oauthplayground didaftarkan
 * sebagai Authorized redirect URI pada OAuth client. Di situlah hampir seluruh kegagalan
 * terjadi: satu garis miring berlebih, perubahan yang belum menyebar, kredensial yang basi di
 * sesi browser, semuanya muncul sebagai pesan galat yang mirip satu sama lain.
 *
 * Skrip ini memakai OAuth client tipe Desktop, yang oleh Google diizinkan memakai alamat
 * loopback http://127.0.0.1:<port> TANPA perlu didaftarkan sama sekali. Tidak ada redirect URI
 * yang bisa salah ketik, dan tidak ada halaman pihak ketiga yang menyimpan kredensial Anda.
 *
 * Skrip meminta prompt=consent secara eksplisit, sehingga Google selalu menerbitkan refresh
 * token baru - termasuk bila akun itu sudah pernah memberi izin sebelumnya. Itu menghilangkan
 * jebakan "kolom Refresh token kosong" yang biasanya menuntut pencabutan izin manual lebih dulu.
 *
 * Client Secret hanya dipakai untuk satu penukaran token ke Google dan tidak pernah ditulis ke
 * berkas mana pun oleh skrip ini.
 *
 * Jalankan: node scripts/gmail-refresh-token.mjs [client-id]
 *           Client ID boleh ikut di baris perintah; Client Secret selalu diketik,
 *           supaya tidak tersimpan di riwayat shell.
 */
import http from 'node:http';
import crypto from 'node:crypto';
import readline from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import { spawn } from 'node:child_process';

// Dua izin, dipisah spasi sesuai ketentuan OAuth2.
//
//   gmail.send  mengirim email. Tidak dapat membaca, menghapus, atau melihat kotak masuk.
//   drive.file  membuat dan membaca berkas YANG DIBUAT APLIKASI INI SENDIRI - dipakai untuk
//               mengubah HTML laporan menjadi PDF lewat konverter Google, persis seperti yang
//               dilakukan Apps Script dulu lewat Utilities.newBlob(...).getAs(MimeType.PDF).
//
// drive.file sengaja dipilih, bukan drive atau drive.readonly: ia TIDAK memberi akses ke berkas
// lain di Drive Anda. Aplikasi hanya melihat berkas yang ia buat sendiri, dan berkas sementara
// itu dihapus lagi begitu PDF-nya jadi.
const SCOPE = [
  'https://www.googleapis.com/auth/gmail.send',
  'https://www.googleapis.com/auth/drive.file'
].join(' ');

function base64url(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

console.log('\n  Mengambil refresh token Gmail untuk RC.');
console.log('  Dari OAuth client bertipe \x1b[1mDesktop app\x1b[0m; tipe itu tidak');
console.log('  memerlukan Authorized redirect URI sama sekali.\n');

// Client ID boleh diberikan lewat argumen karena ia memang bukan rahasia: Google menanamkannya
// di dalam aplikasi terpasang. Client Secret sengaja TIDAK diterima lewat argumen maupun
// variabel lingkungan, supaya ia tidak ikut tercatat di riwayat perintah shell.
const argId = process.argv[2] && process.argv[2].trim();
const rl = readline.createInterface({ input: stdin, output: stdout });

const clientId = argId || (await rl.question('  Client ID     : ')).trim();
if (argId) console.log('  Client ID     : ' + argId);
const clientSecret = (await rl.question('  Client Secret : ')).trim();
rl.close();

if (!clientId || !clientSecret) {
  console.error('\n  Keduanya wajib diisi. Berhenti tanpa melakukan apa pun.\n');
  process.exit(1);
}

// PKCE. Google menganjurkannya untuk aplikasi terpasang, dan ia membuat kode izin yang tercuri
// di tengah jalan tidak dapat ditukar oleh siapa pun selain proses ini.
const verifier = base64url(crypto.randomBytes(32));
const challenge = base64url(crypto.createHash('sha256').update(verifier).digest());
const state = base64url(crypto.randomBytes(16));

const server = http.createServer();
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const port = server.address().port;
const redirectUri = `http://127.0.0.1:${port}`;

const authUrl = 'https://accounts.google.com/o/oauth2/v2/auth?' + new URLSearchParams({
  client_id: clientId,
  redirect_uri: redirectUri,
  response_type: 'code',
  scope: SCOPE,
  access_type: 'offline',
  // Memaksa layar persetujuan tampil lagi, sehingga refresh token selalu diterbitkan.
  prompt: 'consent',
  state,
  code_challenge: challenge,
  code_challenge_method: 'S256'
}).toString();

console.log('\n  Buka alamat berikut di browser, lalu pilih akun yang akan menjadi pengirim:\n');
console.log('  ' + authUrl + '\n');
console.log('  Menunggu persetujuan... (Ctrl+C untuk batal)\n');

// Dibuka lewat rundll32, BUKAN lewat "cmd /c start".
//
// Ini bukan selera: pada cmd.exe karakter & adalah pemisah perintah, dan URL OAuth penuh
// dengan &. "start" memotong alamatnya tepat di & pertama, sehingga browser hanya menerima
// sampai client_id=... dan seluruh parameter sisanya - termasuk response_type - hilang.
// Google lalu menolak dengan "Error 400: invalid_request - Required parameter is missing:
// response_type", yang terlihat seperti kesalahan konfigurasi padahal sebenarnya alamatnya
// yang terpotong sebelum sampai ke browser.
//
// rundll32 menerima alamatnya sebagai satu argumen utuh tanpa melewati shell sama sekali.
try {
  spawn('rundll32', ['url.dll,FileProtocolHandler', authUrl], { detached: true, stdio: 'ignore' }).unref();
} catch {
  /* biarkan; alamat lengkapnya sudah tercetak di atas dan dapat disalin manual */
}

// Penjelasan kode galat Google, dipasangkan dengan tindakan yang benar-benar menyelesaikannya.
const ARTI = {
  org_internal: 'Layar persetujuan diset Internal, tetapi akun yang Anda pilih berada di luar organisasi.'
    + ' Keluar dari semua akun Google, lalu masuk dengan akun @bi-nipponpaint.com.',
  access_denied: 'Anda menekan Cancel, ATAU layar persetujuan diset External dan akun Anda belum'
    + ' terdaftar sebagai Test user. Ubah ke Internal, atau tambahkan akun Anda di OAuth consent screen > Test users.',
  admin_policy_enforced: 'Admin Google Workspace memblokir aplikasi pihak ketiga mengakses Gmail.'
    + ' Ini hanya bisa dibuka oleh admin lewat Admin Console > Security > API controls.',
  invalid_scope: 'Gmail API belum di-enable pada project itu. Buka APIs & Services > Library > Gmail API > Enable.',
  invalid_client: 'Client Secret salah, atau OAuth client sudah dihapus.',
  redirect_uri_mismatch: 'OAuth client bukan bertipe Desktop app. Buat ulang dengan Application type Desktop app.'
};

const code = await new Promise((resolve, reject) => {
  const batas = setTimeout(() => reject(new Error('Tidak ada persetujuan dalam 5 menit.')), 300000);
  server.on('request', (req, res) => {
    const url = new URL(req.url, redirectUri);
    const galat = url.searchParams.get('error');
    const kode = url.searchParams.get('code');
    const kembali = url.searchParams.get('state');

    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    if (galat) {
      // Google menaruh sebab sesungguhnya di error_description dan error_subtype, bukan di
      // kode error yang pendek itu. Keduanya ikut dicetak, karena kode seperti "access_denied"
      // saja tidak cukup untuk memutuskan apa yang harus diperbaiki.
      const uraian = url.searchParams.get('error_description') || '';
      const subtipe = url.searchParams.get('error_subtype') || '';
      res.end(`<h2>Gagal: ${galat}</h2><p>${uraian}</p><p>Kembali ke terminal.</p>`);
      clearTimeout(batas);
      reject(new Error(galat + (subtipe ? ' / ' + subtipe : '') + (uraian ? ' - ' + uraian : '')));
      return;
    }
    if (kembali !== state) {
      res.end('<h2>State tidak cocok</h2><p>Permintaan ditolak demi keamanan.</p>');
      clearTimeout(batas); reject(new Error('State tidak cocok; permintaan ditolak.')); return;
    }
    res.end('<h2>Berhasil</h2><p>Silakan tutup tab ini dan kembali ke terminal.</p>');
    clearTimeout(batas); resolve(kode);
  });
}).catch((e) => {
  const kunci = Object.keys(ARTI).find((k) => String(e.message).includes(k));
  console.error(`\n  \x1b[31mPersetujuan gagal.\x1b[0m ${e.message}`);
  if (kunci) console.error(`\n  ${ARTI[kunci]}`);
  else console.error(`\n  Kode ini tidak ada di daftar. Kirimkan teksnya apa adanya.`);
  console.error('');
  process.exit(1);
}).finally(() => server.close());

const res = await fetch('https://oauth2.googleapis.com/token', {
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({
    client_id: clientId,
    client_secret: clientSecret,
    code,
    code_verifier: verifier,
    grant_type: 'authorization_code',
    redirect_uri: redirectUri
  })
});
const data = await res.json();

if (!res.ok || !data.refresh_token) {
  console.error(`\n  \x1b[31mGagal menukar kode menjadi token.\x1b[0m HTTP ${res.status}`);
  console.error('  ' + JSON.stringify(data) + '\n');
  if (!data.refresh_token && res.ok) {
    console.error('  Google tidak menyertakan refresh token. Cabut izin aplikasi ini di');
    console.error('  https://myaccount.google.com/permissions lalu jalankan skrip ini lagi.\n');
  }
  process.exit(1);
}

console.log('\n  \x1b[32mBerhasil.\x1b[0m Refresh token Anda:\n');
console.log('  ' + data.refresh_token + '\n');
// Keempat rahasia SUDAH ADA di Vault sebagai placeholder sejak migration email dipasang, jadi
// vault.create_secret akan gagal karena namanya sudah terpakai. Yang dicetak di sini bentuk
// update_secret, yang menerima id dan bukan nama - karena itu id-nya dicari lebih dulu.
// Mencetak perintah yang pasti error hanya akan membuat orang mengira tokennya yang salah.
console.log('  Simpan ke Vault lewat SQL Editor Supabase (rahasianya sudah ada, jadi UPDATE):\n');
const perbarui = (nama, nilai) =>
  `  select vault.update_secret((select id from vault.secrets where name = '${nama}'), '${nilai}');`;
console.log(perbarui('rc_gmail_client_id', clientId));
console.log(perbarui('rc_gmail_client_secret', '<client secret Anda, diawali GOCSPX->'));
console.log(perbarui('rc_gmail_refresh_token', data.refresh_token));
console.log(perbarui('rc_email_from', 'RC Reporting <alamat.pengirim@bi-nipponpaint.com>'));
console.log('');
console.log('  Lalu periksa dengan: select public.rc_email_uji_koneksi();\n');
