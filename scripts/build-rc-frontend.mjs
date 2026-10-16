/*
 * Merakit public/index.html dari berkas-berkas sumber di src/.
 *
 * SEJARAH SINGKAT, SUPAYA PERUBAHANNYA MASUK AKAL
 * Sebelumnya skrip ini menempelkan empat puluh suntingan berjangkar ke satu berkas warisan,
 * "index (4).html", lalu membuktikan sisa markup-nya identik byte per byte. Penjagaan itu tepat
 * selama tugasnya memindahkan backend tanpa menyentuh tampilan. Begitu pemilik meminta kolom
 * dihapus, kartu ditambah dan halaman dimodularisasi, penjagaan itu berubah dari pelindung
 * menjadi penghalang: setiap perubahan tampilan yang sah akan membuat build gagal.
 *
 * Sekarang sumbernya adalah src/, dan penjagaannya adalah paritas struktural (lihat
 * scripts/rc-structure.mjs): build boleh menambah apa saja, tetapi tidak boleh menghilangkan
 * id elemen atau fungsi yang pernah ada kecuali penghapusan itu dicantumkan dengan sengaja di
 * config/rc-structure-baseline.json. Dengan begitu tampilan bebas berubah, sementara cara
 * paling umum halaman rusak diam-diam - sebuah id hilang padahal masih dipanggil - tetap
 * tertangkap.
 *
 * Pemecahan pertama dari berkas raksasa ke src/ dilakukan oleh scripts/split-rc-source.mjs dan
 * dibuktikan identik byte per byte, sehingga peralihan ini tidak menghilangkan satu baris pun.
 *
 * Jalankan: node scripts/build-rc-frontend.mjs [--check]
 */
import { readFile, writeFile, mkdir, copyFile, readdir } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { bacaStruktur, bandingkanStruktur } from './rc-structure.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC_DIR = path.join(root, 'src');
const OUT_DIR = path.join(root, 'public');
const BASELINE = path.join(root, 'config', 'rc-structure-baseline.json');

// Penanda sengaja berbentuk komentar HTML biasa, supaya src/index.html tetap bisa dibuka dan
// dibaca sebagai HTML tanpa alat khusus.
const INCLUDE = /^([ \t]*)<!--#include\s+([^\s>]+)-->[ \t]*$/;

async function daftarBerkas(dir) {
  const hasil = [];
  for (const entri of await readdir(dir, { withFileTypes: true })) {
    const p = path.join(dir, entri.name);
    if (entri.isDirectory()) hasil.push(...await daftarBerkas(p));
    else hasil.push(p);
  }
  return hasil.sort();
}

// Dev server memakai daftar ini untuk memutuskan kapan perlu membangun ulang. Seluruh isi src/
// ikut diawasi, sehingga menyunting satu potongan mana pun langsung terasa di browser.
export const BUILD_INPUTS = [
  ...await daftarBerkas(SRC_DIR),
  path.join(root, 'scripts', 'rc-legacy-adapter.js'),
  path.join(root, 'config', 'rc-env.js'),
  // Logika build ikut diawasi: kalau berkas ini berubah, hasil build juga berubah.
  fileURLToPath(import.meta.url),
  path.join(root, 'scripts', 'rc-structure.mjs')
];
export const OUTPUT_DIR = OUT_DIR;

// Menyisipkan potongan, termasuk potongan di dalam potongan.
//
// Rekursi ditambahkan ketika panel Report dan dialog perbesar kartu menjadi berkas bersama:
// report.html menyisipkan view/parts/report-panes.html, sementara report.html sendiri
// disisipkan index.html. Tanpa rekursi, penanda di lapis kedua lolos apa adanya ke hasil build
// dan berakhir sebagai komentar HTML - halaman kehilangan seluruh panelnya tanpa satu pun pesan
// galat, yang justru cara paling buruk untuk gagal.
//
// Kedalamannya dibatasi supaya potongan yang tidak sengaja menyisipkan dirinya sendiri berhenti
// dengan pesan jelas, bukan menggantung.
async function rakit(rel, nl, dipakai, dariSiapa = 'src/index.html', kedalaman = 0) {
  if (kedalaman > 8) {
    throw new Error(`Penanda include terlalu dalam pada "${rel}". Ada potongan yang menyisipkan dirinya sendiri?`);
  }
  let isi;
  try {
    isi = await readFile(path.join(SRC_DIR, rel), 'utf8');
  } catch {
    throw new Error(`${dariSiapa} menyebut "${rel}", tetapi berkas itu tidak ada di src/.`);
  }
  if (kedalaman > 0) dipakai.push(rel);

  const keluar = [];
  for (const b of isi.split(/\r?\n/)) {
    const m = b.match(INCLUDE);
    // Potongan disisipkan apa adanya. Indentasinya sudah benar sejak dipecah, dan menambah
    // indentasi di sini justru akan merusak string multi-baris di dalam JavaScript.
    if (m) keluar.push(await rakit(m[2], nl, dipakai, rel, kedalaman + 1));
    else keluar.push(b);
  }
  return keluar.join(nl);
}

