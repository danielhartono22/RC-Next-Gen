/*
 * GANTI KLAIM PER DEPOT: hapus seluruh klaim depot tertentu, lalu muat ulang dari Excel
 * =====================================================================================
 * Dibuat 14 Oktober 2026 atas permintaan pemilik untuk berkas
 * Temuan_Muat_Ulang_PROD_20261010 (1P 1Q 1Y): "jika ada depot di perbaikan nominal, hapus semua
 * cashback list nya depot yang ada di sheet tersebut dan upload ulang."
 *
 * Berbeda dengan scripts/muat-ulang-data.mjs (seluruh database), alat ini hanya menyentuh klaim:
 *   - lembar GANTI (bawaan "Perbaikan nominal"): seluruh klaim depot yang muncul di lembar ini
 *     dihapus (beserta data sensitif dan riwayat statusnya), lalu dimuat dari lembar ini;
 *   - lembar TAMBAH (bawaan "Klaim"): baris untuk depot lain dimuat sebagai dokumen baru. Baris
 *     untuk depot GANTI harus sama persis dengan barisnya di lembar GANTI (lalu dilewati).
 * Customer, campaign, depot, akun, dan pengaturan tidak disentuh. Pemetaan depot pelanggan
 * ditambahkan bila depot klaim belum terdaftar pada pelanggannya (sama dengan muat ulang penuh).
 *
 * ATURAN (sama dengan muat ulang 10 Oktober 2026 --normalisasi-impor, kecuali Jenis CB):
 *   - Jenis CB "Voucher" dimuat sebagai Voucher, "Voucher Transfer" sebagai Transfer,
 *     manual/RA07/RA7 sebagai Rebate Manual (pemilik, 14 Oktober 2026).
 *   - Cust Code yang tidak ada di Customer Master tetap dimuat ("Customer Master belum ada";
 *     kode sumber disimpan, proses klaim diblokir sampai master ada).
 *   - Baris bergalat lain tidak dimuat dan ditulis ke Excel temuan.
 *   - Dokumen yang sudah ada memakai ID dan Created On lamanya; riwayatnya diganti satu baris
 *     "muat_ulang". Submitted kembali menunggu Management of Approval ("line lama").
 *
 * PENJAGA
 *   - Pemeriksaan lengkap dulu. Pemuatan ditolak bila ada dokumen depot GANTI yang tidak akan
 *     dimuat kembali (akan hilang) atau klaim depot itu berubah sejak diperiksa.
 *   - Seluruh isi lama dicadangkan dulu (scripts/muat-ulang-data.mjs cadangkan) dan dapat
 *     dipulihkan dengan --pulihkan.
 *   - Hapus + muat + pemeriksaan dalam SATU transaksi; satu saja tidak cocok, seluruhnya batal.
 *
 * PEMAKAIAN
 *   node scripts/ganti-klaim-depot.mjs --berkas <xlsx> --env dev|prod --periksa [--temuan-xlsx <xlsx>]
 *   node scripts/ganti-klaim-depot.mjs --berkas <xlsx> --env dev  --jalankan --konfirmasi GANTI-KLAIM-DEV
 *   node scripts/ganti-klaim-depot.mjs --berkas <xlsx> --env prod --jalankan --konfirmasi GANTI-KLAIM-PROD-<yyyymmdd>
 *   node scripts/ganti-klaim-depot.mjs --env prod --pulihkan <folder hasil> --konfirmasi PULIHKAN-KLAIM-PROD-<yyyymmdd>
 *   Opsi: --lembar-ganti <nama> (bawaan "Perbaikan nominal"), --lembar-tambah <nama|-> (bawaan "Klaim").
 */
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

// Tanggal bernama bulan, jam, dan alias Jenis CB dibaca seperti muat ulang 10 Oktober 2026.
if (!process.argv.includes('--normalisasi-impor')) process.argv.push('--normalisasi-impor');
const { XLSX, LEMBAR, STATUS, URUT_STATUS, KOLOM_WAKTU, norm, kunciKode, bacaSel, angka, uraiTanggalKetat, iso,
  penghitungBatch, sambung, lit, jsonLit, siapkanStaging, kirimStaging, cadangkan, root } = await import('./muat-ulang-data.mjs');

const argv = process.argv.slice(2);
const ada = (n) => argv.includes(n);
const ambil = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : null; };
const tglWib = new Date(Date.now() + 7 * 3600 * 1000).toISOString().slice(0, 10).replace(/-/g, '');
const stempel = new Date(Date.now() + 7 * 3600 * 1000).toISOString().slice(0, 19).replace(/[-:T]/g, '').replace(/^(\d{8})/, '$1-');

const KOLOM = LEMBAR.Klaim.kolom.map(([k]) => k);
const JENIS = { 'transfer': 'Transfer', 'cn': 'CN', 'rebate': 'Rebate', 'rebate manual': 'Rebate Manual', 'voucher': 'Voucher',
  'voucher transfer': 'Transfer', 'manual': 'Rebate Manual', 'ra07': 'Rebate Manual', 'ra7': 'Rebate Manual' };
const uniq = (a) => [...new Set(a)];
const rupiah = (n) => 'Rp ' + Math.trunc(Number(n) || 0).toLocaleString('id-ID');
const nilaiSel = (s) => (!s || s.kosong ? null : s.tanggal ? iso(s.tanggal) : (s.angka ?? s.teks));
const tampilSel = (s) => (!s || s.kosong ? null : s.tanggal
  ? `${String(s.tanggal.d).padStart(2, '0')}-${String(s.tanggal.m).padStart(2, '0')}-${s.tanggal.y}` : (s.angka ?? s.teks));

// ------------------------------------------------------------------------------------------
// Membaca dan memeriksa
// ------------------------------------------------------------------------------------------
function bacaLembar(wb, nama) {
  const ws = wb.Sheets[nama];
  if (!ws) throw new Error(`lembar "${nama}" tidak ada di berkas`);
  const jangkau = XLSX.utils.decode_range(ws['!ref'] || 'A1:A1');
  const judul = new Map();
  for (let c = jangkau.s.c; c <= jangkau.e.c; c++) {
    const t = norm(bacaSel(ws, 0, c).teks).toLowerCase();
    if (t && !judul.has(t)) judul.set(t, c);
  }
  const hilang = LEMBAR.Klaim.kolom.filter(([k, wajib]) => wajib && !judul.has(k.toLowerCase())).map(([k]) => k);
  if (hilang.length) throw new Error(`lembar "${nama}": kolom wajib tidak ada: ${hilang.join(', ')}`);
  const baris = [];
  for (let r = 1; r <= jangkau.e.r; r++) {
    const sel = {};
    let isi = false;
    for (const k of KOLOM) {
      const c = judul.get(k.toLowerCase());
      sel[k] = c == null ? { kosong: true, teks: '' } : bacaSel(ws, r, c);
      if (!sel[k].kosong) isi = true;
    }
    if (isi) baris.push({ lembar: nama, baris: r + 1, sel });
  }
  return baris;
}

