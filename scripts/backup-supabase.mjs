/*
 * Backup database DEV sebelum reset auth.
 *
 * Dibuat karena menyusun connection string sendiri mudah salah: tanda kurung placeholder
 * ikut tersalin, dan karakter seperti # atau @ di dalam password merusak URL. Skrip ini
 * meminta password lewat input tersembunyi, meng-encode sendiri, lalu mencoba koneksi
 * langsung dan beralih ke pooler bila jaringan hanya IPv4.
 *
 * Password tidak pernah muncul di layar, di argumen perintah, atau di riwayat PowerShell.
 *
 * Jalankan: npm run backup
 */
import { spawn } from 'node:child_process';
import readline from 'node:readline';
import { stdin, stdout } from 'node:process';
import path from 'node:path';

const PROJECT_REF = 'vvojshgcduqlugngpzkj';
const DIRECT_HOST = `db.${PROJECT_REF}.supabase.co`;

function ask(question) {
  const rl = readline.createInterface({ input: stdin, output: stdout });
  return new Promise((resolve) => rl.question(question, (a) => { rl.close(); resolve(a.trim()); }));
}

// Membaca password tanpa menampilkannya.
function askSecret(question) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: stdin, output: stdout, terminal: true });
    const onData = (char) => {
      if (['\n', '\r', ''].includes(char.toString())) stdin.removeListener('data', onData);
      else stdout.write('\x1b[2K\x1b[200D' + question + '*'.repeat(rl.line.length));
    };
    stdout.write(question);
    stdin.on('data', onData);
    rl.question('', (answer) => { rl.close(); stdout.write('\n'); resolve(answer); });
  });
}

function run(args, label) {
  return new Promise((resolve) => {
    console.log(`\n  ${label}...`);
    const child = spawn(process.platform === 'win32' ? 'npx.cmd' : 'npx', args,
      { stdio: ['ignore', 'inherit', 'pipe'], shell: false });
    let err = '';
    child.stderr.on('data', (c) => { err += c.toString(); stdout.write(c); });
    child.on('exit', (code) => resolve({ code, err }));
    child.on('error', (e) => resolve({ code: 1, err: e.message }));
  });
}

console.log('\n  Backup Supabase DEV ' + PROJECT_REF);
console.log('  Ambil password di Dashboard -> Project Settings -> Database.');
console.log('  Tempel apa adanya. Jangan sertakan tanda < >.\n');

const password = await askSecret('  Password database: ');
if (!password) {
  console.error('\n  Password kosong. Dibatalkan.');
  process.exit(1);
}
if (password.startsWith('<') || password.endsWith('>')) {
  console.error('\n  Password masih memuat tanda < atau >. Itu penanda contoh, bukan bagian password.');
  process.exit(1);
}

// encodeURIComponent menangani # @ / : dan karakter lain yang merusak URL.
const safe = encodeURIComponent(password);
const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
const outFile = path.join(process.cwd(), `backup-sebelum-reset-${stamp}.sql`);

const direct = `postgresql://postgres:${safe}@${DIRECT_HOST}:5432/postgres`;
let result = await run(['--yes', 'supabase@latest', 'db', 'dump', '--db-url', direct, '-f', outFile],
  'Mencoba koneksi langsung');

if (result.code !== 0) {
  const looksLikeNetwork = /unreachable|timeout|refused|no such host|dial|i\/o timeout|connect/i.test(result.err);
  if (!looksLikeNetwork) {
    console.error('\n  Gagal. Kalau pesannya soal autentikasi, password salah atau sudah di-reset.');
    process.exit(1);
  }
  console.log('\n  Koneksi langsung tidak tersambung. Host itu hanya IPv6, dan banyak');
  console.log('  jaringan di Indonesia masih IPv4. Beralih ke pooler.');
  console.log('  Ambil region di Dashboard -> Connect -> Session pooler, contoh: ap-southeast-1\n');
  const region = await ask('  Region pooler: ');
  if (!region) { console.error('  Region kosong. Dibatalkan.'); process.exit(1); }
  const pooled = `postgresql://postgres.${PROJECT_REF}:${safe}@aws-0-${region}.pooler.supabase.com:5432/postgres`;
  result = await run(['--yes', 'supabase@latest', 'db', 'dump', '--db-url', pooled, '-f', outFile],
    'Mencoba lewat pooler');
}

if (result.code !== 0) {
  console.error('\n  Backup gagal. Jangan lanjut ke reset auth.');
  process.exit(1);
}

console.log(`\n  Selesai: ${outFile}`);
console.log('  Pindahkan file ini ke luar folder project. Isinya data pelanggan.');
console.log('  Sesudah itu baru jalankan supabase/apply-pending.sql di SQL Editor.\n');
