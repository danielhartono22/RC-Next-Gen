-- ==========================================================================================
-- Penetapan region untuk peran Management
-- ==========================================================================================
-- Peran Management memperoleh jangkauannya dari REGION, dan pemilik menegaskan sumber
-- regionnya: "untuk region maksud saya di depo master". Jadi daftar pilihannya adalah nilai
-- region yang benar-benar ada pada Depot Master - bukan daftar tersendiri yang harus dipelihara
-- dan lama-lama menyimpang dari master.
--
-- Konsekuensinya sengaja: region yang belum dipakai depot mana pun tidak dapat dipilih, karena
-- menetapkannya hanya akan menghasilkan jangkauan kosong. Yang perlu dilakukan lebih dulu adalah
-- mengisi region depotnya di Depot Master, dan di situlah tempatnya.
--
-- Tiga hal ditambahkan:
--   1. rc_region_list()      - pilihan region, dari Depot Master, beserta jumlah depotnya
--   2. rc_update_access      - menerima kunci 'regions'
--   3. rc_list_users         - mengembalikan region yang sedang dipegang tiap akun
--
-- Siapa boleh menetapkan: Supervisor ke atas, sesuai keputusan pemilik ("minimal supervisor").
-- Aturan itu ditulis sekali di rc_private.boleh_tetapkan_region().
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.boleh_tetapkan_region()
returns boolean language sql stable security definer set search_path='' as $fn$
  select exists(
    select 1 from public.profiles p
     where p.id = (select auth.uid()) and p.status = 'active'
       and not p.must_change_password
       and p.role in ('supervisor','system manager'));
$fn$;
revoke all on function rc_private.boleh_tetapkan_region() from public, anon;
grant execute on function rc_private.boleh_tetapkan_region() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 1. Pilihan region, langsung dari Depot Master
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_region_list()
returns jsonb language plpgsql stable set search_path='' as $fn$
declare hasil jsonb;
begin
  if not rc_private.can_access(null) then
    raise exception 'Access denied' using errcode='42501'; end if;

  select jsonb_build_object('status','success',
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'region', t.region, 'jumlahDepot', t.n) order by t.region), '[]'::jsonb))
  into hasil
  from (select upper(btrim(region)) region, count(*) n
          from public.depots
         where btrim(coalesce(region,'')) <> '' and archived_at is null
         group by 1) t;
  return hasil;
