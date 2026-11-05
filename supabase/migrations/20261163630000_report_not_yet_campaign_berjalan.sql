-- ==========================================================================================
-- Report: dokumen Not Yet dari campaign yang Billing End-nya belum lewat tidak dihitung
-- ==========================================================================================
-- Pemilik, 4 November 2026: "untuk campaign yang belum berakhir (dihitung dari billing end harus
-- > billing end) maka tidak diperhitungkan sebagai Not Yet di depot / bukan pendingan ketika
-- report nya." Pilihan pemilik: KELUAR DARI REPORT sepenuhnya - tidak masuk Total Klaim, Net CB,
-- Clearing Rate, Outstanding maupun Outstanding Claim - dan masuk lagi begitu Billing End lewat.
--
-- * Batas = Billing End dokumen (perpanjangan extend_billing_end lebih dulu, lalu Billing End
--   campaign); bila kosong, SO End lalu Period End campaign. Masuk Report bila hari ini (WIB)
--   sudah MELEWATI batas itu. Tanpa tanggal sama sekali: tetap masuk (seperti sebelumnya).
-- * Hanya status Not Yet. Dokumen yang sudah diajukan / Done / Expired tetap dihitung.
-- * Berlaku untuk semua pembaca rc_report_rows lewat snapshot (20261163600000): Report,
--   dashboard publik, Excel Report, email Daily / Weekly beserta PDF dan grafiknya.
-- Aman dijalankan berulang.
-- ==========================================================================================

do $view$
declare v_def text := pg_get_viewdef('public.rc_report_rows'::regclass, true);
begin
  if v_def ~ 'ca\.so_end, ca\.period_end\) >=' then raise notice 'rc_report_rows sudah ditambal.'; return; end if;
  if md5(v_def) <> 'f5d45410d250d526f0d39fe4f64f72f0' then
    raise exception 'DITOLAK: definisi rc_report_rows berbeda dari yang diukur (md5 %).', md5(v_def); end if;
  execute 'create or replace view public.rc_report_rows as '
    || regexp_replace(v_def, ';\s*$', '')
    || $w$ AND NOT (c.status = 'not_yet'::text
          AND COALESCE(c.extend_billing_end, ca.billing_end, ca.so_end, ca.period_end) >= (now() AT TIME ZONE 'Asia/Jakarta'::text)::date)$w$;
end $view$;

comment on view public.rc_report_rows is
  'Baris Report. 20261163630000: dokumen Not Yet dari campaign yang Billing End-nya (extend, campaign, lalu SO End / Period End) belum lewat tidak termasuk.';

-- Snapshot Report langsung disegarkan supaya angka baru terlihat tanpa menunggu jadwal.
select rc_private.segarkan_report('migrasi 630000');

do $cek$ begin
  if exists (select 1 from public.rc_report_rows r join public.claims c on c.id = r.id join public.campaigns ca on ca.id = c.campaign_id
              where r.status = 'not_yet'
                and coalesce(c.extend_billing_end, ca.billing_end, ca.so_end, ca.period_end) >= (now() at time zone 'Asia/Jakarta')::date) then
    raise exception 'GAGAL: masih ada Not Yet dari campaign yang belum lewat Billing End'; end if;
  if (select count(*) from rc_private.report_rows_snap) <> (select count(*) from public.rc_report_rows) then
    raise exception 'GAGAL: snapshot belum mengikuti view'; end if;
end $cek$;
