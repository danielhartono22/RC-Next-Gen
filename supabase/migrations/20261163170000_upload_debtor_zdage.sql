-- ==========================================================================================
-- Upload Debtor (ZDAGE): toko yang sudah lunas ditawarkan ke depot di Claim Upload > Open
-- ==========================================================================================
-- Pemilik, 16 Oktober 2026 (spesifikasi "Upload Debtor / ZDAGE Clearing" + jawaban atas
-- pertanyaan). OSC mengunggah ekspor debtor SAP ZDAGE di Document Center > Upload Debtor;
-- server menilai setiap klaim Not Yet dan menawarkan yang tokonya lunas ke depot dengan batas
-- waktu 7 hari. Lewat batas, email peringatan berangkat setiap hari sampai klaimnya diproses
-- atau dikembalikan.
--
-- KEPUTUSAN PEMILIK
--  * Kolom A ZDAGE adalah kode depot. Yang dinilai dengan data baru hanya depot yang ada di
--    file. Depot dalam jangkauan yang tidak ada di file memakai DATA LAMA (upload terakhir
--    yang mencakupnya), kecuali pengunggah mencentang "Tidak ada tagihan": depot itu memakai
--    data baru yang kosong, sehingga seluruh tokonya lunas. Depot yang belum pernah punya
--    data dan tidak dicentang tidak dinilai.
--  * Toleransi bawaan Rp 1; mode bawaan per kolom (pengaturan_sistem zdage_toleransi,
--    zdage_mode).
--  * Bad Debt ditandai admin per toko di tab Open (dengan alasan). Klaimnya tetap tampil di
--    Open, paling bawah, berlabel Bad Debt, dan tidak pernah ditawarkan. Mengajukannya hanya
--    perlu approval bila saklar "Approval Bad Debt" (tab Approval On/Off, bawaan MATI)
--    menyala - dan bila menyala, cukup lewat tab Bad Debt di Management of Approval, bukan
--    WPT/Overdue. Email pengajuan memuat remark Bad Debt.
--  * Email peringatan: TO Email TO depot, CC Email CC depot + CC Semua Email + CC wajib
--    Debtor (tab Email Pengajuan). Mengikuti saklar dan mode uji Email Pengajuan.
--  * Tab baru compilation.debtor dan approval.baddebt hanya bila dicentang (System Manager
--    selalu). Aksi dijaga tab, bukan peran (20261162130000); yurisdiksi tetap can_access.
--
-- ATURAN LUNAS (per klaim Not Yet). Bulan SO = bulan SO start, Bulan Bill = bulan billing end
-- campaign klaim itu (perpanjangan On Hold menimpa; billing mengikuti SO end bila kosong).
--   lebih dulu: tanpa Customer Master -> TANPA_MASTER; Bad Debt aktif -> BLOCKED_BAD_DEBT;
--   tawaran aktif -> SUDAH_DITAWARKAN; tawaran terakhir dikembalikan depot -> SUPPRESSED.
--   kode toko tidak ada di data -> LUNAS (aturan tidak dicek).
--   campaign tanpa SO / Billing, atau SO start sesudah Billing end -> PERIODE_SALAH (ringkasan
--   per campaign = "Campaign Bermasalah").
--   Lalu menurut SKALA PRIORITAS pemilik (16 Oktober 2026):
--     1. tidak ada Over Due Amt (> toleransi);
--     2. lunas selama periode campaign (kolom Bulan SO..Bulan Bill);
--     3. lunas sebelum periode campaign (kolom sebelum Bulan SO, termasuk T).
--   Semua aturan yang gagal dicatat beserta bulannya, diurutkan menurut prioritas; "utama"
--   adalah aturan gagal dengan prioritas tertinggi. Kolom sesudah Bulan Bill diabaikan; bulan
--   yang lebih tua dari kolom S jatuh ke T.
--
-- OPEN DAN RESTRICTED (pemilik, 17 Oktober 2026)
--  * Hanya klaim yang lunas (tawaran aktif) yang tampil di Claim Upload > Open dan dapat diajukan;
--    server menolak pengajuan klaim lain dari jalur mana pun (Mass Upload, Manual Input).
--  * Setiap Upload Debtor menilai ulang tawaran aktif: toko yang tidak lunas lagi (mis. muncul
--    Over Due Amt) tawarannya batal dan klaimnya kembali ke Restricted.
--  * Tab Restricted (bawaan terlihat, hanya baca) memuat seluruh klaim Not Yet lainnya beserta
--    alasannya. Pemegang tab "Restricted (Editor)" dapat memindahkannya ke Open (berlabel
--    Restricted, boleh diajukan). Pindah ke Posting Exception boleh bagi siapa saja tetapi hanya
--    Expired; klaim Restricted tidak dapat di-On Hold.
--  * Toko Bad Debt: saklar Approval Bad Debt menyala -> klaimnya tampil di Open dan diajukan lewat
--    approval Bad Debt; saklar mati -> tetap Restricted sampai Editor memindahkannya ke Open.
--  * Tandai / Cabut Bad Debt memerlukan tab "Bad Debt (Tandai)" yang dicentang.
--
-- Log Activity satu baris per proses; jejak per dokumen di claim_status_history.
-- Tambalan memakai penjaga MD5 pra-citra (sama di dev dan prod, 16 Oktober 2026).
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ------------------------------------------------------------------------------------------
-- 1. Tabel
-- ------------------------------------------------------------------------------------------
create table if not exists public.rc_zdage_uploads (
  id uuid primary key default gen_random_uuid(),
  file_name text not null check (btrim(file_name) <> ''),
  extracted_at timestamptz not null,
  as_of_month date not null,
  row_count integer not null default 0,
  uploaded_by uuid not null references public.profiles(id),
  status text not null default 'preview' check (status in ('preview','applied','discarded')),
  depots_kosong text[] not null default '{}',
  toleransi numeric,
  mode text,
  hasil jsonb,
  applied_at timestamptz,
  applied_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.rc_zdage_rows (
  upload_id uuid not null references public.rc_zdage_uploads(id) on delete cascade,
  row_no integer not null,
  channel text,
  depot_id uuid references public.depots(id),
  customer_code text not null,
  customer_key text not null,
  customer_name text,
  term_fi text,
  top_days integer,
  overdue_amt numeric not null default 0,
  total_amt numeric not null default 0,
  buckets jsonb not null default '{}'::jsonb,
  bucket_older numeric not null default 0,
  primary key (upload_id, row_no)
);
create unique index if not exists rc_zdage_rows_kunci on public.rc_zdage_rows(upload_id, customer_key);

-- Data debtor yang berlaku per depot: upload terakhir yang mencakup depot itu, atau tanda
-- "Tidak ada tagihan" (kosong = true).
create table if not exists public.rc_zdage_depot_data (
  depot_id uuid primary key references public.depots(id),
  upload_id uuid not null references public.rc_zdage_uploads(id),
  kosong boolean not null default false,
  as_of_month date not null,
  extracted_at timestamptz not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);

create table if not exists public.rc_bad_debt_remarks (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id),
  reason text not null check (length(btrim(reason)) >= 3),
  status text not null default 'active' check (status in ('active','revoked')),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_by uuid references public.profiles(id),
  revoked_at timestamptz,
  revoke_reason text
);
create unique index if not exists rc_bad_debt_aktif on public.rc_bad_debt_remarks(customer_id) where status = 'active';

