-- ==========================================================================================
-- Model yurisdiksi baru, dan perbaikan Kelola Akses yang selama ini diam-diam gagal
-- ==========================================================================================
-- TIGA MASALAH YANG DIPERBAIKI, KETIGANYA DITEMUKAN DENGAN MEMANGGIL FUNGSINYA LANGSUNG
--
-- 1. Menyimpan otorisasi selalu gagal tanpa pesan apa pun.
--    public.profiles hanya punya satu policy RLS, profiles_self (id = auth.uid()), sehingga
--    seorang pengguna hanya melihat barisnya sendiri. rc_legacy_update_access berjalan sebagai
--    SECURITY INVOKER dan mencari targetnya dengan "select ... from public.profiles where
--    user_code=...", jadi RLS menyembunyikan target itu dan fungsinya berhenti dengan
--    "User not found". Daftar penggunanya sendiri tetap tampil karena dibaca lewat
--    rc_private.legacy_users yang SECURITY DEFINER. Itulah sebabnya layar bisa menampilkan
--    semua orang tetapi tidak bisa menyimpan satu pun. Di sisi browser, saveUserAccess hanya
--    bereaksi ketika status bernilai success, sehingga kegagalannya tidak memunculkan apa pun.
--
-- 2. Kolom Nama Lengkap dan Depot kosong di konsol.
--    Layar membaca u.namaLengkap dan u.kodeDepot, sedangkan server mengirim nama dan
--    depotCodes. Namanya tidak pernah cocok, jadi selalu tampil "-".
--
-- 3. Supervisor tidak bisa mengelola siapa pun.
--    rc_private.is_manager() hanya mengembalikan is_system_manager().
--
-- MODEL YURISDIKSI, SESUAI KEPUTUSAN PEMILIK
--   System Manager  seluruh depot, tanpa perlu diberi yurisdiksi apa pun
--   Admin           depot asalnya sendiri, ditambah depot lain yang di-tag sebagai
--                   Resource Partner (RP)
--   OSC             depot-depot yang di-assign kepadanya
--   Supervisor      gabungan seluruh depot milik OSC yang ia supervisi, ditambah depotnya
--   Others          sesuai assignment depot
--   Non-OSC         DIHAPUS; baris yang masih memakainya dipindahkan menjadi Others
--
-- Yurisdiksi tidak lagi disimpan langsung di user_depot_access. Sumber kebenarannya kini
-- user_depot_grants (asal, RP, assignment) dan user_supervision (supervisor atas OSC).
-- user_depot_access tetap ada dan tetap menjadi yang dibaca RLS, tetapi sekarang ia hasil
-- turunan yang dihitung ulang oleh rc_private.rebuild_depot_access. Dengan begitu satu
-- perubahan pada OSC ikut menggeser supervisornya tanpa perlu disunting dua kali.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Peran: Non-OSC dihapus
-- ------------------------------------------------------------------------------------------
update public.profiles set role='others' where lower(btrim(role))='non-osc';

-- ------------------------------------------------------------------------------------------
-- 2. Sumber kebenaran yurisdiksi
-- ------------------------------------------------------------------------------------------
create table if not exists public.user_depot_grants(
  user_id  uuid not null references public.profiles(id) on delete cascade,
  depot_id uuid not null references public.depots(id)   on delete cascade,
  -- home     : depot asal pengguna, dipakai sebagai identitas di konsol
  -- rp       : Resource Partner, depot lain yang ditagging ke seorang admin
  -- assigned : penugasan biasa untuk OSC dan Others
  kind text not null check(kind in('home','rp','assigned')),
  granted_at timestamptz not null default now(),
  granted_by uuid references public.profiles(id),
  primary key(user_id,depot_id)
);
create index if not exists user_depot_grants_depot_idx on public.user_depot_grants(depot_id,user_id);
alter table public.user_depot_grants enable row level security;
revoke all on public.user_depot_grants from public,anon,authenticated;

create table if not exists public.user_supervision(
  supervisor_id uuid not null references public.profiles(id) on delete cascade,
  osc_id        uuid not null references public.profiles(id) on delete cascade,
  assigned_at timestamptz not null default now(),
  primary key(supervisor_id,osc_id),
  check(supervisor_id <> osc_id)
);
create index if not exists user_supervision_osc_idx on public.user_supervision(osc_id,supervisor_id);
alter table public.user_supervision enable row level security;
revoke all on public.user_supervision from public,anon,authenticated;

-- Yurisdiksi yang sudah ada dipindahkan sekali ke tabel baru, supaya tidak ada yang kehilangan
-- aksesnya saat berkas ini dijalankan. Depot dengan kode terkecil dianggap depot asal.
insert into public.user_depot_grants(user_id,depot_id,kind)
select a.user_id, a.depot_id,
  case when d.depot_code = (select min(d2.depot_code) from public.user_depot_access a2
                             join public.depots d2 on d2.id=a2.depot_id
                            where a2.user_id=a.user_id)
       then 'home' else 'assigned' end
from public.user_depot_access a
join public.depots d on d.id=a.depot_id
join public.profiles p on p.id=a.user_id
where p.role <> 'system manager'
on conflict(user_id,depot_id) do nothing;

