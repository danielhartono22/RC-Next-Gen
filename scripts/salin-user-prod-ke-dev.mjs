/*
 * MENDUPLIKASI USER PROD KE DEV
 *
 * Diminta pemilik, 30 September 2026: "untuk user duplikasi dari user prod dan bagikan
 * yuridiksi secara random tapi seimbang untuk osc dan spv".
 *
 * SUMBER - salah satu:
 *   --berkas <path>   hasil supabase/queries/ekspor-user-prod.sql yang dijalankan di SQL Editor
 *                     prod (hanya membaca). Disimpan di .runtime/ supaya tidak ikut git.
 *   --langsung        membaca prod sendiri lewat Management API dengan token prod di .env
 *                     (variabel token_env milik prod pada config/environments.json). Yang
 *                     dijalankan terhadap prod HANYA berkas ekspor itu - SELECT saja.
 *
 * YANG DITULIS - SELALU ke DEV, tidak pernah ke prod:
 *   * depot: nama, singkatan dan region mengikuti prod; depot yang belum ada ditambahkan
 *   * akun: dibuat lewat Admin API dengan alamat login internal yang sama seperti prod dan
 *     hash PIN prod, sehingga setiap orang masuk ke dev dengan User ID dan PIN prod-nya.
 *     Tanpa hash (atau dengan --pin-uji-semua) dipakai satu PIN uji.
 *     Email bisnis diganti <kode>@dev.invalid - tidak ada email yang bisa sampai ke orang.
 *   * peran, status, departemen, depot rumah, wajib-ganti-PIN, izin modul dan tab: ikut prod
 *   * yurisdiksi: OSC dan Supervisor DIBAGI ULANG acak tetapi seimbang
 *     (supabase/queries/bagi-yurisdiksi-dev.sql); peran lain ikut prod
 *   * akun uji OSCDEV dan SPVDEV dinonaktifkan supaya tidak ikut pembagian. DANIEL dan
 *     SMDEV (System Manager) tidak disentuh.
 *
 * Akun yang User ID-nya sudah ada di dev tidak dibuat ulang dan PIN-nya tidak diubah;
 * profil dan yurisdiksinya tetap diperbarui. Aman dijalankan berulang.
 *
 * Pemakaian:
 *   node scripts/salin-user-prod-ke-dev.mjs --berkas .runtime/user-prod.json --kering
 *   node scripts/salin-user-prod-ke-dev.mjs --berkas .runtime/user-prod.json
 *   node scripts/salin-user-prod-ke-dev.mjs --langsung --pin-uji RCdev2026
 *   opsi: --pin-uji <PIN>  --pin-uji-semua  --tanpa-bagi  --benih <-1..1>
 */
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const argv = process.argv.slice(2);
const opsi = (nama) => { const i = argv.indexOf(nama); return i >= 0 ? argv[i + 1] : null; };
const ada = (nama) => argv.includes(nama);

const berkas = opsi('--berkas');
const langsung = ada('--langsung');
const pinUji = opsi('--pin-uji');
const pinUjiSemua = ada('--pin-uji-semua');
const kering = ada('--kering');
const tanpaBagi = ada('--tanpa-bagi');
const benih = opsi('--benih');
const LOGIN_DOMAIN = '@rc-login.invalid';

function gagal(pesan) { console.error('\n  ' + pesan + '\n'); process.exit(1); }

if (!berkas && !langsung) gagal('Pakai --berkas <ekspor.json> atau --langsung. Lihat kepala berkas ini.');
if (pinUjiSemua && !pinUji) gagal('--pin-uji-semua butuh --pin-uji <PIN>.');
if (pinUji && pinUji.length < 8) gagal('PIN uji minimal 8 karakter (aturan PIN aplikasi).');
if (benih != null && !(Math.abs(Number(benih)) <= 1)) gagal('--benih harus angka antara -1 dan 1.');

// ---- Lingkungan ---------------------------------------------------------------------------
const daftar = JSON.parse(await readFile(path.join(root, 'config', 'environments.json'), 'utf8'));
const dev = daftar.supabase_projects?.dev;
const prod = daftar.supabase_projects?.prod;
if (!dev?.project_ref || !prod?.project_ref) gagal('config/environments.json belum lengkap.');
if (dev.project_ref === prod.project_ref) gagal('DITOLAK: ref dev sama dengan prod.');

