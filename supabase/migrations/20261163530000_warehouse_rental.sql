-- ==========================================================================================
-- Warehouse Rental: form F01.AW.2025 (Rental New / Re-newal Submission) + Upload Omset
-- ==========================================================================================
-- PRD "Modul Warehouse Rental (RC Next Gen)" (pemilik, 27 Oktober 2026), fase 1 dan 2. Approval
-- digital, Legal Review, Top Management, dan Analytics (fase 3-4) di luar cakupan: kotaknya
-- tercetak kosong di PDF untuk tanda tangan basah.
--
-- Jawaban pemilik atas pertanyaan terbuka PRD:
--   * Revenue = Omset - Pajak (net).
--   * PY YTD / Act YTD sampai bulan Date Propose (seperti Excel).
--   * Size Building bawaan = ukuran gudang yang diajukan (Warehouse + Office), dapat diubah.
--   * Offering Price per tahun; Total Price = N tahun x Offering Price. N bawaannya Rental Plane dan
--     dapat diisi sendiri di kolom Total Price for ... Year (pemilik, 27 Oktober 2026), boleh desimal.
--   * Price per m2/month tanpa IPL: Offering Price / (Warehouse + Office) / 12.
--   * Nomor dokumen F01.AW.<tahun>-<Abbr depot>; tahun = tahun Date Propose.
--   * Logo PNG warna (logo merek utuh yang sudah ada di aplikasi).
--   * Satu depot satu submission aktif. Diterapkan per tahun Date Propose: satu form yang tidak
--     Cancelled per depot per tahun, sesuai nomor dokumen yang hanya memuat tahun dan Abbr.
--     Form pengganti setelah Cancel diberi akhiran -2, -3, ... supaya nomor tidak pernah kembar.
--
-- Akses (aturan RC: akses mengikuti tab, dibatasi yurisdiksi depot). Satu izin modul view_rental:
--   rental.form       Fill Form      bawaan tercentang hanya Depot Head; peran lain bila dicentang
--   rental.draft      Draft          sama dengan Fill Form
--   rental.submitted  Submitted      bawaan tercentang bagi pemegang izin (Management dst.)
--   rental.omset      Upload Omset   hanya bila dicentang (Admin SASD). Pemegangnya melihat dan
--                                    mengubah form SELURUH depot dan boleh override Revenue
--                                    dengan alasan wajib.
-- Selain pemegang Upload Omset, form hanya terlihat untuk depot dalam yurisdiksi (can_access).
--
-- Seluruh tabel di schema rental tanpa hak langsung (RLS aktif tanpa kebijakan); akses lewat RPC
-- public.rc_rental_*. PDF hasil submit disimpan di bucket privat rental-pdf.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

create schema if not exists rental;
revoke all on schema rental from public, anon, authenticated;

-- ---- 1. Tabel ------------------------------------------------------------------------------
create table if not exists rental.revenue_uploads (
  id uuid primary key default gen_random_uuid(),
  file_name text,
  uploaded_by uuid references public.profiles(id),
  uploaded_at timestamptz not null default now(),
  rows_inserted integer not null default 0,
  rows_updated integer not null default 0,
  rows_error integer not null default 0,
  error_log jsonb not null default '[]'
);

-- Satu baris per depot per bulan (period = tanggal 1). Omset boleh negatif (retur / koreksi).
create table if not exists rental.depot_revenue (
  depot_id uuid not null references public.depots(id),
  period date not null check (extract(day from period) = 1),
  omset numeric(20, 2) not null,
  pajak numeric(20, 2) not null check (pajak >= 0),
  net numeric(20, 2) generated always as (omset - pajak) stored,
  upload_id uuid references rental.revenue_uploads(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id),
  primary key (depot_id, period)
);

create table if not exists rental.submissions (
  id uuid primary key default gen_random_uuid(),
  doc_no text unique,
  urut integer,
  depot_id uuid not null references public.depots(id),
  date_propose date not null,
  tahun integer generated always as (extract(year from date_propose)::integer) stored,
  lease_type text check (lease_type in ('new', 'renewal')),
  rental_years integer check (rental_years between 1 and 5),
  status text not null default 'draft' check (status in ('draft', 'submitted', 'cancelled')),
  form_data jsonb not null default '{}',
  calc jsonb not null default '{}',
  revenue_snapshot jsonb,
  pdf_path text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now(),
  submitted_by uuid references public.profiles(id),
  submitted_at timestamptz,
  cancelled_by uuid references public.profiles(id),
  cancelled_at timestamptz,
  cancel_reason text,
  cancelled_from text check (cancelled_from in ('draft', 'submitted'))
);
-- Satu submission aktif (Draft / Submitted) per depot per tahun Date Propose.
create unique index if not exists submissions_satu_aktif on rental.submissions(depot_id, tahun) where status <> 'cancelled';
create index if not exists submissions_status on rental.submissions(status, depot_id);

alter table rental.revenue_uploads enable row level security;
alter table rental.depot_revenue enable row level security;
alter table rental.submissions enable row level security;
revoke all on all tables in schema rental from public, anon, authenticated;

-- ---- 2. Bantuan ----------------------------------------------------------------------------
-- Depot dapat dilihat / diubah: pemegang Upload Omset seluruh depot, selainnya yurisdiksi.
create or replace function rental.boleh(p_depot uuid) returns boolean
language sql stable security definer set search_path = '' as $f$
  select rc_private.can_tab('rental.omset') or rc_private.can_access(p_depot)
$f$;

create or replace function rental.nama_bulan(p_bulan integer) returns text
language sql immutable set search_path = '' as $f$
  select (array['Januari','Februari','Maret','April','Mei','Juni','Juli','Agustus','September','Oktober','November','Desember'])[p_bulan]
$f$;

create or replace function rental.bagi(a numeric, b numeric) returns numeric
language sql immutable set search_path = '' as $f$
  select case when a is null or b is null or b = 0 then null else a / b end
$f$;

