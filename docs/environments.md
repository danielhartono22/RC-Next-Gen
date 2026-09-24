# Lingkungan proyek

## Keputusan aktif

Pada 14 September 2026, pemilik memberikan instruksi **“tetapkan dev”** untuk project Supabase `vvojshgcduqlugngpzkj`. Keputusan ini menggantikan penetapan sebelumnya sebagai PROD.

| Lingkungan Supabase | Project | Status |
|---|---|---|
| **DEV** | `vvojshgcduqlugngpzkj` | Target pengembangan dan pengujian |
| PROD | Belum ditetapkan | Tidak ada project Supabase yang ditunjuk sebagai PROD saat ini |

Registry yang dapat dibaca tooling: [config/environments.json](../config/environments.json). Registry ini belum dikonsumsi frontend legacy; ia menjadi acuan pemilihan project untuk pekerjaan Supabase berikutnya.

## Koneksi DEV

- Dashboard: [project DEV](https://supabase.com/dashboard/project/vvojshgcduqlugngpzkj).
- API URL: `https://vvojshgcduqlugngpzkj.supabase.co`.
- Nama server MCP: `supabase`.
- URL MCP: `https://mcp.supabase.com/mcp?project_ref=vvojshgcduqlugngpzkj`.

Pada 14 September 2026, 14:20:54 UTC, MCP mengembalikan project URL yang sesuai, daftar tabel public kosong, dan daftar migration kosong. Koneksi memakai project yang sama; tidak diperlukan konfigurasi/login MCP baru hanya untuk mengubah peran project menjadi DEV.

Penetapan ini mencatat **peran project dalam alur kerja repository**. Tidak membuat project/branch baru, mengubah nama project di dashboard, menerapkan SQL, atau memigrasikan aplikasi secara otomatis. Tidak ada perubahan database pada tindakan penetapan lingkungan ini.

## Penggunaan berikutnya

Cakupan aktif adalah **Resource Collection saja**. Document Center dikesampingkan atas instruksi pemilik karena masih PROD; rincian: [cakupan pekerjaan](scope.md).

- Gunakan project DEV di atas untuk migration dan uji setelah prasyarat mapping/aturan bisnis terkait tersedia.
- Verifikasi project reference sebelum menjalankan migration atau import; jangan memakai label PROD dari laporan historis sebagai target aktif.
- Project Supabase PROD akan ditetapkan terpisah sebelum cutover produksi.
- Penetapan DEV tidak mengubah `ENV` atau ID Spreadsheet pada backend Apps Script. Document Center lama tetap menunjuk Spreadsheet yang tercatat sebagai RC PROD pada sumber legacy.
- Header/formula dan keputusan bisnis RC tetap diperlukan untuk schema/import RC. Inventaris job 15 menit ditunda bersama Document Center dan tidak menghalangi pekerjaan RC DEV; alur dokumen baru tetap harus ditetapkan sebelum cutover produksi.

## Catatan historis

[Bukti Supabase awal](phase-0-supabase-evidence.json), [laporan pemeriksaan awal](phase-0-supabase-audit.md), dan [baseline frontend](phase-0-frontend-baseline.md) mempertahankan istilah PROD sesuai keputusan pada waktu pengambilan bukti. Untuk pemilihan lingkungan sekarang, gunakan registry dan dokumen ini. Bukti lama tidak ditulis ulang menjadi DEV.
