-- ==========================================================================================
-- Document Generator: Form Verifikasi Customer untuk toko yang lunas (Upload Debtor)
-- ==========================================================================================
-- PRD "Auto Generate Form Verifikasi Customer" (pemilik, 18 Oktober 2026), lanjutan Upload
-- Debtor ZDAGE (20261163170000). Setiap toko dengan tawaran aktif di Claim Upload > Open
-- mendapat satu form verifikasi; admin depot mengunduhnya sebagai PDF (2 form per A4), sales
-- membawanya ke toko untuk ditandatangani Kepala Admin, SPV, Sales, dan pemilik toko.
--
-- KEPUTUSAN PEMILIK (PRD bagian 10, 18 Oktober 2026)
--  * Toko dengan lebih dari 4 campaign: dilanjutkan ke form berikutnya (Hal 1/2, 2/2) dengan
--    nomor form yang sama.
--  * Nomor form FV-ABBR-DDMMYY-NNN: ABBR depot (kode depot bila kosong), tanggal cetak WIB,
--    NNN urut per depot per hari. Nomor tidak pernah berulang (unik di tabel).
--  * Berkas unduhan PDF (dibentuk di browser dari data RPC ini).
--  * Tab Document Generator bawaan tercentang untuk Admin Depot (peran admin); peran lain
--    hanya bila dicentang di Access Management; System Manager selalu.
--  * Sesudah uji (18 Oktober 2026): tabel form memuat kolom Jenis CB; nama toko yang panjang
--    dibungkus ke baris berikutnya; logo memakai "Logo Nippon Lengkap" (merek utuh).
--  * Sesudah uji kedua (18 Oktober 2026):
--      - Form memuat Bank, No. Rekening, dan Atas Nama rekening dari Customer Master. Tidak
--        wajib: bila kosong, kolomnya dibiarkan kosong untuk ditulis tangan dan tidak menahan
--        cetak. (Ini menggantikan PRD bagian 6/8 yang melarang rekening dicetak / dikirim ke
--        browser. KTP dan NPWP tetap tidak pernah dikirim.)
--      - Tab kedua "Semua Not Yet" (docgen.notyet): seluruh klaim Not Yet - lunas maupun belum -
--        juga dapat diunduh sebagai form yang sama, dibedakan tabnya. Aturan tab bawaannya sama
--        dengan Form Verifikasi Customer.
--  * Toko yang Customer Master-nya belum lengkap TIDAK dapat dicetak sampai master dilengkapi.
--    Lengkap = master ada dan aktif, Nama Toko, Nama Pemilik (Contact Person), dan KTP / NPWP
--    terisi (subyek pajak dapat ditentukan). Rekening tidak termasuk syarat.
--
-- ATURAN
--  * Satu form = satu toko di satu depot, satu baris per campaign per Jenis CB. Sumber klaim:
--      lunas  (tab Form Verifikasi Customer): klaim Not Yet dengan tawaran aktif (offered /
--             overdue: Lunas, atau dipindah Editor dari Restricted). Bad Debt membatalkan
--             tawaran, jadi tidak pernah masuk.
--      notyet (tab Semua Not Yet): seluruh klaim Not Yet yang belum diajukan; klaim tanpa
--             Customer Master ikut tampil (tidak dapat dicetak).
--  * Net CB per baris = jumlah cb_net klaim campaign itu, dipotong tanpa desimal; Total = jumlah
--    baris yang tercetak.
--  * Subyek Pajak: NPWP terisi = Badan, selain itu Perorangan.
--  * Data dibaca saat unduh (bukan salinan). Yang disimpan hanya jejak: nomor form, sumber, klaim,
--    dan total pada saat unduh - dipakai untuk "Unduh terakhir" dan penanda "data berubah".
--  * Jangkauan depot diperiksa server (lingkup_depot_saya / can_access); aksi dijaga tab
--    docgen.verifikasi / docgen.notyet. Log Activity satu baris per proses unduh.
--
-- Tambalan tab_rights memakai penjaga MD5 pra-citra (sesudah 20261163180000, 18 Oktober 2026).
-- Urutan transport ke prod: 20261163170000, 20261163180000, lalu migrasi ini.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ------------------------------------------------------------------------------------------
-- 1. Jejak form (nomor unik + isi saat unduh)
-- ------------------------------------------------------------------------------------------
create table if not exists public.rc_form_verifikasi (
  id uuid primary key default gen_random_uuid(),
  no_form text not null unique,
  depot_id uuid not null references public.depots(id),
  customer_id uuid not null references public.customers(id),
  tanggal date not null,
  urut integer not null check (urut > 0),
  halaman integer not null default 1 check (halaman > 0),
  claim_ids uuid[] not null,
  total numeric not null,
  proses_id uuid not null,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (depot_id, tanggal, urut)
);
alter table public.rc_form_verifikasi add column if not exists sumber text not null default 'lunas';
do $c$ begin
  if not exists(select 1 from pg_constraint where conname = 'rc_form_verifikasi_sumber_check') then
    alter table public.rc_form_verifikasi add constraint rc_form_verifikasi_sumber_check check (sumber in ('lunas', 'notyet'));
  end if;
