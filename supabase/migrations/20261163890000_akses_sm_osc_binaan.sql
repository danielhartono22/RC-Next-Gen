-- ==========================================================================================
-- Edit Akses: System Manager bebas yurisdiksi; OSC binaan yang tidak aktif tidak menggagalkan simpan
-- ==========================================================================================
-- Pemilik, 11 November 2026: "saya system manager kenapa tidak bisa kasih akses katanya di luar
-- yuridiksi anda? system manager by default bebas semua akses tanpa terkecuali."
--
-- Sebab (log prod 11-Nov 08:22-08:27 WIB, 11 penyimpanan ditolak): rc_update_access memeriksa setiap
-- OSC binaan Supervisor dengan syarat "berperan OSC DAN berstatus active DAN dalam yurisdiksi", lalu
-- menolak dengan satu pesan "OSC tidak valid atau di luar yurisdiksi Anda". Supervisor MIRANTI masih
-- membina OSC IRENE yang sudah Inactive, sehingga SETIAP simpan akses MIRANTI ditolak, juga oleh
-- System Manager - padahal yang gagal bukan yurisdiksi, melainkan status IRENE.
--
-- Perbaikan pada rc_update_access:
--   * Akun yang tidak ada / bukan OSC tetap ditolak, dengan pesan yang menyebut kodenya.
--   * System Manager: tanpa pemeriksaan yurisdiksi atau status OSC.
--   * Peran lain: OSC aktif dalam yurisdiksinya, ATAU OSC yang memang sudah dibina akun ini (supaya
--     binaan lama yang kini tidak aktif tidak mengunci akun pembinanya).
--   * Pemeriksaan depot memakai pesan yang menyebut kode depotnya.
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
  src := replace(pg_get_functiondef('public.rc_update_access(jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261163890000' then
    src := pg_temp.ganti(src,
$p$    if v_depot is null or not rc_private.can_access(v_depot) then raise exception 'Depot di luar yurisdiksi Anda' using errcode='42501'; end if;$p$,
$p$    if v_depot is null or not rc_private.can_access(v_depot) then raise exception 'Depot % di luar yurisdiksi Anda', btrim(c) using errcode='42501'; end if;$p$,
      1, 'depot');
    src := pg_temp.ganti(src,
$p$    if not exists(select 1 from public.profiles p where p.user_code=upper(btrim(c)) and p.role='osc' and p.status='active' and rc_private.can_manage_user(p.id)) then
     raise exception 'OSC tidak valid atau di luar yurisdiksi Anda' using errcode='42501'; end if;$p$,
$p$    -- 20261163890000: akun harus ada dan berperan OSC. System Manager bebas yurisdiksi dan status;
    -- peran lain: OSC aktif dalam yurisdiksinya, atau OSC yang memang sudah dibina akun ini.
    continue when btrim(c) = '';
    if not exists(select 1 from public.profiles p where p.user_code=upper(btrim(c)) and p.role='osc' and p.status<>'deleted') then
     raise exception 'Akun % tidak dapat dibina: ia harus ada dan berperan OSC', upper(btrim(c)) using errcode='22023'; end if;
    if not rc_private.is_system_manager() and not exists(select 1 from public.profiles p
         where p.user_code=upper(btrim(c)) and p.role='osc'
           and ((p.status='active' and rc_private.can_manage_user(p.id))
                or exists(select 1 from public.user_supervision us where us.supervisor_id=v_target and us.osc_id=p.id))) then
     raise exception 'OSC % tidak aktif atau di luar yurisdiksi Anda', upper(btrim(c)) using errcode='42501'; end if;$p$,
      1, 'osc');
    execute src;
  end if;
end $tambal$;

do $cek$
declare src text := pg_get_functiondef('public.rc_update_access(jsonb)'::regprocedure);
begin
  if src !~ '20261163890000' or src ~ 'OSC tidak valid atau di luar yurisdiksi Anda' then raise exception 'GAGAL: rc_update_access belum tertambal'; end if;
end $cek$;
