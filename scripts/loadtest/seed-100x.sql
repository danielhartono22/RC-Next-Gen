\set ON_ERROR_STOP on
do $$ begin raise exception 'Historical 100x seed disabled. Use scripts/performance/import-dummy.psql on EMPTY isolated staging'; end $$;
-- ==========================================================================================
-- Dataset Scaling Plan: 100x volume transaksi, distribusi realistis
-- ==========================================================================================
--
--  ####  JANGAN JALANKAN INI DI PROJECT PRODUKSI  ####
--
-- Berkas ini MENULIS ratusan ribu baris. Penjagaan di bagian pertama menolak berjalan bila
-- database yang dituju memuat penanda produksi. Hapus penjagaan itu hanya bila Anda benar-benar
-- sedang berada di project staging.
--
-- MENGAPA BUKAN SEKADAR MENGGANDAKAN 100 KALI
-- Pemilik meminta distribusi realistis, dan itu bukan kerewelan. Menggandakan baris yang sama
-- 100 kali menghasilkan basis data yang SELALU LEBIH CEPAT daripada kenyataan: nilai yang
-- berulang membuat statistik planner menganggap selektivitasnya tinggi, satu depot yang sama
-- membuat seluruh indeks memusat di beberapa halaman, dan cache menjadi sangat efektif. Uji
-- seperti itu akan lulus dengan gemilang lalu runtuh di hari pertama dipakai.
--
-- Yang ditiru di sini:
--   * Kemiringan antardepot. Di produksi sekarang, sepuluh depot teratas memegang bagian
--     terbesar klaim. Pembagiannya di bawah memakai bobot, bukan rata.
--   * Sebaran status mengikuti perbandingan yang ada sekarang (done 42%, not_yet 30%,
--     released 16%, claimed 11%, sisanya kecil).
--   * Nilai cb_net diambil dari sebaran nyata, bukan angka bulat yang sama.
--   * Tanggal tersebar 24 bulan ke belakang, bukan satu hari yang sama.
--   * Riwayat status: dokumen yang sudah jauh berjalan punya lebih banyak baris riwayat.
--
-- MASTER TIDAK IKUT 100x
-- Depot adalah bangunan fisik dan campaign adalah program yang dirancang orang; keduanya tidak
-- bertambah seratus kali lipat hanya karena transaksinya bertambah. Yang dikalikan adalah tabel
-- transaksi. Depot dinaikkan sedikit (52 -> 60) dan campaign ke 500 supaya matriks Timetable
-- dan filter laporan ikut teruji pada ukuran yang lebih besar, bukan tetap sepele.
--
-- Sasaran (dari baseline 20 September 2026):
--   customers             2.068 ->   206.800   (100x)
--   claims                2.756 ->   275.600   (100x)
--   claim_sensitive       2.757 ->   275.600   (100x)
--   claim_status_history  2.857 ->  ~826.000   (rata-rata 3 baris per dokumen)
--   customer_depots       1.428 ->   ~250.000
--   activity_logs           185 ->   500.000   (jejak 300 pengguna selama berbulan-bulan)
--   campaigns               100 ->       500
--   depots                   52 ->        60
--   profiles                  6 ->       300   (dibuat terpisah, lihat bagian 7)
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 0. Penjagaan
-- ------------------------------------------------------------------------------------------
do $jaga$
begin
  -- Penanda produksi: akun System Manager sungguhan dan alamat email depot yang nyata.
  if exists(select 1 from public.profiles where user_code = 'DANIEL')
     or exists(select 1 from public.depots where email_to ilike '%@nipseapaint.com%') then
    raise exception
      'Database ini memuat data produksi (akun DANIEL dan/atau alamat email depot asli). '
      'Seed 100x MENOLAK berjalan. Pakai project staging.';
  end if;
end $jaga$;

\timing on

-- ------------------------------------------------------------------------------------------
-- 1. Depot: 52 -> 60
-- ------------------------------------------------------------------------------------------
insert into public.depots(depot_code, depot_name, region, abbr)
select 'LT' || lpad(g::text,2,'0'),
       'Depot Uji ' || g,
       (array['1A','1B','2A','2B','3A'])[1 + (g % 5)],
       'LT' || lpad(g::text,2,'0')
from generate_series(1,8) g
on conflict (depot_code) do nothing;

