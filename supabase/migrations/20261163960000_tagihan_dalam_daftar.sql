-- ==========================================================================================
-- Tagihan ikut di dalam daftar (tab Open dan Document Center)
-- ==========================================================================================
-- Pemilik, 14 November 2026: "efisiensi workflow sesuai list sebelumnya".
--
-- Sebelumnya setiap pemuatan tab Open atau Document Center diikuti satu permintaan lagi,
-- rc_tagihan_dokumen, hanya untuk kolom Tagihan dan Final Billing Month. Itu permintaan paling
-- sering di sistem (257 dari 1.874 dalam 4 jam, 13 November 2026). Sekarang nilainya ikut di
-- setiap baris daftar ('tagihan'), dihitung fungsi yang sama (rc_private.tagihan_toko), sehingga
-- layar tidak perlu memanggil lagi. rc_tagihan_dokumen tetap ada untuk Analytics dan layar lama.
--
-- Hak: rc_private.tagihan_toko kini boleh dijalankan pengguna login, karena dua fungsi daftar
-- berjalan sebagai pemanggil. Skema rc_private tidak dibuka lewat API, jadi fungsi itu tetap
-- tidak dapat dipanggil langsung; baris daftar sudah disaring yurisdiksi pemanggil.
-- Saklar ZDAGE mati = kunci 'tagihan' tidak dikirim. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

grant execute on function rc_private.tagihan_toko(uuid, text) to authenticated;

do $tambal$
declare src text;
begin
  -- ---- Tab Open -------------------------------------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_open_claims_filtered(text,text,integer,integer,text)'::regprocedure), E'\r', '');
  if src !~ '20261163960000' then
    src := pg_temp.ganti(src, $p$'badDebt',coalesce(di.bad_debt,false),'badDebtAlasan',coalesce(di.bad_debt_reason,'')) as x$p$,
      $p$'badDebt',coalesce(di.bad_debt,false),'badDebtAlasan',coalesce(di.bad_debt_reason,''))
   -- 20261163960000: Tagihan ikut di baris, supaya layar tidak memanggil rc_tagihan_dokumen lagi.
   || case when v_zd then jsonb_build_object('tagihan', rc_private.tagihan_toko(c.depot_id, coalesce(cu.customer_code, c.source_customer_code)))
           else '{}'::jsonb end as x$p$, 1, 'open tagihan');
    execute src;
  end if;

  -- ---- Document Center ------------------------------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_compilation_list(text,text,text,text,integer,integer,text,date,date,integer)'::regprocedure), E'\r', '');
  if src !~ '20261163960000' then
    src := pg_temp.ganti(src, $p$cu.account_number, cu.account_name, cu.bank) /* 20261163390000 */ as x$p$,
      $p$cu.account_number, cu.account_name, cu.bank) /* 20261163390000 */
   -- 20261163960000: Tagihan ikut di baris, supaya layar tidak memanggil rc_tagihan_dokumen lagi.
   || case when (select rc_private.zdage_aktif()) then jsonb_build_object('tagihan', rc_private.tagihan_toko(c.depot_id, coalesce(cu.customer_code, c.source_customer_code)))
           else '{}'::jsonb end as x$p$, 1, 'document center tagihan');
    execute src;
  end if;
end $tambal$;

do $cek$
begin
  if pg_get_functiondef('public.rc_open_claims_filtered(text,text,integer,integer,text)'::regprocedure) !~ 'tagihan_toko' then raise exception 'GAGAL: open'; end if;
  if pg_get_functiondef('public.rc_compilation_list(text,text,text,text,integer,integer,text,date,date,integer)'::regprocedure) !~ 'tagihan_toko' then raise exception 'GAGAL: document center'; end if;
  if not has_function_privilege('authenticated', 'rc_private.tagihan_toko(uuid,text)', 'execute') then raise exception 'GAGAL: hak tagihan_toko'; end if;
  if has_function_privilege('anon', 'rc_private.tagihan_toko(uuid,text)', 'execute') then raise exception 'GAGAL: tagihan_toko terbuka untuk anon'; end if;
end $cek$;
