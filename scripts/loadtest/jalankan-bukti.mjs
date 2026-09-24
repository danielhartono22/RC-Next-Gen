/*
 * Menjalankan bukti kesetaraan RLS.
 *
 * Kegunaannya satu: memastikan yang diuji adalah TEKS KEBIJAKAN YANG SESUNGGUHNYA dari
 * usulan-optimasi-rls.sql, bukan salinan di dalam skrip bukti yang dapat menyimpang diam-diam.
 * Salinan yang menyimpang adalah cara paling halus sebuah pembuktian menjadi tidak berarti:
 * ia tetap melaporkan "setara" sementara yang diterapkan kemudian sudah berbeda.
 *
 * Skrip ini menyusun satu berkas SQL dari dua bagian:
 *   1. bagian 1-3 usulan-optimasi-rls.sql  (fungsi pembantu dan kebijakan baru)
 *   2. bukti-setara-rls.sql                (pengukuran sebelum/sesudah dan pembandingnya)
 * lalu menjalankannya lewat apply-sql.mjs. Berkasnya berakhir dengan exception, jadi seluruh
 * perubahan dibatalkan - termasuk kebijakan yang sempat dipasang.
 *
 * Jalankan: node scripts/loadtest/jalankan-bukti.mjs
 */
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import jalankanSql from '../lib-sql.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const dir = path.join(root, 'scripts', 'loadtest');

const usulan = await readFile(path.join(dir, 'usulan-optimasi-rls.sql'), 'utf8');
const bukti = await readFile(path.join(dir, 'bukti-setara-rls.sql'), 'utf8');

// Bagian 1-3 usulan: fungsi pembantu sampai tepat sebelum bagian indeks. Indeksnya sengaja
// tidak ikut - CREATE INDEX CONCURRENTLY tidak boleh berada di dalam transaksi, dan yang
// dibuktikan di sini adalah kesetaraan kebijakan, bukan kecepatan indeks.
const awal = usulan.indexOf('create or replace function rc_private.depot_saya()');
const penandaIndeks = usulan.indexOf('-- 4. Indeks penopang');
if (awal < 0 || penandaIndeks < 0) {
  throw new Error('Susunan usulan-optimasi-rls.sql berubah; perbarui penanda di skrip ini.');
}
const akhir = usulan.lastIndexOf('-- ----', penandaIndeks);
const kebijakan = usulan.slice(awal, akhir);

// Skrip bukti menandai tempat kebijakan disisipkan.
const PENANDA = '-- {{KEBIJAKAN USULAN DISISIPKAN DI SINI}}';
if (bukti.indexOf(PENANDA) < 0) {
  throw new Error('bukti-setara-rls.sql tidak memuat penanda penyisipan: ' + PENANDA);
}

const gabungan = bukti.replace(PENANDA,
  '-- Disisipkan otomatis dari usulan-optimasi-rls.sql oleh jalankan-bukti.mjs.\n' + kebijakan);

const keluaran = path.join(dir, '.bukti-gabungan.sql');
await writeFile(keluaran, gabungan, 'utf8');

console.log('  Menyusun bukti dari usulan-optimasi-rls.sql (' + kebijakan.length + ' karakter kebijakan)');
console.log('  Menjalankan... seluruh perubahan akan dibatalkan di akhir.\n');

try {
  await jalankanSql(gabungan);
  console.log('  \x1b[31mSkrip selesai TANPA exception - itu tidak diharapkan.\x1b[0m');
  console.log('  Bukti seharusnya selalu berakhir dengan raise exception supaya dibatalkan.');
  process.exitCode = 1;
} catch (e) {
  const pesan = String(e.message || '');
  const cocok = pesan.match(/HASIL: (\d+) setara, (\d+) berbeda/);
  console.log(pesan.replace(/\\n/g, '\n'));
  if (!cocok) {
    console.log('\n  \x1b[31mBukti tidak selesai sebagaimana mestinya.\x1b[0m');
    process.exitCode = 1;
  } else if (Number(cocok[2]) > 0) {
    console.log('\n  \x1b[31m' + cocok[2] + ' perbedaan ditemukan. JANGAN diterapkan.\x1b[0m');
    process.exitCode = 1;
  } else {
    console.log('\n  \x1b[32mSetara seluruhnya (' + cocok[1] + ' pasangan). Perubahan dibatalkan.\x1b[0m');
  }
}
