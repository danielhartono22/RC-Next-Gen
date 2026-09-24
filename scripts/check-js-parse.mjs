/*
 * Membuktikan bahwa seluruh JavaScript pada halaman hasil build benar-benar dapat diurai.
 *
 * MENGAPA INI ADA
 * Halaman ini satu berkas HTML dengan seluruh JavaScript-nya di dalam satu blok <script>.
 * Satu kesalahan sintaks di mana pun membuat SELURUH blok itu gagal dijalankan, sehingga
 * tidak satu pun tombol bekerja - dan di layar hasilnya hanya halaman yang diam, tanpa pesan
 * apa pun. Kegagalan seperti ini tidak dapat terlihat dari pemeriksaan struktur (id dan nama
 * fungsi tetap utuh) maupun dari penjagaan regex, karena keduanya membaca teks, bukan
 * menguraikannya sebagai program.
 *
 * Kejadian yang melahirkannya: sebuah literal regex /[\r\n,;\t]+/ kehilangan backslash-nya
 * ketika disunting lewat heredoc, sehingga yang tertulis di berkas adalah baris baru dan tab
 * yang sebenarnya. Regex-nya jadi terputus di tengah baris, dan halaman mati seluruhnya.
 *
 * Jalankan: node scripts/check-js-parse.mjs
 */
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const berkas = path.join(root, 'public', 'index.html');

let html;
try {
  html = await readFile(berkas, 'utf8');
} catch {
  console.log('  public/index.html belum ada; jalankan npm run build lebih dulu');
  process.exitCode = 1;
}

if (html) {
  // Hanya <script> tanpa src; yang bersumber dari CDN bukan urusan berkas ini.
  // Dua tangkapan: tag pembukanya sendiri, dan isinya. Keduanya dipisah karena atribut hanya
  // boleh dibaca dari tag pembuka - versi pertama berkas ini memeriksa seluruh hasil
  // pencocokan, sehingga sebuah `<input type="text">` DI DALAM isi script ikut terbaca sebagai
  // atribut type milik <script>, blok satu-satunya dilewati, dan penjagaan ini melaporkan
  // "semua dapat diurai" atas berkas yang sebenarnya rusak.
  const pola = /(<script(?![^>]*\bsrc=)[^>]*>)([\s\S]*?)<\/script>/g;
  const gagal = [];
  let m;
  let jumlah = 0;
  while ((m = pola.exec(html))) {
    const tag = m[1];
    const isi = m[2];
    if (!isi.trim()) continue;
    jumlah += 1;
    // Blok JSON-LD dan sejenisnya bukan JavaScript; dikenali dari atribut type pada tag.
    if (/type\s*=\s*["'](?!text\/javascript|application\/javascript)/.test(tag)) continue;
    try {
      new vm.Script(isi, { filename: `index.html#script${jumlah}` });
    } catch (e) {
      // Nomor baris dihitung dari awal berkas, bukan dari awal blok, supaya langsung
      // dapat dibuka di editor.
      const sebelum = html.slice(0, m.index).split('\n').length;
      const dalam = Number((/\s(\d+)\s*$/.exec(e.stack?.split('\n')[0] || '') || [])[1] || 0);
      gagal.push(`blok #${jumlah} (mulai baris ${sebelum}): ${e.message}${dalam ? ` [+${dalam}]` : ''}`);
    }
  }

  if (gagal.length === 0) {
    console.log(`  \x1b[32mSeluruh JavaScript pada hasil build dapat diurai (${jumlah} blok).\x1b[0m`);
  } else {
    console.log(`  \x1b[31m${gagal.length} blok <script> gagal diurai:\x1b[0m`);
    gagal.forEach((g) => console.log(`    - ${g}`));
    console.log('');
    process.exitCode = 1;
  }
}
