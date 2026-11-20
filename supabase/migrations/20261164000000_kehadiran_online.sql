-- ==========================================================================================
-- Indikator online di daftar akun (Access Management)
-- ==========================================================================================
-- Pemilik, 14 November 2026:
--   "bisakah saya tau mana admin yg online? berdasarkan akun list jika online ada tanda hijau"
--   "ok jalankan yang dengan sinyal tiap 2 menit dengan lampu indikator kalo hijau online di
--    samping kolom user id"
--
-- Setiap tab RC yang sedang terlihat mengirim sinyal rc_hadir() tiap 2 menit. Server mencatat
-- waktu terakhirnya di rc_private.kehadiran (satu baris per akun, tanpa riwayat). Daftar akun
-- (rc_legacy_manageable) membawa dua kunci baru per akun:
--   online         true bila sinyal terakhir kurang dari 5 menit lalu dan akun belum keluar
--   terakhirAktif  'DD-Mon-YYYY HH24:MI' WIB, atau '' bila belum pernah tercatat
-- Yang terlihat mengikuti daftar akun yang sudah ada (yurisdiksi pemanggil); tidak ada layar baru.
-- Sinyal hanya menulis baris milik pemanggil, paling sering sekali per 60 detik. Akun yang tidak
-- aktif (pending, suspended, arsip) tidak dicatat. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

create table if not exists rc_private.kehadiran (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  terakhir_aktif timestamptz not null default now(),
  keluar_pada timestamptz
) with (fillfactor = 70);
alter table rc_private.kehadiran enable row level security;
revoke all on rc_private.kehadiran from public, anon, authenticated;

-- Sinyal dari layar. p_keluar = true saat pengguna menekan Logout.
create or replace function public.rc_hadir(p_keluar boolean default false)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'Masuk lebih dulu' using errcode = '42501'; end if;
  if not exists(select 1 from public.profiles p where p.id = v and p.status = 'active') then
    return jsonb_build_object('status', 'success', 'tercatat', false); end if;
  if coalesce(p_keluar, false) then
    update rc_private.kehadiran set keluar_pada = now() where user_id = v;
    return jsonb_build_object('status', 'success', 'tercatat', true, 'online', false);
  end if;
  insert into rc_private.kehadiran as k (user_id, terakhir_aktif, keluar_pada) values (v, now(), null)
  on conflict (user_id) do update set terakhir_aktif = excluded.terakhir_aktif, keluar_pada = null
   where k.terakhir_aktif < now() - interval '60 seconds' or k.keluar_pada is not null;
  return jsonb_build_object('status', 'success', 'tercatat', true, 'online', true);
end $f$;
revoke all on function public.rc_hadir(boolean) from public, anon;
grant execute on function public.rc_hadir(boolean) to authenticated;

-- Peta kehadiran per User ID, untuk digabung ke daftar akun yang sudah disaring yurisdiksi.
create or replace function rc_private.kehadiran_peta()
returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce(jsonb_object_agg(upper(p.user_code), jsonb_build_object(
           'online', k.keluar_pada is null and k.terakhir_aktif > now() - interval '5 minutes',
           'terakhirAktif', to_char(k.terakhir_aktif at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'))), '{}'::jsonb)
    from rc_private.kehadiran k join public.profiles p on p.id = k.user_id;
$f$;
revoke all on function rc_private.kehadiran_peta() from public, anon;
grant execute on function rc_private.kehadiran_peta() to authenticated;

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('public.rc_legacy_manageable()'::regprocedure), E'\r', '');
  if src !~ '20261164000000' then
    src := pg_temp.ganti(src, $p$then rc_private.legacy_users() else '[]'::jsonb end,$p$,
      $p$then (
     -- 20261164000000: indikator online; urutan dan isi daftar tidak berubah.
     select coalesce(jsonb_agg(u.x || coalesce(h.peta -> upper(u.x->>'userId'), jsonb_build_object('online', false, 'terakhirAktif', '')) order by u.urut), '[]'::jsonb)
       from jsonb_array_elements(rc_private.legacy_users()) with ordinality u(x, urut)
       cross join (select rc_private.kehadiran_peta() peta) h)
   else '[]'::jsonb end,$p$, 1, 'manageable online');
    execute src;
  end if;
end $tambal$;

do $cek$
begin
  if pg_get_functiondef('public.rc_legacy_manageable()'::regprocedure) !~ 'kehadiran_peta' then raise exception 'GAGAL: daftar akun'; end if;
  if has_function_privilege('anon', 'public.rc_hadir(boolean)', 'execute') then raise exception 'GAGAL: rc_hadir terbuka untuk anon'; end if;
  if has_table_privilege('authenticated', 'rc_private.kehadiran', 'select') then raise exception 'GAGAL: tabel kehadiran terbaca langsung'; end if;
end $cek$;
