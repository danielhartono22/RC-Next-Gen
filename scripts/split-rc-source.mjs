/*
 * Memecah public/index.html menjadi berkas-berkas sumber di src/.
 *
 * Dijalankan SEKALI, untuk memindahkan halaman dari satu berkas raksasa menjadi modul yang bisa
 * disunting. Sesudah itu src/ adalah sumber kebenaran dan skrip ini tidak dipakai lagi; ia
 * ditinggalkan supaya pemecahannya dapat ditelusuri dan diulang bila perlu.
 *
 * PEMBUKTIANNYA
 * Pemecahan yang "kelihatan benar" tidak cukup. Skrip ini merakit kembali potongan-potongan itu
 * di dalam memori dan menolak menulis apa pun bila hasil rakitan tidak identik byte per byte
 * dengan halaman asal. Jadi modularisasi ini tidak bisa diam-diam menghilangkan satu baris pun.
 *
 * Jalankan: node scripts/split-rc-source.mjs [--force]
 *   --force  menimpa src/ yang sudah ada
 */
import { readFile, writeFile, mkdir, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { MARKUP_PARTS, SCRIPT_PARTS, SCRIPT_OPEN_LINE, SCRIPT_CLOSE_LINE, TAIL_FROM }
  from './rc-source-layout.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC = path.join(root, 'src');
const force = process.argv.includes('--force');

const source = await readFile(path.join(root, 'public', 'index.html'), 'utf8');
const nl = source.includes('\r\n') ? '\r\n' : '\n';
const lines = source.split(nl);

// Potongan diambil 1-based inklusif, persis seperti yang tertulis di peta.
const slice = (from, to) => lines.slice(from - 1, to).join(nl);

try {
  await access(SRC);
  if (!force) {
    console.error('\n  src/ sudah ada. Jalankan dengan --force bila memang ingin menimpanya.\n');
    process.exit(1);
  }
} catch { /* belum ada, memang yang diharapkan */ }

// ---- Susun isi tiap berkas ----------------------------------------------------------------
const files = new Map();
for (const p of MARKUP_PARTS) files.set(path.join('parts', p.file), slice(p.from, p.to));
for (const p of SCRIPT_PARTS) files.set(path.join('js', p.file), slice(p.from, p.to));

// Shell: kerangka yang menyebut tiap potongan pada tempatnya. Penanda sengaja berupa komentar
// HTML biasa supaya berkasnya tetap bisa dibuka dan dibaca seperti HTML.
const shell = [];
for (const p of MARKUP_PARTS) shell.push(`<!--#include parts/${p.file}-->`);
shell.push(lines[SCRIPT_OPEN_LINE - 1]);            // baris <script> apa adanya, dengan indentasinya
for (const p of SCRIPT_PARTS) shell.push(`<!--#include js/${p.file}-->`);
shell.push(lines[SCRIPT_CLOSE_LINE - 1]);           // baris </script>
shell.push(slice(TAIL_FROM, lines.length));
files.set('index.html', shell.join(nl));

// ---- Buktikan rakitannya identik ----------------------------------------------------------
const rakit = [];
for (const p of MARKUP_PARTS) rakit.push(files.get(path.join('parts', p.file)));
rakit.push(lines[SCRIPT_OPEN_LINE - 1]);
for (const p of SCRIPT_PARTS) rakit.push(files.get(path.join('js', p.file)));
rakit.push(lines[SCRIPT_CLOSE_LINE - 1]);
rakit.push(slice(TAIL_FROM, lines.length));
const hasil = rakit.join(nl);

if (hasil !== source) {
  // Cari baris pertama yang berbeda supaya pesannya bisa ditindaklanjuti, bukan sekadar "gagal".
  const a = hasil.split(nl), b = lines;
  let i = 0;
  while (i < Math.min(a.length, b.length) && a[i] === b[i]) i += 1;
  console.error('\n  Menolak menulis: hasil rakitan tidak identik dengan halaman asal.');
  console.error(`  Baris pertama yang berbeda: ${i + 1} (asal ${b.length} baris, rakitan ${a.length} baris)`);
  console.error(`    asal   : ${JSON.stringify((b[i] || '').slice(0, 100))}`);
  console.error(`    rakitan: ${JSON.stringify((a[i] || '').slice(0, 100))}`);
  console.error('  Perbaiki batas baris di scripts/rc-source-layout.mjs.\n');
  process.exit(1);
}

// ---- Tulis -------------------------------------------------------------------------------
for (const [rel, isi] of files) {
  const tujuan = path.join(SRC, rel);
  await mkdir(path.dirname(tujuan), { recursive: true });
  await writeFile(tujuan, isi, 'utf8');
}

console.log(`\n  \x1b[32mPemecahan terbukti identik byte per byte.\x1b[0m`);
console.log(`  ${files.size} berkas ditulis ke src/ (${MARKUP_PARTS.length} markup, ${SCRIPT_PARTS.length} javascript, 1 shell).`);
console.log(`  Halaman asal ${source.length} karakter, rakitan ${hasil.length} karakter.\n`);
