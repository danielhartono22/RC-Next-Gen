/*
 * Memeriksa kondisi nyata project Supabase dan memberitahu langkah berikutnya.
 *
 * Dibuat supaya pertanyaan "kenapa tidak bisa login" dijawab dengan fakta, bukan tebakan.
 * Hanya membaca. Tidak ada yang diubah, dan tidak memerlukan kredensial rahasia.
 *
 * Jalankan: npm run diagnose
 *           npm run diagnose -- --user DHARTONO      (uji alamat login yang diturunkan)
 */
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { webcrypto } from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const env = await readFile(path.join(root, 'config', 'rc-env.js'), 'utf8');
const URL_ = env.match(/supabaseUrl:\s*'([^']+)'/)?.[1];
const KEY = env.match(/supabasePublishableKey:\s*'([^']+)'/)?.[1];
if (!URL_ || !KEY) { console.error('config/rc-env.js tidak memuat url atau publishable key.'); process.exit(1); }

const ok = (s) => `\x1b[32m${s}\x1b[0m`;
const bad = (s) => `\x1b[31m${s}\x1b[0m`;
const todo = [];

console.log(`\n  Project: ${URL_}\n`);

// 1. Fungsi mana yang sudah ada. 404 berarti belum, 401 berarti ada tapi butuh login.
//
// PostgREST memilih fungsi berdasarkan NAMA argumen yang dikirim. Mengirim {} ke fungsi
// yang punya argumen wajib menghasilkan 404 walaupun fungsinya ada, karena tidak ada
// kandidat yang cocok. Jadi setiap fungsi harus diprobe dengan argumen yang benar.
// Nilainya tidak pernah dieksekusi: anon tidak punya hak EXECUTE, sehingga PostgreSQL
// menolak lebih dulu dan tidak ada data yang tersentuh.
const FUNCTIONS = [
  ['rc_list_claims', {}, 'workflow inti', '20260915071632'],
  ['rc_legacy_bootstrap', {}, 'compat API untuk UI lama', '20260917010000'],
  ['rc_review_request', { p_id: 'probe', p_approve: false }, 'reset auth dan portal pendaftaran', '20260917020000'],
  ['rc_customer_list', {}, 'Key Master dan Cashback Compilation', '20260918010000'],
  ['rc_open_claims', {}, 'alur workflow dan syarat upload', '20260919010000'],
  ['rc_compile_preview', { p_rows: [] }, 'compile cashback dari Excel', '20260920010000'],
  ['rc_public_depots', {}, 'perbaikan Kelola Akses, peran, depot pendaftaran', '20260921010000'],
  ['rc_compilation_list', {}, 'tanggal proses, tab Open, pagination compilation', '20260922010000'],
  ['rc_campaign_list', {}, 'Jenis CB Voucher dan Abbr depot', '20260923010000']
];
console.log('  Migration');
for (const [fn, args, label, version] of FUNCTIONS) {
  const res = await fetch(`${URL_}/rest/v1/rpc/${fn}`, {
    method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify(args)
  });
  const exists = res.status !== 404;
  console.log(`    ${exists ? ok('sudah') : bad('BELUM')}  ${label}  (${version})`);
  if (!exists) todo.push(`Jalankan migration ${version} lewat supabase/apply-pending.sql di SQL Editor.`);
}

// 2. Setting Auth yang menentukan apakah pendaftaran bisa dipakai.
const settings = await (await fetch(`${URL_}/auth/v1/settings`, { headers: { apikey: KEY } })).json();
console.log('\n  Pengaturan Auth');
const signupOn = settings.disable_signup === false;
console.log(`    ${signupOn ? ok('benar') : bad('SALAH')}  pendaftaran mandiri ${signupOn ? 'diizinkan' : 'dinonaktifkan'}`);
if (!signupOn) todo.push('Nyalakan "Allow new users to sign up" di Authentication -> Sign In / Providers.');

const autoconfirm = settings.mailer_autoconfirm === true;
console.log(`    ${autoconfirm ? ok('benar') : bad('SALAH')}  konfirmasi email ${autoconfirm ? 'mati' : 'MASIH MENYALA'}`);
if (!autoconfirm) {
  todo.push('Matikan "Confirm email" di Authentication -> Sign In / Providers -> Email. ' +
    'Alamat login berakhiran .invalid tidak bisa menerima email, sehingga akun baru tidak akan pernah bisa login.');
}

// 3. Alamat login yang diturunkan, untuk mencocokkan dengan isi tabel auth.users.
const userArg = process.argv.indexOf('--user');
if (userArg >= 0 && process.argv[userArg + 1]) {
  const code = process.argv[userArg + 1].trim();
  const digest = await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(code));
  const hex = Buffer.from(digest).toString('hex');
  console.log(`\n  Alamat login untuk User ID "${code}"`);
  console.log(`    ${hex}@rc-login.invalid`);
  console.log('    Cocokkan dengan Dashboard -> Authentication -> Users.');
}

console.log('\n  Langkah berikutnya');
if (todo.length === 0) {
  console.log(`    ${ok('Semua siap.')} Buka portal, klik Daftar. Pendaftar pertama menjadi System Manager.`);
} else {
  todo.forEach((t, i) => console.log(`    ${i + 1}. ${t}`));
}
console.log('');