-- ------------------------------------------------------------------------------------------
-- 3. Menghitung yurisdiksi yang berlaku
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.effective_depots(p_user uuid)
returns setof uuid language sql stable security definer set search_path='' as $fn$
  select d.id from public.depots d
   where (select role from public.profiles where id=p_user)='system manager'
  union
  select g.depot_id from public.user_depot_grants g where g.user_id=p_user
  union
  -- Supervisor mewarisi seluruh depot milik OSC yang ia supervisi.
  select g.depot_id
    from public.user_supervision s
    join public.user_depot_grants g on g.user_id=s.osc_id
   where s.supervisor_id=p_user;
$fn$;
revoke all on function rc_private.effective_depots(uuid) from public,anon;

create or replace function rc_private.rebuild_depot_access(p_user uuid)
returns integer language plpgsql security definer set search_path='' as $fn$
declare n integer;
begin
  delete from public.user_depot_access where user_id=p_user;
  insert into public.user_depot_access(user_id,depot_id)
  select p_user, x from rc_private.effective_depots(p_user) x
  on conflict do nothing;
  select count(*) into n from public.user_depot_access where user_id=p_user;
  return n;
end $fn$;
revoke all on function rc_private.rebuild_depot_access(uuid) from public,anon;

-- Mengubah depot seorang OSC harus ikut menggeser supervisornya. Tanpa ini, yurisdiksi
-- supervisor akan membeku pada keadaan saat terakhir kali ia disunting.
create or replace function rc_private.rebuild_with_supervisors(p_user uuid)
returns void language plpgsql security definer set search_path='' as $fn$
declare s uuid;
begin
  perform rc_private.rebuild_depot_access(p_user);
  for s in select supervisor_id from public.user_supervision where osc_id=p_user loop
    perform rc_private.rebuild_depot_access(s);
  end loop;
end $fn$;
revoke all on function rc_private.rebuild_with_supervisors(uuid) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 4. Siapa boleh mengelola siapa
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.is_manager()
returns boolean language sql stable security definer set search_path='' as $fn$
  select exists(select 1 from public.profiles p
                 where p.id=(select auth.uid()) and p.status='active'
                   and p.role in('system manager','supervisor'));
$fn$;

-- System Manager boleh atas siapa pun. Supervisor hanya atas pengguna yang seluruh depotnya
-- berada di dalam wilayahnya sendiri, dan tidak pernah atas seorang System Manager.
create or replace function rc_private.can_manage_user(p_target uuid)
returns boolean language sql stable security definer set search_path='' as $fn$
  select case
    when p_target is null then false
    when rc_private.is_system_manager() then true
    when not exists(select 1 from public.profiles p
                     where p.id=(select auth.uid()) and p.status='active' and p.role='supervisor')
      then false
    when (select role from public.profiles where id=p_target)='system manager' then false
    else not exists(
      select 1 from rc_private.effective_depots(p_target) t
       where t not in (select rc_private.effective_depots((select auth.uid()))))
  end;
$fn$;
revoke all on function rc_private.can_manage_user(uuid) from public,anon;
grant execute on function rc_private.can_manage_user(uuid) to authenticated;

-- Konsol perlu membaca profil orang lain. Tanpa policy ini, setiap pembacaan sebagai
-- SECURITY INVOKER berhenti dengan "User not found".
drop policy if exists profiles_managed on public.profiles;
create policy profiles_managed on public.profiles
 for select to authenticated
 using (rc_private.can_manage_user(id));

-- ------------------------------------------------------------------------------------------
-- 5. Peran yang dikenali, tanpa Non-OSC
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.set_role(p_user uuid, p_role text)
returns void language plpgsql security definer set search_path='' as $fn$
declare v_role text; v_lama text;
begin
  v_role:=lower(btrim(coalesce(p_role,'')));
  if v_role not in('admin','osc','others','finance','supervisor','system manager') then
    raise exception 'Role "%" tidak dikenali',p_role; end if;
  -- Hanya System Manager yang boleh mengangkat System Manager. Ini aturan yang diminta
  -- pemilik sejak awal dan tidak dilonggarkan oleh perluasan wewenang supervisor.
  if v_role='system manager' and not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat memberikan peran System Manager'
      using errcode='42501'; end if;
  if not rc_private.can_manage_user(p_user) then
    raise exception 'Pengguna ini di luar wilayah Anda' using errcode='42501'; end if;

  select role into v_lama from public.profiles where id=p_user for update;
  if not found then raise exception 'User tidak ditemukan'; end if;
  if v_lama=v_role then return; end if;
  if p_user=(select auth.uid()) then raise exception 'Tidak dapat mengubah peran sendiri'; end if;

  update public.profiles set role=v_role where id=p_user;
  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'role_changed',p_user,jsonb_build_object('dari',v_lama,'menjadi',v_role));
end $fn$;

create or replace function rc_private.marker_20261002() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261002() from public,anon;
grant execute on function rc_private.marker_20261002() to authenticated;

select 'Model yurisdiksi terpasang' as hasil,
 (select count(*) from public.user_depot_grants) as baris_grant,
 (select count(*) from public.user_supervision) as baris_supervisi,
 (select count(*) from public.profiles where role='non-osc') as sisa_non_osc,
 (select count(*) from pg_policies where schemaname='public' and tablename='profiles') as policy_profiles;
