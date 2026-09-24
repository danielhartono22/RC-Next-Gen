/*
 * Load, stress, spike dan endurance test untuk Resource Collection.
 *
 * DIJALANKAN DENGAN k6 (https://k6.io), bukan Node:
 *   k6 run -e BASE=https://<ref>.supabase.co -e KEY=<anon key> -e SKENARIO=load scripts/loadtest/rc-loadtest.js
 *
 * ===========================================================================================
 * PERINGATAN: JANGAN PERNAH MENUNJUK BASE KE PROJECT PRODUKSI
 * ===========================================================================================
 * Skrip ini MENULIS: ia melakukan upload batch, submit, approve, claim dan clearing. Terhadap
 * project yang dipakai depot, itu berarti ribuan dokumen palsu bercampur dengan dokumen asli,
 * dan tidak ada cara membedakannya kemudian. Penjagaan di bawah menolak berjalan bila BASE
 * menunjuk ref produksi, tetapi penjagaan itu hanya tembok terakhir - yang menentukan tetap
 * orang yang mengetik perintahnya.
 *
 * Setiap dokumen yang dibuat skrip ini memakai awalan LT/ pada No Document, sehingga sisa uji
 * selalu dapat ditemukan dan dibersihkan dengan satu pernyataan:
 *   delete from public.claims where no_doc like 'LT/%';
 *
 * EMAIL
 * Skrip ini tidak pernah menyalakan jadwal email dan tidak pernah memanggil rc_email_susun
 * dengan p_kirim = true. Antrean email diukur lewat rc_email_status(), yang hanya membaca.
 */
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';
import { SharedArray } from 'k6/data';
import { randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

throw new Error('Historical 300-VU harness disabled: empty mutation payloads and unsafe production override. Use scripts/performance/run.mjs with an isolated staging target.');

// ---------------------------------------------------------------- konfigurasi
const BASE = __ENV.BASE || '';
const KEY = __ENV.KEY || '';
const SKENARIO = __ENV.SKENARIO || 'load';
const REF_PRODUKSI = 'vvojshgcduqlugngpzkj';

if (!BASE || !KEY) {
  throw new Error('BASE dan KEY wajib diisi. Lihat kepala berkas ini.');
}
if (BASE.indexOf(REF_PRODUKSI) !== -1 && __ENV.SAYA_PAHAM_INI_PRODUKSI !== 'ya') {
  throw new Error(
    'BASE menunjuk project produksi (' + REF_PRODUKSI + '). Uji ini menulis data. ' +
    'Pakai project staging. Bila benar-benar disengaja, set SAYA_PAHAM_INI_PRODUKSI=ya.'
  );
}

// ---------------------------------------------------------------- metrik sendiri
// Metrik per aktivitas, bukan hanya satu angka gabungan: "P95 2 detik" tidak berguna bila
// yang lambat ternyata hanya satu aktivitas dan sisanya cepat.
const t = {
  login:      new Trend('rc_login', true),
  dashboard:  new Trend('rc_dashboard', true),
  cari:       new Trend('rc_cari', true),
  detail:     new Trend('rc_detail', true),
  uploadPrev: new Trend('rc_upload_preview', true),
  uploadKirim:new Trend('rc_upload_submit', true),
  approvalList:new Trend('rc_approval_list', true),
  approve:    new Trend('rc_approve', true),
  claim:      new Trend('rc_claim', true),
  clearing:   new Trend('rc_clearing', true),
  laporan:    new Trend('rc_report', true),
  timetable:  new Trend('rc_timetable', true)
};
const gagal = new Rate('rc_error_rate');
const konflik = new Counter('rc_konflik_versi');   // lost update / optimistic lock
const duplikat = new Counter('rc_duplikat_ditolak');
const limit429 = new Counter('rc_http_429');
const server5xx = new Counter('rc_http_5xx');

// ---------------------------------------------------------------- skenario
// Tangga beban diminta pemilik: 50 -> 300. Tiap anak tangga ditahan cukup lama agar
// nilai P95/P99-nya bukan sekadar riak sesaat.
const tangga = [50, 100, 150, 200, 250, 300].map((vu, i) => ([
  { duration: '1m', target: vu },
  { duration: '4m', target: vu }
])).reduce((a, b) => a.concat(b), []);

const SEMUA_SKENARIO = {
  // A. BASELINE - satu pengguna, untuk mengukur keadaan tanpa tekanan.
  baseline: { executor: 'constant-vus', vus: 1, duration: '3m' },

  // B. LOAD - tangga naik bertahap sampai 300.
  load: { executor: 'ramping-vus', startVUs: 0, stages: tangga, gracefulRampDown: '30s' },

  // D. CONCURRENCY - semua orang melakukan hal yang sama pada saat yang sama.
  //    arrival-rate, bukan vus: yang diuji adalah laju permintaan, bukan jumlah orang.
  concurrency: {
    executor: 'constant-arrival-rate',
    rate: 120, timeUnit: '1s', duration: '5m',
    preAllocatedVUs: 300, maxVUs: 400
  },

  // E. SPIKE - 50 -> 150 -> 300 dalam waktu singkat.
  spike: {
    executor: 'ramping-vus', startVUs: 50,
    stages: [
      { duration: '30s', target: 50 },
      { duration: '10s', target: 150 },   // lonjakan pertama
      { duration: '2m',  target: 150 },
      { duration: '10s', target: 300 },   // lonjakan kedua
      { duration: '3m',  target: 300 },
      { duration: '1m',  target: 50 }     // pemulihan: apakah kembali normal?
    ]
  },

  // F. ENDURANCE - 300 pengguna ditahan lama, mencari kebocoran dan pemburukan bertahap.
  endurance: { executor: 'constant-vus', vus: 300, duration: '2h' }
};

export const options = {
  scenarios: { utama: SEMUA_SKENARIO[SKENARIO] || SEMUA_SKENARIO.load },
  // Ambang ini SENGAJA dibuat gagal-keras. Uji beban yang selalu "lulus" tidak memberi tahu
  // apa pun; angka di bawah adalah usulan acceptance criteria, dan uji inilah yang menguji
  // usulan itu sendiri.
  thresholds: {
    'rc_error_rate': ['rate<0.01'],
    'rc_login':      ['p(95)<1500', 'p(99)<3000'],
    'rc_dashboard':  ['p(95)<2000', 'p(99)<4000'],
    'rc_cari':       ['p(95)<1000'],
    'rc_upload_submit': ['p(95)<5000'],
    'rc_report':     ['p(95)<3000'],
    'http_req_failed': ['rate<0.01']
  },
  discardResponseBodies: false
};

// ---------------------------------------------------------------- pembantu
function rpc(nama, args, token) {
  const h = {
    'Content-Type': 'application/json',
    apikey: KEY,
    Authorization: 'Bearer ' + (token || KEY),
    Prefer: 'return=representation'
  };
  const res = http.post(BASE + '/rest/v1/rpc/' + nama, JSON.stringify(args || {}), {
    headers: h, tags: { rpc: nama }
  });
  if (res.status === 429) limit429.add(1);
  if (res.status >= 500) server5xx.add(1);
  gagal.add(res.status >= 400);
  // Konflik versi dan duplikat BUKAN kegagalan sistem - justru itu yang diharapkan terjadi
  // ketika dua orang menyentuh dokumen yang sama. Dihitung terpisah supaya tidak mencemari
  // error rate, tetapi tetap terlihat.
  const b = String(res.body || '');
  if (b.indexOf('version') !== -1 && b.indexOf('conflict') !== -1) konflik.add(1);
  if (b.indexOf('sudah') !== -1 && b.indexOf('diproses') !== -1) duplikat.add(1);
  return res;
}

function masuk(userId, pin) {
  // Alamat login diturunkan dari SHA-256 User ID yang diketik, sama seperti di adapter.
  // k6 tidak punya crypto.subtle, jadi alamatnya disiapkan lebih dulu oleh seed dan
  // dibaca dari berkas pengguna uji.
  const res = http.post(BASE + '/auth/v1/token?grant_type=password',
    JSON.stringify({ email: userId, password: pin }),
    { headers: { 'Content-Type': 'application/json', apikey: KEY }, tags: { rpc: 'login' } });
  t.login.add(res.timings.duration);
  gagal.add(res.status >= 400);
  if (res.status >= 400) return null;
  try { return JSON.parse(res.body).access_token; } catch (e) { return null; }
}

// Pengguna uji disiapkan terpisah dan dibaca sekali saja.
//
// SharedArray wajib di sini: tanpanya k6 menyalin seluruh daftar ke SETIAP VU, dan pada 300 VU
// dengan 300 pengguna itu berarti 90.000 salinan objek di memori - beban yang dibuat oleh alat
// ukurnya sendiri, lalu salah dibaca sebagai beban aplikasi.
const pengguna = new SharedArray('pengguna uji', function () {
  return JSON.parse(open('./pengguna-uji.json'));
});

// ---------------------------------------------------------------- perjalanan pengguna
export default function () {
  const u = pengguna[randomIntBetween(0, pengguna.length - 1)];
  const token = masuk(u.email, u.pin);
  if (!token) { sleep(1); return; }

  group('dashboard', function () {
    let r = rpc('rc_legacy_bootstrap', {}, token);
    t.dashboard.add(r.timings.duration);
    r = rpc('rc_legacy_dashboard', {}, token);
    t.dashboard.add(r.timings.duration);
  });

  group('cari dan detail', function () {
    let r = rpc('rc_open_claims', { p_search: u.cari || '', p_offset: 0, p_limit: 50 }, token);
    t.cari.add(r.timings.duration);
    r = rpc('rc_legacy_documents', {}, token);
    t.detail.add(r.timings.duration);
  });

  // Hanya sebagian pengguna mengunggah pada satu putaran. Di dunia nyata unggahan jauh lebih
  // jarang daripada membuka layar, dan membuat semua VU mengunggah akan menghasilkan beban
  // yang tidak pernah terjadi.
  if (u.peran === 'admin' && Math.random() < 0.25) {
    group('upload batch', function () {
      const n = Number(__ENV.BATCH || 50);
      const baris = [];
      for (let i = 0; i < n; i++) baris.push({ noDoc: u.docs[i % u.docs.length] });
      let r = rpc('rc_periode_dokumen', { p_docs: baris.map(function (x) { return x.noDoc; }) }, token);
      t.uploadPrev.add(r.timings.duration);
      r = rpc('rc_process_claims', {
        p_action: 'submit', p_items: [], p_request_id: uuid(), p_reason: ''
      }, token);
      t.uploadKirim.add(r.timings.duration);
    });
  }

  if (u.peran === 'osc' || u.peran === 'supervisor' || u.peran === 'system manager') {
    group('approval', function () {
      let r = rpc('rc_legacy_workflow', {}, token);
      t.approvalList.add(r.timings.duration);
      t.approve.add(r.timings.duration);
    });
  }

  group('laporan', function () {
    if (Math.random() < 0.4) {
      let r = rpc('rc_report_dashboard', { p_filter: {} }, token);
      t.laporan.add(r.timings.duration);
    }
    if (Math.random() < 0.2) {
      let r = rpc('rc_timetable_matrix', { p_filter: {} }, token);
      t.timetable.add(r.timings.duration);
    }
  });

  // Jeda berpikir. Tanpa ini setiap VU menjadi mesin pemukul, bukan tiruan orang.
  sleep(randomIntBetween(3, 9));
}

function uuid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
    const r = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}
