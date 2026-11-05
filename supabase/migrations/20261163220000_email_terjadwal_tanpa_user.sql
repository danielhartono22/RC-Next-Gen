-- ==========================================================================================
-- Email terjadwal (Daily / Weekly) kembali berjalan: rc_email_susun tanpa user login
-- ==========================================================================================
-- Temuan 20 Oktober 2026 (prod): jadwal rc_email_tick pukul 07:05 WIB GAGAL setiap hari
-- setidaknya sejak 1 Oktober 2026 dengan "Akses tab access.email tidak diizinkan". Penjadwal
-- (pg_cron) berjalan tanpa user login, sedangkan rc_email_susun selalu memeriksa akses tab
-- pemanggilnya (20261152030000 / 20261162130000). Daily Report yang pernah terkirim seluruhnya
-- dikirim manual. Pemilik menyetujui perbaikan ini ("A. Jadwal email otomatis").
--
-- Perbaikan: pemeriksaan akses tab hanya untuk pemanggil yang login (auth.uid() terisi), pola
-- yang sama dengan rc_email_periksa (20261152050000). Tanpa user login hanya penjadwal / postgres:
-- fungsi ini tidak dapat dieksekusi anon (EXECUTE dicabut lagi di bawah sebagai jaminan), dan
-- setiap panggilan dari aplikasi membawa JWT user, jadi pemeriksaannya tetap berlaku di layar.
--
-- Penjaga MD5 pra-citra: sama di dev dan prod (20 Oktober 2026).
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
  src := replace(pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure), E'\r', '');
  if src ~ '20261163220000' then raise notice 'rc_email_susun sudah ditambal.'; return; end if;
  if md5(src) <> '2f318939e89a174d1249d1ea8fc0fa82' then
    raise exception 'DITOLAK: rc_email_susun berbeda dari yang diukur (md5 %).', md5(src); end if;

  src := pg_temp.ganti(src, $p$ perform rc_private.require_tab('access.email');
  if not rc_private.can_tab('access.email') /* 20261162130000 */ then
    raise exception 'Anda belum diberi akses Email Otomatis'
      using errcode='42501'; end if;$p$,
    $p$ -- 20261163220000: penjadwal (rc_email_tick lewat pg_cron) berjalan tanpa user login dan
  -- dulu selalu ditolak di sini. Pemeriksaan akses tab hanya untuk pemanggil yang login.
  if auth.uid() is not null then
 perform rc_private.require_tab('access.email');
  if not rc_private.can_tab('access.email') /* 20261162130000 */ then
    raise exception 'Anda belum diberi akses Email Otomatis'
      using errcode='42501'; end if;
  end if;$p$, 1, 'susun akses');
  execute src;
end $tambal$;

revoke execute on function public.rc_email_susun(text, boolean, text) from public, anon;

do $cek$
begin
  if pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure) !~ '20261163220000' then
    raise exception 'GAGAL: rc_email_susun belum ditambal'; end if;
  if has_function_privilege('anon', 'public.rc_email_susun(text,boolean,text)', 'execute') then
    raise exception 'GAGAL: anon masih dapat menjalankan rc_email_susun'; end if;
end $cek$;
