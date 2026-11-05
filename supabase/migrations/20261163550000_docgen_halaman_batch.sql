-- ==========================================================================================
-- Document Generator: halaman dari server, saringan di server, dan saringan No Batch Clearing
-- ==========================================================================================
-- Pemilik, 29 Oktober 2026 (sesudah 20261163540000 di prod): "canceling statement due to
-- statement timeout. BUAT pagination, dan buat juga filter berdasarkan no batch clearing."
--
-- Penyebab: rc_docgen_list membentuk SELURUH toko sekaligus (prod: 11.105 toko Done dari 23.333
-- klaim) lengkap dengan daftar campaign-nya, dan label Jenis CB dihitung per klaim. Untuk System
-- Manager ±30 detik, melewati statement timeout (8 detik).
--
--   DAFTAR   rc_docgen_list(p_sumber, p_saring, p_hal, p_per, p_kunci_saja)
--            Satu halaman (bawaan 100 toko) diurut depot lalu kode toko, ditambah total hasil
--            saringan, kartu KPI, dan pilihan saringan (depot, campaign, batch). Seluruh saringan
--            dijalankan server:
--              klaim (ikut menentukan isi form, hanya tab Done): dari, sampai (Tgl Done, WIB),
--                     batch (No Batch Clearing, sama persis)
--              toko  (hanya menyaring daftar): depot (kode), campaign (kode), unduh
--                     (belum/sudah/berubah), master (siap/kurang), cari (teks)
--            p_kunci_saja = true mengembalikan kunci toko siap cetak dari seluruh hasil saringan
--            (maks. 5.000) untuk "Pilih semua hasil filter".
--   UNDUH    rc_docgen_generate(p_toko, p_sumber, p_saring): saringan klaim yang sama; klaim tiap
--            toko dibaca lewat indeks customer, bukan memindai seluruh klaim per toko.
--   JEJAK    rc_form_verifikasi.batch_clearing menyimpan saringan batch saat unduh.
--   LABEL    Jenis CB dihitung sekali per jenis berbeda, bukan per klaim.
-- ==========================================================================================

do $prasyarat$
begin
  if to_regprocedure('public.rc_docgen_generate(jsonb,text,date,date)') is null and to_regprocedure('public.rc_docgen_generate(jsonb,text,jsonb)') is null then
    raise exception 'DITOLAK: jalankan 20261163540000 (Document Generator Done / Not Yet) lebih dulu.';
  end if;
end $prasyarat$;

alter table public.rc_form_verifikasi add column if not exists batch_clearing text;

-- ------------------------------------------------------------------------------------------
-- 1. Saringan klaim dan sumber klaim
-- ------------------------------------------------------------------------------------------
-- Membaca saringan klaim dari jsonb; menolak yang tidak sah. Mengembalikan (dari, sampai, batch).
create or replace function rc_private.docgen_saring_klaim(p_sumber text, p_saring jsonb, out dari date, out sampai date, out batch text)
language plpgsql stable set search_path = '' as $f$
begin
  if p_saring is not null and jsonb_typeof(p_saring) <> 'object' then raise exception 'Saringan tidak valid'; end if;
  begin
    dari := nullif(btrim(coalesce(p_saring->>'dari', '')), '')::date;
    sampai := nullif(btrim(coalesce(p_saring->>'sampai', '')), '')::date;
  exception when others then raise exception 'Tgl Done tidak valid'; end;
  batch := nullif(btrim(coalesce(p_saring->>'batch', '')), '');
  if p_sumber <> 'done' and (dari is not null or sampai is not null or batch is not null) then
    raise exception 'Saringan Tgl Done dan No Batch Clearing hanya untuk tab Done';
  end if;
  if dari > sampai then raise exception 'Tgl Done "dari" melewati "sampai"'; end if;
end $f$;

-- Keterangan saringan klaim untuk form, jejak, dan log. '' bila tanpa saringan.
create or replace function rc_private.docgen_keterangan(p_dari date, p_sampai date, p_batch text) returns text
language sql immutable set search_path = '' as $f$
  select concat_ws(', ',
    case when p_dari is not null or p_sampai is not null
         then 'Tgl Done ' || coalesce(to_char(p_dari, 'DD-Mon-YYYY'), 'awal') || ' s.d. ' || coalesce(to_char(p_sampai, 'DD-Mon-YYYY'), 'sekarang') end,
    case when p_batch is not null then 'Batch Clearing ' || p_batch end);
