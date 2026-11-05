-- ==========================================================================================
-- Document Center: saringan Tahun Campaign + Pilih semua hasil sampai 10.000 baris
-- ==========================================================================================
-- Pemilik, 5 November 2026: "untuk batas download bisa naikan jadi 10 ribu untuk doc center? dan
-- tambahkan filter tahun campaign".
-- * rc_compilation_list mendapat p_tahun: tahun periode campaign, sama dengan "Tahun Campaign" di
--   Claim Process (extract(year from coalesce(c.period_start, ca.period_start))). 0 = periode
--   campaign kosong (prod 05-Nov: 1.525 dokumen); null = semua tahun.
-- * Satu panggilan kini paling banyak 2.000 baris (dulu 500), supaya Pilih semua hasil 10.000 baris
--   cukup 5 panggilan, bukan 20 (setiap panggilan juga menghitung total).
-- Signature lama (9 argumen) dibuang; hak akses sama: authenticated dan service_role saja.
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
declare src text;
begin
  if to_regprocedure('public.rc_compilation_list(text,text,text,text,integer,integer,text,date,date,integer)') is not null then
    raise notice 'rc_compilation_list sudah punya p_tahun.'; return; end if;
  src := replace(pg_get_functiondef('public.rc_compilation_list(text,text,text,text,integer,integer,text,date,date)'::regprocedure), E'\r', '');
  src := pg_temp.ganti(src,
    $p$p_dibuat_sampai date DEFAULT NULL::date)$p$,
    $p$p_dibuat_sampai date DEFAULT NULL::date, p_tahun integer DEFAULT NULL::integer)$p$, 1, 'signature');
  src := pg_temp.ganti(src,
    $p$-- 20261163090000: p_dibuat_dari / p_dibuat_sampai = tanggal Created On (Asia/Jakarta, inklusif).$p$,
    $p$-- 20261163090000: p_dibuat_dari / p_dibuat_sampai = tanggal Created On (Asia/Jakarta, inklusif).
-- 20261163770000: p_tahun = Tahun Campaign (tahun periode campaign; 0 = periode kosong); maks. 2.000 baris per panggilan.$p$, 1, 'komentar');
  src := pg_temp.ganti(src,
    $p$    and (v_sampai is null or c.created_at < v_sampai)
$p$,
    $p$    and (v_sampai is null or c.created_at < v_sampai)
    and (p_tahun is null or case when p_tahun = 0 then coalesce(c.period_start, ca.period_start) is null
                                 else extract(year from coalesce(c.period_start, ca.period_start)) = p_tahun end)
$p$, 2, 'saringan tahun');
  src := pg_temp.ganti(src,
    $p$limit least(greatest(coalesce(p_limit,100),1),500)$p$,
    $p$limit least(greatest(coalesce(p_limit,100),1),2000)$p$, 1, 'batas');
  execute src;
  drop function public.rc_compilation_list(text, text, text, text, integer, integer, text, date, date);
end $tambal$;

revoke all on function public.rc_compilation_list(text, text, text, text, integer, integer, text, date, date, integer) from public, anon;
grant execute on function public.rc_compilation_list(text, text, text, text, integer, integer, text, date, date, integer) to authenticated, service_role;

do $cek$ begin
  if to_regprocedure('public.rc_compilation_list(text,text,text,text,integer,integer,text,date,date)') is not null then raise exception 'GAGAL: signature lama masih ada'; end if;
  if pg_get_functiondef('public.rc_compilation_list(text,text,text,text,integer,integer,text,date,date,integer)'::regprocedure) !~ 'p_tahun = 0' then raise exception 'GAGAL: saringan tahun'; end if;
  if has_function_privilege('anon', 'public.rc_compilation_list(text,text,text,text,integer,integer,text,date,date,integer)', 'execute') then raise exception 'GAGAL: anon boleh menjalankan'; end if;
end $cek$;
