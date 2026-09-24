-- ==========================================================================================
-- Fondasi modul Report dan Timetable
-- ==========================================================================================
-- Modul Report dan Timetable memindahkan RC_Reporting_AppsScript ke dalam RC. Sebagian besar
-- sistem lama itu ada hanya untuk mengakali spreadsheet - konsolidasi tujuh sumber, deteksi
-- perubahan lewat signature, penjadwalan sync, dan penjagaan agar input manual tetap menempel
-- pada barisnya - dan semuanya tidak diperlukan lagi karena public.claims memang sudah menjadi
-- satu-satunya sumber. Yang benar-benar dipindahkan hanyalah perhitungannya.
--
-- Berkas ini menyiapkan empat hal yang belum ada datanya di RC. Ketiadaan itu ditemukan dengan
-- membaca isi database, bukan dari asumsi.
--
-- 1. REGION
--    Tujuh region pada sistem lama berasal dari tujuh spreadsheet sumber, yang justru sudah
--    digantikan RC. Kolom Region pada ListCust.csv tidak dapat dipakai: 4.358 baris kosong,
--    92 berisi #N/A, dan yang terisi menulis "5" untuk depot berkode 4A, 4C, 4D dan 4F.
--    Atas keputusan pemilik, Region menjadi kolom tersendiri pada master depot yang diisi
--    manusia, bukan diturunkan dari kode.
--
-- 2. PERIODE CAMPAIGN
--    Tersimpan sebagai teks. Bentuknya konsisten D-Bulan-YY, tetapi nama bulannya campuran
--    Indonesia dan Inggris, penuh maupun singkat: Agustus, Aug, Des, Dec, Sept, September,
--    Oktober, Oct, dan seterusnya - 29 varian. Peta bulan di bawah disusun dari daftar yang
--    benar-benar ada di data, bukan dari dugaan. Hasil uraiannya disimpan sebagai tanggal
--    sungguhan supaya Timetable dapat menentukan campaign aktif.
--
-- 3. GROSS CLAIMED
--    Bukan input manual seperti pada sistem lama, melainkan dihitung. Halaman RC sudah punya
--    formulanya di calcGrossUp, tetapi padanan servernya, rc_gross_up_legacy, MENGABAIKAN
--    aturan status pajak campaign - sehingga untuk campaign yang pajaknya ditanggung
--    perusahaan, server dan layar memberi angka berbeda. Fungsi baru di bawah memuat aturan
--    lengkapnya, dan sejak ini seluruh laporan memakai satu sumber perhitungan.
--
-- 4. PENANDA NOT ACHIEVED DAN EXCLUDE CAMPAIGN
--    Keduanya pengendali penyebut Timetable, jadi harus persisten dan dapat dibatalkan.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Region pada master depot
-- ------------------------------------------------------------------------------------------
alter table public.depots add column if not exists region text;
comment on column public.depots.region is
  'Region pelaporan, diisi manusia lewat Key Master. Sengaja tidak diturunkan dari kode depot '
  'karena pembagian region sebenarnya tidak selalu mengikuti awalan kode.';

-- ------------------------------------------------------------------------------------------
-- 2. Periode campaign menjadi tanggal sungguhan
-- ------------------------------------------------------------------------------------------
alter table public.campaigns add column if not exists period_start date;
alter table public.campaigns add column if not exists period_end date;

create or replace function rc_private.bulan_ke_angka(p text)
returns integer language sql immutable set search_path='' as $fn$
  select case lower(btrim(coalesce(p,'')))
    when 'jan' then 1 when 'januari' then 1 when 'january' then 1
    when 'feb' then 2 when 'februari' then 2 when 'february' then 2
    when 'mar' then 3 when 'maret' then 3 when 'march' then 3
    when 'apr' then 4 when 'april' then 4
    when 'may' then 5 when 'mei' then 5
    when 'jun' then 6 when 'juni' then 6 when 'june' then 6
    when 'jul' then 7 when 'juli' then 7 when 'july' then 7
    when 'aug' then 8 when 'agu' then 8 when 'agt' then 8
    when 'agustus' then 8 when 'august' then 8
    when 'sep' then 9 when 'sept' then 9 when 'september' then 9
    when 'oct' then 10 when 'okt' then 10 when 'oktober' then 10 when 'october' then 10
    when 'nov' then 11 when 'november' then 11
    when 'dec' then 12 when 'des' then 12 when 'desember' then 12 when 'december' then 12
    else null end;
$fn$;
revoke all on function rc_private.bulan_ke_angka(text) from public,anon;