$f$;

drop function if exists rc_private.docgen_klaim(text, uuid, uuid, date, date);
drop function if exists rc_private.docgen_klaim(text, jsonb, jsonb);
-- Klaim yang masuk form menurut tab dan saringan klaim, di dalam jangkauan depot pemanggil.
-- p_toko null = seluruh toko; p_toko = [{depotId, customerId}] atau [{depotId, kode}] (klaim tanpa
-- Customer Master, kode toko sumber) = hanya toko itu, dibaca lewat indeks.
create function rc_private.docgen_klaim(p_sumber text, p_saring jsonb default '{}', p_toko jsonb default null)
returns table(claim_id uuid, depot_id uuid, customer_id uuid, kode_sumber text, kunci text, campaign_id uuid, cb_net numeric,
              tgl_done date, batch_clearing text, jenis_cb text)
language plpgsql stable security definer set search_path = '' as $f$
declare s record; l record;
begin
  if p_sumber not in ('done', 'notyet') then raise exception 'Sumber form tidak dikenal: %', p_sumber; end if;
  select * into s from rc_private.docgen_saring_klaim(p_sumber, p_saring);
  select x.semua, x.depot into l from rc_private.lingkup_depot_saya() x limit 1;
  return query
  with b as materialized (
    select c.id, c.depot_id, c.customer_id, upper(btrim(coalesce(c.source_customer_code, ''))) kode, c.campaign_id, coalesce(c.cb_net, 0) cb,
           (c.cleared_at at time zone 'Asia/Jakarta')::date tgl, nullif(btrim(c.batch_clearing), '') bc,
           coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type) jenis_raw
      from public.claims c
      join public.campaigns ca on ca.id = c.campaign_id
     where c.archived_at is null
       and (p_toko is null
            or c.customer_id in (select (e->>'customerId')::uuid from jsonb_array_elements(p_toko) e where nullif(e->>'customerId', '') is not null)
            or (c.customer_id is null and upper(btrim(coalesce(c.source_customer_code, ''))) in (select upper(btrim(coalesce(e->>'kode', ''))) from jsonb_array_elements(p_toko) e
                                                                                    where nullif(e->>'customerId', '') is null)))
       and ((p_sumber = 'done' and c.status = 'done'
             and (s.dari is null or (c.cleared_at at time zone 'Asia/Jakarta')::date >= s.dari)
             and (s.sampai is null or (c.cleared_at at time zone 'Asia/Jakarta')::date <= s.sampai)
             and (s.batch is null or btrim(c.batch_clearing) = s.batch))
         or (p_sumber = 'notyet' and c.status = 'not_yet' and c.pending_approval is null))
       and (coalesce(l.semua, false) or c.depot_id = any(coalesce(l.depot, '{}'::uuid[])))
       and (p_toko is null or exists(select 1 from jsonb_array_elements(p_toko) e
                                       where (e->>'depotId')::uuid = c.depot_id
                                         and (case when nullif(e->>'customerId', '') is null
                                                   then c.customer_id is null and upper(btrim(coalesce(c.source_customer_code, ''))) = upper(btrim(coalesce(e->>'kode', '')))
                                                   else c.customer_id = (e->>'customerId')::uuid end)))),
  lbl as (select r.jenis_raw, coalesce(nullif(rc_private.cb_label(r.jenis_raw), ''), '-') label from (select distinct b.jenis_raw from b) r)
  select b.id, b.depot_id, b.customer_id, b.kode, coalesce(b.customer_id::text, 'kode:' || b.kode), b.campaign_id, b.cb, b.tgl, b.bc, lbl.label
    from b join lbl on lbl.jenis_raw is not distinct from b.jenis_raw;
end $f$;

revoke all on function rc_private.docgen_saring_klaim(text, jsonb), rc_private.docgen_keterangan(date, date, text),
  rc_private.docgen_klaim(text, jsonb, jsonb) from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Daftar (satu halaman)
