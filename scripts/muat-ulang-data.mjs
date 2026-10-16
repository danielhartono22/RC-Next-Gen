/*
 * MUAT ULANG DATA RC: kosongkan data transaksi & master, lalu muat data final dari satu Excel
 * ==========================================================================================
 * Dibuat 6 Oktober 2026 atas permintaan pemilik: "besok mau hapus semua data prod dan transport
 * seluruh data prod yang fix. Buatkan template dan caranya." Cara pakainya lengkap ada di
 * docs/muat-ulang-data-prod.md.
 *
 * YANG DIKOSONGKAN LALU DIMUAT ULANG
 *   klaim (public.claims) beserta data sensitif (rc_private.claim_sensitive) dan riwayat status,
 *   pelanggan (public.customers) beserta pemetaan depotnya (public.customer_depots),
 *   campaign (public.campaigns).
 *
 * YANG TIDAK DISENTUH
 *   akun, peran, izin, tab, yurisdiksi, PIN; pengaturan email dan antreannya; log aktivitas;
 *   profil depot. Depot TIDAK PERNAH dihapus - ia dirujuk yurisdiksi setiap akun. Lembar Depot
 *   hanya memperbarui atau menambah depot.
 *
 * YANG DIPERTAHANKAN MELEWATI PENGOSONGAN
 *   tanda Exclude Campaign, tanda Not Achieved Timetable, dan Not Participating Campaign Master
 *   (dipotret per kode campaign/depot/region sebelum campaign dihapus, dipasang kembali untuk
 *   kode yang masih ada).
 *
 * PENJAGA
 *   - Berkas diperiksa lengkap DULU; satu galat saja menghentikan semuanya sebelum database
 *     disentuh.
 *   - Seluruh isi lama dicadangkan ke .runtime/muat-ulang/ sebelum dihapus, dan dapat
 *     dipulihkan dengan --pulihkan.
 *   - Pengosongan + pemuatan + pemeriksaan berjalan dalam SATU transaksi. Bila jumlah baris,
 *     total cashback, atau pemetaan depot tidak cocok, seluruhnya dibatalkan dan data lama utuh.
 *   - Prod hanya jalan dengan kalimat konfirmasi yang memuat tanggal hari itu.
 *
 * PEMAKAIAN
 *   node scripts/muat-ulang-data.mjs --buat-template docs/Template_Muat_Ulang_Data_RC.xlsx
 *   node scripts/muat-ulang-data.mjs --berkas data.xlsx --periksa [--env dev|prod]
 *   node scripts/muat-ulang-data.mjs --env prod --cadangkan
 *   node scripts/muat-ulang-data.mjs --berkas data.xlsx --env dev  --jalankan --konfirmasi MUAT-ULANG-DEV
 *     Tambahkan --pertahankan-warisan hanya untuk hasil ekspor database: teks tanggal lama yang
 *     tidak dapat diurai tetap disimpan di legacy_dates dan email depot lama tidak dinormalisasi.
 *     Tambahkan --normalisasi-impor untuk sumber gabungan: tanggal yang dapat dikenali dinormalkan,
 *     jam dipertahankan sebagai timestamp WIB, dan alias Jenis CB lama dinormalkan.
 *     Tambahkan --izinkan-customer-tidak-ada agar klaim tetap dimuat tanpa Customer Master;
 *     kode sumber disimpan, customer_id dibiarkan kosong, dan proses klaim diblokir sampai master ada.
 *     Tambahkan --hapus-kondisi-lama untuk tidak memulihkan Exclude/N/A/Not Participating dan
 *     menghapus seluruh activity log lama sebelum pertukaran.
 *     --gunakan-cadangan <folder> hanya untuk retry setelah staging gagal dan PROD belum berubah.
 *     Tambahkan --temuan-duplikat (bersama --lewati-galat) agar SEMUA salinan klaim duplikat ditahan
 *     sebagai temuan: No Document ganda, atau Code Campaign + Cust Code + Cashback After Tax sama.
 *     Tambahkan --temuan-xlsx <berkas.xlsx> untuk menulis seluruh baris pending ke Excel temuan
 *     (kolom template + Remark berisi baris sumber dan alasannya).
 *   node scripts/muat-ulang-data.mjs --berkas data.xlsx --env prod --jalankan --konfirmasi MUAT-ULANG-PROD-<yyyymmdd>
 *   node scripts/muat-ulang-data.mjs --env prod --pulihkan <folder cadangan> --konfirmasi PULIHKAN-PROD-<yyyymmdd>
 */
import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// SheetJS 0.18.5 - versi yang sama dengan aplikasi (src/parts/head.html), sehingga sel tanggal
// ditafsirkan sama persis. Integritas berkas dicocokkan dengan SRI resmi cdnjs:
// sha512-r22gChDnGvBylk90+2e/ycr3RVrDi8DIOkIGNhJlKfuyQM4tIRAI062MaV8sfjQKYVGjOBaZBOA87z+IhZE9DA==
// Dimuat seperti di peramban (global XLSX), karena bundelnya tidak mengisi module.exports.
const XLSX = (() => {
  const ctx = {};
  vm.createContext(ctx);
  vm.runInContext(readFileSync(path.join(root, 'scripts', 'vendor', 'xlsx-0.18.5.full.min.js'), 'utf8'), ctx);
  return ctx.XLSX;
})();

// ------------------------------------------------------------------------------------------
// Argumen
// ------------------------------------------------------------------------------------------
const argv = process.argv.slice(2);
const ada = (n) => argv.includes(n);
const ambil = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : null; };
const pertahankanWarisan = ada('--pertahankan-warisan');
const normalisasiImpor = ada('--normalisasi-impor');
const lewatiGalat = ada('--lewati-galat');
const izinkanCustomerTidakAda = ada('--izinkan-customer-tidak-ada');
const hapusKondisiLama = ada('--hapus-kondisi-lama');
const temuanDuplikat = ada('--temuan-duplikat');

const tglWib = new Date(Date.now() + 7 * 3600 * 1000).toISOString().slice(0, 10).replace(/-/g, '');
const stempel = new Date(Date.now() + 7 * 3600 * 1000).toISOString().slice(0, 19).replace(/[-:T]/g, '').replace(/^(\d{8})/, '$1-');

// ------------------------------------------------------------------------------------------
// Definisi template
// ------------------------------------------------------------------------------------------
// wajib: kolom harus ada di lembar DAN terisi di setiap baris. teks: diformat Text di template
// supaya angka nol di depan tidak hilang.
const LEMBAR = {
  Depot: {
    opsional: true,
    keterangan: 'Opsional. Hanya MEMPERBARUI atau MENAMBAH depot; depot tidak pernah dihapus. Sel kosong = nilai lama dipertahankan.',
    kolom: [
      ['Kode Depot', 'wajib', 'teks', '4C', 'Kode depot, unik.'],
      ['Nama Depot', '', '', 'Pematang Siantar', 'Wajib untuk depot baru.'],
      ['Abbr', '', 'teks', 'PST', '2-10 huruf besar/angka; dipakai membentuk No Document.'],
      ['Region', '', '', '2B', ''],
      ['Alamat', '', '', 'Jl. Contoh No. 1', ''],
      ['Email TO', '', '', 'depot@nipponpaint.co.id', 'Maksimal 4 alamat, pisahkan dengan koma.'],
      ['Email CC', '', '', '', 'Maksimal 20 alamat, pisahkan dengan koma.'],
      ['Link Master', '', '', '', 'Tautan master depot (opsional).'],
    ],
  },
  Campaign: {
    keterangan: 'Seluruh Campaign Master. Judul kolom sama dengan template Key Master > Campaign.',
    kolom: [
      ['Code Campaign', 'wajib', 'teks', 'CMP2601', 'Unik.'],
      ['Nama Campaign', 'wajib', '', 'PROMO AWAL TAHUN', ''],
      ['Periode Start', '', 'teks', '01-01-2026', 'Periode dasar setiap dokumen campaign ini.'],
      ['Periode End', '', 'teks', '31-03-2026', ''],
      ['Periode SO Start', '', 'teks', '', 'Kosong = tidak ada periode SO tersendiri.'],
      ['Periode SO End', '', 'teks', '', ''],
      ['Periode Billing Start', '', 'teks', '', 'Kosong = mengikuti SO Start.'],
      ['Periode Billing End', '', 'teks', '', 'Kosong = mengikuti SO End.'],
      ['Jenis CB', 'wajib', '', 'Transfer', 'Transfer, CN, Rebate atau Voucher.'],
      ['Status Pajak', '', '', 'Customer', 'Penanggung pajak: Customer, PT Nipsea Paint and Chemicals, atau Rebate Non Tax. Gross up dihitung untuk semua kecuali Rebate Non Tax; Jenis CB Rebate juga tanpa gross up.'],
      ['Status Campaign', '', '', 'active', 'active, inactive atau cleared. Kosong = active.'],
    ],
  },
  Customer: {
    keterangan: 'Seluruh Customer Master. Kolom Kode Depot WAJIB di sini (tidak ada di template Key Master). Subyek Pajak tidak diisi: ada NPWP = Badan, hanya KTP = Perorangan (aturan database).',
    kolom: [
      ['Customer Code', 'wajib', 'teks', 'C00123', 'Unik.'],
      ['Customer Name', 'wajib', '', 'TOKO MAJU JAYA', ''],
      ['Kode Depot', '', 'teks', '4C', 'Depot yang melayani toko ini. Lebih dari satu: pisahkan dengan koma, mis. "4C, 4D". Kosong = hanya terlihat oleh System Manager.'],
      ['TOP', '', 'teks', '30', ''],
      ['No KTP', '', 'teks', '', 'Format sel Text. Hanya KTP (tanpa NPWP) = Subyek Pajak Perorangan.'],
      ['No NPWP', '', 'teks', '', 'Format sel Text. Ada NPWP = Subyek Pajak Badan (gross up flat 15%).'],
      ['Nama Rekening', '', '', '', ''],
      ['Nomor Rekening', '', 'teks', '', 'Format sel Text supaya nol di depan tidak hilang.'],
      ['Nama Bank', '', '', '', ''],
      ['Contact Person', '', '', '', ''],
    ],
  },
  Klaim: {
    keterangan: 'Seluruh dokumen klaim beserta status terakhirnya. Gross up TIDAK diisi - dihitung sistem dari Customer & Campaign Master.',
    kolom: [
      ['No Document', 'wajib', 'teks', 'NPC/CMP/PST/2601/0001', 'Unik.'],
      ['Kode Depot', 'wajib', 'teks', '4C', 'Harus salah satu depot pelanggan di lembar Customer (bila belum, ditambahkan otomatis dan dilaporkan).'],
      ['Cust Code', 'wajib', 'teks', 'C00123', 'Harus ada di lembar Customer.'],
      ['Code Campaign', 'wajib', 'teks', 'CMP2601', 'Harus ada di lembar Campaign.'],
      ['Net Value', '', '', '10000000', 'Angka.'],
      ['Volume', '', '', '250', 'Angka.'],
      ['Cashback After Tax', 'wajib', '', '500000', 'CB Net, angka >= 0.'],
      ['Status', 'wajib', '', 'Not Yet', 'Not Yet, Submitted, Approved, Released, Claimed, Done, On Hold, Expired.'],
      ['Jenis CB', '', '', '', 'Kosong = ikut campaign. Bila diisi: Transfer, CN, Rebate, Rebate Manual.'],
      ['TOP', '', 'teks', '30', 'Kosong = ikut Customer.'],
      ['Tgl Lunas', '', 'teks', '', 'Tanggal: dd-mm-yyyy, dd.mm.yyyy, dd-mm-yy, dd.mm.yy, ddmmyy, ddmmyyyy, atau sel tanggal Excel.'],
      ['Total Tagihan', '', '', '', 'Angka.'],
      ['No KTP', '', 'teks', '', 'Kosong = ikut Customer.'],
      ['No NPWP', '', 'teks', '', 'Kosong = ikut Customer.'],
      ['Nama Rekening', '', '', '', 'Kosong = ikut Customer.'],
      ['Nomor Rekening', '', 'teks', '', 'Kosong = ikut Customer.'],
      ['Bank', '', '', '', 'Kosong = ikut Customer.'],
      ['Batch Submitted', '', 'teks', '', 'Nomor batch tahap Submitted (15 digit).'],
      ['Tgl Submitted', '', 'teks', '', ''],
      ['Tgl Approved', '', 'teks', '', ''],
      ['Batch Released', '', 'teks', '', ''],
      ['Tgl Released', '', 'teks', '', ''],
      ['Batch Claimed', '', 'teks', '', ''],
      ['Tgl Claimed', '', 'teks', '', ''],
      ['Batch Done', '', 'teks', '', 'Batch Clearing.'],
      ['Tgl Done', '', 'teks', '', ''],
      ['Status Sebelum Hold', '', '', '', 'Hanya untuk On Hold: status saat dokumen ditahan. Kosong = Not Yet.'],
      ['Hold SO Start', '', 'teks', '', 'Hanya untuk On Hold: perpanjangan periode.'],
      ['Hold SO End', '', 'teks', '', ''],
      ['Hold Billing Start', '', 'teks', '', ''],
      ['Hold Billing End', '', 'teks', '', ''],
    ],
  },
};

const STATUS = { 'not yet': 'not_yet', 'notyet': 'not_yet', 'submitted': 'submitted', 'approved': 'approved',
  'released': 'released', 'claimed': 'claimed', 'done': 'done', 'on hold': 'on_hold', 'onhold': 'on_hold', 'expired': 'expired' };
