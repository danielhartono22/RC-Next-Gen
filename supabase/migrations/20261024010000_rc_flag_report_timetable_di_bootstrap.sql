-- ==========================================================================================
-- Report dan Timetable muncul di dashboard sesudah haknya diberikan
-- ==========================================================================================
-- Pemilik melaporkan: akses sudah diberikan lewat Kelola Akses, tetapi modulnya tidak muncul.
--
-- Sebabnya bukan pada pemberian aksesnya. rc_private.legacy_auth_flags - yang menyusun objek
-- auth pada rc_legacy_bootstrap, dan dari objek itulah layar memutuskan kartu mana yang tampak -
-- tidak pernah memuat kunci report maupun timetable. Layar membaca uA.report, memperoleh
-- undefined, lalu menyembunyikan kartunya. Jadi berapa kali pun haknya diberikan, hasilnya sama.
--
-- Ini pasangan yang terlewat: 20261018010000 sudah menambahkan kedua kunci pada legacy_users
-- (daftar di konsol Kelola Akses) dan pada rc_update_access (penyimpanan), tetapi tidak pada
-- jalur bootstrap. Akibatnya konsol memperlihatkan haknya menyala, sementara dashboard tetap
-- menyembunyikan modulnya - dua layar yang menampilkan kebenaran berbeda.
--
-- Daftar hurufnya kini disusun dari satu sumber, sehingga penambahan modul berikutnya tidak
-- bisa lagi terpasang di sebagian tempat saja.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.legacy_auth_flags()
returns jsonb language sql stable security definer set search_path='' as $fn$
 with peta(letter, code) as (values
   ('j','upload_claim'), ('k','release_claim'), ('l','process_claim'),
   ('m','view_analytics'), ('d','view_analytics'), ('n','manage_access'),
   ('p','view_master_depot'), ('s','bulk_process'), ('logs','view_logs'),
   ('keyMaster','manage_key_master'), ('compilation','view_compilation'),
   ('archiveCompilation','archive_compilation'),
   ('report','view_report'), ('timetable','manage_timetable')
 ), milik as (
   select coalesce(jsonb_object_agg(permission_code,true),'{}'::jsonb) as p
     from public.user_permissions where user_id=(select auth.uid())
 )
 select case when rc_private.is_system_manager() then
   -- System Manager memegang seluruh modul, tanpa bergantung pada baris permission.
   (select jsonb_object_agg(letter,'Yes') from peta) || jsonb_build_object('q','No')
 else
   (select jsonb_object_agg(peta.letter,
      case when milik.p ? peta.code then 'Yes' else 'No' end)
    from peta, milik) || jsonb_build_object('q','No')
 end;
$fn$;

create or replace function rc_private.marker_20261024() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261024() from public,anon;
grant execute on function rc_private.marker_20261024() to authenticated;

select 'Flag report dan timetable masuk bootstrap' as hasil,
 (select count(*) from public.permissions) as permission_di_master;
