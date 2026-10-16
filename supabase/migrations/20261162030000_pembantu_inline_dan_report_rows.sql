-- ==========================================================================================
-- Fungsi pembantu per baris dapat di-inline, view laporan tanpa gabung-diri, Depot Master
-- ==========================================================================================
-- Diukur di dev pada 100 ribu klaim, sebagai pemilik database (tanpa RLS sama sekali):
--
--   sum(rc_private.gross_claimed(...))           2.000 - 8.500 ms
--   ekspresi yang PERSIS SAMA ditulis langsung      225 -   250 ms
--   rc_private.legacy_ts(...) x3                  1.570 - 1.610 ms
--   ekspresi yang PERSIS SAMA ditulis langsung      150 -   290 ms
--
-- Isi rumusnya murah; yang mahal adalah PEMANGGILANNYA. PostgreSQL biasanya menanam fungsi
-- SQL sederhana langsung ke dalam kueri pemanggil (inline), tetapi tidak pernah melakukannya
-- untuk fungsi yang membawa klausa SET - di sini "SET search_path TO ''". Akibatnya setiap
-- baris membayar satu panggilan fungsi penuh, untuk setiap kolom tanggal, status dan jenis
-- CB. Itulah yang membuat Report, Cost Center, Analytics dan antrean lambat bersamaan.
--
-- 1. FUNGSI PEMBANTU. Klausa SET dilepas dari tujuh fungsi murni yang dipanggil per baris.
--    ISINYA TIDAK DIUBAH SATU KARAKTER PUN. Aman karena:
--      * ketujuhnya bukan SECURITY DEFINER - berjalan dengan hak pemanggil, sehingga
--        search_path pemanggil tidak dapat dipakai untuk memperoleh hak yang tidak dimilikinya;
--      * isinya hanya fungsi bawaan (pg_catalog, yang selalu dicari lebih dulu) dan fungsi
--        rc_private yang ditulis lengkap dengan skemanya;
--      * setelah di-inline, isinya diurai dengan search_path pemanggil - dan seluruh pemanggil
--        membawa "SET search_path TO ''" sendiri, jadi penguraiannya sama persis seperti sekarang.
--    Supabase Advisor akan menandai ketujuhnya "Function Search Path Mutable" (peringatan,
--    bukan galat). Itu harga yang disengaja untuk kecepatan di atas.
--
--    legacy_date dinyatakan STABLE, bukan IMMUTABLE: isinya memanggil to_char, yang oleh
--    PostgreSQL sendiri digolongkan STABLE, dan fungsi IMMUTABLE yang isinya tidak immutable
--    tidak akan pernah di-inline. Fungsi ini tidak dipakai indeks maupun kolom tergenerasi.
--
-- 2. VIEW rc_report_rows. Definisinya membungkus view lama lalu menggabungkannya kembali ke
--    claims dan campaigns lewat id yang sama (c2.id = v.id, ca2.id = c2.campaign_id) hanya
--    untuk mengambil kolom billing, SO dan tahun. Gabung-diri itu melipatgandakan kerja setiap
--    laporan: menghitung view 100 ribu baris 1.200 - 3.300 ms, tanpa gabung-diri 121 ms. Karena
--    id adalah kunci primer, c2 adalah c dan ca2 adalah ca - kolomnya diambil langsung.
--    Nama, urutan dan tipe kolom dipertahankan persis; pemilik dan hak akses tidak berubah.
--
-- 3. DEPOT MASTER. rc_depot_list berjalan dengan hak pemanggil tetapi menghitung pengajuan
--    tertunda langsung dari depot_profile_requests, yang sejak 20261021 tidak boleh dibaca
--    authenticated. Tab Depot Master karenanya gagal "permission denied" bagi SEMUA pengguna,
--    termasuk System Manager. Hitungannya dipindah ke fungsi SECURITY DEFINER yang HANYA
--    mengembalikan jumlah - isi pengajuan tetap tertutup, dan rc_depot_list tetap memeriksa
--    hak Key Master lebih dulu seperti sebelumnya.
--
-- Setiap bagian dibuktikan: hasil sebelum dan sesudah dibandingkan pada seluruh data, dan
-- migrasi berhenti bila ada satu nilai saja yang berbeda.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Fungsi pembantu
-- ------------------------------------------------------------------------------------------
-- Sidik jari SEBELUM: seluruh klaim, ditambah kasus tepi yang tidak ada di data.
create temp table _sidik_pembantu(tahap text primary key, sidik text, baris bigint) on commit drop;