-- ------------------------------------------------------------------------------------------
-- 2. Campaign: 100 -> 500, periode tersebar 24 bulan
-- ------------------------------------------------------------------------------------------
insert into public.campaigns(campaign_code, campaign_name, period_start, period_end,
                             period_start_text, period_end_text, cashback_type, tax_status, status)
select
  'LT' || lpad(g::text,5,'0'),
  'Promo Uji Beban ' || g || ' ' || to_char(d, 'Mon YYYY'),
  d::date,
  (d + interval '89 days')::date,
  to_char(d,'DD-Mon-YY'),
  to_char(d + interval '89 days','DD-Mon-YY'),
  (array['Transfer','CN','Rebate','Transfer','Transfer'])[1 + (g % 5)],
  (array['PT Nipsea Paint and Chemicals','Customer','Rebate Non Tax'])[1 + (g % 3)],
  case when g % 20 = 0 then 'inactive' else 'active' end
from generate_series(1,400) g
cross join lateral (select (now() - ((g % 24) || ' months')::interval) as d) x
on conflict (campaign_code) do nothing;

-- ------------------------------------------------------------------------------------------
-- 3. Customers: 2.068 -> 206.800
-- ------------------------------------------------------------------------------------------
-- Nama toko dibuat bervariasi supaya pencarian ILIKE benar-benar harus bekerja. Nama yang
-- seragam membuat indeks trigram tampak jauh lebih baik daripada kenyataannya.
insert into public.customers(customer_code, customer_name, top_text, ktp, npwp,
                             account_number, account_name, bank, contact_person)
select
  'LTC' || lpad(g::text,7,'0'),
  (array['TOKO','UD','CV','PT','MITRA','SUMBER','SINAR','JAYA'])[1 + (g % 8)] || ' ' ||
  (array['MAKMUR','SEJAHTERA','ABADI','BERKAH','MANDIRI','UTAMA','LESTARI','AGUNG',
         'BAHAGIA','CEMERLANG','DAMAI','ELOK'])[1 + (g % 12)] || ' ' ||
  (array['MEDAN','JAKARTA','BANDUNG','SURABAYA','SEMARANG','PALEMBANG','MAKASSAR'])[1 + (g % 7)] ||
  ' ' || g,
  (array['30','45','60','90'])[1 + (g % 4)],
  case when g % 3 = 0 then lpad((1000000000000000 + g)::text, 16, '0') else null end,
  case when g % 3 <> 0 then lpad((900000000000000 + g)::text, 15, '0') else null end,
  lpad((1000000000 + g)::text, 10, '0'),
  'PEMILIK ' || g,
  (array['BCA','MANDIRI','BNI','BRI','PERMATA'])[1 + (g % 5)],
  'CP ' || g || ' 08' || lpad((100000000 + g)::text, 10, '0')
from generate_series(1,204732) g
on conflict (customer_code) do nothing;

-- ------------------------------------------------------------------------------------------
-- 4. customer_depots: pemetaan toko ke depot, MIRING bukan rata
-- ------------------------------------------------------------------------------------------
-- Bobot: sepuluh depot teratas memegang porsi jauh lebih besar, meniru keadaan sekarang.
-- Tanpa kemiringan ini, setiap depot punya jumlah klaim yang sama dan tidak ada satu pun
-- "depot berat" - padahal depot berat itulah yang menentukan P99.
insert into public.customer_depots(customer_id, depot_id)
select c.id, d.id
from (
  select id, row_number() over (order by customer_code) rn from public.customers
) c
join lateral (
  select id, row_number() over (order by depot_code) rn
    from public.depots
) d on d.rn = 1 + (
  -- distribusi pangkat: rn kecil (depot awal) jauh lebih sering terpilih
  floor(power(random(), 2.2) * (select count(*) from public.depots))::int
)
on conflict do nothing;

-- ------------------------------------------------------------------------------------------
-- 5. Claims: 2.756 -> 275.600
-- ------------------------------------------------------------------------------------------
-- Sebaran status mengikuti perbandingan produksi:
--   done 42% | not_yet 30% | released 16% | claimed 11% | submitted/on_hold/expired sisanya
insert into public.claims(no_doc, campaign_id, customer_id, depot_id, status,
                          cb_net, net_value, volume, period_start, period_end,
                          uploaded_at, created_at, updated_at, version_no)
