/*
 * MEMBUAT AKUN DI LINGKUNGAN DEV, TANPA EMAIL
 *
 * Pendaftaran lewat layar memakai email konfirmasi Supabase, dan paket gratis membatasi jumlah
 * email per jam - sekali habis, pendaftaran ditolak dengan pesan "email limit" sampai jatahnya
 * pulih. Akun di sini dibuat lewat Admin API dengan email langsung ditandai terkonfirmasi,
 * sehingga batas itu tidak pernah tersentuh.
 *
 * Alamat login diturunkan persis seperti yang dilakukan aplikasi (scripts/rc-legacy-adapter.js,
 * loginEmail): SHA-256 dari User ID, heksadesimal, ditambah @rc-login.invalid. Kalau
 * perhitungannya berbeda sedikit saja, akunnya terbentuk tetapi tidak pernah bisa dipakai masuk.
 *
 * Profil dibuat oleh trigger rc_private.handle_new_user() dari metadata, bukan oleh skrip ini.
 * Pendaftar PERTAMA pada database kosong otomatis menjadi System Manager dengan seluruh izin;
 * akun berikutnya berstatus pending dan perlu disetujui, kecuali --aktifkan diberikan.
 *
 * Menolak jalan terhadap prod.
 *
 * Pemakaian:
 *   node scripts/buat-akun-dev.mjs SMDEV "System Manager Dev" 260926
 *   node scripts/buat-akun-dev.mjs OSCDEV "OSC Dev" 260926 osc --aktifkan
 */
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const argumen = process.argv.slice(2);
const iDepot = argumen.indexOf('--depot');
const depotDiminta = iDepot >= 0 ? argumen[iDepot + 1] : '1A';
const [kode, nama, pin, peran = 'supervisor'] = argumen
  .filter((a, i) => !a.startsWith('--') && !(iDepot >= 0 && i === iDepot + 1));
const aktifkan = argumen.includes('--aktifkan');

if (!kode || !nama || !pin) {
  console.error('\n  Pemakaian: node scripts/buat-akun-dev.mjs <USERID> "<Nama>" <PIN> [peran] [--aktifkan]\n');
  process.exit(1);
}
// Supabase menolak kata sandi di bawah 6 karakter. Ditolak di sini dengan pesan yang jelas,
// bukan dibiarkan menjadi galat Admin API yang membingungkan.
if (String(pin).length < 6) {
  console.error('\n  PIN minimal 6 karakter (batas Supabase).\n');
  process.exit(1);
}

const daftar = JSON.parse(await readFile(path.join(root, 'config', 'environments.json'), 'utf8'));
const env = daftar.supabase_projects?.dev;
const prodRef = daftar.supabase_projects?.prod?.project_ref;
if (!env?.project_ref) { console.error('\n  Lingkungan dev belum punya project_ref.\n'); process.exit(1); }
if (env.project_ref === prodRef) { console.error('\n  DITOLAK: ref dev sama dengan prod.\n'); process.exit(1); }

const REF = env.project_ref;
let token = null;
for (const l of (await readFile(path.join(root, '.env'), 'utf8')).split(/\r?\n/)) {
  const m = l.match(new RegExp('^\\s*' + (env.token_env || 'SUPABASE_ACCESS_TOKEN_DEV') + '\\s*=\\s*(.+?)\\s*$'));
  if (m) token = m[1];
}
if (!token) { console.error('\n  Token dev tidak ada di .env.\n'); process.exit(1); }

// Kunci service_role diambil sekali dan tidak disimpan ke berkas mana pun.
const kunci = await (await fetch(`https://api.supabase.com/v1/projects/${REF}/api-keys`,
  { headers: { Authorization: 'Bearer ' + token } })).json();
const service = kunci.find(k => k.name === 'service_role');
if (!service) { console.error('\n  Kunci service_role tidak ditemukan.\n'); process.exit(1); }

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${REF}/database/query`, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`HTTP ${r.status}: ${t.slice(0, 250)}`);
  try { return JSON.parse(t); } catch { return []; }
}

const email = createHash('sha256').update(String(kode).trim().toUpperCase()).digest('hex')
  + '@rc-login.invalid';

const res = await fetch(`https://${REF}.supabase.co/auth/v1/admin/users`, {
  method: 'POST',
  headers: { apikey: service.api_key, Authorization: 'Bearer ' + service.api_key,
             'Content-Type': 'application/json' },
  body: JSON.stringify({
    email, password: String(pin), email_confirm: true,
    user_metadata: {
      user_code: String(kode).toUpperCase(), full_name: nama,
      business_email: String(kode).toLowerCase() + '@dev.invalid',
      requested_role: peran,
      // Pendaftar selain yang pertama wajib memilih depot (rc_private.handle_new_user).
      // Bawaannya 1A; ganti dengan --depot <kode>.
      requested_depot: depotDiminta,
    },
  }),
});
const body = await res.json();
if (!res.ok) {
  console.error('\n  GAGAL membuat akun: ' + JSON.stringify(body).slice(0, 220) + '\n');
  process.exit(1);
}

if (aktifkan) {
  await sql(`update public.profiles set status='active', role='${peran.replace(/'/g, "''")}'
              where id='${body.id}';`);
}

const [p] = await sql(`select user_code, role, status from public.profiles where id='${body.id}';`);
console.log(`\n  Akun dev dibuat`);
console.log(`  User ID : ${p?.user_code}`);
console.log(`  PIN     : ${pin}`);
console.log(`  Peran   : ${p?.role}`);
console.log(`  Status  : ${p?.status}\n`);
