// Uji parser file bank KlikBCA (MultiTransactionAutoTransferDownload) di src/js/57-clearing-bank.js
// (20261163710000). File contoh pemilik diuji bila ada di folder project (CLEARING_BANK_CONTOH=<path>
// untuk lokasi lain); data sintetis selalu diuji.
import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import path from 'node:path';
import { readFileSync, existsSync, readdirSync } from 'node:fs';

const sumber = readFileSync('src/js/57-clearing-bank.js', 'utf8');
const ctx = { console, Math, Date, Number, String, Set, Object, Infinity, JSON };
vm.createContext(ctx);
vm.runInContext(sumber, ctx);
const plain = (x) => JSON.parse(JSON.stringify(x));

// ---- File contoh pemilik ----------------------------------------------------------------------
const contoh = process.env.CLEARING_BANK_CONTOH
  || readdirSync('.').map(f => path.resolve(f)).find(f => /MultiTransactionAutoTransferDownload_\d{14}.*\.txt$/i.test(f));

test('File contoh: 198 baris, semua Berhasil, total Rp 108.970.394, Eff Date 26-Oct-2026 dari nama file', { skip: !contoh || !existsSync(contoh) }, () => {
  const teks = readFileSync(contoh, 'latin1');
  const r = plain(ctx.rcBankParse(teks, { namaFile: path.basename(contoh) }));
  assert.equal(r.ok, true, r.galat);
  assert.equal(r.tahun, 2026);
  assert.equal(r.tahunSumber, 'nama_file');
  assert.equal(r.ringkas.jumlah, 198);
  assert.equal(r.ringkas.berhasil, 198);
  assert.equal(r.ringkas.total, 108970394);
  assert.equal(r.baris.every(b => b.berhasil && b.status === 'Berhasil'), true);
  assert.equal(r.baris.every(b => b.tglTransfer === '2026-10-26'), true);
  assert.deepEqual(r.peringatan, []);
  const b1 = r.baris[0];
  assert.match(b1.remark1, /^[A-Z]+\/[A-Z]+\/[0-9A-Z]+\/[0-9]+$/);
  assert.equal(b1.transId, '000000000026Okt001');
  assert.equal(b1.nominal, 100000);
  assert.equal(b1.bank, 'BCA');
  assert.match(b1.toAcc, /^[0-9]{10}$/);
  assert.equal(b1.reason, 'HOST_TRAN SUCCESSFUL');
  // No Doc dengan awalan lain tetap terbaca utuh (tidak terpotong oleh pemisahan spasi).
  assert.ok(r.baris.some(b => b.remark1.startsWith('CBCN/') && b.nominal > 0));
  assert.ok(r.baris.some(b => b.remark1.length === 18 && b.nominal > 0)); // No Doc 18 karakter (batas bank) tetap utuh
  assert.equal(new Set(r.baris.map(b => b.remark1)).size, 198);
});

// ---- Data sintetis ------------------------------------------------------------------------------
// Header dan baris disusun fixed-width dengan posisi kolom seperti file asli.
const KOLOM = [['Header ID', 0], ['Eff Date', 11], ['Trans ID', 22], ['Channel', 56], ['To Acc', 181], ['Equivalent Amount', 387],
               ['Rate', 409], ['Remark 1', 476], ['Remark 2', 497], ['Status', 518], ['Reason', 536]];
function susun(isi) {
  let s = '';
  KOLOM.forEach(([nama, p]) => { const v = isi[nama] === undefined ? '' : String(isi[nama]); s = s.padEnd(p, ' ') + v; });
  return s.padEnd(640, ' ');
}
const HEADER = susun(Object.fromEntries(KOLOM.map(([n]) => [n, n])));
const baris = (o) => susun({ 'Eff Date': '26 Oct 202', 'Trans ID': '000000000026Okt001', 'Channel': 'KBB', 'To Acc': '0123456789',
  'Equivalent Amount': 'Rp. 100000', 'Rate': '', 'Remark 1': 'CMP/UJI/CA08/12345', 'Remark 2': 'BCA', 'Status': 'Berhasil', 'Reason': 'HOST_TRAN SUCCESSFUL', ...o });
const file = (rows, akhir = '\r\n') => [HEADER, ...rows].join(akhir) + akhir;

test('Kolom dipotong menurut posisi header, bukan spasi: nilai berspasi tetap utuh', () => {
  const r = plain(ctx.rcBankParse(file([baris({ 'Reason': 'HOST TRAN SUCCESSFUL', 'Remark 2': 'BANK DANAMON' })]), { namaFile: 'MultiTransactionAutoTransferDownload_27102026145112.txt' }));
  assert.equal(r.ok, true, r.galat);
  assert.equal(r.baris[0].reason, 'HOST TRAN SUCCESSFUL');
  assert.equal(r.baris[0].bank, 'BANK DANAMON');
  assert.equal(r.baris[0].remark1, 'CMP/UJI/CA08/12345');
});

test('Bulan Inggris dan Indonesia; tahun dari nama file', () => {
  const nama = 'MultiTransactionAutoTransferDownload_31122026101010.txt';
  const r = plain(ctx.rcBankParse(file([
    baris({ 'Eff Date': '05 Okt 202' }), baris({ 'Eff Date': '06 Mei 202' }), baris({ 'Eff Date': '07 Agu 202' }),
    baris({ 'Eff Date': '08 Des 202' }), baris({ 'Eff Date': '09 May 202' }), baris({ 'Eff Date': '10 Aug 202' })]), { namaFile: nama }));
  assert.deepEqual(r.baris.map(b => b.tglTransfer), ['2026-10-05', '2026-05-06', '2026-08-07', '2026-12-08', '2026-05-09', '2026-08-10']);
});

