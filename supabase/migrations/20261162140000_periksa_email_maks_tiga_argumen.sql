-- ==========================================================================================
-- rc_private.periksa_email_maks(teks, nama, maks): versi tiga argumen yang hanya ada di prod
-- ==========================================================================================
-- Ditemukan 6 Oktober 2026 saat seluruh definisi fungsi dev dan prod dibandingkan setelah
-- transport: public.rc_depot_save (identik di kedua lingkungan) memanggil
-- periksa_email_maks(..., 4) dan (..., 20), tetapi versi tiga argumen itu dibuat langsung di
-- prod dan tidak pernah tercatat di berkas migrasi. Akibatnya menyimpan Depot Master di dev
-- gagal "function does not exist".
--
-- Definisinya disalin PERSIS dari prod (snapshot .runtime/prod-snapshot-20261006), sehingga
-- menjalankannya di prod tidak mengubah apa pun. Versi dua argumen dibiarkan apa adanya.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.periksa_email_maks(p_teks text, p_nama text, p_maks integer default 4)
returns text language plpgsql immutable set search_path to '' as $function$
declare n integer;
begin
  if coalesce(btrim(p_teks),'') = '' then return null; end if;
  n := coalesce(array_length(rc_private.pecah_email(p_teks),1),0);
  if n = 0 then
    raise exception 'Kolom % tidak memuat satu pun alamat email yang sah', p_nama; end if;
  if n > p_maks then
    raise exception 'Kolom % memuat % alamat; maksimal %', p_nama, n, p_maks; end if;
  return btrim(p_teks);
end $function$;
-- Hak eksekusinya juga sama dengan prod: hanya pemilik. Pemanggilnya rc_depot_save, yang
-- berjalan SECURITY DEFINER.
revoke all on function rc_private.periksa_email_maks(text,text,integer) from public, anon, authenticated;