end $c$;
create index if not exists rc_form_verifikasi_toko on public.rc_form_verifikasi(depot_id, customer_id, created_at desc);

alter table public.rc_form_verifikasi enable row level security;
revoke all on public.rc_form_verifikasi from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Helper
-- ------------------------------------------------------------------------------------------
-- Klaim yang masuk form menurut sumbernya ('lunas' / 'notyet'), di dalam jangkauan depot
-- pemanggil. Jenis CB mengikuti label yang dipakai seluruh layar (cb_label atas jenis efektif:
-- ubahan Change CB Type mengungguli jenis campaign). Bentuk dan tanda tangannya pernah berubah
-- (18 Oktober 2026), jadi versi lama dibuang lebih dulu.
drop function if exists rc_private.docgen_klaim(uuid, uuid);
drop function if exists rc_private.docgen_klaim(text, uuid, uuid);
create function rc_private.docgen_klaim(p_sumber text, p_depot uuid default null, p_customer uuid default null)
returns table(claim_id uuid, depot_id uuid, customer_id uuid, kode_sumber text, campaign_id uuid, cb_net numeric,
              deadline_at timestamptz, offer_result text, jenis_cb text, lunas boolean)
language sql stable security definer set search_path = '' as $f$
  select c.id, c.depot_id, c.customer_id, upper(btrim(coalesce(c.source_customer_code, ''))), c.campaign_id, coalesce(c.cb_net, 0),
         o.deadline_at, o.result,
         coalesce(nullif(rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)), ''), '-'),
         o.claim_id is not null
    from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
    left join public.rc_clearing_offers o on o.claim_id = c.id and o.status in ('offered', 'overdue')
   cross join rc_private.lingkup_depot_saya() l
   where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
     and (p_sumber = 'notyet' or (o.claim_id is not null and c.customer_id is not null))
     and (l.semua or c.depot_id = any(l.depot))
     and (p_depot is null or c.depot_id = p_depot)
     and (p_customer is null or c.customer_id = p_customer);
$f$;

-- Kekurangan Customer Master yang menahan cetak; null = lengkap. Rekening tidak termasuk syarat.
create or replace function rc_private.docgen_masalah_master(p_customer uuid) returns text
language sql stable security definer set search_path = '' as $f$
  select case when cu.id is null then 'Customer Master tidak ditemukan'
              when cu.archived_at is not null then 'Customer Master diarsip'
              else nullif(concat_ws('; ',
                case when btrim(coalesce(cu.customer_name, '')) = '' then 'Nama Toko kosong' end,
                case when btrim(coalesce(cu.contact_person, '')) = '' then 'Nama Pemilik (Contact Person) kosong' end,
                case when regexp_replace(coalesce(cu.npwp, ''), '\D', '', 'g') = '' and regexp_replace(coalesce(cu.ktp, ''), '\D', '', 'g') = ''
                     then 'KTP / NPWP kosong (Subyek Pajak tidak dapat ditentukan)' end), '') end
    from (select 1) x left join public.customers cu on cu.id = p_customer;
$f$;

