/*
 * Tests for the local development server. It starts the real server on an ephemeral port
 * and makes real requests, so a broken header or a path traversal hole fails here rather
 * than in a browser.
 *
 * Run: node --test scripts/test_dev_server.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import net from 'node:net';
import { readFile } from 'node:fs/promises';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

async function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once('error', reject);
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

const port = await freePort();
const base = `http://127.0.0.1:${port}`;
const child = spawn(process.execPath, [path.join(root, 'scripts', 'dev-server.mjs'), '--port', String(port)],
  { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });

// Wait for the listen line rather than sleeping a fixed amount.
await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('dev server did not start in time')), 30000);
  let out = '';
  child.stdout.on('data', (c) => {
    out += c.toString();
    if (out.includes('Press Ctrl+C')) { clearTimeout(timer); resolve(); }
  });
  child.on('exit', (code) => { clearTimeout(timer); reject(new Error(`dev server exited with ${code}`)); });
});

test.after(() => child.kill());

test('the root serves the built page, uncached', async () => {
  const res = await fetch(base + '/');
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /text\/html/);
  assert.equal(res.headers.get('cache-control'), 'no-store, must-revalidate');
  const html = await res.text();
  assert.match(html, /Resource Collection/);
  assert.match(html, /assets\/rc-legacy-adapter\.js/);
  // The sign-up portal the owner asked for must be present.
  assert.match(html, /Daftar di sini/);
  assert.match(html, /id="signupModal"/);
  // The transport must be the adapter, never a direct Apps Script call.
  assert.equal(html.includes('fetch(SCRIPT_URL'), false);
});

test('the security headers match the deployed configuration', async () => {
  const res = await fetch(base + '/');
  assert.equal(res.headers.get('x-frame-options'), 'DENY');
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
  const csp = res.headers.get('content-security-policy');
  assert.match(csp, /frame-ancestors 'none'/);
  assert.match(csp, /object-src 'none'/);
  // supabase-js is imported from jsDelivr at runtime and must not be blocked.
  assert.match(csp, /script-src[^;]*cdn\.jsdelivr\.net/);
  // The adapter talks to exactly these two backends and nothing else.
  assert.match(csp, /connect-src[^;]*vvojshgcduqlugngpzkj\.supabase\.co/);
  assert.match(csp, /connect-src[^;]*script\.google\.com/);
});

test('every portal route supports a direct request and refresh', async () => {
  const routing = await readFile(path.join(root, 'src/js/99-rute.js'), 'utf8');
  const paths = [...routing.matchAll(/\{\s*path:\s*'([^']+)'/g)].map(m => m[1]);
  assert.ok(paths.includes('/people-performance'));
  for (const route of paths) {
    const res = await fetch(base + route);
    assert.equal(res.status, 200, route + ' must serve the portal');
    assert.equal(res.headers.get('cache-control'), 'no-store, must-revalidate');
    assert.match(await res.text(), /id="modPeople"/);
  }
});

test('the adapter and the environment file are served', async () => {
  const adapter = await fetch(base + '/assets/rc-legacy-adapter.js');
  assert.equal(adapter.status, 200);
  assert.match(adapter.headers.get('content-type'), /javascript/);
  assert.match(await adapter.text(), /window\.RCBackend/);

  const env = await fetch(base + '/assets/rc-env.js');
  assert.equal(env.status, 200);
  // The flag lives here, so a stale copy would make a rollback look like it did nothing.
  assert.equal(env.headers.get('cache-control'), 'no-store, must-revalidate');
  const body = await env.text();
  assert.match(body, /vvojshgcduqlugngpzkj/);
  // A secret key here would be readable by every visitor. The file's own comments warn
  // about exactly that, so strip comments first and inspect the code that actually ships.
  const code = body.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  assert.equal(/sb_secret_/.test(code), false, 'a Supabase secret key is present');
  assert.equal(/service_role/i.test(code), false, 'a service_role key is present');
  // A service_role JWT is a signed token; a publishable key is not.
  assert.equal(/eyJ[A-Za-z0-9_-]{20,}\./.test(code), false, 'a JWT is present');
  assert.match(code, /supabasePublishableKey:\s*'sb_publishable_/);
});

test('a path outside public/ cannot be read', async () => {
  for (const attack of ['/../config/rc-env.js', '/..%2f..%2fpackage.json', '/assets/../../package.json']) {
    const res = await fetch(base + attack, { redirect: 'manual' });
    assert.ok(res.status === 403 || res.status === 404, `${attack} returned ${res.status}`);
    const body = await res.text();
    assert.equal(body.includes('"name": "rc-next-gen"'), false, `${attack} leaked package.json`);
  }
});

test('an unknown path is a plain 404 and writes are refused', async () => {
  const missing = await fetch(base + '/tidak-ada.html');
  assert.equal(missing.status, 404);
  const write = await fetch(base + '/', { method: 'POST' });
  assert.equal(write.status, 405);
});

test('the inline script of the built page parses', async () => {
  // Modul baru menyuntikkan ratusan baris JavaScript ke dalam <script> inline halaman.
  // Satu kurung yang salah akan mematikan SELURUH halaman, bukan hanya modul itu, jadi
  // hasil build diurai dengan parser sungguhan sebelum sempat sampai ke browser.
  const html = await (await fetch(base + '/')).text();
  const rapat = html.split(String.fromCharCode(32)).filter(Boolean).join(String.fromCharCode(32));
  const blocks = [...html.matchAll(/<script(?![^>]*src=)[^>]*>([\s\S]*?)<\/script>/gi)]
    .map((m) => m[1]).filter((code) => code.trim().length > 0);
  assert.ok(blocks.length >= 1, 'halaman harus punya script inline');
  const { default: vm } = await import('node:vm');
  for (const code of blocks) {
    assert.doesNotThrow(() => new vm.Script(code), 'script inline harus dapat diurai');
  }
  // Fungsi yang dipanggil dari atribut onclick harus benar-benar ada di sumbernya.
  for (const fn of ['openRcModule', 'switchKeyMasterTab', 'openRcRowEditor', 'saveRcRowEditor',
    'downloadCustomerTemplate', 'previewCustomerUpload', 'commitCustomerUpload',
    'downloadCampaignTemplate', 'previewCampaignUpload', 'commitCampaignUpload',
    'loadCompilation', 'archiveCompilationRows', 'toggleArchivedList', 'unarchiveCompilationRow',
    'toggleAllCompilation', 'updateCompSelection', 'cancelMasterUpload', 'closeRcRowEditor',
    'openRcOpenTab', 'loadOpenClaims', 'toggleAllOpen', 'updateOpenSelection',
    'openToMassUpload', 'openToTemplate', 'renderPermissionMatrix', 'rcMatrixValues',
    'downloadCompileTemplate', 'previewCompileUpload', 'commitCompileUpload']) {
    assert.ok(html.includes('function ' + fn + '('), fn + ' dipanggil dari markup tapi tidak didefinisikan');
  }
});

test('every element the new modules address exists in the markup', async () => {
  const html = await (await fetch(base + '/')).text();
  for (const id of ['modKeyMaster', 'modCompilation', 'menuKeyMaster', 'menuCompilation',
    'kmTabCustomer', 'kmTabCampaign', 'kmPanelCustomer', 'kmPanelCampaign',
    'customerSearch', 'customerTableBody', 'customerPager', 'customerFile',
    'customerUploadInfo', 'customerUploadText', 'btnCommitCustomer',
    'campaignSearch', 'campaignTableBody', 'campaignPager', 'campaignFile',
    'campaignUploadInfo', 'campaignUploadText', 'btnCommitCampaign',
    'compCampaign', 'compBatch', 'compStatus', 'compSearch', 'compSummary',
    'compTableBody', 'compPager', 'compArchiveBar', 'compArchiveReason',
    'btnArchiveComp', 'compSelectedCount', 'compSelectAll', 'compArchivedPanel',
    'compArchivedBody', 'btnArchivedList', 'rcRowEditorModal', 'rcRowEditorTitle',
    'rcRowEditorFields', 'rcRowEditorError', 'rcRowEditorErrorText', 'btnSaveRcRow',
    'editSuffix', 'tab_open', 'subnav_open', 'openSearch', 'openCampaign', 'openTableBody',
    'openPager', 'openSelectAll', 'openSelectedCount', 'btnOpenToMass', 'btnOpenToTemplate',
    'editModuleMatrix', 'editModuleMatrixContainer', 'compileFile', 'btnCommitCompile',
    'compileResult', 'editRoleInput', 'editAssignDepotContainer']) {
    assert.ok(html.includes('id="' + id + '"'), 'elemen id ' + id + ' tidak ada di markup');
  }
});

test('the Document Center card is gone and the roles are complete', async () => {
  const html = await (await fetch(base + '/')).text();
  // Kartu Document Center dihapus atas instruksi pemilik; jejak menu dan URL-nya harus ikut hilang.
  assert.equal(html.includes('id="menuPrintDoc"'), false, 'kartu Document Center masih ada');
  assert.equal(html.includes('Print-Document'), false, 'tautan Document Center masih ada');
  // Peran System Manager harus dapat dipilih pada konsol Otorisasi.
  assert.ok(html.includes('<option value="system manager">System Manager</option>'),
    'opsi System Manager tidak ada pada konsol');
  // Depot pendaftaran memakai daftar, bukan isian bebas.
  assert.ok(html.includes('<select id="signupDepot"'), 'depot pendaftaran masih input bebas');
  assert.ok(html.includes('function loadSignupDepots('), 'pemuat daftar depot tidak ada');
});

test('the logo is served at the path the page references', async () => {
  // Halaman punya fallback ikon bila logo gagal dimuat, sehingga logo yang hilang tidak
  // pernah tampak sebagai error. Tanpa test ini kegagalannya akan senyap.
  const html = await (await fetch(base + '/')).text();
  assert.ok(html.includes('src="images/logo.png"'), 'halaman tidak merujuk logo');
  const res = await fetch(base + '/images/logo.png');
  assert.equal(res.status, 200, 'logo tidak tersaji');
  assert.match(res.headers.get('content-type'), /image\/png/);
  const buf = Buffer.from(await res.arrayBuffer());
  assert.ok(buf.length > 1000, 'berkas logo terlalu kecil untuk sebuah PNG');
  assert.equal(buf.subarray(1, 4).toString('ascii'), 'PNG', 'bukan berkas PNG yang sah');
});

test('status colours come from one shared map', async () => {
  const html = await (await fetch(base + '/')).text();
  const rapat = html.split(String.fromCharCode(32)).filter(Boolean).join(String.fromCharCode(32));
  assert.ok(html.includes('function rcStatusClass('), 'peta warna bersama tidak ada');
  // Warna yang diminta pemilik: Submitted oranye, Released kuning, Claimed biru, Done hijau.
  for (const [status, cls] of [['submitted', 'orange'], ['released', 'yellow'],
    ['claimed', 'blue'], ['done', 'green'], ['not yet', 'gray']]) {
    // Jarak spasi pada peta diratakan lebih dulu supaya pengujian menguji warnanya,
    // bukan perataan kode.
    assert.ok(rapat.includes("'" + status + "': 'bg-" + cls + "-"),
      status + ' harus berwarna ' + cls);
  }
  // Peta warna lama yang saling bertentangan harus sudah tidak dipakai.
  assert.equal(html.includes("Claimed: 'bg-purple-100 text-purple-800'"), false,
    'peta warna Bulk Process yang lama masih ada');
  assert.ok(html.includes('rcStatusClass(d.status)'), 'History belum memakai peta bersama');
});

test('long identifiers never render or export as exponent notation', async () => {
  const html = await (await fetch(base + '/')).text();
  assert.ok(html.includes('function rcFull('), 'pemformat angka penuh tidak ada');
  // Nomor batch 15 digit dan identitas panjang ditulis sebagai teks di Excel.
  assert.ok(html.includes('fmt: null, text: true'), 'penanda teks untuk angka panjang tidak ada');
  assert.ok(html.includes("z: '@' }"), 'format teks Excel tidak diterapkan');

  // Perilaku rcFull diuji langsung, bukan hanya keberadaannya. Sumbernya diambil dengan
  // pencarian teks, bukan regex, karena escape di dalam regex berulang kali rusak.
  const mulai = html.indexOf('function rcFull(v) {');
  assert.ok(mulai > 0, 'sumber rcFull tidak ditemukan');
  // rcFull diikuti komentar penanda bagian berikutnya; itulah batas potongannya.
  const akhir = html.indexOf('---------- Compile cashback ----------', mulai);
  assert.ok(akhir > mulai, 'batas akhir rcFull tidak ditemukan');
  const potongan = html.slice(mulai, html.lastIndexOf('}', akhir) + 1);
  const { default: vm } = await import('node:vm');
  const ctx = { hasil: null };
  vm.createContext(ctx);
  vm.runInContext(potongan + ';hasil=[rcFull(100117092600012),rcFull("1.00117E+14"),rcFull("010011709260001"),rcFull(null)];', ctx);
  assert.equal(ctx.hasil[0], '100117092600012', 'angka besar harus utuh');
  assert.equal(ctx.hasil[1], '100117000000000', 'teks eksponen harus kembali ke digit penuh');
  assert.equal(ctx.hasil[2], '010011709260001', 'nol di depan harus dipertahankan');
  assert.equal(ctx.hasil[3], '', 'nilai kosong tetap kosong');
});

test('no status colour is decided anywhere except the shared map', async () => {
  // Badge status di tabel Analytics sempat terlewat karena saya mencari berdasarkan yang
  // sudah saya ketahui, bukan menyapu seluruh halaman. Pengujian ini menyapu: bila ada satu
  // pun tempat yang memutuskan warna dari status di luar rcStatusClass, ia gagal.
  const html = await (await fetch(base + '/')).text();
  const jejak = ["status === 'Done' ? 'bg-", "status === 'Not Yet' ? 'bg-",
    "status === 'Submitted' ? 'bg-", "Claimed: 'bg-", "Released: 'bg-"];
  for (const j of jejak) {
    assert.equal(html.includes(j), false, 'masih ada penentu warna status sendiri: ' + j);
  }
  // Dan seluruh pemanggil memakai peta bersama.
  const pakai = html.split('rcStatusClass(').length - 1;
  assert.ok(pakai >= 5, 'peta warna bersama dipakai di ' + pakai + ' tempat, terlalu sedikit');
});
