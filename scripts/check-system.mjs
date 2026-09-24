/*
 * Pemeriksaan menyeluruh atas hal-hal yang gagal DIAM di halaman ini.
 *
 * Halaman RC adalah satu berkas HTML dengan seluruh JavaScript-nya di dalam satu blok <script>,
 * dan sebagian besar kerusakannya tidak menampilkan pesan apa pun: tombol yang memanggil fungsi
 * yang tidak ada hanya diam, id yang salah ketik membuat setengah fungsi berhenti di tengah, dan
 * aksi yang tidak punya penanganan di adapter menjawab dengan kalimat yang sama untuk semua
 * sebab. Yang diperiksa di sini adalah hal-hal seperti itu.
 *
 * Jalankan: node scripts/check-system.mjs
 *           node scripts/check-system.mjs --db     (ikut memeriksa RPC ke Supabase)
 *
 * Keluar dengan kode 1 bila ada temuan, supaya dapat dipakai sebagai penjaga.
 */
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const html = await readFile(path.join(root, 'public', 'index.html'), 'utf8');
const adapter = await readFile(path.join(root, 'scripts', 'rc-legacy-adapter.js'), 'utf8');

const skrip = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)]
  .map((m) => m[1]).filter((c) => c.trim());
const js = skrip.join('\n');

// Komentar dan isi string DIBUANG sebelum kode dipindai untuk mencari panggilan fungsi.
// Tanpa ini, kalimat Indonesia di dalam komentar - "menunggu persetujuan (lihat di bawah)" -
// terbaca sebagai panggilan persetujuan(), dan "rgba(15,23,42,.08)" di dalam string CSS
// terbaca sebagai panggilan rgba(). Yang tersisa sesudahnya hanyalah kode yang benar-benar
// dijalankan. Isi ${...} pada template literal TETAP dipertahankan, karena di halaman ini
// justru di sanalah sebagian besar pemanggilan fungsi berada.
function kupasKomentarDanString(kode) {
  let keluar = '';
  let i = 0;
  // tumpukan template literal: tiap unsur mencatat kedalaman kurung kurawal di dalam ${...}
  const tumpukanTemplate = [];
  let sebelumnya = '';
  const bolehRegex = () => sebelumnya === '' || '(,=:[!&|?{};+-*%~^<>'.includes(sebelumnya);

  while (i < kode.length) {
    const c = kode[i];
    const d = kode[i + 1];

    if (c === '/' && d === '/') {
      while (i < kode.length && kode[i] !== '\n') i += 1;
      continue;
    }
    if (c === '/' && d === '*') {
      i += 2;
      while (i < kode.length && !(kode[i] === '*' && kode[i + 1] === '/')) i += 1;
      i += 2;
      keluar += ' ';
      continue;
    }
    if (c === '/' && bolehRegex()) {
      // literal regex: dilewati sampai penutupnya, kelas [...] diperhatikan
      let j = i + 1;
      let dalamKelas = false;
      let tutup = false;
      while (j < kode.length) {
        const e = kode[j];
        if (e === '\\') { j += 2; continue; }
        if (e === '\n') break;
        if (e === '[') dalamKelas = true;
        else if (e === ']') dalamKelas = false;
        else if (e === '/' && !dalamKelas) { tutup = true; break; }
        j += 1;
      }
      if (tutup) {
        i = j + 1;
        while (i < kode.length && /[gimsuyd]/.test(kode[i])) i += 1;
        keluar += ' ';
        sebelumnya = ')';
        continue;
      }
    }
    if (c === "'" || c === '"') {
      const kutip = c;
      i += 1;
      while (i < kode.length && kode[i] !== kutip) {
        if (kode[i] === '\\') i += 1;
        i += 1;
      }
      i += 1;
      keluar += ' ';
      sebelumnya = ')';
      continue;
    }
    if (c === '`') {
      i += 1;
      // isi harfiahnya dibuang, tetapi ${...} dimasuki kembali sebagai kode
      while (i < kode.length) {
        if (kode[i] === '\\') { i += 2; continue; }
        if (kode[i] === '`') { i += 1; break; }
        if (kode[i] === '$' && kode[i + 1] === '{') {
          tumpukanTemplate.push(0);
          i += 2;
          keluar += ' (';
          break;
        }
        i += 1;
      }
      if (tumpukanTemplate.length === 0) { keluar += ' '; sebelumnya = ')'; }
      continue;
    }
    if (tumpukanTemplate.length > 0 && c === '{') tumpukanTemplate[tumpukanTemplate.length - 1] += 1;
    if (tumpukanTemplate.length > 0 && c === '}') {
      if (tumpukanTemplate[tumpukanTemplate.length - 1] === 0) {
        tumpukanTemplate.pop();
        i += 1;
        keluar += ') ';
        // kembali ke isi template literal
        while (i < kode.length) {
          if (kode[i] === '\\') { i += 2; continue; }
          if (kode[i] === '`') { i += 1; break; }
          if (kode[i] === '$' && kode[i + 1] === '{') { tumpukanTemplate.push(0); i += 2; keluar += ' ('; break; }
          i += 1;
        }
        sebelumnya = ')';
        continue;
      }
      tumpukanTemplate[tumpukanTemplate.length - 1] -= 1;
    }

    keluar += c;
    if (!/\s/.test(c)) sebelumnya = c;
    i += 1;
  }
  return keluar;
}