const URUT_STATUS = ['not_yet', 'submitted', 'approved', 'released', 'claimed', 'done'];
const KOLOM_WAKTU = new Set(['Tgl Submitted', 'Tgl Approved', 'Tgl Released', 'Tgl Claimed', 'Tgl Done']);
const JENIS_CAMPAIGN = ['transfer', 'cn', 'rebate', 'voucher'];
const JENIS_KLAIM = { 'transfer': 'Transfer', 'cn': 'CN', 'rebate': 'Rebate', 'rebate manual': 'Rebate Manual' };
function jenisKlaimDari(teks) {
  const kunci = norm(teks).toLowerCase();
  if (JENIS_KLAIM[kunci]) return JENIS_KLAIM[kunci];
  if (normalisasiImpor && ['voucher', 'voucher transfer'].includes(kunci)) return 'Transfer';
  if (normalisasiImpor && ['manual', 'ra07', 'ra7'].includes(kunci)) return 'Rebate Manual';
  return null;
}
const BULAN = { jan: 1, januari: 1, january: 1, feb: 2, februari: 2, february: 2, mar: 3, maret: 3, march: 3,
  apr: 4, april: 4, mei: 5, may: 5, jun: 6, juni: 6, june: 6, jul: 7, juli: 7, july: 7, agu: 8, agt: 8, ags: 8,
  agustus: 8, aug: 8, august: 8, sep: 9, sept: 9, september: 9, okt: 10, oktober: 10, oct: 10, october: 10,
  nov: 11, nopember: 11, november: 11, des: 12, desember: 12, dec: 12, december: 12 };

// ------------------------------------------------------------------------------------------
// Membuat template
// ------------------------------------------------------------------------------------------
// Pilihan (dropdown) di template. Pemeriksa tetap menerima huruf besar/kecil apa pun.
const PILIHAN = {
  'Campaign|Jenis CB': ['Transfer', 'CN', 'Rebate', 'Voucher'],
  'Campaign|Status Campaign': ['active', 'inactive', 'cleared'],
  'Klaim|Status': ['Not Yet', 'Submitted', 'Approved', 'Released', 'Claimed', 'Done', 'On Hold', 'Expired'],
  'Klaim|Jenis CB': ['Transfer', 'CN', 'Rebate', 'Rebate Manual'],
  'Klaim|Status Sebelum Hold': ['Not Yet', 'Submitted', 'Approved', 'Released', 'Claimed'],
};

