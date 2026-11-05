-- ==========================================================================================
-- Document Generator: tab Done dan Not Yet untuk seluruh toko (tanpa syarat lunas)
-- ==========================================================================================
-- Pemilik, 29 Oktober 2026:
--   "khusus document generator transport ke prod dengan tidak melihat lunas melainkan seluruh
--    toko. jadi tab nya bukan lunas dan tidak lunas tapi Done dan Not Yet. Artinya jika Done dia
--    akan terdownload yang sudah proses clearing, dan not yet dia akan mengenerate semuanya"
--
-- Migrasi ini berdiri sendiri: di prod (belum ada 20261163170000 Upload Debtor maupun
-- 20261163190000) ia membuat seluruh Document Generator; di dev ia mengganti versi lama.
-- Tidak ada lagi rujukan ke rc_clearing_offers.
--
--   TAB          docgen.done   "Done"    klaim yang sudah Done (sudah melewati Clearing). Saring
--                                        opsional Tgl Done (cleared_at, WIB) dari / sampai; klaim
--                                        Done tanpa Tgl Done hanya ikut bila saringan kosong.
--                docgen.notyet "Not Yet" seluruh klaim Not Yet yang belum diajukan (tanpa
--                                        approval tertunda).
--                docgen.verifikasi (Toko Lunas, dev) dihapus; centang akun dipindah ke docgen.done.
--                Bawaan tercentang hanya Admin Depot (peran admin), peran lain bila dicentang.
--   FORM         Tanda Terima (20261163520000): nomor TT-ABBR-DDMMYY-NNN, satu deret per depot per
--                hari untuk kedua tab; toko.sales dari Customer Master. Klaim tanpa Customer
--                Master tampil tetapi tidak dapat dicetak; master belum lengkap menahan cetak.
--   JEJAK        rc_form_verifikasi.sumber 'done' / 'notyet' (+ 'lunas' riwayat dev), periode
--                saringan Done disimpan. "Unduh terakhir" dan "Data berubah" dihitung per tab.
--
-- Urutan transport ke prod: 20261163520000 (Sales Name; bagian docgen-nya otomatis dilewati),
-- lalu migrasi ini.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $prasyarat$
begin
  if not exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'sales_name') then
    raise exception 'DITOLAK: jalankan 20261163520000 (Sales Name) lebih dulu.';
  end if;
end $prasyarat$;

-- ------------------------------------------------------------------------------------------
-- 1. Jejak form
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
alter table public.rc_form_verifikasi add column if not exists sumber text not null default 'done';
alter table public.rc_form_verifikasi alter column sumber set default 'done';
alter table public.rc_form_verifikasi add column if not exists periode_dari date;
alter table public.rc_form_verifikasi add column if not exists periode_sampai date;
alter table public.rc_form_verifikasi drop constraint if exists rc_form_verifikasi_sumber_check;
alter table public.rc_form_verifikasi add constraint rc_form_verifikasi_sumber_check check (sumber in ('done', 'notyet', 'lunas'));
create index if not exists rc_form_verifikasi_toko on public.rc_form_verifikasi(depot_id, customer_id, created_at desc);
comment on table public.rc_form_verifikasi is 'Jejak unduh Tanda Terima Document Generator (20261163190000, 20261163540000). sumber lunas = riwayat tab Toko Lunas di dev.';

alter table public.rc_form_verifikasi enable row level security;
revoke all on public.rc_form_verifikasi from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Helper
-- ------------------------------------------------------------------------------------------
drop function if exists rc_private.docgen_klaim(uuid, uuid);
drop function if exists rc_private.docgen_klaim(text, uuid, uuid);
drop function if exists rc_private.docgen_klaim(text, uuid, uuid, date, date);
-- Klaim yang masuk form menurut tabnya, di dalam jangkauan depot pemanggil. Jenis CB mengikuti
-- label seluruh layar (cb_label atas jenis efektif: ubahan Change CB Type mengungguli campaign).
create function rc_private.docgen_klaim(p_sumber text, p_depot uuid default null, p_customer uuid default null,
                                        p_dari date default null, p_sampai date default null)
returns table(claim_id uuid, depot_id uuid, customer_id uuid, kode_sumber text, campaign_id uuid, cb_net numeric,
              tgl_done date, jenis_cb text)
