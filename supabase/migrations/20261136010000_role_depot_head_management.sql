-- ==========================================================================================
-- Dua peran baru: Depot Head dan Management
-- ==========================================================================================
-- Permintaan pemilik:
--
--   Depot Head : dapat melakukan seluruhnya sesuai yurisdiksi DEPOT yang ditetapkan, minimal
--                oleh Supervisor atau System Manager.
--   Management : dapat melakukan seluruhnya sesuai yurisdiksi REGION yang ditetapkan, minimal
--                oleh Supervisor.
--
-- ------------------------------------------------------------------------------------------
-- DUA HAL YANG BERBEDA: JANGKAUAN DAN IZIN
-- ------------------------------------------------------------------------------------------
-- Sistem ini sudah memisahkan keduanya, dan pemisahan itu dipertahankan:
--
--   jangkauan -> depot mana yang boleh disentuh  (public.user_depot_access, dihitung
--                rc_private.effective_depots)
--   izin      -> tindakan apa yang boleh dilakukan (public.user_permissions)
--
-- "Dapat melakukan seluruhnya" menyentuh sisi IZIN: kedua peran ini memegang setiap izin tanpa
-- perlu tiga belas baris user_permissions per akun. Itu ditulis sekali di can_access, sehingga
-- izin yang ditambahkan kelak otomatis ikut - tidak ada daftar kedua yang harus diingat.
--
-- "Sesuai yurisdiksi" menyentuh sisi JANGKAUAN, dan di sinilah keduanya berbeda:
--
--   Depot Head memakai jalur yang sudah ada - depot ditempelkan satu per satu lewat
--   user_depot_grants, persis seperti OSC.
--
--   Management memakai jalur baru: region. Region adalah kolom pada public.depots, jadi
--   "region 2B" berarti setiap depot yang region-nya 2B - termasuk depot yang baru dibuat
--   kemudian, tanpa perlu menetapkan ulang siapa pun.
--
-- ------------------------------------------------------------------------------------------
-- MENGAPA MENUMPANG effective_depots, BUKAN MEMBUAT JALUR SENDIRI
-- ------------------------------------------------------------------------------------------
-- Seluruh sistem membaca jangkauan dari satu tempat: user_depot_access, yang diisi ulang
-- rc_private.rebuild_depot_access() dari rc_private.effective_depots(). Menambahkan cabang di
-- sana membuat region ikut berlaku pada RLS, daftar depot, Report, Timetable dan email
-- sekaligus. Membuat jalur kedua akan berarti setiap pembaca jangkauan harus diajari dua cara,
-- dan yang terlupa akan gagal diam-diam.
--
-- Konsekuensinya sama dengan yang sudah berlaku bagi Supervisor: jangkauan itu hasil hitungan
-- yang disimpan, jadi ia perlu dihitung ulang ketika penetapannya berubah. Fungsi
-- rc_private.rebuild_region_access() di bawah melakukannya untuk seluruh akun terdampak.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Penetapan region
-- ------------------------------------------------------------------------------------------
create table if not exists public.user_region_access (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  region     text not null,
  granted_by uuid references public.profiles(id),
  granted_at timestamptz not null default now(),
  primary key (user_id, region)
);

comment on table public.user_region_access is
  'Region yang ditetapkan kepada sebuah akun. Dipakai rc_private.effective_depots untuk '
  'menurunkan daftar depot, sehingga depot baru pada region itu ikut dengan sendirinya.';

create index if not exists user_region_access_region_idx on public.user_region_access(region);

alter table public.user_region_access enable row level security;

-- Kebijakan RLS di project ini hanya mengatur BACA; seluruh tulisan lewat fungsi
-- SECURITY DEFINER yang memeriksa haknya sendiri. Pola itu diikuti di sini.
drop policy if exists user_region_access_scoped on public.user_region_access;
create policy user_region_access_scoped on public.user_region_access
  for select to authenticated
  using (user_id = (select auth.uid()) or rc_private.is_system_manager()
         or exists (select 1 from public.profiles p
                     where p.id = (select auth.uid()) and p.role = 'supervisor'
                       and p.status = 'active'));

revoke all on public.user_region_access from anon;
grant select on public.user_region_access to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Region ikut menentukan jangkauan depot
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.effective_depots(p_user uuid)
returns setof uuid language sql stable security definer set search_path='' as $fn$
  -- Hanya System Manager yang memperoleh seluruh depot sebagai jangkauan BERTINDAK.
  select d.id from public.depots d
   where (select role from public.profiles where id = p_user) = 'system manager'
  union
  -- Depot yang ditempelkan langsung: 'rp' untuk admin, 'assigned' untuk osc, Depot Head dan
  -- peran lain.
  select g.depot_id from public.user_depot_grants g
   where g.user_id = p_user and g.kind in ('rp','assigned')
  union
  -- Supervisor mewarisi depot OSC binaannya. Binaannya harus BENAR-BENAR berperan 'osc':
  -- tanpa syarat ini, sebuah akun yang dikembalikan menjadi admin tetap mewariskan depotnya
  -- kepada supervisor yang dulu membinanya.
  select g.depot_id
    from public.user_supervision s
    join public.profiles o on o.id = s.osc_id and o.role = 'osc' and o.status = 'active'
    join public.user_depot_grants g on g.user_id = s.osc_id and g.kind in ('rp','assigned')
   where s.supervisor_id = p_user
  union
  -- Region yang ditetapkan: seluruh depot di dalamnya, termasuk yang ditambahkan kemudian.
  -- Perbandingannya menoleransi selisih huruf besar-kecil dan spasi, karena region diketik
  -- tangan pada Depot Master dan "2B", "2b" serta " 2B " memang region yang sama.
  select d.id
    from public.user_region_access r
    join public.depots d
      on upper(btrim(coalesce(d.region,''))) = upper(btrim(r.region))
   where r.user_id = p_user and btrim(coalesce(d.region,'')) <> '';
