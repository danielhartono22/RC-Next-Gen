/*
 * Menjaga kontrak modal pada hasil build.
 *
 * MENGAPA PERLU DIJAGA
 * Perilaku "layar di belakang mati selama modal terbuka" bertumpu pada satu kesepakatan sederhana:
 * setiap lapisan modal adalah ANAK LANGSUNG <body>. Dua hal bergantung padanya sekaligus -
 * pengelola modal mencarinya dengan selektor `body > [id$="Modal"]`, dan gaya yang membuat modal
 * tinggi dapat digulir memakai selektor yang sama.
 *
 * Bila suatu saat sebuah modal dipasang lebih dalam - misalnya ikut terbawa ke dalam markup modul -
 * tidak ada yang melempar galat. Modalnya tetap tampil, hanya saja layar di belakangnya tetap
 * hidup dan isinya yang kepanjangan tidak dapat digulir sampai habis. Kegagalan senyap seperti
 * itulah yang ditemukan pemilik sendiri, bukan oleh kita.
 *
 * Markup yang tidak seimbang juga diperiksa di sini. Satu </div> liar tidak membuat halaman
 * gagal dimuat - peramban memperbaikinya diam-diam - tetapi ia menggeser kedalaman seluruh
 * elemen sesudahnya, dan perbaikan diam-diam itu berbeda antar peramban.
 *
 * Jalankan: node scripts/check-modal.mjs
 */
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const hijau = (t) => `\x1b[32m${t}\x1b[0m`;
const merah = (t) => `\x1b[31m${t}\x1b[0m`;

const html = await readFile(path.join(root, 'public', 'index.html'), 'utf8');
const temuan = [];

const awalBody = html.indexOf('>', html.indexOf('<body')) + 1;
if (awalBody <= 0) {
  console.error(merah('  Tidak menemukan <body> pada hasil build.'));
  process.exit(1);
}

// Kedalaman dihitung dari selisih <div> yang dibuka dan ditutup sampai tepat sebelum elemen itu.
// Cukup untuk halaman ini: seluruh lapisan modal memang <div>, dan nol berarti anak langsung body.
function kedalamanDiv(sampai) {
  const potong = html.slice(awalBody, sampai);
  return (potong.match(/<div\b/g) || []).length - (potong.match(/<\/div>/g) || []).length;
}

const modal = [...html.matchAll(/id="([A-Za-z0-9_]*Modal)"/g)];
if (modal.length === 0) temuan.push('Tidak ada satu pun elemen modal pada hasil build.');

for (const m of modal) {
  const awalTag = html.lastIndexOf('<', m.index);
  const dalam = kedalamanDiv(awalTag);
  if (dalam !== 0) {
    temuan.push(`${m[1]} berada ${dalam} tingkat dari <body>, seharusnya anak langsung. `
      + 'Pengelola modal dan gaya penggulirnya memakai selektor body > [id$="Modal"], '
      + 'jadi modal yang bersarang kehilangan keduanya tanpa pesan galat.');
  }
}

// Setiap lapisan penuh layar WAJIB bernama "...Modal".
//
// Cacat ini pernah terjadi dan mahal: editor baris master bernama rcRowEditor dan bersarang di
// dalam workspace, sehingga ia bukan modal menurut selektor mana pun - layar di belakangnya
// tetap hidup, dan pada layar pendek tombol Simpan tidak dapat dicapai. Akibatnya Customer
// Master dan Campaign Master terasa tidak bisa diubah sama sekali, padahal backend-nya sehat.
//
// Yang dicari adalah ciri lapisan itu sendiri - "fixed inset-0" - bukan namanya, supaya lapisan
// berikutnya yang dibuat dengan nama apa pun tetap tertangkap.
for (const m of html.matchAll(/<div[^>]*class="[^"]*fixed[^"]*inset-0[^"]*"[^>]*>/g)) {
  const id = (m[0].match(/id="([^"]+)"/) || [])[1];
  if (!id) {
    temuan.push('Ada lapisan penuh layar (fixed inset-0) tanpa id, jadi pengelola modal tidak '
      + 'dapat mengaturnya. Beri id berakhiran "Modal".');
    continue;
  }
  if (!/Modal$/.test(id)) {
    temuan.push(`Lapisan penuh layar "${id}" tidak berakhiran "Modal", sehingga ia luput dari `
      + 'pengelola modal dan dari gaya penggulirnya: layar di belakangnya tetap aktif dan isinya '
      + 'yang kepanjangan tidak dapat digulir. Ganti namanya menjadi ' + id + 'Modal.');
  }
}

// Seimbang sampai <script> penutup. Angka negatif berarti ada </div> yang tidak punya pasangan.
const awalSkrip = html.indexOf('<script>', awalBody);
const sisa = kedalamanDiv(awalSkrip > 0 ? awalSkrip : html.length);
if (sisa !== 0) {
  temuan.push(`Markup tidak seimbang sampai blok script: selisih <div> ${sisa > 0 ? '+' : ''}${sisa}. `
    + (sisa < 0 ? 'Ada </div> tanpa pasangan.' : 'Ada <div> yang tidak ditutup.'));
}

// Gaya dan pengelolanya harus benar-benar ikut terbangun; keduanya mudah hilang saat berkas
// bersama dipindah-pindah, dan hilangnya tidak terlihat sampai ada yang membuka modal.
const wajib = [
  ['body.rc-modal-terbuka', 'aturan penguncian gulir'],
  ['body > [id$="Modal"]', 'aturan penggulir lapisan modal'],
  ['rcPerbaruiKuncianModal', 'pengelola modal'],
  ['rcModalPalingAtas', 'pemilih modal teratas menurut z-index']
];
for (const [jarum, nama] of wajib) {
  if (!html.includes(jarum)) temuan.push(`${nama} tidak ada pada hasil build (mencari "${jarum}").`);
}

console.log('');
console.log('  PEMERIKSAAN MODAL');
console.log(`  lapisan modal ${modal.length} | kedalaman semua 0 | markup seimbang`);
console.log('');
if (temuan.length === 0) {
  console.log(`  ${hijau('Tidak ada temuan.')}`);
} else {
  console.log(`  ${merah(temuan.length + ' temuan:')}`);
  temuan.forEach((t) => console.log(`    - ${t}`));
  process.exitCode = 1;
}
console.log('');