language sql stable security definer set search_path = '' as $f$
  select c.id, c.depot_id, c.customer_id, upper(btrim(coalesce(c.source_customer_code, ''))), c.campaign_id, coalesce(c.cb_net, 0),
         (c.cleared_at at time zone 'Asia/Jakarta')::date,
         coalesce(nullif(rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)), ''), '-')
    from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
   cross join rc_private.lingkup_depot_saya() l
   where c.archived_at is null
     and ((p_sumber = 'done' and c.status = 'done'
           and (p_dari is null or (c.cleared_at at time zone 'Asia/Jakarta')::date >= p_dari)
           and (p_sampai is null or (c.cleared_at at time zone 'Asia/Jakarta')::date <= p_sampai))
       or (p_sumber = 'notyet' and c.status = 'not_yet' and c.pending_approval is null))
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

-- Subyek Pajak untuk form: NPWP terisi = Badan, selain itu Perorangan.
create or replace function rc_private.docgen_subyek_pajak(p_npwp text) returns text
language sql immutable set search_path = '' as $f$
  select case when regexp_replace(coalesce(p_npwp, ''), '\D', '', 'g') <> '' then 'Badan' else 'Perorangan' end;
$f$;

-- Tab penjaga tiap sumber.
create or replace function rc_private.docgen_tab(p_sumber text) returns text
language plpgsql immutable set search_path = '' as $f$
begin
  if p_sumber = 'done' then return 'docgen.done'; end if;
  if p_sumber = 'notyet' then return 'docgen.notyet'; end if;
  raise exception 'Sumber form tidak dikenal: %', p_sumber;
end $f$;

revoke all on function rc_private.docgen_klaim(text, uuid, uuid, date, date), rc_private.docgen_masalah_master(uuid),
  rc_private.docgen_subyek_pajak(text), rc_private.docgen_tab(text) from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. RPC