// Template ditulis openpyxl (scripts/buat-template-muat-ulang.py): format Text per kolom dan
// dropdown tidak dapat dibuat SheetJS edisi gratis. Definisi kolomnya tetap dari berkas ini.
async function buatTemplate(keluar, data = null) {
  const definisi = Object.entries(LEMBAR).map(([nama, def]) => ({
    nama, opsional: !!def.opsional, keterangan: def.keterangan,
    kolom: def.kolom.map(([k, wajib, teks, contoh, ket]) => ({ nama: k, wajib: !!wajib, teks: teks === 'teks', contoh, keterangan: ket,
      pilihan: PILIHAN[nama + '|' + k] || null })),
  }));
  const { spawnSync } = await import('node:child_process');
  const r = spawnSync('python', [path.join(root, 'scripts', 'buat-template-muat-ulang.py'), keluar],
    { input: JSON.stringify(data ? { definisi, data } : definisi), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error('membuat template gagal (perlu Python + openpyxl): ' + (r.stderr || r.error || '').toString().slice(-4000));
}

// Excel temuan: setiap baris yang TIDAK dimuat, dengan kolom template yang sama ditambah Remark
// (baris sumber + alasan). Nilai disalin dari berkas sumber apa adanya; tanggal Excel ditulis
// dd-mm-yyyy. Bentuknya sama dengan template sehingga baris yang sudah diperbaiki dapat disalin balik.
async function tulisTemuan(keluar, dataAsli, pending) {
  const tampil = (s) => (!s || s.kosong ? null : s.tanggal ? `${String(s.tanggal.d).padStart(2, '0')}-${String(s.tanggal.m).padStart(2, '0')}-${s.tanggal.y}` : (s.angka ?? s.teks));
  const definisi = Object.entries(LEMBAR).map(([nama, def]) => ({
    nama, opsional: !!def.opsional, keterangan: def.keterangan,
    kolom: [...def.kolom.map(([k, wajib, teks, contoh, ket]) => ({ nama: k, wajib: !!wajib, teks: teks === 'teks', contoh, keterangan: ket, pilihan: null })),
      { nama: 'Remark', wajib: false, teks: false, contoh: '', keterangan: 'Baris sumber dan alasan tidak dimuat.', pilihan: null }],
  }));
  const data = {};
  for (const [nama, def] of Object.entries(LEMBAR)) {
    const sumber = new Map(dataAsli[nama].map((b) => [b.baris, b]));
    data[nama] = pending[nama].map((p) => [...def.kolom.map(([k]) => tampil(sumber.get(p.barisSumber)?.sel[k])), `Baris sumber ${p.barisSumber}. ${p.alasan}`]);
  }
  const { spawnSync } = await import('node:child_process');
  const r = spawnSync('python', [path.join(root, 'scripts', 'buat-template-muat-ulang.py'), keluar],
    { input: JSON.stringify({ definisi, data, tanpaPetunjuk: true }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error('menulis Excel temuan gagal: ' + (r.stderr || r.error || '').toString().slice(-4000));
}

// ------------------------------------------------------------------------------------------
// Membaca dan memeriksa berkas
// ------------------------------------------------------------------------------------------
const norm = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
const kunciKode = (s) => norm(s).toUpperCase();

function tanggalDariSerial(n) {
  const p = XLSX.SSF.parse_date_code(n);
  if (!p || !p.y) return null;
  return { y: p.y, m: p.m, d: p.d, H: p.H || 0, M: p.M || 0, S: Math.floor(p.S || 0) };
}
const iso = ({ y, m, d }) => `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
const isoWaktuWib = ({ y, m, d, H = 0, M = 0, S = 0 }) =>
  `${iso({ y, m, d })}T${String(H).padStart(2, '0')}:${String(M).padStart(2, '0')}:${String(S).padStart(2, '0')}+07:00`;
function sahKalender(y, m, d) {
  const t = new Date(Date.UTC(y, m - 1, d));
  return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
}

// Bentuk resmi + sel tanggal Excel. Dalam --normalisasi-impor, nama bulan Indonesia/Inggris,
// tanggal dengan pemisah campur, dan jam juga diterima. Bentuk yang kehilangan informasi
// (mis. hanya bulan/tahun) tetap ditolak karena tanggalnya tidak boleh ditebak.
function uraiTanggalKetat(sel, denganWaktu = false) {
  if (sel.kosong) return { nilai: null };
  if (sel.tanggal) return { nilai: denganWaktu ? isoWaktuWib(sel.tanggal) : iso(sel.tanggal) };
  const s = sel.teks;
  let bagianTanggal = s, H = 0, M = 0, S = 0;
  if (normalisasiImpor) {
    const waktu = bagianTanggal.match(/^(.*?)[ T]+(\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?$/);
    if (waktu) {
      bagianTanggal = waktu[1].trim(); H = +waktu[2]; M = +waktu[3]; S = +(waktu[4] || 0);
      if (H > 23 || M > 59 || S > 59) return { galat: `jam pada "${s}" tidak sah` };
    }
    bagianTanggal = bagianTanggal.replace(/-{2,}/g, '-').trim();
  }
  let d, m, y, h;
  if ((h = bagianTanggal.match(/^(\d{1,2})[.-](\d{1,2})[.-](\d{2}|\d{4})$/))) { d = +h[1]; m = +h[2]; y = +h[3]; }
  else if (normalisasiImpor && (h = bagianTanggal.match(/^(\d{1,2})[./-](\d{1,2})[./-](\d{2}|\d{4})$/))) { d = +h[1]; m = +h[2]; y = +h[3]; }
  else if ((h = bagianTanggal.match(/^(\d{2})(\d{2})(\d{2})$/))) { d = +h[1]; m = +h[2]; y = +h[3]; }
  else if ((h = bagianTanggal.match(/^(\d{2})(\d{2})(\d{4})$/))) { d = +h[1]; m = +h[2]; y = +h[3]; }
  else if (normalisasiImpor && /^\d{7}$/.test(bagianTanggal)) {
    y = +bagianTanggal.slice(-4);
    const depan = bagianTanggal.slice(0, -4);
    const calon = [
      { d: +depan.slice(0, 1), m: +depan.slice(1) },
      { d: +depan.slice(0, 2), m: +depan.slice(2) },
    ].filter((x) => sahKalender(y, x.m, x.d));
    if (calon.length !== 1) return { galat: `format tanggal "${s}" ambigu (pakai dd-mmm-yyyy)` };
    d = calon[0].d; m = calon[0].m;
  }
  else if ((h = bagianTanggal.match(/^(\d{4})-(\d{2})-(\d{2})$/))) { y = +h[1]; m = +h[2]; d = +h[3]; }
  else if (normalisasiImpor && (h = bagianTanggal.match(/^(\d{1,2})[\s./-]+([A-Za-z]+)[\s./-]+(\d{2}|\d{4})$/)) && BULAN[h[2].toLowerCase()]) {
    d = +h[1]; m = BULAN[h[2].toLowerCase()]; y = +h[3];
  }
  else if (normalisasiImpor && (h = bagianTanggal.match(/^(\d{1,2})[./-](\d{1,2})(\d{4})$/))) {
    d = +h[1]; m = +h[2]; y = +h[3];
  }
  else if (normalisasiImpor && (h = bagianTanggal.match(/^(\d{1,2})(\d{1,2})[./-](\d{4})$/))) {
    d = +h[1]; m = +h[2]; y = +h[3];
  }
  else return { galat: `format tanggal "${s}" tidak dikenali (pakai dd-mmm-yyyy)` };
  if (y < 100) y += 2000;
  if (normalisasiImpor && !sahKalender(y, m, d) && d >= 1 && d <= 12 && m > 12 && m <= 31 && sahKalender(y, d, m)) {
    [d, m] = [m, d];
  }
  if (!sahKalender(y, m, d)) return { galat: `tanggal "${s}" tidak ada dalam kalender` };
  const hasil = { y, m, d, H, M, S };
  return { nilai: denganWaktu ? isoWaktuWib(hasil) : iso(hasil) };
}

// Tanggal Campaign Master tetap longgar (nama bulan Indonesia/Inggris, penuh/singkat), sama
// dengan rc_private.urai_tanggal_rc. Teksnya disimpan apa adanya; tanggalnya diurai server.
function uraiTanggalLonggar(sel) {
  if (sel.kosong) return { nilai: null, teks: null };
  if (sel.tanggal) return { nilai: iso(sel.tanggal), teks: `${String(sel.tanggal.d).padStart(2, '0')}-${String(sel.tanggal.m).padStart(2, '0')}-${sel.tanggal.y}` };
  const ketat = uraiTanggalKetat(sel);
  if (!ketat.galat) return { nilai: ketat.nilai, teks: sel.teks };
  const h = sel.teks.match(/^(\d{1,2})[\s./-]+([A-Za-z]+)[\s./-]+(\d{2}|\d{4})$/);
  if (h && BULAN[h[2].toLowerCase()]) {
    let y = +h[3]; if (y < 100) y += 2000;
    const m = BULAN[h[2].toLowerCase()], d = +h[1];
    if (sahKalender(y, m, d)) return { nilai: iso({ y, m, d }), teks: sel.teks };
  }
  return { nilai: null, teks: sel.teks, peringatan: `tanggal "${sel.teks}" tidak dapat diurai; disimpan sebagai teks saja` };
}

function angka(sel) {
  if (sel.kosong) return { nilai: null };
  if (sel.angka != null) return { nilai: sel.angka };
  const s = sel.teks.replace(/\s/g, '').replace(/^Rp\.?/i, '');
  // 1.234.567,89 (Indonesia) atau 1,234,567.89 / 1234567.89
  let t = s;
  if (/^-?\d{1,3}(\.\d{3})+(,\d+)?$/.test(t)) t = t.replace(/\./g, '').replace(',', '.');
  else if (/^-?\d{1,3}(,\d{3})+(\.\d+)?$/.test(t)) t = t.replace(/,/g, '');
  else if (/^-?\d+,\d+$/.test(t)) t = t.replace(',', '.');
  if (!/^-?\d+(\.\d+)?$/.test(t)) return { galat: `"${sel.teks}" bukan angka` };
  return { nilai: Number(t) };
}

function bacaSel(ws, r, c) {
  const cell = ws[XLSX.utils.encode_cell({ r, c })];
  if (!cell || cell.v == null || (cell.t === 's' && norm(cell.v) === '')) return { kosong: true, teks: '' };
  if (cell.t === 'n') {
    const fmt = cell.z || (cell.XF && cell.XF.numFmt) || '';
    if (fmt && XLSX.SSF.is_date(fmt)) {
      const t = tanggalDariSerial(cell.v);
      return { tanggal: t, teks: t ? iso(t) : String(cell.v) };
    }
    return { angka: cell.v, teks: Number.isInteger(cell.v) ? String(cell.v) : String(cell.v), numerik: true };
  }
  if (cell.t === 'd') {
    const t = { y: cell.v.getUTCFullYear(), m: cell.v.getUTCMonth() + 1, d: cell.v.getUTCDate() };
    return { tanggal: t, teks: iso(t) };
  }
  if (cell.t === 'b') return { teks: cell.v ? 'TRUE' : 'FALSE' };
  return { teks: norm(cell.v) };
}

async function bacaBerkas(berkas) {
  const wb = XLSX.read(new Uint8Array(await readFile(berkas)), { type: 'array', cellDates: false, cellNF: true, cellText: false });
  const galat = [], peringatan = [];
  const g = (lembar, baris, kolom, pesan) => galat.push({ lembar, baris, kolom, pesan });
  const p = (lembar, baris, kolom, pesan) => peringatan.push({ lembar, baris, kolom, pesan });
  const data = {};

  for (const [nama, def] of Object.entries(LEMBAR)) {
    const ws = wb.Sheets[nama];
    if (!ws) {
      if (!def.opsional) g(nama, '-', '-', `lembar "${nama}" tidak ada`);
      data[nama] = [];
      continue;
    }
    const jangkau = XLSX.utils.decode_range(ws['!ref'] || 'A1:A1');
    const judul = [];
    for (let c = jangkau.s.c; c <= jangkau.e.c; c++) judul.push({ c, nama: norm(bacaSel(ws, 0, c).teks) });
    const peta = {};
    for (const [kol, wajib] of def.kolom) {
      const k = judul.find((j) => j.nama.toLowerCase() === kol.toLowerCase());
      if (k) peta[kol] = k.c;
      else if (wajib) g(nama, 1, kol, `kolom wajib "${kol}" tidak ada di baris judul`);
    }
    for (const j of judul) {
      if (j.nama && !def.kolom.some(([kol]) => kol.toLowerCase() === j.nama.toLowerCase())) {
        p(nama, 1, j.nama, 'kolom tidak dikenal; diabaikan');
      }
    }
    const baris = [];
    for (let r = 1; r <= jangkau.e.r; r++) {
      const sel = {};
      let isi = false;
      for (const [kol] of def.kolom) {
        sel[kol] = peta[kol] == null ? { kosong: true, teks: '' } : bacaSel(ws, r, peta[kol]);
        if (!sel[kol].kosong) isi = true;
      }
      if (isi) baris.push({ baris: r + 1, sel });
    }
    data[nama] = baris;
  }
  return { data, galat, peringatan, g, p };
}

function periksa({ data, galat, peringatan, g, p }, depotDb) {
  const teksKode = (lembar, b, kol) => {
    const s = b.sel[kol];
    if (s.numerik && s.teks.length > 15) g(lembar, b.baris, kol, `angka ${s.teks.length} digit kehilangan ketelitian di Excel; format sel sebagai Text lalu ketik ulang`);
    else if (s.numerik && /^(No KTP|No NPWP|Nomor Rekening)$/.test(kol)) p(lembar, b.baris, kol, 'tersimpan sebagai angka; nol di depan (bila ada) sudah hilang');
    return s.kosong ? null : s.teks;
  };
  const wajib = (lembar, b, kol) => { if (b.sel[kol].kosong) { g(lembar, b.baris, kol, 'wajib diisi'); return false; } return true; };

  // ---- Depot ------------------------------------------------------------------------------
  const depot = new Map();
  for (const b of data.Depot) {
    if (!wajib('Depot', b, 'Kode Depot')) continue;
    const kode = kunciKode(b.sel['Kode Depot'].teks);
    if (depot.has(kode)) { g('Depot', b.baris, 'Kode Depot', `kode ${kode} ganda (juga baris ${depot.get(kode).baris})`); continue; }
    let abbr = b.sel['Abbr'].kosong ? null : kunciKode(b.sel['Abbr'].teks);
    // Diminta pemilik 10 Oktober 2026: "ABBR JKT/TU normalisasikan menjadi JKT aja" - bagian
    // sebelum garis miring dipakai bila bagian itu sendiri sah.
    if (normalisasiImpor && abbr && abbr.includes('/')) {
      const depan = abbr.split('/')[0].trim();
      if (/^[A-Z0-9]{2,10}$/.test(depan)) {
        p('Depot', b.baris, 'Abbr', `"${abbr}" dinormalkan menjadi "${depan}"`);
        abbr = depan;
      }
    }
    if (abbr && !/^[A-Z0-9]{2,10}$/.test(abbr)) g('Depot', b.baris, 'Abbr', `"${abbr}" harus 2-10 huruf besar/angka`);
    let emailTo = b.sel['Email TO'].kosong ? null : b.sel['Email TO'].teks;
    let emailCc = b.sel['Email CC'].kosong ? null : b.sel['Email CC'].teks;
    let emailDipindahKeCc = 0;
    if (normalisasiImpor && emailTo) {
      const to = emailTo.split(/[,;\s]+/).filter(Boolean);
      const cc = emailCc ? emailCc.split(/[,;\s]+/).filter(Boolean) : [];
      if (to.length > 4 && cc.length + (to.length - 4) <= 20) {
        const pindah = to.splice(4);
        emailDipindahKeCc = pindah.length;
        emailTo = to.join(', ');
        emailCc = [...cc, ...pindah].join(', ');
        p('Depot', b.baris, 'Email TO', `${pindah.length} alamat terakhir dipindahkan ke Email CC: ${pindah.join(', ')}`);
      }
    }
    for (const [kol, maks] of [['Email TO', 4], ['Email CC', 20]]) {
      const isi = kol === 'Email TO' ? emailTo : emailCc;
      if (!isi) continue;
      const alamat = isi.split(/[,;\s]+/).filter(Boolean);
      const saran = ' (perbaiki, atau kosongkan sel ini supaya nilai lama dipertahankan)';
      const catat = pertahankanWarisan ? p : g;
      const catatanWarisan = pertahankanWarisan ? ' (dipertahankan apa adanya dari ekspor database)' : saran;
      if (alamat.length > maks) catat('Depot', b.baris, kol, `${alamat.length} alamat; maksimal ${maks}` + catatanWarisan);
      for (const a of alamat) if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(a)) catat('Depot', b.baris, kol, `"${a}" bukan alamat email` + catatanWarisan);
    }
    if (depotDb && !depotDb.has(kode) && b.sel['Nama Depot'].kosong) g('Depot', b.baris, 'Nama Depot', `depot baru ${kode} wajib punya nama`);
    if (depotDb && !depotDb.has(kode)) p('Depot', b.baris, 'Kode Depot', `depot BARU ${kode}; belum ada akun yang punya yurisdiksi atasnya`);
    depot.set(kode, { baris: b.baris, kode, nama: b.sel['Nama Depot'].kosong ? null : b.sel['Nama Depot'].teks, abbr,
      region: b.sel['Region'].kosong ? null : b.sel['Region'].teks, alamat: b.sel['Alamat'].kosong ? null : b.sel['Alamat'].teks,
      emailTo, emailCc, emailDipindahKeCc,
      link: b.sel['Link Master'].kosong ? null : b.sel['Link Master'].teks });
  }
  const depotDikenal = (kode) => depot.has(kode) || (depotDb ? depotDb.has(kode) : true);

  // ---- Campaign ---------------------------------------------------------------------------
  const campaign = new Map();
  if (!data.Campaign.length) g('Campaign', '-', '-', 'lembar Campaign kosong');
  for (const b of data.Campaign) {
    const okKode = wajib('Campaign', b, 'Code Campaign');
    wajib('Campaign', b, 'Nama Campaign');
    wajib('Campaign', b, 'Jenis CB');
    if (!okKode) continue;
    const kode = norm(b.sel['Code Campaign'].teks);
    const k = kode.toUpperCase();
    if (campaign.has(k)) { g('Campaign', b.baris, 'Code Campaign', `kode ${kode} ganda (juga baris ${campaign.get(k).baris})`); continue; }
    const jenis = norm(b.sel['Jenis CB'].teks).toLowerCase();
    if (jenis && !JENIS_CAMPAIGN.includes(jenis)) g('Campaign', b.baris, 'Jenis CB', `"${b.sel['Jenis CB'].teks}" bukan Transfer, CN, Rebate atau Voucher`);
    const st = b.sel['Status Campaign'].kosong ? 'active' : norm(b.sel['Status Campaign'].teks).toLowerCase();
    if (!['active', 'inactive', 'cleared'].includes(st)) g('Campaign', b.baris, 'Status Campaign', `"${b.sel['Status Campaign'].teks}" bukan active, inactive atau cleared`);
    if (b.sel['Status Pajak'].kosong) p('Campaign', b.baris, 'Status Pajak', 'kosong: gross up dihitung seolah pajak tidak ditanggung perusahaan');
    const tgl = {};
    for (const kol of ['Periode Start', 'Periode End', 'Periode SO Start', 'Periode SO End', 'Periode Billing Start', 'Periode Billing End']) {
      const h = uraiTanggalLonggar(b.sel[kol]);
      if (h.peringatan) p('Campaign', b.baris, kol, h.peringatan);
      tgl[kol] = h;
    }
    const terbalik = (a, z, nama, catat = g) => { if (tgl[a].nilai && tgl[z].nilai && tgl[z].nilai < tgl[a].nilai) catat('Campaign', b.baris, a, `periode ${nama} terbalik: ${tgl[a].teks} sampai ${tgl[z].teks}` + (catat === p ? ' (hampir pasti salah ketik; periksa)' : '')); };
    terbalik('Periode Start', 'Periode End', 'campaign', p);
    terbalik('Periode SO Start', 'Periode SO End', 'SO');
    terbalik('Periode Billing Start', 'Periode Billing End', 'billing');
    if (!tgl['Periode Start'].nilai || !tgl['Periode End'].nilai) p('Campaign', b.baris, 'Periode Start', 'periode campaign kosong/tak terurai: dokumen campaign ini tidak punya periode dasar');
    campaign.set(k, { baris: b.baris, kode, nama: norm(b.sel['Nama Campaign'].teks), jenis: b.sel['Jenis CB'].teks || null,
      pajak: b.sel['Status Pajak'].kosong ? null : b.sel['Status Pajak'].teks, status: st,
      ps: tgl['Periode Start'].teks, pe: tgl['Periode End'].teks, sos: tgl['Periode SO Start'].teks, soe: tgl['Periode SO End'].teks,
      bis: tgl['Periode Billing Start'].teks, bie: tgl['Periode Billing End'].teks });
  }

  // ---- Customer ---------------------------------------------------------------------------
  const customer = new Map();
  if (!data.Customer.length) g('Customer', '-', '-', 'lembar Customer kosong');
  for (const b of data.Customer) {
    const okKode = wajib('Customer', b, 'Customer Code');
    wajib('Customer', b, 'Customer Name');
    // Pelanggan tanpa depot sah (ada di prod), tetapi hanya terlihat oleh System Manager.
    const okDepot = !b.sel['Kode Depot'].kosong;
    if (!okDepot) p('Customer', b.baris, 'Kode Depot', 'kosong: pelanggan ini hanya terlihat oleh System Manager sampai diberi depot (klaimnya tetap memetakan depot klaim)');
    if (!okKode) continue;
    const kode = teksKode('Customer', b, 'Customer Code');
    const k = kode.toUpperCase();
    if (customer.has(k)) { g('Customer', b.baris, 'Customer Code', `kode ${kode} ganda (juga baris ${customer.get(k).baris})`); continue; }
    const depots = okDepot ? [...new Set(b.sel['Kode Depot'].teks.split(/[,;]+/).map(kunciKode).filter(Boolean))] : [];
    for (const d of depots) if (!depotDikenal(d)) g('Customer', b.baris, 'Kode Depot', `depot ${d} tidak ada (di database maupun lembar Depot)`);
    // Subyek Pajak diturunkan database: NPWP -> Badan, hanya KTP -> Perorangan.
    if (b.sel['No NPWP'].kosong && b.sel['No KTP'].kosong) p('Customer', b.baris, 'No NPWP', 'NPWP dan KTP kosong: Subyek Pajak tidak diketahui, gross up dihitung tangga Perorangan');
    customer.set(k, { baris: b.baris, kode, nama: norm(b.sel['Customer Name'].teks), depots,
      top: teksKode('Customer', b, 'TOP'), ktp: teksKode('Customer', b, 'No KTP'), npwp: teksKode('Customer', b, 'No NPWP'),
      namaRek: b.sel['Nama Rekening'].kosong ? null : b.sel['Nama Rekening'].teks, noRek: teksKode('Customer', b, 'Nomor Rekening'),
      bank: b.sel['Nama Bank'].kosong ? null : b.sel['Nama Bank'].teks, cp: b.sel['Contact Person'].kosong ? null : b.sel['Contact Person'].teks });
  }

  // ---- Klaim ------------------------------------------------------------------------------
  const klaim = [];
  const noDoc = new Map();
  const pemetaanBaru = new Map();
  if (!data.Klaim.length) g('Klaim', '-', '-', 'lembar Klaim kosong');
  // --temuan-duplikat (diminta pemilik 10 Oktober 2026): SEMUA salinan ditahan, bukan hanya salinan
  // kedua, karena yang benar tidak dapat ditentukan dari urutan baris. Dua aturan:
  //   1. No Document ganda;
  //   2. Code Campaign + Cust Code + Cashback After Tax sama (klaim yang tercatat dua kali).
  const salinanDoc = new Map(), salinanNilai = new Map();
  if (temuanDuplikat) {
    const catat = (peta, kunci, isi) => { if (!peta.has(kunci)) peta.set(kunci, []); peta.get(kunci).push(isi); };
    for (const b of data.Klaim) {
      const s = b.sel;
      if (!s['No Document'].kosong) catat(salinanDoc, s['No Document'].teks.toUpperCase(), b.baris);
      const cb = angka(s['Cashback After Tax']);
      if (s['Code Campaign'].kosong || s['Cust Code'].kosong || cb.galat || cb.nilai == null) continue;
      catat(salinanNilai, [norm(s['Code Campaign'].teks).toUpperCase(), norm(s['Cust Code'].teks).toUpperCase(), Math.round(cb.nilai * 100)].join('|'),
        { baris: b.baris, doc: s['No Document'].teks });
    }
  }
  for (const b of data.Klaim) {
    const ok = ['No Document', 'Kode Depot', 'Cust Code', 'Code Campaign', 'Cashback After Tax', 'Status'].map((k) => wajib('Klaim', b, k)).every(Boolean);
    if (!ok) continue;
    const doc = teksKode('Klaim', b, 'No Document');
    const kd = doc.toUpperCase();
    if (temuanDuplikat) {
      const semuaDoc = salinanDoc.get(kd) || [];
      if (semuaDoc.length > 1) {
        g('Klaim', b.baris, 'No Document', `${doc} ganda (baris ${semuaDoc.join(', ')}); semua salinan ditahan sebagai temuan`);
        continue;
      }
      const cb = angka(b.sel['Cashback After Tax']).nilai;
      const kembar = cb == null ? [] : (salinanNilai.get([norm(b.sel['Code Campaign'].teks).toUpperCase(), norm(b.sel['Cust Code'].teks).toUpperCase(), Math.round(cb * 100)].join('|')) || [])
        .filter((x) => x.baris !== b.baris);
      if (kembar.length) {
        g('Klaim', b.baris, 'Cashback After Tax', `Code Campaign + Cust Code + Cashback After Tax sama dengan ${kembar.map((x) => `baris ${x.baris} (${x.doc})`).join(', ')}; semua salinan ditahan sebagai temuan`);
      }
    }
    if (noDoc.has(kd)) { g('Klaim', b.baris, 'No Document', `${doc} ganda (juga baris ${noDoc.get(kd)})`); continue; }
    noDoc.set(kd, b.baris);
    const dep = kunciKode(b.sel['Kode Depot'].teks);
    if (!depotDikenal(dep)) g('Klaim', b.baris, 'Kode Depot', `depot ${dep} tidak ada`);
    const custKode = teksKode('Klaim', b, 'Cust Code');
    const cust = customer.get(custKode.toUpperCase());
    if (!cust) {
      const pesan = `pelanggan ${custKode} tidak ada di lembar Customer`;
      if (izinkanCustomerTidakAda) p('Klaim', b.baris, 'Cust Code', `${pesan}; klaim dimuat tanpa master dan tidak dapat diproses`);
      else g('Klaim', b.baris, 'Cust Code', pesan);
    }
    const camp = campaign.get(norm(b.sel['Code Campaign'].teks).toUpperCase());
    if (!camp) g('Klaim', b.baris, 'Code Campaign', `campaign ${b.sel['Code Campaign'].teks} tidak ada di lembar Campaign`);
    if (cust && !cust.depots.includes(dep)) {
      const kunci = cust.kode + '|' + dep;
      if (!pemetaanBaru.has(kunci)) {
        pemetaanBaru.set(kunci, b.baris);
        p('Klaim', b.baris, 'Kode Depot', `pelanggan ${cust.kode} belum terdaftar di depot ${dep}; pemetaannya ditambahkan`);
      }
    }
    const status = STATUS[norm(b.sel['Status'].teks).toLowerCase()];
    if (!status) g('Klaim', b.baris, 'Status', `"${b.sel['Status'].teks}" bukan status yang dikenal`);
    const nilai = {};
    for (const kol of ['Net Value', 'Volume', 'Cashback After Tax', 'Total Tagihan']) {
      const h = angka(b.sel[kol]);
      if (h.galat) g('Klaim', b.baris, kol, h.galat);
      else if (h.nilai != null && h.nilai < 0) g('Klaim', b.baris, kol, 'tidak boleh negatif');
      nilai[kol] = h.nilai;
    }
    let jenis = null;
    const jenisAda = !b.sel['Jenis CB'].kosong;
    if (jenisAda) {
      jenis = jenisKlaimDari(b.sel['Jenis CB'].teks);
      if (!jenis) g('Klaim', b.baris, 'Jenis CB', `"${b.sel['Jenis CB'].teks}" bukan Transfer, CN, Rebate atau Rebate Manual`);
    }
    const tgl = {}, legacy = {};
    const kunciLegacy = {
      'Tgl Lunas': 'paid_on', 'Tgl Submitted': 'uploaded_at', 'Tgl Approved': 'approved_at',
      'Tgl Released': 'released_at', 'Tgl Claimed': 'claimed_at', 'Tgl Done': 'cleared_at',
      'Hold SO Start': 'extend_so_start', 'Hold SO End': 'extend_so_end',
      'Hold Billing Start': 'extend_billing_start', 'Hold Billing End': 'extend_billing_end',
    };
    for (const kol of ['Tgl Lunas', 'Tgl Submitted', 'Tgl Approved', 'Tgl Released', 'Tgl Claimed', 'Tgl Done',
                       'Hold SO Start', 'Hold SO End', 'Hold Billing Start', 'Hold Billing End']) {
      const h = uraiTanggalKetat(b.sel[kol], KOLOM_WAKTU.has(kol));
      if (h.galat && pertahankanWarisan) {
        legacy[kunciLegacy[kol]] = b.sel[kol].teks;
        p('Klaim', b.baris, kol, h.galat + '; teks lama dipertahankan di legacy_dates');
      } else if (h.galat) g('Klaim', b.baris, kol, h.galat);
      tgl[kol] = h.nilai || null;
    }
    let sebelumHold = null;
    if (status === 'on_hold') {
      sebelumHold = b.sel['Status Sebelum Hold'].kosong ? 'not_yet' : STATUS[norm(b.sel['Status Sebelum Hold'].teks).toLowerCase()];
      if (!sebelumHold || ['on_hold', 'expired', 'done'].includes(sebelumHold)) g('Klaim', b.baris, 'Status Sebelum Hold', `"${b.sel['Status Sebelum Hold'].teks}" tidak sah untuk dokumen On Hold`);
      for (const [a, z] of [['Hold SO Start', 'Hold SO End'], ['Hold Billing Start', 'Hold Billing End']]) {
        if (tgl[a] && tgl[z] && tgl[z] < tgl[a]) g('Klaim', b.baris, a, 'periode perpanjangan terbalik');
      }
    } else if (['Status Sebelum Hold', 'Hold SO Start', 'Hold SO End', 'Hold Billing Start', 'Hold Billing End'].some((k) => !b.sel[k].kosong)) {
      p('Klaim', b.baris, 'Status', 'kolom Hold diisi tetapi status bukan On Hold; diabaikan');
    }
    // Kelengkapan jejak per tahap - peringatan saja; data lama tidak selalu lengkap.
    const tingkat = URUT_STATUS.indexOf(status);
    const butuh = [[1, 'Batch Submitted'], [3, 'Batch Released'], [4, 'Batch Claimed'], [5, 'Batch Done']];
    for (const [min, kol] of butuh) if (tingkat >= min && b.sel[kol].kosong) p('Klaim', b.baris, kol, `status ${b.sel['Status'].teks} tetapi ${kol} kosong`);
    for (const kol of ['Batch Submitted', 'Batch Released', 'Batch Claimed', 'Batch Done']) {
      const v = teksKode('Klaim', b, kol);
      if (v && !/^\d{15}$/.test(v)) p('Klaim', b.baris, kol, `"${v}" bukan nomor batch 15 digit`);
    }
    const ktp = teksKode('Klaim', b, 'No KTP');
    const npwp = teksKode('Klaim', b, 'No NPWP');
    klaim.push({ baris: b.baris, noDoc: doc, depot: dep, cust: custKode, customerAda: !!cust, camp: camp ? camp.kode : null, status,
      net: nilai['Net Value'], vol: nilai['Volume'], cb: nilai['Cashback After Tax'], tagih: nilai['Total Tagihan'],
      jenis, jenisAda, top: teksKode('Klaim', b, 'TOP'), lunas: tgl['Tgl Lunas'],
      ktp, npwp, taxSumber: npwp ? 'Badan' : (ktp ? 'Perorangan' : null),
      namaRek: b.sel['Nama Rekening'].kosong ? null : b.sel['Nama Rekening'].teks, noRek: teksKode('Klaim', b, 'Nomor Rekening'),
      bank: b.sel['Bank'].kosong ? null : b.sel['Bank'].teks,
      bUp: teksKode('Klaim', b, 'Batch Submitted'), tUp: tgl['Tgl Submitted'], tAp: tgl['Tgl Approved'],
      bRel: teksKode('Klaim', b, 'Batch Released'), tRel: tgl['Tgl Released'],
      bCl: teksKode('Klaim', b, 'Batch Claimed'), tCl: tgl['Tgl Claimed'],
      bClr: teksKode('Klaim', b, 'Batch Done'), tClr: tgl['Tgl Done'],
      sebelumHold, hSoA: tgl['Hold SO Start'], hSoZ: tgl['Hold SO End'], hBiA: tgl['Hold Billing Start'], hBiZ: tgl['Hold Billing End'],
      legacy });
  }

  // Pelanggan memperoleh pemetaan depot dari kliamnya bila lembar Customer belum memuatnya.
  for (const kunci of pemetaanBaru.keys()) {
    const [kode, dep] = kunci.split('|');
    const c = customer.get(kode.toUpperCase());
    if (c && !c.depots.includes(dep)) c.depots.push(dep);
  }
  return { depot: [...depot.values()], campaign: [...campaign.values()], customer: [...customer.values()], klaim, galat, peringatan };
}

// Nomor batch = tahap(2) + suffix(3) + ddmmyy(6) + urutan(4). Penghitung per tahap/suffix/tanggal
// dinaikkan setinggi urutan tertinggi yang dimuat, supaya batch berikutnya tidak bentrok.
function penghitungBatch(klaim) {
  const peta = new Map();
  for (const k of klaim) for (const b of [k.bUp, k.bRel, k.bCl, k.bClr]) {
    const h = b && b.match(/^(\d{2})(\d{3})(\d{2})(\d{2})(\d{2})(\d{4})$/);
    if (!h) continue;
    const y = 2000 + +h[5], m = +h[4], d = +h[3];
    if (!sahKalender(y, m, d)) continue;
    const kunci = `${h[1]}|${h[2]}|${iso({ y, m, d })}`;
    peta.set(kunci, Math.max(peta.get(kunci) || 0, +h[6]));
  }
  return [...peta].map(([k, counter]) => { const [stage, suffix, tanggal] = k.split('|'); return { stage, suffix, tanggal, counter }; });
}

function ringkas(h) {
  const perStatus = {};
  for (const k of h.klaim) {
    const s = (perStatus[k.status] ??= { n: 0, cb: 0 });
    s.n++; s.cb += k.cb || 0;
  }
  return {
    depot: h.depot.length, campaign: h.campaign.length, customer: h.customer.length,
    pemetaanDepot: h.customer.reduce((a, c) => a + c.depots.length, 0), klaim: h.klaim.length,
    totalCbNet: Math.round(h.klaim.reduce((a, k) => a + (k.cb || 0), 0) * 100) / 100, perStatus,
    batchUploadTerisi: h.klaim.filter((k) => k.bUp).length,
    batchUploadKosong: h.klaim.filter((k) => !k.bUp).length,
    jenisCbDariBerkas: h.klaim.filter((k) => k.jenis).length,
    jenisCbDariMaster: h.klaim.filter((k) => !k.jenisAda).length,
    jenisCbTidakSah: h.klaim.filter((k) => k.jenisAda && !k.jenis).length,
    klaimTanpaCustomerMaster: h.klaim.filter((k) => !k.customerAda).length,
    emailDepotDipindahKeCc: h.depot.reduce((n, d) => n + (d.emailDipindahKeCc || 0), 0),
    timestampDenganJam: h.klaim.reduce((n, k) => n + [k.tUp, k.tAp, k.tRel, k.tCl, k.tClr]
      .filter((v) => v && !/T00:00:00\+07:00$/.test(v)).length, 0),
  };
}

// Memisahkan setiap baris yang mempunyai galat fatal, lalu memeriksa ulang hasilnya. Pemeriksaan
// berulang penting karena membuang satu baris master dapat membuat klaim yang merujuknya menjadi
// tidak sah. Baris sumber tidak pernah diubah; hanya salinan dalam memori yang difilter.
function periksaTanpaGalat(dataAsli, galatDasar, peringatanDasar, depotDb) {
  const skip = new Map(Object.keys(LEMBAR).map((nama) => [nama, new Map()]));
  const semuaGalat = [];
  const tahap = [];
  let h = null;
  let ringAwal = null;
  const campaignSumber = new Map();
  const klaimSumber = new Map(dataAsli.Klaim.map((b) => [Number(b.baris), b]));
  for (const b of dataAsli.Campaign) {
    const kode = norm(b.sel['Code Campaign']?.teks).toUpperCase();
    if (!kode) continue;
    if (!campaignSumber.has(kode)) campaignSumber.set(kode, []);
    campaignSumber.get(kode).push(Number(b.baris));
  }
  const nilaiSel = (s) => {
    if (!s || s.kosong) return null;
    if (s.angka != null) return s.angka;
    if (s.tanggal) return isoWaktuWib(s.tanggal);
    return s.teks;
  };

  const dataTersaring = () => Object.fromEntries(Object.keys(LEMBAR).map((nama) => [
    nama,
    dataAsli[nama].filter((b) => !skip.get(nama).has(b.baris)),
  ]));
  const validasi = (data) => {
    const galat = galatDasar.map((x) => ({ ...x }));
    const peringatan = peringatanDasar.map((x) => ({ ...x }));
    const g = (lembar, baris, kolom, pesan) => galat.push({ lembar, baris, kolom, pesan });
    const p = (lembar, baris, kolom, pesan) => peringatan.push({ lembar, baris, kolom, pesan });
    const hasil = periksa({ data, galat, peringatan, g, p }, depotDb);
    hasil.galat = hasil.galat.map((x) => {
      if (x.lembar !== 'Klaim' || x.kolom !== 'Code Campaign' || !/tidak ada di lembar Campaign/i.test(x.pesan)) return x;
      const sumberKlaim = klaimSumber.get(Number(x.baris));
      const kodeTampil = norm(sumberKlaim?.sel['Code Campaign']?.teks);
      const kandidat = campaignSumber.get(kodeTampil.toUpperCase()) || [];
      const masterPending = kandidat.filter((baris) => skip.get('Campaign').has(baris));
      if (!masterPending.length) return x;
      const detail = masterPending.flatMap((baris) => skip.get('Campaign').get(baris) || [])
        .map((temuan) => `${temuan.kolom}: ${temuan.pesan}`).join('; ');
      return {
        ...x,
        pesan: `campaign ${kodeTampil} ada di lembar Campaign baris ${masterPending.join(', ')}, tetapi Campaign Master pending/invalid${detail ? `: ${detail}` : ''}`,
      };
    });
    return hasil;
  };

  for (let putaran = 0; putaran < 20; putaran++) {
    h = validasi(dataTersaring());
    if (putaran === 0) ringAwal = ringkas(h);
    if (!h.galat.length) break;
    const namaTahap = putaran === 0 ? 'awal' : `turunan-${putaran}`;
    const dapatDilewati = h.galat.filter((x) => Object.hasOwn(LEMBAR, x.lembar) && Number.isInteger(Number(x.baris)));
    const struktural = h.galat.filter((x) => !Object.hasOwn(LEMBAR, x.lembar) || !Number.isInteger(Number(x.baris)));
    tahap.push({ tahap: namaTahap, jumlahGalat: h.galat.length, jumlahBarisBaru: new Set(dapatDilewati.map((x) => `${x.lembar}|${x.baris}`)).size });
    semuaGalat.push(...h.galat.map((x) => ({ tahap: namaTahap, ...x })));
    if (struktural.length) break;

    let baru = 0;
    for (const x of dapatDilewati) {
      const baris = Number(x.baris);
      const perLembar = skip.get(x.lembar);
      if (!perLembar.has(baris)) { perLembar.set(baris, []); baru++; }
      perLembar.get(baris).push({ tahap: namaTahap, kolom: x.kolom, pesan: x.pesan });
    }
    if (!baru) break;
  }

  const pending = {};
  for (const [nama, def] of Object.entries(LEMBAR)) {
    const sumber = new Map(dataAsli[nama].map((b) => [b.baris, b]));
    pending[nama] = [...skip.get(nama)].sort((a, b) => a[0] - b[0]).map(([baris, alasan]) => {
      const sumberBaris = sumber.get(baris);
      return {
        barisSumber: baris,
        jumlahGalat: alasan.length,
        alasan: alasan.map((x) => `${x.kolom}: ${x.pesan}`).join(' | '),
        tahap: [...new Set(alasan.map((x) => x.tahap))].join(', '),
        data: Object.fromEntries(def.kolom.map(([kol]) => [kol, nilaiSel(sumberBaris?.sel[kol])])),
      };
    });
  }
  const sumberKlaim = new Map(dataAsli.Klaim.map((b) => [b.baris, b]));
  const klaimTanpaCustomerMaster = h.klaim.filter((k) => !k.customerAda).map((k) => {
    const sumberBaris = sumberKlaim.get(k.baris);
    return {
      barisSumber: k.baris,
      custCode: k.cust,
      noDocument: k.noDoc,
      statusProses: 'Diblokir sampai Customer Master tersedia',
      alasan: `Customer ${k.cust} tidak ada di lembar Customer`,
      data: Object.fromEntries(LEMBAR.Klaim.kolom.map(([kol]) => [kol, nilaiSel(sumberBaris?.sel[kol])])),
    };
  });
  return { h, semuaGalat, tahap, pending, ringAwal, klaimTanpaCustomerMaster };
}

// ------------------------------------------------------------------------------------------
// Database (Management API, sama seperti scripts/apply-sql.mjs)
// ------------------------------------------------------------------------------------------
async function sambung(namaEnv) {
  const daftar = JSON.parse(await readFile(path.join(root, 'config', 'environments.json'), 'utf8'));
  const env = (daftar.supabase_projects || {})[namaEnv];
  if (!env || !env.project_ref) throw new Error(`lingkungan "${namaEnv}" tidak dikenal`);
  if (namaEnv === 'prod' && env.project_ref !== 'vvojshgcduqlugngpzkj') {
    throw new Error(`ref prod tercatat ${env.project_ref}, bukan vvojshgcduqlugngpzkj - berhenti`);
  }
  const namaVar = env.token_env || 'SUPABASE_ACCESS_TOKEN';
  let token = process.env[namaVar];
  if (!token) {
    const isi = await readFile(path.join(root, '.env'), 'utf8').catch(() => '');
    for (const l of isi.split(/\r?\n/)) { const m = l.match(new RegExp('^\\s*' + namaVar + '\\s*=\\s*(.+?)\\s*$')); if (m) token = m[1].replace(/^["']|["']$/g, ''); }
  }
  if (!token) throw new Error(`${namaVar} belum ada di .env`);
  const API = `https://api.supabase.com/v1/projects/${env.project_ref}/database/query`;
  const sql = async (q) => {
    for (let percobaan = 0; ; percobaan++) {
      const res = await fetch(API, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ query: q }) });
      const teks = await res.text();
      if (res.ok) { try { return JSON.parse(teks); } catch { return []; } }
      if (res.status === 429 && percobaan < 7) {
        const jeda = Math.min(800 * (2 ** percobaan), 15000);
        process.stdout.write(` [rate limit, ulang ${percobaan + 1} dalam ${Math.round(jeda / 1000)} dtk] `);
        await new Promise((selesai) => setTimeout(selesai, jeda));
        continue;
      }
      throw new Error(`HTTP ${res.status}: ${teks.slice(0, 600)}`);
    }
  };
  console.log(`\n  \x1b[${namaEnv === 'prod' ? '41' : '43'}m\x1b[30m  ${namaEnv.toUpperCase()}  \x1b[0m  project ${env.project_ref}\n`);
  return { sql, ref: env.project_ref };
}

const lit = (v) => (v == null ? 'null' : "'" + String(v).replace(/'/g, "''") + "'");
// Tag dollar-quote acak per kiriman: isi data tidak mungkin menutup literalnya lebih awal.
const jsonLit = (o) => { const t = '$d' + randomUUID().replace(/-/g, '') + '$'; return t + JSON.stringify(o) + t + '::jsonb'; };

const TABEL_CADANGAN = [
  ['public.depots', 'depot_code'], ['public.campaigns', 'campaign_code'], ['public.customers', 'customer_code'],
  ['public.customer_depots', 'customer_id, depot_id'], ['public.claims', 'no_doc'], ['rc_private.claim_sensitive', 'claim_id'],
  ['public.claim_status_history', 'id'], ['public.excluded_campaigns', 'campaign_id'],
  ['public.timetable_not_achieved', 'depot_id, campaign_id'], ['rc_private.batch_counters', 'stage, suffix, business_date'],
  ['public.campaign_not_participating', 'id'], ['public.activity_logs', 'id'],
];

async function cadangkan(db, folder) {
  await mkdir(folder, { recursive: true });
  const ringkasan = {};
  for (const [tabel, urut] of TABEL_CADANGAN) {
    const semua = [];
    for (let offset = 0; ; offset += 1000) {
      const r = await db.sql(`select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) as baris from (select * from ${tabel} order by ${urut} limit 1000 offset ${offset}) t;`);
      const baris = r[0].baris || [];
      semua.push(...baris);
      if (baris.length < 1000) break;
    }
    await writeFile(path.join(folder, tabel + '.json'), JSON.stringify(semua));
    ringkasan[tabel] = semua.length;
    console.log(`  cadangan ${tabel.padEnd(30)} ${String(semua.length).padStart(7)} baris`);
  }
  await writeFile(path.join(folder, 'ringkasan.json'), JSON.stringify({ dibuat: new Date().toISOString(), ringkasan }, null, 2));
  return ringkasan;
}

// Staging: skema privat sementara. Tidak ada grant untuk anon/authenticated, jadi tidak
// terjangkau lewat API publik. Dihapus setelah pemuatan berhasil.
async function siapkanStaging(db) {
  await db.sql(`create schema if not exists rc_muat_ulang;
    revoke all on schema rc_muat_ulang from public, anon, authenticated;
    create table if not exists rc_muat_ulang.baris(sesi uuid not null, jenis text not null, urut int not null, data jsonb not null,
      primary key (sesi, jenis, urut));
    revoke all on all tables in schema rc_muat_ulang from public, anon, authenticated;`);
}
async function kirimStaging(db, sesi, jenis, rows, ukuran = 1200) {
  for (let i = 0; i < rows.length; i += ukuran) {
    const potong = rows.slice(i, i + ukuran).map((data, j) => ({ urut: i + j, data }));
    await db.sql(`insert into rc_muat_ulang.baris(sesi, jenis, urut, data)
      select ${lit(sesi)}::uuid, ${lit(jenis)}, (x->>'urut')::int, x->'data' from jsonb_array_elements(${jsonLit(potong)}) x
      on conflict do nothing;`);
    process.stdout.write('.');
    if (i + ukuran < rows.length && ukuran >= 1000) await new Promise((selesai) => setTimeout(selesai, 800));
  }
}

// ------------------------------------------------------------------------------------------
// Pertukaran atomik
// ------------------------------------------------------------------------------------------
// Nilai berkas yang sama dengan Customer Master kecuali nol di depannya diganti nilai master.
const utuhkanNol = (berkas, master) => `case when ${berkas} ~ '^[0-9]+$' and ${master} ~ '^[0-9]+$'
      and length(${berkas}) < length(${master}) and ltrim(${master}, '0') = ltrim(${berkas}, '0')
    then ${master} else coalesce(${berkas}, ${master}) end`;

function sqlTukar(sesi, harap) {
  const potretKondisi = hapusKondisiLama ? '' : `
  create temp table _ex on commit drop as
    select c.campaign_code, e.excluded_by, e.excluded_at, e.reason
      from public.excluded_campaigns e join public.campaigns c on c.id = e.campaign_id;
  create temp table _na on commit drop as
    select d.depot_code, c.campaign_code, na.marked_by, na.marked_at, na.note
      from public.timetable_not_achieved na join public.depots d on d.id = na.depot_id join public.campaigns c on c.id = na.campaign_id;
  create temp table _np on commit drop as
    select c.campaign_code, d.depot_code, n.region, n.catatan, n.dibuat_oleh, n.dibuat_pada
      from public.campaign_not_participating n join public.campaigns c on c.id = n.campaign_id
      left join public.depots d on d.id = n.depot_id;`;
  const pulihkanKondisi = hapusKondisiLama ? '' : `
  insert into public.excluded_campaigns(campaign_id, excluded_by, excluded_at, reason)
  select c.id, x.excluded_by, x.excluded_at, x.reason from _ex x join public.campaigns c on c.campaign_code = x.campaign_code
  on conflict do nothing;
  insert into public.timetable_not_achieved(depot_id, campaign_id, marked_by, marked_at, note)
  select d.id, c.id, x.marked_by, x.marked_at, x.note from _na x
    join public.depots d on d.depot_code = x.depot_code join public.campaigns c on c.campaign_code = x.campaign_code
  on conflict do nothing;
  insert into public.campaign_not_participating(campaign_id, depot_id, region, catatan, dibuat_oleh, dibuat_pada)
  select c.id, d.id, x.region, x.catatan, x.dibuat_oleh, x.dibuat_pada from _np x
    join public.campaigns c on c.campaign_code = x.campaign_code
    left join public.depots d on d.depot_code = x.depot_code
   where x.region is not null or d.id is not null
  on conflict do nothing;`;
  return `
do $tukar$
declare
  v_sesi uuid := ${lit(sesi)}::uuid;
  n int; v_sum numeric; e text := '';
begin
  perform pg_advisory_xact_lock(hashtextextended('rc-muat-ulang', 0));
  -- Pengguna yang sedang menulis menunggu sampai pertukaran selesai (beberapa detik).
  lock table public.claims, public.customers, public.campaigns, public.customer_depots,
             rc_private.claim_sensitive, public.claim_status_history, public.activity_logs in share row exclusive mode;

  -- 0. Staging lengkap?
  if (select count(*) from rc_muat_ulang.baris where sesi=v_sesi and jenis='klaim') <> ${harap.klaim}
  or (select count(*) from rc_muat_ulang.baris where sesi=v_sesi and jenis='customer') <> ${harap.customer}
  or (select count(*) from rc_muat_ulang.baris where sesi=v_sesi and jenis='campaign') <> ${harap.campaign}
  or (select count(*) from rc_muat_ulang.baris where sesi=v_sesi and jenis='depot') <> ${harap.depot} then
    raise exception 'DITOLAK: staging tidak lengkap; kirim ulang.'; end if;

  -- 1. Potret pengaturan lama hanya bila memang diminta untuk dipertahankan.
${potretKondisi}

  -- 2. Kosongkan.
${hapusKondisiLama ? '  delete from public.activity_logs;' : ''}
  delete from public.excluded_campaigns;
  delete from public.timetable_not_achieved;
  delete from public.campaign_not_participating;
  delete from rc_private.claim_sensitive;
  delete from public.claim_status_history;
  delete from public.claims;
  delete from public.customer_depots;
  delete from public.customers;
  delete from public.campaigns;   -- excluded_campaigns & timetable_not_achieved ikut (CASCADE)

  -- 3. Depot: perbarui / tambah, tidak pernah hapus.
  --    Sel kosong = nilai lama dipertahankan.
  update public.depots dp set
    depot_name = coalesce(x.data->>'nama', dp.depot_name), abbr = coalesce(x.data->>'abbr', dp.abbr),
    region = coalesce(x.data->>'region', dp.region), address = coalesce(x.data->>'alamat', dp.address),
    email_to = coalesce(x.data->>'emailTo', dp.email_to), email_cc = coalesce(x.data->>'emailCc', dp.email_cc),
    master_link = coalesce(x.data->>'link', dp.master_link), updated_at = now()
    from rc_muat_ulang.baris x where x.sesi=v_sesi and x.jenis='depot' and dp.depot_code = x.data->>'kode';
  insert into public.depots(depot_code, depot_name, abbr, region, address, email_to, email_cc, master_link)
  select x.data->>'kode', x.data->>'nama', x.data->>'abbr', x.data->>'region', x.data->>'alamat',
         x.data->>'emailTo', x.data->>'emailCc', x.data->>'link'
    from rc_muat_ulang.baris x where x.sesi=v_sesi and x.jenis='depot'
     and not exists(select 1 from public.depots d where d.depot_code = x.data->>'kode');

  -- 4. Campaign - dimasukkan AKTIF dulu: jaga_status_campaign menolak klaim baru untuk campaign
  --    inactive/cleared. Status akhirnya ditetapkan di langkah 7.
  insert into public.campaigns(campaign_code, campaign_name, cashback_type, tax_status, status,
    period_start_text, period_end_text, period_start, period_end,
    so_start_text, so_end_text, so_start, so_end, billing_start_text, billing_end_text, billing_start, billing_end)
  select d->>'kode', d->>'nama', d->>'jenis', d->>'pajak', 'active',
    d->>'ps', d->>'pe', rc_private.urai_tanggal_rc(d->>'ps'), rc_private.urai_tanggal_rc(d->>'pe'),
    d->>'sos', d->>'soe', rc_private.urai_tanggal_rc(d->>'sos'), rc_private.urai_tanggal_rc(d->>'soe'),
    coalesce(d->>'bis', d->>'sos'), coalesce(d->>'bie', d->>'soe'),
    rc_private.urai_tanggal_rc(coalesce(d->>'bis', d->>'sos')), rc_private.urai_tanggal_rc(coalesce(d->>'bie', d->>'soe'))
  from (select data d from rc_muat_ulang.baris where sesi=v_sesi and jenis='campaign') s;

  -- 5. Customer dan pemetaan depotnya.
  -- tax_subject TIDAK diisi: kolom turunan database (NPWP -> Badan, hanya KTP -> Perorangan).
  insert into public.customers(customer_code, customer_name, top_text, ktp, npwp, account_name, account_number, bank, contact_person)
  select d->>'kode', d->>'nama', d->>'top', d->>'ktp', d->>'npwp', d->>'namaRek', d->>'noRek', d->>'bank', d->>'cp'
    from (select data d from rc_muat_ulang.baris where sesi=v_sesi and jenis='customer') s;
  insert into public.customer_depots(customer_id, depot_id)
  select distinct cu.id, dp.id
    from (select data d from rc_muat_ulang.baris where sesi=v_sesi and jenis='customer') s
    cross join lateral jsonb_array_elements_text(s.d->'depots') k
    join public.customers cu on cu.customer_code = s.d->>'kode'
    join public.depots dp on dp.depot_code = k.value;

  -- 6. Klaim, data sensitif, dan satu baris riwayat "muat_ulang" per dokumen.
  insert into public.claims(no_doc, depot_id, customer_id, source_customer_code, master_data_issue,
    campaign_id, status, net_value, volume, cb_net, gross_up,
    cashback_type_override, cashback_type_changed, tax_subject, paid_on, total_billing, legacy_dates,
    batch_upload, uploaded_at, approved_at, batch_release, released_at, batch_claim, claimed_at, batch_clearing, cleared_at,
    previous_status, extend_so_start, extend_so_end, extend_billing_start, extend_billing_end, pending_approval, version_no)
  select d->>'noDoc', dp.id, cu.id, d->>'cust',
    case when cu.id is null then 'Customer Master tidak ditemukan: '||(d->>'cust') end,
    ca.id, d->>'status',
    (d->>'net')::numeric, (d->>'vol')::numeric, (d->>'cb')::numeric,
    -- Aturan Gross Up 20261162250000: semua status pajak, seluruh Rebate 0, bulat.
    case when cu.id is null then null else rc_private.gross_up_klaim((d->>'cb')::numeric, cu.tax_subject, ca.tax_status,
      coalesce(nullif(d->>'jenis', ''), ca.cashback_type)) end,
    d->>'jenis', coalesce(d->>'jenis','') <> '' and rc_private.jenis_efektif(d->>'jenis') <> rc_private.jenis_efektif(ca.cashback_type),
    coalesce(cu.tax_subject, d->>'taxSumber'), (d->>'lunas')::date, (d->>'tagih')::numeric, coalesce(d->'legacy', '{}'::jsonb),
    d->>'bUp', (d->>'tUp')::timestamptz, (d->>'tAp')::timestamptz,
    d->>'bRel', (d->>'tRel')::timestamptz, d->>'bCl', (d->>'tCl')::timestamptz,
    d->>'bClr', (d->>'tClr')::timestamptz,
    case when d->>'status'='on_hold' then d->>'sebelumHold' end,
    case when d->>'status'='on_hold' then (d->>'hSoA')::date end, case when d->>'status'='on_hold' then (d->>'hSoZ')::date end,
    case when d->>'status'='on_hold' then (d->>'hBiA')::date end, case when d->>'status'='on_hold' then (d->>'hBiZ')::date end,
    -- Submitted = sudah diajukan dan menunggu Management of Approval, persis seperti hasil submit.
    case when d->>'status'='submitted' and cu.id is not null then jsonb_build_object('kind','submit','requested_by',null,
      'requested_at', coalesce((d->>'tUp')::timestamptz, now()), 'reason','Muat ulang data',
      'target_status', case when rc_private.jenis_efektif(coalesce(d->>'jenis', ca.cashback_type))='rebate manual' then 'done' else 'approved' end) end,
    1
  from (select data d from rc_muat_ulang.baris where sesi=v_sesi and jenis='klaim') s
  join public.depots dp on dp.depot_code = s.d->>'depot'
  left join public.customers cu on cu.customer_code = s.d->>'cust'
  join public.campaigns ca on ca.campaign_code = s.d->>'camp';

  -- Identitas yang hanya kehilangan nol di depan (sel angka di Excel) memakai nilai Customer
  -- Master yang utuh; nilai yang memang berbeda tetap milik klaimnya (20261162220000).
  insert into rc_private.claim_sensitive(claim_id, ktp, npwp, bank, account_number, account_name, top_text)
  select c.id, ${utuhkanNol("s.d->>'ktp'", 'cu.ktp')}, ${utuhkanNol("s.d->>'npwp'", 'cu.npwp')}, coalesce(s.d->>'bank', cu.bank),
         ${utuhkanNol("s.d->>'noRek'", 'cu.account_number')}, coalesce(s.d->>'namaRek', cu.account_name), coalesce(s.d->>'top', cu.top_text)
    from (select data d from rc_muat_ulang.baris where sesi=v_sesi and jenis='klaim') s
    join public.claims c on c.no_doc = s.d->>'noDoc'
    left join public.customers cu on cu.id = c.customer_id;

  insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
  select c.id, null, null, c.status, 'muat_ulang', 'Data dimuat ulang ${tglWib}' from public.claims c;

  -- 7. Status akhir campaign.
  update public.campaigns ca set status = s.d->>'status'
    from (select data d from rc_muat_ulang.baris where sesi=v_sesi and jenis='campaign') s
   where ca.campaign_code = s.d->>'kode' and s.d->>'status' <> 'active';

  -- 8. Kondisi lama dipulihkan hanya bila flag penghapusan tidak dipakai.
${pulihkanKondisi}

  -- 9. Penghitung batch dinaikkan setinggi nomor yang dimuat, supaya batch baru tidak bentrok.
  --    Dihitung di Node (hanya nomor 15 digit bertanggal sah), dikirim sebagai jenis 'penghitung'.
  insert into rc_private.batch_counters(stage, suffix, business_date, counter)
  select d->>'stage', d->>'suffix', (d->>'tanggal')::date, (d->>'counter')::int
    from (select data d from rc_muat_ulang.baris where sesi=v_sesi and jenis='penghitung') s
  on conflict (stage, suffix, business_date) do update set counter = greatest(rc_private.batch_counters.counter, excluded.counter);

  -- 10. Pemeriksaan. Satu saja gagal -> seluruh transaksi dibatalkan, data lama utuh.
  select count(*), coalesce(sum(cb_net),0) into n, v_sum from public.claims;
  if n <> ${harap.klaim} then e := e || format(' klaim %s (harap ${harap.klaim});', n); end if;
  if round(v_sum, 2) <> round(${harap.totalCbNet}::numeric, 2) then e := e || format(' total CB Net %s (harap ${harap.totalCbNet});', v_sum); end if;
  if (select count(*) from public.customers) <> ${harap.customer} then e := e || ' jumlah customer;'; end if;
  if (select count(*) from public.campaigns) <> ${harap.campaign} then e := e || ' jumlah campaign;'; end if;
  if (select count(*) from rc_private.claim_sensitive) <> ${harap.klaim} then e := e || ' data sensitif;'; end if;
  if exists(select 1 from public.claims c where c.customer_id is not null and not exists(select 1 from public.customer_depots m where m.customer_id=c.customer_id and m.depot_id=c.depot_id)) then
    e := e || ' ada klaim yang depotnya tidak terpetakan pada pelanggannya;'; end if;
  if exists(select 1 from public.claims where status='submitted' and customer_id is not null and pending_approval is null) then e := e || ' Submitted tanpa antrean approval;'; end if;
  if (select count(*) from public.claims where customer_id is null) <> ${harap.klaimTanpaCustomerMaster} then
    e := e || ' jumlah klaim tanpa Customer Master;'; end if;
${hapusKondisiLama ? `  if exists(select 1 from public.excluded_campaigns) or exists(select 1 from public.timetable_not_achieved)
     or exists(select 1 from public.campaign_not_participating) then e := e || ' kondisi lama belum kosong;'; end if;
  if exists(select 1 from public.activity_logs) then e := e || ' activity log lama belum kosong;'; end if;` : ''}
${Object.entries(harap.perStatus).map(([s, v]) => `  if (select count(*) from public.claims where status='${s}') <> ${v.n} then e := e || ' jumlah status ${s};'; end if;`).join('\n')}
  if e <> '' then raise exception 'GAGAL, dibatalkan:%', e; end if;

  insert into public.activity_logs(actor_id, event_type, details)
  values (null, 'data_dimuat_ulang', jsonb_build_object('tanggal', '${tglWib}', 'klaim', ${harap.klaim}, 'customer', ${harap.customer},
    'campaign', ${harap.campaign}, 'depot', ${harap.depot}, 'totalCbNet', ${harap.totalCbNet},
    'klaimTanpaCustomerMaster', ${harap.klaimTanpaCustomerMaster}, 'activityLogLamaDihapus', ${hapusKondisiLama},
    'excludeDipulihkan', (select count(*) from public.excluded_campaigns), 'notAchievedDipulihkan', (select count(*) from public.timetable_not_achieved),
    'notParticipatingDipulihkan', (select count(*) from public.campaign_not_participating)));
end
$tukar$;`;
}

// ------------------------------------------------------------------------------------------
// Pemulihan dari cadangan
// ------------------------------------------------------------------------------------------
async function pulihkan(db, folder, konfirmasiSah) {
  if (!konfirmasiSah) throw new Error('konfirmasi tidak sah');
  const kol = await db.sql(`select string_agg(quote_ident(attname), ', ' order by attnum) k from pg_attribute
    where attrelid = 'public.customers'::regclass and attnum > 0 and not attisdropped and attgenerated = '';`);
  const KOLOM_CUSTOMER = kol[0].k;
  const isi = {};
  // Cadangan lama mungkin belum memuat tabel yang ditambahkan kemudian; dianggap kosong.
  for (const [tabel] of TABEL_CADANGAN) isi[tabel] = JSON.parse(await readFile(path.join(folder, tabel + '.json'), 'utf8').catch(() => '[]'));
  const sesi = randomUUID();
  await siapkanStaging(db);
  for (const [tabel] of TABEL_CADANGAN) {
    process.stdout.write(`  staging ${tabel.padEnd(30)} ${String(isi[tabel].length).padStart(7)} `);
    await kirimStaging(db, sesi, 'pulih:' + tabel, isi[tabel], 300);
    console.log('');
  }
  const rec = (t) => `(select (jsonb_populate_record(null::${t}, data)).* from rc_muat_ulang.baris where sesi=v_sesi and jenis='pulih:${t}')`;
  await db.sql(`
do $pulih$
declare v_sesi uuid := ${lit(sesi)}::uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('rc-muat-ulang', 0));
  delete from public.activity_logs;
  delete from rc_private.claim_sensitive; delete from public.claim_status_history; delete from public.claims;
  delete from public.customer_depots; delete from public.customers; delete from public.campaigns;
  -- Depot dikembalikan nilainya (bukan dihapus): depot baru hasil muat ulang dibiarkan ada.
  update public.depots d set depot_name=b.depot_name, abbr=b.abbr, region=b.region, address=b.address,
    email_to=b.email_to, email_cc=b.email_cc, master_link=b.master_link
    from ${rec('public.depots')} b where d.id = b.id;
  -- Campaign aktif dulu (jaga_status_campaign), status asli dipasang sesudah klaim masuk.
  insert into public.campaigns select (r).* from (select jsonb_populate_record(null::public.campaigns, data || '{"status":"active"}') r
    from rc_muat_ulang.baris where sesi=v_sesi and jenis='pulih:public.campaigns') t;
  -- tax_subject kolom turunan: disisipkan per kolom, tanpa kolom itu.
  insert into public.customers(${KOLOM_CUSTOMER}) select ${KOLOM_CUSTOMER} from ${rec('public.customers')} x;
  insert into public.customer_depots select * from ${rec('public.customer_depots')} x;
  insert into public.claims select * from ${rec('public.claims')} x;
  insert into rc_private.claim_sensitive select * from ${rec('rc_private.claim_sensitive')} x;
  insert into public.claim_status_history overriding system value select * from ${rec('public.claim_status_history')} x;
  update public.campaigns c set status=b.status from ${rec('public.campaigns')} b where c.id=b.id;
  insert into public.excluded_campaigns select * from ${rec('public.excluded_campaigns')} x on conflict do nothing;
  insert into public.timetable_not_achieved select * from ${rec('public.timetable_not_achieved')} x on conflict do nothing;
  insert into public.campaign_not_participating select * from ${rec('public.campaign_not_participating')} x on conflict do nothing;
  insert into rc_private.batch_counters select * from ${rec('rc_private.batch_counters')} x
    on conflict (stage, suffix, business_date) do update set counter = greatest(rc_private.batch_counters.counter, excluded.counter);
  insert into public.activity_logs overriding system value select * from ${rec('public.activity_logs')} x;
  perform setval(pg_get_serial_sequence('public.claim_status_history','id'), greatest((select max(id) from public.claim_status_history), 1));
  perform setval(pg_get_serial_sequence('public.activity_logs','id'), greatest((select max(id) from public.activity_logs), 1));
  if (select count(*) from public.claims) <> ${isi['public.claims'].length}
  or (select count(*) from public.customers) <> ${isi['public.customers'].length}
  or (select count(*) from public.campaigns) <> ${isi['public.campaigns'].length} then
    raise exception 'GAGAL memulihkan: jumlah baris tidak cocok; dibatalkan.'; end if;
  insert into public.activity_logs(actor_id, event_type, details)
  values (null, 'data_dipulihkan', jsonb_build_object('dari', ${lit(path.basename(path.dirname(folder)))}, 'klaim', ${isi['public.claims'].length}));
end
$pulih$;`);
  await db.sql(`delete from rc_muat_ulang.baris where sesi=${lit(sesi)}::uuid;`);
  console.log(`\n  \x1b[32mDipulihkan:\x1b[0m ${isi['public.claims'].length} klaim, ${isi['public.customers'].length} customer, ${isi['public.campaigns'].length} campaign.`);
}

// ------------------------------------------------------------------------------------------
// Ekspor isi database ke format template (HANYA MEMBACA)
// ------------------------------------------------------------------------------------------
// Titik awal "ekspor -> perbaiki di Excel -> muat ulang". Tanggal diambil dari kolom waktu bila
// ada, selain itu dari teks lama (legacy_dates) apa adanya - teks lama yang bentuknya tidak sah
// akan ditandai pemeriksa supaya diperbaiki, bukan ditebak.
// Teks tanggal peninggalan Apps Script (legacy_dates). Diperiksa 7 Oktober 2026 pada seluruh prod:
// dari +-4.900 tanggal bergaris miring, angka pertama TIDAK PERNAH > 12 sedangkan angka kedua > 12
// pada +-2.270 di antaranya - jadi bentuknya pasti Bulan/Hari/Tahun (Google Sheets bawaan AS),
// kadang diikuti jam. Bentuk bernama bulan ("11-Agu-2026", "15 Desember 2025") diurai seperti
// Campaign Master. Selain itu dibiarkan apa adanya supaya ditandai pemeriksa, bukan ditebak.
function konversiTanggalLama(teks) {
  if (teks == null || teks === '') return teks;
  const s = String(teks).trim();
  if (/^\d{2}-\d{2}-\d{4}$/.test(s)) return s;
  const h = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})(\s+\d{1,2}:\d{2}(:\d{2})?)?$/);
  if (h) {
    const m = +h[1], d = +h[2], y = +h[3];
    return sahKalender(y, m, d) ? `${String(d).padStart(2, '0')}-${String(m).padStart(2, '0')}-${y}` : s;
  }
  const l = uraiTanggalLonggar({ teks: s });
  if (l.nilai) { const [y, m, d] = l.nilai.split('-'); return `${d}-${m}-${y}`; }
  return s;
}