create table if not exists public.rc_clearing_offers (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null references public.claims(id),
  upload_id uuid references public.rc_zdage_uploads(id),
  result text not null,
  reason jsonb not null default '{}'::jsonb,
  offered_at timestamptz not null default now(),
  offered_by uuid references public.profiles(id),
  deadline_at timestamptz,   -- kosong untuk klaim yang dipindah dari Restricted (result RESTRICTED)
  status text not null default 'offered' check (status in ('offered','processed','returned','overdue','cancelled')),
  return_reason text,
  acted_by uuid references public.profiles(id),
  acted_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists rc_clearing_offers_aktif on public.rc_clearing_offers(claim_id) where status in ('offered','overdue');
create index if not exists rc_clearing_offers_klaim on public.rc_clearing_offers(claim_id, created_at desc);
create index if not exists rc_clearing_offers_jatuh_tempo on public.rc_clearing_offers(deadline_at) where status = 'offered';

alter table public.rc_clearing_offers alter column deadline_at drop not null;

-- Hasil penilaian terakhir per klaim (sumber alasan di tab Restricted).
create table if not exists public.rc_zdage_hasil (
  claim_id uuid primary key references public.claims(id),
  upload_id uuid references public.rc_zdage_uploads(id),
  hasil text not null,
  alasan jsonb not null default '{}'::jsonb,
  dinilai_pada timestamptz not null default now()
);

-- Klaim yang diajukan ketika tokonya Bad Debt: sumber remark Bad Debt di email pengajuan.
alter table public.claims add column if not exists bad_debt_remark_id uuid references public.rc_bad_debt_remarks(id);

-- Akses hanya lewat RPC.
alter table public.rc_zdage_uploads enable row level security;
alter table public.rc_zdage_rows enable row level security;
alter table public.rc_zdage_depot_data enable row level security;
alter table public.rc_bad_debt_remarks enable row level security;
alter table public.rc_clearing_offers enable row level security;
alter table public.rc_zdage_hasil enable row level security;
revoke all on public.rc_zdage_uploads, public.rc_zdage_rows, public.rc_zdage_depot_data,
  public.rc_bad_debt_remarks, public.rc_clearing_offers, public.rc_zdage_hasil from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Pengaturan dan pembantu
-- ------------------------------------------------------------------------------------------
insert into public.pengaturan_sistem(kunci, nilai, catatan, diubah_pada) values
  ('zdage_toleransi', to_jsonb(1), 'Upload Debtor: sisa tagihan sampai nilai ini (Rp) dianggap lunas', now()),
  ('zdage_mode', to_jsonb('kolom'::text), 'Upload Debtor: kolom = tiap bulan dicek sendiri; jumlah = seluruh kolom sampai Bulan Bill dijumlahkan', now()),
  ('approval_bad_debt', to_jsonb(false), 'Approval pengajuan toko Bad Debt (bawaan mati)', now())
on conflict (kunci) do nothing;

create or replace function rc_private.zdage_toleransi() returns numeric
language sql stable security definer set search_path = '' as $f$
  select coalesce((select (nilai #>> '{}')::numeric from public.pengaturan_sistem where kunci = 'zdage_toleransi'), 1);
$f$;

create or replace function rc_private.zdage_mode() returns text
language sql stable security definer set search_path = '' as $f$
  select case when (select nilai #>> '{}' from public.pengaturan_sistem where kunci = 'zdage_mode') = 'jumlah'
              then 'jumlah' else 'kolom' end;
$f$;

create or replace function rc_private.approval_bad_debt_aktif() returns boolean
language sql stable security definer set search_path = '' as $f$
  select coalesce((select (nilai #>> '{}')::boolean from public.pengaturan_sistem where kunci = 'approval_bad_debt'), false);
$f$;

-- Kode toko dibandingkan tanpa spasi dan tanpa nol di depan (ZDAGE menulis "   617108").
create or replace function rc_private.kode_toko(p text) returns text
language sql immutable set search_path = '' as $f$
  select nullif(ltrim(btrim(coalesce(p, '')), '0'), '');
$f$;
create index if not exists customers_kode_toko_idx on public.customers (rc_private.kode_toko(customer_code));

create or replace function rc_private.toko_bad_debt(p_customer uuid) returns text
language sql stable security definer set search_path = '' as $f$
  select reason from public.rc_bad_debt_remarks where customer_id = p_customer and status = 'active';
$f$;

-- Status debtor satu klaim untuk tab Open (fungsi invoker): tawaran aktif dan Bad Debt.
drop function if exists rc_private.debtor_info(uuid, uuid);
create or replace function rc_private.debtor_info(p_claim uuid, p_customer uuid)
returns table(offer_id uuid, offer_status text, deadline_at timestamptz, sisa_hari integer, reason jsonb,
              bad_debt boolean, bad_debt_reason text, offer_result text)
language sql stable security definer set search_path = '' as $f$
  select o.id, o.status, o.deadline_at,
         case when o.deadline_at is null then null
              else (o.deadline_at at time zone 'Asia/Jakarta')::date - (now() at time zone 'Asia/Jakarta')::date end,
         o.reason, b.id is not null, b.reason, o.result
    from (select 1) x
    left join public.rc_clearing_offers o on o.claim_id = p_claim and o.status in ('offered','overdue')
    left join public.rc_bad_debt_remarks b on b.customer_id = p_customer and b.status = 'active';
$f$;

-- Klaim boleh tampil di Open dan diajukan: tawaran aktif, atau toko Bad Debt saat Approval Bad
-- Debt menyala.
create or replace function rc_private.boleh_open(p_claim uuid, p_customer uuid) returns boolean
language sql stable security definer set search_path = '' as $f$
  select exists(select 1 from public.rc_clearing_offers o where o.claim_id = p_claim and o.status in ('offered','overdue'))
      or (exists(select 1 from public.rc_bad_debt_remarks b where b.customer_id = p_customer and b.status = 'active')
          and rc_private.approval_bad_debt_aktif());
$f$;

-- Alasan Restricted satu klaim (dari penilaian terakhir dan data debtor depotnya).
create or replace function rc_private.restricted_info(p_claim uuid, p_customer uuid, p_depot uuid)
returns table(label text, rinci jsonb, dinilai timestamptz)
language sql stable security definer set search_path = '' as $f$
  select case
           when b.id is not null then 'Bad Debt'
           when akhir.status = 'returned' then 'Dikembalikan depot'
           when h.hasil = 'GAGAL' then 'Belum lunas'
           when h.hasil = 'PERIODE_SALAH' then 'Periode salah'
           when h.hasil = 'TANPA_MASTER' or p_customer is null then 'Tanpa Customer Master'
           when h.hasil in ('LUNAS','SUDAH_DITAWARKAN') then 'Lunas, menunggu Upload Debtor berikutnya'
           when dd.depot_id is not null then 'Belum dinilai (menunggu Upload Debtor berikutnya)'
           else 'Belum ada data debtor depot' end,
         coalesce(h.alasan, '{}'::jsonb) || jsonb_build_object('badDebt', b.reason, 'alasanKembali', case when akhir.status = 'returned' then akhir.return_reason end),
         h.dinilai_pada
    from (select 1) x
    left join public.rc_bad_debt_remarks b on b.customer_id = p_customer and b.status = 'active'
    left join public.rc_zdage_hasil h on h.claim_id = p_claim
    left join public.rc_zdage_depot_data dd on dd.depot_id = p_depot
    left join lateral (select o.status, o.return_reason from public.rc_clearing_offers o where o.claim_id = p_claim
                        order by o.created_at desc limit 1) akhir on true;
$f$;

revoke all on function rc_private.boleh_open(uuid, uuid), rc_private.restricted_info(uuid, uuid, uuid) from public, anon;
grant execute on function rc_private.boleh_open(uuid, uuid), rc_private.restricted_info(uuid, uuid, uuid) to authenticated;

revoke all on function rc_private.zdage_toleransi(), rc_private.zdage_mode(), rc_private.approval_bad_debt_aktif(),
  rc_private.toko_bad_debt(uuid), rc_private.debtor_info(uuid, uuid) from public, anon;
grant execute on function rc_private.toko_bad_debt(uuid), rc_private.debtor_info(uuid, uuid),
  rc_private.kode_toko(text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Aturan lunas satu baris ZDAGE terhadap satu periode klaim
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.zdage_aturan(p_buckets jsonb, p_older numeric, p_overdue numeric,
  p_so date, p_bill date, p_tol numeric, p_mode text)
returns jsonb language plpgsql stable set search_path = '' as $f$
declare k text; v numeric; m date; v_s date; v_so date; v_bill date; ke_t integer; label_t text;
  rinci jsonb := '[]'::jsonb; g integer[]; dalam numeric := 0; sebelum numeric := 0;
begin
  v_so := date_trunc('month', p_so)::date;
  v_bill := date_trunc('month', p_bill)::date;
  select min(to_date(x, 'YYYY-MM')) into v_s from jsonb_object_keys(coalesce(p_buckets, '{}'::jsonb)) x;

  for k, v in select e.key, coalesce(nullif(e.value #>> '{}', '')::numeric, 0) from jsonb_each(coalesce(p_buckets, '{}'::jsonb)) e loop
    m := to_date(k, 'YYYY-MM');
    if m > v_bill then continue; end if;                 -- sesudah Bulan Bill diabaikan
    if m >= v_so then
      dalam := dalam + v;
      if p_mode = 'kolom' and v > p_tol then rinci := rinci || jsonb_build_object('aturan', 2, 'bulan', k, 'nilai', v); end if;
    else
      sebelum := sebelum + v;
      if p_mode = 'kolom' and v > p_tol then rinci := rinci || jsonb_build_object('aturan', 3, 'bulan', k, 'nilai', v); end if;
    end if;
  end loop;

  -- Kolom T berisi seluruh tagihan yang lebih tua dari kolom S. Bila periode campaign
  -- menjangkau bulan setua itu, tagihannya ikut tagihan selama campaign (aturan 2).
  ke_t := case when v_s is not null and v_so < v_s then 2 else 3 end;
  label_t := '<' || coalesce(to_char(v_s, 'YYYY-MM'), '');
  v := coalesce(p_older, 0);
  if ke_t = 2 then dalam := dalam + v; else sebelum := sebelum + v; end if;
  if p_mode = 'kolom' and v > p_tol then rinci := rinci || jsonb_build_object('aturan', ke_t, 'bulan', label_t, 'nilai', v); end if;

  -- Mode jumlah: retur di satu bulan boleh menutup tagihan bulan lain sampai Bulan Bill.
  if p_mode = 'jumlah' and dalam + sebelum > p_tol then
    if dalam > p_tol or sebelum <= p_tol then rinci := rinci || jsonb_build_object('aturan', 2, 'bulan', 'jumlah', 'nilai', dalam); end if;
    if sebelum > p_tol then rinci := rinci || jsonb_build_object('aturan', 3, 'bulan', 'jumlah', 'nilai', sebelum); end if;
  end if;

  if coalesce(p_overdue, 0) > p_tol then
    rinci := rinci || jsonb_build_object('aturan', 1, 'bulan', 'Over Due Amt', 'nilai', p_overdue);
  end if;

  select coalesce(array_agg(distinct (x->>'aturan')::integer order by (x->>'aturan')::integer), '{}') into g
    from jsonb_array_elements(rinci) x;
  -- Rincian diurutkan menurut prioritas aturan, lalu bulan terbaru lebih dulu.
  select coalesce(jsonb_agg(x order by (x->>'aturan')::integer, (x->>'bulan') like '<%', x->>'bulan' desc), '[]'::jsonb) into rinci
    from jsonb_array_elements(rinci) x;
  return jsonb_build_object('gagal', to_jsonb(g), 'utama', g[1], 'rincian', rinci);
end $f$;

-- ------------------------------------------------------------------------------------------
-- 4. Penilaian seluruh klaim Not Yet dalam jangkauan pemanggil
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.zdage_evaluasi(p_upload uuid, p_kosong text[], p_tol numeric, p_mode text)
returns table(claim_id uuid, no_doc text, depot_id uuid, depot_code text, depot_name text, customer_id uuid,
  kode_toko text, nama_toko text, campaign_code text, campaign_name text, cb_net numeric, version_no bigint,
  paid_on date, bulan_so date, bulan_bill date, sumber text, sumber_upload uuid, tgl_tarikan timestamptz,
  hasil text, alasan jsonb)
language sql stable security definer set search_path = '' as $f$
  with up as (select u.* from public.rc_zdage_uploads u where u.id = p_upload),
  dep_file as (select distinct r.depot_id from public.rc_zdage_rows r where r.upload_id = p_upload and r.depot_id is not null),
  sumber as (
    select d.id depot_id, d.depot_code, d.depot_name,
           case when d.id in (select f.depot_id from dep_file f) then 'baru'
                when d.depot_code = any(coalesce(p_kosong, '{}')) then 'kosong'
                when dd.depot_id is not null then case when dd.kosong then 'lama_kosong' else 'lama' end end sumber,
           case when d.id in (select f.depot_id from dep_file f) then p_upload
                when d.depot_code = any(coalesce(p_kosong, '{}')) then null
                when dd.depot_id is not null and not dd.kosong then dd.upload_id end sumber_upload,
           case when d.id in (select f.depot_id from dep_file f) or d.depot_code = any(coalesce(p_kosong, '{}'))
                then (select up.extracted_at from up) else dd.extracted_at end tgl_tarikan
      from public.depots d
      left join public.rc_zdage_depot_data dd on dd.depot_id = d.id
     where d.archived_at is null and rc_private.can_access(d.id, 'view_compilation')
  ),
  k as (
    select c.id, c.no_doc, c.depot_id, s.depot_code, s.depot_name, c.customer_id, cu.customer_code, cu.customer_name,
           ca.campaign_code, ca.campaign_name, c.cb_net, c.version_no, c.paid_on,
           -- Hanya SO dan Billing dari Campaign Master; tanpa keduanya campaign bermasalah.
           date_trunc('month', coalesce(c.extend_so_start, ca.so_start))::date bso,
           date_trunc('month', coalesce(c.extend_billing_end, ca.billing_end, ca.so_end))::date bbill,
           s.sumber, s.sumber_upload, s.tgl_tarikan
      from public.claims c
      join sumber s on s.depot_id = c.depot_id and s.sumber is not null
      join public.campaigns ca on ca.id = c.campaign_id
      left join public.customers cu on cu.id = c.customer_id
     where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
  )
  select k.id, k.no_doc, k.depot_id, k.depot_code, k.depot_name, k.customer_id,
         coalesce(k.customer_code, ''), coalesce(k.customer_name, ''), k.campaign_code, k.campaign_name,
         k.cb_net, k.version_no, k.paid_on, k.bso, k.bbill, k.sumber, k.sumber_upload, k.tgl_tarikan,
         -- Tawaran aktif dinilai ulang (pemilik, 17 Oktober 2026): bila tidak lunas lagi, hasilnya
         -- hasil penilaian baru dan tawarannya dibatalkan saat diterapkan. Klaim yang dipindah
         -- dari Restricted oleh Editor (result RESTRICTED) adalah keputusan manusia - tidak dinilai ulang.
         case when k.customer_id is null then 'TANPA_MASTER'
              when bd.id is not null then 'BLOCKED_BAD_DEBT'
              when ak.id is not null and ak.result = 'RESTRICTED' then 'SUDAH_DITAWARKAN'
              when ak.id is null and akhir.status = 'returned' then 'SUPPRESSED'
              when r.customer_key is null then case when ak.id is not null then 'SUDAH_DITAWARKAN' else 'LUNAS' end
              when k.bso is null or k.bbill is null or k.bso > k.bbill then 'PERIODE_SALAH'
              when jsonb_array_length(a.aturan->'gagal') > 0 then 'GAGAL'
              when ak.id is not null then 'SUDAH_DITAWARKAN'
              else 'LUNAS' end,
         jsonb_build_object('sumber', k.sumber,
           'tarikan', to_char(k.tgl_tarikan at time zone 'Asia/Jakarta', 'YYYY-MM-DD'),
           'bulanSo', to_char(k.bso, 'YYYY-MM'), 'bulanBill', to_char(k.bbill, 'YYYY-MM'),
           'tidakDiFile', r.customer_key is null,
           'badDebt', bd.reason,
           'deadlineAktif', case when ak.deadline_at is null then null else to_char(ak.deadline_at at time zone 'Asia/Jakarta', 'YYYY-MM-DD') end,
           'tawaranAktif', ak.id is not null, 'tawaranJenis', ak.result,
           'masalah', case when k.bso is null or k.bbill is null then 'tanpa_tanggal' when k.bso > k.bbill then 'tanggal_salah' end,
           'alasanKembali', case when akhir.status = 'returned' then akhir.return_reason end,
           'overdue', r.overdue_amt)
           || coalesce(a.aturan, jsonb_build_object('gagal', '[]'::jsonb, 'rincian', '[]'::jsonb))
    from k
    left join public.rc_bad_debt_remarks bd on bd.customer_id = k.customer_id and bd.status = 'active'
    left join public.rc_clearing_offers ak on ak.claim_id = k.id and ak.status in ('offered','overdue')
    left join lateral (select o.status, o.return_reason from public.rc_clearing_offers o
                        where o.claim_id = k.id order by o.created_at desc limit 1) akhir on true
    left join public.rc_zdage_rows r on r.upload_id = k.sumber_upload and r.customer_key = rc_private.kode_toko(k.customer_code)
    left join lateral (select rc_private.zdage_aturan(r.buckets, r.bucket_older, r.overdue_amt, k.bso, k.bbill, p_tol, p_mode) aturan
                        where r.customer_key is not null and k.bso is not null and k.bbill is not null and k.bso <= k.bbill) a on true;
$f$;
revoke all on function rc_private.zdage_aturan(jsonb, numeric, numeric, date, date, numeric, text),
  rc_private.zdage_evaluasi(uuid, text[], numeric, text) from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 5. RPC Upload Debtor
-- ------------------------------------------------------------------------------------------
-- Menerima baris ZDAGE per bagian (<= 500). Bagian pertama membuat upload berstatus preview;
-- bagian berikutnya membawa p_upload_id. Pratinjau lama milik pengunggah yang sama dibuang.
create or replace function public.rc_zdage_stage(p_file_name text, p_extracted_at timestamptz, p_rows jsonb,
  p_upload_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare u public.rc_zdage_uploads; v_as date; v_bulan text[]; v_galat text; v_dup text; n integer;
begin
  perform rc_private.require_tab('compilation.debtor');
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Tidak ada baris yang dikirim'; end if;
  if jsonb_array_length(p_rows) > 500 then raise exception 'Maksimal 500 baris sekali kirim'; end if;

  if p_upload_id is null then
    if btrim(coalesce(p_file_name, '')) = '' then raise exception 'Nama berkas wajib diisi'; end if;
    if p_extracted_at is null then raise exception 'Tanggal tarikan ZDAGE wajib diisi'; end if;
    if p_extracted_at > now() + interval '1 day' then raise exception 'Tanggal tarikan ZDAGE belum terjadi'; end if;
    begin
      select max(to_date(x, 'YYYY-MM')) into v_as from jsonb_object_keys(p_rows->0->'buckets') x;
    exception when others then v_as := null;
    end;
    if v_as is null then raise exception 'Kolom bulan G..S tidak terbaca'; end if;
    delete from public.rc_zdage_rows where upload_id in
      (select id from public.rc_zdage_uploads where uploaded_by = auth.uid() and status = 'preview');
    update public.rc_zdage_uploads set status = 'discarded' where uploaded_by = auth.uid() and status = 'preview';
    insert into public.rc_zdage_uploads(file_name, extracted_at, as_of_month, uploaded_by)
    values (left(btrim(p_file_name), 200), p_extracted_at, v_as, auth.uid()) returning * into u;
  else
    select * into u from public.rc_zdage_uploads where id = p_upload_id for update;
    if not found or u.uploaded_by <> auth.uid() then raise exception 'Upload tidak ditemukan'; end if;
    if u.status <> 'preview' then raise exception 'Upload ini sudah %; unggah ulang berkasnya', u.status; end if;
  end if;

  v_bulan := array(select to_char((u.as_of_month - make_interval(months => i))::date, 'YYYY-MM') from generate_series(0, 12) i);

  -- Seluruh bagian diperiksa sebelum ada yang ditulis.
  select string_agg(format('baris %s', x->>'rowNo'), ', ') into v_galat
    from jsonb_array_elements(p_rows) x
   where coalesce(btrim(x->>'customerCode'), '') = ''
      or rc_private.kode_toko(x->>'customerCode') is null
      or jsonb_typeof(x->'buckets') is distinct from 'object'
      or (select array_agg(b order by b) from jsonb_object_keys(x->'buckets') b) is distinct from (select array_agg(b order by b) from unnest(v_bulan) b)
      or jsonb_typeof(x->'overdueAmt') is distinct from 'number' or jsonb_typeof(x->'totalAmt') is distinct from 'number'
      or jsonb_typeof(x->'bucketOlder') is distinct from 'number'
      or exists(select 1 from jsonb_each(x->'buckets') e where jsonb_typeof(e.value) <> 'number');
  if v_galat is not null then
    raise exception 'Upload ditolak, baris berikut tidak terbaca (kode toko, 13 kolom bulan mundur dari %, atau angka E..T): %',
      to_char(u.as_of_month, 'Mon-YYYY'), left(v_galat, 600); end if;

  select string_agg(format('%s (baris %s)', kode, baris), ', ') into v_dup from (
    select rc_private.kode_toko(x->>'customerCode') kode, string_agg(x->>'rowNo', ' dan ') baris
      from jsonb_array_elements(p_rows) x group by 1 having count(*) > 1
    union all
    select r.customer_key, r.row_no || ' dan ' || (x->>'rowNo')
      from jsonb_array_elements(p_rows) x
      join public.rc_zdage_rows r on r.upload_id = u.id and r.customer_key = rc_private.kode_toko(x->>'customerCode')) d;
  if v_dup is not null then raise exception 'Upload ditolak, kode toko duplikat: %', left(v_dup, 600); end if;

  insert into public.rc_zdage_rows(upload_id, row_no, channel, depot_id, customer_code, customer_key, customer_name,
    term_fi, top_days, overdue_amt, total_amt, buckets, bucket_older)
  select u.id, (x->>'rowNo')::integer, nullif(btrim(coalesce(x->>'channel', '')), ''),
         (select d.id from public.depots d where d.depot_code = upper(btrim(coalesce(x->>'channel', ''))) and d.archived_at is null),
         btrim(x->>'customerCode'), rc_private.kode_toko(x->>'customerCode'), nullif(btrim(coalesce(x->>'customerName', '')), ''),
         nullif(btrim(coalesce(x->>'termFi', '')), ''), nullif(regexp_replace(coalesce(x->>'termFi', ''), '\D', '', 'g'), '')::integer,
         (x->>'overdueAmt')::numeric, (x->>'totalAmt')::numeric, x->'buckets', (x->>'bucketOlder')::numeric
    from jsonb_array_elements(p_rows) x;
  get diagnostics n = row_count;
  update public.rc_zdage_uploads set row_count = row_count + n where id = u.id;
  return jsonb_build_object('status', 'success', 'uploadId', u.id, 'diterima', n,
    'asOf', to_char(u.as_of_month, 'YYYY-MM'));
end $f$;

-- Pemeriksaan yang menolak penerapan: bulan tarikan lebih tua dari data depot yang berlaku.
create or replace function rc_private.zdage_galat(p_upload uuid) returns text
language sql stable security definer set search_path = '' as $f$
  select string_agg(format('%s (data berlaku %s, file %s)', d.depot_code, to_char(dd.as_of_month, 'Mon-YYYY'),
           to_char(u.as_of_month, 'Mon-YYYY')), ', ' order by d.depot_code)
    from public.rc_zdage_uploads u
    join (select distinct r.depot_id from public.rc_zdage_rows r where r.upload_id = p_upload and r.depot_id is not null) f on true
    join public.depots d on d.id = f.depot_id
    join public.rc_zdage_depot_data dd on dd.depot_id = d.id
   where u.id = p_upload and dd.as_of_month > u.as_of_month and dd.upload_id <> u.id
     and rc_private.can_access(d.id, 'view_compilation');
$f$;
revoke all on function rc_private.zdage_galat(uuid) from public, anon, authenticated;

create or replace function public.rc_zdage_preview(p_upload_id uuid, p_kosong text[] default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare u public.rc_zdage_uploads; v_tol numeric := rc_private.zdage_toleransi(); v_mode text := rc_private.zdage_mode();
  v_rows jsonb; v_ring jsonb; v_dep_file jsonb; v_tidak jsonb;
  n_total_beda integer; v_galat text; v_luar jsonb; v_asing jsonb;
begin
  perform rc_private.require_tab('compilation.debtor');
  select * into u from public.rc_zdage_uploads where id = p_upload_id;
  if not found or (u.uploaded_by <> auth.uid() and not rc_private.is_system_manager()) then
    raise exception 'Upload tidak ditemukan'; end if;

  drop table if exists pg_temp._zdage_ev;
  create temp table _zdage_ev on commit drop as select * from rc_private.zdage_evaluasi(u.id, p_kosong, v_tol, v_mode);

  select coalesce(jsonb_agg(jsonb_build_object('noDoc', e.no_doc, 'kodeDepot', e.depot_code, 'namaDepot', e.depot_name,
           'kodeToko', e.kode_toko, 'namaToko', e.nama_toko, 'kodeCampaign', e.campaign_code, 'namaCampaign', e.campaign_name,
           'netCb', e.cb_net, 'bulanSo', to_char(e.bulan_so, 'YYYY-MM'), 'bulanBill', to_char(e.bulan_bill, 'YYYY-MM'),
           'hasil', e.hasil, 'alasan', e.alasan) order by e.depot_code, e.hasil, e.no_doc), '[]'::jsonb)
    into v_rows from _zdage_ev e;

  select jsonb_build_object(
      'total', count(*),
      'lunas', count(*) filter (where hasil = 'LUNAS'),
      'lunasCb', coalesce(sum(cb_net) filter (where hasil = 'LUNAS'), 0),
      'gagal', count(*) filter (where hasil = 'GAGAL'),
      -- Belum lunas per penyebab UTAMA (aturan gagal dengan prioritas tertinggi).
      'gagal1', count(*) filter (where hasil = 'GAGAL' and (alasan->>'utama')::integer = 1),
      'gagal2', count(*) filter (where hasil = 'GAGAL' and (alasan->>'utama')::integer = 2),
      'gagal3', count(*) filter (where hasil = 'GAGAL' and (alasan->>'utama')::integer = 3),
      'badDebt', count(*) filter (where hasil = 'BLOCKED_BAD_DEBT'),
      'suppressed', count(*) filter (where hasil = 'SUPPRESSED'),
      'sudahDitawarkan', count(*) filter (where hasil = 'SUDAH_DITAWARKAN'),
      'periodeSalah', count(*) filter (where hasil = 'PERIODE_SALAH'),
      'campaignBermasalah', count(distinct campaign_code) filter (where hasil = 'PERIODE_SALAH'),
      'kembaliRestricted', count(*) filter (where (alasan->>'tawaranAktif')::boolean and hasil <> 'SUDAH_DITAWARKAN'),
      'tanpaMaster', count(*) filter (where hasil = 'TANPA_MASTER'))
    into v_ring from _zdage_ev;
  -- Campaign Bermasalah: ringkasan per campaign dari klaim Periode Salah.
  v_ring := v_ring || jsonb_build_object('campaign', coalesce((select jsonb_agg(jsonb_build_object('kode', z.campaign_code, 'nama', z.campaign_name,
        'masalah', z.masalah, 'bulanSo', to_char(z.bso, 'YYYY-MM'), 'bulanBill', to_char(z.bbill, 'YYYY-MM'), 'klaim', z.n, 'netCb', z.cb)
        order by z.n desc, z.campaign_code)
      from (select e.campaign_code, e.campaign_name, e.alasan->>'masalah' masalah, min(e.bulan_so) bso, min(e.bulan_bill) bbill,
                   count(*) n, coalesce(sum(e.cb_net), 0) cb
              from _zdage_ev e where e.hasil = 'PERIODE_SALAH' group by 1, 2, 3) z), '[]'::jsonb));

  -- Depot di file.
  select coalesce(jsonb_agg(jsonb_build_object('kode', z.kode, 'nama', z.nama, 'toko', z.toko,
           'notYet', (select count(*) from _zdage_ev e where e.depot_id = z.id)) order by z.kode), '[]'::jsonb)
    into v_dep_file
    from (select d.id, d.depot_code kode, d.depot_name nama, count(*) toko
            from public.rc_zdage_rows r join public.depots d on d.id = r.depot_id
           where r.upload_id = u.id and rc_private.can_access(d.id, 'view_compilation')
           group by d.id, d.depot_code, d.depot_name) z;

  -- Depot di file tetapi di luar jangkauan pengunggah, dan kode kolom A yang bukan depot.
  select coalesce(jsonb_agg(distinct d.depot_code), '[]'::jsonb) into v_luar
    from public.rc_zdage_rows r join public.depots d on d.id = r.depot_id
   where r.upload_id = u.id and not rc_private.can_access(d.id, 'view_compilation');
  select coalesce(jsonb_agg(jsonb_build_object('kode', z.channel, 'toko', z.n) order by z.channel), '[]'::jsonb) into v_asing
    from (select coalesce(r.channel, '(kosong)') channel, count(*) n from public.rc_zdage_rows r
           where r.upload_id = u.id and r.depot_id is null group by 1) z;

  -- Depot dalam jangkauan yang punya klaim Not Yet tetapi tidak ada di file (pop up).
  select coalesce(jsonb_agg(jsonb_build_object('kode', d.depot_code, 'nama', d.depot_name,
           'notYet', (select count(*) from public.claims c where c.depot_id = d.id and c.status = 'not_yet'
                       and c.pending_approval is null and c.archived_at is null),
           'dataLama', case when dd.depot_id is null then null else jsonb_build_object(
             'asOf', to_char(dd.as_of_month, 'Mon-YYYY'), 'tarikan', to_char(dd.extracted_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY'),
             'kosong', dd.kosong) end,
           'tidakAdaTagihan', d.depot_code = any(coalesce(p_kosong, '{}'))) order by d.depot_code), '[]'::jsonb)
    into v_tidak
    from public.depots d
    left join public.rc_zdage_depot_data dd on dd.depot_id = d.id
   where d.archived_at is null and rc_private.can_access(d.id, 'view_compilation')
     and not exists(select 1 from public.rc_zdage_rows r where r.upload_id = u.id and r.depot_id = d.id)
     and exists(select 1 from public.claims c where c.depot_id = d.id and c.status = 'not_yet'
                 and c.pending_approval is null and c.archived_at is null);

  -- Peringatan: Total <> jumlah G..T. Kode toko yang tidak ada di Customer Master dibiarkan
  -- (keputusan pemilik): toko itu tidak punya klaim, jadi tidak memengaruhi penilaian.
  select count(*) into n_total_beda from public.rc_zdage_rows r
   where r.upload_id = u.id
     and abs(r.total_amt - r.bucket_older - (select coalesce(sum((e.value #>> '{}')::numeric), 0) from jsonb_each(r.buckets) e)) > 1;

  v_galat := rc_private.zdage_galat(u.id);

  return jsonb_build_object('status', 'success',
    'upload', jsonb_build_object('id', u.id, 'file', u.file_name, 'status', u.status, 'baris', u.row_count,
      'tarikan', to_char(u.extracted_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
      'asOf', to_char(u.as_of_month, 'Mon-YYYY')),
    'toleransi', v_tol, 'mode', v_mode,
    'ringkasan', v_ring, 'rows', v_rows,
    'depotFile', v_dep_file, 'depotTidakAda', v_tidak, 'depotLuarJangkauan', v_luar, 'kodeDepotAsing', v_asing,
    'totalBeda', n_total_beda,
    'galat', case when v_galat is null then '[]'::jsonb else jsonb_build_array(
      'Bulan tarikan file lebih tua dari data debtor yang sudah berlaku untuk depot: ' || v_galat) end);
end $f$;

create or replace function public.rc_zdage_apply(p_upload_id uuid, p_kosong text[] default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare u public.rc_zdage_uploads; v_tol numeric := rc_private.zdage_toleransi(); v_mode text := rc_private.zdage_mode();
  v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_deadline timestamptz; v_ids uuid[]; v_hasil jsonb;
  v_galat text; v_kosong text[]; v_salah text; n_tgl integer; n_batal integer := 0;
begin
  perform rc_private.require_tab('compilation.debtor');
  perform pg_advisory_xact_lock(hashtextextended('rc-zdage-apply', 0));
  select * into u from public.rc_zdage_uploads where id = p_upload_id for update;
  if not found or (u.uploaded_by <> auth.uid() and not rc_private.is_system_manager()) then
    raise exception 'Upload tidak ditemukan'; end if;
  -- Idempoten: menerapkan ulang tidak membuat tawaran baru dan tidak memperpanjang deadline.
  if u.status = 'applied' then
    return coalesce(u.hasil, '{}'::jsonb) || jsonb_build_object('status', 'success', 'sudahDiterapkan', true,
      'message', 'Upload ini sudah diterapkan pada ' || to_char(u.applied_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || '; tidak ada yang berubah.');
  end if;
  if u.status <> 'preview' then raise exception 'Upload ini sudah dibatalkan; unggah ulang berkasnya'; end if;
  if u.row_count = 0 then raise exception 'Upload belum berisi baris'; end if;
  v_galat := rc_private.zdage_galat(u.id);
  if v_galat is not null then
    raise exception 'Upload ditolak: bulan tarikan file lebih tua dari data debtor yang sudah berlaku untuk depot %', v_galat; end if;

  -- "Tidak ada tagihan" hanya untuk depot dalam jangkauan yang memang tidak ada di file.
  v_kosong := array(select distinct upper(btrim(x)) from unnest(coalesce(p_kosong, '{}')) x where btrim(x) <> '');
  select string_agg(x, ', ') into v_salah from unnest(v_kosong) x
   where not exists(select 1 from public.depots d where d.depot_code = x and d.archived_at is null
                     and rc_private.can_access(d.id, 'view_compilation')
                     and not exists(select 1 from public.rc_zdage_rows r where r.upload_id = u.id and r.depot_id = d.id));
  if v_salah is not null then raise exception 'Depot "Tidak ada tagihan" tidak sah: %', v_salah; end if;

  v_deadline := ((v_hari + 7)::timestamp + time '23:59:59') at time zone 'Asia/Jakarta';
  drop table if exists pg_temp._zdage_ev;
  create temp table _zdage_ev on commit drop as select * from rc_private.zdage_evaluasi(u.id, v_kosong, v_tol, v_mode);

  with baru as (
    insert into public.rc_clearing_offers(claim_id, upload_id, result, reason, offered_at, offered_by, deadline_at, status)
    select e.claim_id, u.id, 'LUNAS', e.alasan, now(), auth.uid(), v_deadline, 'offered'
      from _zdage_ev e where e.hasil = 'LUNAS'
    on conflict (claim_id) where status in ('offered','overdue') do nothing
    returning claim_id)
  select coalesce(array_agg(claim_id), '{}') into v_ids from baru;

  -- Tawaran aktif yang menurut data baru tidak lunas lagi dibatalkan: klaimnya kembali ke Restricted.
  with batal as (
    update public.rc_clearing_offers o set status = 'cancelled', acted_by = auth.uid(), acted_at = now()
      from _zdage_ev e
     where o.claim_id = e.claim_id and o.status in ('offered','overdue') and o.result <> 'RESTRICTED'
       and (e.alasan->>'tawaranAktif')::boolean and e.hasil <> 'SUDAH_DITAWARKAN'
    returning o.claim_id, e.hasil, e.alasan, e.tgl_tarikan),
  h as (
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    select b.claim_id, auth.uid(), 'not_yet', 'not_yet', 'zdage_cancel',
           left('Tidak lunas lagi menurut debtor ZDAGE tarikan ' || to_char(b.tgl_tarikan at time zone 'Asia/Jakarta', 'DD-Mon-YYYY') || ': '
             || case b.hasil when 'GAGAL' then case (b.alasan->>'utama')::integer when 1 then 'over due' when 2 then 'tagihan selama periode campaign'
                                                   else 'tagihan sebelum periode campaign' end
                             when 'PERIODE_SALAH' then 'periode campaign salah' else lower(b.hasil) end
             || '. Kembali ke Restricted.', 300)
      from batal b returning claim_id)
  select count(*) into n_batal from batal;

  -- Hasil penilaian terakhir per klaim: sumber alasan di tab Restricted.
  insert into public.rc_zdage_hasil(claim_id, upload_id, hasil, alasan, dinilai_pada)
  select e.claim_id, u.id, e.hasil, e.alasan, now() from _zdage_ev e
  on conflict (claim_id) do update set upload_id = excluded.upload_id, hasil = excluded.hasil,
    alasan = excluded.alasan, dinilai_pada = excluded.dinilai_pada;

  -- Tgl Lunas = tanggal tarikan data yang dipakai, hanya bila masih kosong.
  update public.claims c set paid_on = (e.tgl_tarikan at time zone 'Asia/Jakarta')::date,
         version_no = c.version_no + 1, updated_at = now()
    from _zdage_ev e
   where c.id = e.claim_id and c.id = any(v_ids) and c.paid_on is null;
  get diagnostics n_tgl = row_count;

  insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
  select e.claim_id, auth.uid(), 'not_yet', 'not_yet', 'zdage_offer',
         left('Toko lunas menurut debtor ZDAGE tarikan ' || to_char(e.tgl_tarikan at time zone 'Asia/Jakarta', 'DD-Mon-YYYY')
           || case e.sumber when 'lama' then ' (data lama depot)' when 'kosong' then ' (depot tanpa tagihan)'
                            when 'lama_kosong' then ' (depot tanpa tagihan, data lama)' else '' end
           || '. Batas proses ' || to_char(v_hari + 7, 'DD-Mon-YYYY') || '.', 300)
    from _zdage_ev e where e.claim_id = any(v_ids);

  insert into public.rc_zdage_depot_data(depot_id, upload_id, kosong, as_of_month, extracted_at, updated_at, updated_by)
  select z.depot_id, u.id, z.kosong, u.as_of_month, u.extracted_at, now(), auth.uid()
    from (select distinct r.depot_id, false kosong from public.rc_zdage_rows r
           where r.upload_id = u.id and r.depot_id is not null and rc_private.can_access(r.depot_id, 'view_compilation')
          union
          select d.id, true from public.depots d where d.depot_code = any(v_kosong) and d.archived_at is null) z
  on conflict (depot_id) do update set upload_id = excluded.upload_id, kosong = excluded.kosong,
    as_of_month = excluded.as_of_month, extracted_at = excluded.extracted_at, updated_at = now(), updated_by = excluded.updated_by;

  select jsonb_build_object(
      'tawaranBaru', coalesce(array_length(v_ids, 1), 0),
      'kembaliRestricted', n_batal,
      'tglLunasDiisi', n_tgl,
      'lunas', count(*) filter (where hasil = 'LUNAS'),
      'gagal', count(*) filter (where hasil = 'GAGAL'),
      'badDebt', count(*) filter (where hasil = 'BLOCKED_BAD_DEBT'),
      'suppressed', count(*) filter (where hasil = 'SUPPRESSED'),
      'sudahDitawarkan', count(*) filter (where hasil = 'SUDAH_DITAWARKAN'),
      'periodeSalah', count(*) filter (where hasil = 'PERIODE_SALAH'),
      'campaignBermasalah', count(distinct campaign_code) filter (where hasil = 'PERIODE_SALAH'),
      'tanpaMaster', count(*) filter (where hasil = 'TANPA_MASTER'),
      'dinilai', count(*),
      'deadline', to_char(v_hari + 7, 'DD-Mon-YYYY'),
      'depotKosong', to_jsonb(v_kosong))
    into v_hasil from _zdage_ev;

  update public.rc_zdage_uploads set status = 'applied', applied_at = now(), applied_by = auth.uid(),
         depots_kosong = v_kosong, toleransi = v_tol, mode = v_mode, hasil = v_hasil
   where id = u.id;

  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), 'zdage_offer', jsonb_build_object(
      'detail', 'Upload Debtor ' || u.file_name || ': ' || coalesce(array_length(v_ids, 1), 0) || ' toko lunas ditawarkan ke depot',
      'uploadId', u.id) || v_hasil, 'compilation', 'debtor', 'debtor');

  return v_hasil || jsonb_build_object('status', 'success', 'sudahDiterapkan', false,
    'message', coalesce(array_length(v_ids, 1), 0) || ' toko lunas ditawarkan ke depot, batas proses ' || to_char(v_hari + 7, 'DD-Mon-YYYY') || '.'
      || case when n_batal > 0 then ' ' || n_batal || ' tawaran tidak lunas lagi dan kembali ke Restricted.' else '' end);
end $f$;

create or replace function public.rc_zdage_discard(p_upload_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $f$
begin
  perform rc_private.require_tab('compilation.debtor');
  delete from public.rc_zdage_rows where upload_id = p_upload_id
     and exists(select 1 from public.rc_zdage_uploads u where u.id = p_upload_id and u.status = 'preview' and u.uploaded_by = auth.uid());
  update public.rc_zdage_uploads set status = 'discarded' where id = p_upload_id and status = 'preview' and uploaded_by = auth.uid();
  return jsonb_build_object('status', 'success');
end $f$;

-- Riwayat upload dan data debtor yang berlaku per depot dalam jangkauan.
create or replace function public.rc_zdage_riwayat()
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  perform rc_private.require_tab('compilation.debtor');
  return jsonb_build_object('status', 'success', 'toleransi', rc_private.zdage_toleransi(), 'mode', rc_private.zdage_mode(),
    'upload', coalesce((select jsonb_agg(jsonb_build_object('file', u.file_name, 'status', u.status,
        'tarikan', to_char(u.extracted_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY'), 'asOf', to_char(u.as_of_month, 'Mon-YYYY'),
        'baris', u.row_count, 'oleh', coalesce(p.full_name, p.user_code, ''),
        'diterapkan', case when u.applied_at is null then '' else to_char(u.applied_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') end,
        'tawaranBaru', coalesce((u.hasil->>'tawaranBaru')::integer, 0)) order by u.created_at desc)
      from (select * from public.rc_zdage_uploads where status = 'applied' order by created_at desc limit 20) u
      left join public.profiles p on p.id = coalesce(u.applied_by, u.uploaded_by)), '[]'::jsonb),
    'depot', coalesce((select jsonb_agg(jsonb_build_object('kode', d.depot_code, 'nama', d.depot_name,
        'asOf', to_char(dd.as_of_month, 'Mon-YYYY'), 'tarikan', to_char(dd.extracted_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY'),
        'kosong', dd.kosong) order by d.depot_code)
      from public.rc_zdage_depot_data dd join public.depots d on d.id = dd.depot_id
     where rc_private.can_access(d.id, 'view_compilation')), '[]'::jsonb));
end $f$;

-- ------------------------------------------------------------------------------------------
-- 6. Tawaran: dikembalikan depot, ditawarkan ulang OSC, mengikuti klaim
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_clearing_return(p_no_docs text[], p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare v_alasan text := left(btrim(coalesce(p_reason, '')), 300); v_docs text[]; n integer; v_gagal text[];
begin
  perform rc_private.require_tab('upload.open');
  if length(v_alasan) < 3 then raise exception 'Alasan mengembalikan wajib diisi'; end if;
  v_docs := array(select distinct upper(btrim(x)) from unnest(coalesce(p_no_docs, '{}')) x where btrim(x) <> '');
  if coalesce(array_length(v_docs, 1), 0) = 0 then raise exception 'Pilih dokumen lebih dulu'; end if;
  if array_length(v_docs, 1) > 500 then raise exception 'Maksimal 500 dokumen sekali proses'; end if;

  with t as (
    update public.rc_clearing_offers o set status = 'returned', return_reason = v_alasan, acted_by = auth.uid(), acted_at = now()
      from public.claims c
     where c.id = o.claim_id and upper(c.no_doc) = any(v_docs) and o.status in ('offered','overdue')
       and c.status = 'not_yet' and c.archived_at is null and rc_private.can_access(c.depot_id, 'upload_claim')
    returning o.claim_id, c.no_doc),
  h as (
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    select t.claim_id, auth.uid(), 'not_yet', 'not_yet', 'zdage_return', left('Tawaran toko lunas dikembalikan depot: ' || v_alasan, 300)
      from t returning claim_id)
  select count(*), array(select d from unnest(v_docs) d where d not in (select upper(t2.no_doc) from t t2)) into n, v_gagal from t;

  if n > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'zdage_return', jsonb_build_object('detail', 'Kembalikan ke Not Yet (toko lunas): ' || n || ' dokumen',
      'jumlah', n, 'alasan', v_alasan), 'upload', 'open', 'open');
  end if;
  return jsonb_build_object('status', 'success', 'berhasil', n, 'gagal', to_jsonb(v_gagal),
    'message', n || ' dokumen dikembalikan; tidak akan ditawarkan otomatis lagi'
      || case when coalesce(array_length(v_gagal, 1), 0) > 0 then '. ' || array_length(v_gagal, 1) || ' dokumen tidak punya tawaran aktif' else '' end);
end $f$;

create or replace function public.rc_clearing_reoffer(p_no_docs text[])
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare v_docs text[]; v_hari date := (now() at time zone 'Asia/Jakarta')::date; n integer;
begin
  perform rc_private.require_tab('compilation.debtor');
  v_docs := array(select distinct upper(btrim(x)) from unnest(coalesce(p_no_docs, '{}')) x where btrim(x) <> '');
  if coalesce(array_length(v_docs, 1), 0) = 0 then raise exception 'Pilih dokumen lebih dulu'; end if;

  with kandidat as (
    select c.id, akhir.upload_id, akhir.return_reason
      from public.claims c
      join lateral (select o.status, o.upload_id, o.return_reason from public.rc_clearing_offers o
                     where o.claim_id = c.id order by o.created_at desc limit 1) akhir on true
     where upper(c.no_doc) = any(v_docs) and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
       and akhir.status in ('returned','cancelled') and rc_private.can_access(c.depot_id, 'view_compilation')
       and not exists(select 1 from public.rc_bad_debt_remarks b where b.customer_id = c.customer_id and b.status = 'active')),
  baru as (
    insert into public.rc_clearing_offers(claim_id, upload_id, result, reason, offered_at, offered_by, deadline_at, status)
    select k.id, k.upload_id, 'REOFFER', jsonb_build_object('tawarUlang', true, 'alasanKembaliSebelumnya', k.return_reason),
           now(), auth.uid(), ((v_hari + 7)::timestamp + time '23:59:59') at time zone 'Asia/Jakarta', 'offered'
      from kandidat k
    on conflict (claim_id) where status in ('offered','overdue') do nothing
    returning claim_id),
  h as (
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    select b.claim_id, auth.uid(), 'not_yet', 'not_yet', 'zdage_reoffer', 'Toko lunas ditawarkan ulang. Batas proses ' || to_char(v_hari + 7, 'DD-Mon-YYYY') || '.'
      from baru b returning claim_id)
  select count(*) into n from baru;

  if n > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'zdage_reoffer', jsonb_build_object('detail', 'Tawarkan ulang toko lunas: ' || n || ' dokumen', 'jumlah', n),
      'compilation', 'debtor', 'debtor');
  end if;
  return jsonb_build_object('status', 'success', 'berhasil', n,
    'message', n || ' dokumen ditawarkan ulang, batas proses ' || to_char(v_hari + 7, 'DD-Mon-YYYY') || '.');
end $f$;

-- Dokumen yang tawarannya dikembalikan depot (bahan Tawarkan Ulang).
create or replace function public.rc_clearing_dikembalikan()
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  perform rc_private.require_tab('compilation.debtor');
  return jsonb_build_object('status', 'success', 'rows', coalesce((select jsonb_agg(jsonb_build_object(
      'noDoc', c.no_doc, 'kodeDepot', d.depot_code, 'kodeToko', coalesce(cu.customer_code, ''), 'namaToko', coalesce(cu.customer_name, ''),
      'kodeCampaign', ca.campaign_code, 'namaCampaign', ca.campaign_name, 'netCb', c.cb_net,
      'alasan', coalesce(akhir.return_reason, ''), 'oleh', coalesce(p.full_name, p.user_code, ''),
      'waktu', to_char(akhir.acted_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI')) order by akhir.acted_at desc)
    from public.claims c
    join lateral (select o.status, o.return_reason, o.acted_at, o.acted_by from public.rc_clearing_offers o
                   where o.claim_id = c.id order by o.created_at desc limit 1) akhir on akhir.status = 'returned'
    join public.depots d on d.id = c.depot_id
    join public.campaigns ca on ca.id = c.campaign_id
    left join public.customers cu on cu.id = c.customer_id
    left join public.profiles p on p.id = akhir.acted_by
   where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
     and rc_private.can_access(c.depot_id, 'view_compilation')), '[]'::jsonb));
end $f$;

-- Tawaran mengikuti klaimnya: diajukan -> processed; On Hold / Expired / arsip -> cancelled.
create or replace function rc_private.zdage_tawaran_ikut_klaim() returns trigger
language plpgsql security definer set search_path = '' as $f$
begin
  if not exists(select 1 from public.rc_clearing_offers where claim_id = new.id and status in ('offered','overdue')) then
    return null; end if;
  if new.archived_at is null and new.status in ('submitted','approved','released','claimed','done','bulk_processed') then
    update public.rc_clearing_offers set status = 'processed', acted_by = auth.uid(), acted_at = now()
     where claim_id = new.id and status in ('offered','overdue');
  else
    update public.rc_clearing_offers set status = 'cancelled', acted_by = auth.uid(), acted_at = now()
     where claim_id = new.id and status in ('offered','overdue');
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    values (new.id, auth.uid(), new.status, new.status, 'zdage_cancel',
      'Tawaran toko lunas dibatalkan: dokumen ' || case when new.archived_at is not null then 'diarsipkan'
        else rc_private.legacy_status(new.status) end);
  end if;
  return null;
end $f$;
revoke all on function rc_private.zdage_tawaran_ikut_klaim() from public, anon, authenticated;

drop trigger if exists zdage_tawaran_ikut_klaim on public.claims;
create trigger zdage_tawaran_ikut_klaim after update of status, archived_at on public.claims
  for each row when ((old.status = 'not_yet' and new.status is distinct from old.status)
                     or (old.archived_at is null and new.archived_at is not null))
  execute function rc_private.zdage_tawaran_ikut_klaim();

-- ------------------------------------------------------------------------------------------
-- 7. Bad Debt per toko (tab Open) dan saklar approval-nya (tab Approval On/Off)
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_bad_debt_set(p_no_docs text[], p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare v_alasan text := left(btrim(coalesce(p_reason, '')), 300); v_docs text[]; v_cust uuid[]; v_tolak text[];
  n_baru integer; n_batal integer; v_kode text;
begin
  perform rc_private.require_tab('upload.baddebt');
  if length(v_alasan) < 3 then raise exception 'Alasan Bad Debt wajib diisi'; end if;
  v_docs := array(select distinct upper(btrim(x)) from unnest(coalesce(p_no_docs, '{}')) x where btrim(x) <> '');
  if coalesce(array_length(v_docs, 1), 0) = 0 then raise exception 'Pilih dokumen lebih dulu'; end if;

  select array_agg(distinct c.customer_id) into v_cust from public.claims c
   where upper(c.no_doc) = any(v_docs) and c.customer_id is not null and rc_private.can_access(c.depot_id, 'upload_claim');
  v_tolak := array(select d from unnest(v_docs) d where not exists(select 1 from public.claims c where upper(c.no_doc) = d
                   and c.customer_id is not null and rc_private.can_access(c.depot_id, 'upload_claim')));
  if coalesce(array_length(v_cust, 1), 0) = 0 then
    raise exception 'Tidak ada dokumen yang dapat ditandai (tidak ditemukan, di luar jangkauan, atau tanpa Customer Master)'; end if;

  with b as (insert into public.rc_bad_debt_remarks(customer_id, reason, created_by)
             select x, v_alasan, auth.uid() from unnest(v_cust) x
             on conflict (customer_id) where status = 'active' do nothing returning customer_id)
  select count(*) into n_baru from b;

  with t as (update public.rc_clearing_offers o set status = 'cancelled', acted_by = auth.uid(), acted_at = now()
               from public.claims c
              where c.id = o.claim_id and c.customer_id = any(v_cust) and o.status in ('offered','overdue')
             returning o.claim_id),
       h as (insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
             select t.claim_id, auth.uid(), 'not_yet', 'not_yet', 'zdage_cancel',
                    left('Tawaran toko lunas dibatalkan: toko ditandai Bad Debt. Alasan: ' || v_alasan, 300) from t returning claim_id)
  select count(*) into n_batal from t;

  select string_agg(cu.customer_code, ', ' order by cu.customer_code) into v_kode from public.customers cu where cu.id = any(v_cust);
  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), 'bad_debt_set', jsonb_build_object('detail', 'Tandai Bad Debt: ' || array_length(v_cust, 1) || ' toko (' || left(v_kode, 400) || ')',
    'toko', array_length(v_cust, 1), 'baru', n_baru, 'tawaranDibatalkan', n_batal, 'alasan', v_alasan), 'upload', 'open', 'open');
  return jsonb_build_object('status', 'success', 'toko', array_length(v_cust, 1), 'baru', n_baru, 'tawaranDibatalkan', n_batal,
    'ditolak', to_jsonb(v_tolak),
    'message', array_length(v_cust, 1) || ' toko ditandai Bad Debt' || case when n_batal > 0 then '; ' || n_batal || ' tawaran toko lunas dibatalkan' else '' end || '.');
end $f$;

create or replace function public.rc_bad_debt_revoke(p_no_docs text[], p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare v_alasan text := left(btrim(coalesce(p_reason, '')), 300); v_docs text[]; n integer;
begin
  perform rc_private.require_tab('upload.baddebt');
  if length(v_alasan) < 3 then raise exception 'Alasan mencabut Bad Debt wajib diisi'; end if;
  v_docs := array(select distinct upper(btrim(x)) from unnest(coalesce(p_no_docs, '{}')) x where btrim(x) <> '');
  if coalesce(array_length(v_docs, 1), 0) = 0 then raise exception 'Pilih dokumen lebih dulu'; end if;
  with t as (update public.rc_bad_debt_remarks b set status = 'revoked', revoked_by = auth.uid(), revoked_at = now(),
                    revoke_reason = v_alasan, updated_at = now()
              where b.status = 'active' and b.customer_id in (select c.customer_id from public.claims c
                     where upper(c.no_doc) = any(v_docs) and rc_private.can_access(c.depot_id, 'upload_claim'))
             returning b.customer_id)
  select count(*) into n from t;
  if n > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'bad_debt_revoke', jsonb_build_object('detail', 'Cabut Bad Debt: ' || n || ' toko', 'toko', n, 'alasan', v_alasan),
      'upload', 'open', 'open');
  end if;
  return jsonb_build_object('status', 'success', 'toko', n,
    'message', case when n = 0 then 'Tidak ada toko Bad Debt pada dokumen yang dipilih.' else n || ' toko dicabut dari Bad Debt.' end);
end $f$;

create or replace function public.rc_bad_debt_approval_setelan()
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare s public.pengaturan_sistem;
begin
  perform rc_private.require_tab('access.approval');
  select * into s from public.pengaturan_sistem where kunci = 'approval_bad_debt';
  return jsonb_build_object('status', 'success', 'aktif', rc_private.approval_bad_debt_aktif(),
    'diubahPada', case when s.diubah_oleh is null then '' else to_char(s.diubah_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI:SS') end,
    'diubahOleh', coalesce((select full_name || ' (' || user_code || ')' from public.profiles where id = s.diubah_oleh), ''),
    'catatan', case when s.diubah_oleh is null then '' else coalesce(s.catatan, '') end,
    'menunggu', (select count(*) from public.claims where archived_at is null and pending_approval->>'kind' = 'submit'
                  and pending_approval->>'bad_debt' = 'true'),
    'riwayat', coalesce((select jsonb_agg(jsonb_build_object(
        'waktu', to_char(a.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
        'oleh', coalesce((select full_name from public.profiles where id = a.actor_id), ''),
        'aksi', case when a.event_type = 'approval_bad_debt_dimatikan' then 'Dimatikan' else 'Dihidupkan' end,
        'catatan', coalesce(a.details->>'catatan', '')) order by a.created_at desc)
      from (select * from public.activity_logs where event_type in ('approval_bad_debt_dimatikan','approval_bad_debt_dihidupkan')
             order by created_at desc limit 10) a), '[]'::jsonb));
end $f$;

create or replace function public.rc_bad_debt_approval_setel(p_aktif boolean, p_catatan text)
returns jsonb language plpgsql security definer set search_path = '' as $f$
begin
  perform rc_private.require_tab('access.approval');
  if p_aktif is null then raise exception 'Pilihan wajib diisi'; end if;
  if length(btrim(coalesce(p_catatan, ''))) < 3 then raise exception 'Alasan wajib diisi'; end if;
  if rc_private.approval_bad_debt_aktif() = p_aktif then
    return jsonb_build_object('status', 'success', 'aktif', p_aktif,
      'message', case when p_aktif then 'Approval Bad Debt sudah aktif.' else 'Approval Bad Debt sudah mati.' end); end if;
  insert into public.pengaturan_sistem(kunci, nilai, catatan, diubah_oleh, diubah_pada)
  values ('approval_bad_debt', to_jsonb(p_aktif), left(btrim(p_catatan), 300), auth.uid(), now())
  on conflict (kunci) do update set nilai = excluded.nilai, catatan = excluded.catatan,
    diubah_oleh = excluded.diubah_oleh, diubah_pada = excluded.diubah_pada;
  insert into public.activity_logs(actor_id, event_type, details)
  values (auth.uid(), case when p_aktif then 'approval_bad_debt_dihidupkan' else 'approval_bad_debt_dimatikan' end,
    jsonb_build_object('catatan', left(btrim(p_catatan), 300)));
  return jsonb_build_object('status', 'success', 'aktif', p_aktif,
    'message', case when p_aktif then 'Approval Bad Debt dihidupkan: pengajuan toko Bad Debt menunggu approval di tab Bad Debt.'
                    else 'Approval Bad Debt dimatikan: pengajuan toko Bad Debt langsung berjalan seperti pengajuan lain.' end);
end $f$;

-- Antrean tab Bad Debt di Management of Approval.
create or replace function public.rc_approval_bad_debt(p_depot text default '', p_search text default '')
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare v_cari text := btrim(coalesce(p_search, ''));
begin
  perform rc_private.require_tab('approval.baddebt');
  return jsonb_build_object('status', 'success', 'rows', coalesce((select jsonb_agg(jsonb_build_object(
      'noDoc', c.no_doc, 'versionNo', c.version_no, 'kodeDepot', d.depot_code, 'namaDepot', d.depot_name,
      'kodeToko', cu.customer_code, 'namaToko', cu.customer_name, 'kodeCampaign', ca.campaign_code, 'namaCampaign', ca.campaign_name,
      'jenisCb', rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)),
      'netCb', c.cb_net, 'batch', coalesce(c.batch_upload, ''),
      'alasanBadDebt', coalesce(b.reason, ''), 'ditandaiOleh', coalesce(pb.full_name, pb.user_code, ''),
      'diajukanOleh', coalesce(p.full_name, p.user_code, ''),
      'diajukanPada', to_char(coalesce((c.pending_approval->>'requested_at')::timestamptz, c.uploaded_at) at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'))
      order by d.depot_code, c.no_doc)
    from public.claims c
    join public.depots d on d.id = c.depot_id
    join public.campaigns ca on ca.id = c.campaign_id
    join public.customers cu on cu.id = c.customer_id
    left join public.rc_bad_debt_remarks b on b.id = coalesce((c.pending_approval->>'bad_debt_id')::uuid, c.bad_debt_remark_id)
    left join public.profiles pb on pb.id = b.created_by
    left join public.profiles p on p.id = (c.pending_approval->>'requested_by')::uuid
   where c.archived_at is null and c.status = 'submitted' and c.pending_approval->>'kind' = 'submit'
     and c.pending_approval->>'bad_debt' = 'true' and rc_private.can_access(c.depot_id, 'approve_claim')
     and (coalesce(btrim(p_depot), '') = '' or d.depot_code = btrim(p_depot))
     and (v_cari = '' or c.no_doc ilike '%' || v_cari || '%' or cu.customer_code ilike '%' || v_cari || '%'
          or cu.customer_name ilike '%' || v_cari || '%')), '[]'::jsonb));
end $f$;

-- Remark Bad Debt di email pengajuan (daftar toko Bad Debt di antara dokumen email itu).
create or replace function rc_private.email_remark_bad_debt(p_ids uuid[]) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare v text;
begin
  select string_agg(rc_private.html_aman(z.kode || ' - ' || z.nama) || ' (' || z.n || ' dokumen, ' || rc_private.rupiah(z.cb) || ')', '<br>' order by z.kode)
    into v
    from (select cu.customer_code kode, cu.customer_name nama, count(*) n, coalesce(sum(c.cb_net), 0) cb
            from public.claims c join public.customers cu on cu.id = c.customer_id
           where c.id = any(p_ids) and c.bad_debt_remark_id is not null
           group by cu.customer_code, cu.customer_name) z;
  if v is null then return ''; end if;
  return '<p style="line-height:1.6;background:#fdecef;border-left:4px solid #C8102E;padding:10px 12px;margin:12px 0;font-size:12px;color:#8a0d20;">'
    || '<strong>Remark: Bad Debt</strong><br>' || v || '</p>';
end $f$;

revoke all on function rc_private.email_remark_bad_debt(uuid[]) from public, anon, authenticated;

-- Tab Restricted: klaim Not Yet yang tidak boleh tampil di Open, beserta alasannya. Fungsi
-- invoker (di bawah RLS pemanggil), sama dengan tab Open.
create or replace function public.rc_restricted_claims(p_search text default '', p_campaign text default '',
  p_offset integer default 0, p_limit integer default 200, p_cb_type text default '')
returns jsonb language plpgsql stable set search_path = '' as $f$
declare v jsonb; jml bigint; v_opsi jsonb; v_cari text := btrim(coalesce(p_search, ''));
begin
  perform rc_private.require_tab('upload.restricted');
  if not rc_private.can_access(null, 'upload_claim') then raise exception 'Access denied' using errcode = '42501'; end if;

  select count(*) into jml from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
    left join public.customers cu on cu.id = c.customer_id
   where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
     and not rc_private.boleh_open(c.id, c.customer_id)
     and (coalesce(btrim(p_cb_type), '') = '' or rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) = rc_private.jenis_efektif(p_cb_type))
     and (coalesce(btrim(p_campaign), '') = '' or ca.campaign_code = btrim(p_campaign))
     and (v_cari = '' or c.no_doc ilike '%' || v_cari || '%' or coalesce(cu.customer_code, c.source_customer_code) ilike '%' || v_cari || '%'
          or coalesce(cu.customer_name, '') ilike '%' || v_cari || '%');

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v from (
    select jsonb_build_object(
      'noDoc', c.no_doc, 'kodeToko', coalesce(cu.customer_code, c.source_customer_code), 'namaToko', coalesce(cu.customer_name, 'Customer Master belum ada'),
      'codeCampaign', ca.campaign_code, 'campaignName', ca.campaign_name,
      'jenisCb', rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)),
      'cbNet', c.cb_net, 'dcCode', d.depot_code, 'depotName', d.depot_name,
      'ktp', coalesce(cu.ktp, ''), 'npwp', coalesce(cu.npwp, ''), 'noRek', coalesce(cu.account_number, ''), 'namaRek', coalesce(cu.account_name, ''),
      'bank', coalesce(cu.bank, ''), 'top', coalesce(cu.top_text, ''), 'contactPerson', coalesce(cu.contact_person, ''),
      'createdOn', to_char(c.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY'),
      'soStart', rc_private.legacy_date(coalesce(c.extend_so_start, ca.so_start)),
      'billingEnd', rc_private.legacy_date(coalesce(c.extend_billing_end, ca.billing_end, ca.so_end)),
      'versionNo', c.version_no,
      'alasan', ri.label, 'alasanRinci', ri.rinci,
      'dinilai', case when ri.dinilai is null then '' else to_char(ri.dinilai at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') end,
      'badDebt', ri.label = 'Bad Debt', 'badDebtAlasan', coalesce(ri.rinci->>'badDebt', '')) x
      from public.claims c
      join public.campaigns ca on ca.id = c.campaign_id
      left join public.customers cu on cu.id = c.customer_id
      join public.depots d on d.id = c.depot_id
      left join lateral rc_private.restricted_info(c.id, c.customer_id, c.depot_id) ri on true
     where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
       and not rc_private.boleh_open(c.id, c.customer_id)
       and (coalesce(btrim(p_cb_type), '') = '' or rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) = rc_private.jenis_efektif(p_cb_type))
       and (coalesce(btrim(p_campaign), '') = '' or ca.campaign_code = btrim(p_campaign))
       and (v_cari = '' or c.no_doc ilike '%' || v_cari || '%' or coalesce(cu.customer_code, c.source_customer_code) ilike '%' || v_cari || '%'
            or coalesce(cu.customer_name, '') ilike '%' || v_cari || '%')
     order by ca.campaign_code, c.no_doc
     limit least(greatest(coalesce(p_limit, 200), 1), 500) offset greatest(coalesce(p_offset, 0), 0)) t;

  if coalesce(p_offset, 0) = 0 then
    select jsonb_build_object(
      'campaigns', coalesce((select jsonb_agg(jsonb_build_object('kode', k.campaign_code, 'nama', k.campaign_name) order by k.campaign_code)
         from (select distinct ca.campaign_code, ca.campaign_name from public.claims c join public.campaigns ca on ca.id = c.campaign_id
                where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
                  and not rc_private.boleh_open(c.id, c.customer_id)) k), '[]'::jsonb),
      'jenisCb', coalesce((select jsonb_agg(j.label order by j.label)
         from (select distinct rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) label
                 from public.claims c join public.campaigns ca on ca.id = c.campaign_id
                where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
                  and not rc_private.boleh_open(c.id, c.customer_id)) j where coalesce(j.label, '') <> ''), '[]'::jsonb),
      'bolehPindah', rc_private.can_tab('upload.restrictedEdit'), 'bolehBadDebt', rc_private.can_tab('upload.baddebt'))
      into v_opsi;
  end if;
  return jsonb_build_object('status', 'success', 'rows', v, 'total', jml)
         || case when v_opsi is null then '{}'::jsonb else jsonb_build_object('opsi', v_opsi) end;
end $f$;

-- Editor Restricted memindahkan klaim ke Open (berlabel Restricted, boleh diajukan, tanpa batas proses).
create or replace function public.rc_restricted_pindah(p_no_docs text[], p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare v_alasan text := left(btrim(coalesce(p_reason, '')), 300); v_docs text[]; n integer; v_gagal text[];
begin
  perform rc_private.require_tab('upload.restrictedEdit');
  if length(v_alasan) < 3 then raise exception 'Alasan memindahkan ke Open wajib diisi'; end if;
  v_docs := array(select distinct upper(btrim(x)) from unnest(coalesce(p_no_docs, '{}')) x where btrim(x) <> '');
  if coalesce(array_length(v_docs, 1), 0) = 0 then raise exception 'Pilih dokumen lebih dulu'; end if;
  if array_length(v_docs, 1) > 500 then raise exception 'Maksimal 500 dokumen sekali proses'; end if;

  with kandidat as (
    select c.id, c.no_doc from public.claims c
     where upper(c.no_doc) = any(v_docs) and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
       and c.customer_id is not null and rc_private.can_access(c.depot_id, 'upload_claim')
       and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = c.id and o.status in ('offered','overdue'))),
  baru as (
    insert into public.rc_clearing_offers(claim_id, upload_id, result, reason, offered_at, offered_by, deadline_at, status)
    select k.id, null, 'RESTRICTED', jsonb_build_object('alasanPindah', v_alasan), now(), auth.uid(), null, 'offered'
      from kandidat k
    on conflict (claim_id) where status in ('offered','overdue') do nothing
    returning claim_id),
  h as (
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    select b.claim_id, auth.uid(), 'not_yet', 'not_yet', 'restricted_open', left('Dipindah dari Restricted ke Open: ' || v_alasan, 300)
      from baru b returning claim_id)
  select count(*), array(select d from unnest(v_docs) d where d not in (select upper(k2.no_doc) from kandidat k2 join baru b2 on b2.claim_id = k2.id))
    into n, v_gagal from baru;

  if n > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'restricted_open', jsonb_build_object('detail', 'Pindah Restricted ke Open: ' || n || ' dokumen', 'jumlah', n, 'alasan', v_alasan),
      'upload', 'restricted', 'restricted');
  end if;
  return jsonb_build_object('status', 'success', 'berhasil', n, 'gagal', to_jsonb(v_gagal),
    'message', n || ' dokumen dipindah ke Open (berlabel Restricted)'
      || case when coalesce(array_length(v_gagal, 1), 0) > 0 then '; ' || array_length(v_gagal, 1) || ' dokumen tidak dapat dipindah' else '' end || '.');
end $f$;

-- ------------------------------------------------------------------------------------------
-- 8. Email peringatan harian + job 07:00 WIB
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.zdage_email_peringatan(p_paksa boolean default false) returns integer
language plpgsql security definer set search_path = '' as $f$
declare v_aktif boolean; v_uji boolean; v_alamat text; v_tam text[]; v_jenis text[]; v_dep record; v_r record;
  v_to text[]; v_cc text[]; v_baris text; v_toko integer; v_cb numeric; v_html text; v_subjek text; v_spanduk text; n integer := 0;
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
begin
  select aktif, mode_uji, btrim(coalesce(email_uji, '')), coalesce(cc_tambahan, '{}'),
         array(select jsonb_array_elements_text(coalesce(cc_per_jenis->'debtor', '[]'::jsonb)))
    into v_aktif, v_uji, v_alamat, v_tam, v_jenis
    from public.email_settings where jenis = 'pengajuan';
  if not coalesce(v_aktif, false) then return 0; end if;
  v_uji := coalesce(v_uji, false) and coalesce(v_alamat, '') <> '';

  for v_dep in
    select d.id, d.depot_code, coalesce(nullif(d.depot_name, ''), d.depot_code) nama, d.email_to, d.email_cc
      from public.depots d
     where exists(select 1 from public.rc_clearing_offers o join public.claims c on c.id = o.claim_id
                   where o.status = 'overdue' and c.depot_id = d.id and c.status = 'not_yet'
                     and c.pending_approval is null and c.archived_at is null)
     order by d.depot_code
  loop
    -- Sekali sehari per depot.
    if not p_paksa and exists(select 1 from public.email_outbox o where o.konteks->>'aksi' = 'debtor_warning'
         and o.konteks->>'depot' = v_dep.id::text
         and o.dibuat_pada >= (date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta')) then
      continue; end if;

    v_to := array(select distinct lower(btrim(x)) from unnest(rc_private.pecah_email(v_dep.email_to)) x where btrim(x) like '%@%');
    v_cc := array(select distinct a from (
              select lower(btrim(x)) a from unnest(rc_private.pecah_email(v_dep.email_cc)) x
              union all select lower(btrim(y)) from unnest(v_tam) y
              union all select lower(btrim(z)) from unnest(v_jenis) z) s
            where a like '%@%' and not (a = any(v_to)));
    if coalesce(array_length(v_to, 1), 0) = 0 and not v_uji then
      insert into public.activity_logs(actor_id, depot_id, event_type, details)
      values (null, v_dep.id, 'email_pengajuan_tanpa_tujuan',
        jsonb_build_object('aksi', 'debtor_warning', 'sebab', 'Alamat email depot belum diisi di Depot Master'));
      continue;
    end if;

    v_baris := ''; v_toko := 0; v_cb := 0;
    for v_r in
      select coalesce(ca.campaign_name, ca.campaign_code, '(tanpa campaign)') campaign,
             count(distinct c.customer_id) toko, coalesce(sum(c.cb_net), 0) cb
        from public.rc_clearing_offers o join public.claims c on c.id = o.claim_id
        left join public.campaigns ca on ca.id = c.campaign_id
       where o.status = 'overdue' and c.depot_id = v_dep.id and c.status = 'not_yet'
         and c.pending_approval is null and c.archived_at is null
       group by 1 order by 3 desc, 1
    loop
      v_toko := v_toko + v_r.toko; v_cb := v_cb + v_r.cb;
      v_baris := v_baris || '<tr><td style="' || v_td || '">' || rc_private.html_aman(v_r.campaign) || '</td>'
        || '<td style="' || v_td || 'text-align:right;">' || v_r.toko::text || '</td>'
        || '<td style="' || v_td || 'text-align:right;white-space:nowrap;">' || rc_private.rupiah(v_r.cb) || '</td></tr>';
    end loop;

    v_subjek := '[RC] Warning – Toko lunas belum diproses – ' || v_dep.nama;
    v_html := rc_private.email_kepala('Warning – Toko lunas belum diproses', 'Depo ' || v_dep.nama || '  |  ' || v_toko::text || ' toko')
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
      || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;">'
      || '<p style="line-height:1.6;margin-top:0;">Dear All,</p>'
      || '<p style="line-height:1.6;">Berikut toko di Depo <strong>' || rc_private.html_aman(v_dep.depot_code || ' - ' || v_dep.nama)
      || '</strong> yang sudah lunas menurut data debtor (ZDAGE) dan sudah melewati batas waktu proses, tetapi klaimnya belum diproses di Claim Upload.</p>'
      || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin-top:12px;">'
      || '<thead><tr style="background:#f5f6f7;">'
      || '<th align="left" style="' || v_th || '">NAMA CAMPAIGN</th><th align="right" style="' || v_th || '">JUMLAH TOKO</th>'
      || '<th align="right" style="' || v_th || '">TOTAL NET CB (RP)</th></tr></thead><tbody>' || v_baris || '</tbody>'
      || '<tfoot><tr style="background:#fdecef;">'
      || '<td style="padding:10px;font-size:12px;font-weight:bold;color:#C8102E;">TOTAL</td>'
      || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;">' || v_toko::text || '</td>'
      || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;white-space:nowrap;">' || rc_private.rupiah(v_cb) || '</td>'
      || '</tr></tfoot></table>'
      || '<p style="line-height:1.6;margin-top:16px;">Mohon management segera mendorong tim depo untuk memproses semua toko-toko yang sudah lunas di atas segera agar tidak ada complaint dari toko dan meningkatkan performance sales toko yang bersangkutan.</p>'
      || rc_private.email_ttd()
      || '</td></tr></table>';

    v_spanduk := '';
    if v_uji then
      v_spanduk := '<div style="font-family:Arial,Helvetica,sans-serif;background:#1f2937;color:#ffffff;'
        || 'padding:12px 16px;border-radius:8px;margin-bottom:12px;max-width:640px;">'
        || '<div style="font-size:13px;font-weight:bold;margin-bottom:6px;">MODE UJI &mdash; surat ini TIDAK dikirim ke depot</div>'
        || '<div style="font-size:11px;line-height:1.7;color:#d1d5db;">Seharusnya dikirim ke<br>'
        || '<strong style="color:#ffffff;">TO</strong> (' || coalesce(array_length(v_to, 1), 0)::text || '): '
        || rc_private.html_aman(coalesce(nullif(array_to_string(v_to, ', '), ''), 'BELUM ADA ALAMAT DEPOT DI DEPOT MASTER')) || '<br>'
        || '<strong style="color:#ffffff;">CC</strong> (' || coalesce(array_length(v_cc, 1), 0)::text || '): '
        || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc, ', '), ''), 'tidak ada')) || '</div></div>';
      v_subjek := '[UJI] ' || v_subjek;
    end if;

    insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, konteks)
    values ('pengajuan', case when v_uji then array[v_alamat] else v_to end, case when v_uji then '{}'::text[] else v_cc end,
      v_subjek, rc_private.email_outlook(v_spanduk || v_html),
      jsonb_build_object('aksi', 'debtor_warning', 'kategori', 'debtor', 'depot', v_dep.id, 'qty', v_toko, 'modeUji', v_uji));
    n := n + 1;
  end loop;
  return n;
end $f$;

create or replace function rc_private.zdage_harian() returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare n integer; v_email integer := 0;
begin
  with t as (
    update public.rc_clearing_offers o set status = 'overdue'
      from public.claims c
     where c.id = o.claim_id and o.status = 'offered' and o.deadline_at < now() and o.result in ('LUNAS','REOFFER')
       and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
    returning o.claim_id, o.deadline_at),
  h as (
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    select t.claim_id, null, 'not_yet', 'not_yet', 'zdage_overdue',
           'Toko lunas belum diproses sampai batas ' || to_char(t.deadline_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY')
      from t returning claim_id)
  select count(*) into n from t;
  if n > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (null, 'zdage_overdue', jsonb_build_object('detail', n || ' tawaran toko lunas melewati batas waktu proses', 'jumlah', n),
      'compilation', 'debtor', 'debtor');
  end if;
  begin
    v_email := rc_private.zdage_email_peringatan(false);
  exception when others then
    insert into public.activity_logs(actor_id, event_type, details)
    values (null, 'email_pengajuan_gagal', jsonb_build_object('aksi', 'debtor_warning', 'sebab', left(sqlerrm, 300)));
  end;
  return jsonb_build_object('overdue', n, 'email', v_email);
end $f$;
revoke all on function rc_private.zdage_email_peringatan(boolean), rc_private.zdage_harian() from public, anon, authenticated;

do $cron$
begin
  if exists(select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'rc_zdage_harian';
    perform cron.schedule('rc_zdage_harian', '0 0 * * *', 'select rc_private.zdage_harian()');  -- 07:00 WIB
  end if;
end $cron$;

-- ------------------------------------------------------------------------------------------
-- 9. Hak eksekusi RPC
-- ------------------------------------------------------------------------------------------
revoke all on function public.rc_zdage_stage(text, timestamptz, jsonb, uuid), public.rc_zdage_preview(uuid, text[]),
  public.rc_zdage_apply(uuid, text[]), public.rc_zdage_discard(uuid), public.rc_zdage_riwayat(),
  public.rc_clearing_return(text[], text), public.rc_clearing_reoffer(text[]), public.rc_clearing_dikembalikan(),
  public.rc_bad_debt_set(text[], text), public.rc_bad_debt_revoke(text[], text),
  public.rc_bad_debt_approval_setelan(), public.rc_bad_debt_approval_setel(boolean, text),
  public.rc_approval_bad_debt(text, text), public.rc_restricted_claims(text, text, integer, integer, text),
  public.rc_restricted_pindah(text[], text) from public, anon;
grant execute on function public.rc_zdage_stage(text, timestamptz, jsonb, uuid), public.rc_zdage_preview(uuid, text[]),
  public.rc_zdage_apply(uuid, text[]), public.rc_zdage_discard(uuid), public.rc_zdage_riwayat(),
  public.rc_clearing_return(text[], text), public.rc_clearing_reoffer(text[]), public.rc_clearing_dikembalikan(),
  public.rc_bad_debt_set(text[], text), public.rc_bad_debt_revoke(text[], text),
  public.rc_bad_debt_approval_setelan(), public.rc_bad_debt_approval_setel(boolean, text),
  public.rc_approval_bad_debt(text, text), public.rc_restricted_claims(text, text, integer, integer, text),
  public.rc_restricted_pindah(text[], text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 10. Katalog tab (opt-in) dan tambalan fungsi yang ada
-- ------------------------------------------------------------------------------------------
insert into rc_private.tab_catalog(code, module, tab, permission, title, label, key)
select 'compilation.debtor', t.module, 'debtor', t.permission, 'Upload Debtor', t.label, t.key
  from rc_private.tab_catalog t where t.code = 'compilation.list'
   and not exists(select 1 from rc_private.tab_catalog where code = 'compilation.debtor');
insert into rc_private.tab_catalog(code, module, tab, permission, title, label, key)
select x.code, t.module, x.tab, t.permission, x.title, t.label, t.key
  from rc_private.tab_catalog t
  cross join (values ('upload.restricted', 'restricted', 'Restricted'),
                     ('upload.restrictedEdit', 'restrictedEdit', 'Restricted (Editor)'),
                     ('upload.baddebt', 'baddebt', 'Bad Debt (Tandai)')) x(code, tab, title)
 where t.code = 'upload.open' and not exists(select 1 from rc_private.tab_catalog c where c.code = x.code);
insert into rc_private.tab_catalog(code, module, tab, permission, title, label, key)
select 'approval.baddebt', t.module, 'baddebt', t.permission, 'Bad Debt', t.label, t.key
  from rc_private.tab_catalog t where t.code = 'approval.hold'
   and not exists(select 1 from rc_private.tab_catalog where code = 'approval.baddebt');

do $tambal$
declare src text; f record;
begin
  for f in select * from (values
    ('rc_private.tab_rights(uuid)', '503f50a8170ee9b5f90b7ba6bb5c6c6a'),
    ('public.rc_open_claims_filtered(text,text,integer,integer,text)', 'a203da3d57cfaf12e783f81d8c5d5a45'),
    ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', 'c718981d171e4d148a6c2cc5894125ca'),
    ('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)', '99e6b8ff8c16fd4f480829a0dc23ee5b'),
    ('public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text,jsonb)', '54a92dc5b89c9ca4b7877be96c93cd0a'),
    ('public.rc_customer_list(text,integer,integer)', '7f7b8692b3aa87a4280455e965351b43'),
    ('public.rc_posting_exception(text,jsonb,text)', 'f374d3fdfbd0b64e677c3e6f6e0cda1e'),
    ('rc_private.legacy_documents(text[])', '2ea506685a3276608d1b48b99d8b0fdd')) x(sig, harapan)
  loop
    src := replace(pg_get_functiondef(f.sig::regprocedure), E'\r', '');
    if src ~ '20261163170000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(src) <> f.harapan then raise exception 'DITOLAK: % berbeda dari yang diukur (md5 %).', f.sig, md5(src); end if;

    if f.sig = 'rc_private.tab_rights(uuid)' then
      src := pg_temp.ganti(src, $p$or t.code='compilation.amend' /* 20261163140000: hanya bila dicentang */$p$,
        $p$or t.code='compilation.amend' /* 20261163140000: hanya bila dicentang */ or t.code in ('compilation.debtor','approval.baddebt','upload.restrictedEdit','upload.baddebt') /* 20261163170000: hanya bila dicentang */$p$, 1, 'tab_rights');

    elsif f.sig like 'public.rc_open_claims_filtered%' then
      src := pg_temp.ganti(src, $p$'billingEnd',rc_private.legacy_date(coalesce(c.extend_billing_end,ca.billing_end,ca.so_end,ca.period_end))) as x$p$,
        $p$'billingEnd',rc_private.legacy_date(coalesce(c.extend_billing_end,ca.billing_end,ca.so_end,ca.period_end)),
   -- 20261163170000: Upload Debtor - tawaran toko lunas, Bad Debt, dan Tgl Lunas dari ZDAGE.
   'tglLunas',rc_private.legacy_date(c.paid_on),'tglLunasIsi',coalesce(to_char(c.paid_on,'DD-MM-YYYY'),''),
   'offerStatus',coalesce(di.offer_status,''),'sisaHari',di.sisa_hari,
   'deadline',case when di.deadline_at is null then '' else to_char(di.deadline_at at time zone 'Asia/Jakarta','DD-Mon-YYYY') end,
   'offerAlasan',di.reason,'offerJenis',coalesce(di.offer_result,''),'restricted',coalesce(di.offer_result,'')='RESTRICTED',
   'badDebt',coalesce(di.bad_debt,false),'badDebtAlasan',coalesce(di.bad_debt_reason,'')) as x$p$, 1, 'open select');
      -- Hanya klaim lunas (tawaran aktif) atau toko Bad Debt saat Approval Bad Debt menyala.
      src := pg_temp.ganti(src, $p$where c.status='not_yet' and c.pending_approval is null and c.archived_at is null$p$,
        $p$where c.status='not_yet' and c.pending_approval is null and c.archived_at is null and rc_private.boleh_open(c.id,c.customer_id) /* 20261163170000 */$p$, 4, 'open hanya lunas');
      src := pg_temp.ganti(src, $p$left join public.profiles p on p.id=c.created_by$p$,
        $p$left join public.profiles p on p.id=c.created_by
  left join lateral rc_private.debtor_info(c.id,c.customer_id) di on true$p$, 1, 'open join');
      src := pg_temp.ganti(src, $p$order by ca.campaign_code,c.no_doc$p$,
        $p$order by coalesce(di.bad_debt,false),di.deadline_at nulls last,ca.campaign_code,c.no_doc /* 20261163170000: deadline terdekat di atas, Bad Debt paling bawah */$p$, 1, 'open order');

    elsif f.sig like 'rc_private.mutate_claims_unchecked%' then
      src := pg_temp.ganti(src, $p$ v_langsung boolean:=(p_action='submit' and not rc_private.approval_aktif());$p$,
        $p$ v_langsung boolean:=(p_action='submit' and not rc_private.approval_aktif());
 v_langsung_proses boolean:=(p_action='submit' and not rc_private.approval_aktif()); -- 20261163170000
 v_bd uuid; v_bd_tahan boolean:=false; v_mail_bd uuid[]:='{}';$p$, 1, 'mutate deklarasi');
      src := pg_temp.ganti(src, $p$  perform rc_private.require_tab(case when exists(select 1 from rc_private.approval_rows ar where$p$,
        $p$  perform rc_private.require_tab(case when c.pending_approval->>'bad_debt'='true' then 'approval.baddebt' /* 20261163170000 */ when exists(select 1 from rc_private.approval_rows ar where$p$, 1, 'mutate tab approve');
      src := pg_temp.ganti(src, $p$ target:=null;$p$,
        $p$ -- 20261163170000: toko Bad Debt. Saat Approval Bad Debt menyala, pengajuannya wajib di-approve
 -- di tab Bad Debt (Management of Approval) walaupun approval biasa dimatikan.
 v_bd:=null; v_bd_tahan:=false; v_langsung:=v_langsung_proses;
 if p_action='submit' then
  select r.id into v_bd from public.rc_bad_debt_remarks r where r.customer_id=c.customer_id and r.status='active';
  v_bd_tahan:=v_bd is not null and rc_private.approval_bad_debt_aktif();
  v_langsung:=v_langsung_proses and not v_bd_tahan;
  -- Hanya klaim yang tampil di Open (lunas, dipindah dari Restricted, atau Bad Debt dengan
  -- approval Bad Debt) yang dapat diajukan - dari jalur mana pun.
  if c.status='not_yet' and not rc_private.boleh_open(c.id,c.customer_id) then
   raise exception 'Dokumen % belum lunas (Restricted) dan tidak dapat diajukan. Minta pemegang akses Restricted (Editor) memindahkannya ke Open.',c.no_doc;
  end if;
 end if;
 target:=null;$p$, 1, 'mutate bad debt');
      src := pg_temp.ganti(src, $p$update public.claims set tax_subject=subject,gross_up=v_gross,$p$,
        $p$update public.claims set tax_subject=subject,gross_up=v_gross,bad_debt_remark_id=v_bd /* 20261163170000 */,$p$, 1, 'mutate tanda bad debt');
      src := pg_temp.ganti(src, $p$else 'approved' end)
   when p_action in('approve','reject_approval','approve_hold','reject_hold') then null else pending_approval end,$p$,
        $p$else 'approved' end)
       || case when v_bd_tahan then jsonb_build_object('bad_debt',true,'bad_debt_id',v_bd) else '{}'::jsonb end /* 20261163170000 */
   when p_action in('approve','reject_approval','approve_hold','reject_hold') then null else pending_approval end,$p$, 1, 'mutate pending bad debt');
      src := pg_temp.ganti(src, $p$v_mail_ids:=v_mail_ids||c.id;$p$,
        $p$v_mail_ids:=v_mail_ids||c.id; if v_bd_tahan then v_mail_bd:=v_mail_bd||c.id; end if; -- 20261163170000$p$, 1, 'mutate email bd');
      src := pg_temp.ganti(src, $p$  perform rc_private.email_pengajuan_antre(case when v_langsung then 'submit_langsung' else p_action end,batch,v_mail_ids,actor,p_reason);$p$,
        $p$  -- 20261163170000: approval dimatikan tetapi ada toko Bad Debt yang menunggu approval Bad Debt -
  -- dokumen lain tetap berangkat sebagai pengajuan langsung, yang tertahan sebagai pengajuan biasa.
  if v_langsung_proses and coalesce(array_length(v_mail_bd,1),0)>0 then
   perform rc_private.email_pengajuan_antre('submit_langsung',batch,array(select x from unnest(v_mail_ids) x where not (x=any(v_mail_bd))),actor,p_reason);
   perform rc_private.email_pengajuan_antre('submit',batch,v_mail_bd,actor,p_reason);
  else
   perform rc_private.email_pengajuan_antre(case when v_langsung_proses then 'submit_langsung' else p_action end,batch,v_mail_ids,actor,p_reason);
  end if;$p$, 1, 'mutate email');

    elsif f.sig like 'rc_private.email_pengajuan_html%' then
      src := pg_temp.ganti(src, $p$    || '</tr></tfoot></table>'$p$,
        $p$    || '</tr></tfoot></table>'
    || rc_private.email_remark_bad_debt(p_ids) /* 20261163170000 */$p$, 1, 'email remark');

    elsif f.sig like 'public.rc_email_pengajuan_simpan%' then
      src := pg_temp.ganti(src, $p$v_kunci text[] := array['pengajuan','approval','done','hold_expired','amend','reprocess'];$p$,
        $p$v_kunci text[] := array['pengajuan','approval','done','hold_expired','amend','reprocess','debtor' /* 20261163170000 */];$p$, 1, 'cc debtor');

    elsif f.sig like 'public.rc_posting_exception%' then
      src := pg_temp.ganti(src, $p$          'sebab','Status '||rc_private.legacy_status(c.status)||' tidak dapat di-On Hold'));
        continue;
      end if;$p$,
        $p$          'sebab','Status '||rc_private.legacy_status(c.status)||' tidak dapat di-On Hold'));
        continue;
      end if;
      -- 20261163170000: klaim Restricted (Not Yet yang belum lunas) hanya dapat di-Expired.
      if c.status = 'not_yet' and not rc_private.boleh_open(c.id, c.customer_id) then
        gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
          'sebab','Dokumen Restricted (belum lunas) hanya dapat di-Expired, tidak dapat di-On Hold'));
        continue;
      end if;$p$, 1, 'posting hold restricted');

    elsif f.sig like 'rc_private.legacy_documents%' then
      -- Pratinjau Posting Claim menandai dokumen Restricted sebelum dikirim (server tetap menolaknya).
      src := pg_temp.ganti(src, $p$'pendingApproval',c.pending_approval is not null,'versionNo',c.version_no) as x$p$,
        $p$'pendingApproval',c.pending_approval is not null,'versionNo',c.version_no,
       'bolehAjukan',case when c.status = 'not_yet' then rc_private.boleh_open(c.id, c.customer_id) else true end /* 20261163170000 */) as x$p$, 2, 'dokumen boleh diajukan');

    elsif f.sig like 'public.rc_customer_list%' then
      src := pg_temp.ganti(src, $p$'contactPerson',coalesce(cu.contact_person,''),$p$,
        $p$'contactPerson',coalesce(cu.contact_person,''),
   'badDebt',rc_private.toko_bad_debt(cu.id) is not null,'badDebtAlasan',coalesce(rc_private.toko_bad_debt(cu.id),''), /* 20261163170000 */$p$, 1, 'customer badge');
    end if;
    execute src;
  end loop;
end
$tambal$;

-- Antrean WPT/Overdue tidak memuat pengajuan toko Bad Debt yang menunggu approval Bad Debt.
do $view$
declare v text := pg_get_viewdef('rc_private.approval_rows'::regclass);
begin
  if v ~ 'bad_debt' then raise notice 'approval_rows sudah ditambal.'; return; end if;
  if md5(v) <> '0da971d653816d7236cb7e31366a5713' then raise exception 'DITOLAK: approval_rows berbeda (md5 %).', md5(v); end if;
  execute 'create or replace view rc_private.approval_rows as ' || pg_temp.ganti(rtrim(v, '; '||chr(10)),
    $p$WHERE (((c.pending_approval ->> 'kind'::text) = 'submit'::text) AND (c.archived_at IS NULL))$p$,
    $p$WHERE (((c.pending_approval ->> 'kind'::text) = 'submit'::text) AND (c.archived_at IS NULL) AND (COALESCE((c.pending_approval ->> 'bad_debt'::text), 'false'::text) <> 'true'::text))$p$,
    1, 'approval_rows');
end
$view$;

-- ------------------------------------------------------------------------------------------
-- 11. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $cek$
declare e text := ''; g jsonb;
begin
  g := rc_private.zdage_aturan('{"2026-10":0,"2026-09":0,"2026-08":0,"2026-07":654390510,"2026-06":0,"2026-05":0,"2026-04":0,"2026-03":0,"2026-02":0,"2026-01":0,"2025-12":0,"2025-11":0,"2025-10":0}'::jsonb,
    0, 0, date '2026-04-01', date '2026-07-31', 1, 'kolom');
  if g->'gagal' <> '[2]'::jsonb then e := e || ' aturan 2 (selama campaign) salah (' || g::text || ');'; end if;
  g := rc_private.zdage_aturan('{"2026-10":0,"2026-09":0,"2026-08":0,"2026-07":-42000,"2026-06":0,"2026-05":0,"2026-04":0,"2026-03":42000.71,"2026-02":0,"2026-01":0,"2025-12":0,"2025-11":0,"2025-10":0}'::jsonb,
    0, 0.71, date '2026-04-01', date '2026-07-31', 1, 'kolom');
  if g->'gagal' <> '[3]'::jsonb then e := e || ' mode kolom salah (' || g::text || ');'; end if;
  g := rc_private.zdage_aturan('{"2026-10":0,"2026-09":0,"2026-08":0,"2026-07":-42000,"2026-06":0,"2026-05":0,"2026-04":0,"2026-03":42000.71,"2026-02":0,"2026-01":0,"2025-12":0,"2025-11":0,"2025-10":0}'::jsonb,
    0, 0.71, date '2026-04-01', date '2026-07-31', 1, 'jumlah');
  if g->'gagal' <> '[]'::jsonb then e := e || ' mode jumlah salah (' || g::text || ');'; end if;
  g := rc_private.zdage_aturan('{"2026-10":0,"2026-09":0,"2026-08":0,"2026-07":0,"2026-06":0,"2026-05":0,"2026-04":0,"2026-03":0,"2026-02":0,"2026-01":0,"2025-12":0,"2025-11":0,"2025-10":0}'::jsonb,
    5500000.3, 5500000.3, date '2026-04-01', date '2026-07-31', 1, 'kolom');
  if g->'gagal' <> '[1, 3]'::jsonb or (g->>'utama')::integer <> 1 or (g->'rincian'->0->>'aturan')::integer <> 1 then
    e := e || ' kolom T / prioritas salah (' || g::text || ');'; end if;
  if rc_private.kode_toko('   0617108') <> '617108' then e := e || ' kode_toko salah;'; end if;
  if not exists(select 1 from rc_private.tab_catalog where code = 'compilation.debtor')
     or not exists(select 1 from rc_private.tab_catalog where code = 'approval.baddebt') then e := e || ' katalog tab;'; end if;
  if pg_get_viewdef('rc_private.approval_rows'::regclass) !~ 'bad_debt' then e := e || ' approval_rows;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