-- Subyek Pajak untuk form: NPWP terisi = Badan, selain itu Perorangan (PRD bagian 6).
create or replace function rc_private.docgen_subyek_pajak(p_npwp text) returns text
language sql immutable set search_path = '' as $f$
  select case when regexp_replace(coalesce(p_npwp, ''), '\D', '', 'g') <> '' then 'Badan' else 'Perorangan' end;
$f$;

-- Tab penjaga tiap sumber.
create or replace function rc_private.docgen_tab(p_sumber text) returns text
language plpgsql immutable set search_path = '' as $f$
begin
  if p_sumber = 'lunas' then return 'docgen.verifikasi'; end if;
  if p_sumber = 'notyet' then return 'docgen.notyet'; end if;
  raise exception 'Sumber form tidak dikenal: %', p_sumber;
end $f$;

revoke all on function rc_private.docgen_klaim(text, uuid, uuid), rc_private.docgen_masalah_master(uuid),
  rc_private.docgen_subyek_pajak(text), rc_private.docgen_tab(text) from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. RPC
-- ------------------------------------------------------------------------------------------
-- Daftar toko: satu baris per toko per depot. Klaim tanpa Customer Master (hanya di Semua Not
-- Yet) dikelompokkan menurut kode toko sumbernya dan ditandai tidak dapat dicetak.
drop function if exists public.rc_docgen_list();
create or replace function public.rc_docgen_list(p_sumber text default 'lunas') returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
begin
  perform rc_private.require_tab(rc_private.docgen_tab(p_sumber));
  return jsonb_build_object('status', 'success', 'sumber', p_sumber, 'rows', coalesce((
    with k as (select x.*, coalesce(x.customer_id::text, 'kode:' || x.kode_sumber) kunci from rc_private.docgen_klaim(p_sumber) x),
    -- Satu baris form per campaign per Jenis CB.
    per_c as (select k.depot_id, k.kunci, k.campaign_id, k.jenis_cb, trunc(sum(k.cb_net)) cb from k group by 1, 2, 3, 4),
    t as (select k.depot_id, k.kunci, (array_agg(k.customer_id))[1] customer_id, min(k.kode_sumber) kode_sumber,
                 array_agg(k.claim_id order by k.claim_id) ids, count(*) n_klaim, count(*) filter (where k.lunas) n_lunas,
                 min(k.deadline_at) deadline, bool_or(k.offer_result = 'RESTRICTED') restricted
            from k group by 1, 2),
    c as (select p.depot_id, p.kunci, sum(p.cb) total, count(distinct p.campaign_id) n_campaign, count(*) n_baris,
                 to_jsonb(array_agg(distinct p.jenis_cb)) jenis,
                 jsonb_agg(jsonb_build_object('id', ca.id, 'kode', ca.campaign_code, 'nama', ca.campaign_name, 'jenisCb', p.jenis_cb)
                           order by ca.campaign_code, p.jenis_cb) campaigns
            from per_c p join public.campaigns ca on ca.id = p.campaign_id group by 1, 2)
    select jsonb_agg(jsonb_build_object(
             'depotId', d.id, 'depotKode', d.depot_code, 'depotNama', coalesce(nullif(d.depot_name, ''), d.depot_code),
             'customerId', cu.id, 'kode', coalesce(cu.customer_code, t.kode_sumber), 'nama', coalesce(cu.customer_name, ''),
             'pemilik', coalesce(cu.contact_person, ''),
             'subyekPajak', case when cu.id is null then '' else rc_private.docgen_subyek_pajak(cu.npwp) end,
             'bank', coalesce(btrim(cu.bank), ''), 'noRek', coalesce(btrim(cu.account_number), ''), 'atasNama', coalesce(btrim(cu.account_name), ''),
             'jumlahKlaim', t.n_klaim, 'jumlahLunas', t.n_lunas, 'jumlahCampaign', c.n_campaign, 'campaigns', c.campaigns, 'totalNetCb', c.total,
             'jenisCb', c.jenis, 'halaman', ceil(c.n_baris / 4.0)::integer,
             'deadline', coalesce(to_char(t.deadline at time zone 'Asia/Jakarta', 'DD-Mon-YYYY'), ''),
             'restricted', coalesce(t.restricted, false),
             'masalahMaster', m.masalah, 'siap', m.masalah is null,
             'unduh', case when f.no_form is null then null else jsonb_build_object('noForm', f.no_form,
                        'pada', to_char(f.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
                        'oleh', coalesce(nullif(pf.full_name, ''), pf.user_code, '-'), 'sumber', f.sumber) end,
             'jumlahUnduh', coalesce(fn.n, 0),
             -- Klaim atau nilainya berubah sejak unduh terakhir (mis. Amend Doc): perlu unduh ulang.
             'berubah', f.no_form is not null and (not (f.claim_ids @> t.ids and t.ids @> f.claim_ids) or f.total <> c.total))
             order by d.depot_code, coalesce(cu.customer_code, t.kode_sumber))
      from t
      join c on c.depot_id = t.depot_id and c.kunci = t.kunci
      join public.depots d on d.id = t.depot_id
      left join public.customers cu on cu.id = t.customer_id
     cross join lateral (select rc_private.docgen_masalah_master(t.customer_id) masalah) m
      left join lateral (select x.no_form, x.created_at, x.created_by, x.claim_ids, x.total, x.sumber from public.rc_form_verifikasi x
                          where x.depot_id = t.depot_id and x.customer_id = t.customer_id and x.claim_ids && t.ids
                          order by x.created_at desc, x.urut desc limit 1) f on true
      left join public.profiles pf on pf.id = f.created_by
      left join lateral (select count(*) n from public.rc_form_verifikasi x
                          where x.depot_id = t.depot_id and x.customer_id = t.customer_id and x.claim_ids && t.ids) fn on true
  ), '[]'::jsonb));
end $f$;

-- Bentuk form untuk toko terpilih dan beri nomor. Toko yang gagal disebut beserta alasannya;
-- toko yang berhasil selalu utuh (tidak ada form setengah jadi).
drop function if exists public.rc_docgen_generate(jsonb);
create or replace function public.rc_docgen_generate(p_toko jsonb, p_sumber text default 'lunas') returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_proses uuid := gen_random_uuid();
  r record; v_forms jsonb := '[]'; v_gagal jsonb := '[]'; v_rows jsonb; v_ids uuid[]; v_total numeric; v_n integer;
  v_urut integer; v_no text; v_masalah text; v_nomor text[] := '{}'; v_depot text[] := '{}';
  v_tab text := rc_private.docgen_tab(p_sumber);
  v_judul text := case when p_sumber = 'notyet' then 'Semua Not Yet' else 'Toko Lunas' end;
begin
  perform rc_private.require_tab(v_tab);
  if jsonb_typeof(p_toko) is distinct from 'array' or jsonb_array_length(p_toko) = 0 then raise exception 'Pilih toko lebih dulu'; end if;
  if jsonb_array_length(p_toko) > 500 then raise exception 'Maksimal 500 toko sekali unduh'; end if;
  begin
    perform (e->>'depotId')::uuid, (e->>'customerId')::uuid from jsonb_array_elements(p_toko) e;
  exception when invalid_text_representation then raise exception 'Data toko tidak valid'; end;

  -- Urut depot lalu kode toko, supaya nomor dan halaman PDF berurutan.
  for r in
    select x.depot_id, x.customer_id, d.id d_ada, d.depot_code, coalesce(nullif(d.depot_name, ''), d.depot_code) depot_nama,
           upper(coalesce(nullif(btrim(d.abbr), ''), d.depot_code)) abbr, cu.customer_code, cu.customer_name, cu.contact_person, cu.npwp,
           coalesce(btrim(cu.bank), '') bank, coalesce(btrim(cu.account_number), '') no_rek, coalesce(btrim(cu.account_name), '') atas_nama
      from (select distinct (e->>'depotId')::uuid depot_id, (e->>'customerId')::uuid customer_id from jsonb_array_elements(p_toko) e) x
      left join public.depots d on d.id = x.depot_id
      left join public.customers cu on cu.id = x.customer_id
     order by d.depot_code nulls last, cu.customer_code nulls last
  loop
    if r.d_ada is null or r.depot_id is null or not rc_private.can_access(r.depot_id) then
      v_gagal := v_gagal || jsonb_build_object('depotKode', coalesce(r.depot_code, '-'), 'kode', coalesce(r.customer_code, '-'),
                   'nama', coalesce(r.customer_name, ''), 'alasan', 'Depot di luar jangkauan Anda');
      continue;
    end if;
    v_masalah := rc_private.docgen_masalah_master(r.customer_id);
    if v_masalah is not null then
      v_gagal := v_gagal || jsonb_build_object('depotKode', r.depot_code, 'kode', coalesce(r.customer_code, '-'),
                   'nama', coalesce(r.customer_name, ''), 'alasan', 'Customer Master belum lengkap: ' || v_masalah);
      continue;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object('kode', ca.campaign_code, 'nama', ca.campaign_name, 'jenisCb', p.jenis_cb, 'netCb', p.cb,
                                                 'taxStatus', coalesce(ca.tax_status, '')) order by ca.campaign_code, p.jenis_cb), '[]'::jsonb),
           coalesce(sum(p.cb), 0), count(*)
      into v_rows, v_total, v_n
      from (select k.campaign_id, k.jenis_cb, trunc(sum(k.cb_net)) cb from rc_private.docgen_klaim(p_sumber, r.depot_id, r.customer_id) k group by 1, 2) p
      join public.campaigns ca on ca.id = p.campaign_id;
    if v_n = 0 then
      v_gagal := v_gagal || jsonb_build_object('depotKode', r.depot_code, 'kode', r.customer_code, 'nama', coalesce(r.customer_name, ''),
                   'alasan', case when p_sumber = 'notyet' then 'Tidak ada klaim Not Yet (sudah diajukan atau diproses)'
                                  else 'Tidak ada klaim lunas aktif (sudah diajukan atau tawarannya dibatalkan)' end);
      continue;
    end if;
    select array_agg(k.claim_id order by k.claim_id) into v_ids from rc_private.docgen_klaim(p_sumber, r.depot_id, r.customer_id) k;

    -- Nomor urut per depot per hari (satu deret untuk kedua tab); kunci transaksi mencegah dua
    -- unduhan bersamaan memakai nomor yang sama.
    perform pg_advisory_xact_lock(hashtextextended('rc_form_verifikasi:' || r.depot_id::text || ':' || v_hari::text, 0));
    select coalesce(max(f.urut), 0) + 1 into v_urut from public.rc_form_verifikasi f where f.depot_id = r.depot_id and f.tanggal = v_hari;
    v_no := 'FV-' || r.abbr || '-' || to_char(v_hari, 'DDMMYY') || '-' || lpad(v_urut::text, 3, '0');
    insert into public.rc_form_verifikasi(no_form, depot_id, customer_id, tanggal, urut, halaman, claim_ids, total, proses_id, created_by, sumber)
    values (v_no, r.depot_id, r.customer_id, v_hari, v_urut, ceil(v_n / 4.0)::integer, v_ids, v_total, v_proses, auth.uid(), p_sumber);

    v_nomor := v_nomor || v_no;
    if not (r.depot_code = any(v_depot)) then v_depot := v_depot || r.depot_code; end if;
    v_forms := v_forms || jsonb_build_object('noForm', v_no, 'dicetak', to_char(v_hari, 'DD-Mon-YYYY'), 'sumber', p_sumber,
      'depot', jsonb_build_object('kode', r.depot_code, 'nama', r.depot_nama),
      'toko', jsonb_build_object('kode', r.customer_code, 'nama', r.customer_name, 'pemilik', r.contact_person,
                                 'subyekPajak', rc_private.docgen_subyek_pajak(r.npwp)),
      'rekening', jsonb_build_object('bank', r.bank, 'noRek', r.no_rek, 'atasNama', r.atas_nama),
      'campaigns', v_rows, 'total', v_total, 'halaman', ceil(v_n / 4.0)::integer, 'jumlahKlaim', cardinality(v_ids));
  end loop;

  if jsonb_array_length(v_forms) > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'docgen_verifikasi',
      jsonb_build_object('detail', 'Document Generator (' || v_judul || '): ' || jsonb_array_length(v_forms) || ' form verifikasi ('
                                     || v_nomor[1] || case when cardinality(v_nomor) > 1 then ' s.d. ' || v_nomor[cardinality(v_nomor)] else '' end || ')'
                                     || case when jsonb_array_length(v_gagal) > 0 then '; ' || jsonb_array_length(v_gagal) || ' toko gagal' else '' end,
                         'jumlah', jsonb_array_length(v_forms), 'gagal', jsonb_array_length(v_gagal), 'nomor', to_jsonb(v_nomor),
                         'depot', to_jsonb(v_depot), 'proses', v_proses, 'sumber', p_sumber),
      'docgen', split_part(v_tab, '.', 2), split_part(v_tab, '.', 2));
  end if;

  return jsonb_build_object('status', 'success', 'forms', v_forms, 'gagal', v_gagal,
    'message', jsonb_array_length(v_forms) || ' form dibuat'
      || case when jsonb_array_length(v_gagal) > 0 then '; ' || jsonb_array_length(v_gagal) || ' toko tidak dapat dibuatkan form' else '' end || '.');