// Aturan per baris sama dengan bagian Klaim pada periksa() di muat-ulang-data.mjs.
function uraiBaris(b) {
  const galat = [], peringatan = [];
  const s = b.sel;
  const teks = (kol) => {
    const x = s[kol];
    if (x.numerik && x.teks.length > 15) galat.push(`${kol}: angka ${x.teks.length} digit kehilangan ketelitian di Excel; format sel sebagai Text lalu ketik ulang`);
    else if (x.numerik && /^(No KTP|No NPWP|Nomor Rekening)$/.test(kol)) peringatan.push(`${kol}: tersimpan sebagai angka; nol di depan (bila ada) sudah hilang`);
    return x.kosong ? null : x.teks;
  };
  for (const kol of ['No Document', 'Kode Depot', 'Cust Code', 'Code Campaign', 'Cashback After Tax', 'Status']) {
    if (s[kol].kosong) galat.push(`${kol}: wajib diisi`);
  }
  const status = s['Status'].kosong ? null : STATUS[norm(s['Status'].teks).toLowerCase()];
  if (!s['Status'].kosong && !status) galat.push(`Status: "${s['Status'].teks}" bukan status yang dikenal`);
  const nilai = {};
  for (const kol of ['Net Value', 'Volume', 'Cashback After Tax', 'Total Tagihan']) {
    const h = angka(s[kol]);
    if (h.galat) galat.push(`${kol}: ${h.galat}`);
    else if (h.nilai != null && h.nilai < 0) galat.push(`${kol}: tidak boleh negatif`);
    nilai[kol] = h.galat ? null : h.nilai;
  }
  let jenis = null;
  if (!s['Jenis CB'].kosong) {
    jenis = JENIS[norm(s['Jenis CB'].teks).toLowerCase()] || null;
    if (!jenis) galat.push(`Jenis CB: "${s['Jenis CB'].teks}" bukan Transfer, CN, Voucher, Rebate atau Rebate Manual`);
  }
  const tgl = {};
  for (const kol of ['Tgl Lunas', 'Tgl Submitted', 'Tgl Approved', 'Tgl Released', 'Tgl Claimed', 'Tgl Done',
                     'Hold SO Start', 'Hold SO End', 'Hold Billing Start', 'Hold Billing End']) {
    const h = uraiTanggalKetat(s[kol], KOLOM_WAKTU.has(kol));
    if (h.galat) galat.push(`${kol}: ${h.galat}`);
    tgl[kol] = h.nilai || null;
  }
  let sebelumHold = null;
  if (status === 'on_hold') {
    sebelumHold = s['Status Sebelum Hold'].kosong ? 'not_yet' : STATUS[norm(s['Status Sebelum Hold'].teks).toLowerCase()];
    if (!sebelumHold || ['on_hold', 'expired', 'done'].includes(sebelumHold)) galat.push(`Status Sebelum Hold: "${s['Status Sebelum Hold'].teks}" tidak sah untuk dokumen On Hold`);
    for (const [a, z] of [['Hold SO Start', 'Hold SO End'], ['Hold Billing Start', 'Hold Billing End']]) {
      if (tgl[a] && tgl[z] && tgl[z] < tgl[a]) galat.push(`${a}: periode perpanjangan terbalik`);
    }
  } else if (['Status Sebelum Hold', 'Hold SO Start', 'Hold SO End', 'Hold Billing Start', 'Hold Billing End'].some((k) => !s[k].kosong)) {
    peringatan.push('Status: kolom Hold diisi tetapi status bukan On Hold; diabaikan');
  }
  const tingkat = URUT_STATUS.indexOf(status);
  for (const [min, kol] of [[1, 'Batch Submitted'], [3, 'Batch Released'], [4, 'Batch Claimed'], [5, 'Batch Done']]) {
    if (tingkat >= min && s[kol].kosong) peringatan.push(`${kol}: status ${s['Status'].teks} tetapi ${kol} kosong`);
  }
  for (const kol of ['Batch Submitted', 'Batch Released', 'Batch Claimed', 'Batch Done']) {
    const v = teks(kol);
    if (v && !/^\d{15}$/.test(v)) peringatan.push(`${kol}: "${v}" bukan nomor batch 15 digit`);
  }
  const ktp = teks('No KTP'), npwp = teks('No NPWP');
  const k = {
    lembar: b.lembar, baris: b.baris, noDoc: teks('No Document'),
    depot: s['Kode Depot'].kosong ? null : kunciKode(s['Kode Depot'].teks),
    cust: teks('Cust Code'), camp: s['Code Campaign'].kosong ? null : norm(s['Code Campaign'].teks), status,
    net: nilai['Net Value'], vol: nilai['Volume'], cb: nilai['Cashback After Tax'], tagih: nilai['Total Tagihan'],
    jenis, top: teks('TOP'), lunas: tgl['Tgl Lunas'], ktp, npwp, taxSumber: npwp ? 'Badan' : (ktp ? 'Perorangan' : null),
    namaRek: s['Nama Rekening'].kosong ? null : s['Nama Rekening'].teks, noRek: teks('Nomor Rekening'),
    bank: s['Bank'].kosong ? null : s['Bank'].teks,
    bUp: teks('Batch Submitted'), tUp: tgl['Tgl Submitted'], tAp: tgl['Tgl Approved'],
    bRel: teks('Batch Released'), tRel: tgl['Tgl Released'], bCl: teks('Batch Claimed'), tCl: tgl['Tgl Claimed'],
    bClr: teks('Batch Done'), tClr: tgl['Tgl Done'],
    sebelumHold, hSoA: tgl['Hold SO Start'], hSoZ: tgl['Hold SO End'], hBiA: tgl['Hold Billing Start'], hBiZ: tgl['Hold Billing End'],
    legacy: {},
  };
  return { b, k, galat, peringatan };
}