end $fn$;
revoke all on function public.rc_region_list() from public, anon;
grant execute on function public.rc_region_list() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. rc_update_access menerima 'regions'
-- ------------------------------------------------------------------------------------------
-- Ditulis sebagai fungsi tersendiri lalu dipanggil dari pembungkusnya, supaya badan
-- rc_update_access yang panjang tidak perlu dibedah lebih dalam daripada satu sisipan.
create or replace function rc_private.tetapkan_region(p_user uuid, p_regions jsonb)
returns integer language plpgsql security definer set search_path='' as $fn$
declare n int := 0; v text;
begin
  if p_regions is null or jsonb_typeof(p_regions) <> 'array' then return 0; end if;
  if not rc_private.boleh_tetapkan_region() then
    raise exception 'Hanya Supervisor atau System Manager yang dapat menetapkan region'
      using errcode='42501';
  end if;

  delete from public.user_region_access where user_id = p_user;
  for v in select upper(btrim(x #>> '{}')) from jsonb_array_elements(p_regions) x loop
    if v is null or v = '' then continue; end if;
    -- Hanya region yang benar-benar ada di Depot Master. Menetapkan region yang tidak dipakai
    -- depot mana pun hanya menghasilkan jangkauan kosong, dan kekosongan itu jauh lebih sulit
    -- dilacak daripada penolakan di sini.
    if not exists (select 1 from public.depots d
                    where upper(btrim(coalesce(d.region,''))) = v) then
      raise exception 'Region "%" tidak ada pada Depot Master', v;
    end if;
    insert into public.user_region_access(user_id, region, granted_by)
    values (p_user, v, (select auth.uid()))
    on conflict (user_id, region) do nothing;
    n := n + 1;
  end loop;

  -- Jangkauan depot dihitung ulang, karena ia disimpan - bukan dihitung setiap kali dibaca.
  perform rc_private.rebuild_depot_access(p_user);
  return n;
end $fn$;
revoke all on function rc_private.tetapkan_region(uuid, jsonb) from public, anon;
grant execute on function rc_private.tetapkan_region(uuid, jsonb) to authenticated;

do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='rc_update_access';
  if src is null then raise exception 'public.rc_update_access tidak ditemukan.'; end if;

  if position('tetapkan_region' in src) > 0 then
    raise notice 'rc_update_access sudah menangani region; dilewati.'; return; end if;

  -- Disisipkan tepat sebelum rc_update_access membangun jawabannya, setelah seluruh perubahan
  -- lain selesai - termasuk perubahan peran, sehingga pemeriksaan hak memakai peran yang baru.
  -- Disisipkan tepat sebelum jangkauan dihitung ulang, sesudah seluruh perubahan lain selesai -
  -- termasuk perubahan peran, sehingga pemeriksaan haknya memakai peran yang baru.
  if position($q$perform rc_private.rebuild_with_supervisors(v_target);$q$ in src) = 0 then
    raise exception 'Pola perhitungan ulang jangkauan tidak ditemukan pada rc_update_access.'; end if;

  baru := replace(src, $q$perform rc_private.rebuild_with_supervisors(v_target);$q$,
    $q$if p_payload ? 'regions' then$q$ || chr(10) ||
    $q$   perform rc_private.tetapkan_region(v_target, p_payload->'regions');$q$ || chr(10) ||
    $q$ end if;$q$ || chr(10) ||
    $q$ perform rc_private.rebuild_with_supervisors(v_target);$q$);
  if baru = src then raise exception 'Penyisipan region gagal.'; end if;
  execute baru;
  raise notice 'rc_update_access menerima kunci regions.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 3. Daftar akun memuat region yang dipegangnya
-- ------------------------------------------------------------------------------------------
-- rc_list_users hanyalah pembungkus tipis atas rc_private.list_users; yang perlu disunting
-- badannya, bukan pembungkusnya.
do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='list_users';
  if src is null then raise exception 'rc_private.list_users tidak ditemukan.'; end if;
  if position('user_region_access' in src) > 0 then
    raise notice 'list_users sudah memuat region; dilewati.'; return; end if;

  if position($q$ array(select depot_id from public.user_depot_access where user_id=p.id) as depots$q$ in src) = 0 then
    raise exception 'Pola daftar depot tidak ditemukan pada rc_private.list_users.'; end if;

  baru := replace(src,
    $q$ array(select depot_id from public.user_depot_access where user_id=p.id) as depots$q$,
    $q$ array(select depot_id from public.user_depot_access where user_id=p.id) as depots,$q$ || chr(10) ||
    $q$ array(select region from public.user_region_access where user_id=p.id order by region) as regions$q$);
  execute baru;
  raise notice 'list_users memuat region tiap akun.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_uid uuid; v_target uuid; v_role text; r jsonb; n_depot int; v_region text;
begin
  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
  r := public.rc_region_list();
  reset role;
  if (r->>'status') <> 'success' then raise exception 'GAGAL: rc_region_list.'; end if;
  if jsonb_array_length(r->'rows') = 0 then
    raise notice 'Depot Master belum punya region; penetapan tidak diuji.';
    raise notice 'Pemeriksaan lolos.';
    return;
  end if;
  v_region := r->'rows'->0->>'region';

  -- Penetapan sungguhan pada sebuah akun, lalu dikembalikan. Jangkauannya harus benar-benar
  -- bertambah sesuai isi region itu.
  select id, role into v_target, v_role from public.profiles
   where coalesce(status,'')='active' and lower(coalesce(role,'')) not like '%system%'
   order by user_code limit 1;
  if v_target is null then raise notice 'Tidak ada akun untuk diuji.'; return; end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
  perform rc_private.tetapkan_region(v_target, jsonb_build_array(v_region));
  reset role;

  select count(*) into n_depot from public.user_depot_access a
    join public.depots d on d.id = a.depot_id
   where a.user_id = v_target and upper(btrim(coalesce(d.region,''))) = v_region;
  if n_depot = 0 then
    raise exception 'GAGAL: region % tidak menghasilkan jangkauan depot.', v_region; end if;

  -- Region karangan harus ditolak.
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
    perform rc_private.tetapkan_region(v_target, jsonb_build_array('REGION-KARANGAN'));
    reset role;
    raise exception 'GAGAL: region karangan diterima.';
  exception when others then
    reset role;
    if sqlerrm like 'GAGAL:%' then raise; end if;
  end;

  delete from public.user_region_access where user_id = v_target;
  perform rc_private.rebuild_depot_access(v_target);

  raise notice 'Region % menghasilkan % depot bagi akun uji.', v_region, n_depot;
  raise notice 'Pemeriksaan lolos.';
exception when others then
  reset role; raise;
end
$periksa$;
