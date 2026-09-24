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
