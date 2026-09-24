-- ==========================================================================================
-- Membuang sisa data uji sintetis "Synthetic E2E"
-- ==========================================================================================
-- OPSIONAL, DAN INI SATU-SATUNYA BERKAS YANG MENGHAPUS BARIS. Jalankan hanya bila Anda
-- memang ingin sisa data uji itu hilang.
--
-- Apa yang dihapus, seluruhnya dibuat oleh scripts/test_rc_e2e_http.py pada 15 September 2026
-- dan semuanya berawalan __rc_e2e_ :
--   depot    __rc_e2e_1789457198954  "Synthetic E2E"
--   customer 1 baris berawalan __rc_e2e_
--   campaign 1 baris berawalan __rc_e2e_
--   claim    __rc_e2e_1789457198954  status released, CB Net 85.000
--
-- Mengapa perlu: claim uji itu berstatus released, sehingga ia ikut muncul di antrean
-- Claim to Finance sebagai baris palsu, dan depot "Synthetic E2E" tampil sebagai pilihan yang
-- sah di halaman Sign Up.
--
-- Tidak ada satu pun baris nyata yang tersentuh: setiap perintah disaring ketat pada awalan
-- __rc_e2e_ (garis miring terbalik di bawah ini meng-escape underscore, yang pada LIKE adalah
-- wildcard satu karakter).
--
-- Aman dijalankan berulang; sesudah pertama kali tidak ada lagi yang cocok.
-- ==========================================================================================

-- Urutannya dari anak ke induk supaya tidak melanggar foreign key.
delete from public.claim_status_history h
 using public.claims c where h.claim_id=c.id and c.no_doc like '\_\_rc\_e2e\_%';

delete from rc_private.claim_sensitive s
 using public.claims c where s.claim_id=c.id and c.no_doc like '\_\_rc\_e2e\_%';

delete from public.claims where no_doc like '\_\_rc\_e2e\_%';

delete from public.activity_logs a
 using public.depots d where a.depot_id=d.id and d.depot_code like '\_\_rc\_e2e\_%';

delete from public.user_depot_access x
 using public.depots d where x.depot_id=d.id and d.depot_code like '\_\_rc\_e2e\_%';

delete from public.customer_depots x
 using public.depots d where x.depot_id=d.id and d.depot_code like '\_\_rc\_e2e\_%';

delete from public.customers where customer_code like '\_\_rc\_e2e\_%';
delete from public.campaigns where campaign_code like '\_\_rc\_e2e\_%';
delete from public.depots   where depot_code   like '\_\_rc\_e2e\_%';

create or replace function rc_private.marker_20260927() returns boolean
language sql immutable set search_path='' as $$select true$$;
revoke all on function rc_private.marker_20260927() from public,anon;
grant execute on function rc_private.marker_20260927() to authenticated;

select 'Data uji sintetis dibersihkan' as hasil,
 (select count(*) from public.depots    where depot_code    like '\_\_rc\_e2e\_%') as sisa_depot,
 (select count(*) from public.claims    where no_doc        like '\_\_rc\_e2e\_%') as sisa_claim,
 (select count(*) from public.customers where customer_code like '\_\_rc\_e2e\_%') as sisa_customer,
 (select count(*) from public.campaigns where campaign_code like '\_\_rc\_e2e\_%') as sisa_campaign,
 (select count(*) from public.depots) as total_depot_sekarang,
 (select count(*) from public.claims) as total_claim_sekarang;
