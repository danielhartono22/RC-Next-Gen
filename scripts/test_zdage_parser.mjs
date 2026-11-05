// Uji parser Upload Debtor (ZDAGE) di src/js/51-upload-debtor.js (20261163170000).
// Data sintetis selalu diuji; berkas contoh pemilik ikut diuji bila ada di komputer ini
// (ZDAGE_CONTOH=<path> untuk lokasi lain).
import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync, existsSync } from 'node:fs';

const sumber = readFileSync('src/js/51-upload-debtor.js', 'utf8');
const xlsx = readFileSync('scripts/vendor/xlsx-0.18.5.full.min.js', 'utf8');
const ctx = { console, Math, Date, Number, String, isFinite };
vm.createContext(ctx);
vm.runInContext(xlsx, ctx);
vm.runInContext(sumber, ctx);
const plain = (x) => JSON.parse(JSON.stringify(x));

const KEPALA = ['Distribution Channel', 'Customer', 'Customer Name', 'Term-FI', ' Over Due Amt', 'Total',
  'Oct-2026', 'Sep-2026', 'Aug-2026', 'Jul-2026', 'Jun-2026', 'May-2026', 'Apr-2026', 'Mar-2026', 'Feb2026',
  'Jan-2026', 'Dec-2025', 'Nov-2025', 'Oct-2025', '<Oct-2025'];
const baris = (kode, isi = {}) => {
  const r = ['4A', kode, 'TOKO ' + kode, 'I060', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  Object.entries(isi).forEach(([i, v]) => { r[Number(i)] = v; });
  r[5] = r.slice(6).reduce((a, v) => a + (typeof v === 'number' ? v : 0), 0);
  return r;
};

test('header, bulan, kode toko, angka dan baris total dibaca sesuai format ZDAGE', () => {
  const h = ctx.zdParse([KEPALA, baris('   617108', { 6: 3095410.45, 7: 5198819.98 }), baris('   665071', { 4: -3494.59, 9: -3494.59 }),
    ['', '', '', '', '', 129, 1, 2, 3, 4, '', '', '', '', '', '', '', '', '', '']]);
  assert.deepEqual(plain(h.galat), []);
  assert.equal(h.asOf, '2026-10');
  assert.equal(h.bulan.length, 13);
  assert.equal(h.bulan[8], '2026-02');                      // "Feb2026" tanpa tanda hubung
  assert.equal(h.baris.length, 2);                          // baris grand total (B kosong) dilewati
  assert.equal(h.baris[0].customerCode, '617108');
  assert.equal(h.baris[0].buckets['2026-10'], 3095410.45);
  assert.equal(h.baris[1].overdueAmt, -3494.59);            // nilai negatif disimpan apa adanya
  assert.equal(h.baris[0].rowNo, 2);
  assert.deepEqual(plain(Object.keys(h.depot)), ['4A']);
});

test('berkas ditolak: header salah, bulan tidak berurutan, kolom T salah, kode duplikat, angka tidak terbaca', () => {
  const salah = KEPALA.slice(); salah[4] = 'Overdue';
  assert.match(ctx.zdParse([salah, baris('1')]).galat.join(' '), /kolom E/);
  const loncat = KEPALA.slice(); loncat[9] = 'Jun-2026';
  assert.match(ctx.zdParse([loncat, baris('1')]).galat.join(' '), /berurutan mundur/);
  const t = KEPALA.slice(); t[19] = '<Sep-2025';
  assert.match(ctx.zdParse([t, baris('1')]).galat.join(' '), /kolom T/);
  assert.match(ctx.zdParse([KEPALA, baris('   0617108'), baris('617108')]).galat.join(' '), /duplikat 617108 \(baris 2 dan 3\)/);
  const rusak = baris('1'); rusak[8] = 'abc';
  assert.match(ctx.zdParse([KEPALA, baris('2'), rusak]).galat.join(' '), /baris 3/);
});

test('angka teks SAP: pemisah ribuan, desimal koma, minus di belakang, kurung; kosong = 0', () => {
  assert.equal(ctx.zdAngka(''), 0);
  assert.equal(ctx.zdAngka(null), 0);
  assert.equal(ctx.zdAngka('42.000,71'), 42000.71);
  assert.equal(ctx.zdAngka('1,234,567.89'), 1234567.89);
  assert.equal(ctx.zdAngka('42.000-'), -42000);
  assert.equal(ctx.zdAngka('(1.500,5)'), -1500.5);
  assert.equal(ctx.zdAngka('12x'), null);
  assert.equal(ctx.zdTanggalDariNama('EXPORT_20261016_205703-contoh zdage.xlsx'), '2026-10-16T20:57');
  assert.equal(ctx.zdTanggalDariNama('debtor oktober.xlsx'), '');
  assert.equal(ctx.zdLabelBulan('<2025-10'), '<Oct-2025');
});

test('peringatan Total berbeda dari jumlah G..T (bukan penolakan)', () => {
  const r = baris('9', { 6: 100 }); r[5] = 250;
  const h = ctx.zdParse([KEPALA, r]);
  assert.deepEqual(plain(h.galat), []);
  assert.equal(h.totalBeda, 1);
  assert.match(h.peringatan.join(' '), /Total/);
});

const contoh = process.env.ZDAGE_CONTOH || 'C:/Users/lenovo/Documents/SAP/SAP GUI/EXPORT_20261016_205703-contoh zdage.xlsx';
test('berkas contoh EXPORT_20261016_205703 terbaca tanpa penolakan (angka persis untuk versi asli 1.217 toko)', { skip: !existsSync(contoh) && 'berkas contoh tidak ada' }, () => {
  const wb = ctx.XLSX.read(readFileSync(contoh), { type: 'buffer' });
  const h = ctx.zdParse(ctx.zdBacaBuku(wb));
  assert.deepEqual(plain(h.galat), []);
  assert.ok(h.baris.length > 0);
  assert.equal(h.asOf, '2026-10');
  // Pemilik menyunting berkas contoh (17 Oktober 2026); angka persis hanya untuk versi asli.
  if (h.baris.length !== 1217) return;
  assert.equal(h.asOf, '2026-10');
  assert.deepEqual(plain(h.depot), { '4A': 712, '4B': 2, '4C': 226, '4D': 133, '4F': 144 });
  assert.equal(h.totalBeda, 0);
  const meg = h.baris.find(b => b.customerCode === '630270');
  assert.equal(meg.buckets['2026-07'], -42000);
  assert.equal(meg.overdueAmt, 0.71);
});
