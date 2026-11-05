-- ==========================================================================================
-- Document Generator: tab Not Yet ditiadakan, tinggal tab Done
-- ==========================================================================================
-- Pemilik, 4 November 2026: "untuk di docgen gada tab not yet lagi".
--
-- * Tab docgen.notyet dihapus dari katalog tab beserta centang per user (user_tab_access);
--   layar tidak lagi menampilkannya dan Access Management tidak lagi mendaftarnya.
-- * Server menolak sumber 'notyet' di rc_docgen_list / rc_docgen_generate dengan pesan jelas.
-- * Jejak unduh lama berasal Not Yet (rc_form_verifikasi.sumber = 'notyet') TIDAK dihapus;
--   nomor TT tetap satu deret per depot per hari.
-- Aman dijalankan berulang.
-- ==========================================================================================

do $pra$
declare v_md5 text := md5(replace(pg_get_functiondef('rc_private.docgen_tab(text)'::regprocedure), E'\r', ''));
begin
  if pg_get_functiondef('rc_private.docgen_tab(text)'::regprocedure) ~ '20261163690000' then raise notice 'docgen_tab sudah diubah.'; return; end if;
  if v_md5 <> '7aab115bf1f3e5e40e121861c89e3052' then
    raise exception 'DITOLAK: definisi rc_private.docgen_tab berbeda dari yang diukur (md5 %).', v_md5; end if;
end $pra$;

create or replace function rc_private.docgen_tab(p_sumber text)
returns text language plpgsql immutable set search_path to '' as $function$
begin
  if p_sumber = 'done' then return 'docgen.done'; end if;
  -- 20261163690000: tab Not Yet ditiadakan (pemilik, 4 November 2026).
  if p_sumber = 'notyet' then raise exception 'Tab Not Yet Document Generator sudah ditiadakan; gunakan tab Done.'; end if;
  raise exception 'Sumber form tidak dikenal: %', p_sumber;
end $function$;

do $hapus$
declare n integer;
begin
  delete from rc_private.user_tab_access where tab_code = 'docgen.notyet';
  get diagnostics n = row_count;
  delete from rc_private.tab_catalog where code = 'docgen.notyet';
  raise notice 'Tab docgen.notyet dihapus (% centang user ikut dihapus).', n;
end $hapus$;

do $cek$ begin
  if exists (select 1 from rc_private.tab_catalog where code = 'docgen.notyet') then raise exception 'GAGAL: tab masih ada'; end if;
  if not exists (select 1 from rc_private.tab_catalog where code = 'docgen.done') then raise exception 'GAGAL: tab Done hilang'; end if;
end $cek$;