async function periksaBerkas(db, berkas, lembarGanti, lembarTambah) {
  const wb = XLSX.read(new Uint8Array(await readFile(berkas)), { type: 'array', cellDates: false, cellNF: true, cellText: false });
  const ganti = bacaLembar(wb, lembarGanti);
  const tambah = lembarTambah ? bacaLembar(wb, lembarTambah) : [];
  const depotGanti = uniq(ganti.map((b) => (b.sel['Kode Depot'].kosong ? null : kunciKode(b.sel['Kode Depot'].teks))).filter(Boolean)).sort();
  if (!depotGanti.length) throw new Error(`lembar "${lembarGanti}" tidak memuat Kode Depot`);
  const semua = [...ganti, ...tambah].map(uraiBaris);

  // Baris lembar TAMBAH untuk depot GANTI = temuan 10 Oktober yang sudah diperbaiki pemilik, sedangkan
  // lembar GANTI memuat dokumen yang sama apa adanya. Bila No Document, depot, customer, campaign,
  // Cashback, dan Status sama, versi lembar TAMBAH yang dipakai dan baris GANTI-nya dilewati
  // (14 Oktober 2026: 19 dokumen berbeda hanya di Tgl Lunas/tanggal tahap/Jenis CB). Selain itu galat.
  const KUNCI = ['noDoc', 'depot', 'cust', 'camp', 'status', 'cb'];
  const isiK = (k, kolom) => kolom.map((f) => JSON.stringify(typeof k[f] === 'string' ? k[f].toUpperCase() : k[f] ?? null)).join('|');
  const ISI = Object.keys(semua[0]?.k || {}).filter((f) => !['lembar', 'baris', 'legacy'].includes(f));
  const petaGanti = new Map(semua.filter((x) => x.b.lembar === lembarGanti && x.k.noDoc).map((x) => [x.k.noDoc.toUpperCase(), x]));
  for (const x of semua.filter((x) => x.b.lembar !== lembarGanti && depotGanti.includes(x.k.depot))) {
    const g = x.k.noDoc ? petaGanti.get(x.k.noDoc.toUpperCase()) : null;
    if (g && isiK(x.k, ISI) === isiK(g.k, ISI) && x.galat.length === g.galat.length) {
      x.lewati = `sama dengan "${lembarGanti}" baris ${g.b.baris}`;
    } else if (g && isiK(x.k, KUNCI) === isiK(g.k, KUNCI)) {
      const beda = KOLOM.filter((kol) => String(nilaiSel(x.b.sel[kol]) ?? '') !== String(nilaiSel(g.b.sel[kol]) ?? ''));
      g.lewati = `diganti versi lembar "${x.b.lembar}" baris ${x.b.baris} (berbeda: ${beda.join(', ')})`;
      x.versiPerbaikan = g.b.baris;
    } else {
      x.galat.push(`Kode Depot: depot ${x.k.depot} dimuat ulang dari lembar "${lembarGanti}", tetapi baris ini ${g
        ? `berbeda dengan baris ${g.b.baris} pada kolom kunci (${KUNCI.filter((f) => isiK(x.k, [f]) !== isiK(g.k, [f])).join(', ')})` : 'tidak ada di lembar itu'}`);
    }
  }
  const calon = semua.filter((x) => !x.lewati);

  // Master dan klaim yang ada, sekali baca (hanya SELECT).
  const j = async (q) => (await db.sql(q))[0].j;
  const daftar = (a) => `(select upper(x) from jsonb_array_elements_text(${jsonLit(a)}) x)`;
  const kodeCamp = uniq(calon.map((x) => x.k.camp?.toUpperCase()).filter(Boolean));
  const kodeCust = uniq(calon.map((x) => x.k.cust?.toUpperCase()).filter(Boolean));
  const noDocs = uniq(calon.map((x) => x.k.noDoc?.toUpperCase()).filter(Boolean));
  const depot = await j(`select coalesce(jsonb_agg(jsonb_build_object('kode', depot_code, 'id', id, 'arsip', archived_at is not null)), '[]') j from public.depots`);
  const campaign = await j(`select coalesce(jsonb_agg(jsonb_build_object('kode', campaign_code, 'id', id, 'status', status, 'arsip', archived_at is not null)), '[]') j
    from public.campaigns where upper(campaign_code) in ${daftar(kodeCamp)}`);
  const customer = await j(`select coalesce(jsonb_agg(jsonb_build_object('kode', cu.customer_code, 'id', cu.id, 'arsip', cu.archived_at is not null,
      'depots', (select coalesce(jsonb_agg(cd.depot_id), '[]') from public.customer_depots cd where cd.customer_id = cu.id))), '[]') j
    from public.customers cu where upper(cu.customer_code) in ${daftar(kodeCust)}`);
  const adaDoc = await j(`select coalesce(jsonb_agg(jsonb_build_object('noDoc', c.no_doc, 'depot', d.depot_code)), '[]') j
    from public.claims c join public.depots d on d.id = c.depot_id where upper(c.no_doc) in ${daftar(noDocs)}`);
  const lama = await j(`select coalesce(jsonb_agg(jsonb_build_object('noDoc', c.no_doc, 'depot', d.depot_code, 'status', c.status, 'cb', c.cb_net,
      'arsip', c.archived_at is not null, 'pending', c.pending_approval->>'kind', 'actualOn', c.cleared_actual_on)), '[]') j
    from public.claims c join public.depots d on d.id = c.depot_id where d.depot_code in (select x from jsonb_array_elements_text(${jsonLit(depotGanti)}) x)`);
  const total = (await db.sql('select count(*)::int n, coalesce(sum(cb_net), 0) cb from public.claims;'))[0];

  const petaDepot = new Map(depot.map((d) => [kunciKode(d.kode), d]));
  const petaCamp = new Map(), petaCust = new Map(), petaAda = new Map();
  for (const c of campaign) { const k = c.kode.toUpperCase(); petaCamp.set(k, petaCamp.has(k) ? 'ganda' : c); }
  for (const c of customer) { const k = c.kode.toUpperCase(); petaCust.set(k, petaCust.has(k) ? 'ganda' : c); }
  for (const c of adaDoc) petaAda.set(c.noDoc.toUpperCase(), c);
  for (const d of depotGanti) if (!petaDepot.has(d)) throw new Error(`depot ${d} di lembar "${lembarGanti}" tidak ada di database`);

  const salinan = new Map();
  for (const x of calon) if (x.k.noDoc) { const k = x.k.noDoc.toUpperCase(); salinan.set(k, [...(salinan.get(k) || []), x]); }
  for (const x of calon) {
    const { k } = x;
    if (k.noDoc && salinan.get(k.noDoc.toUpperCase()).length > 1) {
      x.galat.push(`No Document: ${k.noDoc} ganda (${salinan.get(k.noDoc.toUpperCase()).filter((y) => y !== x).map((y) => `${y.b.lembar} baris ${y.b.baris}`).join(', ')}); semua salinan ditahan`);
    }
    const dp = k.depot ? petaDepot.get(k.depot) : null;
    if (k.depot && !dp) x.galat.push(`Kode Depot: depot ${k.depot} tidak ada`);
    else if (dp?.arsip) x.peringatan.push(`Kode Depot: depot ${k.depot} terarsip`);
    k.depotId = dp?.id || null;
    const lain = k.noDoc ? petaAda.get(k.noDoc.toUpperCase()) : null;
    if (lain && !depotGanti.includes(kunciKode(lain.depot))) x.galat.push(`No Document: ${k.noDoc} sudah ada di database pada depot ${lain.depot}`);
    const ca = k.camp ? petaCamp.get(k.camp.toUpperCase()) : null;
    if (k.camp && !ca) x.galat.push(`Code Campaign: campaign ${k.camp} tidak ada di Campaign Master`);
    else if (ca === 'ganda') x.galat.push(`Code Campaign: ${k.camp} cocok dengan lebih dari satu campaign (beda huruf besar/kecil)`);
    else if (ca) {
      if (['inactive', 'cleared'].includes(ca.status)) x.galat.push(`Code Campaign: campaign ${ca.kode} berstatus ${ca.status}; klaim baru tidak dapat dibuat`);
      if (ca.arsip) x.peringatan.push(`Code Campaign: campaign ${ca.kode} terarsip`);
      k.camp = ca.kode; k.campaignId = ca.id;
    }
    const cu = k.cust ? petaCust.get(k.cust.toUpperCase()) : null;
    k.customerId = null;
    if (cu === 'ganda') x.galat.push(`Cust Code: ${k.cust} cocok dengan lebih dari satu customer (beda huruf besar/kecil)`);
    else if (k.cust && !cu) x.peringatan.push(`Cust Code: pelanggan ${k.cust} tidak ada di Customer Master; dimuat sebagai "Customer Master belum ada"`);
    else if (cu) {
      k.cust = cu.kode; k.customerId = cu.id;
      if (cu.arsip) x.peringatan.push(`Cust Code: pelanggan ${cu.kode} terarsip`);
      if (k.depotId && !cu.depots.includes(k.depotId)) { x.pemetaan = true; x.peringatan.push(`Kode Depot: pelanggan ${cu.kode} belum terdaftar di depot ${k.depot}; pemetaannya ditambahkan`); }
    }
  }

  // Not Achieved / Not Participating menolak klaim baru lewat trigger; diperiksa lebih dulu.
  const pasangan = uniq(calon.filter((x) => !x.galat.length && x.k.depotId && x.k.campaignId).map((x) => x.k.depotId + '|' + x.k.campaignId)).map((p) => p.split('|'));
  const larang = pasangan.length ? await j(`select coalesce(jsonb_agg(jsonb_build_object('p', p->>0 || '|' || (p->>1), 'na', na, 'np', np)) filter (where na or np), '[]') j from (
      select p, exists(select 1 from public.timetable_not_achieved t where t.depot_id = (p->>0)::uuid and t.campaign_id = (p->>1)::uuid) na,
             rc_private.np_pasangan((p->>0)::uuid, (p->>1)::uuid) np from jsonb_array_elements(${jsonLit(pasangan)}) p) s`) : [];
  const petaLarang = new Map(larang.map((l) => [l.p, l]));
  for (const x of calon) {
    const l = petaLarang.get(x.k.depotId + '|' + x.k.campaignId);
    if (l) x.galat.push(`Code Campaign: depot ${x.k.depot} pada campaign ${x.k.camp} ditandai ${[l.na && 'Not Achieved', l.np && 'Not Participating'].filter(Boolean).join(' dan ')}`);
  }

  const dimuat = calon.filter((x) => !x.galat.length);
  const ditahan = calon.filter((x) => x.galat.length);
  const kunciDimuat = new Set(dimuat.map((x) => x.k.noDoc.toUpperCase()));
  const hilang = lama.filter((c) => !kunciDimuat.has(c.noDoc.toUpperCase()));
  const kunciLama = new Set(lama.map((c) => c.noDoc.toUpperCase()));

  // Kembar nilai (Code Campaign + Cust Code + Cashback After Tax) hanya dilaporkan.
  const nilaiKembar = new Map();
  for (const x of dimuat) { const k = [x.k.camp, x.k.cust, Math.round((x.k.cb || 0) * 100)].join('|'); nilaiKembar.set(k, [...(nilaiKembar.get(k) || []), x]); }
  for (const grup of nilaiKembar.values()) if (grup.length > 1) for (const x of grup) {
    x.peringatan.push(`Cashback After Tax: Code Campaign + Cust Code + Cashback sama dengan ${grup.filter((y) => y !== x).map((y) => y.k.noDoc).join(', ')}`);
  }

  const rincian = new Map();
  for (const x of dimuat) {
    const kunci = x.k.depot + '|' + x.k.status;
    const r = rincian.get(kunci) || { depot: x.k.depot, status: x.k.status, n: 0, cb: 0 };
    r.n++; r.cb += x.k.cb || 0; rincian.set(kunci, r);
  }
  const pemetaan = uniq(dimuat.filter((x) => x.pemetaan).map((x) => x.k.customerId + '|' + x.k.depotId)).map((p) => { const [c, d] = p.split('|'); return { customerId: c, depotId: d }; });
  const jumlah = (a, f = (x) => x.k.cb) => a.reduce((s, x) => s + (Number(f(x)) || 0), 0);
  return {
    lembarGanti, lembarTambah, depotGanti, depotGantiId: depotGanti.map((d) => petaDepot.get(d).id),
    semua, dimuat, ditahan, dilewati: semua.filter((x) => x.lewati), hilang, lama, total, pemetaan,
    rincian: [...rincian.values()].sort((a, b) => (a.depot + a.status).localeCompare(b.depot + b.status)),
    harap: {
      klaim: dimuat.length, totalCb: jumlah(dimuat), hapus: lama.length, cbHapus: jumlah(lama, (c) => c.cb),
      depotGanti: dimuat.filter((x) => depotGanti.includes(x.k.depot)).length,
      tanpaCustomer: dimuat.filter((x) => !x.k.customerId).length,
      submitted: dimuat.filter((x) => x.k.status === 'submitted' && x.k.customerId).length,
      baru: dimuat.filter((x) => !kunciLama.has(x.k.noDoc.toUpperCase())).length,
    },
  };
}

