-- Jalankan ini lebih dulu di Supabase Dashboard -> SQL Editor.
-- Query ini hanya membaca. Tidak ada yang diubah.
-- Gunakan hasilnya untuk menentukan migration mana yang masih perlu dijalankan.

select 'Migration tercatat' as bagian, version, name
from supabase_migrations.schema_migrations
order by version;

-- Penanda tiap migration. 'sudah' berarti jangan dijalankan ulang.
select 'Status objek' as bagian, label, case when ada then 'sudah' else 'BELUM' end as status
from (
 values
  ('20260916010000 input validation',
   to_regprocedure('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)') is not null),
  ('20260917010000 compat API',
   to_regprocedure('public.rc_legacy_bootstrap()') is not null),
  ('20260917020000 reset auth + signup',
   to_regprocedure('public.rc_review_request(text,boolean)') is not null)
) as t(label, ada);

-- Apa yang akan dihapus oleh migration reset auth. Periksa angkanya sebelum menjalankannya.
select 'Yang akan dihapus' as bagian,
 (select count(*) from auth.users) as auth_users,
 (select count(*) from public.profiles) as profiles,
 (select count(*) from public.user_permissions) as permissions,
 (select count(*) from public.user_depot_access) as depot_access,
 (select count(*) from public.profile_change_requests) as profile_requests;

-- Data bisnis. Angka ini harus tetap sama sesudah reset auth dijalankan.
select 'Data bisnis' as bagian,
 (select count(*) from public.claims) as claims,
 (select count(*) from public.customers) as customers,
 (select count(*) from public.campaigns) as campaigns,
 (select count(*) from public.depots) as depots,
 (select count(*) from public.claim_status_history) as history;

-- Sesudah migration reset auth diterapkan: apakah sudah ada System Manager.
-- Kalau kosong, pendaftar pertama lewat portal yang akan menjadi System Manager.
select 'System Manager' as bagian, user_code, full_name, status
from public.profiles where role='system manager';
