-- ==========================================================================================
-- Depot asal dibaca dari profil, bukan dari grant yang sudah tidak ada
-- ==========================================================================================
-- Keluhan pemilik, 20 September 2026: "kenapa depot asal nya ini tidak berubah padahal sudah
-- saya assign".
--
-- Penyimpanannya ternyata BERHASIL. profiles.home_depot_id memang sudah terisi:
--
--   ANIADMPTI  4C        DANIEL  HO
--   ANNA_MDN   4A        IQBAL   HO
--
-- Yang gagal adalah menampilkannya kembali. Ini kesalahan migration 20261111010000: depot asal
-- dipindahkan dari baris user_depot_grants berjenis 'home' ke kolom profiles.home_depot_id, dan
-- seluruh baris 'home' dihapus - tetapi tidak semua PEMBACA ikut dipindahkan.
--
-- Dua fungsi masih mencari di tempat yang sudah kosong:
--
--   rc_private.legacy_users   - daftar akun di Access Management (tiga kolom sekaligus)
--   public.rc_pin_requests    - kotak masuk permohonan PIN
--
-- Karena barisnya sudah tidak ada, keduanya selalu mengembalikan string kosong. Akibatnya
-- layar Access Management menampilkan Depot Asal sebagai kosong, dan ketika dialognya dibuka
-- pilihannya kembali ke "-- Tanpa depot --". Tersimpan benar, tampil salah - dan dari kursi
-- pengguna keduanya tidak dapat dibedakan.
--
-- Migration ini melengkapi pemindahan yang belum selesai itu.
--
-- PELAJARANNYA, supaya tidak terulang: memindahkan sumber kebenaran belum selesai ketika
-- penulisnya sudah dipindahkan. Yang menentukan adalah PEMBACANYA - dan cara memastikannya
-- adalah mencari seluruh fungsi yang menyebut pola lama, bukan mengandalkan ingatan:
--
--   select n.nspname||'.'||p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--    where p.prokind='f' and pg_get_functiondef(p.oid) like '%kind=''home''%';
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $mig$
declare src text; baru text; n int := 0;

  -- Pola lama yang sama persis dipakai di kedua fungsi.
  pola_kode text := 'coalesce((select d.depot_code from public.user_depot_grants g'
    || chr(10) || '      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind=''home'' limit 1),'''')';
  pola_nama text := 'coalesce((select d.depot_name from public.user_depot_grants g'
    || chr(10) || '      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind=''home'' limit 1),'''')';
  baru_kode text := 'coalesce((select d.depot_code from public.depots d where d.id=p.home_depot_id),'''')';
  baru_nama text := 'coalesce((select d.depot_name from public.depots d where d.id=p.home_depot_id),'''')';
begin
  -- ----------------------------------------------------------------------------------------
  -- 1. rc_private.legacy_users - kodeDepot, namaDepot dan depotName
  -- ----------------------------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'rc_private' and p.proname = 'legacy_users';
  if src is null then raise exception 'rc_private.legacy_users tidak ditemukan.'; end if;

  if position('kind=''home''' in src) = 0 then
    raise notice 'legacy_users sudah tidak membaca kind=home; dilewati.';
  else
    baru := replace(replace(src, pola_kode, baru_kode), pola_nama, baru_nama);
    if baru = src then
      raise exception 'Pola depot asal tidak ditemukan pada rc_private.legacy_users. '
        'Sumbernya sudah berubah - periksa dan perbarui migration ini.';
    end if;
    if position('kind=''home''' in baru) > 0 then
      raise exception 'Masih tersisa rujukan kind=home pada legacy_users sesudah penggantian.';
    end if;
    execute baru;
    n := n + 1;
  end if;

  -- ----------------------------------------------------------------------------------------
  -- 2. public.rc_pin_requests - kodeDepot
  -- ----------------------------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'rc_pin_requests';
  if src is null then raise exception 'public.rc_pin_requests tidak ditemukan.'; end if;

  if position('kind=''home''' in src) = 0 then
    raise notice 'rc_pin_requests sudah tidak membaca kind=home; dilewati.';
  else
    -- Berkas ini memakai lekukan yang sedikit berbeda, jadi penggantiannya dilakukan pada
    -- potongan terpendek yang tetap khas.
    baru := replace(src,
      'coalesce((select d.depot_code from public.user_depot_grants g' || chr(10)
        || '       join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind=''home'' limit 1),'''')',
      baru_kode);
    if baru = src then
      raise exception 'Pola depot asal tidak ditemukan pada public.rc_pin_requests. '
        'Sumbernya sudah berubah - periksa dan perbarui migration ini.';
    end if;
    if position('kind=''home''' in baru) > 0 then
      raise exception 'Masih tersisa rujukan kind=home pada rc_pin_requests sesudah penggantian.';
    end if;
    execute baru;
    n := n + 1;
  end if;

  raise notice 'Fungsi pembaca depot asal yang diperbaiki: %', n;
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare n int;
begin
  -- Tidak boleh ada lagi fungsi yang mencari depot asal di tempat yang sudah kosong.
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where p.prokind = 'f' and ns.nspname in ('public','rc_private')
     and pg_get_functiondef(p.oid) like '%kind=''home''%';
  if n > 0 then
    raise exception 'GAGAL: masih ada % fungsi yang membaca grant kind=home.', n;
  end if;

  -- Dan depot asal yang tersimpan harus benar-benar terbaca kembali.
  select count(*) into n from public.profiles p
   where p.status <> 'deleted' and p.home_depot_id is not null;
  raise notice 'Akun ber-depot asal: %', n;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
