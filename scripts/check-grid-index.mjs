/*
 * Melarang penulisan sel grid berdasarkan NOMOR URUT kolom.
 *
 * ASAL-USULNYA
 * Grid Mass Upload kini memiliki dua susunan kolom: mode Posting Claim (sepuluh kolom) dan
 * mode Posting Exception (lima kolom). Kode yang menulis lewat inputs[5].value benar pada
 * susunan pertama dan melempar TypeError pada susunan kedua, karena inputs[5] bernilai
 * undefined. Kegagalannya tidak terlihat sebagai kesalahan di layar: perulangan berhenti di
 * baris pertama, sehingga hanya SATU dokumen yang masuk ke grid betapapun banyak yang
 * dicentang, dan kolom tanggalnya tetap kosong. Pemilik melaporkannya dua kali sebelum
 * sebabnya ditemukan.
 *
 * Bentuk yang benar adalah menulis lewat atribut name:
 *   tr.querySelector('[name="noRekening"]')
 * Kolom yang tidak ada pada susunan yang sedang aktif lantas terlewati dengan sendirinya,
 * bukan menjatuhkan seluruh perulangan.
 *
 * Jalankan: node scripts/check-grid-index.mjs
 */
import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dir = path.join(root, 'src', 'js');

// Penugasan ke sel yang dipilih lewat indeks angka: inputs[5].value = ...
// Indeks berupa variabel (inputs[i]) tidak ikut tertangkap - itu lumrah dan tidak berbahaya,
// karena panjangnya ikut menyesuaikan susunan kolom yang sedang aktif.
const POLA = /\b([A-Za-z_$][\w$]*)\s*\[\s*\d+\s*\]\s*\.value\s*=/g;

const masalah = [];
for (const berkas of await readdir(dir)) {
  if (!berkas.endsWith('.js')) continue;
  const isi = await readFile(path.join(dir, berkas), 'utf8');
  const baris = isi.split(/\r?\n/);
  baris.forEach((teks, i) => {
    if (/^\s*\/\//.test(teks)) return; // komentar yang menjelaskan larangan ini
    POLA.lastIndex = 0;
    const m = POLA.exec(teks);
    if (m) masalah.push(`src/js/${berkas}:${i + 1}  ${teks.trim().slice(0, 100)}`);
  });
}

if (masalah.length === 0) {
  console.log('  \x1b[32mTidak ada penulisan sel grid berdasarkan nomor urut kolom.\x1b[0m');
} else {
  console.log(`  \x1b[31m${masalah.length} penulisan lewat indeks angka:\x1b[0m`);
  masalah.forEach((m) => console.log(`    - ${m}`));
  console.log('    Pakai tr.querySelector(\'[name="..."]\') supaya kedua susunan kolom aman.');
  console.log('');
  process.exitCode = 1;
}