export async function buildFrontend({ check = false } = {}) {
  const shell = await readFile(path.join(SRC_DIR, 'index.html'), 'utf8');
  const nl = shell.includes('\r\n') ? '\r\n' : '\n';

  const dipakai = [];
  const built = await rakit('index.html', nl, dipakai);

  // ---- Paritas struktural ------------------------------------------------------------------
  const sekarang = bacaStruktur(built);
  let laporan = '';
  try {
    const base = JSON.parse(await readFile(BASELINE, 'utf8'));
    const beda = bandingkanStruktur(base, sekarang, base.sengajaDihapus || []);
    if (!beda.lolos) {
      const p = [];
      if (beda.hilangId.length) p.push(`id hilang: ${beda.hilangId.join(', ')}`);
      if (beda.hilangFungsi.length) p.push(`fungsi hilang: ${beda.hilangFungsi.join(', ')}`);
      throw new Error(
        'Menolak membangun: struktur halaman kehilangan sesuatu yang masih dipakai.\n  ' +
        p.join('\n  ') +
        '\n  Bila penghapusan ini memang disengaja, cantumkan namanya pada "sengajaDihapus"' +
        '\n  di config/rc-structure-baseline.json.');
    }
    const tambah = beda.tambahId.length + beda.tambahFungsi.length;
    laporan = `${dipakai.length} potongan, ${sekarang.ids.length} id, ${sekarang.fungsi.length} fungsi`
      + (tambah ? `, ${tambah} tambahan baru` : '')
      + (beda.izinBasi.length ? `, ${beda.izinBasi.length} izin hapus sudah usang` : '');
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
    laporan = `${dipakai.length} potongan, ${sekarang.ids.length} id, ${sekarang.fungsi.length} fungsi`
      + ' (baseline belum ada; jalankan node scripts/make-structure-baseline.mjs)';
  }

  // ---- Penjaga "satu sumber" ----------------------------------------------------------------
  // Pemilik meminta Claim Dashboard publik sama dengan modul Report "termasuk jika ada perubahan
  // ke depan". Yang menjaganya bukan ingatan siapa pun, melainkan pemeriksaan ini: setiap
  // potongan di src/view WAJIB benar-benar dipakai KEDUA halaman. Begitu salah satu berhenti
  // memakainya - misalnya seseorang menempelkan salinan panel ke salah satu halaman - build
  // berhenti dan menyebut nama berkasnya.
  const dipakaiPublik = [];
  const publik = await rakit('dashboard-publik.html', nl, dipakaiPublik, 'src/dashboard-publik.html');

  const berkasView = (await daftarBerkas(path.join(SRC_DIR, 'view')))
    .map((f) => path.relative(SRC_DIR, f).split(path.sep).join('/'));
  if (!berkasView.length) throw new Error('src/view kosong; lapisan tampilan bersama hilang.');

  for (const rel of berkasView) {
    // Berkas JS disisipkan index.html dan dipancarkan sebagai aset yang dimuat halaman publik
    // dengan <script src>, jadi ia tidak muncul pada daftar potongan halaman publik.
    const wajibPublik = !rel.endsWith('.js');
    const adaDiApp = dipakai.includes(rel);
    const adaDiPublik = dipakaiPublik.includes(rel);
    if (!adaDiApp || (wajibPublik && !adaDiPublik)) {
      throw new Error(
        `Menolak membangun: src/${rel} adalah potongan bersama, tetapi tidak dipakai `
        + `${!adaDiApp ? 'src/index.html' : 'src/dashboard-publik.html'}.\n`
        + '  Isi src/view harus dipakai portal DAN dashboard publik - itulah yang membuat\n'
        + '  keduanya tidak mungkin menyimpang. Tambahkan penandanya, atau keluarkan berkas\n'
        + '  itu dari src/view bila memang tidak lagi bersama.');
    }
  }

  laporan += `; ${berkasView.length} potongan bersama`;
  if (check) return `check: ${laporan}`;

  await mkdir(path.join(OUT_DIR, 'assets'), { recursive: true });
  await writeFile(path.join(OUT_DIR, 'index.html'), built);
  await copyFile(path.join(root, 'scripts', 'rc-legacy-adapter.js'),
    path.join(OUT_DIR, 'assets', 'rc-legacy-adapter.js'));
  // Konfigurasi peramban mengikuti lingkungan yang diminta. Bawaannya prod, sehingga build
  // tanpa bendera apa pun tetap menghasilkan halaman produksi persis seperti sebelumnya -
  // hanya "--env dev" yang menukarnya. Kalau berkas dev diminta tetapi tidak ada, build
  // BERHENTI: diam-diam jatuh ke config produksi berarti halaman dev berbicara ke database
  // sungguhan, dan itu tidak boleh terjadi tanpa ada yang tahu.
  // Vercel menjalankan buildCommand-nya SENDIRI, jadi build lokal tidak pernah ikut terkirim.
  // Karena itu lingkungan juga dibaca dari variabel RC_ENV_TARGET, yang disetel per project di
  // Vercel. Tanpa ini, project dev akan selalu membangun ulang dengan config produksi dan
  // diam-diam berbicara ke database sungguhan.
  const iEnv = process.argv.indexOf('--env');
  const envBuild = iEnv >= 0 ? process.argv[iEnv + 1]
    : (process.env.RC_ENV_TARGET || 'prod');
  const berkasEnv = envBuild === 'prod' ? 'rc-env.js' : `rc-env.${envBuild}.js`;
  const asalEnv = path.join(root, 'config', berkasEnv);
  try {
    await copyFile(asalEnv, path.join(OUT_DIR, 'assets', 'rc-env.js'));
  } catch {
    throw new Error(`config/${berkasEnv} tidak ada; build untuk lingkungan "${envBuild}" dihentikan.`);
  }
  // Halaman merujuk images/logo.png dan punya fallback ikon bila berkasnya hilang, sehingga
  // logo yang tidak tersalin tidak pernah terlihat sebagai error. Build menyalinnya supaya
  // logo asli yang tampil, bukan fallback itu.
  await mkdir(path.join(OUT_DIR, 'images'), { recursive: true });
  await copyFile(path.join(root, 'logo.png'), path.join(OUT_DIR, 'images', 'logo.png'));

  // Maskot pada kartu login. Berkasnya PNG bertransparansi - latar putih aslinya sudah dibuang -
  // sehingga ia menyatu dengan lingkaran putih di belakangnya tanpa kotak putih yang terlihat.
  // Sumbernya blooby.jpg di akar proyek; blobby.png inilah hasil olahannya dan yang dipakai.
  await copyFile(path.join(root, 'blobby.png'), path.join(OUT_DIR, 'images', 'blobby.png'));

  // ---- Lapisan tampilan bersama --------------------------------------------------------------
  // src/view/js/*.js sudah disisipkan ke dalam index.html lewat penanda include di atas.
  // Berkas yang sama juga dipancarkan sebagai satu aset, karena halaman kedua memuatnya dengan
  // <script src>, bukan menyisipkannya.
  //
  // Inilah yang membuat permintaan pemilik - dashboard publik sama dengan Report "termasuk jika
  // ada perubahan ke depan" - terpenuhi secara mekanis, bukan lewat kedisiplinan: kedua halaman
  // membaca berkas sumber yang sama, sehingga tidak ada cara untuk mengubah salah satunya saja.
  // Berkas view yang berupa JS sudah disisipkan ke dalam index.html lewat penanda include.
  // Berkas yang sama juga dipancarkan sebagai satu aset, karena halaman publik memuatnya dengan
  // <script src>, bukan menyisipkannya.
  //
  // Akhir barisnya diseragamkan seperti yang dilakukan penyisip di atas, supaya aset ini dapat
  // dibandingkan baris per baris dengan index.html - itulah cara membuktikan keduanya benar-benar
  // berasal dari sumber yang sama, bukan sekadar mirip.
  const view = [];
  for (const rel of berkasView.filter((r) => r.endsWith('.js'))) {
    view.push((await readFile(path.join(SRC_DIR, rel), 'utf8')).split(/\r?\n/).join(nl));
  }
  await writeFile(path.join(OUT_DIR, 'assets', 'rc-report-view.js'), view.join(nl));

  // Halaman kedua: Claim Dashboard yang dapat dibuka tanpa login, ditautkan dari email Weekly.
  await writeFile(path.join(OUT_DIR, 'dashboard.html'), publik);

  return `built public/index.html (${built.length} bytes); ${laporan}`
    + `; dashboard.html (${publik.length} bytes)`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  console.log(await buildFrontend({ check: process.argv.includes('--check') }));
}
