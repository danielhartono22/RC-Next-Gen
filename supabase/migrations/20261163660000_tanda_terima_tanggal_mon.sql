-- ==========================================================================================
-- Tanda Terima: Tanggal Proses berformat dd-Mmm-yy (01-Jun-26)
-- ==========================================================================================
-- Pemilik, 4 November 2026: "untuk docgen udah sesuai tapi tanggal nya formatnya jadi dd-mmm-yy
-- contoh 01-Jun-26". Sebelumnya DD-MM-YY (20261163590000). Pemisah antartanggal tetap ", ".
-- Keterangan di bawah tabel diganti di 53-document-generator.js (PDF dibuat di browser).
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $tambal$
declare src text; f text := 'public.rc_docgen_generate(jsonb,text,jsonb)';
begin
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src ~ '20261163660000' then raise notice '% sudah ditambal.', f; return; end if;
  src := pg_temp.ganti(src,
    $p$(select string_agg(to_char(t, 'DD-MM-YY'), ', ' order by t)$p$,
    $p$(select string_agg(to_char(t, 'DD-Mon-YY') /* 20261163660000 */, ', ' order by t)$p$, 1, 'tglProses');
  execute src;
end $tambal$;
