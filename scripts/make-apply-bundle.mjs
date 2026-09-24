/*
 * Menggabungkan migration yang belum diterapkan menjadi satu file untuk ditempel sekali ke
 * Supabase SQL Editor.
 *
 * Isinya diturunkan dari file migration aslinya, tidak diketik ulang, sehingga tidak bisa
 * menyimpang. Seluruhnya dibungkus satu transaksi: kalau ada satu perintah gagal, semuanya
 * dibatalkan dan database kembali seperti semula. Tidak ada kondisi setengah jadi.
 *
 * Di depan ada penjaga yang menolak berjalan bila salah satu migration sudah ada, karena
 * migration ini tidak idempotent dan menjalankannya dua kali akan merusak.
 *
 * Jalankan: node scripts/make-apply-bundle.mjs [--skip <awalan versi>]...
 * Contoh:    node scripts/make-apply-bundle.mjs --skip 20260916010000
 *            dipakai ketika penjaga melaporkan migration itu sudah diterapkan.
 */
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Urutan wajib: yang belakangan memakai fungsi buatan yang terdahulu.
const skip = process.argv.reduce((acc, arg, i, all) =>
  arg === '--skip' && all[i + 1] ? acc.concat(all[i + 1]) : acc, []);

const ALL = [
  { file: '20260916010000_rc_transaction_input_validation.sql', probe: "rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)", label: 'validasi input transaksi' },
  { file: '20260917010000_rc_legacy_compat_api.sql', probe: 'public.rc_legacy_bootstrap()', label: 'compat API untuk UI lama' },
  { file: '20260917020000_rc_auth_reset_and_signup.sql', probe: 'public.rc_review_request(text,boolean)', label: 'reset auth dan portal pendaftaran' },
  { file: '20260918010000_rc_key_master_and_compilation.sql', probe: 'public.rc_customer_list(text,integer,integer)', label: 'Key Master dan Cashback Compilation' },
  { file: '20260919010000_rc_workflow_routing_and_upload_rules.sql', probe: 'public.rc_open_claims(text,text,integer,integer)', label: 'alur workflow dan syarat upload', idempotent: true },
  { file: '20260920010000_rc_cashback_compilation_upload.sql', probe: 'public.rc_compile_preview(jsonb)', label: 'compile cashback dari Excel', idempotent: true },
  { file: '20260921010000_rc_access_console_fixes.sql', probe: 'public.rc_public_depots()', label: 'perbaikan Kelola Akses, peran, depot pendaftaran', idempotent: true },
  { file: '20260922010000_rc_display_and_pagination_fixes.sql', probe: 'rc_private.marker_20260922()', label: 'tanggal proses, tab Open, pagination compilation', idempotent: true },
  { file: '20260923010000_rc_jenis_cb_voucher_and_depot_abbr.sql', probe: 'rc_private.marker_20260923()', label: 'Jenis CB Voucher dan Abbr depot', idempotent: true },
  { file: '20260924010000_rc_system_manager_sees_everything.sql', probe: 'rc_private.marker_20260924()', label: 'System Manager melihat semua lewat peran', idempotent: true },
  { file: '20260925010000_rc_role_consistency_and_self_diagnostic.sql', probe: 'public.rc_workflow_diagnostic()', label: 'konsistensi peran dan diagnostik mandiri', idempotent: true },
  { file: '20260926010000_rc_claim_sensitive_terbaca_workflow.sql', probe: 'rc_private.marker_20260926()', label: 'hak baca claim_sensitive supaya antrean workflow terisi', idempotent: true },
  { file: '20260927010000_rc_bersihkan_data_uji_sintetis.sql', probe: 'rc_private.marker_20260927()', label: 'membuang sisa data uji Synthetic E2E (opsional, menghapus baris)', idempotent: true },
  { file: '20260928010000_rc_pulihkan_digit_dari_sumber.sql', probe: 'rc_private.marker_20260928()', label: 'memulihkan KTP, NPWP, rekening dan nomor batch dari Compile.csv', idempotent: true },
  { file: '20260929010000_rc_pulihkan_customer_master.sql', probe: 'rc_private.marker_20260929()', label: 'memulihkan Customer Master dari ListCust.csv', idempotent: true },
  { file: '20260930010000_rc_lengkapi_customer_dari_compile.sql', probe: 'rc_private.marker_20260930()', label: 'melengkapi Customer Master dari Compile.csv', idempotent: true },
  { file: '20261001010000_rc_abbr_jakarta_tu_dan_penjagaan.sql', probe: 'rc_private.marker_20261001()', label: 'abbr Jakarta (TU) menjadi JKT dan penjagaan abbr', idempotent: true },
  { file: '20261002010000_rc_yurisdiksi_dan_kelola_akses.sql', probe: 'rc_private.marker_20261002()', label: 'model yurisdiksi: home, Resource Partner, supervisi OSC', idempotent: true },
  { file: '20261003010000_rc_konsol_kelola_akses.sql', probe: 'rc_private.marker_20261003()', label: 'konsol Kelola Akses benar-benar menyimpan', idempotent: true },
  { file: '20261004010000_rc_permintaan_pin.sql', probe: 'rc_private.marker_20261004()', label: 'permintaan ganti PIN dan lupa PIN dengan persetujuan', idempotent: true },
  { file: '20261005010000_rc_aturan_unggah_jenis_cb.sql', probe: 'rc_private.marker_20261005()', label: 'Jenis CB per dokumen, RA07/RA7 langsung Done, Expired bernomor batch', idempotent: true },
  { file: '20261006010000_rc_analytics_semua_status.sql', probe: 'rc_private.marker_20261006()', label: 'Cashback List memuat seluruh status', idempotent: true },
  { file: '20261007010000_rc_perbaikan_akses_pin_depot.sql', probe: 'rc_private.marker_20261007()', label: 'syarat pengelola disamakan, diagnostik akses, depot Head Office', idempotent: true },
  { file: '20261008010000_rc_voucher_sebagai_transfer.sql', probe: 'rc_private.marker_20261008()', label: 'Voucher dihitung sebagai Transfer', idempotent: true },
  { file: '20261009010000_rc_pin_diajukan_pengguna.sql', probe: 'rc_private.marker_20261009()', label: 'PIN diajukan pengguna, disetujui pengelola', idempotent: true },
  { file: '20261010010000_rc_fondasi_report_timetable.sql', probe: 'rc_private.marker_20261010()', label: 'fondasi Report dan Timetable: region, periode campaign, gross claimed', idempotent: true },
  { file: '20261011010000_rc_modul_report.sql', probe: 'rc_private.marker_20261011()', label: 'Report: Dashboard, Cost Center 1, Cost Center 2', idempotent: true },
  { file: '20261012010000_rc_modul_timetable.sql', probe: 'rc_private.marker_20261012()', label: 'Timetable: matrix, Not Achieved, exclude campaign', idempotent: true },
  { file: '20261013010000_rc_tanggal_legacy_dan_depot_manager.sql', probe: 'rc_private.marker_20261013()', label: 'tanggal warisan diurai, System Manager melihat seluruh depot', idempotent: true },
  { file: '20261014010000_rc_depot_master_dan_email_tujuan.sql', probe: 'rc_private.marker_20261014()', label: 'Depot Master di Key Master dengan email TO dan CC', idempotent: true },
  { file: '20261015010000_rc_email_otomatis.sql', probe: 'rc_private.marker_20261015()', label: 'email otomatis: pengaturan, penyusun isi, outbox', idempotent: true },
  { file: '20261016010000_rc_pengirim_email.sql', probe: 'rc_private.marker_20261016()', label: 'pengirim email lewat pg_net dan pg_cron', idempotent: true },
  { file: '20261017010000_rc_pengirim_gmail.sql', probe: 'rc_private.marker_20261017()', label: 'pengiriman lewat Gmail API dengan OAuth refresh token', idempotent: true },
  { file: '20261018010000_rc_katalog_izin_report_timetable.sql', probe: 'rc_private.marker_20261018()', label: 'Report dan Timetable masuk katalog izin Kelola Akses', idempotent: true },
  { file: '20261019010000_rc_report_timetable_lengkap.sql', probe: 'rc_private.marker_20261019()', label: 'Report dan Timetable disamakan dengan RC Reporting', idempotent: true },
  { file: '20261020010000_rc_system_manager_ubah_identitas_sendiri.sql', probe: 'rc_private.marker_20261020()', label: 'System Manager dapat mengubah identitas sendiri', idempotent: true },
  { file: '20261021010000_rc_profil_depot.sql', probe: 'rc_private.marker_20261021()', label: 'profil depot: penyimpanan, pengajuan, persetujuan', idempotent: true },
  { file: '20261022010000_rc_depot_master_satu_pintu.sql', probe: 'rc_private.marker_20261022()', label: 'Depot Master jadi satu pintu, approval di Access Management', idempotent: true },
  { file: '20261023010000_rc_gmail_token_lewat_query.sql', probe: 'rc_private.marker_20261023()', label: 'penyegaran token Gmail lewat query string', idempotent: true },
  { file: '20261024010000_rc_flag_report_timetable_di_bootstrap.sql', probe: 'rc_private.marker_20261024()', label: 'flag report dan timetable masuk bootstrap', idempotent: true },
  { file: '20261025010000_rc_upload_created_by_dan_sinkron_rekening.sql', probe: 'rc_private.marker_20261025()', label: 'Created by pada tab Open', idempotent: true },
  { file: '20261026010000_rc_posting_exception.sql', probe: 'rc_private.marker_20261026()', label: 'Posting Exception, rancangan pertama', idempotent: true },
  { file: '20261027010000_rc_posting_exception_per_baris.sql', probe: 'rc_private.marker_20261027()', label: 'Posting Exception memakai grid dengan empat tanggal per baris', idempotent: true },
  { file: '20261028010000_rc_reprocessing_doc.sql', probe: 'rc_private.marker_20261028()', label: 'Reprocessing Doc: On Hold direvisi lalu kembali Not Yet', idempotent: true }
];

