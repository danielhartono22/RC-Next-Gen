/*
 * Menjaga agar literal regex pada halaman tidak kehilangan backslash-nya.
 *
 * ASAL-USULNYA
 * Sebelum modularisasi, seluruh JavaScript halaman ditulis di dalam template literal pada
 * berkas .mjs. Di dalam template literal, `\d` bukan escape yang dikenali JavaScript, sehingga
 * backslash-nya dibuang diam-diam dan /^-?\d+$/ berubah menjadi /^-?d+$/ pada hasil build.
 * Regex itu tetap sah, tidak menimbulkan error, dan hanya berhenti cocok - validasinya mati
 * tanpa suara. Kegagalan ini pernah lolos sampai ke hasil build.
 *
 * MENGAPA VERSI SEBELUMNYA SALAH MENUDUH
 * Pemeriksaan lama mencari substring seperti "d{4}-" pada hasil build. Masalahnya, teks itu
 * JUGA terkandung di dalam bentuk yang benar: `\d{4}-` memuat `d{4}-`. Akibatnya kode yang
 * sepenuhnya benar dilaporkan rusak. Penjagaan yang menuduh kode benar sama merugikannya
 * dengan tidak ada penjagaan sama sekali, karena pembacanya berhenti mempercayainya.
 *
 * Sekarang yang diperiksa adalah kelas karakter regex yang berdiri TANPA backslash di depannya,
 * memakai lookbehind negatif. Bentuk yang benar tidak lagi ikut tertangkap.
 *
 * Jalankan: node scripts/check-template-regex.mjs
 */
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const masalah = [];

// Bentuk rusak yang benar-benar mungkin muncul: sebuah kuantifier atau kelas karakter yang
// kehilangan backslash-nya. Lookbehind memastikan yang berbackslash tidak ikut tertangkap.
const POLA_RUSAK = [
  { nama: 'd{...} tanpa backslash', re: /(?<!\\)\bd\{\d/ },
  { nama: 'w{...} tanpa backslash', re: /(?<!\\)\bw\{\d/ },
  { nama: 's{...} tanpa backslash', re: /(?<!\\)\bs\{\d/ },
  { nama: '/^-?d+ tanpa backslash', re: /\/\^-\?d\+/ },
  { nama: '(.d+) tanpa backslash', re: /\(\.d\+\)/ }
];

try {
  const html = await readFile(path.join(root, 'public', 'index.html'), 'utf8');
  for (const { nama, re } of POLA_RUSAK) {
    const m = html.match(re);
    if (m) {
      // Memakai m.index, bukan indexOf(m[0]): teks yang cocok bisa muncul lebih awal di
      // tempat yang justru benar, dan cuplikan yang menunjuk baris keliru akan menyesatkan
      // orang yang memperbaikinya.
      const at = m.index;
      const cuplikan = html.slice(Math.max(0, at - 40), at + 40).replace(/\s+/g, ' ');
      masalah.push(`${nama}: ...${cuplikan}...`);
    }
  }
} catch {
  masalah.push('public/index.html belum ada; jalankan npm run build lebih dulu');
}

if (masalah.length === 0) {
  console.log('  \x1b[32mSeluruh regex pada hasil build utuh.\x1b[0m');
} else {
  console.log(`  \x1b[31m${masalah.length} masalah:\x1b[0m`);
  [...new Set(masalah)].forEach((m) => console.log(`    - ${m}`));
  console.log('');
  process.exitCode = 1;
}
