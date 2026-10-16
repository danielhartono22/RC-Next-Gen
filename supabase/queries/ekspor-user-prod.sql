-- ==========================================================================================
-- Ekspor user PROD untuk diduplikasi ke DEV - HANYA MEMBACA
-- ==========================================================================================
-- Jalankan di SQL Editor Supabase project PROD (vvojshgcduqlugngpzkj). Kueri ini tidak
-- mengubah apa pun: hanya SELECT. Hasilnya satu sel JSON; salin isinya ke sebuah berkas,
-- misalnya .runtime/user-prod.json (folder .runtime tidak ikut git), lalu jalankan:
--
--   node scripts/salin-user-prod-ke-dev.mjs --berkas .runtime/user-prod.json
--
-- ISINYA
--   * user yang belum diarsip: kode, nama, peran, status, departemen, depot rumah, alamat
--     login internal (hash User ID, bukan email pribadi), dan HASH PIN (bcrypt) supaya setiap
--     orang dapat masuk ke dev dengan PIN prod-nya sendiri. PIN aslinya tidak pernah ada di
--     database, hanya hash-nya.
--       -> Bila tidak ingin PIN dev sama dengan prod, hapus baris 'password_hash' di bawah;
--          skrip impor lalu memakai satu PIN uji untuk semua.
--   * izin per modul dan per tab, penugasan depot, region, dan pembinaan supervisor
--   * daftar depot beserta singkatan dan region, supaya depot dev ikut prod
--
-- Email bisnis TIDAK diekspor: di dev semua diganti <kode>@dev.invalid, supaya tidak ada
-- email yang bisa sampai ke orang sungguhan.
-- ==========================================================================================
select jsonb_build_object(
  'diekspor_pada', now(),
  'sumber', 'vvojshgcduqlugngpzkj',
  'depots', (
    select jsonb_agg(jsonb_build_object(
             'kode', d.depot_code, 'nama', d.depot_name, 'abbr', d.abbr, 'region', d.region)
           order by d.depot_code)
      from public.depots d where d.archived_at is null),
  'users', (
    select jsonb_agg(jsonb_build_object(
             'user_code', p.user_code,
             'full_name', p.full_name,
             'role', p.role,
             'status', p.status,
             'department', p.department,
             'home_depot', hd.depot_code,
             'must_change_password', p.must_change_password,
             'login_email', u.email,
             'password_hash', u.encrypted_password,
             'permissions', coalesce((select jsonb_agg(x.permission_code order by x.permission_code)
                                        from public.user_permissions x where x.user_id = p.id), '[]'::jsonb),
             'tabs', coalesce((select jsonb_object_agg(t.tab_code, t.allowed)
                                 from rc_private.user_tab_access t where t.user_id = p.id), '{}'::jsonb),
             'grants', coalesce((select jsonb_agg(jsonb_build_object('depot', gd.depot_code, 'kind', g.kind)
                                                  order by gd.depot_code, g.kind)
                                   from public.user_depot_grants g join public.depots gd on gd.id = g.depot_id
                                  where g.user_id = p.id), '[]'::jsonb),
             'regions', coalesce((select jsonb_agg(r.region order by r.region)
                                    from public.user_region_access r where r.user_id = p.id), '[]'::jsonb),
             'membina', coalesce((select jsonb_agg(o.user_code order by o.user_code)
                                    from public.user_supervision s join public.profiles o on o.id = s.osc_id
                                   where s.supervisor_id = p.id), '[]'::jsonb))
           order by p.user_code)
      from public.profiles p
      join auth.users u on u.id = p.id
      left join public.depots hd on hd.id = p.home_depot_id
     where p.archived_at is null)
) as ekspor;