create temp view _uji_pembantu as
  with tepi(status, jenis, subyek, pajak, net, tgl, ts, top_a, top_b) as (values
    (null::text, null::text, null::text, null::text, null::numeric, null::date, null::timestamptz, null::text, null::text),
    ('', '', '', '', 0, date '2026-01-31', timestamptz '2026-12-31 23:59:59+07', '', ''),
    ('  submitted ', ' VOUCHER ', 'Badan', 'PT Nipsea Paint and Chemicals', 57000000, date '2024-02-29', timestamptz '2026-01-01 00:00:00+00', '30', '45'),
    ('xyz', 'RA07', 'badan ', 'Rebate Non Tax', 57000001, date '2026-09-29', timestamptz '2026-06-15 17:00:00+00', '60', '30'),
    ('on_hold', 'ra7', 'orang pribadi', 'ditanggung PT', 218500000, null, null, '30.5', '30'),
    ('expired', 'Rebate Manual', null, 'Ditanggung Perusahaan', 406000000, null, null, 'COD', '30'),
    ('done', 'CN', 'Pribadi', 'Kena Pajak', 3556000000, null, null, '-', '0'),
    ('claimed', 'transfer', 'x', null, 3556000001, null, null, '00012', '12.0'),
    ('not_yet', 'rebate', '', 'lainnya', -5, null, null, ' 7 ', '7'))
  select md5(string_agg(concat_ws('|',
           rc_private.legacy_status(status), rc_private.jenis_efektif(jenis), rc_private.cb_label(jenis),
           rc_private.gross_claimed(net, subyek, pajak)::text, rc_private.legacy_date(tgl),
           rc_private.legacy_ts(ts), rc_private.approval_overdue(top_a, top_b)::text), '#')) as sidik,
         count(*) as baris
    from (
      select status, jenis, subyek, pajak, net, tgl, ts, top_a, top_b from tepi
      union all
      select c.status, coalesce(nullif(c.cashback_type_override,''), ca.cashback_type), c.tax_subject,
             ca.tax_status, c.cb_net, c.period_start, c.uploaded_at, s.top_text, '30'
        from public.claims c
        join public.campaigns ca on ca.id = c.campaign_id
        left join rc_private.claim_sensitive s on s.claim_id = c.id
    ) u;

insert into _sidik_pembantu select 'sebelum', sidik, baris from _uji_pembantu;

alter function rc_private.legacy_status(text)                   reset search_path;
alter function rc_private.legacy_ts(timestamptz)                reset search_path;
alter function rc_private.legacy_date(date)                     reset search_path;
alter function rc_private.legacy_date(date)                     stable;
alter function rc_private.jenis_efektif(text)                   reset search_path;
alter function rc_private.cb_label(text)                        reset search_path;
alter function rc_private.gross_claimed(numeric, text, text)    reset search_path;
alter function rc_private.approval_overdue(text, text)          reset search_path;

insert into _sidik_pembantu select 'sesudah', sidik, baris from _uji_pembantu;

do $pembantu$
declare a record; b record; baris text; rencana text := '';
begin
  select * into a from _sidik_pembantu where tahap = 'sebelum';
  select * into b from _sidik_pembantu where tahap = 'sesudah';
  if a.sidik is distinct from b.sidik or a.baris <> b.baris then
    raise exception 'GAGAL: hasil fungsi pembantu berubah (% baris, sidik % -> %).',
      a.baris, a.sidik, b.sidik;
  end if;

  -- Bukti bahwa tujuannya tercapai: di rencana kueri, tidak ada lagi panggilan ke fungsi
  -- pembantu - yang tersisa hanya ekspresi yang sudah ditanam. Diperiksa dengan search_path
  -- kosong, persis seperti di dalam fungsi pemanggil.
  perform set_config('search_path', '', true);
  for baris in execute $q$
    explain (verbose, costs off)
    select rc_private.legacy_status(c.status), rc_private.legacy_ts(c.uploaded_at),
           rc_private.legacy_date(c.period_start),
           rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''), ca.cashback_type)),
           rc_private.gross_claimed(c.cb_net, c.tax_subject, ca.tax_status),
           rc_private.approval_overdue(c.tax_subject, '30')
      from public.claims c join public.campaigns ca on ca.id = c.campaign_id$q$
  loop rencana := rencana || baris || E'\n'; end loop;
  perform set_config('search_path', 'public', true);

  if rencana ~ '(legacy_status|legacy_ts|legacy_date|jenis_efektif|cb_label|gross_claimed|approval_overdue)\(' then
    raise exception E'GAGAL: masih ada fungsi pembantu yang tidak di-inline:\n%', rencana;
  end if;
  raise notice 'Fungsi pembantu: % baris identik, seluruhnya di-inline.', a.baris;
end
$pembantu$;

