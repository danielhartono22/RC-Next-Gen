/*
 * MEMASANG SKEMA KE LINGKUNGAN DEV
 *
 * Memutar ulang seluruh migrasi ke project dev yang masih kosong, berurutan menurut nama
 * berkas. Kemajuannya dicatat di tabel public._migrasi_dev pada database tujuan - bukan di
 * berkas lokal - supaya "sudah sampai mana" selalu dibaca dari kenyataan, bukan dari catatan
 * yang bisa basi.
 *
 * Sebagian migrasi memuat blok pemeriksaan yang membaca data (memilih satu klaim, satu
 * campaign). Pada database kosong blok itu bisa berhenti. Karena itu berkas ini BERHENTI pada
 * kegagalan pertama dan mencetak sebabnya, alih-alih menerjang terus dan meninggalkan skema
 * setengah jadi yang lebih sulit ditelusuri daripada kegagalan yang jujur.
 *
 *   node scripts/siapkan-dev.mjs --env dev             pasang, berhenti bila gagal
 *   node scripts/siapkan-dev.mjs --env dev --lewati    lewati yang gagal, laporkan di akhir
 *   node scripts/siapkan-dev.mjs --env dev --survei    hanya melihat: apa yang sudah terpasang
 *
 * Menolak jalan terhadap prod. Skema produksi dibangun oleh migrasi yang sama, tetapi
 * memasangnya ulang di sana tidak pernah menjadi maksud berkas ini.
 */
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function arg(nama, bawaan = null) {
  const i = process.argv.indexOf(nama);
  return i >= 0 ? process.argv[i + 1] : bawaan;
}
const namaEnv = arg('--env', 'dev');
const lewati = process.argv.includes('--lewati');
const survei = process.argv.includes('--survei');
// --sampai <awalan>: berhenti SEBELUM berkas yang namanya >= awalan itu. Dipakai untuk
// membangun skema sampai titik tertentu, lalu menerapkan sisanya dengan cara lain.
const sampai = arg('--sampai', null);

if (namaEnv === 'prod') {
  console.error('\n  DITOLAK: berkas ini tidak untuk prod.\n');
  process.exit(1);
}

const daftarEnv = JSON.parse(
  await readFile(path.join(root, 'config', 'environments.json'), 'utf8'));
const env = daftarEnv.supabase_projects?.[namaEnv];
if (!env?.project_ref) {
  console.error(`\n  Lingkungan "${namaEnv}" belum punya project_ref.\n`);
  process.exit(1);
}
if (env.project_ref === daftarEnv.supabase_projects?.prod?.project_ref) {
  console.error('\n  DITOLAK: project_ref tujuan sama dengan produksi.\n');
  process.exit(1);
}

const namaVar = env.token_env || 'SUPABASE_ACCESS_TOKEN_DEV';
let token = process.env[namaVar] || null;
if (!token) {
  try {
    const isi = await readFile(path.join(root, '.env'), 'utf8');
    for (const line of isi.split(/\r?\n/)) {
      const m = line.match(new RegExp('^\\s*' + namaVar + '\\s*=\\s*(.+?)\\s*$'));
      if (m) token = m[1].replace(/^["']|["']$/g, '');
    }
  } catch { /* .env belum ada */ }
}
if (!token) {
  console.error(`\n  ${namaVar} belum tersedia di .env.\n`);
  process.exit(1);
}

const API = `https://api.supabase.com/v1/projects/${env.project_ref}/database/query`;

async function jalankan(sql) {
  const res = await fetch(API, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const teks = await res.text();
  if (!res.ok) {
    let pesan = teks;
    try { pesan = JSON.parse(teks).message || teks; } catch { /* biarkan apa adanya */ }
    throw new Error(pesan.replace(/\s+/g, ' ').slice(0, 260));
  }
  try { return JSON.parse(teks); } catch { return []; }
}

// ------------------------------------------------------------------------------------------
console.log('\n  MEMASANG SKEMA');
console.log('  lingkungan : ' + namaEnv.toUpperCase());
console.log('  project    : ' + env.project_ref);

await jalankan(`
  create table if not exists public._migrasi_dev(
    berkas text primary key,
    dipasang_pada timestamptz not null default now(),
    catatan text not null default ''
  );`);

const semua = (await readdir(path.join(root, 'supabase', 'migrations')))
  .filter(f => f.endsWith('.sql')).sort()
  .filter(f => !sampai || f < sampai);
const sudah = new Set((await jalankan('select berkas from public._migrasi_dev;'))
  .map(r => r.berkas));

console.log(`  migrasi    : ${semua.length} berkas, ${sudah.size} sudah terpasang\n`);

if (survei) {
  const belum = semua.filter(f => !sudah.has(f));
  console.log('  Belum terpasang: ' + belum.length);
  belum.slice(0, 20).forEach(f => console.log('    - ' + f));
  if (belum.length > 20) console.log(`    … dan ${belum.length - 20} lagi`);
  console.log('');
  process.exit(0);
}

let ok = 0;
const gagal = [];

for (const berkas of semua) {
  if (sudah.has(berkas)) continue;
  const sql = await readFile(path.join(root, 'supabase', 'migrations', berkas), 'utf8');
  const pendek = berkas.replace(/^\d+_/, '').replace(/\.sql$/, '');
  process.stdout.write(`  ${String(ok + gagal.length + 1).padStart(3)}. ${pendek.slice(0, 54).padEnd(56)}`);
  try {
    await jalankan(sql);
    await jalankan(
      `insert into public._migrasi_dev(berkas) values ('${berkas.replace(/'/g, "''")}')
       on conflict (berkas) do nothing;`);
    ok++;
    console.log('ok');
  } catch (e) {
    console.log('GAGAL');
    console.log(`       ${e.message}`);
    gagal.push({ berkas, pesan: e.message });
    if (!lewati) {
      console.log(`\n  Berhenti di ${berkas}.`);
      console.log('  Perbaiki, lalu jalankan ulang - yang sudah terpasang tidak diulang.');
      console.log('  Atau pakai --lewati untuk melihat seluruh kegagalan sekaligus.\n');
      process.exit(1);
    }
  }
}

console.log(`\n  Terpasang: ${ok}   Gagal: ${gagal.length}`);
if (gagal.length) {
  console.log('\n  Yang gagal:');
  gagal.forEach(g => console.log(`    - ${g.berkas}\n      ${g.pesan}`));
  console.log('');
  process.exit(1);
}
console.log('');