-- ------------------------------------------------------------------------------------------
drop function if exists public.rc_docgen_list();
drop function if exists public.rc_docgen_list(text);
-- Daftar toko: satu baris per toko per depot. Klaim tanpa Customer Master dikelompokkan menurut
-- kode toko sumbernya dan ditandai tidak dapat dicetak.
create or replace function public.rc_docgen_list(p_sumber text default 'done', p_dari date default null, p_sampai date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
begin
  perform rc_private.require_tab(rc_private.docgen_tab(p_sumber));
  if p_sumber <> 'done' and (p_dari is not null or p_sampai is not null) then raise exception 'Saringan Tgl Done hanya untuk tab Done'; end if;
  if p_dari > p_sampai then raise exception 'Tgl Done "dari" melewati "sampai"'; end if;
  return jsonb_build_object('status', 'success', 'sumber', p_sumber, 'rows', coalesce((
    with k as (select x.*, coalesce(x.customer_id::text, 'kode:' || x.kode_sumber) kunci from rc_private.docgen_klaim(p_sumber, null, null, p_dari, p_sampai) x),
    -- Satu baris form per campaign per Jenis CB.
    per_c as (select k.depot_id, k.kunci, k.campaign_id, k.jenis_cb, trunc(sum(k.cb_net)) cb from k group by 1, 2, 3, 4),
    t as (select k.depot_id, k.kunci, (array_agg(k.customer_id))[1] customer_id, min(k.kode_sumber) kode_sumber,
                 array_agg(k.claim_id order by k.claim_id) ids, count(*) n_klaim, min(k.tgl_done) done_awal, max(k.tgl_done) done_akhir
            from k group by 1, 2),
    c as (select p.depot_id, p.kunci, sum(p.cb) total, count(distinct p.campaign_id) n_campaign, count(*) n_baris,
                 to_jsonb(array_agg(distinct p.jenis_cb)) jenis,
                 jsonb_agg(jsonb_build_object('id', ca.id, 'kode', ca.campaign_code, 'nama', ca.campaign_name, 'jenisCb', p.jenis_cb)
                           order by ca.campaign_code, p.jenis_cb) campaigns
            from per_c p join public.campaigns ca on ca.id = p.campaign_id group by 1, 2)
    select jsonb_agg(jsonb_build_object(
             'depotId', d.id, 'depotKode', d.depot_code, 'depotNama', coalesce(nullif(d.depot_name, ''), d.depot_code),
             'customerId', cu.id, 'kode', coalesce(cu.customer_code, t.kode_sumber), 'nama', coalesce(cu.customer_name, ''),
             'pemilik', coalesce(cu.contact_person, ''), 'sales', coalesce(btrim(cu.sales_name), ''),
             'subyekPajak', case when cu.id is null then '' else rc_private.docgen_subyek_pajak(cu.npwp) end,
             'bank', coalesce(btrim(cu.bank), ''), 'noRek', coalesce(btrim(cu.account_number), ''), 'atasNama', coalesce(btrim(cu.account_name), ''),
             'jumlahKlaim', t.n_klaim, 'jumlahCampaign', c.n_campaign, 'campaigns', c.campaigns, 'totalNetCb', c.total,
             'jenisCb', c.jenis, 'halaman', ceil(c.n_baris / 4.0)::integer,
             'tglDone', case when t.done_awal is null then ''
                             when t.done_awal = t.done_akhir then to_char(t.done_awal, 'DD-Mon-YYYY')
                             else to_char(t.done_awal, 'DD-Mon-YYYY') || ' s.d. ' || to_char(t.done_akhir, 'DD-Mon-YYYY') end,
             'masalahMaster', m.masalah, 'siap', m.masalah is null,
             'unduh', case when f.no_form is null then null else jsonb_build_object('noForm', f.no_form,
                        'pada', to_char(f.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
                        'oleh', coalesce(nullif(pf.full_name, ''), pf.user_code, '-')) end,
             'jumlahUnduh', coalesce(fn.n, 0),
             -- Klaim atau nilainya berubah sejak unduh terakhir di tab ini (mis. Amend Doc, klaim baru Done).
             'berubah', f.no_form is not null and (not (f.claim_ids @> t.ids and t.ids @> f.claim_ids) or f.total <> c.total))
             order by d.depot_code, coalesce(cu.customer_code, t.kode_sumber))
      from t
      join c on c.depot_id = t.depot_id and c.kunci = t.kunci
      join public.depots d on d.id = t.depot_id
      left join public.customers cu on cu.id = t.customer_id
     cross join lateral (select rc_private.docgen_masalah_master(t.customer_id) masalah) m
      left join lateral (select x.no_form, x.created_at, x.created_by, x.claim_ids, x.total from public.rc_form_verifikasi x
                          where x.depot_id = t.depot_id and x.customer_id = t.customer_id and x.sumber = p_sumber and x.claim_ids && t.ids
                          order by x.created_at desc, x.urut desc limit 1) f on true
      left join public.profiles pf on pf.id = f.created_by
      left join lateral (select count(*) n from public.rc_form_verifikasi x
                          where x.depot_id = t.depot_id and x.customer_id = t.customer_id and x.sumber = p_sumber and x.claim_ids && t.ids) fn on true
  ), '[]'::jsonb));
end $f$;

drop function if exists public.rc_docgen_generate(jsonb);
drop function if exists public.rc_docgen_generate(jsonb, text);
-- Bentuk Tanda Terima untuk toko terpilih dan beri nomor. Toko yang gagal disebut beserta
-- alasannya; toko yang berhasil selalu utuh (tidak ada form setengah jadi).
create or replace function public.rc_docgen_generate(p_toko jsonb, p_sumber text default 'done', p_dari date default null, p_sampai date default null) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_proses uuid := gen_random_uuid();
  r record; v_forms jsonb := '[]'; v_gagal jsonb := '[]'; v_rows jsonb; v_ids uuid[]; v_total numeric; v_n integer;
  v_urut integer; v_no text; v_masalah text; v_nomor text[] := '{}'; v_depot text[] := '{}';
  v_tab text := rc_private.docgen_tab(p_sumber);
  v_judul text := case when p_sumber = 'notyet' then 'Not Yet' else 'Done' end;
  v_periode text := case when p_dari is null and p_sampai is null then ''
                         else coalesce(to_char(p_dari, 'DD-Mon-YYYY'), 'awal') || ' s.d. ' || coalesce(to_char(p_sampai, 'DD-Mon-YYYY'), 'sekarang') end;
begin
  perform rc_private.require_tab(v_tab);
  if p_sumber <> 'done' and (p_dari is not null or p_sampai is not null) then raise exception 'Saringan Tgl Done hanya untuk tab Done'; end if;
  if p_dari > p_sampai then raise exception 'Tgl Done "dari" melewati "sampai"'; end if;
  if jsonb_typeof(p_toko) is distinct from 'array' or jsonb_array_length(p_toko) = 0 then raise exception 'Pilih toko lebih dulu'; end if;
  if jsonb_array_length(p_toko) > 500 then raise exception 'Maksimal 500 toko sekali unduh'; end if;
  begin
    perform (e->>'depotId')::uuid, (e->>'customerId')::uuid from jsonb_array_elements(p_toko) e;
  exception when invalid_text_representation then raise exception 'Data toko tidak valid'; end;

  -- Urut depot lalu kode toko, supaya nomor dan halaman PDF berurutan.
  for r in
    select x.depot_id, x.customer_id, d.id d_ada, d.depot_code, coalesce(nullif(d.depot_name, ''), d.depot_code) depot_nama,
           upper(coalesce(nullif(btrim(d.abbr), ''), d.depot_code)) abbr, cu.customer_code, cu.customer_name, cu.contact_person, cu.npwp,
           coalesce(btrim(cu.bank), '') bank, coalesce(btrim(cu.account_number), '') no_rek, coalesce(btrim(cu.account_name), '') atas_nama,
           coalesce(btrim(cu.sales_name), '') sales
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
      from (select k.campaign_id, k.jenis_cb, trunc(sum(k.cb_net)) cb
              from rc_private.docgen_klaim(p_sumber, r.depot_id, r.customer_id, p_dari, p_sampai) k group by 1, 2) p
      join public.campaigns ca on ca.id = p.campaign_id;
    if v_n = 0 then
      v_gagal := v_gagal || jsonb_build_object('depotKode', r.depot_code, 'kode', r.customer_code, 'nama', coalesce(r.customer_name, ''),
                   'alasan', case when p_sumber = 'notyet' then 'Tidak ada klaim Not Yet (sudah diajukan atau diproses)'
                                  else 'Tidak ada klaim Done' || case when v_periode <> '' then ' pada Tgl Done ' || v_periode else '' end end);
      continue;
    end if;
    select array_agg(k.claim_id order by k.claim_id) into v_ids from rc_private.docgen_klaim(p_sumber, r.depot_id, r.customer_id, p_dari, p_sampai) k;

    -- Nomor urut per depot per hari (satu deret untuk kedua tab); kunci transaksi mencegah dua
    -- unduhan bersamaan memakai nomor yang sama.
    perform pg_advisory_xact_lock(hashtextextended('rc_form_verifikasi:' || r.depot_id::text || ':' || v_hari::text, 0));
    select coalesce(max(f.urut), 0) + 1 into v_urut from public.rc_form_verifikasi f where f.depot_id = r.depot_id and f.tanggal = v_hari;
    v_no := 'TT-' || r.abbr || '-' || to_char(v_hari, 'DDMMYY') || '-' || lpad(v_urut::text, 3, '0');
    insert into public.rc_form_verifikasi(no_form, depot_id, customer_id, tanggal, urut, halaman, claim_ids, total, proses_id, created_by, sumber, periode_dari, periode_sampai)
    values (v_no, r.depot_id, r.customer_id, v_hari, v_urut, ceil(v_n / 4.0)::integer, v_ids, v_total, v_proses, auth.uid(), p_sumber, p_dari, p_sampai);

    v_nomor := v_nomor || v_no;
    if not (r.depot_code = any(v_depot)) then v_depot := v_depot || r.depot_code; end if;
    v_forms := v_forms || jsonb_build_object('noForm', v_no, 'dicetak', to_char(v_hari, 'DD-Mon-YYYY'), 'sumber', p_sumber, 'periode', v_periode,
      'depot', jsonb_build_object('kode', r.depot_code, 'nama', r.depot_nama),
      'toko', jsonb_build_object('kode', r.customer_code, 'nama', r.customer_name, 'pemilik', r.contact_person,
                                 'subyekPajak', rc_private.docgen_subyek_pajak(r.npwp), 'sales', r.sales),
      'rekening', jsonb_build_object('bank', r.bank, 'noRek', r.no_rek, 'atasNama', r.atas_nama),
      'campaigns', v_rows, 'total', v_total, 'halaman', ceil(v_n / 4.0)::integer, 'jumlahKlaim', cardinality(v_ids));
  end loop;

  if jsonb_array_length(v_forms) > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'docgen_verifikasi',
      jsonb_build_object('detail', 'Document Generator (' || v_judul || case when v_periode <> '' then ', Tgl Done ' || v_periode else '' end || '): '
                                     || jsonb_array_length(v_forms) || ' tanda terima ('
                                     || v_nomor[1] || case when cardinality(v_nomor) > 1 then ' s.d. ' || v_nomor[cardinality(v_nomor)] else '' end || ')'
                                     || case when jsonb_array_length(v_gagal) > 0 then '; ' || jsonb_array_length(v_gagal) || ' toko gagal' else '' end,
                         'jumlah', jsonb_array_length(v_forms), 'gagal', jsonb_array_length(v_gagal), 'nomor', to_jsonb(v_nomor),
                         'depot', to_jsonb(v_depot), 'proses', v_proses, 'sumber', p_sumber, 'dari', p_dari, 'sampai', p_sampai),
      'docgen', split_part(v_tab, '.', 2), split_part(v_tab, '.', 2));
  end if;

  return jsonb_build_object('status', 'success', 'forms', v_forms, 'gagal', v_gagal,
    'message', jsonb_array_length(v_forms) || ' tanda terima dibuat'
      || case when jsonb_array_length(v_gagal) > 0 then '; ' || jsonb_array_length(v_gagal) || ' toko tidak dapat dibuatkan' else '' end || '.');
end $f$;

revoke all on function public.rc_docgen_list(text, date, date), public.rc_docgen_generate(jsonb, text, date, date) from public, anon;
grant execute on function public.rc_docgen_list(text, date, date), public.rc_docgen_generate(jsonb, text, date, date) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Katalog tab (Done, Not Yet) dan tambalan tab_rights
-- ------------------------------------------------------------------------------------------
insert into rc_private.tab_catalog(code, module, tab, permission, title, label, key)
select x.code, 'docgen', x.tab, null, x.title, 'Document Generator', 'docgen'
  from (values ('docgen.done', 'done', 'Done'), ('docgen.notyet', 'notyet', 'Not Yet')) x(code, tab, title)
 where not exists(select 1 from rc_private.tab_catalog c where c.code = x.code);
update rc_private.tab_catalog set title = 'Not Yet' where code = 'docgen.notyet' and title is distinct from 'Not Yet';
-- Dev: tab lama Toko Lunas / Tanda Terima. Centang akun pindah ke Done, lalu tabnya dihapus.
insert into rc_private.user_tab_access(user_id, tab_code, allowed)
select u.user_id, 'docgen.done', u.allowed from rc_private.user_tab_access u
 where u.tab_code = 'docgen.verifikasi'
   and not exists(select 1 from rc_private.user_tab_access v where v.user_id = u.user_id and v.tab_code = 'docgen.done');
delete from rc_private.user_tab_access where tab_code = 'docgen.verifikasi';
delete from rc_private.tab_catalog where code = 'docgen.verifikasi';

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure), E'\r', '');
  if src ~ 'docgen\.done' then raise notice 'tab_rights sudah ditambal.';
  elsif src ~ 'docgen\.verifikasi' then
    -- Dev: versi 20261163190000.
    src := pg_temp.ganti(src, $p$(t.code in ('docgen.verifikasi','docgen.notyet') and p.role<>'admin') /* 20261163190000: bawaan tercentang hanya untuk Admin Depot */$p$,
      $p$(t.code in ('docgen.done','docgen.notyet') and p.role<>'admin') /* 20261163190000, 20261163540000: bawaan tercentang hanya untuk Admin Depot */$p$, 1, 'tab_rights dev');
    execute src;
  else
    -- Prod, diukur 29 Oktober 2026.
    if md5(src) <> 'efab14f8d2340e470428a97cf6ce022c' then
      raise exception 'DITOLAK: tab_rights berbeda dari yang diukur (md5 %).', md5(src); end if;
    src := pg_temp.ganti(src, $p$or t.code='access.approval' /* 20261162180000: hanya bila dicentang */$p$,
      $p$or (t.code in ('docgen.done','docgen.notyet') and p.role<>'admin') /* 20261163540000: Document Generator bawaan tercentang hanya untuk Admin Depot */ or t.code='access.approval' /* 20261162180000: hanya bila dicentang */$p$, 1, 'tab_rights prod');
    execute src;
  end if;
