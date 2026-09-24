-- ==========================================================================================
-- Tanggal warisan diurai, dan System Manager kembali melihat seluruh depot
-- ==========================================================================================
-- DUA MASALAH YANG DITEMUKAN SAAT MENGUJI MODUL REPORT DAN TIMETABLE
--
-- 1. SELURUH TANGGAL CLAIM KOSONG, PADAHAL DATANYA ADA
--    claims.cleared_at bernilai NULL untuk seluruh 1.162 baris berstatus Done, sehingga Cost
--    Center 2 tidak menghasilkan satu baris pun dan aging kehilangan sebagian besar acuannya.
--    Tanggalnya ternyata tidak hilang: impor menyimpannya sebagai teks di kolom legacy_dates -
--    misalnya {"cleared_at":"13-Apr-26","uploaded_at":"16-Mar-26"} - dan tidak pernah
--    menguraikannya ke kolom sungguhan.
--
--    Ini juga penjelasan atas keluhan lama pemilik bahwa kolom Tanggal Proses menampilkan
--    tanda hubung: server memang mengirim "-" karena cleared_at kosong, bukan karena
--    tampilannya salah.
--
--    Penguraiannya memakai rc_private.urai_tanggal yang sudah dipasang di 20261010010000 dan
--    sudah terbukti mengurai seluruh 80 periode campaign tanpa satu pun gagal. Tanggal yang
--    tetap tidak terurai dibiarkan NULL, bukan ditebak.
--
-- 2. SYSTEM MANAGER HANYA MELIHAT EMPAT DEPOT
--    Policy depots_scoped menuntut adanya baris pada user_depot_access, tanpa pengecualian
--    untuk peran. Itu persis kegagalan yang pernah diperbaiki untuk public.claims pada
--    20260924010000, tetapi tabel depots ketinggalan. Selama ini tidak terlihat karena
--    rc_public_depots berjalan SECURITY DEFINER sehingga selalu mengembalikan seluruh depot -
--    begitu Timetable membaca public.depots secara langsung, masalahnya baru muncul: matrix
--    hanya menampilkan 4 dari 51 depot.
--
--    Policy-nya kini memakai rc_private.can_access, yang sudah mengenal peran System Manager,
--    sehingga hanya ada satu tempat yang memutuskan siapa boleh melihat depot mana.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Tanggal warisan diurai ke kolom sungguhan
-- ------------------------------------------------------------------------------------------
-- Hanya mengisi yang masih kosong. Nilai yang sudah benar tidak pernah ditimpa, sehingga
-- dokumen yang sudah diproses lewat RC tidak tergeser oleh data impor yang lebih tua.
update public.claims c set
  uploaded_at = coalesce(c.uploaded_at,
    (rc_private.urai_tanggal(c.legacy_dates->>'uploaded_at') + time '00:00') at time zone 'Asia/Jakarta'),
  released_at = coalesce(c.released_at,
    (rc_private.urai_tanggal(c.legacy_dates->>'released_at') + time '00:00') at time zone 'Asia/Jakarta'),
  claimed_at  = coalesce(c.claimed_at,
    (rc_private.urai_tanggal(c.legacy_dates->>'claimed_at')  + time '00:00') at time zone 'Asia/Jakarta'),
  cleared_at  = coalesce(c.cleared_at,
    (rc_private.urai_tanggal(c.legacy_dates->>'cleared_at')  + time '00:00') at time zone 'Asia/Jakarta'),
  paid_on      = coalesce(c.paid_on,      rc_private.urai_tanggal(c.legacy_dates->>'paid_on')),
  period_start = coalesce(c.period_start, rc_private.urai_tanggal(c.legacy_dates->>'period_start')),
  period_end   = coalesce(c.period_end,   rc_private.urai_tanggal(c.legacy_dates->>'period_end'))
where c.legacy_dates is not null
  and (c.uploaded_at is null or c.released_at is null or c.claimed_at is null
       or c.cleared_at is null or c.paid_on is null
       or c.period_start is null or c.period_end is null);

-- ------------------------------------------------------------------------------------------
-- 2. Depot mengikuti aturan akses yang sama dengan tabel lain
-- ------------------------------------------------------------------------------------------
drop policy if exists depots_scoped on public.depots;
create policy depots_scoped on public.depots
 for select to authenticated
 using (rc_private.can_access(depots.id));

-- Yurisdiksi turunan milik System Manager dihitung ulang, supaya user_depot_access tidak lagi
-- memuat sisa lama yang lebih sempit dari perannya.
do $rebuild$
declare u uuid;
begin
  for u in select id from public.profiles where role='system manager' loop
    perform rc_private.rebuild_depot_access(u);
  end loop;
end $rebuild$;

create or replace function rc_private.marker_20261013() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261013() from public,anon;
grant execute on function rc_private.marker_20261013() to authenticated;

select 'Tanggal warisan diurai dan akses depot diperbaiki' as hasil,
 (select count(*) from public.claims where status='done' and cleared_at is not null) as done_bertanggal,
 (select count(*) from public.claims where status='done' and cleared_at is null) as done_masih_kosong,
 (select count(*) from public.claims where uploaded_at is not null) as claim_beruploaded,
 (select count(*) from public.user_depot_access a
   join public.profiles p on p.id=a.user_id where p.role='system manager') as depot_system_manager,
 (select count(*) from public.depots) as total_depot;