const jsKode = kupasKomentarDanString(js);

// Markup saja, tanpa isi <script>: id di dalam string JavaScript bukan elemen yang ada.
const markup = html.replace(/<script[\s\S]*?<\/script>/g, '');

const temuan = [];
const lapor = (jenis, pesan) => temuan.push({ jenis, pesan });

// ---------------------------------------------------------------- 1. Sintaks
for (const [i, kode] of skrip.entries()) {
  try {
    new vm.Script(kode, { filename: `index.html#script${i + 1}` });
  } catch (e) {
    lapor('SINTAKS', `blok <script> #${i + 1} tidak dapat diurai: ${e.message}`);
  }
}

// ---------------------------------------------------------------- 2. id ganda
const semuaId = [...markup.matchAll(/\bid="([A-Za-z0-9_-]+)"/g)].map((m) => m[1]);
const hitung = new Map();
semuaId.forEach((x) => hitung.set(x, (hitung.get(x) || 0) + 1));
[...hitung.entries()].filter(([, n]) => n > 1).forEach(([id, n]) => {
  // Dua elemen ber-id sama berarti getElementById selalu mengambil yang pertama, dan yang
  // kedua tidak pernah tersentuh oleh kode mana pun.
  lapor('ID GANDA', `id "${id}" dipakai ${n} kali; getElementById hanya menemukan yang pertama`);
});

// ---------------------------------------------------------------- 3. id yang dirujuk tapi tidak ada
const idAda = new Set(semuaId);