-- ------------------------------------------------------------------------------------------
-- Ringkasan per toko dibuat ramping (tanpa daftar campaign), lalu daftar campaign hanya dibaca
-- untuk toko di halaman yang diminta - membawa daftar campaign seluruh toko melewati setiap
-- langkah itulah yang membuat versi sebelumnya lambat.
drop function if exists public.rc_docgen_list(text, date, date);
drop function if exists public.rc_docgen_list(text, jsonb, integer, integer, boolean);
create function public.rc_docgen_list(p_sumber text default 'done', p_saring jsonb default '{}', p_hal integer default 0,
                                      p_per integer default 100, p_kunci_saja boolean default false) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare
  sk record; v_sar jsonb := coalesce(p_saring, '{}'::jsonb); v_klaim jsonb;
  v_depot text := nullif(btrim(coalesce(v_sar->>'depot', '')), ''); v_camp text := nullif(btrim(coalesce(v_sar->>'campaign', '')), '');
  v_unduh text := nullif(btrim(coalesce(v_sar->>'unduh', '')), ''); v_master text := nullif(btrim(coalesce(v_sar->>'master', '')), '');
  v_cari text := lower(nullif(btrim(coalesce(v_sar->>'cari', '')), ''));
  v_per integer := least(greatest(coalesce(p_per, 100), 10), 500); v_hal integer := greatest(coalesce(p_hal, 0), 0);
  v jsonb; v_rows jsonb; v_toko jsonb; v_camp_map jsonb;