-- Mengurai "01-May-24", "9-Desember-24", "30-Sept-24". Tanggal yang tidak dikenali menjadi
-- NULL, bukan ditebak: sebuah tanggal yang salah tebak akan diam-diam memindahkan campaign ke
-- periode yang keliru dan merusak seluruh angka Timetable.
create or replace function rc_private.urai_tanggal(p text)
returns date language plpgsql immutable set search_path='' as $fn$
declare m text[]; bln integer; thn integer;
begin
  if coalesce(btrim(p),'')='' then return null; end if;
  m := regexp_match(btrim(p), '^([0-9]{1,2})[-/ ]+([A-Za-z]+)[-/ ]+([0-9]{2,4})$');
  if m is null then return null; end if;
  bln := rc_private.bulan_ke_angka(m[2]);
  if bln is null then return null; end if;
  thn := m[3]::integer;
  if thn < 100 then thn := 2000 + thn; end if;
  begin
    return make_date(thn, bln, m[1]::integer);
  exception when others then
    return null;
  end;
end $fn$;
revoke all on function rc_private.urai_tanggal(text) from public,anon;

update public.campaigns
   set period_start = rc_private.urai_tanggal(period_start_text),
       period_end   = rc_private.urai_tanggal(period_end_text)
 where period_start is null or period_end is null;

create index if not exists campaigns_period_idx on public.campaigns(period_start, period_end);

-- ------------------------------------------------------------------------------------------
-- 3. Gross Claimed, satu perhitungan untuk semua
-- ------------------------------------------------------------------------------------------
-- Aturan lengkapnya, sama persis dengan calcGrossUp di halaman:
--   pajak ditanggung perusahaan  -> 0, karena toko sudah menerima net penuh
--   Badan                        -> net / 0.85
--   Perorangan                   -> progresif lima lapis
create or replace function rc_private.gross_claimed(
  p_net numeric, p_subyek text, p_status_campaign text)
returns numeric language sql immutable set search_path='' as $fn$
  select case
    when coalesce(p_net,0) <= 0 then 0
    -- Data nyata menulis status ini sebagai "PT Nipsea Paint and Chemicals" dengan berbagai
    -- kapitalisasi, dan "Rebate Non Tax". Keduanya berarti tidak ada pajak yang ditagihkan.
    when lower(btrim(coalesce(p_status_campaign,''))) like '%nipsea%'
      or lower(btrim(coalesce(p_status_campaign,''))) like '%ditanggung perusahaan%'
      or lower(btrim(coalesce(p_status_campaign,''))) like '%ditanggung pt%'
      or lower(btrim(coalesce(p_status_campaign,''))) like '%non tax%' then 0
    when lower(btrim(coalesce(p_subyek,''))) = 'badan' then p_net / 0.85
    when p_net <= 57000000    then p_net / 0.95
    when p_net <= 218500000   then 60000000  + (p_net - 57000000)  / 0.85
    when p_net <= 406000000   then 250000000 + (p_net - 218500000) / 0.75
    when p_net <= 3556000000  then 500000000 + (p_net - 406000000) / 0.70
    else                           5000000000 + (p_net - 3556000000) / 0.65
  end;
$fn$;
revoke all on function rc_private.gross_claimed(numeric,text,text) from public,anon;
grant execute on function rc_private.gross_claimed(numeric,text,text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Penanda Not Achieved dan Exclude Campaign
-- ------------------------------------------------------------------------------------------
create table if not exists public.timetable_not_achieved(
  depot_id uuid not null references public.depots(id) on delete cascade,
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  marked_by uuid references public.profiles(id),
  marked_at timestamptz not null default now(),
  note text not null default '',
  primary key(depot_id, campaign_id)
);
alter table public.timetable_not_achieved enable row level security;
revoke all on public.timetable_not_achieved from public,anon,authenticated;

create table if not exists public.excluded_campaigns(
  campaign_id uuid primary key references public.campaigns(id) on delete cascade,
  excluded_by uuid references public.profiles(id),
  excluded_at timestamptz not null default now(),
  reason text not null default ''
);
alter table public.excluded_campaigns enable row level security;
revoke all on public.excluded_campaigns from public,anon,authenticated;

-- Dua hak modul baru, supaya Report dan Timetable ikut dapat diatur di Kelola Akses.
insert into public.permissions(code,description) values
  ('view_report','Lihat modul Report: Dashboard, Cost Center 1 dan Cost Center 2'),
  ('manage_timetable','Menandai Not Achieved dan mengecualikan campaign')
on conflict(code) do nothing;

create or replace function rc_private.marker_20261010() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261010() from public,anon;
grant execute on function rc_private.marker_20261010() to authenticated;

-- Ringkasan. Kolom periode_gagal_urai penting dibaca: campaign yang periodenya tidak terurai
-- tidak akan pernah dihitung sebagai campaign aktif.
select 'Fondasi Report dan Timetable terpasang' as hasil,
 (select count(*) from public.campaigns) as campaign_total,
 (select count(*) from public.campaigns where period_start is not null) as periode_terurai,
 (select count(*) from public.campaigns
   where coalesce(btrim(period_start_text),'')<>'' and period_start is null) as periode_gagal_urai,
 (select count(*) from public.campaigns where coalesce(btrim(period_start_text),'')='') as tanpa_teks_periode,
 (select count(*) from public.depots where coalesce(btrim(region),'')<>'') as depot_ber_region,
 (select count(*) from public.permissions) as jumlah_permission;
