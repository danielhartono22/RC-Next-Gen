/*
 * PEMERIKSAAN PEMAKAIAN SEBELUM DEKLARASI (Temporal Dead Zone)
 *
 * MENGAPA INI ADA
 * Sebuah fungsi penyimpanan memakai variabel `modeUji` pada baris 11, sementara
 * `const modeUji` baru ditulis pada baris 23 fungsi yang sama. JavaScript melempar
 * ReferenceError di titik pemakaian itu - dan karena lemparannya terjadi SEBELUM blok try,
 * tidak ada yang menangkapnya. Tombol Simpan tampak bekerja, tidak ada pesan galat sama
 * sekali, tetapi tidak ada apa pun yang tersimpan.
 *
 * Seluruh pemeriksaan yang ada lolos: berkasnya sah secara sintaks, id-nya lengkap, nama
 * fungsinya terdaftar, regex-nya utuh. Yang salah hanya URUTAN, dan itu tidak terlihat oleh
 * pemeriksaan mana pun yang membaca teks atau sekadar menguraikan program.
 *
 * CARA KERJANYA
 * Untuk setiap fungsi, deklarasi `const`/`let` yang berada langsung di badan fungsi dicatat
 * beserta letaknya. Bila nama yang sama muncul sebagai identifier di dalam fungsi itu SEBELUM
 * letak deklarasinya, itu pasti ReferenceError saat dijalankan - bukan dugaan, karena deklarasi
 * pada badan fungsi berlaku untuk seluruh isi fungsi.
 *
 * Nama yang dideklarasikan lebih dari sekali di fungsi yang sama dilewati: di situ ada
 * pembayangan (shadowing) pada blok bersarang, dan menilainya tanpa pohon sintaks akan salah.
 *
 * Jalankan: node scripts/check-tdz.mjs
 */
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temuan = [];

// Komentar, teks dan literal regex diganti spasi dengan panjang yang sama, sehingga seluruh
// nomor baris dan posisi tetap menunjuk ke tempat yang benar pada berkas aslinya.
function bersihkan(s) {
  let out = '';
  let i = 0;
  const n = s.length;
  const spasi = (t) => t.replace(/[^\n]/g, ' ');
  while (i < n) {
    const c = s[i], d = s[i + 1];
    if (c === '/' && d === '/') {
      const j = s.indexOf('\n', i); const k = j < 0 ? n : j;
      out += spasi(s.slice(i, k)); i = k; continue;
    }
    if (c === '/' && d === '*') {
      const j = s.indexOf('*/', i + 2); const k = j < 0 ? n : j + 2;
      out += spasi(s.slice(i, k)); i = k; continue;
    }
    if (c === '"' || c === "'" || c === '`') {
      let j = i + 1;
      while (j < n && s[j] !== c) { if (s[j] === '\\') j++; j++; }
      out += spasi(s.slice(i, Math.min(j + 1, n))); i = j + 1; continue;
    }
    // Literal regex: hanya ketika tanda bagi tidak mungkin berarti pembagian.
    if (c === '/') {
      const sebelum = out.replace(/\s+$/, '').slice(-1);
      if (sebelum === '' || '(,=:[!&|?{};+-*%~^<>'.includes(sebelum)) {
        let j = i + 1, kelas = false, tutup = false;
        while (j < n) {
          const e = s[j];
          if (e === '\\') { j += 2; continue; }
          if (e === '\n') break;
          if (e === '[') kelas = true;
          else if (e === ']') kelas = false;
          else if (e === '/' && !kelas) { tutup = true; break; }
          j++;
        }
        if (tutup) { out += spasi(s.slice(i, j + 1)); i = j + 1; continue; }
      }
    }
    out += c; i++;
  }
  return out;
}

// Mengembalikan [awalBadan, akhirBadan] untuk kurung kurawal yang dibuka pada posisi buka.
function badan(s, buka) {
  let d = 0;
  for (let i = buka; i < s.length; i++) {
    if (s[i] === '{') d++;
    else if (s[i] === '}') { d--; if (d === 0) return [buka + 1, i]; }
  }
  return null;
}

const KATA_KUNCI = new Set(['if', 'for', 'while', 'switch', 'catch', 'return', 'typeof',
  'new', 'delete', 'void', 'in', 'of', 'instanceof', 'do', 'else', 'case', 'throw', 'await',
  'yield', 'true', 'false', 'null', 'undefined', 'this']);