-- ------------------------------------------------------------------------------------------
-- 2. View rc_report_rows tanpa gabung-diri
-- ------------------------------------------------------------------------------------------
create temp table _sidik_report(tahap text primary key, sidik text, baris bigint) on commit drop;
insert into _sidik_report
  select 'sebelum', md5(string_agg(md5(r::text), '' order by r.id)), count(*) from public.rc_report_rows r;

create or replace view public.rc_report_rows as
  select c.id,
         c.no_doc,
         c.status,
         c.cb_net,
         c.cleared_at,
         c.uploaded_at,
         c.tax_subject,
         d.id as depot_id,
         d.depot_code,
         d.depot_name,
         coalesce(d.region, ''::text) as region,
         ca.id as campaign_id,
         ca.campaign_code,
         ca.campaign_name,
         ca.tax_status,
         ca.period_start,
         ca.period_end,
         rc_private.gross_claimed(c.cb_net, c.tax_subject, ca.tax_status) as gross_claimed,
         c.status = any (array['not_yet'::text, 'submitted'::text, 'approved'::text,
                               'released'::text, 'claimed'::text]) as outstanding,
         coalesce(ca.period_end, ca.period_start, c.uploaded_at::date) as acuan_aging,
         coalesce(c.extend_billing_start, ca.billing_start) as billing_start,
         coalesce(c.extend_billing_end, ca.billing_end) as billing_end,
         coalesce(c.extend_so_start, ca.so_start) as so_start,
         coalesce(c.extend_so_end, ca.so_end) as so_end,
         extract(year from coalesce(ca.period_start, ca.period_end))::integer as campaign_year
    from public.claims c
    join public.depots d on d.id = c.depot_id
    join public.campaigns ca on ca.id = c.campaign_id
   where c.archived_at is null
     and not exists (select 1 from public.excluded_campaigns x where x.campaign_id = ca.id);

insert into _sidik_report
  select 'sesudah', md5(string_agg(md5(r::text), '' order by r.id)), count(*) from public.rc_report_rows r;

do $report$
declare a record; b record;
begin
  select * into a from _sidik_report where tahap = 'sebelum';
  select * into b from _sidik_report where tahap = 'sesudah';
  if a.sidik is distinct from b.sidik or a.baris <> b.baris then
    raise exception 'GAGAL: isi rc_report_rows berubah (% -> % baris).', a.baris, b.baris;
  end if;
  raise notice 'rc_report_rows: % baris identik tanpa gabung-diri.', a.baris;
end
$report$;

-- ------------------------------------------------------------------------------------------
-- 3. Depot Master: jumlah pengajuan tertunda
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.jumlah_pengajuan_depot_tertunda(p_depot uuid)
returns bigint language sql stable security definer set search_path to '' as $fn$
  select count(*) from public.depot_profile_requests r
   where r.depot_id = p_depot and r.status = 'pending';
$fn$;
revoke all on function rc_private.jumlah_pengajuan_depot_tertunda(uuid) from public, anon;
grant execute on function rc_private.jumlah_pengajuan_depot_tertunda(uuid) to authenticated;

do $depot$
declare src text; baru text; pola text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rc_depot_list';
  if src is null then raise exception 'public.rc_depot_list tidak ditemukan.'; end if;

  pola := '\(select count\(\*\) from public\.depot_profile_requests r\s+where r\.depot_id=t\.id and r\.status=''pending''\)';
  if src ~ pola then
    baru := regexp_replace(src, pola, 'rc_private.jumlah_pengajuan_depot_tertunda(t.id)');
    execute baru;
    raise notice 'rc_depot_list: jumlah pengajuan dibaca lewat rc_private.jumlah_pengajuan_depot_tertunda.';
  elsif src ~ 'public\.depot_profile_requests' then
    raise exception 'rc_depot_list membaca depot_profile_requests dalam bentuk yang tidak dikenali.';
  else
    raise notice 'rc_depot_list sudah tidak membaca depot_profile_requests langsung.';
  end if;
end
$depot$;

-- Bukti lewat jalur pengguna sungguhan: setiap pengguna aktif yang boleh membuka Depot Master
-- kini mendapat daftarnya, bukan "permission denied".
do $depot_uji$
declare u record; hasil jsonb; n int := 0;
begin
  for u in select id, user_code from public.profiles where status = 'active' order by user_code loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    if not rc_private.can_tab('keyMaster.depot') then continue; end if;
    set local role authenticated;
    hasil := public.rc_depot_list(null, 0, 5);
    reset role;
    if hasil->>'status' <> 'success' then
      raise exception 'GAGAL: rc_depot_list untuk % tidak berhasil: %', u.user_code, hasil; end if;
    n := n + 1;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'rc_depot_list berhasil untuk % pengguna yang berhak.', n;
exception when others then
  reset role; raise;
end
$depot_uji$;