end $tambal$;

-- ------------------------------------------------------------------------------------------
-- 5. Pemeriksaan diri
-- ------------------------------------------------------------------------------------------
do $cek$
declare e text := ''; src text := pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure);
begin
  if src !~ 'docgen\.done' or src ~ 'docgen\.verifikasi' then e := e || ' tab_rights;'; end if;
  if (select count(*) from rc_private.tab_catalog where module = 'docgen') <> 2
     or (select count(*) from rc_private.tab_catalog where code in ('docgen.done', 'docgen.notyet') and permission is null) <> 2 then
    e := e || ' katalog tab;'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.rc_form_verifikasi'::regclass) then e := e || ' RLS;'; end if;
  if has_table_privilege('authenticated', 'public.rc_form_verifikasi', 'select') then e := e || ' hak tabel;'; end if;
  if to_regprocedure('public.rc_docgen_list(text)') is not null or to_regprocedure('public.rc_docgen_generate(jsonb,text)') is not null then
    e := e || ' versi lama RPC;'; end if;
  if pg_get_functiondef('rc_private.docgen_klaim(text,uuid,uuid,date,date)'::regprocedure) ~ 'rc_clearing_offers' then e := e || ' masih lunas;'; end if;
  if rc_private.docgen_subyek_pajak('01.234.567.8-901.000') <> 'Badan' or rc_private.docgen_subyek_pajak('') <> 'Perorangan' then
    e := e || ' subyek pajak;'; end if;
  if rc_private.docgen_masalah_master(null) is null then e := e || ' master kosong;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