$fn$;

-- Menghitung ulang jangkauan seluruh akun yang memegang sebuah region. Dipanggil sesudah
-- penetapan region berubah, dan sesudah region sebuah depot diubah di Depot Master.
create or replace function rc_private.rebuild_region_access(p_region text default null)
returns integer language plpgsql security definer set search_path='' as $fn$
declare u uuid; n integer := 0;
begin
  for u in
    select distinct r.user_id from public.user_region_access r
     where p_region is null or upper(btrim(r.region)) = upper(btrim(p_region))
  loop
    perform rc_private.rebuild_depot_access(u);
    n := n + 1;
  end loop;
  return n;
end $fn$;
revoke all on function rc_private.rebuild_region_access(text) from public, anon;

-- ------------------------------------------------------------------------------------------
-- 3. Kedua peran memegang seluruh izin, tetap dibatasi jangkauannya
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.can_access(p_depot uuid, p_permission text default null)
returns boolean language sql stable security definer set search_path='' as $fn$
select exists(
  select 1 from public.profiles p
  where p.id=(select auth.uid())
    and p.status='active'
    and not p.must_change_password
    and (
      p.role='system manager'
      or (
        (p_depot is null
         or exists(select 1 from public.user_depot_access a
                   where a.user_id=p.id and a.depot_id=p_depot))
        and (p_permission is null
         -- Depot Head dan Management "dapat melakukan seluruhnya" - seluruh izin melekat pada
         -- perannya, bukan pada tiga belas baris yang harus dicentang satu per satu. Izin yang
         -- ditambahkan kelak ikut dengan sendirinya, dan batas mereka tetap jangkauan depot di
         -- atas: seluruhnya, tetapi hanya di dalam yurisdiksinya.
         or p.role in ('depot head','management')
         or exists(select 1 from public.user_permissions x
                   where x.user_id=p.id and x.permission_code=p_permission))
      )
    )
);
$fn$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_region text; v_depot uuid; n_region int; n_semua int; src text;
begin
  -- Tabel dan indeksnya ada.
  if to_regclass('public.user_region_access') is null then
    raise exception 'GAGAL: tabel user_region_access tidak terbentuk.'; end if;
  if not exists (select 1 from pg_policies where schemaname='public'
                  and tablename='user_region_access') then
    raise exception 'GAGAL: user_region_access tanpa kebijakan RLS.'; end if;
  if (select relrowsecurity from pg_class where oid='public.user_region_access'::regclass) is false then
    raise exception 'GAGAL: RLS belum aktif pada user_region_access.'; end if;
  if has_table_privilege('anon','public.user_region_access','select') then
    raise exception 'GAGAL: anon dapat membaca user_region_access.'; end if;

  -- can_access benar-benar mengenal kedua peran.
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='rc_private' and p.proname='can_access';
  if position('depot head' in src) = 0 or position('management' in src) = 0 then
    raise exception 'GAGAL: can_access belum mengenal peran baru.'; end if;

  -- Cabang region pada effective_depots benar-benar bekerja: sebuah region nyata harus
  -- menurunkan depot yang jumlahnya sama dengan isi region itu.
  select upper(btrim(region)) into v_region from public.depots
   where btrim(coalesce(region,'')) <> '' group by 1 order by count(*) desc limit 1;
  if v_region is null then
    raise notice 'Tidak ada depot ber-region; cabang region tidak diuji.';
  else
    select count(*) into n_semua from public.depots
     where upper(btrim(coalesce(region,''))) = v_region;

    -- Diuji memakai akun contoh di dalam transaksi ini, lalu dibatalkan oleh migration runner
    -- bila gagal. Tidak ada akun sungguhan yang disentuh.
    select id into v_depot from public.profiles order by user_code limit 1;
    insert into public.user_region_access(user_id, region) values (v_depot, v_region)
      on conflict do nothing;
    select count(*) into n_region from rc_private.effective_depots(v_depot) x
      join public.depots d on d.id = x
     where upper(btrim(coalesce(d.region,''))) = v_region;
    delete from public.user_region_access where user_id = v_depot and region = v_region;

    if n_region <> n_semua then
      raise exception 'GAGAL: region % menurunkan % depot, seharusnya %.',
        v_region, n_region, n_semua;
    end if;
    raise notice 'Region % menurunkan % depot - benar.', v_region, n_region;
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