begin
  perform rc_private.require_tab(rc_private.docgen_tab(p_sumber));
  select * into sk from rc_private.docgen_saring_klaim(p_sumber, v_sar);
  if v_unduh is not null and v_unduh not in ('belum', 'sudah', 'berubah') then raise exception 'Saringan Status Unduh tidak dikenal'; end if;
  if v_master is not null and v_master not in ('siap', 'kurang') then raise exception 'Saringan Customer Master tidak dikenal'; end if;
  -- Hanya saringan klaim yang diteruskan ke sumber klaim.
  v_klaim := jsonb_strip_nulls(jsonb_build_object('dari', sk.dari, 'sampai', sk.sampai, 'batch', sk.batch));

  with k as materialized (select * from rc_private.docgen_klaim(p_sumber, v_klaim)),
  pc as materialized (select k.depot_id, k.kunci, k.campaign_id, k.jenis_cb, trunc(sum(k.cb_net)) cb from k group by 1, 2, 3, 4),
  tc as (
    select p.depot_id, p.kunci, sum(p.cb) total, count(distinct p.campaign_id) n_campaign, count(*) n_baris,
           array_agg(distinct ca.campaign_code) kode_campaign, array_agg(distinct p.jenis_cb) jenis
      from pc p join public.campaigns ca on ca.id = p.campaign_id group by 1, 2),
  t as (
    select k.depot_id, k.kunci, (array_agg(k.customer_id))[1] customer_id, min(k.kode_sumber) kode_sumber,
           array_agg(k.claim_id order by k.claim_id) ids, count(*) n_klaim, min(k.tgl_done) done_awal, max(k.tgl_done) done_akhir
      from k group by 1, 2),
  s as materialized (
    select t.depot_id, t.customer_id, t.kode_sumber, t.n_klaim, t.done_awal, t.done_akhir,
           tc.total, tc.n_campaign, tc.n_baris, tc.kode_campaign, tc.jenis,
           d.depot_code, coalesce(nullif(d.depot_name, ''), d.depot_code) depot_nama,
           coalesce(cu.customer_code, t.kode_sumber) kode, coalesce(cu.customer_name, '') nama, coalesce(cu.contact_person, '') pemilik,
           coalesce(btrim(cu.sales_name), '') sales, case when cu.id is null then '' else rc_private.docgen_subyek_pajak(cu.npwp) end subyek,
           coalesce(btrim(cu.bank), '') bank, coalesce(btrim(cu.account_number), '') no_rek, coalesce(btrim(cu.account_name), '') atas_nama,
           -- Sama dengan rc_private.docgen_masalah_master, ditulis langsung supaya tidak dipanggil per toko.
           case when cu.id is null then 'Customer Master tidak ditemukan'
                when cu.archived_at is not null then 'Customer Master diarsip'
                else nullif(concat_ws('; ',
                  case when btrim(coalesce(cu.customer_name, '')) = '' then 'Nama Toko kosong' end,
                  case when btrim(coalesce(cu.contact_person, '')) = '' then 'Nama Pemilik (Contact Person) kosong' end,
                  case when regexp_replace(coalesce(cu.npwp, ''), '\D', '', 'g') = '' and regexp_replace(coalesce(cu.ktp, ''), '\D', '', 'g') = ''
                       then 'KTP / NPWP kosong (Subyek Pajak tidak dapat ditentukan)' end), '') end masalah,
           f.no_form, f.created_at f_pada, coalesce(nullif(pf.full_name, ''), pf.user_code, '-') f_oleh, coalesce(fn.n, 0) n_unduh,
           -- Klaim atau nilainya berubah sejak unduh terakhir di tab ini (mis. Amend Doc, klaim baru Done).
           (f.no_form is not null and (not (f.claim_ids @> t.ids and t.ids @> f.claim_ids) or f.total <> tc.total)) berubah
      from t
      join tc on tc.depot_id = t.depot_id and tc.kunci = t.kunci
      join public.depots d on d.id = t.depot_id
      left join public.customers cu on cu.id = t.customer_id
      left join lateral (select x.no_form, x.created_at, x.created_by, x.claim_ids, x.total from public.rc_form_verifikasi x
                          where t.customer_id is not null and x.depot_id = t.depot_id and x.customer_id = t.customer_id and x.sumber = p_sumber and x.claim_ids && t.ids
                          order by x.created_at desc, x.urut desc limit 1) f on true
      left join public.profiles pf on pf.id = f.created_by
      left join lateral (select count(*) n from public.rc_form_verifikasi x
                          where f.no_form is not null and x.depot_id = t.depot_id and x.customer_id = t.customer_id and x.sumber = p_sumber and x.claim_ids && t.ids) fn on true),
  q as materialized (
    select s.* from s
     where (v_depot is null or s.depot_code = v_depot)
       and (v_camp is null or v_camp = any(s.kode_campaign))
       and (v_unduh is null or (v_unduh = 'belum' and s.no_form is null) or (v_unduh = 'sudah' and s.no_form is not null) or (v_unduh = 'berubah' and s.berubah))
       and (v_master is null or (v_master = 'siap') = (s.masalah is null))
       and (v_cari is null or position(v_cari in lower(concat_ws(' ', s.kode, s.nama, s.pemilik, s.sales, s.bank, s.no_rek, s.atas_nama, s.depot_code, s.depot_nama,
                                                                  s.no_form, array_to_string(s.jenis, ' ')))) > 0))
  select case when p_kunci_saja then
      jsonb_build_object('status', 'success', 'sumber', p_sumber,
        'kunci', coalesce((select jsonb_agg(jsonb_build_object('depotId', z.depot_id, 'customerId', z.customer_id) order by z.depot_code, z.kode)
                             from (select * from q where q.masalah is null order by q.depot_code, q.kode limit 5000) z), '[]'::jsonb),
        'lebih', (select count(*) from q where q.masalah is null) > 5000)
    else jsonb_build_object('status', 'success', 'sumber', p_sumber, 'hal', v_hal, 'per', v_per,
      'total', (select count(*) from q),
      'saringan', rc_private.docgen_keterangan(sk.dari, sk.sampai, sk.batch),
      'kpi', (select jsonb_build_object('toko', count(*), 'siap', count(*) filter (where s.masalah is null),
                                        'kurang', count(*) filter (where s.masalah is not null),
                                        'belumUnduh', count(*) filter (where s.masalah is null and s.no_form is null)) from s),
      'opsi', jsonb_build_object(
        'depot', coalesce((select jsonb_agg(jsonb_build_object('kode', x.depot_code, 'nama', x.depot_nama) order by x.depot_code)
                             from (select distinct s.depot_code, s.depot_nama from s) x), '[]'::jsonb),
        'campaign', coalesce((select jsonb_agg(jsonb_build_object('kode', ca.campaign_code, 'nama', ca.campaign_name) order by ca.campaign_code)
                                from public.campaigns ca where ca.id in (select distinct pc.campaign_id from pc)), '[]'::jsonb)),
      'rows', coalesce((select jsonb_agg(jsonb_build_object(
             'depotId', h.depot_id, 'depotKode', h.depot_code, 'depotNama', h.depot_nama,
             'customerId', h.customer_id, 'kode', h.kode, 'kodeSumber', h.kode_sumber, 'nama', h.nama, 'pemilik', h.pemilik, 'sales', h.sales, 'subyekPajak', h.subyek,
             'bank', h.bank, 'noRek', h.no_rek, 'atasNama', h.atas_nama,
             'jumlahKlaim', h.n_klaim, 'jumlahCampaign', h.n_campaign, 'totalNetCb', h.total,
             'jenisCb', to_jsonb(h.jenis), 'halaman', ceil(h.n_baris / 4.0)::integer,
             'tglDone', case when h.done_awal is null then ''
                             when h.done_awal = h.done_akhir then to_char(h.done_awal, 'DD-Mon-YYYY')
                             else to_char(h.done_awal, 'DD-Mon-YYYY') || ' s.d. ' || to_char(h.done_akhir, 'DD-Mon-YYYY') end,
             'masalahMaster', h.masalah, 'siap', h.masalah is null,
             'unduh', case when h.no_form is null then null else jsonb_build_object('noForm', h.no_form,
                        'pada', to_char(h.f_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), 'oleh', h.f_oleh) end,
             'jumlahUnduh', h.n_unduh, 'berubah', h.berubah) order by h.depot_code, h.kode)
          from (select * from q order by q.depot_code, q.kode limit v_per offset v_hal * v_per) h), '[]'::jsonb))
    end into v;
  if p_kunci_saja then return v; end if;

  -- Daftar campaign hanya untuk toko di halaman ini (lewat indeks, bukan dari seluruh klaim).
  v_rows := v->'rows';
  if jsonb_array_length(v_rows) > 0 then
    v_toko := (select jsonb_agg(case when r->>'customerId' is null then jsonb_build_object('depotId', r->>'depotId', 'kode', r->>'kodeSumber')
                                     else jsonb_build_object('depotId', r->>'depotId', 'customerId', r->>'customerId') end)
                 from jsonb_array_elements(v_rows) r);
    select jsonb_object_agg(z.kunci, z.campaigns) into v_camp_map
      from (select p.depot_id::text || '|' || p.kunci kunci,
                   jsonb_agg(jsonb_build_object('id', ca.id, 'kode', ca.campaign_code, 'nama', ca.campaign_name, 'jenisCb', p.jenis_cb)
                             order by ca.campaign_code, p.jenis_cb) campaigns
              from (select distinct k.depot_id, k.kunci, k.campaign_id, k.jenis_cb from rc_private.docgen_klaim(p_sumber, v_klaim, v_toko) k) p
              join public.campaigns ca on ca.id = p.campaign_id group by 1) z;
    v := jsonb_set(v, '{rows}', (select jsonb_agg((r - 'kodeSumber') || jsonb_build_object('campaigns',
                                          coalesce(v_camp_map->((r->>'depotId') || '|' || coalesce(r->>'customerId', 'kode:' || (r->>'kodeSumber'))), '[]'::jsonb))
                                          order by o)
                                   from jsonb_array_elements(v_rows) with ordinality x(r, o)));
  end if;

  -- Pilihan No Batch Clearing: batch klaim Done dalam jangkauan, terbaru dulu (tidak ikut saringan).
  if p_sumber = 'done' then
    v := jsonb_set(v, '{opsi,batch}', coalesce((
      select jsonb_agg(x.bc order by x.terakhir desc nulls last, x.bc desc)
        from (select btrim(c.batch_clearing) bc, max(c.cleared_at) terakhir
                from public.claims c cross join rc_private.lingkup_depot_saya() l
               where c.status = 'done' and c.archived_at is null and nullif(btrim(c.batch_clearing), '') is not null
                 and (l.semua or c.depot_id = any(l.depot))
               group by 1) x), '[]'::jsonb));
  end if;
  return v;
