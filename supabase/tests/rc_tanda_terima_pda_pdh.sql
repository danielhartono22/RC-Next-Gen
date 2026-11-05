-- ==========================================================================================
-- Uji Tanda Terima PDA / PDH (20261163700000, 20261163720000): Jenis CB Transfer / CN dengan
-- Tanggal Proses mulai 01-Oct-2026 = PDA (kolom tampil); selain itu = PDH (kolom disembunyikan);
-- toko campuran = 2 form; Remark di daftar; jejak unduh per proses.
-- ==========================================================================================
-- Tanggal Clearing klaim uji diubah lalu dibatalkan lewat UJI_SELESAI.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_tanda_terima_pda_pdh.sql
-- ==========================================================================================
create temp table if not exists _hasil_pda(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_pda;

do $uji$
declare hasil jsonb := '[]'; r jsonb; v_sm uuid; t record; v_ids uuid[]; v_row jsonb; v_kode text; v_bt date := rc_private.docgen_batas_pda();
  v_tot numeric; rb record; -- rb: klaim Done berjenis selain Transfer / CN
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- Toko Done bermaster lengkap dengan >= 2 klaim Done.
  select c.depot_id, c.customer_id, cu.customer_code into t from public.claims c join public.customers cu on cu.id = c.customer_id
    join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'done' and c.archived_at is null and rc_private.docgen_masalah_master(c.customer_id) is null
   group by 1, 2, 3
  having count(*) >= 2 and bool_and(rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('transfer', 'cn'))
   order by count(*) desc, 3 limit 1;
  -- Toko lain yang punya klaim Done berjenis Rebate / Rebate Manual / Voucher.
  select c.id, c.depot_id, c.customer_id, cu.customer_code, rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) jenis into rb
    from public.claims c join public.customers cu on cu.id = c.customer_id join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'done' and c.archived_at is null and rc_private.docgen_masalah_master(c.customer_id) is null and c.customer_id <> t.customer_id
     and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('rebate', 'rebate manual', 'voucher')
   order by c.id limit 1;
  select array_agg(c.id order by c.id) into v_ids from public.claims c
   where c.status = 'done' and c.archived_at is null and c.depot_id = t.depot_id and c.customer_id = t.customer_id;
  v_kode := t.customer_code;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    hasil := hasil || jsonb_build_object('uji', 'Batas PDA = 01-Oct-2026', 'lulus', v_bt = date '2026-10-01', 'rinci', v_bt::text);

    -- ---- Campuran: klaim pertama sebelum Oktober, sisanya Oktober ke atas -------------------
    update public.claims set cleared_at = (date '2026-09-15' + time '10:00') at time zone 'Asia/Jakarta' where id = v_ids[1];
    update public.claims set cleared_at = (date '2026-10-07' + time '10:00') at time zone 'Asia/Jakarta' where id = any(v_ids[2:]);
    v_row := (select x from jsonb_array_elements(public.rc_docgen_list('done', jsonb_build_object('cari', v_kode), 0, 500)->'rows') x
               where (x->>'customerId')::uuid = t.customer_id limit 1);
    hasil := hasil || jsonb_build_object('uji', 'Daftar Done: Remark toko campuran = PDA + PDH', 'lulus', regexp_replace(v_row->>'remark', ' \+ PP$', '') = 'PDA + PDH' /* PP: 20261163740000 */, 'rinci', coalesce(v_row->>'remark', '-'));
    select coalesce(sum(trunc(cb_net)), 0) into v_tot from public.claims where id = any(v_ids);
    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', t.depot_id, 'customerId', t.customer_id)), 'done');
    hasil := hasil || jsonb_build_object('uji', 'Toko campuran: 2 form, PDA lebih dulu lalu PDH, nomor berurutan',
      'lulus', jsonb_array_length(r->'forms') = 2 and r->'forms'->0->>'kategori' = 'PDA' and r->'forms'->1->>'kategori' = 'PDH'
           and right(r->'forms'->1->>'noForm', 3)::int = right(r->'forms'->0->>'noForm', 3)::int + 1
           and (r->>'pda')::int = 1 and (r->>'pdh')::int = 1,
      'rinci', (select string_agg((x->>'noForm') || ' ' || (x->>'kategori'), ', ') from jsonb_array_elements(r->'forms') x));
    hasil := hasil || jsonb_build_object('uji', 'Form PDA: Tanggal Proses terisi (07-Oct-26); form PDH: kosong semua',
      'lulus', not exists (select 1 from jsonb_array_elements(r->'forms'->0->'campaigns') x where x->>'tglProses' <> '07-Oct-26')
           and not exists (select 1 from jsonb_array_elements(r->'forms'->1->'campaigns') x where x->>'tglProses' <> ''),
      'rinci', (r->'forms'->0->'campaigns'->0->>'tglProses') || ' / ' || coalesce(r->'forms'->1->'campaigns'->0->>'tglProses', '-'));
    hasil := hasil || jsonb_build_object('uji', 'Klaim terbagi tanpa sisa: jumlah klaim dan total kedua form = seluruh klaim Done toko',
      'lulus', (r->'forms'->0->>'jumlahKlaim')::int = cardinality(v_ids) - 1 and (r->'forms'->1->>'jumlahKlaim')::int = 1
           and (r->'forms'->0->>'total')::numeric + (r->'forms'->1->>'total')::numeric = v_tot,
      'rinci', (r->'forms'->0->>'total') || ' + ' || (r->'forms'->1->>'total') || ' = ' || v_tot);
    hasil := hasil || jsonb_build_object('uji', 'Jejak: kategori tercatat per form, satu proses unduh',
      'lulus', (select array_agg(kategori order by urut) from public.rc_form_verifikasi where proses_id =
                 (select proses_id from public.rc_form_verifikasi where no_form = r->'forms'->0->>'noForm')) = array['PDA', 'PDH'],
      'rinci', '-');
    v_row := (select x from jsonb_array_elements(public.rc_docgen_list('done', jsonb_build_object('cari', v_kode), 0, 500)->'rows') x
               where (x->>'customerId')::uuid = t.customer_id limit 1);
    hasil := hasil || jsonb_build_object('uji', 'Sesudah unduh: belum berubah, Unduh terakhir memuat kedua nomor (PDA, PDH)',
      'lulus', not (v_row->>'berubah')::boolean and v_row->'unduh'->>'noForm' ~ (r->'forms'->0->>'noForm') and v_row->'unduh'->>'noForm' ~ '\(PDA\).*\(PDH\)',
      'rinci', coalesce((v_row->'unduh')::text, '-') || ' x' || (v_row->>'jumlahUnduh'));

    -- Saringan Tgl Done hanya Oktober: satu form PDA.
    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', t.depot_id, 'customerId', t.customer_id)), 'done',
           jsonb_build_object('dari', '2026-10-01', 'sampai', '2026-10-31'));
    hasil := hasil || jsonb_build_object('uji', 'Saringan Tgl Done Oktober: hanya form PDA',
      'lulus', jsonb_array_length(r->'forms') = 1 and r->'forms'->0->>'kategori' = 'PDA', 'rinci', r->>'message');

    -- ---- Semua sebelum Oktober / tanpa tanggal: satu form PDH -----------------------------
    update public.claims set cleared_at = (date '2026-08-20' + time '09:00') at time zone 'Asia/Jakarta' where id = any(v_ids);
    update public.claims set cleared_at = null where id = v_ids[1];
    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', t.depot_id, 'customerId', t.customer_id)), 'done');
    hasil := hasil || jsonb_build_object('uji', 'Seluruh klaim sebelum 01-Oct-2026 atau tanpa tanggal: satu form PDH tanpa Tanggal Proses',
      'lulus', jsonb_array_length(r->'forms') = 1 and r->'forms'->0->>'kategori' = 'PDH'
           and not exists (select 1 from jsonb_array_elements(r->'forms'->0->'campaigns') x where x->>'tglProses' <> ''),
      'rinci', r->>'message');
    v_row := (select x from jsonb_array_elements(public.rc_docgen_list('done', jsonb_build_object('cari', v_kode), 0, 500)->'rows') x
               where (x->>'customerId')::uuid = t.customer_id limit 1);
    hasil := hasil || jsonb_build_object('uji', 'Daftar: Remark PDH', 'lulus', v_row->>'remark' = 'PDH', 'rinci', coalesce(v_row->>'remark', '-'));

    -- ---- Semua Oktober ke atas: satu form PDA ------------------------------------------------
    update public.claims set cleared_at = (date '2026-10-01' + time '00:00') at time zone 'Asia/Jakarta' where id = any(v_ids);
    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', t.depot_id, 'customerId', t.customer_id)), 'done');
    v_row := (select x from jsonb_array_elements(public.rc_docgen_list('done', jsonb_build_object('cari', v_kode), 0, 500)->'rows') x
               where (x->>'customerId')::uuid = t.customer_id limit 1);
    hasil := hasil || jsonb_build_object('uji', 'Tepat 01-Oct-2026: PDA (satu form, Tanggal Proses 01-Oct-26); Remark PDA',
      'lulus', jsonb_array_length(r->'forms') = 1 and r->'forms'->0->>'kategori' = 'PDA'
           and not exists (select 1 from jsonb_array_elements(r->'forms'->0->'campaigns') x where x->>'tglProses' <> '01-Oct-26')
           and regexp_replace(v_row->>'remark', ' \+ PP$', '') = 'PDA',
      'rinci', coalesce(r->'forms'->0->'campaigns'->0->>'tglProses', '-') || ' / ' || coalesce(v_row->>'remark', '-'));

    -- ---- 20261163720000: Jenis CB selain Transfer / CN selalu PDH ----------------------------
    if rb.id is not null then
      update public.claims set cleared_at = (date '2026-10-15' + time '10:00') at time zone 'Asia/Jakarta'
       where status = 'done' and archived_at is null and depot_id = rb.depot_id and customer_id = rb.customer_id;
      r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', rb.depot_id, 'customerId', rb.customer_id)), 'done');
      hasil := hasil || jsonb_build_object('uji', 'Jenis ' || rb.jenis || ' bertanggal Oktober: masuk form PDH tanpa Tanggal Proses',
        'lulus', exists (select 1 from jsonb_array_elements(r->'forms') f, jsonb_array_elements(f->'campaigns') x
                          where f->>'kategori' = 'PDH' and x->>'jenisCb' = rb.jenis and x->>'tglProses' = '')
             and not exists (select 1 from jsonb_array_elements(r->'forms') f, jsonb_array_elements(f->'campaigns') x
                              where f->>'kategori' = 'PDA' and rc_private.jenis_efektif(x->>'jenisCb') not in ('transfer', 'cn')),
        'rinci', (select string_agg((f->>'kategori') || ': ' || (select string_agg(x->>'jenisCb', ',') from jsonb_array_elements(f->'campaigns') x), ' / ')
                    from jsonb_array_elements(r->'forms') f));
    end if;
    hasil := hasil || jsonb_build_object('uji', 'Aturan: Transfer / CN mulai 01-Oct-2026 = PDA; Rebate, Rebate Manual, Voucher, sebelum batas, tanpa tanggal = PDH',
      'lulus', rc_private.docgen_kategori(date '2026-10-01', 'Transfer') = 'PDA' and rc_private.docgen_kategori(date '2026-10-01', 'CN') = 'PDA'
           and rc_private.docgen_kategori(date '2026-10-01', 'Rebate') = 'PDH' and rc_private.docgen_kategori(date '2026-10-01', 'Voucher') = 'PDH'
           and rc_private.docgen_kategori(date '2026-10-01', 'Rebate Manual') = 'PDH' and rc_private.docgen_kategori(date '2026-09-30', 'CN') = 'PDH'
           and rc_private.docgen_kategori(null, 'Transfer') = 'PDH', 'rinci', '-');

    -- 20261163760000: daftar menulis aturan PDA langsung (tanpa memanggil docgen_kategori); hasilnya
    -- harus sama dengan docgen_kategori untuk setiap toko di halaman pertama.
    create temp table _uji_kat on commit drop as
      select k.depot_id, k.customer_id, concat_ws(' + ', case when bool_or(rc_private.docgen_kategori(k.tgl_done, k.jenis_cb) = 'PDA') then 'PDA' end,
                                                     case when bool_or(rc_private.docgen_kategori(k.tgl_done, k.jenis_cb) = 'PDH') then 'PDH' end) remark
        from rc_private.docgen_klaim('done', '{}') k where k.customer_id is not null group by 1, 2;
    r := public.rc_docgen_list('done', '{}', 0, 500);
    hasil := hasil || jsonb_build_object('uji', 'Remark daftar = rc_private.docgen_kategori untuk setiap toko (500 toko pertama)',
      'lulus', jsonb_array_length(r->'rows') > 0 and not exists (select 1 from jsonb_array_elements(r->'rows') x join _uji_kat u
                 on u.depot_id = (x->>'depotId')::uuid and u.customer_id = (x->>'customerId')::uuid
                 where regexp_replace(x->>'remark', ' \+ PP$', '') <> u.remark),
      'rinci', (select count(*) from jsonb_array_elements(r->'rows') x join _uji_kat u on u.depot_id = (x->>'depotId')::uuid and u.customer_id = (x->>'customerId')::uuid
                 where regexp_replace(x->>'remark', ' \+ PP$', '') <> u.remark) || ' beda dari ' || jsonb_array_length(r->'rows'));

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_pda(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_pda order by urut;
