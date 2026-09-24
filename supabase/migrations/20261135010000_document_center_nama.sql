-- ==========================================================================================
-- "Cashback Compilation" menjadi "Document Center" di konsol hak akses
-- ==========================================================================================
-- Modulnya sudah dinamai ulang di layar, tetapi pemilik menemukan namanya belum berubah pada
-- daftar hak akses: "Pada hak menu dashboard nama cashback compilation belum berubah menjadi
-- Document Center, sinkronisasikan dan perbaiki jika ada salah".
--
-- Sebabnya nama itu tidak tinggal di markup. Matriks izin pada Access Management digambar dari
-- public.rc_permission_catalog(), dan katalog itu menyimpan nama modulnya sendiri - jadi
-- mengganti judul di HTML tidak menyentuhnya sama sekali. Uraian pada tabel public.permissions
-- pun masih memakai nama lama.
--
-- Kode izinnya TIDAK ikut diganti. view_compilation dan archive_compilation sudah tersimpan pada
-- hak setiap akun; mengganti kodenya berarti memindahkan data hak akses, dan itu risiko yang
-- tidak sebanding untuk sebuah penggantian nama. Yang dilihat orang adalah labelnya.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

update public.permissions
   set description = 'Lihat Document Center'
 where code = 'view_compilation' and description is distinct from 'Lihat Document Center';

update public.permissions
   set description = 'Arsipkan baris pada Document Center'
 where code = 'archive_compilation'
   and description is distinct from 'Arsipkan baris pada Document Center';

do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rc_permission_catalog';
  if src is null then raise exception 'public.rc_permission_catalog tidak ditemukan.'; end if;

  if position('Cashback Compilation' in src) = 0 then
    raise notice 'Katalog izin sudah memakai nama baru; dilewati.';
    return;
  end if;

  baru := replace(src, '''modul'',''Cashback Compilation''', '''modul'',''Document Center''');
  if baru = src then
    raise exception 'Pola nama modul tidak ditemukan pada rc_permission_catalog. '
      'Sumbernya sudah berubah - periksa dan perbarui migration ini.';
  end if;
  execute baru;
  raise notice 'Katalog izin memakai nama Document Center.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text; n int;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'public' and p.proname = 'rc_permission_catalog';

  if position('Cashback Compilation' in src) > 0 then
    raise exception 'GAGAL: katalog izin masih menyebut Cashback Compilation.'; end if;
  if position('Document Center' in src) = 0 then
    raise exception 'GAGAL: katalog izin tidak menyebut Document Center.'; end if;

  select count(*) into n from public.permissions where description ilike '%cashback compilation%';
  if n > 0 then
    raise exception 'GAGAL: % uraian izin masih memakai nama lama.', n; end if;

  -- Kodenya harus TETAP, supaya hak yang sudah diberikan tidak hilang.
  if not exists (select 1 from public.permissions where code = 'view_compilation') then
    raise exception 'GAGAL: kode view_compilation hilang.'; end if;
  if not exists (select 1 from public.permissions where code = 'archive_compilation') then
    raise exception 'GAGAL: kode archive_compilation hilang.'; end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
