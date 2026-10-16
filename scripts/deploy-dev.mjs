/*
 * MENERBITKAN LINGKUNGAN DEV KE VERCEL
 *
 * Dijalankan lewat `npm run deploy:dev`, yang lebih dulu membangun ulang halaman dengan
 * config/rc-env.dev.js.
 *
 * Project Vercel tujuan DITENTUKAN lewat variabel lingkungan VERCEL_PROJECT_ID, bukan lewat
 * .vercel/project.json yang tertaut ke produksi. Dengan begitu tautan produksi tidak perlu
 * diputus, dan tidak ada keadaan di tengah jalan di mana `npm run deploy` justru mengirim ke
 * project yang salah.
 *
 * Sebelum mengirim, berkas config yang BENAR-BENAR ada di hasil build diperiksa. Satu build
 * produksi yang tertinggal di public/ akan membuat situs dev berbicara ke database sungguhan -
 * dan itu tidak akan terlihat sampai ada yang menekan tombol di sana.
 */
import { readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const daftarEnv = JSON.parse(
  await readFile(path.join(root, 'config', 'environments.json'), 'utf8'));
const dev = daftarEnv.supabase_projects?.dev;
const prod = daftarEnv.supabase_projects?.prod;

if (!dev?.project_ref) {
  console.error('\n  Lingkungan dev belum punya project Supabase.\n');
  process.exit(1);
}

// ---- Penjaga: yang akan dikirim harus benar-benar menunjuk dev ---------------------------
const terbangun = await readFile(path.join(root, 'public', 'assets', 'rc-env.js'), 'utf8');
if (!terbangun.includes(dev.project_ref)) {
  console.error('\n  DITOLAK: public/assets/rc-env.js tidak menunjuk project dev.');
  console.error('  Jalankan `npm run deploy:dev` (yang membangun ulang lebih dulu),');
  console.error('  bukan skrip ini sendirian.\n');
  process.exit(1);
}
if (prod?.project_ref && terbangun.includes(prod.project_ref)) {
  console.error('\n  DITOLAK: hasil build masih memuat project produksi.\n');
  process.exit(1);
}

const PROJECT_ID = 'prj_ltzf1IcU05uKaIkzcke1q0mmSXOt';   // niel17/resource-collection-dev
const ORG_ID = 'team_ZFTXro4rqBcBvjQvzlTSmQSD';          // tim niel17

console.log('\n  MENERBITKAN DEV');
console.log('  vercel   : ' + (dev.vercel_project || '-'));
console.log('  supabase : ' + dev.project_ref);
console.log('  data     : ' + (dev.data || '-') + '\n');

const anak = spawn('npx', ['--yes', 'vercel@latest', 'deploy', '--prod', '--yes'], {
  cwd: root,
  stdio: 'inherit',
  shell: true,
  env: { ...process.env, VERCEL_PROJECT_ID: PROJECT_ID, VERCEL_ORG_ID: ORG_ID },
});
anak.on('exit', (kode) => process.exit(kode ?? 1));
