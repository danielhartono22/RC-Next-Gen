-- ==========================================================================================
-- Penanda modul untuk peran baru dan untuk Management of Approval
-- ==========================================================================================
-- rc_private.legacy_auth_flags() menentukan kartu modul mana yang tampil di beranda. Ia membaca
-- baris public.user_permissions satu per satu, dan itu menyisakan dua lubang sesudah perubahan
-- terakhir:
--
--   1. Modul Management of Approval belum punya penandanya, sehingga kartunya tidak akan pernah
--      muncul bagi siapa pun.
--
--   2. Depot Head dan Management memegang seluruh izin lewat perannya - itu ditulis di
--      rc_private.can_access, bukan sebagai baris user_permissions. Fungsi ini membaca barisnya,
--      jadi keduanya akan masuk aplikasi tanpa satu kartu pun: berhak melakukan segalanya,
--      tetapi tidak melihat apa-apa.
--
-- Keduanya diperbaiki di sini, dengan aturan yang sama persis dengan can_access - "peran ini
-- memegang seluruh izin" ditulis sekali lagi di tempat yang membaca izin, bukan diterjemahkan
-- menjadi daftar modul yang harus diingat dan disamakan setiap kali modul bertambah.
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
   ('approval','approve_claim'),
   ('report','view_report'), ('timetable','manage_timetable')
 ), milik as (
   select coalesce(jsonb_object_agg(permission_code,true),'{}'::jsonb) as p
     from public.user_permissions where user_id=(select auth.uid())
 ), semua as (
   -- Peran yang "dapat melakukan seluruhnya sesuai yurisdiksi": batasnya jangkauan depot, bukan
   -- daftar izin. Jangkauan itu dijaga can_access pada setiap tindakan, jadi di sini seluruh
   -- kartunya memang ditampilkan.
   select exists(select 1 from public.profiles p
                  where p.id=(select auth.uid()) and p.status='active'
                    and not p.must_change_password
                    and p.role in ('depot head','management')) as ya
 )
 select case when rc_private.is_system_manager() or (select ya from semua) then
   (select jsonb_object_agg(letter,'Yes') from peta) || jsonb_build_object('q','No')
 else
   (select jsonb_object_agg(peta.letter,
      case when milik.p ? peta.code then 'Yes' else 'No' end)
    from peta, milik) || jsonb_build_object('q','No')
 end;
$fn$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text; v_uid uuid; f jsonb; v_role text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='rc_private' and p.proname='legacy_auth_flags';
  if position('approve_claim' in src) = 0 then
    raise exception 'GAGAL: penanda modul approval tidak ada.'; end if;
  if position('depot head' in src) = 0 or position('management' in src) = 0 then
    raise exception 'GAGAL: peran baru belum dikenali penanda modul.'; end if;

  -- System Manager tetap memperoleh seluruh kartu, termasuk yang baru.
  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
  f := rc_private.legacy_auth_flags();
  reset role;
  if (f->>'approval') <> 'Yes' then
    raise exception 'GAGAL: System Manager tidak memperoleh modul approval.'; end if;

  -- Seorang Depot Head harus memperoleh seluruh kartu. Diuji dengan mengubah peran sebuah akun
  -- di dalam transaksi ini, lalu dikembalikan - tidak ada akun sungguhan yang berubah.
  select id, role into v_uid, v_role from public.profiles
   where coalesce(status,'')='active' and lower(coalesce(role,'')) not like '%system%'
   order by user_code limit 1;
  if v_uid is null then
    raise notice 'Tidak ada akun non-System Manager untuk diuji.';
  else
    update public.profiles set role='depot head' where id=v_uid;
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
    f := rc_private.legacy_auth_flags();
    reset role;
    update public.profiles set role=v_role where id=v_uid;

    if (f->>'approval') <> 'Yes' or (f->>'k') <> 'Yes' or (f->>'report') <> 'Yes' then
      raise exception 'GAGAL: Depot Head tidak memperoleh seluruh kartu modul (%).', f::text; end if;
    raise notice 'Depot Head memperoleh seluruh kartu modul.';
  end if;

  raise notice 'Pemeriksaan lolos.';
exception when others then
  reset role; raise;
end
$periksa$;
