-- Lihat semua akun yang ada sekarang. Hanya membaca, tidak mengubah apa pun.
-- Supabase Dashboard -> SQL Editor -> tempel -> Run.
--
-- Pendaftar pertama sesudah reset otomatis menjadi System Manager. Kalau Anda mendapat
-- pesan "menunggu persetujuan", berarti ada profil lain yang terdaftar lebih dulu.
-- Baris paling atas pada hasil di bawah adalah akun tersebut.

select
  user_code                                   as user_id,
  full_name                                   as nama,
  role,
  status,
  suffix_num                                  as suffix_batch,
  to_char(registered_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI:SS') as waktu_daftar,
  (select count(*) from public.user_permissions up where up.user_id=p.id) as jml_permission,
  (select count(*) from public.user_depot_access ud where ud.user_id=p.id) as jml_depot
from public.profiles p
order by registered_at;

-- Jumlah akun Auth harus sama dengan jumlah profil di atas. Kalau Auth lebih banyak,
-- ada akun yang dibuat sebelum trigger pendaftaran terpasang.
select
  (select count(*) from auth.users)     as akun_auth,
  (select count(*) from public.profiles) as profil,
  (select count(*) from public.profiles where role='system manager' and status='active') as system_manager_aktif;
