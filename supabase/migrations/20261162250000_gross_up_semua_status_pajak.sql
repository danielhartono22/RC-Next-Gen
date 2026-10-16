-- ==========================================================================================
-- Gross Up dihitung untuk semua status pajak; seluruh Rebate 0; disimpan bulat
-- ==========================================================================================
-- Pemilik, 12 Oktober 2026:
--   "Gross up sekarang dihitung untuk semua status pajak (baik customer ataupun pt nipsea
--    paint and chemicals / perusahaan) dan hitung semua gross up."
--   Rebate: "semua rebate baik 'rebate' atau 'rebate non tax' langsung 0".
--   Pembulatan: "Disimpan bulat".
--
-- ATURAN BARU
--   0  bila Jenis CB efektif dokumen Rebate atau Rebate Manual (RA07/RA7), atau Status Pajak
--      campaign Rebate Non Tax.
--   Selain itu - Customer, PT Nipsea Paint and Chemicals / Ditanggung Perusahaan, maupun
--   kosong - dihitung dengan rumus yang sama: Badan cashback / 0,85, selain itu progresif
--   (s.d. 57 jt / 0,95; s.d. 218,5 jt; s.d. 406 jt; s.d. 3,556 M; di atasnya).
--   Hasilnya DIPOTONG ke rupiah bulat (trunc), sama dengan yang tampil di layar.
--
--   Sebelumnya PT Nipsea / Ditanggung Perusahaan menghasilkan 0, Jenis CB Rebate dihitung
--   seperti biasa, dan hasilnya disimpan berdesimal.
--
-- DI MANA RUMUS DIPAKAI
--   rc_private.gross_claimed(cashback, subyek, status pajak)   rumus dasar (tanpa Jenis CB)
--   rc_private.gross_up_klaim(cashback, subyek, status pajak, jenis CB)   BARU, aturan lengkap
--   Pemakai yang dialihkan ke gross_up_klaim: compile (rc_private.compile_upload), submit
--   (rc_private.mutate_claims_unchecked), Reprocessing (public.rc_reprocessing_upload), dan
--   view public.rc_report_rows yang menjadi sumber Gross Claimed di Report dan Cost Center.
--
-- HITUNG ULANG. Gross Up setiap dokumen dihitung ulang dengan subyek pajak dan Jenis CB yang
-- tersimpan pada dokumen itu. version_no dan updated_at TIDAK diubah: Gross Up nilai turunan
-- yang tidak pernah ditulis layar, jadi layar yang sedang terbuka tidak perlu dipaksa memuat
-- ulang. Dokumen tanpa Customer Master dilewati - jaga_customer_master_klaim memang menolak
-- setiap perubahan atasnya; Report tetap menghitungnya lewat rc_report_rows.
--
-- Ditambal dengan penjaga MD5 pra-citra (sama di dev dan prod, 12 Oktober 2026).
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Rumus
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.gross_claimed(p_net numeric, p_subyek text, p_status_campaign text)
 returns numeric
 language sql
 immutable
as $function$
  -- 20261162250000: semua status pajak dihitung kecuali Rebate Non Tax; hasil dipotong bulat.
  select trunc(case
    when coalesce(p_net,0) <= 0 then 0
    -- "Rebate Non Tax", "Rebate Non-Tax", "Rebate NonTax": penulisan di master tidak seragam.
    when lower(coalesce(p_status_campaign,'')) ~ 'non[[:space:]_-]*tax' then 0
    when lower(btrim(coalesce(p_subyek,''))) = 'badan' then p_net / 0.85
    when p_net <= 57000000    then p_net / 0.95
    when p_net <= 218500000   then 60000000  + (p_net - 57000000)  / 0.85
    when p_net <= 406000000   then 250000000 + (p_net - 218500000) / 0.75
    when p_net <= 3556000000  then 500000000 + (p_net - 406000000) / 0.70
    else                           5000000000 + (p_net - 3556000000) / 0.65
  end);
$function$;

create or replace function rc_private.gross_up_klaim(p_net numeric, p_subyek text, p_status_campaign text, p_jenis text)
 returns numeric
 language sql
 immutable
as $function$
  -- 20261162250000: seluruh Rebate (Rebate dan Rebate Manual) tanpa gross up.
  select case when rc_private.jenis_efektif(p_jenis) in ('rebate', 'rebate manual') then 0
              else rc_private.gross_claimed(p_net, p_subyek, p_status_campaign) end;
