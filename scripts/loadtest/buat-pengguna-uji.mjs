/*
 * Membuat akun uji untuk load test, dan menulis pengguna-uji.json yang dibaca k6.
 *
 *   node scripts/loadtest/buat-pengguna-uji.mjs --url https://<ref>.supabase.co --jumlah 300
 *
 * Service role key dibaca dari peubah lingkungan SUPABASE_SERVICE_ROLE_KEY, tidak pernah dari
 * argumen. Kunci itu melewati seluruh RLS; menaruhnya di baris perintah berarti ia tersimpan di
 * riwayat shell dan terlihat di daftar proses.
 *
 * ===========================================================================================
 * MENOLAK BERJALAN TERHADAP PRODUKSI
 * ===========================================================================================
 * Skrip ini membuat ratusan akun. Terhadap project yang dipakai depot, akun-akun itu akan
 * bercampur dengan akun sungguhan di layar Access Management.
 *
 * Setiap akun uji memakai awalan LT pada User ID, sehingga selalu dapat ditemukan dan dihapus:
 *   delete from auth.users where id in (select id from public.profiles where user_code like 'LT%');
 *
 * SUSUNAN PERANNYA meniru keadaan nyata, bukan 300 akun yang sama:
 *   ±85%  admin       - pengguna depot, satu depot masing-masing
 *   ±10%  osc         - beberapa depot
 *   ±4%   supervisor  - lintas depot
 *   ±1%   finance
 * Campuran ini menentukan hasil: admin hanya membaca depotnya sendiri, supervisor membaca
 * semuanya. Uji yang seluruhnya supervisor akan mengukur beban jauh lebih berat daripada
 * kenyataan, dan yang seluruhnya admin jauh lebih ringan.
 */
import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

throw new Error('Historical provisioner disabled: production override and incomplete role/document fixtures. Follow docs/performance-testing-2026-09-21.md for isolated staging preparation.');

const args = process.argv.slice(2);
const ambil = (nama, bawaan) => {
  const i = args.indexOf('--' + nama);
  return i >= 0 && args[i + 1] ? args[i + 1] : bawaan;
};

const URL_PROYEK = ambil('url', '');
const JUMLAH = Number(ambil('jumlah', '300'));
const PIN = ambil('pin', 'UjiBeban2026!');
const KUNCI = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
const REF_PRODUKSI = 'vvojshgcduqlugngpzkj';

if (!URL_PROYEK) throw new Error('--url wajib diisi, contoh https://abcd.supabase.co');
if (!KUNCI) throw new Error('SUPABASE_SERVICE_ROLE_KEY belum diatur di lingkungan.');
if (URL_PROYEK.includes(REF_PRODUKSI) && process.env.SAYA_PAHAM_INI_PRODUKSI !== 'ya') {
  throw new Error('URL menunjuk project produksi. Pakai staging.');
}

// Peran ditebar menurut porsi di atas.
function peranUntuk(i) {
  const p = i / JUMLAH;
  if (p < 0.85) return 'admin';
  if (p < 0.95) return 'osc';
  if (p < 0.99) return 'supervisor';
  return 'finance';
}

async function panggil(jalur, opsi) {
  const res = await fetch(URL_PROYEK + jalur, {
    ...opsi,
    headers: {
      'Content-Type': 'application/json',
      apikey: KUNCI,
      Authorization: 'Bearer ' + KUNCI,
      ...(opsi && opsi.headers)
    }
  });
  const teks = await res.text();
  if (!res.ok) throw new Error('HTTP ' + res.status + ': ' + teks.slice(0, 200));
  return teks ? JSON.parse(teks) : null;
}

// Alamat login diturunkan dari SHA-256 User ID PERSIS SEPERTI YANG DIKETIK, sama seperti
// adapter aplikasi. Dihitung di sini supaya k6 tidak perlu crypto.subtle saat berjalan.
async function alamatLogin(userCode) {
  const bytes = new TextEncoder().encode(userCode);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('')
    + '@rc-login.invalid';
}

