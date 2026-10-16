-- ==========================================================================================
-- PROD, sekali jalan: Tgl Done 29-Okt-2026 (belum terjadi) -> tanggal nomor batch Clearing
-- ==========================================================================================
-- Disetujui pemilik 16 Oktober 2026 ("ok sesuaikan"). 53 dokumen Done (4A 51, 4C 2) dari muat
-- ulang 10 Oktober 2026 tercatat cleared_at 29-10-2026 00:00 WIB, padahal nomor batch Clearing
-- (40 23 011026 000x) bertanggal 01-10-2026. Released 18-09-2026 dan Claimed 21-09-2026, jadi
-- 01-10-2026 berurutan. Tanggal diambil dari nomor batch setiap dokumen (ddmmyy, posisi 5-10),
-- jam 00:00 WIB seperti data muat ulang. version_no tidak dinaikkan (sama dengan 20261163130000).
-- Cadangan: .runtime/cadangan-prod-20261016-transport/klaim-tgl-done-29okt-sebelum.json
--
--   node scripts/apply-sql.mjs --env prod supabase/queries/perbaiki_tgl_done_29okt_prod_20261016.sql
-- ==========================================================================================
do $perbaiki$
declare n int;
begin
  if (select count(*) from public.claims where cleared_at > now()) <> 53 then
    raise exception 'DITOLAK: jumlah dokumen bertanggal Done di masa depan bukan 53 (%); periksa ulang.',
      (select count(*) from public.claims where cleared_at > now()); end if;
  if exists(select 1 from public.claims where cleared_at > now()
             and (status <> 'done' or batch_clearing !~ '^\d{4}011026\d{4}$' or customer_id is null)) then
    raise exception 'DITOLAK: ada dokumen di luar pola yang diperiksa (status/batch/customer).'; end if;

  update public.claims
     set cleared_at = (to_date(substring(batch_clearing from 5 for 6), 'DDMMYY'))::timestamp at time zone 'Asia/Jakarta'
   where cleared_at > now();
  get diagnostics n = row_count;

  if n <> 53 then raise exception 'GAGAL: % dokumen diubah, harap 53; dibatalkan.', n; end if;
  if exists(select 1 from public.claims where cleared_at > now()) then
    raise exception 'GAGAL: masih ada Tgl Done di masa depan; dibatalkan.'; end if;
  if (select count(*) from public.claims where cleared_at = timestamptz '2026-10-01 00:00:00+07' and batch_clearing ~ '^\d{4}011026\d{4}$') < 53 then
    raise exception 'GAGAL: Tgl Done hasil perbaikan tidak 01-10-2026 00:00 WIB; dibatalkan.'; end if;
  if exists(select 1 from public.claims where status = 'done' and batch_clearing ~ '^\d{4}011026\d{4}$' and cleared_at < claimed_at) then
    raise exception 'GAGAL: ada Tgl Done sebelum Tgl Claimed; dibatalkan.'; end if;

  insert into public.activity_logs(actor_id, event_type, details)
  values (null, 'perbaikan_tgl_done', jsonb_build_object('tanggal', '20261016', 'dokumen', n,
    'dari', '29-10-2026 00:00 WIB', 'menjadi', '01-10-2026 00:00 WIB (tanggal nomor batch Clearing)',
    'depot', jsonb_build_object('4A', 51, '4C', 2)));
end
$perbaiki$;

select count(*) filter (where cleared_at > now()) masa_depan,
       count(*) filter (where cleared_at = timestamptz '2026-10-01 00:00:00+07' and batch_clearing ~ '^\d{4}011026\d{4}$') jadi_01okt
  from public.claims;
