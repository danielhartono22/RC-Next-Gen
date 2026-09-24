/*
 * Menjaga bentuk pemanggilan dua fungsi yang tanda tangannya mudah salah diingat.
 *
 * MENGAPA INI ADA
 * Keduanya sudah pernah dipanggil dengan bentuk yang salah, dan keduanya gagal secara DIAM:
 *
 *   showConfirmModal(opts) -> Promise<boolean>
 *     Pernah dipanggil gaya lama dengan empat argumen posisi
 *     showConfirmModal(judul, pesan, onOk, onCancel). Akibatnya opts bernilai string, judul
 *     dan pesannya hilang, kedua callback diabaikan, dan Promise yang membungkusnya tidak
 *     pernah selesai. Di layar tombolnya sekadar tidak melakukan apa-apa, tanpa pesan galat.
 *
 *   showActionResult(judul, daftarBerhasil, daftarGagal, jenisAksi, noBatch)
 *     Pernah dipanggil sebagai showActionResult(judul, htmlString). Fungsi itu memanggil
 *     .map() atas argumen kedua, sehingga melempar TypeError sebelum sempat menampilkan
 *     apa pun - dialognya tidak muncul dan layarnya diam.
 *
 * Yang diperiksa hanya bentuk argumen PERTAMA yang kasatmata, bukan tipe sungguhan; itu sudah
 * cukup untuk menangkap kedua kekeliruan di atas tanpa perlu menguraikan seluruh program.
 *
 * Jalankan: node scripts/check-call-shapes.mjs
 */
import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dir = path.join(root, 'src', 'js');

const ATURAN = [
  {
    // Argumen pertama harus objek literal atau sebuah variabel, bukan string.
    nama: 'showConfirmModal dipanggil dengan argumen posisi',
    re: /\bshowConfirmModal\s*\(\s*['"`]/,
    saran: "showConfirmModal({ title, message, confirmText, danger }) dan await hasilnya."
  },
  {
    // Argumen kedua harus array; string HTML adalah kekeliruan yang pernah terjadi.
    nama: 'showActionResult diberi string HTML sebagai argumen kedua',
    re: /\bshowActionResult\s*\(\s*[^,()]+,\s*['"`]/,
    saran: 'Pakai rcDialog(judul, html) untuk menampilkan HTML bebas.'
  }
];

const masalah = [];
for (const berkas of await readdir(dir)) {
  if (!berkas.endsWith('.js')) continue;
  const isi = await readFile(path.join(dir, berkas), 'utf8');
  isi.split(/\r?\n/).forEach((teks, i) => {
    if (/^\s*(\/\/|\*)/.test(teks)) return; // komentar yang menjelaskan larangan ini
    for (const { nama, re, saran } of ATURAN) {
      if (re.test(teks)) {
        masalah.push(`src/js/${berkas}:${i + 1}  ${nama}\n      ${teks.trim().slice(0, 110)}\n      ${saran}`);
      }
    }
  });
}

if (masalah.length === 0) {
  console.log('  \x1b[32mBentuk pemanggilan dialog sudah sesuai tanda tangannya.\x1b[0m');
} else {
  console.log(`  \x1b[31m${masalah.length} pemanggilan dengan bentuk yang salah:\x1b[0m`);
  masalah.forEach((m) => console.log(`    - ${m}`));
  console.log('');
  process.exitCode = 1;
}