const dibuat = [];
const gagal = [];

console.log('  Membuat ' + JUMLAH + ' akun uji di ' + URL_PROYEK + '\n');

for (let i = 1; i <= JUMLAH; i += 1) {
  const kode = 'LT' + String(i).padStart(4, '0');
  const peran = peranUntuk(i);
  const email = await alamatLogin(kode);
  try {
    // handle_new_user() menuntut user_metadata lengkap; tanpa itu pendaftarannya ditolak
    // dengan pesan yang menyebut portal RC. Kuncinya persis empat nama di bawah.
    const akun = await panggil('/auth/v1/admin/users', {
      method: 'POST',
      body: JSON.stringify({
        email: email,
        password: PIN,
        email_confirm: true,
        user_metadata: {
          user_code: kode,
          full_name: 'Pengguna Uji ' + i,
          business_email: 'uji' + i + '@contoh-uji.invalid',
          requested_role: peran
        }
      })
    });
    dibuat.push({ id: akun.id, userId: kode, email: email, pin: PIN, peran: peran });
    if (i % 25 === 0) console.log('    ' + i + ' / ' + JUMLAH);
  } catch (e) {
    gagal.push({ kode: kode, sebab: String(e.message).slice(0, 120) });
  }
}

console.log('\n  Berhasil ' + dibuat.length + ', gagal ' + gagal.length);
if (gagal.length) {
  console.log('  Contoh kegagalan:');
  gagal.slice(0, 5).forEach((g) => console.log('    ' + g.kode + ': ' + g.sebab));
}

// Berkas untuk k6. Field docs diisi belakangan oleh langkah SQL yang memberi depot dan izin,
// karena dokumen mana yang boleh disentuh sebuah akun baru diketahui sesudah depotnya diberikan.
const berkas = path.join(path.dirname(fileURLToPath(import.meta.url)), 'pengguna-uji.json');
await writeFile(berkas, JSON.stringify(dibuat.map((u) => ({
  email: u.email, pin: u.pin, peran: u.peran, userId: u.userId, cari: '', docs: []
})), null, 2), 'utf8');

console.log('\n  Ditulis: ' + berkas);
console.log('\n  LANGKAH BERIKUTNYA - beri depot, izin dan status aktif lewat SQL Editor staging:');
console.log(`
  -- Aktifkan seluruh akun uji dan beri izin sesuai perannya
  update public.profiles set status='active', must_change_password=false
   where user_code like 'LT%';

  -- Admin: satu depot masing-masing, ditebar merata ke seluruh depot
  insert into public.user_depot_access(user_id, depot_id)
  select p.id, d.id from (
    select id, row_number() over (order by user_code) rn from public.profiles
     where user_code like 'LT%' and role='admin') p
  join (select id, row_number() over (order by depot_code) rn,
               count(*) over () n from public.depots) d
    on d.rn = 1 + (p.rn % d.n)
  on conflict do nothing;

  -- OSC dan supervisor: seluruh depot
  insert into public.user_depot_access(user_id, depot_id)
  select p.id, d.id from public.profiles p cross join public.depots d
   where p.user_code like 'LT%' and p.role in ('osc','supervisor')
  on conflict do nothing;

  -- Izin sesuai peran
  insert into public.user_permissions(user_id, permission_code)
  select p.id, x.kode from public.profiles p
  cross join lateral (values ('upload_claim'),('view_analytics'),('archive_compilation')) x(kode)
   where p.user_code like 'LT%' and p.role='admin'
  on conflict do nothing;

  insert into public.user_permissions(user_id, permission_code)
  select p.id, x.kode from public.profiles p
  cross join lateral (values ('release_claim'),('process_claim'),('view_report'),
                             ('manage_timetable'),('view_compilation')) x(kode)
   where p.user_code like 'LT%' and p.role in ('osc','supervisor')
  on conflict do nothing;

  analyze public.profiles; analyze public.user_depot_access; analyze public.user_permissions;
`);