function periksa(nama, isi) {
  const s = bersihkan(isi);
  const reFn = /\bfunction\s+([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{/g;
  let m;
  while ((m = reFn.exec(s)) !== null) {
    const b = badan(s, s.indexOf('{', m.index + m[0].length - 1));
    if (!b) continue;
    const [a, z] = b;
    const tubuh = s.slice(a, z);

    // Deklarasi yang berada LANGSUNG di badan fungsi (kedalaman kurawal nol).
    const dek = new Map();
    const ulang = new Set();
    let d = 0;
    const reDek = /\b(const|let)\s+([A-Za-z_$][\w$]*)/g;
    const kedalaman = new Array(tubuh.length);
    for (let i = 0; i < tubuh.length; i++) {
      if (tubuh[i] === '{') d++;
      else if (tubuh[i] === '}') d--;
      kedalaman[i] = d;
    }
    let dm;
    while ((dm = reDek.exec(tubuh)) !== null) {
      const v = dm[2];
      if (dek.has(v) || ulang.has(v)) { ulang.add(v); dek.delete(v); continue; }
      // Variabel perulangan `for (let i = ...)` terikat pada perulangannya, bukan pada badan
      // fungsi, jadi ia tidak membentuk zona mati bagi pemakaian di atasnya.
      if (/\bfor\s*\($/.test(tubuh.slice(Math.max(0, dm.index - 12), dm.index))) {
        ulang.add(v); continue;
      }
      if (kedalaman[dm.index] === 0) dek.set(v, dm.index);
      else ulang.add(v);   // dideklarasikan di blok bersarang: lewati, bisa jadi pembayangan
    }

    // Nama yang juga dipakai sebagai parameter arrow function mengikat ulang dirinya sendiri di
    // dalam arrow itu. Tanpa pohon sintaks, membedakan keduanya tidak dapat diandalkan - jadi
    // nama seperti itu dilewati. Lebih baik melewatkan satu temuan daripada menuduh kode sehat.
    for (const v of [...dek.keys()]) {
      const reArrow = new RegExp(
        '(^|[^\\w$.])' + v.replace(/\$/g, '\\$') + '\\s*=>|\\(\\s*[^()]*\\b'
        + v.replace(/\$/g, '\\$') + '\\b[^()]*\\)\\s*=>');
      if (reArrow.test(tubuh)) dek.delete(v);
    }

    for (const [v, pos] of dek) {
      const rePakai = new RegExp('(^|[^\\w$.])' + v.replace(/\$/g, '\\$') + '(?![\\w$])', 'g');
      let pm;
      while ((pm = rePakai.exec(tubuh)) !== null) {
        const at = pm.index + pm[1].length;
        if (at >= pos) break;
        // Kunci objek ({ v: ... }) dan properti singkat bukan pemakaian variabel di sini.
        const sesudah = tubuh.slice(at + v.length).match(/^\s*:/);
        if (sesudah) continue;
        const baris = isi.slice(0, a + at).split('\n').length;
        const barisDek = isi.slice(0, a + pos).split('\n').length;
        temuan.push(`${nama}:${baris} fungsi ${m[1]}() memakai '${v}' `
          + `sebelum dideklarasikan pada baris ${barisDek} -> ReferenceError saat dijalankan`);
        break;
      }
    }
  }
}

const dirJs = [path.join(root, 'src', 'js'), path.join(root, 'src', 'view', 'js')];
for (const dir of dirJs) {
  let daftar;
  try { daftar = await readdir(dir); } catch { continue; }
  for (const f of daftar.filter((x) => x.endsWith('.js'))) {
    periksa(path.relative(root, path.join(dir, f)).replace(/\\/g, '/'),
      await readFile(path.join(dir, f), 'utf8'));
  }
}

console.log('\n  PEMERIKSAAN PEMAKAIAN SEBELUM DEKLARASI');
if (temuan.length) {
  console.log(`\n\x1b[31m  ${temuan.length} temuan:\x1b[0m`);
  temuan.forEach((t) => console.log('   - ' + t));
  console.log('');
  process.exit(1);
}
console.log('  Tidak ada variabel yang dipakai sebelum dideklarasikan.');
console.log('\n\x1b[32m  Tidak ada temuan.\x1b[0m\n');