const PENDING = ALL.filter((m) => !skip.some((s) => m.file.startsWith(s)));
if (PENDING.length === 0) {
  console.error('Semua migration dilewati. Tidak ada yang perlu dijalankan.');
  process.exit(1);
}
for (const s of skip) {
  if (!ALL.some((m) => m.file.startsWith(s))) {
    console.error(`--skip ${s} tidak cocok dengan migration mana pun.`);
    process.exit(1);
  }
}

// Hanya migration yang TIDAK aman dijalankan ulang yang dijaga. Migration idempotent
// memakai CREATE OR REPLACE dan IF NOT EXISTS, sehingga menjalankannya lagi tidak merusak
// apa pun; menjaganya justru menghalangi pengulangan yang sah setelah satu kali gagal.
// Sumber tiap migration dibaca lebih dulu supaya isinya dapat diperiksa saat menyusun
// header, bukan hanya saat disalin.
const sources = new Map();
for (const m of PENDING) {
  sources.set(m.file, await readFile(path.join(root, 'supabase', 'migrations', m.file), 'utf8'));
}

const guarded = PENDING.filter((m) => !m.idempotent);
// Peringatan penghapusan hanya boleh muncul bila berkas ini memang menghapus sesuatu.
// Peringatan yang salah sama buruknya dengan tidak ada peringatan: ia membuat pembaca
// berhenti mempercayai isinya.
const destructive = PENDING.some((m) => /delete from auth\.users/i.test(sources.get(m.file) || ''));
// Peringatan disusun sebagai larik baris, bukan satu string dengan escape newline, karena
// escape itu berulang kali rusak saat berkas ini disunting dari skrip lain.
const nl = String.fromCharCode(10);
const warningLines = destructive
  ? ['-- PERINGATAN: berkas ini MENGHAPUS seluruh akun Auth, profil, permission dan scope depot.',
     '-- Claim, campaign, customer, depot dan snapshot tidak disentuh. Ambil backup lebih dulu',
     '-- dengan "npm run backup". Penghapusan ini tidak bisa dibatalkan.']
  : ['-- Berkas ini TIDAK menghapus akun, profil maupun data bisnis apa pun. Isinya hanya',
     '-- pembuatan dan pembaruan fungsi, kolom serta hak akses.'];