async function ekspor(db, keluar) {
  const ambilSemua = async (q, urut) => {
    const semua = [];
    for (let offset = 0; ; offset += 2000) {
      const r = await db.sql(`select coalesce(jsonb_agg(t), '[]'::jsonb) as b from (${q} order by ${urut} limit 2000 offset ${offset}) t;`);
      semua.push(...(r[0].b || []));
      if ((r[0].b || []).length < 2000) return semua;
    }
  };
  const tgl = (kol, leg) => `coalesce(to_char(${kol} at time zone 'Asia/Jakarta','DD-MM-YYYY'), nullif(c.legacy_dates->>'${leg}',''))`;
  const tglDate = (kol) => `to_char(${kol},'DD-MM-YYYY')`;
  const label = (kol) => `case ${kol} when 'not_yet' then 'Not Yet' when 'submitted' then 'Submitted' when 'approved' then 'Approved'
    when 'released' then 'Released' when 'claimed' then 'Claimed' when 'done' then 'Done' when 'on_hold' then 'On Hold' when 'expired' then 'Expired' end`;
  const depot = await ambilSemua(`select depot_code, depot_name, abbr, region, address, email_to, email_cc, master_link from public.depots where archived_at is null`, 'depot_code');
  const campaign = await ambilSemua(`select campaign_code, campaign_name, period_start_text, period_end_text, so_start_text, so_end_text,
      billing_start_text, billing_end_text, cashback_type, tax_status, status from public.campaigns`, 'campaign_code');
  const customer = await ambilSemua(`select cu.customer_code, cu.customer_name,
      (select string_agg(d.depot_code, ', ' order by d.depot_code) from public.customer_depots m join public.depots d on d.id=m.depot_id where m.customer_id=cu.id) depots,
      cu.tax_subject, cu.top_text, cu.ktp, cu.npwp, cu.account_name, cu.account_number, cu.bank, cu.contact_person from public.customers cu`, 'customer_code');
  const klaim = await ambilSemua(`select c.no_doc, d.depot_code, cu.customer_code, ca.campaign_code, c.net_value, c.volume, c.cb_net, ${label('c.status')} status,
      c.cashback_type_override, c.tax_subject, s.top_text, coalesce(${tglDate('c.paid_on')}, nullif(c.legacy_dates->>'paid_on','')) paid_on, c.total_billing,
      s.ktp, s.npwp, s.account_name, s.account_number, s.bank,
      nullif(c.batch_upload,'') bu, ${tgl('c.uploaded_at', 'uploaded_at')} tu, to_char(c.approved_at at time zone 'Asia/Jakarta','DD-MM-YYYY') ta,
      nullif(c.batch_release,'') br, ${tgl('c.released_at', 'released_at')} tr, nullif(c.batch_claim,'') bc, ${tgl('c.claimed_at', 'claimed_at')} tc,
      nullif(c.batch_clearing,'') bd, ${tgl('c.cleared_at', 'cleared_at')} td,
      case when c.status='on_hold' then ${label('c.previous_status')} end sh,
      ${tglDate('c.extend_so_start')} hsa, ${tglDate('c.extend_so_end')} hsz, ${tglDate('c.extend_billing_start')} hba, ${tglDate('c.extend_billing_end')} hbz
    from public.claims c join public.depots d on d.id=c.depot_id join public.customers cu on cu.id=c.customer_id
    join public.campaigns ca on ca.id=c.campaign_id left join rc_private.claim_sensitive s on s.claim_id=c.id
    where c.archived_at is null`, 'no_doc');
  const r = await db.sql(`select (select count(*) from public.claims where archived_at is not null) arsip,
      (select count(*) from public.claims where pending_approval->>'kind' in ('hold','expire')) ajuan_hold;`);
  const data = {
    Depot: depot.map((x) => [x.depot_code, x.depot_name, x.abbr, x.region, x.address, x.email_to, x.email_cc, x.master_link]),
    Campaign: campaign.map((x) => [x.campaign_code, x.campaign_name, x.period_start_text, x.period_end_text, x.so_start_text, x.so_end_text,
      x.billing_start_text, x.billing_end_text, x.cashback_type, x.tax_status, x.status]),
    Customer: customer.map((x) => [x.customer_code, x.customer_name, x.depots, x.top_text, x.ktp, x.npwp, x.account_name, x.account_number, x.bank, x.contact_person]),
    Klaim: klaim.map((x) => { for (const k of ['paid_on', 'tu', 'tr', 'tc', 'td']) x[k] = konversiTanggalLama(x[k]); return x; }).map((x) => [x.no_doc, x.depot_code, x.customer_code, x.campaign_code, x.net_value, x.volume, x.cb_net, x.status,
      x.cashback_type_override, x.top_text, x.paid_on, x.total_billing, x.ktp, x.npwp, x.account_name, x.account_number, x.bank,
      x.bu, x.tu, x.ta, x.br, x.tr, x.bc, x.tc, x.bd, x.td, x.sh, x.hsa, x.hsz, x.hba, x.hbz]),
  };
  await buatTemplate(keluar, data);
  console.log(`  Ekspor: ${depot.length} depot, ${campaign.length} campaign, ${customer.length} customer, ${klaim.length} klaim -> ${keluar}`);
  if (r[0].arsip > 0) console.log(`  Catatan: ${r[0].arsip} klaim terarsip TIDAK diekspor (muat ulang menghapusnya).`);
  if (r[0].ajuan_hold > 0) console.log(`  Catatan: ${r[0].ajuan_hold} ajuan On Hold/Expired yang belum diputuskan tidak ikut; dokumennya diekspor dengan status saat ini.`);
}

