-- ==========================================================================================
-- Modul Release, Claim Process dan Bulk Process kosong karena RPC-nya melempar error
-- ==========================================================================================
-- Ini ditemukan dengan memanggil RPC-nya langsung sebagai akun DANIEL, bukan dengan menduga:
--
--   ERROR: 42501 permission denied for table claim_sensitive
--   CONTEXT: ... public.rc_legacy_workflow() ...
--
-- public.rc_legacy_workflow membaca rc_private.claim_sensitive untuk mengambil TOP, KTP,
-- NPWP, bank dan nomor rekening. Fungsi itu SECURITY INVOKER - dan memang harus begitu,
-- karena pemisahan antar depot pada kueri di dalamnya bergantung sepenuhnya pada RLS tabel
-- public.claims; kueri itu sendiri hanya menyaring status, tidak menyaring depot. Bila
-- fungsinya diubah menjadi SECURITY DEFINER, RLS terlewati dan setiap pengguna akan melihat
-- depot orang lain. Jadi bukan mode keamanan fungsi yang salah.
--
-- Yang salah adalah rc_private.claim_sensitive: RLS-nya aktif tetapi tidak memiliki satu pun
-- policy, dan peran authenticated tidak diberi hak apa pun atasnya. Akibatnya setiap
-- pembacaan ditolak, rc_legacy_workflow gagal seluruhnya, dan keempat antrean tampil kosong
-- tanpa satu pun pesan yang sampai ke layar.
--
-- Perbaikannya mengikuti pola yang sudah dipakai tabel lain di project ini (bandingkan policy
-- depots_scoped): beri hak baca kepada authenticated, lalu batasi barisnya lewat policy yang
-- mengikuti akses depot pemilik claim. Dengan begitu kerahasiaan KTP, NPWP dan rekening tetap
-- dijaga per depot, dan System Manager tetap melihat seluruhnya karena rc_private.can_access
-- sudah mengenal perannya sejak 20260924010000.
--
-- Hanya hak baca yang diberikan. Penulisan tetap hanya lewat rc_private.mutate_claims_unchecked
-- yang SECURITY DEFINER.
--
-- Diuji lebih dulu di dalam transaksi yang dibatalkan, sebagai akun DANIEL:
--   sebelum : seluruh pemanggilan gagal dengan 42501
--   sesudah : Release 79, Claim to Finance 347, Clearing 90, Bulk Rebate 218
--
-- Aman dijalankan berulang.
-- ==========================================================================================

grant select on rc_private.claim_sensitive to authenticated;

drop policy if exists claim_sensitive_scoped on rc_private.claim_sensitive;
create policy claim_sensitive_scoped on rc_private.claim_sensitive
 for select to authenticated
 using (exists(select 1 from public.claims c
               where c.id = claim_sensitive.claim_id
                 and rc_private.can_access(c.depot_id)));

create or replace function rc_private.marker_20260926() returns boolean
language sql immutable set search_path='' as $$select true$$;
revoke all on function rc_private.marker_20260926() from public,anon;
grant execute on function rc_private.marker_20260926() to authenticated;

-- Ringkasan. Bila keempat angka di bawah masih nol sesudah Run, penyebabnya bukan lagi hak
-- akses tabel ini dan perlu diperiksa ulang.
select 'Hak baca claim_sensitive dipasang' as hasil,
 (select count(*) from pg_policies
   where schemaname='rc_private' and tablename='claim_sensitive') as jumlah_policy,
 (select count(*) from public.claims where status='submitted') as antrean_release,
 (select count(*) from public.claims where status='released') as antrean_claim_finance,
 (select count(*) from public.claims where status='claimed') as antrean_clearing,
 'Logout lalu login lagi, kemudian buka modul Release' as langkah_berikutnya;
