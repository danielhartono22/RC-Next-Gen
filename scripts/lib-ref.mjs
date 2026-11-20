/*
 * Project ref Supabase dibaca dari config/environments.json LOKAL (tidak masuk git sejak
 * 20-Nov-2026: "push ke github dengan exclude output dan connection link"). Skrip yang dulu
 * menulis ref prod secara polos mengambilnya dari sini.
 *
 * Bila berkas lokal tidak ada, ref kosong dan pemanggil yang membutuhkannya berhenti dengan
 * pesan yang jelas - tidak pernah menebak project.
 */
import { readFileSync } from 'node:fs';

let cfg = {};
try {
  cfg = JSON.parse(readFileSync(new URL('../config/environments.json', import.meta.url), 'utf8'));
} catch { cfg = {}; }

export const PROD_REF = (cfg.supabase_projects && cfg.supabase_projects.prod && cfg.supabase_projects.prod.project_ref) || process.env.RC_PROD_REF || '';
export const DEV_REF = (cfg.supabase_projects && cfg.supabase_projects.dev && cfg.supabase_projects.dev.project_ref) || process.env.RC_DEV_REF || '';

export function wajibRef(ref, nama) {
  if (!/^[a-z]{20}$/.test(ref || '')) {
    throw new Error(`Project ref ${nama} tidak ditemukan: isi config/environments.json lokal (lihat config/environments.example.json) atau variabel RC_${nama.toUpperCase()}_REF.`);
  }
  return ref;
}