// ------------------------------------------------------------------------------------------
// Laporan
// ------------------------------------------------------------------------------------------
async function tulisLaporan(folder, h, ring) {
  await mkdir(folder, { recursive: true });
  const csv = (rows) => ['Jenis,Lembar,Baris,Kolom,Pesan', ...rows.map((r) => [r.jenis, r.lembar, r.baris, r.kolom, r.pesan].map((v) => '"' + String(v).replace(/"/g, '""') + '"').join(','))].join('\r\n');
  const semua = [...h.galat.map((x) => ({ jenis: 'GALAT', ...x })), ...h.peringatan.map((x) => ({ jenis: 'peringatan', ...x }))];
  await writeFile(path.join(folder, 'temuan.csv'), '﻿' + csv(semua));
  await writeFile(path.join(folder, 'ringkasan.json'), JSON.stringify(ring, null, 2));
}

function cetakTemuan(h) {
  const tampil = (daftar, warna, label) => {
    if (!daftar.length) return;
    console.log(`\n  \x1b[${warna}m${label} (${daftar.length})\x1b[0m`);
    for (const x of daftar.slice(0, 40)) console.log(`   ${x.lembar} baris ${x.baris} [${x.kolom}]: ${x.pesan}`);
    if (daftar.length > 40) console.log(`   ... ${daftar.length - 40} lagi - lihat temuan.csv`);
  };
  // Peringatan sejenis diringkas supaya galat tidak tenggelam.
  const kelompok = {};
  for (const x of h.peringatan) { const k = x.lembar + ' [' + x.kolom + ']: ' + x.pesan.replace(/"[^"]*"|\b[A-Z0-9]{2,}\b|\d+/g, '…'); kelompok[k] = (kelompok[k] || 0) + 1; }
  tampil(h.galat, '31', 'GALAT - wajib diperbaiki');
  if (h.peringatan.length) {
    console.log(`\n  \x1b[33mPERINGATAN (${h.peringatan.length}) - boleh, tetapi baca dulu\x1b[0m`);
    for (const [k, n] of Object.entries(kelompok).sort((a, b) => b[1] - a[1]).slice(0, 25)) console.log(`   ${String(n).padStart(5)} x  ${k}`);
  }
}

// ------------------------------------------------------------------------------------------
// Main
// ------------------------------------------------------------------------------------------
async function main() {
  if (ambil('--buat-template')) {
    const keluar = path.resolve(ambil('--buat-template'));
    await buatTemplate(keluar);
    console.log(`\n  Template dibuat: ${keluar}\n`);
    return;
  }

  const namaEnv = ambil('--env');
  const konfirmasi = ambil('--konfirmasi');

  if (ambil('--ekspor')) {
    if (!namaEnv) throw new Error('--ekspor memerlukan --env');
    const db = await sambung(namaEnv);
    await ekspor(db, path.resolve(ambil('--ekspor')));
    return;
  }

  if (ambil('--pulihkan')) {
    if (!namaEnv) throw new Error('--pulihkan memerlukan --env');
    const harus = namaEnv === 'prod' ? `PULIHKAN-PROD-${tglWib}` : `PULIHKAN-${namaEnv.toUpperCase()}`;
    if (konfirmasi !== harus) throw new Error(`ketik --konfirmasi ${harus}`);
    const db = await sambung(namaEnv);
    await pulihkan(db, path.resolve(ambil('--pulihkan')), true);
    await db.sql('select rc_private.segarkan_dashboard_publik();').catch(() => {});
    return;
  }

  if (ada('--cadangkan') && !ambil('--berkas')) {
    if (!namaEnv) throw new Error('--cadangkan memerlukan --env');
    const db = await sambung(namaEnv);
    const folder = path.join(root, '.runtime', 'muat-ulang', `${namaEnv}-${stempel}`, 'cadangan');
    await cadangkan(db, folder);
    console.log(`\n  Cadangan: ${folder}\n`);
    return;
  }

  const berkas = ambil('--berkas');
  if (!berkas) {
    console.log('\n  Lihat pemakaian di kepala berkas scripts/muat-ulang-data.mjs atau docs/muat-ulang-data-prod.md\n');
    process.exitCode = 1; return;
  }

  const db = namaEnv ? await sambung(namaEnv) : null;
  let depotDb = null;
  if (db) {
    const r = await db.sql('select coalesce(jsonb_agg(depot_code), \'[]\') as kode from public.depots;');
    depotDb = new Set((r[0].kode || []).map(kunciKode));
  }

  console.log(`  Membaca ${berkas} ...`);
  const mentah = await bacaBerkas(path.resolve(berkas));
  if (lewatiGalat && !normalisasiImpor) throw new Error('--lewati-galat wajib dipakai bersama --normalisasi-impor');
  if (izinkanCustomerTidakAda && !normalisasiImpor) throw new Error('--izinkan-customer-tidak-ada wajib dipakai bersama --normalisasi-impor');
  if (temuanDuplikat && !lewatiGalat) throw new Error('--temuan-duplikat wajib dipakai bersama --lewati-galat');
  if (ambil('--temuan-xlsx') && !lewatiGalat) throw new Error('--temuan-xlsx wajib dipakai bersama --lewati-galat');
  const galatDasar = mentah.galat.map((x) => ({ ...x }));
  const peringatanDasar = mentah.peringatan.map((x) => ({ ...x }));
  const pemisahan = lewatiGalat ? periksaTanpaGalat(mentah.data, galatDasar, peringatanDasar, depotDb) : null;
  const h = pemisahan ? pemisahan.h : periksa(mentah, depotDb);
  const ring = ringkas(h);
  const folder = path.join(root, '.runtime', 'muat-ulang', `${namaEnv || 'lokal'}-${stempel}`);
  const hLaporan = pemisahan
    ? { galat: pemisahan.semuaGalat.map(({ tahap, ...x }) => ({ ...x, pesan: `[${tahap}] ${x.pesan}` })), peringatan: h.peringatan }
    : h;
  await tulisLaporan(folder, hLaporan, { ...ring, galat: h.galat.length, peringatan: h.peringatan.length });

  if (pemisahan) {
    const hitungPending = Object.fromEntries(Object.entries(pemisahan.pending).map(([nama, rows]) => [nama, rows.length]));
    const rencana = {
      dibuatPada: new Date().toISOString(),
      sumber: path.basename(path.resolve(berkas)),
      lingkungan: namaEnv || null,
      normalisasi: {
        batchKosongDilewati: true,
        jenisCbKosongMengikutiCampaign: true,
        aliasJenisCbDinormalisasi: true,
        tanggalDinormalisasi: true,
        jamDipertahankanWib: true,
        customerTidakAdaTetapDitransport: izinkanCustomerTidakAda,
        emailToBerlebihDipindahKeCc: normalisasiImpor,
        kondisiLamaDihapus: hapusKondisiLama,
        activityLogLamaDihapus: hapusKondisiLama,
        abbrBergarisMiringDinormalisasi: normalisasiImpor,
        semuaSalinanDuplikatDitahan: temuanDuplikat,
      },
      awal: {
        ...pemisahan.ringAwal,
        jumlahGalat: pemisahan.semuaGalat.filter((x) => x.tahap === 'awal').length,
        jumlahBarisKlaimPending: new Set(pemisahan.semuaGalat.filter((x) => x.tahap === 'awal' && x.lembar === 'Klaim').map((x) => x.baris)).size,
      },
      putaran: pemisahan.tahap,
      pending: { jumlah: hitungPending, baris: pemisahan.pending },
      klaimTanpaCustomerMaster: pemisahan.klaimTanpaCustomerMaster,
      transport: { ...ring, jumlahGalatTersisa: h.galat.length, jumlahPeringatan: h.peringatan.length },
      temuanFatal: pemisahan.semuaGalat,
    };
    const rencanaPath = path.resolve(ambil('--rekap-pending-json') || path.join(folder, 'rekap-pending.json'));
    await mkdir(path.dirname(rencanaPath), { recursive: true });
    await writeFile(rencanaPath, JSON.stringify(rencana, null, 2));
    console.log(`\n  Dipisahkan ke pending: ${Object.entries(hitungPending).map(([k, v]) => `${k} ${v}`).join(' | ')}`);
    console.log(`  Rekap pending (JSON): ${rencanaPath}`);
    if (ambil('--temuan-xlsx')) {
      const temuanPath = path.resolve(ambil('--temuan-xlsx'));
      await tulisTemuan(temuanPath, mentah.data, pemisahan.pending);
      console.log(`  Excel temuan: ${temuanPath}`);
    }
  }

  console.log(`\n  Depot ${ring.depot} | Campaign ${ring.campaign} | Customer ${ring.customer} (pemetaan depot ${ring.pemetaanDepot}) | Klaim ${ring.klaim}`);
  console.log(`  Total Cashback After Tax: ${ring.totalCbNet.toLocaleString('id-ID')}`);
  if (normalisasiImpor) {
    console.log(`  Batch Submitted: ${ring.batchUploadTerisi} terisi | ${ring.batchUploadKosong} kosong (kosong dilewati)`);
    console.log(`  Jenis CB: ${ring.jenisCbDariBerkas} dari berkas | ${ring.jenisCbDariMaster} mengikuti Campaign Master | ${ring.jenisCbTidakSah} tidak sah`);
    console.log(`  Timestamp yang mempertahankan jam: ${ring.timestampDenganJam}`);
    console.log(`  Klaim tanpa Customer Master: ${ring.klaimTanpaCustomerMaster} (tetap dimuat, proses diblokir)`);
    console.log(`  Alamat Email TO dipindahkan ke CC: ${ring.emailDepotDipindahKeCc}`);
  }
  for (const [s, v] of Object.entries(ring.perStatus)) console.log(`    ${s.padEnd(10)} ${String(v.n).padStart(6)} dokumen   CB Net ${Math.round(v.cb).toLocaleString('id-ID')}`);
  cetakTemuan(h);
  console.log(`\n  Laporan lengkap: ${folder}`);

  // Tanggal Campaign Master diurai server dengan fungsi yang sama dengan Key Master.
  if (db) {
    const teks = [...new Set(h.campaign.flatMap((c) => [c.ps, c.pe, c.sos, c.soe, c.bis, c.bie]).filter(Boolean))];
    if (teks.length) {
      const r = await db.sql(`select coalesce(jsonb_agg(t), '[]'::jsonb) as tak from unnest(array[${teks.map(lit).join(',')}]::text[]) t where rc_private.urai_tanggal_rc(t) is null;`);
      const tak = r[0].tak || [];
      if (tak.length) console.log(`\n  \x1b[33mCatatan:\x1b[0m ${tak.length} teks tanggal campaign tidak terurai server (disimpan sebagai teks): ${tak.slice(0, 10).join(' | ')}`);
    }
  }

  if (h.galat.length) {
    console.log(`\n  \x1b[31mBELUM SIAP:\x1b[0m ${h.galat.length} galat. Perbaiki berkasnya lalu periksa ulang.\n`);
    process.exitCode = 1; return;
  }
  if (!ada('--jalankan')) {
    console.log(`\n  \x1b[32mBERKAS SIAP DIMUAT.\x1b[0m Tidak ada yang diubah (mode periksa).\n`);
    return;
  }

  // ---- Jalankan ---------------------------------------------------------------------------
  if (!db) throw new Error('--jalankan memerlukan --env');
  const harus = namaEnv === 'prod' ? `MUAT-ULANG-PROD-${tglWib}` : `MUAT-ULANG-${namaEnv.toUpperCase()}`;
  if (konfirmasi !== harus) throw new Error(`ketik --konfirmasi ${harus}`);

  console.log('\n  1/4 Mencadangkan isi lama ...');
  let cad;
  const pakaiCadangan = ambil('--gunakan-cadangan');
  if (pakaiCadangan) {
    cad = path.resolve(pakaiCadangan);
    const basisCadangan = path.join(root, '.runtime', 'muat-ulang');
    const relatif = path.relative(basisCadangan, cad);
    if (!relatif || relatif.startsWith('..') || path.isAbsolute(relatif)) throw new Error('--gunakan-cadangan harus berada di .runtime/muat-ulang');
    const info = JSON.parse(await readFile(path.join(cad, 'ringkasan.json'), 'utf8'));
    const sekarang = await db.sql(`select
      (select count(*) from public.claims) klaim,
      (select count(*) from public.customers) customer,
      (select count(*) from public.campaigns) campaign,
      (select count(*) from public.activity_logs) log;`);
    const cocok = info.ringkasan?.['public.claims'] === Number(sekarang[0].klaim)
      && info.ringkasan?.['public.customers'] === Number(sekarang[0].customer)
      && info.ringkasan?.['public.campaigns'] === Number(sekarang[0].campaign)
      && info.ringkasan?.['public.activity_logs'] === Number(sekarang[0].log);
    if (!cocok) throw new Error('cadangan retry tidak sama dengan isi PROD saat ini; buat cadangan baru');
    console.log(`  memakai ulang cadangan lengkap yang cocok: ${cad}`);
  } else {
    cad = path.join(folder, 'cadangan');
    await cadangkan(db, cad);
  }

  console.log('\n  2/4 Mengirim data ke staging ...');
  await siapkanStaging(db);
  // Sesi yang putus sebelum pertukaran tidak pernah menyentuh data utama; bersihkan agar staging
  // tidak tumbuh tanpa batas. Loader ini dijalankan tunggal untuk satu project.
  await db.sql('delete from rc_muat_ulang.baris;');
  const sesi = randomUUID();
  const kirim = async (jenis, rows) => { process.stdout.write(`  ${jenis.padEnd(9)} ${String(rows.length).padStart(7)} `); await kirimStaging(db, sesi, jenis, rows); console.log(''); };
  await kirim('depot', h.depot.map(({ baris, ...d }) => d));
  await kirim('campaign', h.campaign.map(({ baris, ...d }) => d));
  await kirim('customer', h.customer.map(({ baris, ...d }) => d));
  await kirim('klaim', h.klaim.map(({ baris, ...d }) => d));
  await kirim('penghitung', penghitungBatch(h.klaim));

  console.log('\n  3/4 Mengosongkan dan memuat dalam satu transaksi ...');
  try {
    const dukunganCustomerKosong = izinkanCustomerTidakAda
      ? await readFile(path.join(root, 'supabase', 'migrations', '20261162200000_klaim_tanpa_customer_master.sql'), 'utf8')
      : '';
    await db.sql(dukunganCustomerKosong + '\n' + sqlTukar(sesi, ring));
  } catch (e) {
    await db.sql(`delete from rc_muat_ulang.baris where sesi=${lit(sesi)}::uuid;`).catch(() => {});
    console.log(`\n  \x1b[31mDIBATALKAN - data lama utuh.\x1b[0m\n  ${e.message}\n`);
    process.exitCode = 1; return;
  }

  console.log('  4/4 Menyegarkan dashboard publik dan membersihkan staging ...');
  await db.sql(`delete from rc_muat_ulang.baris where sesi=${lit(sesi)}::uuid;`);
  await db.sql('select rc_private.segarkan_dashboard_publik();').catch((e) => console.log('  (dashboard publik disegarkan cron 5 menit lagi: ' + e.message.slice(0, 120) + ')'));
  const r = await db.sql(`select status, count(*) n, sum(cb_net) cb from public.claims group by 1 order by 1;`);
  console.log('\n  \x1b[32mSELESAI.\x1b[0m Isi database sekarang:');
  for (const x of r) console.log(`    ${String(x.status).padEnd(10)} ${String(x.n).padStart(6)} dokumen   CB Net ${Math.round(x.cb).toLocaleString('id-ID')}`);
  console.log(`\n  Cadangan isi lama: ${cad}`);
  console.log(`  Bila perlu kembali: node scripts/muat-ulang-data.mjs --env ${namaEnv} --pulihkan "${cad}" --konfirmasi ${namaEnv === 'prod' ? 'PULIHKAN-PROD-' + tglWib : 'PULIHKAN-' + namaEnv.toUpperCase()}\n`);
}

// Fungsi pembantu dipakai ulang oleh scripts/ganti-klaim-depot.mjs (14 Oktober 2026), supaya
// pembacaan sel, tanggal, angka, status, dan batch identik dengan muat ulang penuh. main() hanya
// berjalan bila berkas ini dijalankan langsung, bukan saat diimpor.
export { XLSX, LEMBAR, STATUS, URUT_STATUS, KOLOM_WAKTU, BULAN, norm, kunciKode, bacaSel, angka, uraiTanggalKetat,
  iso, isoWaktuWib, sahKalender, penghitungBatch, sambung, lit, jsonLit, siapkanStaging, kirimStaging, cadangkan, root };

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => { console.error(`\n  \x1b[31mBerhenti:\x1b[0m ${e.message}\n`); process.exitCode = 1; });
}