const envFile = {};
for (const l of (await readFile(path.join(root, '.env'), 'utf8')).split(/\r?\n/)) {
  const m = l.match(/^\s*([A-Z0-9_]+)\s*=\s*(.+?)\s*$/);
  if (m) envFile[m[1]] = m[2];
}
const tokenDev = envFile[dev.token_env || 'SUPABASE_ACCESS_TOKEN_DEV'];
if (!tokenDev) gagal('Token dev tidak ada di .env.');

async function sql(ref, token, query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`HTTP ${r.status}: ${t.slice(0, 400)}`);
  try { return JSON.parse(t); } catch { return []; }
}
const sqlDev = (q) => sql(dev.project_ref, tokenDev, q);

// ---- 1. Ekspor prod -----------------------------------------------------------------------
function normalisasi(x) {
  if (Array.isArray(x)) x = x[0];
  if (x && typeof x === 'object' && 'ekspor' in x) x = x.ekspor;
  if (typeof x === 'string') x = JSON.parse(x);
  if (!x || !Array.isArray(x.users) || !Array.isArray(x.depots)) {
    gagal('Berkas bukan hasil ekspor-user-prod.sql (tidak ada users/depots).');
  }
  return x;
}

let ekspor;
if (berkas) {
  ekspor = normalisasi(JSON.parse(await readFile(path.resolve(berkas), 'utf8')));
} else {
  const tokenProd = envFile[prod.token_env || 'SUPABASE_ACCESS_TOKEN'];
  if (!tokenProd) gagal(`Token prod (${prod.token_env || 'SUPABASE_ACCESS_TOKEN'}) tidak ada di .env.`);
  const q = await readFile(path.join(root, 'supabase', 'queries', 'ekspor-user-prod.sql'), 'utf8');
  // Penjaga: yang dikirim ke prod harus benar-benar hanya membaca.
  const tanpaKomentar = q.replace(/--.*$/gm, '');
  if (/\b(insert|update|delete|alter|drop|create|truncate|grant|revoke)\b/i.test(tanpaKomentar)) {
    gagal('DITOLAK: kueri ekspor memuat perintah yang mengubah data.');
  }
  console.log(`\n  Membaca user dari PROD (${prod.project_ref}) - hanya SELECT...`);
  ekspor = normalisasi(await sql(prod.project_ref, tokenProd, q));
}

if (!ekspor.depots.length) gagal('Ekspor tidak memuat satu depot pun.');

// Akun khusus dev tidak pernah ditimpa, sekalipun prod kebetulan punya User ID yang sama:
// DANIEL adalah System Manager bawaan dev, sisanya akun uji.
const DICADANGKAN = new Set(['DANIEL', 'SMDEV', 'OSCDEV', 'SPVDEV', 'OFFDEV']);
const bentrok = ekspor.users.filter((u) => DICADANGKAN.has(String(u.user_code).trim().toUpperCase()));
const users = ekspor.users.filter((u) => !DICADANGKAN.has(String(u.user_code).trim().toUpperCase()));
const tanpaHash = users.filter((u) => !u.password_hash);
if ((pinUjiSemua || tanpaHash.length) && !pinUji) {
  gagal(`${tanpaHash.length} user tidak membawa hash PIN. Tambahkan --pin-uji <PIN> untuk mereka.`);
}

// ---- 2. Rencana -----------------------------------------------------------------------------
const perPeran = {};
for (const u of users) {
  const k = `${u.role}/${u.status}`;
  perPeran[k] = (perPeran[k] || 0) + 1;
}
const devAda = new Map((await sqlDev('select user_code, id from public.profiles;'))
  .map((r) => [String(r.user_code).toUpperCase(), r.id]));
const baru = users.filter((u) => !devAda.has(String(u.user_code).trim().toUpperCase()));

console.log(`\n  Ekspor prod: ${users.length} user, ${ekspor.depots.length} depot` +
  (ekspor.diekspor_pada ? ` (diekspor ${ekspor.diekspor_pada})` : ''));
