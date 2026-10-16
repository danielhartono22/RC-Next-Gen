/*
 * Unit tests for the value conversions the legacy adapter performs between the Resource
 * Collection user interface and the Supabase RPC contract. These are the places where a
 * silent coercion would change a business value, so each one must either convert exactly
 * or refuse. No network and no database are involved.
 *
 * Run: node --test scripts/test_rc_legacy_adapter.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import path from 'node:path';
import { webcrypto } from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const code = await readFile(path.join(root, 'scripts', 'rc-legacy-adapter.js'), 'utf8');

const sandbox = { window: {}, crypto: webcrypto, TextEncoder, fetch: () => { throw new Error('no network in tests'); } };
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(code, sandbox);
const rc = sandbox.window.RCBackend._test;
// Values built inside the vm realm have a different Object.prototype, so normalise before
// comparing structures; this does not hide any difference in the data itself.
const plain = (value) => JSON.parse(JSON.stringify(value));

test('grid dates convert to ISO without inventing a value', () => {
  assert.equal(rc.toIsoDate('15-04-2026'), '2026-04-15');
  assert.equal(rc.toIsoDate('2026-04-15'), '2026-04-15');
  assert.equal(rc.toIsoDate(''), null);
  assert.equal(rc.toIsoDate(null), null);

  // dd-mm-yy dulu ditolak; sejak pemilik menetapkan enam bentuk resmi, ia sah.
  assert.equal(rc.toIsoDate('15-04-26'), '2026-04-15');
});

test('an unrecognised date is refused instead of guessed', () => {
  assert.throws(() => rc.toIsoDate('15 April 2026'), /tidak dikenali/);

  // Garis miring DULU diterima dan kini ditolak, atas ketetapan pemilik. Justru bentuk inilah
  // yang paling berbahaya: 5/4/2026 dibaca 5 April di Indonesia dan 4 Mei di Amerika, dan
  // keduanya sama-sama masuk akal - jadi tidak ada cara aman menebaknya.
  assert.throws(() => rc.toIsoDate('5/4/2026'), /tidak dikenali/);
  assert.throws(() => rc.toIsoDate('2026/04/15'), /tidak dikenali/);
});

test('billing months convert from the Mon-YY form the page produces', () => {
  assert.equal(rc.toIsoMonth('Apr-26'), '2026-04');
  assert.equal(rc.toIsoMonth('Des-26'), '2026-12');
  assert.equal(rc.toIsoMonth('May-2026'), '2026-05');
  assert.equal(rc.toIsoMonth('2026-04'), '2026-04');
  assert.equal(rc.toIsoMonth(''), null);
  assert.throws(() => rc.toIsoMonth('Xyz-26'), /tidak dikenali/);
});

test('login address is the documented SHA-256 of the trimmed user ID', async () => {
  // Fixed vector so a change to the derivation cannot pass unnoticed; it must match the
  // addresses already imported into auth.users by 20260915064525_rc_userid_auth_password_gate.
  assert.equal(
    await rc.loginEmail('  RC001 '),
    '40538eb9c44e104284c814543d06137c3f13a94d2f9cdea5bf532a1e5e06d7fa@rc-login.invalid'
  );
});

test('a submit row maps onto the RPC item contract', () => {
  rc.setVersion('DOC-001', 7);
  const item = rc.submitItem({
    noDoc: 'DOC-001', subyekPajak: 'Badan', totTagih: 1500000, tglLunas: '15-04-2026',
    approval: 'NSM', ktp: '', npwp: '012345678901234', bankCust: 'BCA',
    // approval sengaja tetap dikirimkan halaman lama; lihat pernyataan di bawah.
    noRekening: '0081234567', pemilikRekening: 'TOKO ABC', top: '30',
    blnTagih1: 'Apr-26', blnTagih2: 'May-26', blnTagih3: '', blnTagih4: ''
  });
  assert.deepEqual(plain(item), {
    no_doc: 'DOC-001', version_no: 7, tax_subject: 'Badan', total_billing: 1500000,
    paid_on: '2026-04-15', npwp: '012345678901234', bank: 'BCA',
    account_number: '0081234567', account_name: 'TOKO ABC', top: '30',
    billing_months: ['2026-04', '2026-05']
  });
  // Empty KTP must be absent, not an empty string that would overwrite stored data.
  assert.equal('ktp' in item, false);

  // Kolom Approval dicabut dari unggahan atas instruksi pemilik: seluruh dokumen boleh diunggah
  // berapa pun TOP-nya, dan layak-tidaknya ditentukan di modul Management of Approval. Baris di
  // atas tetap memuat approval untuk membuktikan adapter MENGABAIKANNYA - bukan meneruskannya
  // diam-diam ke server bila suatu saat ada layar lama yang masih mengirimkannya.
  assert.equal('approval' in item, false);
  // A leading zero on the account number survives as text.
  assert.equal(item.account_number, '0081234567');
});

test('only a typed Jenis CB is sent, never the Campaign Master value', () => {
  rc.setVersion('DOC-003', 2);

  // Terisi otomatis dari Campaign Master: jenisCashback ada, jenisCashbackInput kosong.
  // Field ini TIDAK boleh ikut dikirim - server akan memakai Campaign Master sendiri, yang
  // mengenali nama lama seperti Voucher. Mengirimnya berarti dokumen sah ditolak.
  const otomatis = rc.submitItem({ noDoc: 'DOC-003', jenisCashback: 'Voucher', jenisCashbackInput: '' });
  assert.equal('jenis_cashback' in otomatis, false);

  // Diketik pengguna: dikirim apa adanya, karena inilah yang menimpa Campaign Master.
  const diketik = rc.submitItem({ noDoc: 'DOC-003', jenisCashback: 'RA07', jenisCashbackInput: 'RA07' });
  assert.equal(diketik.jenis_cashback, 'RA07');
});

test('toIsoDate menerima enam bentuk resmi dan bentuk kanonik layar', () => {
  const diterima = {
    '22-Jan-2026': '2026-01-22',   // bentuk kanonik keluaran normalizeDateUI
    '22.01.2026': '2026-01-22',
    '22-01-2026': '2026-01-22',
    '22.01.26': '2026-01-22',
    '22-01-26': '2026-01-22',
    '220126': '2026-01-22',
    '22012026': '2026-01-22',
    '2026-01-22': '2026-01-22',    // ISO, dipakai antar-mesin
    '1-2-2026': '2026-02-01'       // satu digit tetap sah
  };
  for (const [masuk, keluar] of Object.entries(diterima)) {
    assert.equal(rc.toIsoDate(masuk), keluar, masuk + ' seharusnya ' + keluar);
  }
});

test('toIsoDate menolak bentuk di luar daftar, dan tanggal yang tidak ada', () => {
  // Garis miring TIDAK termasuk enam bentuk yang ditetapkan pemilik. Ia dulu diterima, dan
  // justru itu bahayanya: 01/02/2026 ambigu antara 1 Februari dan 2 Januari.
  for (const buruk of ['22/01/2026', 'Jan-22-2026', '2026/01/22', '22 Jan 2026', '22-Januari-2026', 'kemarin', '1234']) {
    assert.throws(() => rc.toIsoDate(buruk), /tidak dikenali/, buruk + ' seharusnya ditolak');
  }
  // Pola benar, tanggalnya tidak ada dalam kalender
  for (const buruk of ['31-04-2026', '29-02-2027', '00-01-2026']) {
    assert.throws(() => rc.toIsoDate(buruk), /tidak ada dalam kalender|tidak dikenali/, buruk + ' seharusnya ditolak');
  }
  assert.equal(rc.toIsoDate(''), null);
  assert.equal(rc.toIsoDate(null), null);
});

test('an unknown document is refused rather than submitted without a version', () => {
  assert.throws(() => rc.submitItem({ noDoc: 'DOC-NOT-LOADED' }), /belum dimuat/);
});

test('a negative billing value is refused', () => {
  rc.setVersion('DOC-002', 1);
  assert.throws(() => rc.submitItem({ noDoc: 'DOC-002', totTagih: -5 }), /tidak valid/);
});

test('every legacy action the page can send has a handler', async () => {
  // Daftarnya DITURUNKAN dari halaman hasil build, bukan ditulis tangan.
  //
  // Versi sebelumnya memuat daftar tetap yang disalin sekali dari hasil grep. Daftar seperti
  // itu tidak mungkin menangkap aksi BARU: tujuh aksi yang ditambahkan ke layar dalam satu
  // hari - campaignDelete, campaignMemoUpload, campaignMemoUrl, campaignMemoClear,
  // timetableNotAchieved, emailCancel dan accountDelete - semuanya lolos tanpa penanganan di
  // adapter, dan tesnya tetap hijau. Di layar akibatnya tombol yang menjawab
  // "Aksi tidak tersedia pada backend Supabase".
  //
  // Dengan menurunkannya dari halaman, menambah tombol tanpa menambah penanganannya langsung
  // menjatuhkan tes ini.
  const html = await readFile(path.join(root, 'public', 'index.html'), 'utf8');
  const aksi = [...new Set([...html.matchAll(/\baction:\s*'([A-Za-z][A-Za-z0-9_]*)'/g)].map((m) => m[1]))];
  assert.ok(aksi.length > 30, 'halaman harus mengirim puluhan aksi; ditemukan ' + aksi.length);

  const tanpaPenanganan = [];
  for (const action of aksi) {
    const res = await sandbox.window.RCBackend.call({ action });
    if (res && res.message === 'Aksi tidak tersedia pada backend Supabase: ' + action) {
      tanpaPenanganan.push(action);
    }
  }
  assert.deepEqual(tanpaPenanganan, [],
    'aksi berikut dikirim halaman tetapi tidak ada penanganannya di adapter: ' + tanpaPenanganan.join(', '));
});

test('sign up refuses a short PIN and a mismatched confirmation before any network call', async () => {
  // The vm sandbox throws on fetch, so reaching the network at all would fail the test.
  const short = await sandbox.window.RCBackend.call({
    action: 'signUp', data: { userId: 'RC900', pin: 'abc123', pinConfirm: 'abc123' }
  });
  assert.equal(short.status, 'error');
  assert.match(short.message, /minimal 8/);

  const mismatch = await sandbox.window.RCBackend.call({
    action: 'signUp', data: { userId: 'RC900', pin: 'abcd1234', pinConfirm: 'abcd9999' }
  });
  assert.equal(mismatch.status, 'error');
  assert.match(mismatch.message, /tidak sama/);
});

// ---------------------------------------------------------------------------------------
// Muat bertahap (20261162050000): kursor diteruskan apa adanya, compileData disusun dari
// history, dan database yang belum dimigrasi tetap dilayani versi lamanya.
// ---------------------------------------------------------------------------------------
function halamanBackend(jawab) {
  const panggilan = [];
  const c = { window: {}, crypto: webcrypto, TextEncoder,
    __testClient: { rpc: async (nama, arg) => { panggilan.push({ nama, arg: plain(arg || {}) }); return jawab(nama, arg || {}); } } };
  vm.createContext(c);
  vm.runInContext(code.replace('var clientPromise = null;', 'var clientPromise = Promise.resolve(__testClient);'), c);
  return { call: c.window.RCBackend.call, panggilan };
}

test('workflow pages forward page size and cursor unchanged', async () => {
  const kosong = { status: 'success', releaseData: [], claimFinData: [], clearingData: [], bulkRebateData: [], dimuat: 0, berikutnya: null };
  const { call, panggilan } = halamanBackend(() => ({ data: kosong }));
  await call({ action: 'getWorkflowData', limit: 300 });
  await call({ action: 'getWorkflowData', setelah: { waktu: '2026-09-29T01:02:03.456789+00:00', id: 'a1b2' } });
  assert.deepEqual(panggilan, [
    { nama: 'rc_legacy_workflow', arg: { p_limit: 300 } },
    { nama: 'rc_legacy_workflow', arg: { p_limit: 1000, p_setelah_waktu: '2026-09-29T01:02:03.456789+00:00', p_setelah_id: 'a1b2' } }
  ]);
});

test('analytics compileData is built from the same history rows', async () => {
  const h = { noDoc: 'N1', depot: 'Depot Satu', codeCampaign: 'C1', campaign: 'Campaign Satu',
              validYear: '2026', totalClaim: 1500.5, kodeToko: 'T1', status: 'Done' };
  const { call } = halamanBackend(() => ({ data: { status: 'success', history: [h], dimuat: 1, berikutnya: null } }));
  const res = await call({ action: 'getDashboardData' });
  assert.deepEqual(plain(res.compileData), [
    { depotName: 'Depot Satu', codeCampaign: 'C1', campaign: 'Campaign Satu', validYear: '2026', reward: 1500.5, kodeToko: 'T1' }
  ]);
});

test('an unmigrated database falls back to the single-call RPC', async () => {
  const dariServer = [{ depotName: 'D', codeCampaign: 'C', campaign: 'X', validYear: '2025', reward: 1, kodeToko: 'T' }];
  const { call, panggilan } = halamanBackend((nama, arg) => arg.p_limit
    ? { error: { message: 'Could not find the function public.rc_legacy_dashboard(p_limit) in the schema cache' } }
    : { data: { status: 'success', history: [], compileData: dariServer } });
  const res = await call({ action: 'getDashboardData', limit: 300 });
  assert.equal(res.status, 'success');
  assert.deepEqual(plain(res.compileData), dariServer);
  assert.deepEqual(panggilan.map((p) => p.arg), [{ p_limit: 300 }, {}]);
});

test('a failure on a later page is reported, never silently replaced', async () => {
  const { call, panggilan } = halamanBackend(() => ({ error: { message: 'Could not find the function public.rc_legacy_workflow' } }));
  const res = await call({ action: 'getWorkflowData', setelah: { waktu: '2026-09-29T00:00:00+00:00', id: 'x' } });
  assert.equal(res.status, 'error');
  assert.equal(panggilan.length, 1);
});

// ---------------------------------------------------------------------------------------
// Akun suspended (20261162110000): salah PIN dicatat server, akun suspended tidak bisa masuk.
// ---------------------------------------------------------------------------------------
function loginBackend(jawabAuth, jawabRpc) {
  const panggilan = []; let keluar = 0;
  const c = { window: {}, crypto: webcrypto, TextEncoder,
    __testClient: {
      auth: { signInWithPassword: async () => jawabAuth(), signOut: async () => { keluar++; return {}; } },
      rpc: async (nama, arg) => { panggilan.push({ nama, arg: plain(arg || {}) }); return jawabRpc(nama, arg || {}); } } };
  vm.createContext(c);
  vm.runInContext(code.replace('var clientPromise = null;', 'var clientPromise = Promise.resolve(__testClient);'), c);
  return { call: c.window.RCBackend.call, panggilan, keluar: () => keluar };
}

test('a third wrong PIN reports the suspension from the server', async () => {
  const { call, panggilan } = loginBackend(
    () => ({ error: { code: 'invalid_credentials', message: 'Invalid login credentials' } }),
    (nama) => nama === 'rc_login_gagal' ? { data: { status: 'success', suspended: true, message: 'Akun di-suspend karena salah PIN 3 kali berturut-turut.' } } : { data: {} });
  const res = await call({ action: 'login', userid: 'qa-user', pin: 'salah123' });
  assert.equal(res.status, 'error');
  assert.match(res.message, /di-suspend/);
  assert.deepEqual(panggilan.map((p) => p.nama), ['rc_login_gagal']);
  assert.deepEqual(panggilan[0].arg, { p_user_code: 'qa-user', p_pin: 'salah123' });
});

test('a correct PIN on a suspended account is refused and the session closed', async () => {
  const { call, panggilan, keluar } = loginBackend(
    () => ({ data: { session: {} } }),
    (nama) => nama === 'rc_login_berhasil' ? { data: { status: 'success', akun: 'suspended', message: 'Akun di-suspend karena salah PIN berulang.' } } : { data: {} });
  const res = await call({ action: 'login', userid: 'QA-USER', pin: 'benar123' });
  assert.equal(res.status, 'error');
  assert.match(res.message, /di-suspend/);
  assert.equal(keluar(), 1);
  assert.ok(!panggilan.some((p) => p.nama === 'rc_legacy_bootstrap'));
});

// Regresi prod 6 Oktober 2026: sejak bootstrap tidak lagi mengirim dokumen, lookupMaster satu-
// satunya sumber dokumen di Mass Upload. Versinya harus tercatat supaya Posting Claim jalan.
test('documents fetched by lookupMaster can be posted right away', async () => {
  const panggilan = [];
  const c = { window: {}, crypto: webcrypto, TextEncoder,
    __testClient: { rpc: async (nama, arg) => {
      panggilan.push({ nama, arg: plain(arg || {}) });
      if (nama === 'rc_lookup_master') {
        return { data: { status: 'success', customers: [], documents: [{ noDoc: 'NPC/CMP/PSN/326B/23767', versionNo: 4 }] } };
      }
      return { data: { processed: [{ no_doc: 'NPC/CMP/PSN/326B/23767', status: 'submitted', version_no: 5 }], batch: 'B1', count: 1 } };
    } } };
  vm.createContext(c);
  vm.runInContext(code.replace('var clientPromise = null;', 'var clientPromise = Promise.resolve(__testClient);'), c);
  const cari = await c.window.RCBackend.call({ action: 'lookupMaster', custCodes: [], docNos: ['NPC/CMP/PSN/326B/23767'] });
  assert.equal(cari.status, 'success');
  const res = await c.window.RCBackend.call({ action: 'submitData', data: [{ noDoc: 'npc/cmp/psn/326b/23767 ' }] });
  assert.equal(res.status, 'success');
  const kirim = panggilan.find((p) => p.nama === 'rc_process_claims');
  assert.deepEqual(kirim.arg.p_items.map((x) => [x.no_doc, x.version_no]), [['npc/cmp/psn/326b/23767', 4]]);
});

test('bulk reject sends reject_bulk with the reason and the loaded versions', async () => {
  const panggilan = [];
  const c = { window: {}, crypto: webcrypto, TextEncoder,
    __testClient: { rpc: async (nama, arg) => { panggilan.push({ nama, arg: plain(arg || {}) });
      return { data: { processed: [{ no_doc: 'DOC-R1', status: 'not_yet', version_no: 8 }], batch: null, count: 1 } }; } } };
  vm.createContext(c);
  vm.runInContext(code.replace('var clientPromise = null;', 'var clientPromise = Promise.resolve(__testClient);'), c);
  c.window.RCBackend._test.setVersion('DOC-R1', 7);
  const res = await c.window.RCBackend.call({ action: 'bulkReject', docsToProcess: ['DOC-R1'], reason: 'Data toko salah' });
  assert.equal(res.status, 'success');
  assert.equal(panggilan[0].nama, 'rc_process_claims');
  assert.equal(panggilan[0].arg.p_action, 'reject_bulk');
  assert.equal(panggilan[0].arg.p_reason, 'Data toko salah');
  assert.deepEqual(panggilan[0].arg.p_items.map((x) => [x.no_doc, x.version_no]), [['DOC-R1', 7]]);
});

// Server menerima paling banyak 500 dokumen per proses. Mass Process Clearing dengan ratusan No
// Document dulu ditolak seluruhnya ("Satu proses maksimal 500 dokumen"); kini dikirim bertahap.
function prosesBackend(jawab) {
  const panggilan = [];
  const c = { window: {}, crypto: webcrypto, TextEncoder,
    __testClient: { rpc: async (nama, arg) => { panggilan.push({ nama, arg: plain(arg || {}) }); return jawab(panggilan.length, arg || {}); } } };
  vm.createContext(c);
  vm.runInContext(code.replace('var clientPromise = null;', 'var clientPromise = Promise.resolve(__testClient);'), c);
  const docs = [];
  for (let i = 1; i <= 1234; i++) { const d = 'NPC/CMP/UJI/0001/' + i; docs.push(d); c.window.RCBackend._test.setVersion(d, 3); }
  return { call: c.window.RCBackend.call, panggilan, docs };
}

test('more than 500 documents are posted in stages of 500 and merged', async () => {
  const { call, panggilan, docs } = prosesBackend((ke, arg) => ({ data: {
    batch: 'B' + ke, count: arg.p_items.length,
    processed: arg.p_items.map((x) => ({ no_doc: x.no_doc, status: 'done', gross_up: 0, version_no: 4 })) } }));
  const res = await call({ action: 'processWorkflow', workflowType: 'clearing', actionType: 'approve', tglProses: '10-10-2026', docsToProcess: docs });
  assert.equal(res.status, 'success');
  assert.deepEqual(panggilan.map((p) => p.arg.p_items.length), [500, 500, 234]);
  assert.ok(panggilan.every((p) => p.nama === 'rc_process_claims' && p.arg.p_action === 'clearing'));
  assert.equal(new Set(panggilan.map((p) => p.arg.p_request_id)).size, 3, 'setiap tahap punya request id sendiri');
  assert.equal(res.summary.successCount, 1234);
  assert.equal(res.summary.successfulDocs.length, 1234);
  assert.equal(res.summary.batchNum, 'B1, B2, B3');
});

test('a failing later stage reports what was already posted', async () => {
  const { call, panggilan, docs } = prosesBackend((ke, arg) => ke === 2
    ? { error: { message: 'Customer Master 644012 belum tersedia; klaim tidak dapat diproses.' } }
    : { data: { batch: 'B' + ke, count: arg.p_items.length,
        processed: arg.p_items.map((x) => ({ no_doc: x.no_doc, status: 'done', version_no: 4 })) } });
  const res = await call({ action: 'processWorkflow', workflowType: 'clearing', actionType: 'approve', tglProses: '10-10-2026', docsToProcess: docs });
  assert.equal(res.status, 'error');
  assert.equal(panggilan.length, 2, 'tahap sesudah yang gagal tidak dikirim');
  assert.match(res.message, /^500 dokumen sudah diproses \(batch B1\); sisanya gagal: Customer Master 644012 belum tersedia/);
});

// Clearing meneruskan Tgl Clearing (Aktual) ke server sebagai tgl_aktual setiap dokumen.
test('clearing forwards the actual transfer date chosen on screen', async () => {
  const { call, panggilan, docs } = prosesBackend((ke, arg) => ({ data: { batch: 'B1', count: arg.p_items.length,
    processed: arg.p_items.map((x) => ({ no_doc: x.no_doc, status: 'done', version_no: 4 })) } }));
  const res = await call({ action: 'processWorkflow', workflowType: 'clearing', actionType: 'approve', tglProses: '10-10-2026', docsToProcess: docs.slice(0, 3) });
  assert.equal(res.status, 'success');
  assert.deepEqual(panggilan[0].arg.p_items.map((x) => x.tgl_aktual), ['2026-10-10', '2026-10-10', '2026-10-10']);
});

test('clearing without an actual date is refused before any network call', async () => {
  const { call, panggilan, docs } = prosesBackend(() => ({ data: {} }));
  const res = await call({ action: 'processWorkflow', workflowType: 'clearing', actionType: 'approve', tglProses: '', docsToProcess: docs.slice(0, 1) });
  assert.equal(res.status, 'error');
  assert.match(res.message, /wajib diisi/);
  assert.equal(panggilan.length, 0);
  // Tahap lain tidak membawa tanggal aktual.
  await call({ action: 'processWorkflow', workflowType: 'release', actionType: 'approve', docsToProcess: docs.slice(0, 1) });
  assert.equal(panggilan.length, 1);
  assert.equal(panggilan[0].arg.p_items[0].tgl_aktual, undefined);
});

// Document Center: filter Depot diteruskan sebagai p_depot (kode depot), dan daftar pilihannya
// diambil dari server (20261163040000).
test('document center forwards the depot filter and loads the depot choices', async () => {
  const { call, panggilan } = prosesBackend(() => ({ data: { status: 'success', rows: [], total: 0 } }));
  await call({ action: 'compilationList', campaign: 'CA1', depot: '4A', batch: '', status: '', search: '', offset: 0 });
  assert.equal(panggilan[0].nama, 'rc_compilation_list');
  assert.equal(panggilan[0].arg.p_depot, '4A');
  assert.equal(panggilan[0].arg.p_campaign, 'CA1');
  await call({ action: 'compilationList', campaign: '', offset: 0 });
  assert.equal(panggilan[1].arg.p_depot, '', 'tanpa pilihan depot berarti semua depot');
  await call({ action: 'compilationDepots' });
  assert.equal(panggilan[2].nama, 'rc_compilation_depots');
});

// Document Center: arsip lebih dari 500 baris dikirim bertahap per 500 dan jumlahnya digabung.
test('document center archives more than 500 rows in stages of 500', async () => {
  const { call, panggilan } = prosesBackend((ke, arg) => ({ data: { status: 'success', jumlah: arg.p_ids.length } }));
  const ids = Array.from({ length: 1234 }, (_, i) => 'id-' + i);
  const res = await call({ action: 'archiveCompilation', ids, reason: 'uji' });
  assert.equal(res.status, 'success');
  assert.equal(res.jumlah, 1234);
  assert.deepEqual(panggilan.map((p) => [p.nama, p.arg.p_ids.length, p.arg.p_reason]),
    [['rc_archive_compilation', 500, 'uji'], ['rc_archive_compilation', 500, 'uji'], ['rc_archive_compilation', 234, 'uji']]);
});

// Document Center: filter Created On diteruskan sebagai tanggal ISO, kosong = null (20261163090000).
test('document center forwards the created-on date range', async () => {
  const { call, panggilan } = prosesBackend(() => ({ data: { status: 'success', rows: [], total: 0 } }));
  await call({ action: 'compilationList', dibuatDari: '2026-10-01', dibuatSampai: '2026-10-14', offset: 0 });
  assert.equal(panggilan[0].arg.p_dibuat_dari, '2026-10-01');
  assert.equal(panggilan[0].arg.p_dibuat_sampai, '2026-10-14');
  await call({ action: 'compilationList', dibuatDari: '', offset: 0 });
  assert.equal(panggilan[1].arg.p_dibuat_dari, null);
  assert.equal(panggilan[1].arg.p_dibuat_sampai, null);
});