-- Angka dari JSON (angka, atau teks angka). Kosong = null; selain itu ditolak, tidak ditebak.
create or replace function rental.angka(p jsonb, p_kunci text, p_label text, p_boleh_negatif boolean default false) returns numeric
language plpgsql immutable set search_path = '' as $f$
declare v jsonb := p->p_kunci; t text; n numeric;
begin
  if v is null or jsonb_typeof(v) = 'null' then return null; end if;
  if jsonb_typeof(v) = 'number' then n := (v #>> '{}')::numeric;
  elsif jsonb_typeof(v) = 'string' then
    t := btrim(v #>> '{}');
    if t = '' then return null; end if;
    if t !~ '^-?[0-9]+(\.[0-9]+)?$' then raise exception '% harus angka', p_label; end if;
    n := t::numeric;
  else raise exception '% harus angka', p_label;
  end if;
  if n < 0 and not p_boleh_negatif then raise exception '% tidak boleh negatif', p_label; end if;
  if abs(n) >= 1e17 then raise exception '% terlalu besar', p_label; end if;
  return n;
end $f$;

create or replace function rental.teks(p jsonb, p_kunci text, p_label text, p_maks integer) returns text
language plpgsql immutable set search_path = '' as $f$
declare v jsonb := p->p_kunci; t text;
begin
  if v is null or jsonb_typeof(v) = 'null' then return null; end if;
  if jsonb_typeof(v) not in ('string', 'number') then raise exception '% harus teks', p_label; end if;
  t := upper(btrim(regexp_replace(v #>> '{}', '\s+', ' ', 'g')));
  if length(t) > p_maks then raise exception '% maksimal % karakter', p_label, p_maks; end if;
  return nullif(t, '');
end $f$;

create or replace function rental.pilihan(p jsonb, p_kunci text, p_label text, p_opsi text[]) returns text
language plpgsql immutable set search_path = '' as $f$
declare t text := nullif(btrim(coalesce(p->>p_kunci, '')), '');
begin
  if t is not null and not (t = any(p_opsi)) then raise exception '% tidak dikenal: %', p_label, t; end if;
  return t;
end $f$;

-- N tahun untuk Total Price; kosong = ikut Rental Plane.
create or replace function rental.tahun_total(p jsonb) returns numeric
language plpgsql immutable set search_path = '' as $f$
declare n numeric := rental.angka(p, 'totalYears', 'Total Price for ... Year');
begin
  if n is not null and (n <= 0 or n > 50) then raise exception 'Total Price for ... Year harus lebih dari 0 dan paling banyak 50 tahun'; end if;
  return round(n, 2);
end $f$;

-- Isi form dibersihkan menjadi daftar kunci yang dikenal saja. Override Revenue hanya dari
-- pemegang Upload Omset; selainnya override lama dipertahankan apa adanya.
create or replace function rental.bersihkan(p jsonb, p_admin boolean, p_lama jsonb) returns jsonb
language plpgsql stable set search_path = '' as $f$
declare
  v_merek text[] := array['AVIAN','PROPAN','DULUX','JOTUN','MOWILEX','DANAPAINT','PACIFIC PAINT','KEMTONE','OTHERS'];
  v_fas text[] := array['mess','musholla','parking','cctv','security'];
  v_comp jsonb := '[]'; v_ca jsonb := '[]'; v_f jsonb := '[]'; v_ov jsonb := '{}'; e jsonb; k text; t text; i integer;
begin
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Isi form tidak valid'; end if;
  if octet_length(p::text) > 65536 then raise exception 'Isi form terlalu besar'; end if;

  if jsonb_typeof(p->'competitors') = 'array' then
    for e in select value from jsonb_array_elements(p->'competitors') loop
      t := upper(btrim(e #>> '{}'));
      if not (t = any(v_merek)) then raise exception 'Competitor tidak dikenal: %', t; end if;
      if not v_comp ? t then v_comp := v_comp || to_jsonb(t); end if;
    end loop;
  end if;
  for i in 0..9 loop
    v_ca := v_ca || to_jsonb(coalesce(rental.teks(jsonb_build_object('x', p->'coveredArea'->i), 'x', 'Covered Area ' || (i + 1), 60), ''));
  end loop;
  if jsonb_typeof(p->'facilities') = 'array' then
    for e in select value from jsonb_array_elements(p->'facilities') loop
      t := lower(btrim(e #>> '{}'));
      if not (t = any(v_fas)) then raise exception 'Facilities tidak dikenal: %', t; end if;
      if not v_f ? t then v_f := v_f || to_jsonb(t); end if;
    end loop;
  end if;

  if p_admin then
    if jsonb_typeof(p->'revOverride') = 'object' then
      for k in select key from jsonb_each(p->'revOverride') loop
        if k not in ('py1', 'py', 'pyytd', 'actytd') then raise exception 'Override Revenue tidak dikenal: %', k; end if;
        e := p->'revOverride'->k;
        if e is null or jsonb_typeof(e) <> 'object' or rental.angka(e, 'nilai', 'Override Revenue', true) is null then continue; end if;
        t := btrim(coalesce(e->>'alasan', ''));
        if t = '' then raise exception 'Alasan override Revenue % wajib diisi', upper(k); end if;
        if length(t) > 200 then raise exception 'Alasan override maksimal 200 karakter'; end if;
        v_ov := v_ov || jsonb_build_object(k, jsonb_build_object('nilai', rental.angka(e, 'nilai', 'Override Revenue', true), 'alasan', t,
          'oleh', coalesce(case when (p_lama->'revOverride'->k->>'nilai')::numeric = rental.angka(e, 'nilai', 'Override Revenue', true)
                                     and p_lama->'revOverride'->k->>'alasan' = t then p_lama->'revOverride'->k->>'oleh' end,
                           (select full_name from public.profiles where id = auth.uid())),
          'pada', coalesce(case when (p_lama->'revOverride'->k->>'nilai')::numeric = rental.angka(e, 'nilai', 'Override Revenue', true)
                                     and p_lama->'revOverride'->k->>'alasan' = t then p_lama->'revOverride'->k->>'pada' end,
                           to_char(now() at time zone 'Asia/Jakarta', 'YYYY-MM-DD HH24:MI'))));
      end loop;
    end if;
  else
    v_ov := coalesce(p_lama->'revOverride', '{}');
  end if;

  return jsonb_build_object(
    'leaseType', rental.pilihan(p, 'leaseType', 'Jenis sewa', array['new', 'renewal']),
    'rentalYears', (rental.pilihan(p, 'rentalYears', 'Rental Plane', array['1', '2', '3', '4', '5']))::integer,
    'competitors', v_comp,
    'competitorOther', case when v_comp ? 'OTHERS' then rental.teks(p, 'competitorOther', 'Competitor lainnya', 100) end,
    'competitorSum', rental.angka(p, 'competitorSum', 'Sum Competitor Depo'),
    'competitorShare', rental.angka(p, 'competitorShare', 'Competitor Share Value'),
    'coveredArea', v_ca,
    'revBudget', rental.angka(p, 'revBudget', 'Revenue Budget', true),
    'revEstimate', rental.angka(p, 'revEstimate', 'Revenue Estimate', true),
    'revOverride', v_ov,
    'sizePy1', rental.angka(p, 'sizePy1', 'Size Building PY-1'),
    'sizePy', rental.angka(p, 'sizePy', 'Size Building PY'),
    'sizeBudget', rental.angka(p, 'sizeBudget', 'Size Building Budget'),
    'sizeEstimate', rental.angka(p, 'sizeEstimate', 'Size Building Estimate'),
    'landSize', rental.angka(p, 'landSize', 'Land Size'),
    'warehouseSize', rental.angka(p, 'warehouseSize', 'Warehouse Size'),
    'officeSize', rental.angka(p, 'officeSize', 'Office Size'),
    'offeringPrice', rental.angka(p, 'offeringPrice', 'Offering Price'),
    'totalYears', rental.tahun_total(p),
    'facilities', v_f,
    'pph', rental.pilihan(p, 'pph', 'Income Tax (PPH)', array['owner', 'nipsea']),
    'pbb', rental.pilihan(p, 'pbb', 'Land Tax (PBB)', array['owner', 'nipsea']),
    'notaris', rental.pilihan(p, 'notaris', 'Notaries Fee', array['owner', 'nipsea', '5050']),
    'ipl', rental.angka(p, 'ipl', 'Mtn/Surcharge (IPL)'),
    'ownerName', rental.teks(p, 'ownerName', 'Owners / Agent', 100),
    'ownerPhone', rental.teks(p, 'ownerPhone', 'Phone Number', 40),
    'ownerAddress', rental.teks(p, 'ownerAddress', 'Properties Address', 300));
end $f$;

-- Agregasi omset (net) untuk Date Propose: PY-1 = Jan-Des Y-2, PY = Jan-Des Y-1, PY YTD = Jan s/d
-- bulan M Y-1, Act YTD = Jan s/d bulan M Y. Periode tanpa satu bulan pun bernilai null ("-").
create or replace function rental.revenue(p_depot uuid, p_tanggal date) returns jsonb
language sql stable security definer set search_path = '' as $f$
  with k as (select extract(year from p_tanggal)::integer y, extract(month from p_tanggal)::integer m),
  b as (select g::date bulan from k, generate_series(make_date(k.y - 2, 1, 1), make_date(k.y, k.m, 1), interval '1 month') g),
  d as (select b.bulan, extract(year from b.bulan)::integer th, extract(month from b.bulan)::integer bl, r.net
          from b left join rental.depot_revenue r on r.depot_id = p_depot and r.period = b.bulan)
  select jsonb_build_object(
    'tahun', k.y, 'bulan', k.m,
    'py1',    sum(d.net) filter (where d.th = k.y - 2),
    'py',     sum(d.net) filter (where d.th = k.y - 1),
    'pyytd',  sum(d.net) filter (where d.th = k.y - 1 and d.bl <= k.m),
    'actytd', sum(d.net) filter (where d.th = k.y),
    'hilang', coalesce(jsonb_agg(to_char(d.bulan, 'YYYY-MM') order by d.bulan) filter (where d.net is null), '[]'))
  from k cross join d group by k.y, k.m
$f$;

-- Nilai Revenue akhir: override (bila ada) menggantikan hasil omset.
create or replace function rental.revenue_akhir(p_rev jsonb, p_override jsonb) returns jsonb
language sql immutable set search_path = '' as $f$
  select jsonb_object_agg(k, case when p_override ? k
      then jsonb_build_object('nilai', (p_override->k->>'nilai')::numeric, 'sumber', 'override', 'omset', p_rev->k,
                              'alasan', p_override->k->>'alasan', 'oleh', p_override->k->>'oleh', 'pada', p_override->k->>'pada')
      else jsonb_build_object('nilai', p_rev->k, 'sumber', 'omset') end)
  from unnest(array['py1', 'py', 'pyytd', 'actytd']) k
$f$;

-- Rumus form (sel Excel di kurung). Pembagi 0 / kosong = null, ditampilkan "-".
create or replace function rental.hitung(p jsonb, p_rev jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $f$
declare
  rv_py1 numeric := (p_rev->'py1'->>'nilai')::numeric; rv_py numeric := (p_rev->'py'->>'nilai')::numeric;
  rv_pyytd numeric := (p_rev->'pyytd'->>'nilai')::numeric; rv_act numeric := (p_rev->'actytd'->>'nilai')::numeric;
  rv_bud numeric := (p->>'revBudget')::numeric; rv_est numeric := (p->>'revEstimate')::numeric;
  wh numeric := (p->>'warehouseSize')::numeric; off numeric := (p->>'officeSize')::numeric;
  luas numeric := case when wh is null and off is null then null else coalesce(wh, 0) + coalesce(off, 0) end;
  sz_py1 numeric := coalesce((p->>'sizePy1')::numeric, luas); sz_py numeric := coalesce((p->>'sizePy')::numeric, luas);
  sz_bud numeric := coalesce((p->>'sizeBudget')::numeric, luas); sz_est numeric := coalesce((p->>'sizeEstimate')::numeric, luas);
  harga numeric := (p->>'offeringPrice')::numeric; n numeric := coalesce((p->>'totalYears')::numeric, (p->>'rentalYears')::numeric);
begin
  return jsonb_build_object(
    'growthPy', rental.bagi(rv_py, rv_py1) - 1,          -- E23
    'growthActYtd', rental.bagi(rv_act, rv_pyytd) - 1,   -- H23
    'growthBudget', rental.bagi(rv_bud, rv_py) - 1,      -- K23
    'growthEstimate', rental.bagi(rv_est, rv_bud) - 1,   -- L23
    'sizePy1', sz_py1, 'sizePy', sz_py, 'sizeBudget', sz_bud, 'sizeEstimate', sz_est,
    'revSqmPy1', rental.bagi(rv_py1, sz_py1), 'revSqmPy', rental.bagi(rv_py, sz_py),   -- D25:L25
    'revSqmBudget', rental.bagi(rv_bud, sz_bud), 'revSqmEstimate', rental.bagi(rv_est, sz_est),
    'totalYears', n, 'totalPrice', n * harga,                      -- E38 (N dapat diisi sendiri)
    'pricePerM2Month', rental.bagi(rental.bagi(harga, luas), 12),  -- E39, tanpa IPL
    'labelSewa', case p->>'leaseType' when 'new' then 'NEW LEASE / SEWA BARU' when 'renewal' then 'RE-NEWAL / PERPANJANG SEWA' else '-' end); -- K29
end $f$;

-- Field wajib saat submit (PRD "Spesifikasi form").
create or replace function rental.kurang(p jsonb) returns text[]
language sql immutable set search_path = '' as $f$
  select array_remove(array[
    case when p->>'leaseType' is null then 'Jenis sewa (New Lease / Re-newal)' end,
    case when p->>'rentalYears' is null then 'Rental Plane' end,
    case when not exists(select 1 from jsonb_array_elements_text(p->'coveredArea') x where x <> '') then 'Covered Area (minimal 1)' end,
    case when p->'competitors' ? 'OTHERS' and p->>'competitorOther' is null then 'Nama competitor OTHERS' end,
    case when coalesce((p->>'warehouseSize')::numeric, 0) <= 0 then 'Warehouse Size' end,
    case when coalesce((p->>'offeringPrice')::numeric, 0) <= 0 then 'Offering Price' end,
    case when p->>'pph' is null then 'Income Tax (PPH)' end,
    case when p->>'pbb' is null then 'Land Tax (PBB)' end,
    case when p->>'notaris' is null then 'Notaries Fee' end,
    case when p->>'ownerName' is null then 'Owners / Agent' end,
    case when p->>'ownerAddress' is null then 'Properties Address' end], null)
$f$;

-- Satu baris lengkap untuk layar / PDF. Draft selalu memakai omset terbaru; Submitted memakai
-- angka yang dikunci saat submit.
create or replace function rental.baris(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare s rental.submissions%rowtype; d public.depots%rowtype; v_rev jsonb; v_akhir jsonb; v_calc jsonb;
begin
  select * into s from rental.submissions where id = p_id;
  if not found then return null; end if;
  select * into d from public.depots where id = s.depot_id;
  if s.status = 'draft' then
    v_rev := rental.revenue(s.depot_id, s.date_propose);
    v_akhir := rental.revenue_akhir(v_rev, coalesce(s.form_data->'revOverride', '{}'));
    v_calc := rental.hitung(s.form_data, v_akhir);
  else
    v_rev := s.revenue_snapshot->'omset'; v_akhir := s.revenue_snapshot->'akhir'; v_calc := s.calc;
  end if;
  return jsonb_build_object('id', s.id, 'docNo', s.doc_no, 'status', s.status, 'tanggal', s.date_propose, 'tahun', s.tahun,
    'depot', jsonb_build_object('id', d.id, 'kode', d.depot_code, 'nama', d.depot_name, 'abbr', upper(coalesce(nullif(btrim(d.abbr), ''), d.depot_code))),
    'data', s.form_data, 'calc', v_calc, 'revenue', v_akhir, 'omset', v_rev, 'pdfPath', s.pdf_path,
    'namaBerkas', 'F01AW_' || d.depot_code || '_' || to_char(s.date_propose, 'YYYYMMDD') || '_' || coalesce(lpad(s.urut::text, 3, '0'), 'DRAFT') || '.pdf',
    'dibuat', jsonb_build_object('oleh', (select full_name from public.profiles where id = s.created_by), 'pada', s.created_at),
    'diubah', jsonb_build_object('oleh', (select full_name from public.profiles where id = s.updated_by), 'pada', s.updated_at),
    'disubmit', case when s.submitted_at is null then null else jsonb_build_object('oleh', (select full_name from public.profiles where id = s.submitted_by), 'pada', s.submitted_at) end,
    'dibatalkan', case when s.cancelled_at is null then null else jsonb_build_object('oleh', (select full_name from public.profiles where id = s.cancelled_by), 'pada', s.cancelled_at, 'alasan', s.cancel_reason) end);
end $f$;

create or replace function rental.log(p_event text, p_depot uuid, p_id uuid, p_tab text, p_detail jsonb) returns void
language sql security definer set search_path = '' as $f$
  insert into public.activity_logs(actor_id, depot_id, event_type, entity_id, details, module, tab, process_stage)
  values (auth.uid(), p_depot, p_event, p_id, p_detail, 'rental', p_tab, p_tab)
$f$;

-- ---- 3. RPC --------------------------------------------------------------------------------
create or replace function public.rc_rental_init() returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_admin boolean := rc_private.can_tab('rental.omset');
begin
  if not (rc_private.can_tab('rental.form') or rc_private.can_tab('rental.draft') or rc_private.can_tab('rental.submitted') or v_admin) then
    raise exception 'Akses Warehouse Rental tidak diizinkan' using errcode = '42501'; end if;
  return jsonb_build_object('status', 'success', 'admin', v_admin,
    'depots', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kode', d.depot_code, 'nama', d.depot_name,
                         'abbr', upper(coalesce(nullif(btrim(d.abbr), ''), d.depot_code))) order by d.depot_code)
                from public.depots d where d.archived_at is null and not d.bukan_depot and (v_admin or rc_private.can_access(d.id))), '[]'));
end $f$;

create or replace function public.rc_rental_revenue(p_depot uuid, p_tanggal date) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
begin
  if not (rc_private.can_tab('rental.form') or rc_private.can_tab('rental.omset')) then
    raise exception 'Akses tab rental.form tidak diizinkan' using errcode = '42501'; end if;
  if p_depot is null or p_tanggal is null then raise exception 'Pilih Depot Name dan Date Propose lebih dulu'; end if;
  if not rental.boleh(p_depot) then raise exception 'Depot di luar jangkauan Anda' using errcode = '42501'; end if;
  return jsonb_build_object('status', 'success', 'omset', rental.revenue(p_depot, p_tanggal),
    'aktif', (select jsonb_build_object('id', s.id, 'docNo', s.doc_no, 'status', s.status) from rental.submissions s
               where s.depot_id = p_depot and s.tahun = extract(year from p_tanggal)::integer and s.status <> 'cancelled' limit 1));
end $f$;

create or replace function public.rc_rental_simpan(p_id uuid, p_depot uuid, p_tanggal date, p_data jsonb, p_submit boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  s rental.submissions%rowtype; d public.depots%rowtype; v_admin boolean := rc_private.can_tab('rental.omset');
  v_data jsonb; v_rev jsonb; v_akhir jsonb; v_calc jsonb; v_kurang text[]; v_lain rental.submissions%rowtype;
  v_urut integer; v_no text; v_abbr text; v_id uuid;
begin
  if not (rc_private.can_tab('rental.form') or v_admin) then raise exception 'Akses tab rental.form tidak diizinkan' using errcode = '42501'; end if;
  if p_depot is null then raise exception 'Depot Name wajib diisi'; end if;
  if p_tanggal is null then raise exception 'Date Propose wajib diisi'; end if;
  if p_tanggal < date '2000-01-01' or p_tanggal > date '2100-12-31' then raise exception 'Date Propose tidak wajar'; end if;
  select * into d from public.depots where id = p_depot and archived_at is null and not bukan_depot;
  if not found then raise exception 'Depot tidak ada di Depot Master'; end if;
  if not rental.boleh(p_depot) then raise exception 'Depot di luar jangkauan Anda' using errcode = '42501'; end if;

  if p_id is not null then
    select * into s from rental.submissions where id = p_id for update;
    if not found then raise exception 'Form tidak ditemukan'; end if;
    if not rental.boleh(s.depot_id) then raise exception 'Depot di luar jangkauan Anda' using errcode = '42501'; end if;
    if s.status <> 'draft' then raise exception 'Form % sudah %; tidak dapat diubah', coalesce(s.doc_no, ''), case s.status when 'submitted' then 'di-submit' else 'dibatalkan' end; end if;
  end if;

  -- Satu submission aktif per depot per tahun.
  perform pg_advisory_xact_lock(hashtextextended('rental:' || p_depot::text || ':' || extract(year from p_tanggal)::text, 0));
  select * into v_lain from rental.submissions x
   where x.depot_id = p_depot and x.tahun = extract(year from p_tanggal)::integer and x.status <> 'cancelled' and x.id is distinct from p_id limit 1;
  if found then
    raise exception 'Depot % sudah punya form % tahun % (%). Satu depot hanya satu submission aktif; batalkan form itu lebih dulu bila ingin membuat yang baru.',
      d.depot_code, case v_lain.status when 'draft' then 'Draft' else 'Submitted ' || v_lain.doc_no end, v_lain.tahun,
      'dibuat ' || coalesce((select full_name from public.profiles where id = v_lain.created_by), '-');
  end if;

  v_data := rental.bersihkan(p_data, v_admin, coalesce(s.form_data, '{}'));
  v_rev := rental.revenue(p_depot, p_tanggal);
  v_akhir := rental.revenue_akhir(v_rev, v_data->'revOverride');
  v_calc := rental.hitung(v_data, v_akhir);

  if p_submit then
    v_kurang := rental.kurang(v_data);
    if cardinality(v_kurang) > 0 then raise exception 'Form belum lengkap: %', array_to_string(v_kurang, ', '); end if;
    v_abbr := upper(coalesce(nullif(btrim(d.abbr), ''), d.depot_code));
    select coalesce(max(x.urut), 0) + 1 into v_urut from rental.submissions x
     where x.depot_id = p_depot and x.tahun = extract(year from p_tanggal)::integer and x.urut is not null;
    v_no := 'F01.AW.' || extract(year from p_tanggal)::integer || '-' || v_abbr || case when v_urut > 1 then '-' || v_urut else '' end;
  end if;

  if p_id is null then
    insert into rental.submissions(depot_id, date_propose, lease_type, rental_years, form_data, calc, created_by, updated_by)
    values (p_depot, p_tanggal, v_data->>'leaseType', (v_data->>'rentalYears')::integer, v_data, v_calc, auth.uid(), auth.uid())
    returning id into v_id;
  else
    v_id := p_id;
    update rental.submissions set depot_id = p_depot, date_propose = p_tanggal, lease_type = v_data->>'leaseType',
      rental_years = (v_data->>'rentalYears')::integer, form_data = v_data, calc = v_calc, updated_by = auth.uid(), updated_at = now()
     where id = p_id;
  end if;
  if p_submit then
    update rental.submissions set status = 'submitted', doc_no = v_no, urut = v_urut,
      revenue_snapshot = jsonb_build_object('omset', v_rev, 'akhir', v_akhir), submitted_by = auth.uid(), submitted_at = now()
     where id = v_id;
  end if;

  perform rental.log(case when p_submit then 'rental_submit' when p_id is null then 'rental_draft_baru' else 'rental_draft_ubah' end, p_depot, v_id,
    case when p_submit then 'submitted' else 'draft' end,
    jsonb_build_object('detail', 'Warehouse Rental: ' || case when p_submit then 'submit ' || v_no when p_id is null then 'draft baru' else 'draft diubah' end
                                 || ' (' || d.depot_code || ', Date Propose ' || to_char(p_tanggal, 'DD-Mon-YYYY') || ')',
                       'docNo', v_no, 'override', (select coalesce(jsonb_agg(k), '[]') from jsonb_object_keys(v_data->'revOverride') k)));
  return jsonb_build_object('status', 'success', 'row', rental.baris(v_id),
    'message', case when p_submit then 'Form di-submit: ' || v_no else 'Draft tersimpan.' end);
end $f$;

create or replace function public.rc_rental_get(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare s rental.submissions%rowtype;
begin
  select * into s from rental.submissions where id = p_id;
  if not found then raise exception 'Form tidak ditemukan'; end if;
  if not (rental.boleh(s.depot_id) and (rc_private.can_tab('rental.omset')
          or (s.status = 'draft' and (rc_private.can_tab('rental.form') or rc_private.can_tab('rental.draft')))
          or (s.status <> 'draft' and rc_private.can_tab('rental.submitted')))) then
    raise exception 'Form di luar jangkauan Anda' using errcode = '42501'; end if;
  return jsonb_build_object('status', 'success', 'row', rental.baris(p_id), 'admin', rc_private.can_tab('rental.omset'));
end $f$;

-- p_status: 'draft' (tab Draft) atau 'submitted' (tab Submitted: Submitted + Cancelled).
create or replace function public.rc_rental_list(p_status text) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_admin boolean := rc_private.can_tab('rental.omset');
begin
  if p_status = 'draft' then
    if not (rc_private.can_tab('rental.draft') or v_admin) then raise exception 'Akses tab rental.draft tidak diizinkan' using errcode = '42501'; end if;
  elsif p_status = 'submitted' then
    if not (rc_private.can_tab('rental.submitted') or v_admin) then raise exception 'Akses tab rental.submitted tidak diizinkan' using errcode = '42501'; end if;
  else raise exception 'Status tidak dikenal';
  end if;
  return jsonb_build_object('status', 'success', 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'docNo', s.doc_no, 'status', s.status, 'tanggal', s.date_propose, 'tahun', s.tahun,
             'depotKode', d.depot_code, 'depotNama', d.depot_name, 'leaseType', s.lease_type, 'rentalYears', s.rental_years,
             'offeringPrice', s.form_data->'offeringPrice', 'totalPrice', s.calc->'totalPrice', 'ownerName', s.form_data->>'ownerName',
             'pdfPath', s.pdf_path, 'dibuatOleh', (select full_name from public.profiles where id = s.created_by), 'dibuatPada', s.created_at,
             'diubahPada', s.updated_at, 'disubmitOleh', (select full_name from public.profiles where id = s.submitted_by), 'disubmitPada', s.submitted_at,
             'dibatalkanOleh', (select full_name from public.profiles where id = s.cancelled_by), 'dibatalkanPada', s.cancelled_at,
             'alasanBatal', s.cancel_reason, 'batalDari', s.cancelled_from)
           order by coalesce(s.submitted_at, s.updated_at) desc)
      from rental.submissions s join public.depots d on d.id = s.depot_id
     where (v_admin or rc_private.can_access(s.depot_id))
       and (case when p_status = 'draft' then s.status = 'draft' else s.status = 'submitted' or (s.status = 'cancelled' and s.cancelled_from = 'submitted') end)), '[]'));
end $f$;

create or replace function public.rc_rental_batal(p_id uuid, p_alasan text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare s rental.submissions%rowtype; v_alasan text := nullif(btrim(coalesce(p_alasan, '')), '');
begin
  select * into s from rental.submissions where id = p_id for update;
  if not found then raise exception 'Form tidak ditemukan'; end if;
  if not rental.boleh(s.depot_id) then raise exception 'Form di luar jangkauan Anda' using errcode = '42501'; end if;
  if s.status = 'cancelled' then raise exception 'Form sudah dibatalkan'; end if;
  if s.status = 'draft' and not (rc_private.can_tab('rental.form') or rc_private.can_tab('rental.draft') or rc_private.can_tab('rental.omset')) then
    raise exception 'Akses tab rental.draft tidak diizinkan' using errcode = '42501'; end if;
  if s.status = 'submitted' then
    if not (rc_private.can_tab('rental.form') or rc_private.can_tab('rental.omset')) then raise exception 'Akses tab rental.form tidak diizinkan' using errcode = '42501'; end if;
    if v_alasan is null then raise exception 'Alasan pembatalan wajib diisi'; end if;
  end if;
  if length(v_alasan) > 300 then raise exception 'Alasan maksimal 300 karakter'; end if;
  update rental.submissions set status = 'cancelled', cancelled_from = s.status, cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = v_alasan
   where id = p_id;
  perform rental.log('rental_batal', s.depot_id, s.id, case when s.status = 'draft' then 'draft' else 'submitted' end,
    jsonb_build_object('detail', 'Warehouse Rental: ' || case when s.status = 'draft' then 'draft dibatalkan' else 'cancel ' || s.doc_no end
                                 || coalesce(' - ' || v_alasan, ''), 'docNo', s.doc_no, 'alasan', v_alasan));
  return jsonb_build_object('status', 'success', 'message', case when s.status = 'draft' then 'Draft dibatalkan.' else 'Form ' || s.doc_no || ' dibatalkan.' end);
end $f$;

-- PDF hasil submit: browser mengunggah ke rental-pdf/<id>/<nama berkas>, lalu jalurnya dicatat.
create or replace function public.rc_rental_pdf_set(p_id uuid, p_path text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare s rental.submissions%rowtype;
begin
  select * into s from rental.submissions where id = p_id for update;
  if not found then raise exception 'Form tidak ditemukan'; end if;
  if not (rental.boleh(s.depot_id) and (rc_private.can_tab('rental.form') or rc_private.can_tab('rental.omset'))) then
    raise exception 'Form di luar jangkauan Anda' using errcode = '42501'; end if;
  if s.status <> 'submitted' then raise exception 'PDF hanya disimpan untuk form yang sudah di-submit'; end if;
  if s.pdf_path is not null then return jsonb_build_object('status', 'success', 'path', s.pdf_path); end if;
  if split_part(coalesce(p_path, ''), '/', 1) <> s.id::text then raise exception 'Jalur PDF tidak sesuai form'; end if;
  if not exists(select 1 from storage.objects o where o.bucket_id = 'rental-pdf' and o.name = p_path) then raise exception 'Berkas PDF belum terunggah'; end if;
  update rental.submissions set pdf_path = p_path where id = p_id;
  return jsonb_build_object('status', 'success', 'path', p_path);
end $f$;

-- Kebijakan Storage: tulis sekali untuk form Submitted yang belum punya PDF; baca bagi yang
-- boleh melihat form Submitted itu.
create or replace function public.rc_rental_pdf_boleh(p_name text, p_tulis boolean) returns boolean
language plpgsql stable security definer set search_path = '' as $f$
declare v_id text := split_part(coalesce(p_name, ''), '/', 1); s rental.submissions%rowtype;
begin
  if v_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  select * into s from rental.submissions where id = v_id::uuid;
  if not found or not rental.boleh(s.depot_id) then return false; end if;
  if p_tulis then
    return s.status = 'submitted' and s.pdf_path is null and p_name ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]+\.pdf$'
       and (rc_private.can_tab('rental.form') or rc_private.can_tab('rental.omset'));
  end if;
  return coalesce(s.pdf_path = p_name, false) and (rc_private.can_tab('rental.submitted') or rc_private.can_tab('rental.form') or rc_private.can_tab('rental.omset'));
end $f$;

-- ---- 4. Upload Omset -----------------------------------------------------------------------
-- p_rows: [{baris, kodeDepot, omset, pajak, bulan 'YYYY-MM'}]. Pratinjau (p_simpan=false)
-- menandai setiap baris baru / ditimpa / galat; simpan memasukkan baris yang valid saja.
create or replace function public.rc_rental_omset_unggah(p_rows jsonb, p_simpan boolean, p_nama text default null) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  e jsonb; v_hasil jsonb := '[]'; v_galat jsonb := '[]'; v_kode text; v_depot public.depots%rowtype; v_omset numeric; v_pajak numeric;
  v_bulan text; v_periode date; v_lama numeric; v_ada boolean; v_salah text; v_kunci text; v_dilihat jsonb := '{}';
  n_baru integer := 0; n_timpa integer := 0; n_galat integer := 0; v_upload uuid;
begin
  perform rc_private.require_tab('rental.omset');
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'Tidak ada baris data'; end if;
  if jsonb_array_length(p_rows) > 5000 then raise exception 'Maksimal 5.000 baris sekali upload'; end if;

  for e in select value from jsonb_array_elements(p_rows) loop
    v_salah := null; v_depot := null; v_periode := null; v_omset := null; v_pajak := null; v_lama := null;
    v_kode := upper(btrim(coalesce(e->>'kodeDepot', '')));
    v_bulan := btrim(coalesce(e->>'bulan', ''));
    begin
      if v_kode = '' then v_salah := 'Kode Depot kosong';
      else
        select * into v_depot from public.depots where depot_code = v_kode and archived_at is null and not bukan_depot;
        if v_depot.id is null then v_salah := 'Kode Depot "' || v_kode || '" tidak ada di Depot Master'; end if;
      end if;
      if v_salah is null then
        if v_bulan = '' then v_salah := 'Bulan kosong';
        elsif v_bulan !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then v_salah := 'Bulan "' || v_bulan || '" harus YYYY-MM';
        else v_periode := (v_bulan || '-01')::date;
          if v_periode < date '2000-01-01' or v_periode > date '2100-12-01' then v_salah := 'Bulan tidak wajar'; end if;
        end if;
      end if;
      if v_salah is null then v_omset := rental.angka(e, 'omset', 'Omset', true); if v_omset is null then v_salah := 'Omset kosong'; end if; end if;
      if v_salah is null then v_pajak := rental.angka(e, 'pajak', 'Pajak', false); if v_pajak is null then v_salah := 'Pajak kosong'; end if; end if;
    exception when others then v_salah := sqlerrm;
    end;
    if v_salah is null then
      v_kunci := v_depot.id::text || '|' || v_bulan;
      if v_dilihat ? v_kunci then v_salah := 'Kode Depot + Bulan ganda di berkas (baris ' || (v_dilihat->>v_kunci) || ')';
      else v_dilihat := v_dilihat || jsonb_build_object(v_kunci, coalesce(e->>'baris', '?')); end if;
    end if;
    if v_salah is null then
      select r.net into v_lama from rental.depot_revenue r where r.depot_id = v_depot.id and r.period = v_periode;
      v_ada := found;
      if v_ada then n_timpa := n_timpa + 1; else n_baru := n_baru + 1; end if;
      v_hasil := v_hasil || jsonb_build_object('baris', e->'baris', 'kodeDepot', v_kode, 'depotNama', v_depot.depot_name, 'bulan', v_bulan,
        'omset', v_omset, 'pajak', v_pajak, 'net', v_omset - v_pajak, 'status', case when v_ada then 'ditimpa' else 'baru' end, 'netLama', v_lama,
        'depotId', v_depot.id);
    else
      n_galat := n_galat + 1;
      v_hasil := v_hasil || jsonb_build_object('baris', e->'baris', 'kodeDepot', v_kode, 'bulan', v_bulan, 'omset', e->'omset', 'pajak', e->'pajak', 'status', 'galat', 'galat', v_salah);
      v_galat := v_galat || jsonb_build_object('baris', e->'baris', 'kodeDepot', v_kode, 'bulan', v_bulan, 'galat', v_salah);
    end if;
  end loop;

  if p_simpan then
    if n_baru + n_timpa = 0 then raise exception 'Tidak ada baris valid untuk disimpan'; end if;
    insert into rental.revenue_uploads(file_name, uploaded_by, rows_inserted, rows_updated, rows_error, error_log)
    values (left(nullif(btrim(coalesce(p_nama, '')), ''), 200), auth.uid(), n_baru, n_timpa, n_galat, v_galat) returning id into v_upload;
    insert into rental.depot_revenue(depot_id, period, omset, pajak, upload_id, updated_at, updated_by)
    select (x->>'depotId')::uuid, (x->>'bulan' || '-01')::date, (x->>'omset')::numeric, (x->>'pajak')::numeric, v_upload, now(), auth.uid()
      from jsonb_array_elements(v_hasil) x where x->>'status' <> 'galat'
    on conflict (depot_id, period) do update set omset = excluded.omset, pajak = excluded.pajak, upload_id = excluded.upload_id,
      updated_at = excluded.updated_at, updated_by = excluded.updated_by;
    perform rental.log('rental_omset_upload', null, v_upload, 'omset',
      jsonb_build_object('detail', 'Upload Omset' || coalesce(' ' || nullif(btrim(coalesce(p_nama, '')), ''), '') || ': ' || n_baru || ' baru, '
                                   || n_timpa || ' ditimpa, ' || n_galat || ' galat', 'baru', n_baru, 'ditimpa', n_timpa, 'galat', n_galat));
  end if;
  return jsonb_build_object('status', 'success', 'simpan', p_simpan, 'baru', n_baru, 'ditimpa', n_timpa, 'galat', n_galat,
    'baris', (select coalesce(jsonb_agg(x - 'depotId'), '[]') from jsonb_array_elements(v_hasil) x));
end $f$;

-- Rekap omset satu tahun: net per depot per bulan, plus riwayat upload.
create or replace function public.rc_rental_omset_data(p_tahun integer) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_th integer := coalesce(p_tahun, extract(year from now() at time zone 'Asia/Jakarta')::integer);
begin
  perform rc_private.require_tab('rental.omset');
  return jsonb_build_object('status', 'success', 'tahun', v_th,
    'tahunAda', coalesce((select jsonb_agg(t order by t desc) from (select distinct extract(year from period)::integer t from rental.depot_revenue) x), '[]'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('kode', d.depot_code, 'nama', d.depot_name,
               'bulan', (select jsonb_agg((select r.net from rental.depot_revenue r where r.depot_id = d.id and r.period = make_date(v_th, b, 1))) from generate_series(1, 12) b))
             order by d.depot_code) from public.depots d where d.archived_at is null and not d.bukan_depot), '[]'),
    'upload', coalesce((select jsonb_agg(jsonb_build_object('nama', u.file_name, 'oleh', p.full_name, 'pada', u.uploaded_at, 'baru', u.rows_inserted,
               'ditimpa', u.rows_updated, 'galat', u.rows_error) order by u.uploaded_at desc)
             from (select * from rental.revenue_uploads order by uploaded_at desc limit 20) u left join public.profiles p on p.id = u.uploaded_by), '[]'));
end $f$;

revoke all on function rental.boleh(uuid), rental.revenue(uuid, date), rental.baris(uuid), rental.log(text, uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.rc_rental_init(), public.rc_rental_revenue(uuid, date), public.rc_rental_simpan(uuid, uuid, date, jsonb, boolean),
  public.rc_rental_get(uuid), public.rc_rental_list(text), public.rc_rental_batal(uuid, text), public.rc_rental_pdf_set(uuid, text),
  public.rc_rental_pdf_boleh(text, boolean), public.rc_rental_omset_unggah(jsonb, boolean, text), public.rc_rental_omset_data(integer) from public, anon;
grant execute on function public.rc_rental_init(), public.rc_rental_revenue(uuid, date), public.rc_rental_simpan(uuid, uuid, date, jsonb, boolean),
  public.rc_rental_get(uuid), public.rc_rental_list(text), public.rc_rental_batal(uuid, text), public.rc_rental_pdf_set(uuid, text),
  public.rc_rental_pdf_boleh(text, boolean), public.rc_rental_omset_unggah(jsonb, boolean, text), public.rc_rental_omset_data(integer) to authenticated;

-- ---- 5. Storage ----------------------------------------------------------------------------
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('rental-pdf', 'rental-pdf', false, 5242880, array['application/pdf'])
on conflict (id) do nothing;
drop policy if exists rental_pdf_tulis on storage.objects;
create policy rental_pdf_tulis on storage.objects for insert to authenticated
  with check (bucket_id = 'rental-pdf' and public.rc_rental_pdf_boleh(name, true));
drop policy if exists rental_pdf_baca on storage.objects;
create policy rental_pdf_baca on storage.objects for select to authenticated
  using (bucket_id = 'rental-pdf' and public.rc_rental_pdf_boleh(name, false));

-- ---- 6. Izin dan tab -----------------------------------------------------------------------
insert into public.permissions(code, description)
values ('view_rental', 'Warehouse Rental: form F01.AW.2025 Rental New / Re-newal Submission, Draft, Submitted, Upload Omset')
on conflict (code) do update set description = excluded.description;

insert into rc_private.tab_catalog(code, module, label, permission, key, tab, title) values
  ('rental.form',      'rental', 'Warehouse Rental', 'view_rental', 'rental', 'form',      'Fill Form'),
  ('rental.draft',     'rental', 'Warehouse Rental', 'view_rental', 'rental', 'draft',     'Draft'),
  ('rental.submitted', 'rental', 'Warehouse Rental', 'view_rental', 'rental', 'submitted', 'Submitted'),
  ('rental.omset',     'rental', 'Warehouse Rental', 'view_rental', 'rental', 'omset',     'Upload Omset')
on conflict (code) do update set module = excluded.module, label = excluded.label, permission = excluded.permission,
  key = excluded.key, tab = excluded.tab, title = excluded.title;

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163530000' then
    src := pg_temp.ganti(src, $p$not ((p.role='depot head' and t.code in ('approval.ovd','approval.hold'))$p$,
      $p$not ((p.role='depot head' and t.code in ('approval.ovd','approval.hold')) or t.code='rental.omset' or (t.code in ('rental.form','rental.draft') and p.role<>'depot head') /* 20261163530000: Upload Omset bila dicentang; Fill Form & Draft bawaan Depot Head */$p$,
      1, 'tab_rights rental');
    execute src;
  end if;
  src := replace(pg_get_functiondef('public.rc_update_access(jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261163530000' then
    src := pg_temp.ganti(src, $p$('report','view_report'),$p$,
      $p$('report','view_report'),('rental','view_rental') /* 20261163530000 */,$p$, 1, 'update_access rental');
    execute src;
  end if;
end $tambal$;
