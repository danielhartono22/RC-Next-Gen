/*
 * MEMUAT DATA REKAYASA KE LINGKUNGAN DEV
 *
 * Pasangan Node dari scripts/performance/import-dummy.psql, untuk mesin yang tidak punya psql.
 * Jalurnya lewat Management API yang sama dengan apply-sql.mjs, jadi hanya perlu
 * SUPABASE_ACCESS_TOKEN - tidak perlu kata sandi database.
 *
 * SELURUH PENJAGA DARI BERKAS PSQL DIPERTAHANKAN, dan satu ditambahkan. Menuang 100 ribu baris
 * rekayasa ke database yang salah tidak bisa dibatalkan, dan data pelanggan sungguhan ada di
 * project sebelah. Karena itu berkas ini menolak jalan kecuali:
 *
 *   1. --env yang dipilih bukan "prod"
 *   2. project_ref tujuan bukan ref produksi yang tercatat di config/environments.json
 *   3. tabel inti di tujuan benar-benar KOSONG
 *   4. tidak ada cron aktif, tidak ada rahasia di vault
 *   5. email dalam keadaan nonaktif dan antreannya kosong
 *
 * Penjaga nomor 3 yang paling menentukan: ia membedakan project dev yang baru dibuat dari
 * salinan produksi, dan salinan produksi adalah satu-satunya cara data sungguhan bisa ikut
 * tertimpa di sini.
 *
 * Jalankan:
 *   node scripts/impor-dev.mjs --env dev --data .runtime/dev-dataset-100k
 *   node scripts/impor-dev.mjs --data .runtime/dev-dataset-100k --dry-run   (tanpa database)
 */
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function arg(nama, bawaan = null) {
  const i = process.argv.indexOf(nama);
  return i >= 0 ? process.argv[i + 1] : bawaan;
}
const kering = process.argv.includes('--dry-run');
const namaEnv = arg('--env', kering ? 'dev' : null);
const dirData = arg('--data');

if (!dirData) {
  console.error('\n  Pemakaian: node scripts/impor-dev.mjs --env dev --data <folder dataset>\n');
  process.exit(1);
}

const daftarEnv = JSON.parse(
  await readFile(path.join(root, 'config', 'environments.json'), 'utf8'));
const refProd = daftarEnv.supabase_projects?.prod?.project_ref || null;

// ---- Penjaga 1 dan 2: tujuan tidak boleh produksi ----------------------------------------
if (namaEnv === 'prod') {
  console.error('\n  DITOLAK: berkas ini tidak boleh dijalankan terhadap prod.\n');
  process.exit(1);
}
const env = daftarEnv.supabase_projects?.[namaEnv];
if (!kering) {
  if (!env || !env.project_ref) {
    console.error(`\n  Lingkungan "${namaEnv}" belum punya project Supabase.`);
    console.error('  Isi project_ref pada config/environments.json lebih dulu.\n');
    process.exit(1);
  }
  if (refProd && env.project_ref === refProd) {
    console.error('\n  DITOLAK: project_ref tujuan sama dengan produksi.\n');
    process.exit(1);
  }
}

// ------------------------------------------------------------------------------------------
// Membaca CSV
// ------------------------------------------------------------------------------------------
// Pengurai kecil yang menghormati tanda kutip dan koma di dalamnya. Nama campaign pada dataset
// memuat garis miring dan koma, jadi memecah dengan split(',') akan merusak barisnya diam-diam.
function uraiCsv(teks) {
  const baris = [];
  let sel = '', row = [], kutip = false;
  for (let i = 0; i < teks.length; i++) {
    const c = teks[i];
    if (kutip) {
      if (c === '"') {
        if (teks[i + 1] === '"') { sel += '"'; i++; } else kutip = false;
      } else sel += c;
    } else if (c === '"') kutip = true;
    else if (c === ',') { row.push(sel); sel = ''; }
    else if (c === '\n') { row.push(sel); baris.push(row); row = []; sel = ''; }
    else if (c !== '\r') sel += c;
  }
  if (sel !== '' || row.length) { row.push(sel); baris.push(row); }
  return baris;
}

async function muatCsv(nama) {
  const teks = await readFile(path.join(root, dirData, nama), 'utf8');
  const baris = uraiCsv(teks);
  const kepala = baris.shift();
  return { kepala, baris: baris.filter(r => r.length === kepala.length) };
}

// Urutannya mengikuti foreign key: induk lebih dulu, anak menyusul.
const URUTAN = [
  ['depots.csv', 'public.depots'],
  ['campaigns.csv', 'public.campaigns'],
  ['customers.csv', 'public.customers'],
  ['customer_depots.csv', 'public.customer_depots'],
  ['claims.csv', 'public.claims'],
];