console.log('  Peran/status: ' + Object.entries(perPeran).map(([k, n]) => `${k}=${n}`).join(', '));
console.log(`  Akun baru di dev: ${baru.length}; sudah ada (profil diperbarui, PIN tetap): ${users.length - baru.length}`);
if (bentrok.length) console.log('  Dilewati (User ID khusus dev): ' + bentrok.map((u) => u.user_code).join(', '));
console.log(`  PIN: ${pinUjiSemua ? 'PIN uji untuk semua' : `hash prod untuk ${users.length - tanpaHash.length}, PIN uji untuk ${tanpaHash.length}`}`);
console.log(`  Yurisdiksi OSC/Supervisor: ${tanpaBagi ? 'ikut prod' : 'dibagi ulang acak seimbang'}`);
// --kering berhenti di sini. Sisanya dibungkus blok, bukan diakhiri process.exit(): keluar paksa
// selagi koneksi fetch masih terbuka memicu penegasan libuv di Windows (kode keluar 127).
if (kering) console.log('\n  --kering: tidak ada yang ditulis.\n');
if (!kering) {

// ---- 3. Depot -------------------------------------------------------------------------------
const lit = (s) => (s == null ? 'null' : "'" + String(s).replace(/'/g, "''") + "'");
await sqlDev(`
do $d$ begin
  if not exists (select 1 from public.customers where npwp like 'DUMMY-NPWP-%') then
    raise exception 'DITOLAK: bukan database dev.'; end if;
end $d$;
with v(kode, nama, abbr, region) as (values ${ekspor.depots.map((d) =>
  `(${lit(d.kode)}, ${lit(d.nama)}, ${lit(d.abbr)}, ${lit(d.region)})`).join(',\n  ')})
, ubah as (
  update public.depots d set depot_name = v.nama, abbr = v.abbr, region = v.region
    from v where d.depot_code = v.kode returning d.depot_code)
insert into public.depots(depot_code, depot_name, abbr, region)
select v.kode, v.nama, v.abbr, v.region from v
 where not exists (select 1 from public.depots d where d.depot_code = v.kode);`);
console.log('\n  Depot diselaraskan dengan prod.');

// ---- 4. Akun Auth ---------------------------------------------------------------------------
const kunci = await (await fetch(`https://api.supabase.com/v1/projects/${dev.project_ref}/api-keys`,
  { headers: { Authorization: 'Bearer ' + tokenDev } })).json();
const service = Array.isArray(kunci) && kunci.find((k) => k.name === 'service_role');
if (!service) gagal('Kunci service_role dev tidak ditemukan.');

const depotSah = new Set(ekspor.depots.map((d) => d.kode));
const depotCadangan = ekspor.depots[0]?.kode;
const ditolak = [];
for (const u of baru) {
  const kode = String(u.user_code).trim();
  const email = u.login_email ||
    createHash('sha256').update(kode.toUpperCase()).digest('hex') + LOGIN_DOMAIN;
  const peran = String(u.role || '').toLowerCase() === 'non-osc' ? 'others' : String(u.role || '').toLowerCase();
  const body = {
    email, email_confirm: true,
    user_metadata: {
      user_code: kode, full_name: u.full_name || kode,
      business_email: kode.toLowerCase().replace(/[^a-z0-9._-]/g, '') + '@dev.invalid',
      requested_role: peran,
      requested_depot: depotSah.has(u.home_depot) ? u.home_depot : depotCadangan,
    },
  };
  if (u.password_hash && !pinUjiSemua) body.password_hash = u.password_hash;
  else body.password = pinUji;

  const r = await fetch(`https://${dev.project_ref}.supabase.co/auth/v1/admin/users`, {
    method: 'POST',
    headers: { apikey: service.api_key, Authorization: 'Bearer ' + service.api_key, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const hasil = await r.json().catch(() => ({}));
  if (!r.ok) { ditolak.push(`${kode}: ${String(hasil.msg || hasil.message || hasil.error_description || r.status).slice(0, 160)}`); continue; }
  devAda.set(kode.toUpperCase(), hasil.id);
}
console.log(`  Akun dibuat: ${baru.length - ditolak.length}` + (ditolak.length ? `, ditolak: ${ditolak.length}` : ''));
ditolak.forEach((d) => console.log('    - ' + d));

// ---- 5. Profil, izin, yurisdiksi peran lain -------------------------------------------------
const baris = users
  .filter((u) => devAda.has(String(u.user_code).trim().toUpperCase()))
  .map((u) => ({
    id: devAda.get(String(u.user_code).trim().toUpperCase()),
    kode: String(u.user_code).trim(),
    full_name: u.full_name, role: String(u.role || '').toLowerCase() === 'non-osc' ? 'others' : String(u.role || '').toLowerCase(),
    status: u.status, department: u.department ?? null, home_depot: u.home_depot ?? null,
    mcp: !!u.must_change_password,
    permissions: u.permissions || [], tabs: u.tabs || {}, grants: u.grants || [],
    regions: u.regions || [], membina: u.membina || [],
  }));
const json = JSON.stringify(baris);
const tag = '$impor_' + createHash('sha256').update(json).digest('hex').slice(0, 12) + '$';
if (json.includes(tag)) gagal('Data memuat penanda kutipan; batal.');

await sqlDev(`
do $i$
declare r record; g jsonb; x text;
begin
  if not exists (select 1 from public.customers where npwp like 'DUMMY-NPWP-%') then
    raise exception 'DITOLAK: bukan database dev.'; end if;

  for r in select * from jsonb_to_recordset(${tag}${json}${tag}::jsonb) as t(
      id uuid, kode text, full_name text, role text, status text, department text, home_depot text,
      mcp boolean, permissions jsonb, tabs jsonb, grants jsonb, regions jsonb, membina jsonb) loop
    update public.profiles p
       set full_name = coalesce(r.full_name, p.full_name), role = r.role, status = r.status,
           department = r.department, must_change_password = r.mcp,
           business_email = lower(regexp_replace(r.kode, '[^A-Za-z0-9._-]', '', 'g')) || '@dev.invalid',
           home_depot_id = (select d.id from public.depots d where d.depot_code = r.home_depot)
     where p.id = r.id;

    delete from public.user_permissions where user_id = r.id;
    insert into public.user_permissions(user_id, permission_code)
    select r.id, v from jsonb_array_elements_text(r.permissions) v
     where exists (select 1 from public.permissions pm where pm.code = v)
    on conflict do nothing;

    delete from rc_private.user_tab_access where user_id = r.id;
    insert into rc_private.user_tab_access(user_id, tab_code, allowed)
    select r.id, e.key, (e.value)::text::boolean from jsonb_each(r.tabs) e
     where exists (select 1 from rc_private.tab_catalog c where c.code = e.key);

    -- Yurisdiksi: OSC dan Supervisor dibagi ulang oleh bagi-yurisdiksi-dev.sql kecuali
    -- --tanpa-bagi; peran lain selalu ikut prod.
    if r.role not in ('osc', 'supervisor') or ${tanpaBagi ? 'true' : 'false'} then
      delete from public.user_depot_grants where user_id = r.id;
      insert into public.user_depot_grants(user_id, depot_id, kind)
      select r.id, d.id, gg->>'kind' from jsonb_array_elements(r.grants) gg
        join public.depots d on d.depot_code = gg->>'depot'
      on conflict do nothing;
      delete from public.user_region_access where user_id = r.id;
      insert into public.user_region_access(user_id, region)
      select r.id, v from jsonb_array_elements_text(r.regions) v on conflict do nothing;
    end if;
    if r.role = 'supervisor' and ${tanpaBagi ? 'true' : 'false'} then
      delete from public.user_supervision where supervisor_id = r.id;
      insert into public.user_supervision(supervisor_id, osc_id)
      select r.id, o.id from jsonb_array_elements_text(r.membina) v
        join public.profiles o on upper(o.user_code) = upper(v) and o.role = 'osc'
      on conflict do nothing;
    end if;
  end loop;

  -- Akun uji OSC/Supervisor dev tidak ikut pembagian.
  update public.profiles set status = 'inactive'
   where user_code in ('OSCDEV', 'SPVDEV') and status = 'active';
end
$i$;`);
console.log(`  Profil, izin dan yurisdiksi peran lain: ${baris.length} user.`);

// ---- 6. Pembagian OSC/Supervisor, lalu akses dibangun ulang ---------------------------------
if (!tanpaBagi) {
  const bagi = await readFile(path.join(root, 'supabase', 'queries', 'bagi-yurisdiksi-dev.sql'), 'utf8');
  const hasil = await sqlDev((benih != null ? `select set_config('rc.benih', ${lit(benih)}, false);\n` : '') + bagi);
  console.log('\n  Pembagian yurisdiksi:');
  for (const h of hasil) console.log(`    ${h.kunci}: ${h.nilai}`);
}
await sqlDev(`select count(rc_private.rebuild_depot_access(p.id)) from public.profiles p;`);
const [ringkas] = await sqlDev(`
  select count(*) filter (where status = 'active') as aktif, count(*) as total,
         string_agg(distinct role, ', ') as peran from public.profiles;`);
console.log(`\n  Selesai. Profil di dev: ${ringkas.total} (aktif ${ringkas.aktif}); peran: ${ringkas.peran}.\n`);
}