select
  'LT/' || to_char(x.tgl,'YYYYMM') || '/' || lpad(g::text, 8, '0'),
  x.campaign_id, x.customer_id, x.depot_id,
  case
    when r < 0.42 then 'done'
    when r < 0.72 then 'not_yet'
    when r < 0.88 then 'released'
    when r < 0.99 then 'claimed'
    when r < 0.995 then 'submitted'
    when r < 0.998 then 'on_hold'
    else 'expired' end,
  -- Nilai cb_net: sebaran lognormal kasar, bukan angka bulat yang sama.
  round((exp(random() * 3.2) * 250000)::numeric, -3),
  round((exp(random() * 3.2) * 2500000)::numeric, -3),
  round((random() * 400 + 10)::numeric, 2),
  x.period_start, x.period_end,
  x.tgl, x.tgl, x.tgl + (random() * interval '30 days'),
  1
from generate_series(1, 272844) g
cross join lateral (
  select cd.customer_id, cd.depot_id,
         ca.id as campaign_id, ca.period_start, ca.period_end,
         (now() - (random() * interval '720 days')) as tgl,
         random() as r0
    from public.customer_depots cd
    join lateral (select id, period_start, period_end from public.campaigns
                   where period_start is not null
                   order by random() limit 1) ca on true
   offset floor(random() * greatest((select count(*) from public.customer_depots),1))
   limit 1
) x
cross join lateral (select random() as r) rr
on conflict (no_doc) do nothing;

-- ------------------------------------------------------------------------------------------
-- 6. claim_sensitive dan claim_status_history
-- ------------------------------------------------------------------------------------------
insert into rc_private.claim_sensitive(claim_id, ktp, npwp, bank, account_number, account_name, top_text)
select c.id, cu.ktp, cu.npwp, cu.bank, cu.account_number, cu.account_name, cu.top_text
from public.claims c join public.customers cu on cu.id = c.customer_id
where c.no_doc like 'LT/%'
on conflict (claim_id) do nothing;

-- Riwayat: makin jauh dokumen berjalan, makin banyak barisnya. Dokumen 'done' punya empat
-- baris (upload, submit, release, claim, done), 'not_yet' hanya satu.
insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, created_at)
select c.id, null,
       s.dari, s.ke, s.aksi,
       c.created_at + (s.urut * interval '3 days')
from public.claims c
cross join lateral (
  values (1,'not_yet','submitted','submit'),
         (2,'submitted','released','release'),
         (3,'released','claimed','claim'),
         (4,'claimed','done','clearing')
) s(urut, dari, ke, aksi)
where c.no_doc like 'LT/%'
  and s.urut <= case c.status
        when 'done' then 4 when 'claimed' then 3
        when 'released' then 2 when 'submitted' then 1 else 0 end;

-- ------------------------------------------------------------------------------------------
-- 7. activity_logs: 500.000
-- ------------------------------------------------------------------------------------------
insert into public.activity_logs(actor_id, depot_id, event_type, details, created_at)
select null, d.id,
       (array['login','upload_claim','release','claim','clearing','view_report'])[1 + (g % 6)],
       jsonb_build_object('uji', true, 'n', g),
       now() - (random() * interval '365 days')
from generate_series(1, 500000) g
cross join lateral (select id from public.depots order by random() limit 1) d;

-- ------------------------------------------------------------------------------------------
-- 8. Statistik planner WAJIB diperbarui
-- ------------------------------------------------------------------------------------------
-- Tanpa ANALYZE, planner masih memakai statistik dari 2.756 baris dan memilih rencana yang
-- sama sekali tidak cocok untuk 275.600 baris. Uji beban di atasnya akan mengukur hal yang salah.
analyze public.claims;
analyze public.customers;
analyze public.customer_depots;
analyze public.campaigns;
analyze public.depots;
analyze public.claim_status_history;
analyze public.activity_logs;
analyze rc_private.claim_sensitive;

select 'Seed selesai' as hasil,
  (select count(*) from public.claims) as claims,
  (select count(*) from public.customers) as customers,
  (select count(*) from public.claim_status_history) as history,
  (select count(*) from public.activity_logs) as logs,
  pg_size_pretty(pg_database_size(current_database())) as ukuran;
