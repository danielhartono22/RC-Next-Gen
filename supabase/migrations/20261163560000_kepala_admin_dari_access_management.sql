-- ==========================================================================================
-- Depot Master: Kepala Admin diisi SEKALI dari Access Management
-- ==========================================================================================
-- Pemilik, 29 Oktober 2026: "untuk email done saya minta ke kepala admin masing masing ... dan
-- overwrite kepala admin adalah sesuai user di management access untuk pertama kali", dengan
-- pilihan: semua Admin depot itu; TO email Done = Kepala Admin, CC tetap; diisi sekali saja,
-- selanjutnya diubah manual di Depot Master.
--
--   Setiap depot yang punya akun peran Admin (aktif, ber-email) dengan akses ke depot itu
--   (Access Management > depot akun):
--     depot_profiles.kepala_admin       = nama akun-akun itu (dipisah koma)
--     depot_profiles.email_kepala_admin = email akun-akun itu (maks. 4, urut alfabet)
--   Nilai lama DITIMPA. Depot tanpa Admin tidak diubah (email Done-nya tetap jatuh ke pengaju /
--   user yang memproses Done, 20261163210000). Baris depot_profiles dibuat bila belum ada.
--   Sesudahnya tidak ada sinkron otomatis: perubahan akun di Access Management tidak menimpa
--   Depot Master. Migrasi ini hanya berjalan sekali per lingkungan (penanda di Log Activity).
--
-- Aturan TO email Done tidak berubah: Email Kepala Admin bila terisi (kini terisi dari sini).
-- ==========================================================================================

do $isi$
declare v_n integer; v_lewat integer; v_rinci jsonb;
begin
  if exists(select 1 from public.activity_logs where event_type = 'kepala_admin_dari_access_management') then
    raise notice 'Kepala Admin sudah pernah diisi dari Access Management; dilewati.';
    return;
  end if;

  with ka as (
    select a.depot_id,
           string_agg(coalesce(nullif(btrim(p.full_name), ''), p.user_code), ', ' order by lower(btrim(p.business_email))) nama,
           (array_agg(lower(btrim(p.business_email)) order by lower(btrim(p.business_email))))[1:4] email
      from public.user_depot_access a
      join public.profiles p on p.id = a.user_id
     where p.role = 'admin' and p.status = 'active' and coalesce(p.business_email, '') ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
     group by a.depot_id),
  tulis as (
    insert into public.depot_profiles as dp (depot_id, kepala_admin, email_kepala_admin, updated_at, updated_by)
    select ka.depot_id, ka.nama, array_to_string(ka.email, ', '), now(), null from ka
    on conflict (depot_id) do update set kepala_admin = excluded.kepala_admin, email_kepala_admin = excluded.email_kepala_admin, updated_at = now()
    returning dp.depot_id, dp.email_kepala_admin)
  select count(*), coalesce(jsonb_agg(jsonb_build_object('depot', d.depot_code, 'email', t.email_kepala_admin) order by d.depot_code), '[]')
    into v_n, v_rinci
    from tulis t join public.depots d on d.id = t.depot_id;

  select count(*) into v_lewat from public.depots d
   where not exists(select 1 from public.user_depot_access a join public.profiles p on p.id = a.user_id
                     where a.depot_id = d.id and p.role = 'admin' and p.status = 'active'
                       and coalesce(p.business_email, '') ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (null, 'kepala_admin_dari_access_management',
    jsonb_build_object('detail', 'Depot Master: Kepala Admin dan Email Kepala Admin ' || v_n || ' depot diisi dari akun Admin di Access Management (sekali); '
                                 || v_lewat || ' depot tanpa Admin tidak diubah',
                       'jumlah', v_n, 'tanpaAdmin', v_lewat, 'depot', v_rinci, 'migrasi', '20261163560000'),
    'Profil Depot', 'Profil Depot', 'Profil Depot');
  raise notice 'Kepala Admin diisi untuk % depot; % depot tanpa Admin.', v_n, v_lewat;
end $isi$;
