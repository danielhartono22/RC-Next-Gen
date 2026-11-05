-- ==========================================================================================
-- Uji Document Generator (Tanda Terima, tab Done dan Not Yet) - 20261163190000, 20261163520000,
-- 20261163540000, 20261163550000 (halaman dan saringan di server, No Batch Clearing)
-- ==========================================================================================
-- Fixture memakai klaim Done dan Not Yet yang sudah ada. Seluruh uji berjalan di subtransaksi
-- yang DIBATALKAN (UJI_SELESAI): nomor form, isi Customer Master yang diubah, centang tab, dan
-- jangkauan depot akun uji ikut dibatalkan. Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_document_generator.sql
-- ==========================================================================================
create temp table if not exists _hasil_dg(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_dg;

create or replace function pg_temp.dg_sebagai(p_user uuid) returns void language sql as $f$
  select set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
$f$;
-- Baris satu toko di daftar: dicari lewat saringan teks (kode toko), lalu dicocokkan customer-nya.
create or replace function pg_temp.dg_baris(p_sumber text, p_saring jsonb, p_customer uuid) returns jsonb language sql as $f$
  select x from jsonb_array_elements(public.rc_docgen_list(p_sumber,
           p_saring || jsonb_build_object('cari', (select customer_code from public.customers where id = p_customer)), 0, 500)->'rows') x
   where (x->>'customerId')::uuid = p_customer limit 1;
$f$;

do $uji$
declare v_sm uuid; v_adm uuid; v_osc uuid; hasil jsonb := '[]'; r jsonb; r2 jsonb; v_galat text; v_txt text; v_tabs jsonb; n integer; m integer;
  t1 record; t2 record; t3 record; n1 record; v_row jsonb; v_form jsonb; v_log0 integer; v_hari text := to_char((now() at time zone 'Asia/Jakarta')::date, 'DDMMYY');
  v_abbr text; v_npwp text; v_tgl date; v_no1 text; v_batch text; v_camp text; v_t3depot text; t0 timestamptz;
  v_kat_n integer; v_no_akhir text; -- 20261163700000: toko t1 bisa 1 atau 2 form (PDA / PDH)
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select id into v_adm from public.profiles where role = 'admin' and status = 'active' and not must_change_password order by user_code limit 1;
  select id into v_osc from public.profiles where role in ('osc', 'finance', 'others') and status = 'active' and not must_change_password order by user_code limit 1;

  -- t1 = toko Done (ada Tgl Done dan No Batch Clearing) dengan campaign terbanyak di depot yang juga
  -- punya >= 2 toko Not Yet bermaster; t2 = toko Done lain di depot itu; t3 = toko Done di depot lain;
  -- n1 = toko Not Yet di depot t1.
  select z.depot_id, z.customer_id, z.n into t1 from (
    select c.depot_id, c.customer_id, count(distinct c.campaign_id) n from public.claims c
     where c.status = 'done' and c.archived_at is null and c.customer_id is not null
       and c.depot_id in (select x.depot_id from public.claims x where x.status = 'not_yet' and x.pending_approval is null and x.archived_at is null
                            and x.customer_id is not null group by 1 having count(distinct x.customer_id) >= 2)
     group by 1, 2 having count(*) filter (where c.cleared_at is not null and nullif(btrim(c.batch_clearing), '') is not null) > 0
     order by 3 desc, 1, 2 limit 1) z;
  select c.depot_id, c.customer_id into t2 from public.claims c
   where c.status = 'done' and c.archived_at is null and c.depot_id = t1.depot_id and c.customer_id <> t1.customer_id order by c.customer_id limit 1;
  select c.depot_id, c.customer_id into t3 from public.claims c
   where c.status = 'done' and c.archived_at is null and c.depot_id <> t1.depot_id and c.customer_id is not null order by c.depot_id, c.customer_id limit 1;
  select c.depot_id, c.customer_id into n1 from public.claims c
   where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null and c.depot_id = t1.depot_id and c.customer_id is not null
     and c.customer_id not in (t1.customer_id, t2.customer_id) order by c.customer_id limit 1;
  select upper(coalesce(nullif(btrim(abbr), ''), depot_code)) into v_abbr from public.depots where id = t1.depot_id;
  select depot_code into v_t3depot from public.depots where id = t3.depot_id;
  select btrim(c.batch_clearing) into v_batch from public.claims c where c.status = 'done' and c.archived_at is null and c.depot_id = t1.depot_id
     and c.customer_id = t1.customer_id and nullif(btrim(c.batch_clearing), '') is not null order by c.cleared_at desc nulls last limit 1;

  begin
    if t1.customer_id is null or t2.customer_id is null or t3.customer_id is null or n1.customer_id is null then raise exception 'Fixture: klaim Done / Not Yet tidak cukup'; end if;
    -- Admin depot uji hanya menjangkau depot t1; tab Document Generator mengikuti bawaannya.
    delete from public.user_depot_access where user_id = v_adm;
    insert into public.user_depot_access(user_id, depot_id) values (v_adm, t1.depot_id);
    delete from rc_private.user_tab_access where user_id in (v_adm, v_osc) and tab_code like 'docgen.%';
    -- t1, t3, n1 lengkap (Contact Person + NPWP); t2 tanpa Contact Person.
    update public.customers set contact_person = 'Pemilik Uji DG', sales_name = 'Sales Uji DG', npwp = coalesce(nullif(npwp, ''), '01.234.567.8-901.000')
     where id in (t1.customer_id, t3.customer_id, n1.customer_id);
    update public.customers set contact_person = null where id = t2.customer_id;
    select npwp into v_npwp from public.customers where id = t1.customer_id;

    -- ---- Katalog dan hak tab ---------------------------------------------------------
    hasil := hasil || jsonb_build_object('uji', 'Tab Document Generator: Done saja (Toko Lunas dihapus; Not Yet ditiadakan 20261163690000)',
      'lulus', (select string_agg(code || '=' || title, ',' order by code) from rc_private.tab_catalog where module = 'docgen') = 'docgen.done=Done'
           and not exists (select 1 from rc_private.user_tab_access where tab_code = 'docgen.notyet'),
      'rinci', (select string_agg(code || '=' || title, ',' order by code) from rc_private.tab_catalog where module = 'docgen'));
    hasil := hasil || jsonb_build_object('uji', 'Sumber klaim tidak lagi memakai tawaran lunas',
      'lulus', pg_get_functiondef('rc_private.docgen_klaim(text,jsonb,jsonb)'::regprocedure) !~ 'rc_clearing_offers', 'rinci', '-');
    perform pg_temp.dg_sebagai(v_adm);
    v_tabs := rc_private.tab_rights(v_adm);
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot: tab Done bawaan tercentang; tab Not Yet tidak ada lagi',
      'lulus', (v_tabs->>'docgen.done')::boolean and not (v_tabs ? 'docgen.notyet'), 'rinci', (v_tabs->>'docgen.done') || '/' || coalesce(v_tabs->>'docgen.notyet', 'tidak ada'));
    perform pg_temp.dg_sebagai(v_osc);
    v_tabs := rc_private.tab_rights(v_osc);
    hasil := hasil || jsonb_build_object('uji', 'Peran lain: bawaan tidak tercentang',
      'lulus', not (v_tabs->>'docgen.done')::boolean and not (v_tabs ? 'docgen.notyet'), 'rinci', (v_tabs->>'docgen.done') || '/' || coalesce(v_tabs->>'docgen.notyet', 'tidak ada'));
    begin perform public.rc_docgen_list(); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Peran lain tanpa centang: daftar Done ditolak server', 'lulus', v_galat ~ 'docgen\.done', 'rinci', v_galat);
    insert into rc_private.user_tab_access values (v_osc, 'docgen.done', true);
    begin perform public.rc_docgen_list(); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Peran lain setelah Done dicentang: daftar Done dapat dibuka', 'lulus', v_galat = 'lolos', 'rinci', v_galat);
    begin perform public.rc_docgen_list('notyet'); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Not Yet ditolak server: tab sudah ditiadakan', 'lulus', v_galat ~ 'sudah ditiadakan', 'rinci', v_galat);
    insert into rc_private.user_tab_access values (v_adm, 'docgen.done', false);
    perform pg_temp.dg_sebagai(v_adm);
    begin perform public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', t1.depot_id, 'customerId', t1.customer_id))); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot yang tab Done-nya dimatikan: unduh ditolak server', 'lulus', v_galat ~ 'docgen\.done', 'rinci', v_galat);
    delete from rc_private.user_tab_access where user_id = v_adm and tab_code = 'docgen.done';

    -- ---- Daftar Done (Admin Depot, jangkauan depot t1) -------------------------------
    r := public.rc_docgen_list('done');
    select count(*) into n from (select coalesce(c.customer_id::text, c.source_customer_code) from public.claims c
       where c.status = 'done' and c.archived_at is null and c.depot_id = t1.depot_id group by 1) z;
    hasil := hasil || jsonb_build_object('uji', 'Done: total = seluruh toko Done di depot dalam jangkauan; halaman maks. 100; KPI toko = total',
      'lulus', (r->>'total')::int = n and jsonb_array_length(r->'rows') = least(n, 100) and (r->'kpi'->>'toko')::int = n
        and not exists(select 1 from jsonb_array_elements(r->'rows') x where (x->>'depotId')::uuid <> t1.depot_id),
      'rinci', (r->>'total') || ' vs ' || n || '; baris ' || jsonb_array_length(r->'rows'));
    hasil := hasil || jsonb_build_object('uji', 'Pilihan saringan: depot, campaign, dan No Batch Clearing dikirim',
      'lulus', jsonb_array_length(r->'opsi'->'depot') = 1 and jsonb_array_length(r->'opsi'->'campaign') > 0 and r->'opsi'->'batch' @> to_jsonb(array[v_batch]),
      'rinci', jsonb_array_length(r->'opsi'->'campaign') || ' campaign, ' || jsonb_array_length(r->'opsi'->'batch') || ' batch');
    select count(*) into m from (select c.campaign_id, rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) from public.claims c
       join public.campaigns ca on ca.id = c.campaign_id
      where c.status = 'done' and c.archived_at is null and c.depot_id = t1.depot_id and c.customer_id = t1.customer_id group by 1, 2) z;
    v_row := pg_temp.dg_baris('done', '{}', t1.customer_id);
    hasil := hasil || jsonb_build_object('uji', 'Toko lengkap: siap, Badan (NPWP), campaign, halaman, pemilik, sales, Tgl Done, daftar campaign',
      'lulus', (v_row->>'siap')::boolean and v_row->>'subyekPajak' = 'Badan' and (v_row->>'jumlahCampaign')::int = t1.n
               and (v_row->>'halaman')::int = ceil(m / 4.0)::int and v_row->>'pemilik' = 'Pemilik Uji DG' and v_row->>'sales' = 'Sales Uji DG'
               and v_row->>'tglDone' ~ '^\d{2}-[A-Z][a-z]{2}-\d{4}' and jsonb_array_length(v_row->'campaigns') = m and not (v_row ? 'kodeSumber'),
      'rinci', coalesce((v_row - 'campaigns')::text, 'tidak ditemukan'));
    v_camp := v_row->'campaigns'->0->>'kode';
    select sum(trunc(z.s)) into v_txt from (select sum(coalesce(c.cb_net, 0)) s from public.claims c join public.campaigns ca on ca.id = c.campaign_id
       where c.status = 'done' and c.archived_at is null and c.depot_id = t1.depot_id and c.customer_id = t1.customer_id
       group by c.campaign_id, rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type))) z;
    hasil := hasil || jsonb_build_object('uji', 'Total Net CB = jumlah per campaign per Jenis CB, dipotong tanpa desimal',
      'lulus', (v_row->>'totalNetCb')::numeric = v_txt::numeric and (v_row->>'totalNetCb')::numeric = trunc((v_row->>'totalNetCb')::numeric),
      'rinci', v_row->>'totalNetCb' || ' vs ' || v_txt);
    -- 20261163740000: rekening tidak lagi dikirim (diganti Bukti TF dari file bank).
    hasil := hasil || jsonb_build_object('uji', 'Daftar tidak mengirim KTP / NPWP maupun rekening',
      'lulus', position(v_npwp in r::text) = 0 and r::text !~ '"(ktp|npwp)"'
        and not exists(select 1 from jsonb_array_elements(r->'rows') x where x ? 'bank' or x ? 'noRek' or x ? 'atasNama'), 'rinci', '-');
    v_row := pg_temp.dg_baris('done', '{}', t2.customer_id);
    hasil := hasil || jsonb_build_object('uji', 'Toko tanpa Contact Person: tidak siap, alasannya disebut',
      'lulus', not (v_row->>'siap')::boolean and v_row->>'masalahMaster' ~ 'Contact Person', 'rinci', v_row->>'masalahMaster');

    -- ---- Halaman dan saringan toko ---------------------------------------------------
    r := public.rc_docgen_list('done', '{}', 0, 10); r2 := public.rc_docgen_list('done', '{}', 1, 10);
    hasil := hasil || jsonb_build_object('uji', 'Halaman: 10 per halaman, halaman 1 dan 2 berbeda, total sama',
      'lulus', (n <= 10 and jsonb_array_length(r2->'rows') = 0) or (jsonb_array_length(r->'rows') = 10 and r->>'total' = r2->>'total'
        and jsonb_array_length(r2->'rows') = least(n - 10, 10)
        and not exists(select 1 from jsonb_array_elements(r->'rows') a, jsonb_array_elements(r2->'rows') b where a->>'kode' = b->>'kode')),
      'rinci', jsonb_array_length(r->'rows') || ' + ' || jsonb_array_length(r2->'rows') || ' dari ' || (r->>'total'));
    hasil := hasil || jsonb_build_object('uji', 'Ukuran halaman dibatasi 10..500', 'lulus', (public.rc_docgen_list('done', '{}', 0, 9999)->>'per')::int = 500
      and (public.rc_docgen_list('done', '{}', 0, 1)->>'per')::int = 10, 'rinci', '-');
    r := public.rc_docgen_list('done', '{"master":"kurang"}', 0, 500);
    hasil := hasil || jsonb_build_object('uji', 'Saringan Customer Master "kurang": hanya toko belum lengkap, termasuk t2',
      'lulus', exists(select 1 from jsonb_array_elements(r->'rows') x where (x->>'customerId')::uuid = t2.customer_id)
        and not exists(select 1 from jsonb_array_elements(r->'rows') x where (x->>'siap')::boolean), 'rinci', r->>'total');
    r := public.rc_docgen_list('done', jsonb_build_object('campaign', v_camp), 0, 500);
    hasil := hasil || jsonb_build_object('uji', 'Saringan campaign: hanya toko yang punya campaign itu',
      'lulus', exists(select 1 from jsonb_array_elements(r->'rows') x where (x->>'customerId')::uuid = t1.customer_id)
        and not exists(select 1 from jsonb_array_elements(r->'rows') x where not (x->'campaigns' @> jsonb_build_array(jsonb_build_object('kode', v_camp)))),
      'rinci', v_camp || ': ' || (r->>'total'));
    begin perform public.rc_docgen_list('done', '{"unduh":"apa"}'); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Nilai saringan tidak dikenal ditolak', 'lulus', v_galat ~ 'tidak dikenal', 'rinci', v_galat);
    r := public.rc_docgen_list('done', '{}', 0, 100, true);
    hasil := hasil || jsonb_build_object('uji', 'Pilih semua hasil filter: kunci seluruh toko siap cetak (lintas halaman)',
      'lulus', jsonb_array_length(r->'kunci') = least((public.rc_docgen_list('done')->'kpi'->>'siap')::int, 5000)
        and not (r->'kunci' @> jsonb_build_array(jsonb_build_object('customerId', t2.customer_id)))
        and r->'kunci' @> jsonb_build_array(jsonb_build_object('depotId', t1.depot_id, 'customerId', t1.customer_id)),
      'rinci', jsonb_array_length(r->'kunci') || ' kunci');

    -- ---- Unduh Done ------------------------------------------------------------------
    v_log0 := (select count(*) from public.activity_logs where event_type = 'docgen_verifikasi');
    r := public.rc_docgen_generate(jsonb_build_array(
           jsonb_build_object('depotId', t1.depot_id, 'customerId', t1.customer_id),
           jsonb_build_object('depotId', t2.depot_id, 'customerId', t2.customer_id),
           jsonb_build_object('depotId', t3.depot_id, 'customerId', t3.customer_id),
           jsonb_build_object('depotId', t1.depot_id, 'customerId', t1.customer_id)));
    -- 20261163700000: t1 mendapat satu form per golongan yang dimilikinya (PDA mulai 01-Oct-2026, PDH sebelumnya / tanpa tanggal).
    -- 20261163720000: PDA hanya Jenis CB Transfer / CN.
    select count(distinct rc_private.docgen_kategori((c.cleared_at at time zone 'Asia/Jakarta')::date, rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)))) into v_kat_n
      from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where c.status = 'done' and c.archived_at is null and c.depot_id = t1.depot_id and c.customer_id = t1.customer_id;
    hasil := hasil || jsonb_build_object('uji', 'Unduh campuran: tanda terima t1 (1 form per golongan PDA/PDH); master belum lengkap & depot lain gagal beserta alasan; toko ganda sekali',
      'lulus', jsonb_array_length(r->'forms') = v_kat_n and jsonb_array_length(r->'gagal') = 2
        and exists(select 1 from jsonb_array_elements(r->'gagal') x where x->>'alasan' ~ 'belum lengkap.*Contact Person')
        and exists(select 1 from jsonb_array_elements(r->'gagal') x where x->>'alasan' ~ 'di luar jangkauan'),
      'rinci', (r->>'message') || ' ' || (r->'gagal')::text);
    v_form := r->'forms'->0; v_no1 := v_form->>'noForm'; v_no_akhir := r->'forms'->(jsonb_array_length(r->'forms') - 1)->>'noForm';
    hasil := hasil || jsonb_build_object('uji', 'Golongan: PDA lebih dulu, lalu PDH; nomor berurutan; kategori tercatat di jejak',
      'lulus', (select bool_and(x->>'kategori' in ('PDA', 'PDH')) from jsonb_array_elements(r->'forms') x)
        and (jsonb_array_length(r->'forms') = 1 or (r->'forms'->0->>'kategori' = 'PDA' and r->'forms'->1->>'kategori' = 'PDH'
             and right(v_no_akhir, 3)::int = right(v_no1, 3)::int + 1))
        and (select bool_and(f.kategori = x->>'kategori') from jsonb_array_elements(r->'forms') x join public.rc_form_verifikasi f on f.no_form = x->>'noForm'),
      'rinci', (select string_agg((x->>'noForm') || ' ' || (x->>'kategori'), ', ') from jsonb_array_elements(r->'forms') x));
    hasil := hasil || jsonb_build_object('uji', 'Nomor TT-ABBR-DDMMYY-NNN', 'lulus', v_no1 ~ ('^TT-' || v_abbr || '-' || v_hari || '-[0-9]{3}$'), 'rinci', v_no1);
    hasil := hasil || jsonb_build_object('uji', 'Isi: sumber done, toko, depot, pemilik, sales, subyek pajak, tanggal dd-Mmm-yyyy, tanpa saringan',
      'lulus', v_form->>'sumber' = 'done' and v_form->>'saringan' = '' and v_form->'toko'->>'pemilik' = 'Pemilik Uji DG' and v_form->'toko'->>'sales' = 'Sales Uji DG'
        and v_form->'toko'->>'subyekPajak' = 'Badan' and v_form->>'dicetak' = to_char((now() at time zone 'Asia/Jakarta')::date, 'DD-Mon-YYYY')
        and v_form->'depot'->>'kode' = (select depot_code from public.depots where id = t1.depot_id),
      'rinci', (v_form - 'campaigns')::text);
    -- Seluruh form t1 (PDA dan/atau PDH) bersama-sama memuat semua campaign x Jenis CB dan semua klaim.
    hasil := hasil || jsonb_build_object('uji', 'Baris = campaign x Jenis CB toko (gabungan form), Total = jumlah baris, halaman = ceil(n/4), klaim lengkap',
      'lulus', (select count(distinct (y->>'kode') || '|' || (y->>'jenisCb')) from jsonb_array_elements(r->'forms') x, jsonb_array_elements(x->'campaigns') y) = m
        and not exists (select 1 from jsonb_array_elements(r->'forms') x
                         where (x->>'halaman')::int <> ceil(jsonb_array_length(x->'campaigns') / 4.0)::int
                            or (x->>'total')::numeric <> (select sum((y->>'netCb')::numeric) from jsonb_array_elements(x->'campaigns') y)
                            or (select cardinality(f.claim_ids) from public.rc_form_verifikasi f where f.no_form = x->>'noForm') <> (x->>'jumlahKlaim')::int)
        and (select sum((x->>'jumlahKlaim')::int) from jsonb_array_elements(r->'forms') x)
            = (select count(*) from public.claims c where c.status = 'done' and c.archived_at is null and c.depot_id = t1.depot_id and c.customer_id = t1.customer_id),
      'rinci', (select string_agg((x->>'kategori') || ': ' || jsonb_array_length(x->'campaigns') || ' baris, ' || (x->>'halaman') || ' hal, ' || (x->>'jumlahKlaim') || ' klaim', '; ')
                  from jsonb_array_elements(r->'forms') x) || ' / harap ' || m || ' baris');
    hasil := hasil || jsonb_build_object('uji', 'Form tidak memuat KTP / NPWP', 'lulus', position(v_npwp in r::text) = 0, 'rinci', '-');
    -- 20261163590000: Tanggal Proses = tanggal Clearing (cleared_at, WIB) klaim baris itu, DD-Mon-YY dipisah koma (20261163660000).
    -- 20261163700000: hanya form PDA (tanggal mulai 01-Oct-2026) yang memuatnya; form PDH kosong.
    select string_agg(to_char(d, 'DD-Mon-YY'), ', ' order by d) into v_txt
      from (select distinct (c.cleared_at at time zone 'Asia/Jakarta')::date d from public.claims c join public.campaigns ca on ca.id = c.campaign_id
             where c.status = 'done' and c.archived_at is null and c.depot_id = t1.depot_id and c.customer_id = t1.customer_id and c.cleared_at is not null
               and rc_private.docgen_kategori((c.cleared_at at time zone 'Asia/Jakarta')::date, rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type))) = 'PDA') z;
    hasil := hasil || jsonb_build_object('uji', 'Tanggal Proses: form PDA = tanggal Clearing mulai 01-Oct-2026 (DD-Mon-YY, dipisah koma); form PDH tanpa tanggal',
      'lulus', not exists(select 1 from jsonb_array_elements(r->'forms') f, jsonb_array_elements(f->'campaigns') x
                           where not (x ? 'tglProses') or x->>'tglProses' !~ '^(\d{2}-[A-Z][a-z]{2}-\d{2}(, \d{2}-[A-Z][a-z]{2}-\d{2})*)?$'
                              or (f->>'kategori' = 'PDH' and x->>'tglProses' <> ''))
        and (select string_agg(y, ', ' order by to_date(y, 'DD-Mon-YY')) from (select distinct btrim(u) y
               from jsonb_array_elements(r->'forms') f, jsonb_array_elements(f->'campaigns') x, unnest(string_to_array(x->>'tglProses', ',')) u
              where f->>'kategori' = 'PDA' and btrim(u) <> '') q) is not distinct from v_txt,
      'rinci', coalesce(v_txt, '- (tidak ada tanggal mulai 01-Oct-2026)'));
    select count(*) - v_log0 into n from public.activity_logs where event_type = 'docgen_verifikasi';
    hasil := hasil || jsonb_build_object('uji', 'Log Activity satu baris per proses unduh (tab done)',
      'lulus', n = 1 and (select tab from public.activity_logs where event_type = 'docgen_verifikasi' order by created_at desc, id desc limit 1) = 'done', 'rinci', n);

    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', t1.depot_id, 'customerId', t1.customer_id)), 'done');
    hasil := hasil || jsonb_build_object('uji', 'Unduh ulang: nomor baru, tidak berulang',
      'lulus', r->'forms'->0->>'noForm' <> v_no1 and right(r->'forms'->0->>'noForm', 3)::int = right(v_no_akhir, 3)::int + 1
        and (select count(*) from public.rc_form_verifikasi) = (select count(distinct no_form) from public.rc_form_verifikasi),
      'rinci', v_no1 || ' -> ' || (r->'forms'->0->>'noForm'));

    v_row := pg_temp.dg_baris('done', '{}', t1.customer_id);
    -- Jumlah unduh dihitung terhadap jejak toko itu (unduhan sungguhan sebelum uji ikut terhitung).
    -- 20261163700000: satu unduhan bisa menghasilkan form PDA + PDH; jejak dihitung per proses unduh.
    hasil := hasil || jsonb_build_object('uji', 'Jejak unduh: semua nomor proses terakhir, jumlah unduh = proses unduh toko (2 unduhan uji ikut); belum berubah',
      'lulus', position((select f.no_form from public.rc_form_verifikasi f where f.customer_id = t1.customer_id and f.depot_id = t1.depot_id and f.sumber = 'done' order by f.created_at desc, f.urut desc limit 1) in v_row->'unduh'->>'noForm') > 0
        and (v_row->>'jumlahUnduh')::int = (select count(distinct f.proses_id) from public.rc_form_verifikasi f where f.customer_id = t1.customer_id and f.depot_id = t1.depot_id and f.sumber = 'done')
        and (v_row->>'jumlahUnduh')::int >= 2 and not (v_row->>'berubah')::boolean,
      'rinci', (v_row->'unduh')::text || ' x' || (v_row->>'jumlahUnduh'));
    r := public.rc_docgen_list('done', '{"unduh":"sudah"}', 0, 500); r2 := public.rc_docgen_list('done', '{"unduh":"belum"}', 0, 500);
    hasil := hasil || jsonb_build_object('uji', 'Saringan Status Unduh: t1 di "sudah", tidak di "belum"',
      'lulus', exists(select 1 from jsonb_array_elements(r->'rows') x where (x->>'customerId')::uuid = t1.customer_id)
        and not exists(select 1 from jsonb_array_elements(r2->'rows') x where (x->>'customerId')::uuid = t1.customer_id)
        and ((r2->>'total')::int > 500 or (r->'kpi'->>'belumUnduh')::int = (select count(*) from jsonb_array_elements(r2->'rows') x where (x->>'siap')::boolean)),
      'rinci', (r->>'total') || ' / ' || (r2->>'total'));

    -- Amend mengubah nilai: daftar menandai perlu unduh ulang.
    update public.claims set cb_net = coalesce(cb_net, 0) + 1000
     where id = (select k.claim_id from rc_private.docgen_klaim('done', '{}', jsonb_build_array(jsonb_build_object('depotId', t1.depot_id, 'customerId', t1.customer_id))) k order by k.claim_id limit 1);
    v_row := pg_temp.dg_baris('done', '{}', t1.customer_id);
    hasil := hasil || jsonb_build_object('uji', 'Nilai berubah sejak unduh: ditandai berubah; saringan "berubah" memuatnya',
      'lulus', (v_row->>'berubah')::boolean and exists(select 1 from jsonb_array_elements(public.rc_docgen_list('done', '{"unduh":"berubah"}', 0, 500)->'rows') x
                                                       where (x->>'customerId')::uuid = t1.customer_id), 'rinci', v_row->>'berubah');

    -- ---- Saringan klaim: Tgl Done dan No Batch Clearing ------------------------------
    select max((c.cleared_at at time zone 'Asia/Jakarta')::date) into v_tgl from public.claims c
     where c.status = 'done' and c.archived_at is null and c.depot_id = t1.depot_id and c.customer_id = t1.customer_id;
    select count(*) into n from public.claims c where c.status = 'done' and c.archived_at is null and c.depot_id = t1.depot_id
       and c.customer_id = t1.customer_id and (c.cleared_at at time zone 'Asia/Jakarta')::date = v_tgl;
    r := public.rc_docgen_list('done', jsonb_build_object('dari', v_tgl, 'sampai', v_tgl), 0, 500);
    v_row := pg_temp.dg_baris('done', jsonb_build_object('dari', v_tgl, 'sampai', v_tgl), t1.customer_id);
    hasil := hasil || jsonb_build_object('uji', 'Saringan Tgl Done: hanya klaim Done pada rentang itu',
      'lulus', (v_row->>'jumlahKlaim')::int = n and v_row->>'tglDone' = to_char(v_tgl, 'DD-Mon-YYYY') and r->>'saringan' = 'Tgl Done ' || to_char(v_tgl, 'DD-Mon-YYYY') || ' s.d. ' || to_char(v_tgl, 'DD-Mon-YYYY')
        and not exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'tglDone' <> to_char(v_tgl, 'DD-Mon-YYYY')),
      'rinci', coalesce(v_row->>'jumlahKlaim', '?') || ' vs ' || n || ' @ ' || v_tgl);
    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', t1.depot_id, 'customerId', t1.customer_id)), 'done', jsonb_build_object('dari', v_tgl, 'sampai', v_tgl));
    v_form := r->'forms'->0;
    hasil := hasil || jsonb_build_object('uji', 'Unduh dengan saringan Tgl Done: jumlah klaim sesuai, keterangan tercetak dan tersimpan',
      'lulus', (v_form->>'jumlahKlaim')::int = n and v_form->>'saringan' = 'Tgl Done ' || to_char(v_tgl, 'DD-Mon-YYYY') || ' s.d. ' || to_char(v_tgl, 'DD-Mon-YYYY')
        and (select periode_dari = v_tgl and periode_sampai = v_tgl and batch_clearing is null from public.rc_form_verifikasi where no_form = v_form->>'noForm'),
      'rinci', coalesce((v_form - 'campaigns')::text, r::text));

    select count(*) into n from public.claims c where c.status = 'done' and c.archived_at is null and c.depot_id = t1.depot_id
       and c.customer_id = t1.customer_id and btrim(c.batch_clearing) = v_batch;
    v_row := pg_temp.dg_baris('done', jsonb_build_object('batch', v_batch), t1.customer_id);
    r := public.rc_docgen_list('done', jsonb_build_object('batch', v_batch), 0, 500);
    hasil := hasil || jsonb_build_object('uji', 'Saringan No Batch Clearing: hanya klaim batch itu; seluruh baris punya klaim di batch itu',
      'lulus', (v_row->>'jumlahKlaim')::int = n and r->>'saringan' = 'Batch Clearing ' || v_batch
        and not exists(select 1 from jsonb_array_elements(r->'rows') x where not exists(select 1 from public.claims c where c.depot_id = (x->>'depotId')::uuid
                         and c.customer_id = (x->>'customerId')::uuid and c.status = 'done' and btrim(c.batch_clearing) = v_batch)),
      'rinci', coalesce(v_row->>'jumlahKlaim', '?') || ' vs ' || n || ' @ ' || v_batch || '; ' || (r->>'total') || ' toko');
    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', t1.depot_id, 'customerId', t1.customer_id)), 'done', jsonb_build_object('batch', ' ' || v_batch || ' '));
    v_form := r->'forms'->0;
    hasil := hasil || jsonb_build_object('uji', 'Unduh dengan saringan batch: klaim batch itu saja, keterangan dan batch tersimpan',
      'lulus', (v_form->>'jumlahKlaim')::int = n and v_form->>'saringan' = 'Batch Clearing ' || v_batch
        and (select batch_clearing = v_batch and periode_dari is null from public.rc_form_verifikasi where no_form = v_form->>'noForm')
        and (select details->>'batch' from public.activity_logs where event_type = 'docgen_verifikasi' order by created_at desc, id desc limit 1) = v_batch,
      'rinci', coalesce((v_form - 'campaigns')::text, r::text));
    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', t1.depot_id, 'customerId', t1.customer_id)), 'done', '{"batch":"BATCH-TIDAK-ADA"}');
    hasil := hasil || jsonb_build_object('uji', 'Batch tanpa klaim toko itu: ditolak dengan alasan', 'lulus', jsonb_array_length(r->'forms') = 0
      and r->'gagal'->0->>'alasan' ~ 'Tidak ada klaim Done pada Batch Clearing', 'rinci', r->'gagal'->0->>'alasan');
    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', t1.depot_id, 'customerId', t1.customer_id)), 'done', '{"dari":"1990-01-01","sampai":"1990-01-31"}');
    hasil := hasil || jsonb_build_object('uji', 'Rentang tanpa klaim Done: ditolak dengan alasan', 'lulus', jsonb_array_length(r->'forms') = 0
      and r->'gagal'->0->>'alasan' ~ 'Tidak ada klaim Done pada Tgl Done', 'rinci', r->'gagal'->0->>'alasan');
    begin perform public.rc_docgen_list('done', jsonb_build_object('dari', v_tgl, 'sampai', v_tgl - 1)); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Tgl Done dari > sampai ditolak', 'lulus', v_galat ~ 'melewati', 'rinci', v_galat);
    begin perform public.rc_docgen_list('done', '{"dari":"31-10-2026"}'); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Tgl Done bukan tanggal ISO ditolak', 'lulus', v_galat ~ 'tidak valid', 'rinci', v_galat);
    begin perform public.rc_docgen_list('notyet', jsonb_build_object('batch', v_batch)); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Sumber Not Yet dengan saringan pun ditolak (tab ditiadakan)', 'lulus', v_galat ~ 'sudah ditiadakan', 'rinci', v_galat);

    -- Masukan tidak valid
    begin perform public.rc_docgen_generate('[{"depotId":"x","customerId":"y"}]'::jsonb); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Data toko tidak valid ditolak', 'lulus', v_galat ~ 'tidak valid', 'rinci', v_galat);
    begin perform public.rc_docgen_generate('[]'::jsonb); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Tanpa pilihan ditolak', 'lulus', v_galat ~ 'Pilih toko', 'rinci', v_galat);
    begin perform public.rc_docgen_list('lunas'); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Sumber lama "lunas" tidak dikenal lagi', 'lulus', v_galat ~ 'Sumber form tidak dikenal', 'rinci', v_galat);

    -- ---- Tab Not Yet ditiadakan (20261163690000); rekening diuji lewat tab Done --------------
    begin perform public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', n1.depot_id, 'customerId', n1.customer_id)), 'notyet');
      v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Unduh Not Yet ditolak server (tab ditiadakan)', 'lulus', v_galat ~ 'sudah ditiadakan', 'rinci', v_galat);

    update public.customers set bank = 'BCA', account_number = '1234567890', account_name = 'Pemilik Uji DG' where id = t1.customer_id;
    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', t1.depot_id, 'customerId', t1.customer_id)), 'done');
    v_form := r->'forms'->0;
    hasil := hasil || jsonb_build_object('uji', 'Form tidak lagi memuat rekening Customer Master (20261163740000)',
      'lulus', v_form is not null and not (v_form ? 'rekening') and position('1234567890' in r::text) = 0, 'rinci', coalesce((v_form->'rekening')::text, '-'));
    update public.customers set bank = null, account_number = '', account_name = null where id = t1.customer_id;
    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', t1.depot_id, 'customerId', t1.customer_id)), 'done');
    hasil := hasil || jsonb_build_object('uji', 'Rekening kosong tidak menahan cetak (tidak wajib)',
      'lulus', jsonb_array_length(r->'forms') >= 1 and not exists (select 1 from jsonb_array_elements(r->'forms') x where x ? 'rekening'), 'rinci', r->>'message');

    -- Klaim tanpa Customer Master tampil di Done, ditandai, tidak dapat dicetak, dan daftar
    -- campaign-nya terbaca lewat kode toko.
    begin
      update public.claims set customer_id = null
       where id = (select k.claim_id from rc_private.docgen_klaim('done') k where k.depot_id = t1.depot_id and k.customer_id is not null
                      and k.customer_id <> t1.customer_id order by k.claim_id limit 1)
      returning upper(btrim(coalesce(source_customer_code, ''))) into v_txt;
      r := public.rc_docgen_list('done', jsonb_build_object('cari', v_txt), 0, 500);
      select x into v_row from jsonb_array_elements(r->'rows') x where x->>'customerId' is null and x->>'kode' = v_txt;
      hasil := hasil || jsonb_build_object('uji', 'Klaim tanpa Customer Master: tampil per kode toko, tidak siap cetak, campaign terbaca',
        'lulus', v_row is not null and not (v_row->>'siap')::boolean and v_row->>'masalahMaster' = 'Customer Master tidak ditemukan'
          and jsonb_array_length(v_row->'campaigns') > 0,
        'rinci', coalesce(v_row::text, 'tidak tampil: ' || coalesce(v_txt, '-')));
    exception when others then
      hasil := hasil || jsonb_build_object('uji', 'Klaim tanpa Customer Master: tampil per kode toko, tidak siap cetak, campaign terbaca', 'lulus', false, 'rinci', sqlerrm);
    end;

    -- System Manager menjangkau seluruh depot; waktu daftar Done seluruh depot.
    perform pg_temp.dg_sebagai(v_sm);
    t0 := clock_timestamp();
    r := public.rc_docgen_list('done');
    hasil := hasil || jsonb_build_object('uji', 'System Manager: daftar Done seluruh depot < 6 detik, satu halaman',
      'lulus', clock_timestamp() - t0 < interval '6 seconds' and jsonb_array_length(r->'rows') = least((r->>'total')::int, 100),
      'rinci', round(extract(epoch from clock_timestamp() - t0) * 1000) || ' ms, ' || (r->>'total') || ' toko, ' || length(r::text) || ' byte');
    r := public.rc_docgen_list('done', jsonb_build_object('depot', v_t3depot), 0, 500);
    hasil := hasil || jsonb_build_object('uji', 'System Manager melihat toko di depot lain (saringan depot)',
      'lulus', (r->>'total')::int > 0 and not exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'depotKode' <> v_t3depot), 'rinci', r->>'total');

    hasil := hasil || jsonb_build_object('uji', 'Tabel jejak tertutup bagi authenticated', 'lulus', not has_table_privilege('authenticated', 'public.rc_form_verifikasi', 'select'), 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  insert into _hasil_dg(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_dg order by urut;