// Sebagian besar tabel di halaman ini dirangkai sebagai string di dalam JavaScript, sehingga
// id-nya baru ada setelah baris digambar - dan tidak pernah muncul di markup statis. Id
// seperti itu SAH dirujuk, jadi ikut dikumpulkan. Tanpa ini, setiap id yang dibuat runtime
// akan dilaporkan hilang, dan laporan yang berisik cepat berhenti dibaca.
const idDibuatJs = new Set([...js.matchAll(/\bid=\\?["'`]([A-Za-z0-9_-]+)\\?["'`]/g)].map((m) => m[1]));

const dirujuk = new Set();
for (const m of js.matchAll(/getElementById\(\s*['"]([A-Za-z0-9_-]+)['"]\s*\)/g)) dirujuk.add(m[1]);
for (const m of js.matchAll(
  /(?:setHiddenSafely|setDisabledSafely|setValueSafely|setTextSafely|getValueSafely|rcIsiKartuAngka|rcAktifkanUrutSemua|rcToggleCardExpand)\(\s*['"]([A-Za-z0-9_-]+)['"]/g
)) dirujuk.add(m[1]);

// Rujukan yang memang sengaja dibiarkan: modul Document Center belum dimigrasikan, dan
// beberapa nama adalah awalan yang dirangkai dengan indeks saat dijalankan.
const sengajaTidakAda = new Set(['menuPrintDoc']);
const awalanDirangkai = ['kaGrade_', 'kaTipe_', 'rcField_', 'mContent', 'mTab', 'btnCommit'];

[...dirujuk].sort().forEach((id) => {
  if (idAda.has(id) || idDibuatJs.has(id) || sengajaTidakAda.has(id)) return;
  if (awalanDirangkai.some((a) => id === a || id.startsWith(a))) return;
  lapor('ID HILANG', `kode merujuk id "${id}" yang tidak ada di markup`);
});

// ---------------------------------------------------------------- 4. fungsi atribut yang tidak ada
const dipanggil = new Set(
  [...markup.matchAll(/\bon(?:click|change|input|submit|keyup|blur|focus)="\s*([A-Za-z_$][\w$]*)\s*\(/g)]
    .map((m) => m[1])
);
const adaFungsi = new Set();
for (const m of jsKode.matchAll(/(?:^|[\s;{])(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/g)) adaFungsi.add(m[1]);
for (const m of jsKode.matchAll(/(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:function|\()/g)) adaFungsi.add(m[1]);
const kataKunci = new Set(['if', 'for', 'while', 'switch', 'return', 'typeof', 'catch']);
[...dipanggil].sort().forEach((f) => {
  if (adaFungsi.has(f) || kataKunci.has(f)) return;
  lapor('FUNGSI HILANG', `atribut memanggil ${f}() yang tidak didefinisikan di mana pun`);
});

// ------------------------------------------------- 4b. fungsi yang dipanggil DARI DALAM JavaScript
// Pemeriksaan 4 hanya melihat atribut on-klik di markup. Panggilan dari dalam kode sendiri lolos
// begitu saja - dan justru di situ kerusakannya paling sunyi: ttBolehLihatPerDepot() pernah
// dipanggil oleh loadTimetable() tanpa pernah didefinisikan, sehingga modul Timetable gagal dibuka
// untuk SEMUA orang dengan pesan "Gagal memuat Timetable" yang tidak menyebut sebab apa pun.
// ReferenceError di dalam try/catch memang tampak persis seperti kegagalan jaringan.
//
// Yang dianggap sah: fungsi yang didefinisikan di halaman, kata kunci bahasa, dan nama bawaan
// browser maupun JavaScript yang dipanggil tanpa titik di depannya.
const bawaan = new Set([
  // JavaScript
  'String', 'Number', 'Boolean', 'Array', 'Object', 'Date', 'Error', 'RegExp', 'Map', 'Set',
  'Promise', 'Symbol', 'BigInt', 'Function', 'Proxy', 'WeakMap', 'WeakSet', 'JSON', 'Math',
  'parseInt', 'parseFloat', 'isNaN', 'isFinite', 'eval', 'structuredClone', 'queueMicrotask',
  'encodeURIComponent', 'decodeURIComponent', 'encodeURI', 'decodeURI', 'btoa', 'atob',
  'Uint8Array', 'Uint16Array', 'Uint32Array', 'Int8Array', 'Int16Array', 'Int32Array',
  'Float32Array', 'Float64Array', 'ArrayBuffer', 'DataView', 'Uint8ClampedArray',
  // Browser
  'alert', 'confirm', 'prompt', 'fetch', 'setTimeout', 'setInterval', 'clearTimeout',
  'clearInterval', 'requestAnimationFrame', 'cancelAnimationFrame', 'getComputedStyle',
  'scrollTo', 'scrollBy', 'open', 'close', 'print', 'focus', 'blur', 'matchMedia',
  'FormData', 'Blob', 'File', 'FileReader', 'URL', 'URLSearchParams', 'Image', 'Audio',
  'XMLHttpRequest', 'Event', 'CustomEvent', 'MutationObserver', 'IntersectionObserver',
  'AbortController', 'TextEncoder', 'TextDecoder', 'Intl', 'Notification', 'Worker'
]);
// Global milik pustaka yang dimuat lewat <script src> dari CDN. Nama-nama ini tidak akan
// pernah ditemukan di dalam halaman karena memang bukan milik halaman ini.
const pustakaLuar = new Set(['Chart', 'XLSX', 'tailwind']);

const kataKunciJs = new Set([
  'if', 'for', 'while', 'switch', 'return', 'typeof', 'catch', 'function', 'new', 'await',
  'delete', 'void', 'in', 'of', 'do', 'else', 'try', 'throw', 'case', 'yield', 'import',
  'export', 'class', 'extends', 'super', 'this', 'instanceof', 'with', 'let', 'const', 'var'
]);

// Nama yang diberi nilai di mana pun - termasuk parameter, perusakan objek dan penugasan biasa -
// mungkin memegang fungsi tanpa terlihat sebagai definisi fungsi. Dikumpulkan supaya tidak
// dilaporkan sebagai hilang padahal ada.
const namaTerikat = new Set(adaFungsi);
for (const m of jsKode.matchAll(/(?:const|let|var)\s+([A-Za-z_$][\w$]*)/g)) namaTerikat.add(m[1]);
for (const m of jsKode.matchAll(/function\s*[A-Za-z_$\w$]*\s*\(([^)]*)\)/g)) {
  m[1].split(',').forEach((bagian) => {
    const nama = bagian.trim().match(/^([A-Za-z_$][\w$]*)/);
    if (nama) namaTerikat.add(nama[1]);
  });
}
// Parameter arrow function - (resolve, reject) => ... dan x => ... - juga memegang nilai,
// dan seringkali memegang fungsi. Tanpa ini, resolve() di dalam new Promise dilaporkan hilang.
for (const m of jsKode.matchAll(/\(([^()]*)\)\s*=>/g)) {
  m[1].split(',').forEach((bagian) => {
    const nama = bagian.trim().match(/^([A-Za-z_$][\w$]*)/);
    if (nama) namaTerikat.add(nama[1]);
  });
}
for (const m of jsKode.matchAll(/([A-Za-z_$][\w$]*)\s*=>/g)) namaTerikat.add(m[1]);

// Panggilan bare: nama( yang TIDAK didahului titik (itu pemanggilan method) atau karakter kata.
const sudahDilapor = new Set();
for (const m of jsKode.matchAll(/(^|[^.\w$])([A-Za-z_$][\w$]*)\s*\(/g)) {
  const nama = m[2];
  if (kataKunciJs.has(nama) || bawaan.has(nama) || pustakaLuar.has(nama) || namaTerikat.has(nama)) continue;
  if (sudahDilapor.has(nama)) continue;
  sudahDilapor.add(nama);
  lapor('FUNGSI HILANG', `kode memanggil ${nama}() yang tidak didefinisikan di mana pun`);
}

// ---------------------------------------------------------------- 5. aksi tanpa penanganan adapter
const aksi = [...new Set([...html.matchAll(/\baction:\s*'([A-Za-z][A-Za-z0-9_]*)'/g)].map((m) => m[1]))];
const penanganan = new Set([...adapter.matchAll(/^\s{4}([A-Za-z][A-Za-z0-9_]*)\s*:\s*function/gm)].map((m) => m[1]));
aksi.sort().forEach((a) => {
  if (!penanganan.has(a)) lapor('AKSI HILANG', `halaman mengirim action "${a}" yang tidak ada penanganannya di adapter`);
});

// ---------------------------------------------------------------- 6. RPC ganda / salah nama
const rpcDipakai = [...new Set([...adapter.matchAll(/rpc\(\s*'([a-z0-9_]+)'/g)].map((m) => m[1]))].sort();

// ---------------------------------------------------------------- 7. karakter kendali nyasar
// Backspace, tab vertikal dan sejenisnya pernah masuk ke berkas lewat escape yang termakan shell,
// dan merusak literal regex tanpa terlihat sama sekali di editor.
const kendali = [...js.matchAll(/[ --]/g)];
if (kendali.length > 0) {
  lapor('KARAKTER KENDALI', `${kendali.length} karakter kendali nyasar di dalam JavaScript hasil build`);
}

// ---------------------------------------------------------------- 8. pemeriksaan basis data
if (process.argv.includes('--db')) {
  const { default: jalankanSql } = await import('./lib-sql.mjs').catch(() => ({ default: null }));
  if (!jalankanSql) {
    lapor('DB', 'scripts/lib-sql.mjs tidak ada; lewati pemeriksaan RPC');
  } else {
    const daftar = rpcDipakai.map((n) => `'${n}'`).join(',');
    const sql = `select coalesce(jsonb_agg(x.n),'[]'::jsonb) as hilang from (
      select n from unnest(array[${daftar}]) n
      where not exists(select 1 from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
                        where ns.nspname='public' and p.proname=n)) x;`;
    try {
      const hasil = await jalankanSql(sql);
      const hilang = (hasil && hasil[0] && hasil[0].hilang) || [];
      hilang.forEach((n) => lapor('RPC HILANG', `adapter memanggil ${n}() yang tidak ada di basis data`));
    } catch (e) {
      lapor('DB', `pemeriksaan RPC gagal: ${e.message}`);
    }
  }
}

// ---------------------------------------------------------------- laporan
const hijau = (t) => `\x1b[32m${t}\x1b[0m`;
const merah = (t) => `\x1b[31m${t}\x1b[0m`;

console.log('');
console.log('  PEMERIKSAAN SISTEM');
console.log(`  blok script ${skrip.length} | id markup ${idAda.size} | id dari JS ${idDibuatJs.size} | id dirujuk ${dirujuk.size}`);
console.log(`  fungsi ${adaFungsi.size} | action ${aksi.length} | rpc ${rpcDipakai.length}`);
console.log('');

if (temuan.length === 0) {
  console.log(`  ${hijau('Tidak ada temuan.')}`);
} else {
  const perJenis = new Map();
  temuan.forEach((t) => {
    if (!perJenis.has(t.jenis)) perJenis.set(t.jenis, []);
    perJenis.get(t.jenis).push(t.pesan);
  });
  console.log(`  ${merah(temuan.length + ' temuan:')}`);
  for (const [jenis, pesan] of perJenis) {
    console.log(`\n  ${jenis} (${pesan.length})`);
    pesan.forEach((p) => console.log(`    - ${p}`));
  }
  process.exitCode = 1;
}
console.log('');
