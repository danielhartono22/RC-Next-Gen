-- ==========================================================================================
-- Gross Up Rebate dan Rebate Manual = Cashback x 1,11 (Cashback + PPN 11%)
-- ==========================================================================================
-- Pemilik, 22 Oktober 2026 (saat merancang Ad-Hoc Process): "jika rebate x 11% sesuai ppn",
-- dijawab "CB x 1,11 (CB + PPN 11%)"; lalu "ini semua yang rebate gross up nya udah dikali
-- 11% termasuk rebate manual? jika belum overwrite ya".
--
-- ATURAN BARU (rc_private.gross_up_klaim)
--   Jenis CB efektif Rebate atau Rebate Manual (RA07/RA7): trunc(cashback x 1,11), apa pun
--     subyek pajak dan Status Pajak campaign-nya - termasuk Rebate Non Tax.
--   Voucher: tetap 0 (20261163120000).
--   Selain itu tidak berubah: Status Pajak Rebate Non Tax 0; Badan cashback / 0,85;
--     Perorangan progresif (rc_private.gross_claimed).
--   Sebelumnya (20261162250000) seluruh Rebate dan Rebate Manual bernilai 0.
--
-- Rumus ini dipakai compile, submit, Reprocessing, Amend Doc, penautan Customer Master, dan
-- view public.rc_report_rows (Report, Cost Center, Dashboard), jadi semuanya ikut tanpa tambal.
--
-- TIMPA. Gross up tersimpan setiap dokumen Rebate / Rebate Manual dihitung ulang, termasuk
-- yang sudah Done, Expired, dan diarsipkan. version_no dan updated_at TIDAK diubah (nilai
-- turunan, sama seperti 20261162250000). Dokumen tanpa Customer Master dilewati karena
-- jaga_customer_master_klaim menolak perubahan atasnya; Report tetap menghitungnya lewat view.
-- ==========================================================================================

create or replace function rc_private.gross_up_klaim(p_net numeric, p_subyek text, p_status_campaign text, p_jenis text)
 returns numeric
 language sql
 immutable
as $function$
  -- 20261162250000: seluruh Rebate (Rebate dan Rebate Manual) tanpa gross up.
  -- 20261163120000: Voucher juga tanpa gross up.
  -- 20261163430000: Rebate dan Rebate Manual = cashback x 1,11 (PPN 11%), dipotong bulat.
  select case
    when rc_private.jenis_efektif(p_jenis) in ('rebate', 'rebate manual') then trunc(greatest(coalesce(p_net, 0), 0) * 1.11)
    when rc_private.jenis_efektif(p_jenis) = 'voucher' then 0
    else rc_private.gross_claimed(p_net, p_subyek, p_status_campaign) end;
$function$;

-- ------------------------------------------------------------------------------------------
-- Timpa gross up tersimpan
-- ------------------------------------------------------------------------------------------
do $hitung$
declare n_ubah int; n_lewat int; v_sebelum numeric; v_sesudah numeric;
begin
  create temp table _gu on commit drop as
    select c.id, c.customer_id, c.gross_up lama, rc_private.gross_up_klaim(c.cb_net, c.tax_subject, ca.tax_status, j.jenis) baru
      from public.claims c join public.campaigns ca on ca.id = c.campaign_id
      cross join lateral (select coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type) jenis) j
     where rc_private.jenis_efektif(j.jenis) in ('rebate', 'rebate manual');

  select count(*) filter (where customer_id is null and lama is distinct from baru) into n_lewat from _gu;
  select coalesce(sum(lama) filter (where customer_id is not null), 0), coalesce(sum(baru) filter (where customer_id is not null), 0)
    into v_sebelum, v_sesudah from _gu;

  update public.claims c set gross_up = g.baru
    from _gu g where g.id = c.id and g.customer_id is not null and c.gross_up is distinct from g.baru;
  get diagnostics n_ubah = row_count;

  if exists(select 1 from public.claims c join _gu g on g.id = c.id
             where g.customer_id is not null and c.gross_up is distinct from g.baru) then
    raise exception 'GAGAL: masih ada gross up Rebate / Rebate Manual yang belum x 1,11.'; end if;

  if n_ubah = 0 then raise notice 'Gross up Rebate / Rebate Manual sudah x 1,11.'; return; end if;
  insert into public.activity_logs(actor_id, event_type, details)
  values (null, 'gross_up_dihitung_ulang', jsonb_build_object(
    'migrasi', '20261163430000',
    'detail', 'Gross up Rebate dan Rebate Manual menjadi cashback x 1,11 (PPN 11%): ' || n_ubah || ' dokumen',
    'klaimDiubah', n_ubah, 'dilewatiTanpaCustomerMaster', n_lewat,
    'totalSebelum', v_sebelum, 'totalSesudah', v_sesudah));
  raise notice 'Gross up Rebate / Rebate Manual ditimpa: % dokumen (lewat tanpa master %), total % -> %.',
    n_ubah, n_lewat, v_sebelum, v_sesudah;
end
$hitung$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan rumus (tidak mengubah data)
-- ------------------------------------------------------------------------------------------
do $uji$
declare e text := '';
begin
  if rc_private.gross_up_klaim(1000000, 'Badan', 'Customer', 'Rebate') <> 1110000 then e := e || ' Rebate;'; end if;
  if rc_private.gross_up_klaim(1000000, 'Perorangan', 'Customer', 'Rebate Manual') <> 1110000 then e := e || ' Rebate Manual;'; end if;
  if rc_private.gross_up_klaim(1000000, null, null, 'RA07') <> 1110000 then e := e || ' RA07;'; end if;
  if rc_private.gross_up_klaim(1000000, 'Badan', 'Rebate Non Tax', 'Rebate') <> 1110000 then e := e || ' Rebate Non Tax;'; end if;
  if rc_private.gross_up_klaim(999, 'Badan', 'Customer', 'Rebate') <> 1108 then e := e || ' pembulatan;'; end if;
  if rc_private.gross_up_klaim(-5, 'Badan', 'Customer', 'Rebate') <> 0 then e := e || ' negatif;'; end if;
  if rc_private.gross_up_klaim(1000000, 'Badan', 'Customer', 'Voucher') <> 0 then e := e || ' Voucher;'; end if;
  if rc_private.gross_up_klaim(85000, 'Badan', 'Customer', 'Transfer') <> 100000 then e := e || ' Transfer;'; end if;
  if rc_private.gross_up_klaim(1000000, 'Badan', 'Rebate Non Tax', 'Transfer') <> 0 then e := e || ' Non Tax Transfer;'; end if;
  if e <> '' then raise exception 'GAGAL rumus:%', e; end if;
end
$uji$;