$function$;
-- Izin sama dengan rc_private.gross_claimed: hanya pemilik dan authenticated (dibaca lewat view).
revoke all on function rc_private.gross_up_klaim(numeric, text, text, text) from public, anon;
grant execute on function rc_private.gross_up_klaim(numeric, text, text, text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Pemakai rumus
-- ------------------------------------------------------------------------------------------
do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  ('rc_private.compile_upload(jsonb,uuid)', 'c72a3df5469d1c94f96f0c0ed9dd3051',
   $p$rc_private.gross_claimed(v_cb,v_subject,v_camp.tax_status)$p$,
   $p$rc_private.gross_up_klaim(v_cb,v_subject,v_camp.tax_status,coalesce(nullif(v_jenis,''),v_camp.cashback_type)) /* 20261162250000 */$p$, 1),

  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '101c59845076ee607f1d629e8d8c4b23',
   $p$v_gross:=rc_private.gross_claimed(c.cb_net,subject,camp.tax_status);$p$,
   $p$v_gross:=rc_private.gross_up_klaim(c.cb_net,subject,camp.tax_status,jenis); -- 20261162250000$p$, 1),

  ('public.rc_reprocessing_upload(jsonb,text)', '36dc05c481ed42af7105b9bab27d9769',
   $p$v_subjek text; v_pajak text; v_gross numeric; -- 20261162240000$p$,
   $p$v_subjek text; v_pajak text; v_gross numeric; -- 20261162240000
  v_jenis_gu text; -- 20261162250000$p$, 1),
  ('public.rc_reprocessing_upload(jsonb,text)', '36dc05c481ed42af7105b9bab27d9769',
   $p$select coalesce(cu.tax_subject, c.tax_subject), ca.tax_status into v_subjek, v_pajak$p$,
   $p$select coalesce(cu.tax_subject, c.tax_subject), ca.tax_status,
           coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)
      into v_subjek, v_pajak, v_jenis_gu$p$, 1),
  ('public.rc_reprocessing_upload(jsonb,text)', '36dc05c481ed42af7105b9bab27d9769',
   $p$rc_private.gross_claimed(v_baru, v_subjek, v_pajak)$p$,
   $p$rc_private.gross_up_klaim(v_baru, v_subjek, v_pajak, v_jenis_gu)$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261162250000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(src, E'\r', '')); end if;
    baru := src;
    for r in select * from _tambal where sig = f.sig order by urut loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> r.n then
        raise exception '%: pola "%" ditemukan % kali, diharapkan %.', f.sig, left(r.lama, 80), n, r.n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
    execute baru;
  end loop;

  -- View sumber Report / Cost Center. CREATE OR REPLACE VIEW mempertahankan izin yang ada.
  src := pg_get_viewdef('public.rc_report_rows'::regclass, true);
  if src !~ 'gross_up_klaim' then
    if md5(src) <> '6b148da1561dbd2afb5debb751743756' then
      raise exception 'DITOLAK: definisi public.rc_report_rows berbeda dari yang diukur (md5 %).', md5(src); end if;
    baru := replace(src, 'rc_private.gross_claimed(c.cb_net, c.tax_subject, ca.tax_status) AS gross_claimed',
      'rc_private.gross_up_klaim(c.cb_net, c.tax_subject, ca.tax_status, COALESCE(NULLIF(c.cashback_type_override, ''''::text), ca.cashback_type)) AS gross_claimed');
    if baru = src then raise exception 'DITOLAK: kolom gross_claimed pada rc_report_rows tidak ditemukan.'; end if;
    execute 'create or replace view public.rc_report_rows as ' || baru;
  end if;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- 3. Hitung ulang seluruh Gross Up
-- ------------------------------------------------------------------------------------------
do $hitung$
declare n_ubah int; n_lewat int; v_sebelum numeric; v_sesudah numeric; v_rebate int; v_nipsea int;
begin
  select count(*) into n_lewat from public.claims where customer_id is null;
  create temp table _gu on commit drop as
    select c.id, c.gross_up lama,
           rc_private.gross_up_klaim(c.cb_net, c.tax_subject, ca.tax_status,
             coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) baru,
           rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('rebate', 'rebate manual') rebate,
           lower(coalesce(ca.tax_status, '')) like '%nipsea%' nipsea
      from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where c.customer_id is not null;

  select coalesce(sum(lama), 0), coalesce(sum(baru), 0),
         count(*) filter (where rebate and lama is distinct from baru),
         count(*) filter (where nipsea and not rebate and lama is distinct from baru)
    into v_sebelum, v_sesudah, v_rebate, v_nipsea from _gu;

  update public.claims c set gross_up = g.baru
    from _gu g where g.id = c.id and c.gross_up is distinct from g.baru;
  get diagnostics n_ubah = row_count;

  -- Pemeriksaan
  if exists(select 1 from public.claims c join public.campaigns ca on ca.id = c.campaign_id
             where c.customer_id is not null
               and c.gross_up is distinct from rc_private.gross_up_klaim(c.cb_net, c.tax_subject, ca.tax_status,
                     coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type))) then
    raise exception 'GAGAL: masih ada Gross Up yang tidak sesuai aturan baru.'; end if;
  if exists(select 1 from public.claims where gross_up <> trunc(gross_up)) then
    raise exception 'GAGAL: masih ada Gross Up berdesimal.'; end if;

  if n_ubah = 0 then raise notice 'Gross Up sudah sesuai aturan baru.'; return; end if;
  insert into public.activity_logs(actor_id, event_type, details)
  values (null, 'gross_up_dihitung_ulang', jsonb_build_object(
    'migrasi', '20261162250000', 'klaimDiubah', n_ubah, 'dilewatiTanpaCustomerMaster', n_lewat,
    'rebateMenjadiNol', v_rebate, 'ptNipseaKiniDihitung', v_nipsea,
    'totalSebelum', v_sebelum, 'totalSesudah', v_sesudah));
  raise notice 'Gross Up dihitung ulang: % klaim berubah (Rebate -> 0: %, PT Nipsea kini dihitung: %), total % -> %.',
    n_ubah, v_rebate, v_nipsea, v_sebelum, v_sesudah;
end
$hitung$;

-- ------------------------------------------------------------------------------------------
-- 4. Pemeriksaan rumus dan alur (dibatalkan seluruhnya)
-- ------------------------------------------------------------------------------------------
do $uji$
declare e text := ''; v_sm uuid; d record; hasil jsonb; v_gu numeric;
begin
  -- Rumus dasar dan aturan Rebate.
  if rc_private.gross_up_klaim(85000, 'Badan', 'PT Nipsea Paint and Chemicals', 'CN') <> 100000 then e := e || ' Nipsea Badan;'; end if;
  if rc_private.gross_up_klaim(57000000, 'Perorangan', 'PT Nipsea Paint And Chemicals', 'Transfer') <> 60000000 then e := e || ' Nipsea Perorangan;'; end if;
  if rc_private.gross_up_klaim(85000, 'Badan', 'Customer', 'Transfer') <> 100000 then e := e || ' Customer Badan;'; end if;
  if rc_private.gross_up_klaim(1000000, 'Badan', 'Customer', 'Rebate') <> 0 then e := e || ' Rebate;'; end if;
  if rc_private.gross_up_klaim(1000000, 'Badan', 'Customer', 'RA07') <> 0 then e := e || ' Rebate Manual;'; end if;
  if rc_private.gross_up_klaim(1000000, 'Badan', 'Rebate Non Tax', 'Transfer') <> 0 then e := e || ' Non Tax;'; end if;
  if rc_private.gross_up_klaim(1000000, 'Badan', 'Customer', 'Transfer') <> 1176470 then e := e || ' pembulatan;'; end if;
  if rc_private.gross_up_klaim(1000000, null, null, null) <> 1052631 then e := e || ' subyek/status kosong;'; end if;

  -- Reprocessing memakai aturan baru (dokumen Not Yet ditahan sementara, lalu dibatalkan).
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  if v_sm is not null then
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
      for d in
        select distinct on (rebate) * from (
          select c.id, c.no_doc, c.tax_subject, ca.tax_status, coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type) jenis,
                 rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('rebate', 'rebate manual') rebate
            from public.claims c join public.campaigns ca on ca.id = c.campaign_id and ca.status = 'active'
           where c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null and c.customer_id is not null) x
         order by rebate, no_doc
      loop
        update public.claims set status = 'on_hold', previous_status = 'not_yet' where id = d.id;
        hasil := public.rc_reprocessing_upload(jsonb_build_array(jsonb_build_object('noDoc', d.no_doc, 'totalCashback', '1000000.9')), 'uji');
        select gross_up into v_gu from public.claims where id = d.id;
        if (hasil->>'berhasil')::int <> 1
           or v_gu is distinct from rc_private.gross_up_klaim(1000000, d.tax_subject, d.tax_status, d.jenis)
           or (d.rebate and v_gu <> 0) or v_gu <> trunc(v_gu) then
          e := e || format(' reprocessing %s (%s) gross %s;', d.no_doc, d.jenis, v_gu); end if;
      end loop;
      raise exception 'UJI_SELESAI';
    exception when others then
      if sqlerrm <> 'UJI_SELESAI' then e := e || ' galat: ' || sqlerrm; end if;
    end;
    perform set_config('request.jwt.claims', '', true);
  end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;

-- Dashboard publik memuat Gross Claimed; disegarkan supaya tidak menunggu jadwal berikutnya.
do $segar$ begin
  if to_regprocedure('rc_private.segarkan_dashboard_publik()') is not null then
    perform rc_private.segarkan_dashboard_publik();
  end if;
end $segar$;