function cetakPeriksa(h) {
  const { harap } = h;
  console.log(`\n  Depot diganti (${h.lembarGanti}): ${h.depotGanti.join(', ')}`);
  console.log(`  Baris dibaca: ${h.semua.length} | dilewati (dokumen yang sama di dua lembar): ${h.dilewati.length} | DIMUAT: ${harap.klaim} | ditahan sebagai temuan: ${h.ditahan.length}`);
  const versi = h.dimuat.filter((x) => x.versiPerbaikan);
  if (versi.length) console.log(`  Dokumen depot ganti yang memakai versi perbaikan lembar ${h.lembarTambah}: ${versi.length} (${versi.map((x) => x.k.noDoc).join(', ')})`);
  console.log(`  Klaim depot ${h.depotGanti.join('/')} sekarang: ${harap.hapus} dokumen ${rupiah(harap.cbHapus)} -> dihapus, diganti ${harap.depotGanti} dokumen`);
  console.log(`  Dokumen baru (belum ada di database): ${harap.baru} | tanpa Customer Master: ${harap.tanpaCustomer} | Submitted menunggu approval: ${harap.submitted} | pemetaan depot ditambah: ${h.pemetaan.length}`);
  console.log(`  Total klaim database: ${h.total.n} ${rupiah(h.total.cb)} -> ${h.total.n - harap.hapus + harap.klaim} ${rupiah(Number(h.total.cb) - harap.cbHapus + harap.totalCb)}`);
  const perDepot = (a, f) => a.reduce((m, x) => { const d = f(x); m[d] ??= { n: 0, cb: 0 }; m[d].n++; m[d].cb += Number(x.cb ?? x.k?.cb) || 0; return m; }, {});
  const sebelum = perDepot(h.lama.map((c) => ({ ...c, depot: kunciKode(c.depot) })), (c) => c.depot);
  const sesudah = h.rincian.reduce((m, r) => { m[r.depot] ??= { n: 0, cb: 0 }; m[r.depot].n += r.n; m[r.depot].cb += r.cb; return m; }, {});
  console.log('\n  Depot   sebelum                          sesudah');
  for (const d of uniq([...h.depotGanti, ...Object.keys(sesudah)]).sort()) {
    const a = sebelum[d], z = sesudah[d];
    console.log(`  ${d.padEnd(6)}  ${(a ? `${a.n} dok ${rupiah(a.cb)}` : h.depotGanti.includes(d) ? '0' : '(tidak diganti; ditambah)').padEnd(32)} ${z ? `${z.n} dok ${rupiah(z.cb)}` : '-'}`);
  }
  if (h.ditahan.length) {
    console.log(`\n  \x1b[31mDITAHAN (${h.ditahan.length}) - tidak dimuat, ditulis ke Excel temuan\x1b[0m`);
    for (const x of h.ditahan) console.log(`   ${x.b.lembar} baris ${x.b.baris} ${x.k.noDoc || '-'} (${x.k.depot || '-'}): ${x.galat.join(' | ')}`);
  }
  const kelompok = {};
  for (const x of h.dimuat) for (const p of x.peringatan) { const k = p.replace(/"[^"]*"|\b[A-Z0-9/]{3,}\b|\d+/g, '…'); kelompok[k] = (kelompok[k] || 0) + 1; }
  if (Object.keys(kelompok).length) {
    console.log('\n  \x1b[33mPERINGATAN pada baris yang dimuat\x1b[0m');
    for (const [k, n] of Object.entries(kelompok).sort((a, b) => b[1] - a[1])) console.log(`   ${String(n).padStart(5)} x  ${k}`);
  }
  if (h.hilang.length) {
    console.log(`\n  \x1b[41m\x1b[30m DOKUMEN AKAN HILANG (${h.hilang.length}) \x1b[0m ada di depot ${h.depotGanti.join('/')} tetapi tidak akan dimuat kembali:`);
    for (const c of h.hilang.slice(0, 30)) console.log(`   ${c.noDoc} ${c.depot} ${c.status} ${rupiah(c.cb)}`);
  }
  const pending = h.lama.filter((c) => c.pending).length, arsip = h.lama.filter((c) => c.arsip).length, actual = h.lama.filter((c) => c.actualOn).length;
  if (pending || arsip || actual) console.log(`\n  Catatan: dari dokumen lama, ${pending} punya ajuan approval, ${arsip} terarsip, ${actual} punya Tanggal Clearing Aktual - semuanya diganti isi berkas.`);
}

async function tulisLaporan(folder, h, temuanXlsx) {
  await mkdir(folder, { recursive: true });
  const q = (v) => '"' + String(v ?? '').replace(/"/g, '""') + '"';
  const baris = [];
  for (const x of h.semua) {
    for (const g of x.galat) baris.push(['GALAT', x.b.lembar, x.b.baris, x.k.noDoc, x.k.depot, g]);
    for (const p of x.peringatan) baris.push(['peringatan', x.b.lembar, x.b.baris, x.k.noDoc, x.k.depot, p]);
    if (x.lewati) baris.push(['dilewati', x.b.lembar, x.b.baris, x.k.noDoc, x.k.depot, x.lewati]);
  }
  await writeFile(path.join(folder, 'temuan.csv'), '﻿' + ['Jenis,Lembar,Baris,No Document,Kode Depot,Pesan', ...baris.map((r) => r.map(q).join(','))].join('\r\n'));
  await writeFile(path.join(folder, 'periksa.json'), JSON.stringify({ depotGanti: h.depotGanti, harap: h.harap, rincian: h.rincian,
    total: h.total, ditahan: h.ditahan.map((x) => ({ lembar: x.b.lembar, baris: x.b.baris, noDoc: x.k.noDoc, galat: x.galat })),
    hilang: h.hilang }, null, 2));
  if (temuanXlsx) {
    // Bentuk sama dengan Excel temuan muat ulang: kolom template Klaim + Remark (baris sumber dan alasan).
    const definisi = [{ nama: 'Klaim', opsional: false, keterangan: LEMBAR.Klaim.keterangan,
      kolom: [...LEMBAR.Klaim.kolom.map(([k, wajib, teks, contoh, ket]) => ({ nama: k, wajib: !!wajib, teks: teks === 'teks', contoh, keterangan: ket, pilihan: null })),
        { nama: 'Remark', wajib: false, teks: false, contoh: '', keterangan: 'Baris sumber dan alasan tidak dimuat.', pilihan: null }] }];
    const data = { Klaim: h.ditahan.map((x) => [...KOLOM.map((k) => tampilSel(x.b.sel[k])), `${x.b.lembar} baris ${x.b.baris}. ${x.galat.join(' | ')}`]) };
    await mkdir(path.dirname(path.resolve(temuanXlsx)), { recursive: true });
    const r = spawnSync('python', [path.join(root, 'scripts', 'buat-template-muat-ulang.py'), path.resolve(temuanXlsx)],
      { input: JSON.stringify({ definisi, data, tanpaPetunjuk: true }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
    if (r.status !== 0) throw new Error('menulis Excel temuan gagal: ' + (r.stderr || r.error || '').toString().slice(-4000));
    console.log(`  Excel temuan: ${path.resolve(temuanXlsx)} (${h.ditahan.length} baris)`);
  }
}

// ------------------------------------------------------------------------------------------
// Pertukaran atomik
// ------------------------------------------------------------------------------------------
const utuhkanNol = (berkas, master) => `case when ${berkas} ~ '^[0-9]+$' and ${master} ~ '^[0-9]+$'
      and length(${berkas}) < length(${master}) and ltrim(${master}, '0') = ltrim(${berkas}, '0')
    then ${master} else coalesce(${berkas}, ${master}) end`;

function sqlGanti(sesi, h, uji = false) {
  const { harap } = h;
  const arrDep = `array[${h.depotGantiId.map((id) => lit(id) + '::uuid').join(',')}]`;
  const alasan = `Data dimuat ulang ${tglWib} (ganti klaim depot ${h.depotGanti.join(', ')})`;
  return `
do $ganti$
declare
  v_sesi uuid := ${lit(sesi)}::uuid;
  v_dep uuid[] := ${arrDep};
  v_awal int; n int; v_sum numeric; v_map int; e text := '';
begin
  perform pg_advisory_xact_lock(hashtextextended('rc-muat-ulang', 0));
  lock table public.claims, public.customer_depots, rc_private.claim_sensitive, public.claim_status_history in share row exclusive mode;

  -- 0. Staging lengkap, dan klaim depot ganti tidak berubah sejak diperiksa.
  if (select count(*) from rc_muat_ulang.baris where sesi=v_sesi and jenis='klaim') <> ${harap.klaim}
  or (select count(*) from rc_muat_ulang.baris where sesi=v_sesi and jenis='pemetaan') <> ${h.pemetaan.length} then
    raise exception 'DITOLAK: staging tidak lengkap; kirim ulang.'; end if;
  select count(*), coalesce(sum(cb_net), 0) into n, v_sum from public.claims where depot_id = any(v_dep);
  if n <> ${harap.hapus} or round(v_sum, 2) <> round(${harap.cbHapus}::numeric, 2) then
    raise exception 'DITOLAK: klaim depot ${h.depotGanti.join('/')} berubah sejak diperiksa (% dokumen, CB %); periksa ulang.', n, v_sum; end if;
  if exists(select 1 from public.claims c join rc_muat_ulang.baris s on s.sesi=v_sesi and s.jenis='klaim' and upper(c.no_doc) = upper(s.data->>'noDoc')
             where not (c.depot_id = any(v_dep))) then
    raise exception 'DITOLAK: ada No Document berkas yang sudah dipakai depot lain; periksa ulang.'; end if;
  select count(*) into v_awal from public.claims;

  -- 1. ID dan Created On dokumen lama dipertahankan untuk No Document yang sama.
  create temp table _lama on commit drop as select id, no_doc, created_at from public.claims where depot_id = any(v_dep);
  delete from rc_private.claim_sensitive s using _lama l where s.claim_id = l.id;
  delete from public.claim_status_history x using _lama l where x.claim_id = l.id;
  delete from public.claims c using _lama l where c.id = l.id;
  get diagnostics n = row_count;
  if n <> ${harap.hapus} then raise exception 'GAGAL: % klaim terhapus, harap ${harap.hapus}', n; end if;

  -- 2. Pemetaan depot pelanggan yang belum ada.
  insert into public.customer_depots(customer_id, depot_id)
  select (d->>'customerId')::uuid, (d->>'depotId')::uuid from (select data d from rc_muat_ulang.baris where sesi=v_sesi and jenis='pemetaan') s
  on conflict do nothing;
  get diagnostics v_map = row_count;

  -- 3. Klaim: kolom dan aturan sama dengan muat ulang penuh (sqlTukar langkah 6).
  create temp table _baru(id uuid primary key, no_doc text, status text) on commit drop;
  with ins as (
    insert into public.claims(id, created_at, no_doc, depot_id, customer_id, source_customer_code, master_data_issue,
      campaign_id, status, net_value, volume, cb_net, gross_up,
      cashback_type_override, cashback_type_changed, tax_subject, paid_on, total_billing, legacy_dates,
      batch_upload, uploaded_at, approved_at, batch_release, released_at, batch_claim, claimed_at, batch_clearing, cleared_at,
      previous_status, extend_so_start, extend_so_end, extend_billing_start, extend_billing_end, pending_approval, version_no)
    select coalesce(l.id, gen_random_uuid()), coalesce(l.created_at, now()), coalesce(l.no_doc, d->>'noDoc'), dp.id, cu.id, d->>'cust',
      case when cu.id is null then 'Customer Master tidak ditemukan: '||(d->>'cust') end,
      ca.id, d->>'status',
      (d->>'net')::numeric, (d->>'vol')::numeric, (d->>'cb')::numeric,
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
      -- Submitted menunggu Management of Approval; Rebate Manual dan Voucher langsung ke Done (20261163100000).
      case when d->>'status'='submitted' and cu.id is not null then jsonb_build_object('kind','submit','requested_by',null,
        'requested_at', coalesce((d->>'tUp')::timestamptz, now()), 'reason','Muat ulang data',
        'target_status', case when rc_private.jenis_efektif(coalesce(nullif(d->>'jenis', ''), ca.cashback_type)) in ('rebate manual','voucher')
          then 'done' else 'approved' end) end,
      1
    from (select data d from rc_muat_ulang.baris where sesi=v_sesi and jenis='klaim') s
    join public.depots dp on dp.id = (s.d->>'depotId')::uuid
    left join public.customers cu on cu.id = (s.d->>'customerId')::uuid
    join public.campaigns ca on ca.id = (s.d->>'campaignId')::uuid
    left join _lama l on upper(l.no_doc) = upper(s.d->>'noDoc')
    returning id, no_doc, status)
  insert into _baru select id, no_doc, status from ins;
  get diagnostics n = row_count;
  if n <> ${harap.klaim} then e := e || format(' klaim dimuat %s (harap ${harap.klaim});', n); end if;

  insert into rc_private.claim_sensitive(claim_id, ktp, npwp, bank, account_number, account_name, top_text)
  select c.id, ${utuhkanNol("s.d->>'ktp'", 'cu.ktp')}, ${utuhkanNol("s.d->>'npwp'", 'cu.npwp')}, coalesce(s.d->>'bank', cu.bank),
         ${utuhkanNol("s.d->>'noRek'", 'cu.account_number')}, coalesce(s.d->>'namaRek', cu.account_name), coalesce(s.d->>'top', cu.top_text)
    from (select data d from rc_muat_ulang.baris where sesi=v_sesi and jenis='klaim') s
    join _baru b on upper(b.no_doc) = upper(s.d->>'noDoc')
    join public.claims c on c.id = b.id
    left join public.customers cu on cu.id = c.customer_id;

  insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
  select b.id, null, null, b.status, 'muat_ulang', ${lit(alasan)} from _baru b;

  -- 4. Penghitung batch dinaikkan setinggi nomor yang dimuat.
  insert into rc_private.batch_counters(stage, suffix, business_date, counter)
  select d->>'stage', d->>'suffix', (d->>'tanggal')::date, (d->>'counter')::int
    from (select data d from rc_muat_ulang.baris where sesi=v_sesi and jenis='penghitung') s
  on conflict (stage, suffix, business_date) do update set counter = greatest(rc_private.batch_counters.counter, excluded.counter);

  -- 5. Pemeriksaan. Satu saja gagal -> seluruh transaksi dibatalkan, data lama utuh.
  if (select count(*) from public.claims) <> v_awal - ${harap.hapus} + ${harap.klaim} then e := e || ' jumlah klaim total;'; end if;
  if (select count(*) from public.claims where depot_id = any(v_dep)) <> ${harap.depotGanti} then e := e || ' jumlah klaim depot ganti;'; end if;
  select coalesce(sum(c.cb_net), 0) into v_sum from _baru b join public.claims c on c.id = b.id;
  if round(v_sum, 2) <> round(${harap.totalCb}::numeric, 2) then e := e || format(' total CB Net %s (harap ${harap.totalCb});', v_sum); end if;
  create temp table _harap on commit drop as select * from jsonb_to_recordset(${jsonLit(h.rincian)}) as x(depot text, status text, n int, cb numeric);
  if exists(select 1 from (select dp.depot_code depot, c.status, count(*)::int n, sum(c.cb_net) cb from _baru b join public.claims c on c.id = b.id
              join public.depots dp on dp.id = c.depot_id group by 1, 2) a full join _harap x using (depot, status)
             where a.n is distinct from x.n or round(a.cb, 2) is distinct from round(x.cb, 2)) then e := e || ' rincian depot/status;'; end if;
  if (select count(*) from rc_private.claim_sensitive s join _baru b on b.id = s.claim_id) <> ${harap.klaim} then e := e || ' data sensitif;'; end if;
  if (select count(*) from public.claim_status_history x join _baru b on b.id = x.claim_id) <> ${harap.klaim} then e := e || ' riwayat;'; end if;
  if (select count(*) from _baru b join public.claims c on c.id = b.id where c.customer_id is null) <> ${harap.tanpaCustomer} then e := e || ' klaim tanpa Customer Master;'; end if;
  if (select count(*) from _baru b join public.claims c on c.id = b.id where c.status = 'submitted' and c.pending_approval is not null) <> ${harap.submitted} then
    e := e || ' antrean approval Submitted;'; end if;
  if exists(select 1 from _baru b join public.claims c on c.id = b.id where c.customer_id is not null
             and not exists(select 1 from public.customer_depots m where m.customer_id = c.customer_id and m.depot_id = c.depot_id)) then
    e := e || ' klaim yang depotnya tidak terpetakan pada pelanggannya;'; end if;
  if exists(select 1 from _baru b join public.claims c on c.id = b.id join public.campaigns ca on ca.id = c.campaign_id
             where c.customer_id is not null and coalesce(c.gross_up, 0) <> 0
               and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('rebate', 'rebate manual', 'voucher')) then
    e := e || ' gross up Rebate/Voucher bukan 0;'; end if;
  if e <> '' then raise exception 'GAGAL, dibatalkan:%', e; end if;
${uji ? `  -- --uji: semua langkah dan pemeriksaan sudah lolos; hasilnya dilaporkan lalu DIBATALKAN.
  raise exception 'UJI_SELESAI%', (select jsonb_build_object('n', (select count(*) from public.claims), 'cb', (select sum(cb_net) from public.claims),
    'depot', (select jsonb_object_agg(t.depot_code, jsonb_build_array(t.jml, t.total)) from (select dp.depot_code, count(*) jml, sum(c.cb_net) total
               from public.claims c join public.depots dp on dp.id = c.depot_id where c.depot_id = any(v_dep) group by dp.depot_code) t),
    'idSama', (select count(*) from _baru b join _lama l on l.id = b.id))::text);` : ''}

  insert into public.activity_logs(actor_id, event_type, details)
  values (null, 'klaim_depot_dimuat_ulang', jsonb_build_object('tanggal', '${tglWib}', 'depot', ${jsonLit(h.depotGanti)},
    'dihapus', ${harap.hapus}, 'cbDihapus', ${harap.cbHapus}, 'dimuat', ${harap.klaim}, 'dimuatDepotGanti', ${harap.depotGanti},
    'totalCbNet', ${harap.totalCb}, 'klaimTanpaCustomerMaster', ${harap.tanpaCustomer}, 'pemetaanDitambah', v_map,
    'ditahan', ${h.ditahan.length}));
end
$ganti$;`;
}

// ------------------------------------------------------------------------------------------
// Pemulihan: klaim depot ganti dari cadangan, dokumen baru dihapus, pemetaan baru dicabut
// ------------------------------------------------------------------------------------------
async function pulihkan(db, folder) {
  const rencana = JSON.parse(await readFile(path.join(folder, 'rencana.json'), 'utf8'));
  const baca = async (t) => JSON.parse(await readFile(path.join(rencana.cadangan, t + '.json'), 'utf8'));
  const depIds = new Set(rencana.depotGantiId);
  const klaim = (await baca('public.claims')).filter((c) => depIds.has(c.depot_id));
  const ids = new Set(klaim.map((c) => c.id));
  const sensitif = (await baca('rc_private.claim_sensitive')).filter((s) => ids.has(s.claim_id));
  const riwayat = (await baca('public.claim_status_history')).filter((x) => ids.has(x.claim_id));
  const cb = klaim.reduce((s, c) => s + Number(c.cb_net), 0);
  console.log(`  Cadangan ${rencana.cadangan}: ${klaim.length} klaim depot ${rencana.depotGanti.join('/')} ${rupiah(cb)}, ${sensitif.length} sensitif, ${riwayat.length} riwayat`);
  const sesi = randomUUID();
  await siapkanStaging(db);
  for (const [jenis, isi] of [['pulih:claims', klaim], ['pulih:sensitif', sensitif], ['pulih:riwayat', riwayat],
    ['pulih:dimuat', rencana.noDocDimuat.map((d) => ({ d }))], ['pulih:pemetaan', rencana.pemetaan]]) {
    process.stdout.write(`  staging ${jenis.padEnd(16)} ${String(isi.length).padStart(6)} `);
    await kirimStaging(db, sesi, jenis, isi, 400);
    console.log('');
  }
  const rec = (t, j) => `(select (jsonb_populate_record(null::${t}, data)).* from rc_muat_ulang.baris where sesi=v_sesi and jenis='${j}')`;
  const arrDep = `array[${rencana.depotGantiId.map((id) => lit(id) + '::uuid').join(',')}]`;
  try {
    await db.sql(`
do $pulih$
declare v_sesi uuid := ${lit(sesi)}::uuid; v_dep uuid[] := ${arrDep}; n int; v_sum numeric;
begin
  perform pg_advisory_xact_lock(hashtextextended('rc-muat-ulang', 0));
  lock table public.claims, public.customer_depots, rc_private.claim_sensitive, public.claim_status_history in share row exclusive mode;
  create temp table _hapus on commit drop as select id from public.claims c where c.depot_id = any(v_dep)
    or upper(c.no_doc) in (select upper(data->>'d') from rc_muat_ulang.baris where sesi=v_sesi and jenis='pulih:dimuat');
  delete from rc_private.claim_sensitive s using _hapus h where s.claim_id = h.id;
  delete from public.claim_status_history x using _hapus h where x.claim_id = h.id;
  delete from public.claims c using _hapus h where c.id = h.id;
  insert into public.claims select * from ${rec('public.claims', 'pulih:claims')} x;
  insert into rc_private.claim_sensitive select * from ${rec('rc_private.claim_sensitive', 'pulih:sensitif')} x;
  insert into public.claim_status_history overriding system value select * from ${rec('public.claim_status_history', 'pulih:riwayat')} x;
  perform setval(pg_get_serial_sequence('public.claim_status_history','id'), greatest((select max(id) from public.claim_status_history), 1));
  -- Pemetaan yang ditambahkan alat ini dicabut bila tidak ada lagi klaim yang memerlukannya.
  delete from public.customer_depots m using (select (data->>'customerId')::uuid c, (data->>'depotId')::uuid d
      from rc_muat_ulang.baris where sesi=v_sesi and jenis='pulih:pemetaan') p
   where m.customer_id = p.c and m.depot_id = p.d
     and not exists(select 1 from public.claims k where k.customer_id = p.c and k.depot_id = p.d);
  select count(*), coalesce(sum(cb_net), 0) into n, v_sum from public.claims where depot_id = any(v_dep);
  if n <> ${klaim.length} or round(v_sum, 2) <> round(${cb}::numeric, 2) then
    raise exception 'GAGAL memulihkan: % klaim CB % (harap ${klaim.length} CB ${cb}); dibatalkan.', n, v_sum; end if;
  if (select count(*) from rc_private.claim_sensitive s join public.claims c on c.id = s.claim_id where c.depot_id = any(v_dep)) <> ${sensitif.length}
  or (select count(*) from public.claim_status_history x join public.claims c on c.id = x.claim_id where c.depot_id = any(v_dep)) <> ${riwayat.length} then
    raise exception 'GAGAL memulihkan: data sensitif/riwayat tidak cocok; dibatalkan.'; end if;
  insert into public.activity_logs(actor_id, event_type, details)
  values (null, 'klaim_depot_dipulihkan', jsonb_build_object('dari', ${lit(path.basename(folder))}, 'depot', ${jsonLit(rencana.depotGanti)}, 'klaim', ${klaim.length}));
end
$pulih$;`);
  } finally {
    await db.sql(`delete from rc_muat_ulang.baris where sesi=${lit(sesi)}::uuid;`);
  }
  console.log(`\n  \x1b[32mDipulihkan:\x1b[0m ${klaim.length} klaim depot ${rencana.depotGanti.join('/')} ${rupiah(cb)}; ${rencana.noDocDimuat.length} dokumen hasil pemuatan dicabut.`);
}

// ------------------------------------------------------------------------------------------
// Main
// ------------------------------------------------------------------------------------------
async function ringkasDb(db, depotGanti) {
  return (await db.sql(`select coalesce(jsonb_agg(x order by x->>'depot', x->>'status'), '[]') j from (
    select jsonb_build_object('depot', d.depot_code, 'status', c.status, 'n', count(*), 'cb', sum(c.cb_net)) x
      from public.claims c join public.depots d on d.id = c.depot_id
     where d.depot_code in (select x from jsonb_array_elements_text(${jsonLit(depotGanti)}) x) group by d.depot_code, c.status) s;`))[0].j;
}

// --uji: staging + transaksi lengkap dengan seluruh pemeriksaannya, lalu dibatalkan. Tidak ada
// cadangan karena tidak ada yang berubah; staging dibersihkan di akhir.
async function ujiTransaksi(db, h) {
  const sesi = randomUUID();
  await siapkanStaging(db);
  const baris = h.dimuat.map((x) => { const { lembar, baris: _b, ...k } = x.k; return k; });
  let hasil = null;
  try {
    await kirimStaging(db, sesi, 'klaim', baris);
    await kirimStaging(db, sesi, 'pemetaan', h.pemetaan);
    await kirimStaging(db, sesi, 'penghitung', penghitungBatch(baris));
    await db.sql(sqlGanti(sesi, h, true));
  } catch (e) {
    // Pesan galat datang sebagai JSON di dalam badan HTTP (tanda kutip ter-escape); objeknya
    // diambil sampai kurung kurawal penutup pasangannya.
    const t = e.message.replace(/\\"/g, '"');
    const a = t.indexOf('UJI_SELESAI{');
    if (a < 0) throw new Error(`UJI GAGAL (tidak ada yang berubah): ${e.message}`);
    let i = a + 'UJI_SELESAI'.length, dalam = 0;
    do { if (t[i] === '{') dalam++; else if (t[i] === '}') dalam--; i++; } while (dalam > 0 && i < t.length);
    hasil = JSON.parse(t.slice(a + 'UJI_SELESAI'.length, i));
  } finally {
    await db.sql(`delete from rc_muat_ulang.baris where sesi=${lit(sesi)}::uuid;`).catch(() => {});
  }
  if (!hasil) throw new Error('UJI tidak mencapai akhir transaksi');
  console.log(`\n  \x1b[32mUJI LOLOS\x1b[0m - seluruh pemeriksaan transaksi cocok, lalu dibatalkan (tidak ada yang berubah).`);
  console.log(`   total klaim sesudah: ${hasil.n} ${rupiah(hasil.cb)} | ID lama dipakai ulang: ${hasil.idSama}`);
  for (const [d, [n, cb]] of Object.entries(hasil.depot || {})) console.log(`   ${d}: ${n} dok ${rupiah(cb)}`);
}

async function main() {
  const namaEnv = ambil('--env');
  const konfirmasi = ambil('--konfirmasi');
  if (!namaEnv) throw new Error('--env dev|prod wajib');

  if (ambil('--pulihkan')) {
    const harus = namaEnv === 'prod' ? `PULIHKAN-KLAIM-PROD-${tglWib}` : `PULIHKAN-KLAIM-${namaEnv.toUpperCase()}`;
    if (konfirmasi !== harus) throw new Error(`ketik --konfirmasi ${harus}`);
    const db = await sambung(namaEnv);
    await pulihkan(db, path.resolve(ambil('--pulihkan')));
    await db.sql('select rc_private.segarkan_dashboard_publik();').catch(() => {});
    return;
  }

  const berkas = ambil('--berkas');
  if (!berkas) throw new Error('--berkas <xlsx> wajib');
  const lembarGanti = ambil('--lembar-ganti') || 'Perbaikan nominal';
  const lembarTambah = ambil('--lembar-tambah') === '-' ? null : (ambil('--lembar-tambah') || 'Klaim');
  const jalankan = ada('--jalankan');
  const uji = ada('--uji');
  if (uji && jalankan) throw new Error('pilih --uji atau --jalankan');
  if (jalankan) {
    const harus = namaEnv === 'prod' ? `GANTI-KLAIM-PROD-${tglWib}` : `GANTI-KLAIM-${namaEnv.toUpperCase()}`;
    if (konfirmasi !== harus) throw new Error(`ketik --konfirmasi ${harus}`);
  } else if (!ada('--periksa') && !uji) throw new Error('pilih --periksa, --uji, atau --jalankan');

  const db = await sambung(namaEnv);
  console.log(`  Membaca ${berkas} ...`);
  const h = await periksaBerkas(db, path.resolve(berkas), lembarGanti, lembarTambah);
  const folder = path.join(root, '.runtime', 'ganti-klaim', `${namaEnv}-${stempel}`);
  cetakPeriksa(h);
  await tulisLaporan(folder, h, ambil('--temuan-xlsx'));
  console.log(`\n  Laporan: ${folder}`);
  if (h.hilang.length) throw new Error(`${h.hilang.length} dokumen depot ${h.depotGanti.join('/')} akan hilang; perbaiki berkas dulu`);
  if (!jalankan && !uji) { console.log('\n  \x1b[32mBERKAS SIAP DIMUAT\x1b[0m (baris ditahan tidak ikut dimuat).\n'); return; }
  if (uji) return ujiTransaksi(db, h);

  console.log('\n  1/4 Mencadangkan seluruh isi lama ...');
  const cadangan = path.join(folder, 'cadangan');
  await cadangkan(db, cadangan);
  const rencana = { env: namaEnv, berkas: path.resolve(berkas), depotGanti: h.depotGanti, depotGantiId: h.depotGantiId, cadangan,
    noDocDimuat: h.dimuat.map((x) => x.k.noDoc), pemetaan: h.pemetaan, harap: h.harap };
  await writeFile(path.join(folder, 'rencana.json'), JSON.stringify(rencana, null, 2));

  console.log('  2/4 Mengirim ke staging ...');
  const sesi = randomUUID();
  await siapkanStaging(db);
  const baris = h.dimuat.map((x) => { const { lembar, baris: _b, ...k } = x.k; return k; });
  try {
    await kirimStaging(db, sesi, 'klaim', baris);
    await kirimStaging(db, sesi, 'pemetaan', h.pemetaan);
    await kirimStaging(db, sesi, 'penghitung', penghitungBatch(baris));
    console.log('\n  3/4 Menghapus dan memuat dalam satu transaksi ...');
    await db.sql(sqlGanti(sesi, h));
  } catch (e) {
    throw new Error(`DIBATALKAN - data lama utuh. ${e.message}`);
  } finally {
    await db.sql(`delete from rc_muat_ulang.baris where sesi=${lit(sesi)}::uuid;`).catch(() => {});
  }
  console.log('  4/4 Menyegarkan dashboard publik ...');
  await db.sql('select rc_private.segarkan_dashboard_publik();').catch((e) => console.log('   (gagal menyegarkan: ' + e.message + ')'));
  const sesudah = await ringkasDb(db, h.depotGanti);
  await writeFile(path.join(folder, 'sesudah.json'), JSON.stringify(sesudah, null, 2));
  console.log(`\n  \x1b[32mSELESAI.\x1b[0m ${h.harap.hapus} klaim lama dihapus, ${h.harap.klaim} dimuat. Depot ${h.depotGanti.join('/')} sekarang:`);
  for (const r of sesudah) console.log(`   ${r.depot} ${r.status.padEnd(10)} ${String(r.n).padStart(5)} dok ${rupiah(r.cb)}`);
  console.log(`\n  Pulihkan bila perlu: node scripts/ganti-klaim-depot.mjs --env ${namaEnv} --pulihkan "${folder}" --konfirmasi ${namaEnv === 'prod' ? 'PULIHKAN-KLAIM-PROD-<yyyymmdd>' : 'PULIHKAN-KLAIM-' + namaEnv.toUpperCase()}\n`);
}

main().catch((e) => { console.error(`\n  \x1b[31mBerhenti:\x1b[0m ${e.message}\n`); process.exitCode = 1; });