const guard = guarded.map((m) => `  if to_regprocedure('${m.probe}') is not null then
   raise exception 'Migration "%" sudah diterapkan dan TIDAK aman dijalankan ulang. Hentikan bundle ini.', '${m.file}';
  end if;`).join('\n');

const header = `-- ==========================================================================================
-- RC: terapkan seluruh migration yang belum ada, sekali jalan.
--
-- DIHASILKAN OLEH scripts/make-apply-bundle.mjs. Jangan diedit langsung; ubah file
-- migration aslinya lalu jalankan ulang skrip itu.
--
-- Cara pakai: Supabase Dashboard -> SQL Editor -> tempel seluruh isi file ini -> Run.
--
${warningLines.join(nl)}
--
-- Seluruh isi berjalan dalam satu transaksi. Bila ada satu perintah gagal, tidak ada yang
-- tersimpan dan database tetap seperti sebelumnya.
-- ==========================================================================================

begin;

${guarded.length === 0
  ? '-- Seluruh migration di berkas ini aman dijalankan ulang (CREATE OR REPLACE / IF NOT EXISTS).'
  : `-- Penjaga: sebagian migration tidak aman dijalankan ulang.
do $rc_guard$
begin
${guard}
end $rc_guard$;`}
`;

const parts = [header];
for (const m of PENDING) {
  const sql = sources.get(m.file);
  parts.push(`
-- ==========================================================================================
-- ${m.file}
-- ${m.label}
-- ==========================================================================================
${sql.trimEnd()}
`);
}

parts.push(`
-- Ringkasan supaya hasilnya langsung terlihat sesudah Run.
select 'Selesai' as hasil,
 (select count(*) from auth.users) as akun_auth,
 (select count(*) from public.profiles) as profil,
 (select count(*) from public.claims) as claims,
 (select count(*) from public.customers) as customers,
 (select count(*) from public.campaigns) as campaigns,
 ${destructive
   ? `'Akun terhapus. Daftar ulang lewat portal; pendaftar pertama menjadi System Manager'`
   : `'Tidak ada data yang dihapus. Logout lalu login lagi supaya hak akses terbaru terbaca'`} as langkah_berikutnya;

commit;
`);

const out = path.join(root, 'supabase', 'apply-pending.sql');
const body = parts.join('\n');
await writeFile(out, body, 'utf8');
console.log(`Ditulis: supabase/apply-pending.sql (${body.length} karakter)`);
for (const m of PENDING) console.log(`  disertakan : ${m.file}`);
for (const m of ALL) if (!PENDING.includes(m)) console.log(`  dilewati   : ${m.file}`);
