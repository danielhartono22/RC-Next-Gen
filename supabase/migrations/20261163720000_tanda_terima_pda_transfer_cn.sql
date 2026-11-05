-- ==========================================================================================
-- Tanda Terima: Tanggal Proses (PDA) hanya untuk Jenis CB Transfer dan CN
-- ==========================================================================================
-- Pemilik, 5 November 2026: "untuk tanggal proses cuma untuk transfer dan CN, lainnya ga".
--
-- Golongan klaim (20261163700000) kini:
--   PDA = Jenis CB Transfer atau CN DAN Tanggal Proses mulai 01-Oct-2026 -> tanggal dicetak;
--   PDH = selain itu (Rebate, Rebate Manual, Voucher, Others; atau tanggal sebelum batas / kosong).
-- Satu aturan di rc_private.docgen_kategori, dipakai rc_docgen_generate dan rc_docgen_list (Remark).
-- Butuh 20261163700000. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $pra$ begin
  if to_regprocedure('rc_private.docgen_batas_pda()') is null then raise exception 'DITOLAK: jalankan 20261163700000 lebih dulu.'; end if;
end $pra$;

create or replace function rc_private.docgen_kategori(p_tgl date, p_jenis text) returns text
language sql stable set search_path to '' as $f$
  select case when p_tgl >= rc_private.docgen_batas_pda() and rc_private.jenis_efektif(p_jenis) in ('transfer', 'cn') then 'PDA' else 'PDH' end;
$f$;

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('public.rc_docgen_generate(jsonb,text,jsonb)'::regprocedure), E'\r', '');
  if src !~ 'docgen_kategori' then
    src := pg_temp.ganti(src,
      $p$with gk as materialized (select x.*, case when x.tgl_done >= v_bt then 'PDA' else 'PDH' end kat$p$,
      $p$with gk as materialized (select x.*, rc_private.docgen_kategori(x.tgl_done, x.jenis_cb) /* 20261163720000: hanya Transfer / CN */ kat$p$,
      1, 'generate');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_docgen_list(text,jsonb,integer,integer,boolean)'::regprocedure), E'\r', '');
  if src !~ 'docgen_kategori' then
    src := pg_temp.ganti(src,
      $p$bool_or(k.tgl_done >= rc_private.docgen_batas_pda()) ada_pda,
           bool_or(k.tgl_done is null or k.tgl_done < rc_private.docgen_batas_pda()) ada_pdh$p$,
      $p$bool_or(rc_private.docgen_kategori(k.tgl_done, k.jenis_cb) = 'PDA') ada_pda, /* 20261163720000: hanya Transfer / CN */
           bool_or(rc_private.docgen_kategori(k.tgl_done, k.jenis_cb) = 'PDH') ada_pdh$p$,
      1, 'list');
    execute src;
  end if;
end $tambal$;

do $cek$ begin
  if rc_private.docgen_kategori(date '2026-10-07', 'Transfer') <> 'PDA' or rc_private.docgen_kategori(date '2026-10-07', 'CN') <> 'PDA'
     or rc_private.docgen_kategori(date '2026-10-07', 'Rebate') <> 'PDH' or rc_private.docgen_kategori(date '2026-10-07', 'Voucher') <> 'PDH'
     or rc_private.docgen_kategori(date '2026-10-07', 'Rebate Manual') <> 'PDH' or rc_private.docgen_kategori(date '2026-09-30', 'Transfer') <> 'PDH'
     or rc_private.docgen_kategori(null, 'CN') <> 'PDH' then
    raise exception 'GAGAL: aturan PDA / PDH'; end if;
end $cek$;
