# Bukti deployment RC snapshot intake

Tanggal: 15 September 2026. Target terverifikasi melalui `get_project_url`: DEV `vvojshgcduqlugngpzkj`.

- Inventaris sebelum push: tabel public kosong.
- `apply_migration(rc_snapshot_intake)` mengembalikan `success: true`.
- `list_migrations`: versi `20260915004131`, nama `rc_snapshot_intake`; nama file lokal diselaraskan dengan versi remote.
- Uji SQL `supabase/tests/rc_snapshot_intake.sql` pada remote dalam transaksi yang di-rollback: insert service_role, replay identik, konflik isi, penolakan sheet Upload dan sel nonteks lulus.
- Pemeriksaan ACL: `anon_denied`, `authenticated_denied`, `staging_private`, `rls_enabled`, `replay_single_row` seluruhnya true.
- Setelah rollback: `staging.rc_snapshots` berisi 0 snapshot; data uji tidak disimpan.
- `python scripts/test_sync_rc.py`: 5 test lulus (CSV valid dengan koma dalam kutipan, header duplikat, lebar salah, Upload dan Authority ditolak). Percobaan pertama terhalang akses temporary directory sandbox; rerun dengan izin berhasil.

Batas verifikasi: jalur HTTP skrip belum diuji end-to-end karena service_role credential dan CSV sumber tidak tersedia. SQL RPC diuji langsung sebagai service_role melalui MCP. Belum ada import data bisnis, jadwal otomatis, tabel final, Auth, adapter frontend, atau perubahan Document Center.
