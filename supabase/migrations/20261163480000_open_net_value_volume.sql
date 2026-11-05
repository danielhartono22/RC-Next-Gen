-- ==========================================================================================
-- Tab Open: Net Value dan Volume ikut dikirim (tampil sebagai kolom bawaan)
-- ==========================================================================================
-- Pemilik, 27 Oktober 2026: "tampilkan net value dan volume di open, bukan default harus
-- dikeluarkan di pilih kolom terdahulu." Nilainya dari dokumen klaim (claims.net_value, volume).
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $tambal$
declare src text; f text := 'public.rc_open_claims_filtered(text,text,integer,integer,text)';
begin
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163480000' then
    src := pg_temp.ganti(src, $p$'cbNet',c.cb_net,'dcCode',d.depot_code,'depotName',d.depot_name,$p$,
      $p$'cbNet',c.cb_net,'dcCode',d.depot_code,'depotName',d.depot_name,
   'netValue',coalesce(c.net_value,0),'volume',coalesce(c.volume,0), /* 20261163480000 */$p$, 1, f);
    execute src;
  end if;
end $tambal$;
