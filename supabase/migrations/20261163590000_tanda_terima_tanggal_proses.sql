-- ==========================================================================================
-- Tanda Terima: kolom Tanggal Proses (tanggal Clearing yang dipilih pengguna)
-- ==========================================================================================
-- Pemilik, 30 Oktober 2026: "tambahkan tanggal proses actual (sesuai pemilihan tanggal di
-- clearing) di tanda terima. letaknya paling akhir aja formatnya dd-mm-yy , dd-mm-yy. nama
-- kolomnya tanggal proses."
--
--   Setiap baris form (campaign x Jenis CB) membawa tglProses: tanggal Done (claims.cleared_at,
--   WIB - tanggal yang dipilih di Clearing, 20261163130000) seluruh klaim baris itu, berbeda-beda
--   diurutkan, format DD-MM-YY dipisah ", ". Klaim Not Yet belum punya tanggal -> kosong.
--   Kolom digambar paling kanan di PDF (53-document-generator.js).
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
  if to_regprocedure(f) is null then raise exception 'DITOLAK: jalankan 20261163550000 lebih dulu.'; end if;
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src ~ '20261163590000' then raise notice '% sudah ditambal.', f; return; end if;
  src := pg_temp.ganti(src,
    $p$  gp as (select gk.depot_id, gk.customer_id, gk.campaign_id, gk.jenis_cb, trunc(sum(gk.cb_net)) cb from gk group by 1, 2, 3, 4),$p$,
    $p$  gp as (select gk.depot_id, gk.customer_id, gk.campaign_id, gk.jenis_cb, trunc(sum(gk.cb_net)) cb,
                -- 20261163590000: tanggal proses (Clearing) klaim baris ini, DD-MM-YY dipisah koma.
                (select string_agg(to_char(t, 'DD-MM-YY'), ', ' order by t) from unnest(array_agg(distinct gk.tgl_done)) t where t is not null) tgl
           from gk group by 1, 2, 3, 4),$p$, 1, 'gp');
  src := pg_temp.ganti(src,
    $p$'taxStatus', coalesce(ca.tax_status, '')) order by ca.campaign_code, gp.jenis_cb) baris$p$,
    $p$'taxStatus', coalesce(ca.tax_status, ''), 'tglProses', coalesce(gp.tgl, '')) order by ca.campaign_code, gp.jenis_cb) baris$p$, 1, 'baris');
  execute src;
end $tambal$;

do $cek$ begin
  if pg_get_functiondef('public.rc_docgen_generate(jsonb,text,jsonb)'::regprocedure) !~ 'tglProses' then raise exception 'GAGAL: tglProses'; end if;
end $cek$;
