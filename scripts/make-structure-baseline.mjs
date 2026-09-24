/*
 * Mencatat "tulang" halaman yang sedang berlaku sebagai baseline paritas struktural.
 *
 * Jalankan ketika sebuah penghapusan memang disengaja dan sudah dicantumkan pada
 * "sengajaDihapus", atau ketika baseline perlu dibuat pertama kali. Di luar itu jangan
 * dijalankan: menyegarkan baseline setiap kali build gagal akan membuat penjagaannya tidak
 * berarti apa-apa, karena setiap kehilangan otomatis menjadi normal baru.
 *
 * Jalankan: node scripts/make-structure-baseline.mjs
 */
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { bacaStruktur } from './rc-structure.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TARGET = path.join(root, 'config', 'rc-structure-baseline.json');

const html = await readFile(path.join(root, 'public', 'index.html'), 'utf8');
const s = bacaStruktur(html);

let sengajaDihapus = [];
try {
  sengajaDihapus = JSON.parse(await readFile(TARGET, 'utf8')).sengajaDihapus || [];
} catch { /* baseline pertama */ }

await mkdir(path.dirname(TARGET), { recursive: true });
await writeFile(TARGET, JSON.stringify({
  catatan: 'Dihasilkan oleh scripts/make-structure-baseline.mjs. Build menolak kehilangan id '
    + 'atau fungsi yang tercantum di sini, kecuali namanya juga tercantum pada sengajaDihapus.',
  dicatatPada: new Date().toISOString().slice(0, 10),
  ids: s.ids,
  fungsi: s.fungsi,
  sengajaDihapus
}, null, 2) + '\n', 'utf8');

console.log(`\n  Baseline dicatat: ${s.ids.length} id, ${s.fungsi.length} fungsi.`);
if (s.idDipanggilTanpaMarkup.length) {
  console.log(`  ${s.idDipanggilTanpaMarkup.length} id dipanggil kode tetapi tidak ada di markup:`);
  console.log('    ' + s.idDipanggilTanpaMarkup.slice(0, 20).join(', ')
    + (s.idDipanggilTanpaMarkup.length > 20 ? ', ...' : ''));
  console.log('  Sebagian mungkin dibuat saat runtime; sisanya pantas diperiksa.');
}
console.log('');
