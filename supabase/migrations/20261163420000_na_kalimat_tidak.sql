-- ==========================================================================================
-- Email Not Achieved: kalimat pembuka "gagal mencapai target" menjadi "tidak mencapai target".
-- Pemilik, 22 Oktober 2026: "gagal ganti tidak". Badan email dan lampiran PDF.
-- Bergantung pada 20261163410000.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $tambal$
declare src text; f text;
begin
  foreach f in array array['rc_private.email_na_html(jsonb,timestamptz,timestamptz)', 'rc_private.email_na_pdf_html(jsonb,timestamptz,timestamptz)'] loop
    src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
    if position('dikonfirmasi gagal mencapai target' in src) > 0 then
      src := pg_temp.ganti(src, 'dikonfirmasi gagal mencapai target', 'dikonfirmasi tidak mencapai target', 1, f);
      execute src;
    end if;
  end loop;
end $tambal$;
