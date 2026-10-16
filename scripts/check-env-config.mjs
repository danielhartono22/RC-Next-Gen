/*
 * PEMERIKSAAN KONFIGURASI BROWSER
 *
 * config/rc-env.js disalin apa adanya menjadi public/assets/rc-env.js, lalu dijalankan peramban
 * sebelum apa pun yang lain. Kalau berkas itu gagal DIJALANKAN, window.RC_ENV tidak pernah
 * terbentuk dan seluruh aplikasi berhenti di "Konfigurasi Supabase belum diisi." - tanpa satu pun
 * pemeriksaan lain mengeluh.
 *
 * Itu persis yang terjadi: satu kata liar ("ampil") tersisip di awal berkas. Secara TATA BAHASA
 * berkas itu sah - `ampil` adalah ekspresi identifier yang valid - sehingga `node --check` lolos,
 * `npm run check` hijau seluruhnya, dan build pun sukses. Yang gagal hanya saat DIJALANKAN:
 * ReferenceError menghentikan skrip sebelum baris `window.RC_ENV = {...}` sempat dieksekusi.
 *
 * Pelajarannya sama seperti pada pemeriksaan migrasi yang dulu memeriksa sifat yang keliru:
 * memeriksa bahwa berkas dapat DIURAI tidak sama dengan memeriksa bahwa ia MENGERJAKAN tugasnya.
 * Karena itu pemeriksaan di bawah benar-benar menjalankan berkasnya dan menuntut hasilnya, bukan
 * sekadar membaca isinya.
 *
 * Dijalankan sebagai bagian dari `npm run check`.
 */
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temuan = [];

// Keduanya diperiksa: sumbernya, dan hasil build yang benar-benar disajikan ke peramban.
// Hasil build bisa tertinggal basi, dan yang menentukan nasib pengguna adalah yang disajikan.
const SASARAN = [
  ['config/rc-env.js', true],
  ['public/assets/rc-env.js', false]   // belum tentu ada bila build belum pernah dijalankan
];

for (const [rel, wajibAda] of SASARAN) {
  let src;
  try {
    src = await readFile(path.join(root, rel), 'utf8');
  } catch (e) {
    if (wajibAda) temuan.push(`${rel}: tidak dapat dibaca -> ${e.message}`);
    continue;
  }

  // Dijalankan di dalam kurungan tanpa akses apa pun selain objek window tiruan. Berkas ini
  // memang hanya boleh menyentuh window - kalau ia menyentuh yang lain, di peramban pun gagal.
  const jendela = {};
  try {
    new Function('window', src)(jendela);
  } catch (e) {
    temuan.push(`${rel}: GAGAL DIJALANKAN -> ${e.name}: ${e.message}`);
    continue;
  }

  const env = jendela.RC_ENV;
  if (!env || typeof env !== 'object') {
    temuan.push(`${rel}: dijalankan tanpa galat, tetapi window.RC_ENV tidak terbentuk.`);
    continue;
  }

  for (const kunci of ['supabaseUrl', 'supabasePublishableKey']) {
    if (!env[kunci] || typeof env[kunci] !== 'string' || !env[kunci].trim()) {
      temuan.push(`${rel}: ${kunci} kosong - login akan menolak dengan "Konfigurasi Supabase belum diisi."`);
    }
  }

  if (env.supabaseUrl && !/^https:\/\/[a-z0-9]+\.supabase\.co\/?$/.test(String(env.supabaseUrl).trim())) {
    temuan.push(`${rel}: supabaseUrl tidak berbentuk URL project Supabase -> ${env.supabaseUrl}`);
  }

  // Kunci rahasia di berkas ini akan terbaca setiap pengunjung. Publishable/anon saja yang boleh.
  const kunci = String(env.supabasePublishableKey || '');
  if (/^sb_secret_/.test(kunci) || /service_role/.test(kunci)) {
    temuan.push(`${rel}: memuat kunci RAHASIA. Berkas ini disajikan ke publik - hanya publishable/anon yang boleh.`);
  }

  if (env.dataBackend && !['supabase', 'apps_script'].includes(env.dataBackend)) {
    temuan.push(`${rel}: dataBackend '${env.dataBackend}' tidak dikenal (hanya 'supabase' atau 'apps_script').`);
  }
}

console.log('\n  PEMERIKSAAN KONFIGURASI BROWSER');
if (temuan.length) {
  console.log('\n\x1b[31m  Ditemukan ' + temuan.length + ' masalah:\x1b[0m');
  temuan.forEach(t => console.log('   - ' + t));
  console.log('\n  Aplikasi TIDAK akan bisa login sampai ini diperbaiki.\n');
  process.exit(1);
}
console.log('  rc-env.js dapat dijalankan dan menghasilkan RC_ENV yang terpakai.');
console.log('\n\x1b[32m  Tidak ada temuan.\x1b[0m\n');
