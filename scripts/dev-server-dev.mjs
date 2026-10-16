/*
 * SERVER LOKAL YANG MENUNJUK LINGKUNGAN DEV
 *
 * scripts/dev-server.mjs membangun ulang halaman setiap kali berkas sumber berubah, dan
 * bawaannya adalah config PRODUKSI. Menjalankannya begitu saja berarti localhost berbicara ke
 * database sungguhan - tombol yang ditekan saat mencoba akan mengubah data orang.
 *
 * Berkas ini menyetel RC_ENV_TARGET sebelum server dimuat, sehingga build pertama maupun
 * seluruh build ulang otomatis memakai config/rc-env.dev.js.
 *
 * Jalankan: npm run dev:dev
 */
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

process.env.RC_ENV_TARGET = 'dev';

// Dibacakan sebelum server hidup. Yang paling mudah keliru saat mencoba adalah lupa sedang
// menunjuk database yang mana, dan itu baru ketahuan setelah ada yang berubah.
const daftar = JSON.parse(await readFile(path.join(root, 'config', 'environments.json'), 'utf8'));
const dev = daftar.supabase_projects?.dev;
const prod = daftar.supabase_projects?.prod;

const cfg = await readFile(path.join(root, 'config', 'rc-env.dev.js'), 'utf8');
if (prod?.project_ref && cfg.includes(prod.project_ref)) {
  console.error('\n  DITOLAK: config/rc-env.dev.js menunjuk project produksi.\n');
  process.exit(1);
}

console.log('\n  \x1b[43m\x1b[30m  LINGKUNGAN DEV  \x1b[0m  data rekayasa, bukan data sungguhan');
console.log('  supabase : ' + (dev?.project_ref || '-'));
console.log('  login    : User ID SMDEV');

await import('./dev-server.mjs');