// --pakai-depot-tujuan: jangan muat depot karangan; petakan seluruh depot_id pada dataset ke
// depot yang SUDAH ADA di tujuan. Dipakai ketika dev memakai daftar depot sungguhan, sehingga
// penyaring depot, penyaring region dan yurisdiksi OSC diuji di atas struktur yang sebenarnya -
// bukan di atas seratus depot bernama "Dummy Depot" yang tidak dikenal siapa pun.
const pakaiDepotTujuan = process.argv.includes('--pakai-depot-tujuan');

// ------------------------------------------------------------------------------------------
// Jalur ke database
// ------------------------------------------------------------------------------------------
// Kredensial dev terpisah dari kredensial prod, dan namanya datang dari environments.json.
// Karena kedua lingkungan berada di akun Supabase yang berbeda, token dev secara harfiah tidak
// mampu menyentuh prod - lapisan pertahanan yang tidak bergantung pada kode ini sama sekali.
async function bacaToken(nama) {
  if (process.env[nama]) return process.env[nama].trim();
  try {
    const isi = await readFile(path.join(root, '.env'), 'utf8');
    for (const line of isi.split(/\r?\n/)) {
      const m = line.match(new RegExp('^\\s*' + nama + '\\s*=\\s*(.+?)\\s*$'));
      if (m) return m[1].replace(/^["']|["']$/g, '');
    }
  } catch { /* .env belum ada */ }
  return null;
}

let jalankan;
if (kering) {
  jalankan = async () => [{ dry: true }];
} else {
  const namaVar = env.token_env || 'SUPABASE_ACCESS_TOKEN_DEV';
  const token = await bacaToken(namaVar);
  if (!token) {
    console.error(`\n  ${namaVar} belum tersedia di .env (diperlukan lingkungan "${namaEnv}").\n`);
    process.exit(1);
  }
  const API = `https://api.supabase.com/v1/projects/${env.project_ref}/database/query`;
  jalankan = async (sql) => {
    const res = await fetch(API, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: sql }),
    });
    const teks = await res.text();
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${teks.slice(0, 300)}`);
    try { return JSON.parse(teks); } catch { return []; }
  };
}

// ------------------------------------------------------------------------------------------
// Penjaga 3-5: keadaan tujuan
// ------------------------------------------------------------------------------------------
const PERIKSA = `
select
  (select count(*) from public.claims)                                    as claims,
  (select count(*) from public.customers)                                 as customers,
  (select count(*) from public.depots)                                    as depots,
  (select count(*) from public.campaigns)                                 as campaigns,
  (select count(*) from public.activity_logs)                             as logs,
  (select count(*) from public.profiles)                                  as profiles,
  coalesce((select count(*) from cron.job where active),0)                as cron_aktif,
  coalesce((select count(*) from vault.decrypted_secrets),0)              as rahasia,
  (select count(*) from public.email_settings where aktif)                as email_aktif,
  (select count(*) from public.email_outbox)                              as outbox;
`;

function q(v) {
  if (v === '' || v === null || v === undefined) return 'null';
  return "'" + String(v).replace(/'/g, "''") + "'";
}

// ------------------------------------------------------------------------------------------
async function main() {
  console.log('\n  MEMUAT DATA REKAYASA');
  console.log('  lingkungan : ' + namaEnv + (kering ? '  (dry-run, tanpa database)' : ''));
  console.log('  project    : ' + (kering ? '-' : env.project_ref));
  console.log('  dataset    : ' + dirData);

  const berkas = await readdir(path.join(root, dirData));
  for (const [nama] of URUTAN) {
    if (!berkas.includes(nama)) {
      console.error(`\n  Berkas ${nama} tidak ada di ${dirData}.\n`);
      process.exit(1);
    }
  }

  if (!kering) {
    // Yang membedakan project dev yang baru dipasang dari SALINAN PRODUKSI adalah data
    // transaksinya. Depot ditanam migrasi, dan satu-dua profil beserta log lahir saat akun
    // pertama dibuat - ketiganya wajar ada di dev yang masih bersih, dan menolak karenanya
    // hanya membuat penjaga ini dimatikan orang, yang jauh lebih berbahaya.
    //
    // Klaim, pelanggan dan campaign tetap ditolak keras: produksi pasti memilikinya, dan
    // menuang data rekayasa ke atasnya tidak bisa dibatalkan.
    const [k] = await jalankan(PERIKSA);
    const isi = ['claims', 'customers', 'campaigns'].filter(t => Number(k[t]) > 0);
    if (isi.length) {
      console.error('\n  DITOLAK: tujuan sudah memuat data transaksi. Terisi: '
        + isi.map(t => `${t}=${k[t]}`).join(', '));
      console.error('  Berkas ini hanya untuk project dev yang belum berisi transaksi,');
      console.error('  bukan untuk salinan produksi.\n');
      process.exit(1);
    }
    const bawaan = ['depots', 'profiles', 'logs'].filter(t => Number(k[t]) > 0);
    if (bawaan.length) {
      console.log('  bawaan     : ' + bawaan.map(t => `${t}=${k[t]}`).join(', ')
        + '  (dari migrasi dan akun pertama, bukan salinan produksi)');
    }
    if (Number(k.cron_aktif) > 0) {
      console.error('\n  DITOLAK: masih ada ' + k.cron_aktif + ' cron aktif. Matikan dulu.\n');
      process.exit(1);
    }
    if (Number(k.rahasia) > 0) {
      console.error('\n  DITOLAK: vault masih memuat rahasia layanan luar. Kosongkan dulu.\n');
      process.exit(1);
    }
    if (Number(k.email_aktif) > 0 || Number(k.outbox) > 0) {
      console.error('\n  DITOLAK: email masih aktif atau antreannya belum kosong.\n');
      process.exit(1);
    }
    console.log('  penjaga    : tujuan kosong, cron mati, vault bersih, email mati');
  }

  // ---- Pemetaan depot -------------------------------------------------------------------
  // Dibangun dari depot yang benar-benar ada di tujuan, diurutkan menurut kode supaya hasilnya
  // sama setiap kali dijalankan. Depot karangan ke-N jatuh ke depot tujuan ke-(N mod jumlah),
  // sehingga kemiringan sebaran yang dirancang generator tetap terbawa: depot yang ramai di
  // dataset tetap menjadi depot yang ramai di sini.
  let petaDepot = null;
  if (pakaiDepotTujuan && !kering) {
    // Kolom archived_at ditambahkan migrasi yang belakangan; pada dev yang skemanya belum
    // lengkap ia bisa belum ada. Penyaringnya dipasang hanya bila kolomnya memang ada, supaya
    // pemuat ini tidak menuntut skema yang lebih maju daripada yang sedang diisinya.
    const [adaKolom] = await jalankan(`
      select count(*) as n from information_schema.columns
       where table_schema='public' and table_name='depots' and column_name='archived_at';`);
    const saring = Number(adaKolom.n) > 0 ? 'where archived_at is null' : '';
    const tujuan = await jalankan(
      `select id from public.depots ${saring} order by depot_code;`);
    if (!tujuan.length) {
      console.error('\n  DITOLAK: --pakai-depot-tujuan diminta, tetapi tujuan tidak punya depot.\n');
      process.exit(1);
    }
    const { baris: asal } = await muatCsv('depots.csv');
    petaDepot = new Map(asal.map((r, i) => [r[0], tujuan[i % tujuan.length].id]));
    console.log(`  depot      : ${asal.length} depot dataset dipetakan ke ${tujuan.length} depot tujuan`);
  }

  let totalBaris = 0;
  const UKURAN = 2000;   // baris per permintaan; cukup besar untuk cepat, cukup kecil untuk aman

  for (const [nama, tabel] of URUTAN) {
    if (pakaiDepotTujuan && nama === 'depots.csv') {
      console.log(`  ${tabel.padEnd(24)} ${'dilewati'.padStart(7)}  (memakai depot tujuan)`);
      continue;
    }
    let { kepala, baris } = await muatCsv(nama);

    // Kolom terhitung (generated) tidak boleh diisi - PostgreSQL menolaknya. Daftarnya dibaca
    // dari tujuan, bukan ditulis mati di sini, karena kolom mana yang terhitung berbeda antar
    // versi skema dan akan berubah lagi nanti.
    if (!kering) {
      const terhitung = (await jalankan(`
        select column_name from information_schema.columns
         where table_schema='public' and table_name='${tabel.split('.')[1]}'
           and is_generated='ALWAYS';`)).map(r => r.column_name);
      if (terhitung.length) {
        const buang = kepala
          .map((k, i) => (terhitung.includes(k) ? i : -1))
          .filter(i => i >= 0)
          .sort((a, b) => b - a);
        buang.forEach(i => { kepala.splice(i, 1); baris.forEach(r => r.splice(i, 1)); });
        console.log(`  ${''.padEnd(24)} lewati kolom terhitung: ${terhitung.join(', ')}`);
      }
    }

    // Setiap kolom depot_id ditukar ke id tujuan. Baris yang depotnya tidak terpetakan
    // DIBUANG, bukan dibiarkan menunjuk depot yang tidak ada - relasi putus jauh lebih sulit
    // ditemukan nanti daripada baris yang sejak awal tidak ikut.
    const iDepot = kepala.indexOf('depot_id');
    let dibuang = 0;
    if (petaDepot && iDepot >= 0) {
      for (let i = baris.length - 1; i >= 0; i--) {
        const baru = petaDepot.get(baris[i][iDepot]);
        if (baru) baris[i][iDepot] = baru;
        else { baris.splice(i, 1); dibuang++; }
      }
    }

    process.stdout.write(`  ${tabel.padEnd(24)} ${String(baris.length).padStart(7)} baris `);
    if (dibuang) process.stdout.write(`(${dibuang} dibuang) `);
    for (let i = 0; i < baris.length; i += UKURAN) {
      const potong = baris.slice(i, i + UKURAN);
      const nilai = potong.map(r => '(' + r.map(q).join(',') + ')').join(',');
      const sql = `insert into ${tabel}(${kepala.join(',')}) values ${nilai};`;
      if (!kering) await jalankan(sql);
      process.stdout.write('.');
    }
    totalBaris += baris.length;
    console.log(' selesai');
  }

  // ---- Turunan: sama persis dengan yang dikerjakan import-dummy.psql ---------------------
  const TURUNAN = [
    ["identitas rekayasa",
     `update public.customers set npwp='DUMMY-NPWP-'||customer_code where npwp is null;`],
    ["gross up",
     `update public.claims set gross_up=rc_private.gross_claimed(cb_net,tax_subject,'Customer');`],
    ["claim_sensitive",
     `insert into rc_private.claim_sensitive(claim_id,npwp,bank,account_number,account_name,top_text)
      select c.id,u.npwp,u.bank,u.account_number,u.account_name,u.top_text
        from public.claims c join public.customers u on u.id=c.customer_id
      on conflict do nothing;`],
    ["riwayat status",
     `insert into public.claim_status_history(claim_id,from_status,to_status,action,created_at,batch)
      select c.id,h.from_status,h.to_status,h.action,c.created_at+h.step*interval '1 day',
             case h.step when 1 then c.batch_upload when 2 then c.batch_release
                         when 3 then c.batch_claim when 4 then c.batch_clearing end
        from public.claims c cross join (values
          (1,'not_yet','submitted','submit'),(2,'submitted','released','release'),
          (3,'released','claimed','claim'),(4,'claimed','done','clearing')) h(step,from_status,to_status,action)
       where h.step <= case c.status when 'submitted' then 1 when 'released' then 2
                                     when 'claimed' then 3 when 'done' then 4
                                     when 'on_hold' then 1 else 0 end;`],
  ];
  for (const [label, sql] of TURUNAN) {
    process.stdout.write(`  ${label.padEnd(24)} `);
    if (!kering) await jalankan(sql);
    console.log('selesai');
  }

  if (!kering) {
    const [h] = await jalankan(`
      select (select count(*) from public.claims)                         as claims,
             (select count(*) from public.customers)                      as customers,
             (select count(*) from rc_private.claim_sensitive)            as sensitive,
             (select count(*) from public.claim_status_history)           as riwayat,
             (select count(*) from public.claims c
               where not exists(select 1 from public.depots d where d.id=c.depot_id)
                  or not exists(select 1 from public.campaigns k where k.id=c.campaign_id)
                  or not exists(select 1 from public.customers u where u.id=c.customer_id))
                                                                          as relasi_putus;`);
    console.log('\n  HASIL');
    console.log('  claims           : ' + h.claims);
    console.log('  customers        : ' + h.customers);
    console.log('  claim_sensitive  : ' + h.sensitive);
    console.log('  riwayat status   : ' + h.riwayat);
    console.log('  relasi putus     : ' + h.relasi_putus);
    if (Number(h.relasi_putus) > 0) {
      console.error('\n  GAGAL: ada relasi yang putus setelah impor.\n');
      process.exit(1);
    }
  }

  console.log(`\n  Selesai: ${totalBaris.toLocaleString('id-ID')} baris inti dimuat.`
    + (kering ? '  (dry-run - tidak ada yang ditulis)' : '') + '\n');
}

main().catch(e => { console.error('\n  GAGAL: ' + e.message + '\n'); process.exit(1); });
