-- ==========================================================================================
-- Daftar Document Generator lebih ringan + batas 1.000 baris per file bank
-- ==========================================================================================
-- Pemilik, 5 November 2026 ("ok lanjut"), sesudah pengukuran beban:
-- * rc_docgen_list memanggil rc_private.docgen_kategori tiga kali per klaim Done (Remark PDA / PDH /
--   PP). Fungsi itu memakai SET search_path sehingga tidak dapat di-inline: ±8 mikrodetik per panggilan,
--   di prod (23.862 klaim Done) ±0,5-0,7 s tambahan setiap daftar dibuka oleh pengguna semua depot.
--   Aturan yang sama kini ditulis langsung di kueri (tanggal batas dibaca sekali ke variabel,
--   rc_private.jenis_efektif dapat di-inline). rc_private.docgen_kategori tetap sumber aturan untuk
--   rc_docgen_generate; uji rc_tanda_terima_pda_pdh membandingkan keduanya.
-- * rc_clearing_bank_preview: maksimal 1.000 baris per file (sebelumnya 5.000). Pemeriksaan duplikat
--   membandingkan setiap baris dengan seluruh baris; 1.000 baris ±5 s, file harian KlikBCA ±200 baris.
-- Butuh 20261163750000. Aman dijalankan berulang.
-- ==========================================================================================

do $pra$ begin
  if pg_get_functiondef('public.rc_clearing_bank_preview(text,text,integer,text,jsonb,text)'::regprocedure) !~ 'otomatis' then
    raise exception 'DITOLAK: jalankan 20261163750000 lebih dulu.'; end if;
end $pra$;

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('public.rc_docgen_list(text,jsonb,integer,integer,boolean)'::regprocedure), E'\r', '');
  if src ~ 'docgen_kategori' then
    src := pg_temp.ganti(src,
      $p$  v jsonb; v_rows jsonb; v_toko jsonb; v_camp_map jsonb;$p$,
      $p$  v jsonb; v_rows jsonb; v_toko jsonb; v_camp_map jsonb;
  v_bt date := rc_private.docgen_batas_pda(); -- 20261163760000: aturan PDA ditulis langsung (sama dengan fungsi kategori Tanda Terima)$p$,
      1, 'list declare');
    src := pg_temp.ganti(src,
      $p$rc_private.docgen_kategori(k.tgl_done, k.jenis_cb) = 'PDA'$p$,
      $p$(coalesce(k.tgl_done >= v_bt, false) and rc_private.jenis_efektif(k.jenis_cb) in ('transfer', 'cn'))$p$, 2, 'list PDA');
    src := pg_temp.ganti(src,
      $p$rc_private.docgen_kategori(k.tgl_done, k.jenis_cb) = 'PDH'$p$,
      $p$not (coalesce(k.tgl_done >= v_bt, false) and rc_private.jenis_efektif(k.jenis_cb) in ('transfer', 'cn'))$p$, 1, 'list PDH');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_clearing_bank_preview(text,text,integer,text,jsonb,text)'::regprocedure), E'\r', '');
  if src ~ '> 5000' then
    src := pg_temp.ganti(src,
      $p$  if jsonb_array_length(p_baris) > 5000 then raise exception 'Maksimal 5.000 baris per file'; end if;$p$,
      $p$  if jsonb_array_length(p_baris) > 1000 then raise exception 'Maksimal 1.000 baris per file (file harian KlikBCA sekitar 200 baris). Pecah file yang lebih besar.'; end if; -- 20261163760000$p$,
      1, 'preview batas');
    execute src;
  end if;
end $tambal$;

do $cek$ begin
  if pg_get_functiondef('public.rc_docgen_list(text,jsonb,integer,integer,boolean)'::regprocedure) ~ 'docgen_kategori' then raise exception 'GAGAL: list'; end if;
  if pg_get_functiondef('public.rc_clearing_bank_preview(text,text,integer,text,jsonb,text)'::regprocedure) !~ '> 1000' then raise exception 'GAGAL: preview'; end if;
end $cek$;
