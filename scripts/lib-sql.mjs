/*
 * Satu jalan menjalankan SQL ke project Supabase, dipakai bersama oleh skrip lain.
 *
 * Dipisahkan dari apply-sql.mjs supaya pemeriksa seperti check-system.mjs dapat bertanya ke
 * basis data tanpa menyalin ulang pembacaan token dan pemanggilan Management API - dua salinan
 * yang cepat atau lambat akan berbeda dalam cara menangani galat.
 *
 * Token dibaca dari .env dan tidak pernah dicetak.
 */
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PROJECT_REF = 'vvojshgcduqlugngpzkj';
const API = `https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`;

async function bacaToken() {
  if (process.env.SUPABASE_ACCESS_TOKEN) return process.env.SUPABASE_ACCESS_TOKEN.trim();
  try {
    const env = await readFile(path.join(root, '.env'), 'utf8');
    for (const line of env.split(/\r?\n/)) {
      const m = line.match(/^\s*SUPABASE_ACCESS_TOKEN\s*=\s*(.+?)\s*$/);
      if (m) return m[1].replace(/^["']|["']$/g, '');
    }
  } catch { /* .env belum ada */ }
  return null;
}

export default async function jalankanSql(sql) {
  const token = await bacaToken();
  if (!token) throw new Error('SUPABASE_ACCESS_TOKEN belum tersedia di .env');
  const res = await fetch(API, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql })
  });
  const teks = await res.text();
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${teks.slice(0, 300)}`);
  try {
    return JSON.parse(teks);
  } catch {
    throw new Error(`Jawaban bukan JSON: ${teks.slice(0, 200)}`);
  }
}
