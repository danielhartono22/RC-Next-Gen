/*
 * Pemeriksaan statis untuk bundle SQL sebelum ditempel ke SQL Editor.
 *
 * Tidak menjalankan PostgreSQL. Yang diperiksa adalah kesalahan yang paling sering membuat
 * satu berkas besar gagal di tengah jalan, dan yang pesan errornya sering menyesatkan:
 *
 *  1. Fungsi yang dipanggil tetapi tidak pernah dibuat, baik di bundle maupun di migration
 *     yang sudah diterapkan sebelumnya.
 *  2. DROP FUNCTION terhadap tanda tangan yang tidak pernah ada.
 *  3. Kolom yang dirujuk pada tabel inti tetapi tidak pernah ditambahkan.
 *  4. Blok dollar-quote yang tidak tertutup.
 *
 * Jalankan: node scripts/check-sql-refs.mjs [berkas]
 */
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const target = process.argv[2] || path.join(root, 'supabase', 'apply-pending.sql');

// Seluruh migration dibaca supaya fungsi yang dibuat lebih dulu dianggap sudah ada.
const migDir = path.join(root, 'supabase', 'migrations');
const migFiles = (await readdir(migDir)).filter((f) => f.endsWith('.sql')).sort();
let history = '';
for (const f of migFiles) history += await readFile(path.join(migDir, f), 'utf8') + '\n';

// An absent generated bundle says nothing about the remote migration ledger.
let bundle;
try {
  bundle = await readFile(target, 'utf8');
} catch (e) {
  if (e.code !== 'ENOENT' || process.argv[2]) throw e;
  console.log(`\n  SKIPPED: ${path.relative(root, target)} tidak tersedia; status migration remote belum diperiksa.`);
  console.log('  Berikan nama file SQL untuk pemeriksaan statis. Rekonsiliasi ledger sebelum membuat/menerapkan bundle.\n');
  process.exit(0);
}

const problems = [];

// 1. Dollar-quote yang tidak seimbang membuat sisa berkas terbaca sebagai teks.
const tags = [...bundle.matchAll(/\$([A-Za-z_][A-Za-z0-9_]*)?\$/g)].map((m) => m[0]);
const open = new Map();
for (const t of tags) open.set(t, (open.get(t) || 0) + 1);
for (const [tag, n] of open) {
  if (n % 2 !== 0) problems.push(`Dollar-quote ${tag} muncul ${n} kali (ganjil); blok tidak tertutup.`);
}

// 2. Fungsi yang dibuat, dari seluruh riwayat dan dari bundle.
const created = new Set();
for (const src of [history, bundle]) {
  for (const m of src.matchAll(/create\s+(?:or\s+replace\s+)?function\s+([a-z_]+\.[a-z_0-9]+)\s*\(/gi)) {
    created.add(m[1].toLowerCase());
  }
}

// 3. Fungsi yang dipanggil di dalam bundle.
//
// "insert into public.claims(...)" secara sintaksis mirip pemanggilan fungsi. Kata kunci
// di depan nama dan daftar tabel yang dikenal dipakai untuk membedakannya, supaya laporan
// tidak dipenuhi temuan palsu yang membuat temuan asli terlewat.
const tableNames = new Set();
for (const src of [history, bundle]) {
  for (const m of src.matchAll(/create\s+table\s+(?:if\s+not\s+exists\s+)?([a-z_]+\.[a-z_0-9]+)/gi)) {
    tableNames.add(m[1].toLowerCase());
  }
}
const SQL_KEYWORDS = ['into', 'from', 'join', 'update', 'table', 'on', 'exists'];
const called = new Map();
for (const m of bundle.matchAll(/(\w+)?\s*((?:rc_private|public)\.[a-z_0-9]+)\s*\(/gi)) {
  const before = (m[1] || '').toLowerCase();
  const name = m[2].toLowerCase();
  if (SQL_KEYWORDS.includes(before)) continue;
  if (tableNames.has(name)) continue;
  if (!called.has(name)) called.set(name, bundle.slice(0, m.index).split('\n').length);
}
// Fungsi bawaan PostgreSQL pada schema public tidak pernah kita buat sendiri.
const builtin = new Set(['public.gen_random_uuid']);
for (const [name, line] of called) {
  if (!created.has(name) && !builtin.has(name)) {
    problems.push(`Baris ~${line}: memanggil ${name}() yang tidak pernah dibuat.`);
  }
}

// 4. DROP FUNCTION terhadap tanda tangan yang tidak pernah ada.
for (const m of bundle.matchAll(/drop\s+function\s+(?:if\s+exists\s+)?([a-z_]+\.[a-z_0-9]+)/gi)) {
  const name = m[1].toLowerCase();
  if (!created.has(name)) {
    const line = bundle.slice(0, m.index).split('\n').length;
    problems.push(`Baris ~${line}: DROP FUNCTION ${name} yang tidak pernah dibuat.`);
  }
}

// 5. Kolom tabel inti. Dikumpulkan dari CREATE TABLE dan ALTER TABLE ADD COLUMN.
const columns = new Map();
const all = history + '\n' + bundle;
for (const m of all.matchAll(/create\s+table\s+([a-z_]+\.[a-z_0-9]+)\s*\(([\s\S]*?)\n\)\s*;/gi)) {
  const tbl = m[1].toLowerCase();
  const set = columns.get(tbl) || new Set();
  for (const line of m[2].split(/,(?![^(]*\))/)) {
    const col = line.trim().match(/^([a-z_][a-z_0-9]*)\s/i);
    if (col && !/^(primary|unique|check|foreign|constraint)$/i.test(col[1])) set.add(col[1].toLowerCase());
  }
  columns.set(tbl, set);
}
for (const m of all.matchAll(/alter\s+table\s+([a-z_]+\.[a-z_0-9]+)\s+add\s+column\s+(?:if\s+not\s+exists\s+)?([a-z_0-9]+)/gi)) {
  const tbl = m[1].toLowerCase();
  const set = columns.get(tbl) || new Set();
  set.add(m[2].toLowerCase());
  columns.set(tbl, set);
}

// Kolom yang dipakai bundle pada tabel yang strukturnya kita ketahui.
const WATCH = ['public.claims', 'public.customers', 'public.campaigns', 'public.depots', 'public.profiles'];
for (const tbl of WATCH) {
  const known = columns.get(tbl);
  if (!known) { problems.push(`Struktur ${tbl} tidak ditemukan; pemeriksaan kolom dilewati.`); continue; }
  const alias = tbl.split('.')[1];
  const re = new RegExp(`${alias}\\.([a-z_0-9]+)`, 'gi');
  for (const m of bundle.matchAll(re)) {
    const col = m[1].toLowerCase();
    if (!known.has(col)) {
      const line = bundle.slice(0, m.index).split('\n').length;
      problems.push(`Baris ~${line}: ${tbl}.${col} tidak ada pada struktur tabel.`);
    }
  }
}

console.log(`\n  Memeriksa ${path.relative(root, target)}`);
console.log(`  ${migFiles.length} migration dibaca sebagai riwayat, ${created.size} fungsi dikenal.\n`);
if (problems.length === 0) {
  console.log('  \x1b[32mTidak ditemukan masalah pada pemeriksaan ini.\x1b[0m');
  console.log('  Ini bukan jaminan SQL berhasil; hanya PostgreSQL yang dapat memastikannya.\n');
} else {
  console.log(`  \x1b[31m${problems.length} hal perlu diperiksa:\x1b[0m`);
  [...new Set(problems)].forEach((p) => console.log(`    - ${p}`));
  console.log('');
  process.exitCode = 1;
}