end $f$;

-- ------------------------------------------------------------------------------------------
-- 3. Unduh
-- ------------------------------------------------------------------------------------------
drop function if exists public.rc_docgen_generate(jsonb, text, date, date);
drop function if exists public.rc_docgen_generate(jsonb, text, jsonb);
create function public.rc_docgen_generate(p_toko jsonb, p_sumber text default 'done', p_saring jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_proses uuid := gen_random_uuid();
  r record; v_forms jsonb := '[]'; v_gagal jsonb := '[]'; v_rows jsonb; v_ids uuid[]; v_total numeric; v_n integer;
  v_urut integer; v_no text; v_masalah text; v_nomor text[] := '{}'; v_depot text[] := '{}';
  v_tab text := rc_private.docgen_tab(p_sumber);
  v_judul text := case when p_sumber = 'notyet' then 'Not Yet' else 'Done' end;
  sk record; v_ket text; v_sar jsonb; v_isi jsonb; v_satu_isi jsonb;
begin
  perform rc_private.require_tab(v_tab);
  select * into sk from rc_private.docgen_saring_klaim(p_sumber, coalesce(p_saring, '{}'::jsonb));
  -- Hanya saringan klaim yang menentukan isi form.
  v_sar := jsonb_strip_nulls(jsonb_build_object('dari', sk.dari, 'sampai', sk.sampai, 'batch', sk.batch));
  v_ket := rc_private.docgen_keterangan(sk.dari, sk.sampai, sk.batch);
  if jsonb_typeof(p_toko) is distinct from 'array' or jsonb_array_length(p_toko) = 0 then raise exception 'Pilih toko lebih dulu'; end if;
  if jsonb_array_length(p_toko) > 500 then raise exception 'Maksimal 500 toko sekali unduh'; end if;
  begin
    perform (e->>'depotId')::uuid, (e->>'customerId')::uuid from jsonb_array_elements(p_toko) e;
  exception when invalid_text_representation then raise exception 'Data toko tidak valid'; end;

  -- Isi form seluruh toko terpilih dalam satu bacaan (per toko: baris campaign x Jenis CB, total,
  -- dan klaimnya). docgen_klaim sudah membatasi jangkauan depot pemanggil.
  with gk as materialized (select * from rc_private.docgen_klaim(p_sumber, v_sar, p_toko) x where x.customer_id is not null),
  gp as (select gk.depot_id, gk.customer_id, gk.campaign_id, gk.jenis_cb, trunc(sum(gk.cb_net)) cb from gk group by 1, 2, 3, 4),
  gr as (select gp.depot_id, gp.customer_id, sum(gp.cb) total, count(*) n,
                jsonb_agg(jsonb_build_object('kode', ca.campaign_code, 'nama', ca.campaign_name, 'jenisCb', gp.jenis_cb, 'netCb', gp.cb,
                                             'taxStatus', coalesce(ca.tax_status, '')) order by ca.campaign_code, gp.jenis_cb) baris
           from gp join public.campaigns ca on ca.id = gp.campaign_id group by 1, 2),
  gi as (select gk.depot_id, gk.customer_id, array_agg(gk.claim_id order by gk.claim_id) ids from gk group by 1, 2)
  select coalesce(jsonb_object_agg(gr.depot_id::text || '|' || gr.customer_id::text,
                                   jsonb_build_object('rows', gr.baris, 'total', gr.total, 'n', gr.n, 'ids', to_jsonb(gi.ids))), '{}'::jsonb)
    into v_isi
    from gr join gi on gi.depot_id = gr.depot_id and gi.customer_id = gr.customer_id;

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

    v_satu_isi := v_isi->(r.depot_id::text || '|' || r.customer_id::text);
    v_rows := coalesce(v_satu_isi->'rows', '[]'::jsonb); v_total := coalesce((v_satu_isi->>'total')::numeric, 0);
    v_n := coalesce((v_satu_isi->>'n')::integer, 0);
    if v_n = 0 then
      v_gagal := v_gagal || jsonb_build_object('depotKode', r.depot_code, 'kode', r.customer_code, 'nama', coalesce(r.customer_name, ''),
                   'alasan', case when p_sumber = 'notyet' then 'Tidak ada klaim Not Yet (sudah diajukan atau diproses)'
                                  else 'Tidak ada klaim Done' || case when v_ket <> '' then ' pada ' || v_ket else '' end end);
      continue;
    end if;
    select array_agg(x::uuid order by x::uuid) into v_ids from jsonb_array_elements_text(v_satu_isi->'ids') x;

    -- Nomor urut per depot per hari (satu deret untuk kedua tab); kunci transaksi mencegah dua
    -- unduhan bersamaan memakai nomor yang sama.
    perform pg_advisory_xact_lock(hashtextextended('rc_form_verifikasi:' || r.depot_id::text || ':' || v_hari::text, 0));
    select coalesce(max(f.urut), 0) + 1 into v_urut from public.rc_form_verifikasi f where f.depot_id = r.depot_id and f.tanggal = v_hari;
    v_no := 'TT-' || r.abbr || '-' || to_char(v_hari, 'DDMMYY') || '-' || lpad(v_urut::text, 3, '0');
    insert into public.rc_form_verifikasi(no_form, depot_id, customer_id, tanggal, urut, halaman, claim_ids, total, proses_id, created_by, sumber,
                                          periode_dari, periode_sampai, batch_clearing)
    values (v_no, r.depot_id, r.customer_id, v_hari, v_urut, ceil(v_n / 4.0)::integer, v_ids, v_total, v_proses, auth.uid(), p_sumber,
            sk.dari, sk.sampai, sk.batch);

    v_nomor := v_nomor || v_no;
    if not (r.depot_code = any(v_depot)) then v_depot := v_depot || r.depot_code; end if;
    v_forms := v_forms || jsonb_build_object('noForm', v_no, 'dicetak', to_char(v_hari, 'DD-Mon-YYYY'), 'sumber', p_sumber, 'saringan', v_ket,
      'depot', jsonb_build_object('kode', r.depot_code, 'nama', r.depot_nama),
      'toko', jsonb_build_object('kode', r.customer_code, 'nama', r.customer_name, 'pemilik', r.contact_person,
                                 'subyekPajak', rc_private.docgen_subyek_pajak(r.npwp), 'sales', r.sales),
      'rekening', jsonb_build_object('bank', r.bank, 'noRek', r.no_rek, 'atasNama', r.atas_nama),
      'campaigns', v_rows, 'total', v_total, 'halaman', ceil(v_n / 4.0)::integer, 'jumlahKlaim', cardinality(v_ids));
  end loop;

  if jsonb_array_length(v_forms) > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'docgen_verifikasi',
      jsonb_build_object('detail', 'Document Generator (' || v_judul || case when v_ket <> '' then ', ' || v_ket else '' end || '): '
                                     || jsonb_array_length(v_forms) || ' tanda terima ('
                                     || v_nomor[1] || case when cardinality(v_nomor) > 1 then ' s.d. ' || v_nomor[cardinality(v_nomor)] else '' end || ')'
                                     || case when jsonb_array_length(v_gagal) > 0 then '; ' || jsonb_array_length(v_gagal) || ' toko gagal' else '' end,
                         'jumlah', jsonb_array_length(v_forms), 'gagal', jsonb_array_length(v_gagal), 'nomor', to_jsonb(v_nomor),
                         'depot', to_jsonb(v_depot), 'proses', v_proses, 'sumber', p_sumber,
                         'dari', sk.dari, 'sampai', sk.sampai, 'batch', sk.batch),
      'docgen', split_part(v_tab, '.', 2), split_part(v_tab, '.', 2));
  end if;

  return jsonb_build_object('status', 'success', 'forms', v_forms, 'gagal', v_gagal,
    'message', jsonb_array_length(v_forms) || ' tanda terima dibuat'
      || case when jsonb_array_length(v_gagal) > 0 then '; ' || jsonb_array_length(v_gagal) || ' toko tidak dapat dibuatkan' else '' end || '.');
end $f$;

revoke all on function public.rc_docgen_list(text, jsonb, integer, integer, boolean), public.rc_docgen_generate(jsonb, text, jsonb) from public, anon;
grant execute on function public.rc_docgen_list(text, jsonb, integer, integer, boolean), public.rc_docgen_generate(jsonb, text, jsonb) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Pemeriksaan diri
-- ------------------------------------------------------------------------------------------
do $cek$
declare e text := '';
begin
  if to_regprocedure('public.rc_docgen_list(text,date,date)') is not null or to_regprocedure('public.rc_docgen_generate(jsonb,text,date,date)') is not null then
    e := e || ' versi lama RPC;'; end if;
  if rc_private.docgen_keterangan(date '2026-10-01', date '2026-10-31', 'B1') <> 'Tgl Done 01-Oct-2026 s.d. 31-Oct-2026, Batch Clearing B1'
     or rc_private.docgen_keterangan(null, null, null) <> '' then e := e || ' keterangan;'; end if;
  if (rc_private.docgen_saring_klaim('done', '{"batch":" B1 "}')).batch <> 'B1' then e := e || ' saringan batch;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
