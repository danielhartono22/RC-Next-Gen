/*
 * Membuktikan Claim Dashboard publik benar-benar tergambar.
 *
 * MENGAPA PERLU DIUJI TERSENDIRI
 * Halaman publik memakai panel, filter dan penggambar yang sama dengan modul Report, tetapi dari
 * dokumen yang berbeda: potongannya disisipkan build, penggambarnya dimuat sebagai <script src>,
 * dan datanya datang dari satu RPC alih-alih tiga. Bila salah satu sambungan itu putus - sebuah
 * id berubah, bentuk jawaban RPC bergeser, sebuah fungsi tertinggal di berkas yang tidak ikut
 * dipancarkan - halamannya tidak melempar galat yang terlihat. Ia hanya tampil kosong, dan yang
 * menemukannya adalah penerima email, bukan kita.
 *
 * Build sudah menjaga bahwa kedua halaman memakai potongan yang sama. Yang dijaga di sini hal
 * lain: bahwa potongan itu, dijalankan sebagaimana halaman publik menjalankannya, memang mengisi
 * panelnya.
 *
 * CARA KERJANYA
 * Yang dijalankan bukan fungsi penggambar satu per satu, melainkan skrip halaman itu sendiri -
 * titik masuknya, dengan fetch dipalsukan oleh jawaban RPC yang sungguhan. Dengan begitu jalur
 * yang diuji sama dengan jalur yang ditempuh pengunjung: alamat -> switchReportTab -> loadReport
 * -> filterReport -> penggambar.
 *
 * DOM-nya tiruan, dan getElementById hanya mengakui id yang benar-benar ada pada
 * public/dashboard.html - sehingga salah ketik tertangkap alih-alih diam-diam menulis ke elemen
 * bayangan.
 *
 * Uji ini memerlukan jaringan. Bila RPC tidak dapat dihubungi, ia dilewati dengan keterangan;
 * gagal karena tidak ada koneksi bukan kabar yang berguna.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import vm from 'node:vm';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ASET = path.join(root, 'public', 'assets', 'rc-report-view.js');
const HALAMAN = path.join(root, 'public', 'dashboard.html');

// Jumlah grafik yang harus tergambar. Angkanya sengaja dikunci: menambah grafik di panel bersama
// berarti angka ini ikut naik, dan itu memaksa orang yang menambahnya memastikan grafik itu
// muncul di KEDUA halaman, bukan hanya di portal.
const JUMLAH_GRAFIK = 11;

const PANEL_WAJIB = ['rtKpi', 'rtPerformaBody', 'rtRegionBody', 'rtDepotTblBody',
  'rtCc1Body', 'rtCc2Body'];

// Bilah filter bersama. Halaman publik harus memilikinya - pemilik memintanya secara khusus -
// dan filterReport() membacanya, jadi ketiadaannya membuat filter diam-diam tidak berfungsi.
const FILTER_WAJIB = ['rtRegion', 'rtDepot', 'rtCampaign'];

function konfigEnv() {
  const s = readFileSync(path.join(root, 'config', 'rc-env.js'), 'utf8');
  const url = s.match(/supabaseUrl\s*:\s*['"]([^'"]+)['"]/);
  const key = s.match(/supabasePublishableKey\s*:\s*['"]([^'"]+)['"]/);
  return { url: url && url[1], key: key && key[1] };
}

async function ambilData(filter) {
  const { url, key } = konfigEnv();
  if (!url || !key) return null;
  try {
    const res = await fetch(url + '/rest/v1/rpc/rc_dashboard_publik', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: key, Authorization: 'Bearer ' + key },
      body: JSON.stringify({ p_filter: filter || {} }),
      signal: AbortSignal.timeout(20000)
    });
    if (!res.ok) return null;
    return await res.json();
  } catch { return null; }
}

// DOM tiruan secukupnya: yang ditagih halaman hanyalah menulis innerHTML/innerText, membaca
// value pada bilah filter, dan membuat grafik.
function buatPanggung(halaman) {
  const idAda = new Set([...halaman.matchAll(/id="([A-Za-z0-9_]+)"/g)].map((m) => m[1]));
  const peta = new Map();
  const digambar = [];
  const ditulis = new Set();

  const buatEl = (id) => ({
    id, _html: '', innerText: '', value: '', dataset: {}, className: '', style: {},
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    cells: [], rows: [], tBodies: [], tHead: null, options: [],
    get innerHTML() { return this._html; },
    set innerHTML(v) { this._html = String(v); ditulis.add(id); },
    querySelector: () => null, querySelectorAll: () => [],
    insertAdjacentHTML() {}, addEventListener() {}, appendChild() {},
    getContext: () => ({}), closest: () => null, remove() {}
  });

  const document = {
    getElementById(id) {
      if (!idAda.has(id)) return null;
      if (!peta.has(id)) peta.set(id, buatEl(id));
      return peta.get(id);
    },
    querySelectorAll: () => [],
    createElement: () => buatEl('baru'),
    createComment: () => ({ parentNode: null, remove() {} }),
    addEventListener() {},
    body: buatEl('body')
  };

  class Chart {
    constructor(_ctx, konfig) {
      // Chart.js tidak mengeluh bila datasetnya cacat; ia hanya menggambar kanvas kosong.
      assert.ok(konfig && konfig.data && Array.isArray(konfig.data.datasets),
        'konfigurasi grafik tanpa data.datasets');
      konfig.data.datasets.forEach((d, i) =>
        assert.ok(Array.isArray(d.data), `dataset ke-${i} bukan larik`));
      digambar.push(konfig);
      this.destroy = () => {};
      this.resize = () => {};
    }
    static getChart() { return null; }
  }

  const ctx = vm.createContext({ document, Chart, console, setTimeout, clearTimeout,
    location: { pathname: '/dashboard' }, history: { pushState() {} } });
  ctx.addEventListener = () => {};
  ctx.window = ctx;
  ctx.globalThis = ctx;
  return { ctx, peta, digambar, ditulis, idAda };
}

function skripHalaman(halaman) {
  // Skrip sebaris halaman - blok <script> terakhir, yang tidak punya atribut src.
  const blok = [...halaman.matchAll(/<script>\r?\n([\s\S]*?)\r?\n<\/script>/g)];
  assert.ok(blok.length > 0, 'halaman publik tidak punya skrip sebaris');
  return blok[blok.length - 1][1];
}

test('dashboard publik: halaman menggambar dirinya dari data asli', async (t) => {
  if (!existsSync(ASET) || !existsSync(HALAMAN)) {
    return t.skip('public/ belum dibangun; jalankan npm run build lebih dulu.');
  }
  const data = await ambilData();
  if (!data || data.status !== 'success') {
    return t.skip('rc_dashboard_publik tidak dapat dihubungi; uji ini memerlukan jaringan.');
  }

  const halaman = readFileSync(HALAMAN, 'utf8');
  const { ctx, peta, digambar, ditulis, idAda } = buatPanggung(halaman);

  for (const id of FILTER_WAJIB) {
    assert.ok(idAda.has(id), `bilah filter bersama tidak ada di halaman publik: ${id}`);
  }

  // fetch dipalsukan oleh jawaban RPC yang sungguhan, sehingga yang diuji adalah jalur halaman -
  // bukan rangkaian pemanggilan yang disusun ulang oleh uji ini.
  const diminta = [];
  ctx.fetch = (url, opsi) => {
    diminta.push(JSON.parse(opsi.body));
    return Promise.resolve({ ok: true, json: () => Promise.resolve(data) });
  };
  ctx.RC_ENV = { supabaseUrl: 'https://contoh.invalid', supabasePublishableKey: 'kunci' };

  vm.runInContext(readFileSync(ASET, 'utf8'), ctx, { filename: 'rc-report-view.js' });
  vm.runInContext(skripHalaman(halaman), ctx, { filename: 'dashboard.html' });

  // loadReport() asinkron; beri kesempatan janjinya selesai.
  await new Promise((r) => setTimeout(r, 50));

  assert.equal(diminta.length, 1, 'halaman seharusnya memanggil RPC tepat sekali saat dibuka');
  assert.ok(diminta[0] && typeof diminta[0].p_filter === 'object',
    'RPC dipanggil tanpa p_filter; bilah filter tidak tersambung');

  for (const id of PANEL_WAJIB) {
    assert.ok(ditulis.has(id), `${id} tidak pernah diisi penggambar`);
    assert.ok(peta.get(id).innerHTML.trim().length > 0, `${id} terisi tetapi kosong`);
  }

  assert.equal(digambar.length, JUMLAH_GRAFIK,
    `seharusnya ${JUMLAH_GRAFIK} grafik pada halaman publik, tergambar ${digambar.length}. `
    + 'Bila sebuah grafik memang ditambah atau dihapus di panel bersama, sesuaikan '
    + 'JUMLAH_GRAFIK - dan pastikan grafik itu muncul di kedua halaman.');

  // Batas yang tidak boleh dilanggar: data pribadi tidak sampai tergambar.
  const semua = [...peta.values()].map((e) => e.innerHTML).join('\n');
  assert.ok(!/KTP|NPWP|No Rekening|Nama Rekening/i.test(semua),
    'data pribadi muncul pada keluaran halaman publik');
});

test('dashboard publik: filter benar-benar mempersempit di sisi server', async (t) => {
  const semua = await ambilData();
  if (!semua || semua.status !== 'success') {
    return t.skip('rc_dashboard_publik tidak dapat dihubungi; uji ini memerlukan jaringan.');
  }
  const baris = (semua.cc1 && semua.cc1.rows) || [];
  if (!baris.length) return t.skip('belum ada data untuk diuji.');

  const depot = baris[0].kodeDepot;
  const saring = await ambilData({ depot });
  assert.ok(saring && saring.status === 'success', 'pemanggilan dengan filter gagal');

  const n = (saring.cc1.rows || []).length;
  assert.ok(n > 0, `filter depot ${depot} menghasilkan nol baris`);
  assert.ok(n < baris.length,
    `filter depot ${depot} tidak mempersempit (${n} dari ${baris.length})`);
  assert.ok((saring.cc1.rows || []).every((r) => r.kodeDepot === depot),
    'hasil tersaring memuat depot lain');
});

test('dashboard publik memuat penggambar bersama, bukan salinannya', () => {
  if (!existsSync(HALAMAN) || !existsSync(ASET)) return;
  const halaman = readFileSync(HALAMAN, 'utf8');
  assert.match(halaman, /<script src="\/assets\/rc-report-view\.js"><\/script>/,
    'halaman publik tidak memuat /assets/rc-report-view.js');

  // Setiap baris berarti dari aset bersama harus ada pula di dalam index.html. Inilah bukti
  // bahwa keduanya berasal dari berkas sumber yang sama, bukan sekadar mirip.
  const app = readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
  const baris = readFileSync(ASET, 'utf8').split('\n').filter((l) => l.trim().length > 3);
  const hilang = baris.filter((l) => !app.includes(l));
  assert.equal(hilang.length, 0,
    `${hilang.length} baris penggambar bersama tidak ada di portal, contoh: ${hilang[0]}`);
});
