-- ==========================================================================================
-- Galat "dokumen berubah" tidak lagi memakai SQLSTATE 40001
-- ==========================================================================================
-- 13 November 2026, CPU prod 100%.
--
-- Tiga fungsi menolak dokumen yang versinya sudah berubah dengan SQLSTATE 40001
-- (serialization_failure). PostgREST menganggap 40001 sebagai galat sementara dan MENGULANG
-- transaksinya sendiri, tanpa batas dan tanpa jeda. Karena versi dokumen tidak akan pernah cocok
-- lagi, satu klik pada data yang sudah basi membuat satu koneksi API berputar ratusan kali per
-- detik sampai layanan di-restart. Di prod pada 13 November 2026 dua koneksi berputar sejak
-- 11:12 WIB (±445 rollback per detik) sementara permintaan pengguna hanya ±12 per menit.
--
-- Perbaikan: kodenya menjadi P0001 (galat biasa). Pesan untuk pengguna tidak berubah, hanya
-- tidak lagi diulang oleh PostgREST. Permintaan yang sedang berputar berhenti sendiri pada
-- putaran berikutnya.
--   rc_private.mutate_claims_unchecked   'Document changed; refresh first'
--   public.rc_adhoc_proses               'Dokumen % berubah sejak dimuat; segarkan data lalu ulangi'
--   public.rc_adhoc_tolak                (sama)
-- Aman dijalankan berulang.
-- ==========================================================================================

do $tambal$
declare f regprocedure; src text; n integer;
begin
  foreach f in array array[
    'rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)'::regprocedure,
    'public.rc_adhoc_proses(jsonb,uuid)'::regprocedure,
    'public.rc_adhoc_tolak(jsonb,uuid,text)'::regprocedure]
  loop
    src := replace(pg_get_functiondef(f), E'\r', '');
    n := (length(src) - length(replace(src, '40001', ''))) / 5;
    if n = 0 then continue; end if; -- sudah ditambal
    if n <> 1 then raise exception '%: 40001 ditemukan % kali, diharapkan 1', f, n; end if;
    if src !~ 'using errcode ?= ?''40001''' then raise exception '%: bentuk errcode 40001 tidak dikenali', f; end if;
    src := regexp_replace(src, 'using errcode ?= ?''40001''', 'using errcode = ''P0001'' /* 20261163940000: bukan serialization_failure, yang diulang PostgREST tanpa henti */');
    execute src;
  end loop;
end $tambal$;

do $cek$
declare v text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'rc_private', 'disc', 'rental', 'staging', 'rc_muat_ulang') and p.prokind in ('f', 'p')
     and pg_get_functiondef(p.oid) ~ '40001|40P01';
  if v is not null then raise exception 'GAGAL: masih ada SQLSTATE yang diulang PostgREST di %', v; end if;
end $cek$;