test('Pergantian tahun: file Januari, Eff Date Desember = tahun sebelumnya', () => {
  const r = plain(ctx.rcBankParse(file([baris({ 'Eff Date': '30 Dec 202' }), baris({ 'Eff Date': '02 Jan 202' })]),
    { namaFile: 'MultiTransactionAutoTransferDownload_03012027080000.txt' }));
  assert.deepEqual(r.baris.map(b => b.tglTransfer), ['2026-12-30', '2027-01-02']);
});

test('Nama file tanpa pola tanggal: tahun wajib diisi; dengan tahun dari form terbaca', () => {
  const t = file([baris({})]);
  const r1 = plain(ctx.rcBankParse(t, { namaFile: 'transfer-bca.txt' }));
  assert.equal(r1.ok, false);
  assert.equal(r1.perluTahun, true);
  const r2 = plain(ctx.rcBankParse(t, { namaFile: 'transfer-bca.txt', tahun: '2026' }));
  assert.equal(r2.ok, true);
  assert.equal(r2.tahunSumber, 'form');
  assert.equal(r2.baris[0].tglTransfer, '2026-10-26');
});

test('Status selain Berhasil ditandai; nominal "Rp." dibuang menjadi bilangan bulat', () => {
  const r = plain(ctx.rcBankParse(file([
    baris({ 'Status': 'Gagal', 'Reason': 'REKENING TIDAK AKTIF' }),
    baris({ 'Equivalent Amount': 'Rp. 1.250.000,00' }), baris({ 'Equivalent Amount': 'Rp. 1.250.000' }), baris({ 'Equivalent Amount': 'Rp.2250000' })]),
    { namaFile: 'MultiTransactionAutoTransferDownload_27102026145112.txt' }));
  assert.equal(r.baris[0].berhasil, false);
  assert.equal(r.baris[0].reason, 'REKENING TIDAK AKTIF');
  assert.deepEqual(r.baris.slice(1).map(b => b.nominal), [1250000, 1250000, 2250000]);
  assert.equal(r.ringkas.berhasil, 3);
  assert.equal(r.ringkas.total, 100000 + 1250000 + 1250000 + 2250000);
});

test('Akhir baris LF dan baris kosong di ujung tetap terbaca', () => {
  const r = plain(ctx.rcBankParse(file([baris({}), baris({ 'Trans ID': '000000000026Okt002' })], '\n') + '\n\n', { namaFile: 'x_27102026145112.txt' }));
  assert.equal(r.ringkas.jumlah, 2);
  assert.equal(r.baris[1].transId, '000000000026Okt002');
});

test('Header bukan format KlikBCA ditolak dengan nama kolom yang hilang', () => {
  const r = plain(ctx.rcBankParse('No Doc;Tanggal;Nominal\r\nA;B;C\r\n', { namaFile: 'x_27102026145112.txt' }));
  assert.equal(r.ok, false);
  assert.match(r.galat, /Eff Date/);
  assert.match(r.galat, /Remark 1/);
});

test('Eff Date / nominal tidak terbaca masuk peringatan, baris tetap dikirim', () => {
  const r = plain(ctx.rcBankParse(file([baris({ 'Eff Date': '99 Xyz 202', 'Equivalent Amount': 'Rp. abc' })]), { namaFile: 'x_27102026145112.txt' }));
  assert.equal(r.ok, true);
  assert.equal(r.baris[0].tglTransfer, null);
  assert.equal(r.baris[0].nominal, null);
  assert.equal(r.peringatan.length, 2);
});

// 20261163730000: kolom Bukti Transfer (tidak wajib) ikut terbaca.
test('File contoh: kolom Bukti TF (layanan, pengirim, SWIFT, nama bank, biaya) terbaca', { skip: !contoh || !existsSync(contoh) }, () => {
  const r = plain(ctx.rcBankParse(readFileSync(contoh, 'latin1'), { namaFile: path.basename(contoh) }));
  const bca = r.baris.find(b => b.layanan === 'BCA'), llg = r.baris.find(b => b.layanan === 'LLG');
  assert.equal(r.baris.filter(b => b.layanan === 'BCA').length, 108);
  assert.equal(r.baris.filter(b => b.layanan === 'LLG').length, 90);
  assert.match(bca.dariRek, /^[0-9]{10}$/);
  assert.equal(bca.dariNama, 'NIPSEA PAINT AND CHEMICA');
  assert.equal(bca.swift, '');
  assert.equal(bca.biaya, 0);
  assert.equal(bca.biayaOleh, 'OUR');
  assert.equal(bca.channel, 'KBB');
  assert.ok(['BRINIDJA', 'BMRIIDJA', 'BNINIDJA'].includes(llg.swift));
  assert.match(llg.namaBank, /^PT\. BANK /);
  assert.equal(llg.biaya, 2900);
});

test('File tanpa kolom Bukti TF tetap terbaca (kolom tambahan kosong)', () => {
  const r = plain(ctx.rcBankParse(file([baris({})]), { namaFile: 'x_27102026145112.txt' }));
  assert.equal(r.ok, true);
  assert.equal(r.baris[0].layanan, '');
  assert.equal(r.baris[0].namaBank, '');
  assert.equal(r.baris[0].biaya, null);
});