end $f$;

revoke all on function public.rc_docgen_list(text), public.rc_docgen_generate(jsonb, text) from public, anon;
grant execute on function public.rc_docgen_list(text), public.rc_docgen_generate(jsonb, text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Katalog tab dan tambalan tab_rights
-- ------------------------------------------------------------------------------------------
insert into rc_private.tab_catalog(code, module, tab, permission, title, label, key)
select x.code, 'docgen', x.tab, null, x.title, 'Document Generator', 'docgen'
  from (values ('docgen.verifikasi', 'verifikasi', 'Form Verifikasi Customer'), ('docgen.notyet', 'notyet', 'Semua Not Yet')) x(code, tab, title)
 where not exists(select 1 from rc_private.tab_catalog c where c.code = x.code);

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure), E'\r', '');
  if src ~ 'docgen\.notyet' then raise notice 'tab_rights sudah ditambal.';
  elsif src ~ '20261163190000' then
    -- Dev, 18 Oktober 2026: versi awal migrasi ini hanya mengenal docgen.verifikasi.
    src := pg_temp.ganti(src, $p$(t.code='docgen.verifikasi' and p.role<>'admin')$p$,
      $p$(t.code in ('docgen.verifikasi','docgen.notyet') and p.role<>'admin')$p$, 1, 'tab_rights docgen.notyet');
    execute src;
  else
    if md5(src) <> 'd6771571659aed0202eca832bf1dc956' then
      raise exception 'DITOLAK: tab_rights berbeda dari yang diukur (md5 %).', md5(src); end if;
    src := pg_temp.ganti(src, $p$or t.code='links.editor' /* 20261163180000: hanya bila dicentang */$p$,
      $p$or t.code='links.editor' /* 20261163180000: hanya bila dicentang */ or (t.code in ('docgen.verifikasi','docgen.notyet') and p.role<>'admin') /* 20261163190000: bawaan tercentang hanya untuk Admin Depot */$p$, 1, 'tab_rights');
    execute src;
  end if;
end $tambal$;

-- ------------------------------------------------------------------------------------------
-- 5. Pemeriksaan diri
-- ------------------------------------------------------------------------------------------
do $cek$
declare e text := '';
begin
  if pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure) !~ 'docgen\.notyet' then e := e || ' tab_rights;'; end if;
  if (select count(*) from rc_private.tab_catalog where code in ('docgen.verifikasi', 'docgen.notyet') and permission is null) <> 2 then
    e := e || ' katalog tab;'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.rc_form_verifikasi'::regclass) then e := e || ' RLS;'; end if;
  if has_table_privilege('authenticated', 'public.rc_form_verifikasi', 'select') then e := e || ' hak tabel;'; end if;
  if rc_private.docgen_subyek_pajak('01.234.567.8-901.000') <> 'Badan' or rc_private.docgen_subyek_pajak('') <> 'Perorangan' then
    e := e || ' subyek pajak;'; end if;
  if rc_private.docgen_masalah_master(null) is null then e := e || ' master kosong;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
