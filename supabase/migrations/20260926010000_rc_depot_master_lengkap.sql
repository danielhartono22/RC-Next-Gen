-- ==========================================================================================
-- Master depot dilengkapi menjadi 50 depot, dan baris uji sintetis dibersihkan
-- ==========================================================================================
-- Sebabnya ditemukan dengan membaca isi project yang sedang berjalan, bukan dari dugaan:
-- public.depots hanya memuat empat depot nyata (4A, 4C, 4D, 4F) ditambah satu baris uji
-- bernama "Synthetic E2E". Sementara itu data-rc/ListCampaign.csv, sumber yang sama yang
-- dipakai pemilik, memuat 50 depot.
--
-- Akibat yang terlihat oleh pengguna:
--  1. Daftar pilihan depot pada halaman Sign Up hampir kosong, dan memuat satu nama uji.
--  2. Pengguna depot mana pun di luar keempat kode itu tidak dapat didaftarkan, sehingga
--     modul Release, Claim Process dan Bulk Process tampak kosong baginya.
--  3. Baris uji "Synthetic E2E" terlihat oleh pendaftar sebagai pilihan yang sah.
--
-- Migration 20260923010000 hanya MEMPERBARUI abbr pada depot yang sudah ada; ia memang tidak
-- pernah menambahkan depot baru. Berkas inilah yang menambahkannya.
--
-- Aman dijalankan berulang: penambahan memakai ON CONFLICT, penghapusan memakai penjagaan
-- referensi, dan tidak ada satu pun data bisnis yang dihapus.
-- ==========================================================================================

-- 1. Kolom abbr dipastikan ada sebelum dipakai (20260923010000 sudah membuatnya; baris ini
--    hanya membuat berkas ini berdiri sendiri).
alter table public.depots add column if not exists abbr text;

-- 2. Seluruh depot dari ListCampaign.csv. Kode pada kolom DC, nama pada Depot Name, dan
--    singkatan pada Abbr - persis seperti yang diminta pemilik.
with sumber(depot_code,depot_name,abbr) as (values
 ('1A','Jakarta ( TU )','JKT'),
 ('1B','Bahagia','BHG'),
 ('1C','Cikampek','CKP'),
 ('1D','THK','THK'),
 ('1E','Cikarang','CKR'),
 ('1F','Bandung','BDG'),
 ('1G','Lampung','LPG'),
 ('1H','Jambi','JBI'),
 ('1I','Padang','PDG'),
 ('1J','Palembang','PLB'),
 ('1K','Bengkulu','BKL'),
 ('1L','Bangka','BKA'),
 ('1M','Belitung','BLG'),
 ('1N','Solo','SLO'),
 ('1O','Yogyakarta','YJK'),
 ('1P','Semarang','SMR'),
 ('1Q','Cirebon','CRB'),
 ('1R','Tangerang','TGR'),
 ('1S','Bogor','BGR'),
 ('1T','Pontianak','PTN'),
 ('1U','Pekan Baru','PKB'),
 ('1V','Purwokerto','PWT'),
 ('1W','Tasik Malaya','TSM'),
 ('1X','Serang','SRG'),
 ('1Y','Pati','PTI'),
 ('1Z','Bandar Jaya','BDJ'),
 ('4A','Medan','MDN'),
 ('4C','Pematang Siantar','PST'),
 ('4D','Rantau Prapat','RPP'),
 ('4F','Padang Sidempuan','PSN'),
 ('5A','Pemalang','PML'),
 ('5B','Bukittinggi','BKT'),
 ('5C','Cianjur','CJR'),
 ('5D','Baturaja','BRJ'),
 ('5F','Singkawang','SKW'),
 ('5G','Sintang','STG'),
 ('5H','Garut','GUT'),
 ('5I','Kopo','KPO'),
 ('5J','Ketapang','KTP'),
 ('5K','Jatiasih','JAS'),
 ('5L','Lubuklinggau','LLG'),
 ('5M','Blora','BLR'),
 ('5N','Kebumen','KBM'),
 ('5O','Serpong','SPG'),
 ('5P','Subang','SBG'),
 ('5Q','Malimping','MPG'),
 ('5R','Maja','MJA'),
 ('5U','Muara Bungo','MBG'),
 ('5V','Solok','SLK'),
 ('5W','Sawangan','SWG')
)
insert into public.depots(depot_code,depot_name,abbr)
select depot_code,depot_name,abbr from sumber
on conflict(depot_code) do update
  set depot_name=excluded.depot_name,
      abbr=coalesce(public.depots.abbr,excluded.abbr);

-- 3. Baris uji sintetis dibuang, tetapi hanya bila benar-benar tidak dirujuk apa pun.
--    Bila ternyata ada yang merujuknya, baris itu dibiarkan dan tidak ada yang rusak.
delete from public.depots d
where d.depot_code like '\_\_rc\_e2e\_%'
  and not exists(select 1 from public.user_depot_access x where x.depot_id=d.id)
  and not exists(select 1 from public.customer_depots x where x.depot_id=d.id)
  and not exists(select 1 from public.claims x where x.depot_id=d.id)
  and not exists(select 1 from public.activity_logs x where x.depot_id=d.id)
  and not exists(select 1 from public.profile_change_requests x where x.depot_id=d.id);

create or replace function rc_private.marker_20260926() returns boolean
language sql immutable set search_path='' as $$select true$$;
revoke all on function rc_private.marker_20260926() from public,anon;
grant execute on function rc_private.marker_20260926() to authenticated;

-- 4. Ringkasan. Kolom abbr_tidak_terpakai penting dibaca: rc_private.next_document menolak
--    abbr yang bukan 2-10 huruf atau angka, sehingga depot dengan abbr bergaris miring
--    (misalnya Jakarta TU dengan "JKT/TU") tidak akan bisa menghasilkan No Doc sampai
--    singkatannya diputuskan ulang oleh pemilik.
select 'Master depot dilengkapi' as hasil,
 (select count(*) from public.depots) as total_depot,
 (select count(*) from public.depots where abbr is not null) as punya_abbr,
 (select count(*) from public.depots where depot_code like '\_\_rc\_e2e\_%') as sisa_baris_uji,
 (select string_agg(depot_code||' ('||abbr||')',', ' order by depot_code)
    from public.depots where abbr is not null and abbr !~ '^[A-Z0-9]{2,10}$') as abbr_tidak_terpakai;
