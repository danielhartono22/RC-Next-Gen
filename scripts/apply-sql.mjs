/*
 * Menjalankan SQL ke project Supabase lewat Management API.
 *
 * Dibuat karena connector MCP pada sesi ini tidak memiliki izin atas project
 * vvojshgcduqlugngpzkj, sehingga setiap migration harus ditempel manual ke SQL Editor. Dengan
 * satu Personal Access Token, langkah itu hilang.
 *
 * CARA MEMBERI AKSES
 *   1. Supabase Dashboard -> pojok kanan atas -> Account -> Access Tokens -> Generate new token
 *   2. Salin tokennya, lalu buat berkas .env di folder project berisi satu baris:
 *        SUPABASE_ACCESS_TOKEN=sbp_xxxxxxxxxxxxxxxx
 *      .env sudah tercantum di .gitignore, jadi token tidak akan ikut ter-commit.
 *
 * PEMAKAIAN
 *   node scripts/apply-sql.mjs                          -> jalankan supabase/apply-pending.sql
 *   node scripts/apply-sql.mjs <berkas.sql>             -> jalankan berkas lain
 *   node scripts/apply-sql.mjs --check                  -> hanya uji koneksi dan izin
 *
 * Token ini setara kunci ke seluruh akun Supabase Anda. Ia hanya dibaca dari .env, tidak
 * pernah dicetak, dan tidak pernah dikirim ke mana pun selain api.supabase.com.
 */
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PROJECT_REF = 'vvojshgcduqlugngpzkj';
const API = `https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`;

async function bacaToken() {
  if (process.env.SUPABASE_ACCESS_TOKEN) return process.env.SUPABASE_ACCESS_TOKEN.trim();
  try {
    const env = await readFile(path.join(root, '.env'), 'utf8');
    for (const line of env.split(/\r?\n/)) {
      const m = line.match(/^\s*SUPABASE_ACCESS_TOKEN\s*=\s*(.+?)\s*$/);
      if (m) return m[1].replace(/^["']|["']$/g, '');
    }
  } catch { /* .env belum ada */ }
  return null;
}

const token = await bacaToken();
if (!token) {
  console.error('\n  SUPABASE_ACCESS_TOKEN belum tersedia.\n');
  console.error('  1. Supabase Dashboard -> Account -> Access Tokens -> Generate new token');
  console.error('  2. Buat berkas .env di folder project, isinya satu baris:');
  console.error('       SUPABASE_ACCESS_TOKEN=sbp_xxxxxxxxxxxx');
  console.error('  3. Jalankan ulang perintah ini.\n');
  console.error('  .env sudah di-gitignore, jadi token tidak akan ikut ter-commit.\n');
  process.exit(1);
}

async function jalankan(sql) {
  const res = await fetch(API, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql })
  });
  const teks = await res.text();
  let data;
  try { data = JSON.parse(teks); } catch { data = teks; }
  if (!res.ok) {
    const pesan = (data && (data.message || data.error)) || teks;
    throw new Error(`HTTP ${res.status}: ${pesan}`);
  }
  return data;
}

if (process.argv.includes('--check')) {
  try {
    const hasil = await jalankan(
      "select current_database() as db, current_user as pengguna, " +
      "(select count(*) from public.claims) as claims, " +
      "(select count(*) from public.profiles) as profil");
    console.log('\n  \x1b[32mKoneksi berhasil.\x1b[0m');
    console.log('  ' + JSON.stringify(hasil) + '\n');
  } catch (e) {
    console.error(`\n  \x1b[31mGagal:\x1b[0m ${e.message}\n`);
    console.error('  Bila pesannya soal izin, token itu milik akun yang tidak memegang');
    console.error(`  project ${PROJECT_REF}. Buat token dari akun pemilik project tersebut.\n`);
    process.exitCode = 1;
  }
} else {
  const berkas = process.argv[2] || path.join(root, 'supabase', 'apply-pending.sql');
  const sql = await readFile(berkas, 'utf8');
  console.log(`\n  Menjalankan ${path.relative(root, berkas)} (${sql.length} karakter) ke ${PROJECT_REF}...`);
  try {
    const hasil = await jalankan(sql);
    console.log('  \x1b[32mBerhasil.\x1b[0m');
    // Berkas bundle diakhiri satu select ringkasan. Berkas uji sering diakhiri rollback,
    // sehingga baris terakhir kosong dan yang menarik justru ada sebelumnya. Karena itu
    // setiap baris yang berisi sesuatu ditampilkan, bukan hanya yang terakhir.
    if (Array.isArray(hasil)) {
      const berisi = hasil.filter((r) => r && Object.keys(r).length > 0);
      for (const r of berisi.length ? berisi : hasil.slice(-1)) console.log('  ' + JSON.stringify(r));
    } else if (hasil) {
      console.log('  ' + JSON.stringify(hasil));
    }
    console.log('');
  } catch (e) {
    console.error(`  \x1b[31mGagal:\x1b[0m ${e.message}\n`);
    console.error('  Tidak ada yang tersimpan: seluruh berkas berjalan dalam satu transaksi.\n');
    process.exitCode = 1;
  }
}
