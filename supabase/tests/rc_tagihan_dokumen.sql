-- ==========================================================================================
-- Uji Tagihan / Final Billing Month per dokumen (migrasi 20261163270000)
-- ==========================================================================================
-- Seluruhnya di subtransaksi yang DIBATALKAN (UJI_SELESAI). Butuh data Upload Debtor yang sudah
-- diterapkan (rc_zdage_depot_data). Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_tagihan_dokumen.sql
-- ==========================================================================================
create temp table if not exists _hasil_tg(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_tg;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; r jsonb; a record; b record; t record; v_galat text; u record; v_harap text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;

  -- Dokumen yang tokonya ada di file debtor dengan tagihan.
  select c.no_doc, c.depot_id, zr.total_amt, zr.overdue_amt, zr.buckets, zr.bucket_older, coalesce(zu.toleransi, 1) tol into a
    from public.claims c
    join public.rc_zdage_depot_data dd on dd.depot_id = c.depot_id and not dd.kosong
    join public.rc_zdage_uploads zu on zu.id = dd.upload_id
    left join public.customers cu on cu.id = c.customer_id
    join public.rc_zdage_rows zr on zr.upload_id = dd.upload_id and zr.customer_key = rc_private.kode_toko(coalesce(cu.customer_code, c.source_customer_code))
   where c.archived_at is null and zr.total_amt > 1
   order by zr.total_amt desc limit 1;
  -- Dokumen di depot yang sama, tokonya tidak ada di file.
  select c.no_doc into b
    from public.claims c left join public.customers cu on cu.id = c.customer_id
   where c.archived_at is null and c.depot_id = a.depot_id
     and not exists(select 1 from public.rc_zdage_rows zr join public.rc_zdage_depot_data dd on dd.upload_id = zr.upload_id and dd.depot_id = a.depot_id
                     where zr.customer_key = rc_private.kode_toko(coalesce(cu.customer_code, c.source_customer_code)))
   limit 1;
  -- Dokumen di depot tanpa data debtor.
  select c.no_doc, c.depot_id into t from public.claims c
   where c.archived_at is null and not exists(select 1 from public.rc_zdage_depot_data dd where dd.depot_id = c.depot_id) limit 1;

  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  begin
    if a.no_doc is null then raise exception 'Fixture: belum ada data Upload Debtor yang diterapkan dengan tagihan'; end if;
    r := public.rc_tagihan_dokumen(array[a.no_doc, lower(a.no_doc), coalesce(b.no_doc, ''), coalesce(t.no_doc, '')]);
    v_harap := (select concat_ws(', ', nullif(string_agg(to_char(to_date(e.key, 'YYYY-MM'), 'Mon-YY'), ', ' order by e.key), ''),
                                 case when a.bucket_older > a.tol then '<1 yrs' end)
                  from jsonb_each(a.buckets) e where (e.value #>> '{}')::numeric > a.tol);
    hasil := hasil || jsonb_build_object('uji', 'Toko di file: Tagihan = Total, Over Due, Final Billing Month sesuai kolom bulan',
      'lulus', r->'data'->upper(a.no_doc)->>'status' = 'ada'
        and (r->'data'->upper(a.no_doc)->>'tagihan')::numeric = a.total_amt
        and (r->'data'->upper(a.no_doc)->>'overdue')::numeric = a.overdue_amt
        and r->'data'->upper(a.no_doc)->>'bulan' = v_harap,
      'rinci', a.no_doc || ' | ' || (r->'data'->upper(a.no_doc))::text);
    hasil := hasil || jsonb_build_object('uji', 'No Doc huruf kecil / ganda tetap satu kunci huruf besar',
      'lulus', (select count(*) from jsonb_object_keys(r->'data') k where k = upper(a.no_doc)) = 1, 'rinci', '');
    hasil := hasil || jsonb_build_object('uji', 'Toko tidak ada di file: Tagihan 0 (lunas)',
      'lulus', b.no_doc is null or (r->'data'->upper(b.no_doc)->>'status' = 'tidak_di_file' and (r->'data'->upper(b.no_doc)->>'tagihan')::numeric = 0),
      'rinci', coalesce(b.no_doc, '(tidak ada contoh)'));
    hasil := hasil || jsonb_build_object('uji', 'Depot tanpa data debtor: tanpa_data (layar "-")',
      'lulus', t.no_doc is null or r->'data'->upper(t.no_doc)->>'status' = 'tanpa_data', 'rinci', coalesce(t.no_doc, '(tidak ada contoh)'));

    update public.rc_zdage_depot_data set kosong = true where depot_id = a.depot_id;
    r := public.rc_tagihan_dokumen(array[a.no_doc]);
    hasil := hasil || jsonb_build_object('uji', 'Depot ditandai "Tidak ada tagihan": Tagihan 0',
      'lulus', r->'data'->upper(a.no_doc)->>'status' = 'kosong' and (r->'data'->upper(a.no_doc)->>'tagihan')::numeric = 0, 'rinci', '');

    hasil := hasil || jsonb_build_object('uji', 'Format bulan: urut naik, di atas toleransi saja, "<1 yrs" terakhir; header bulan apa pun',
      'lulus', rc_private.tagihan_bulan('{"2026-10": 5, "2026-09": 100, "2025-12": 2, "2026-01": -50, "2026-02": 1}'::jsonb, 3, 1) = 'Dec-25, Sep-26, Oct-26, <1 yrs'
        and rc_private.tagihan_bulan('{"2026-11": 10, "2025-11": 0}'::jsonb, 0, 1) = 'Nov-26'
        and rc_private.tagihan_bulan('{"2026-11": 1}'::jsonb, 1, 1) = '',
      'rinci', rc_private.tagihan_bulan('{"2026-10": 5, "2026-09": 100, "2025-12": 2, "2026-01": -50, "2026-02": 1}'::jsonb, 3, 1));

    begin
      perform public.rc_tagihan_dokumen(array(select 'X' || g from generate_series(1, 2001) g));
      v_galat := '(tidak ditolak)';
    exception when others then v_galat := sqlerrm;
    end;
    hasil := hasil || jsonb_build_object('uji', 'Lebih dari 2000 dokumen per permintaan ditolak', 'lulus', v_galat ~ 'Maksimal 2000', 'rinci', v_galat);

    -- Jangkauan: user yang tidak menjangkau depot dokumen tidak menerima tagihannya.
    for u in select p.id from public.profiles p where p.status = 'active' and not p.must_change_password and p.role <> 'system manager'
              and not exists(select 1 from public.user_depot_access x where x.user_id = p.id and x.depot_id = a.depot_id)
              and exists(select 1 from public.user_depot_access x where x.user_id = p.id) order by p.user_code limit 1 loop
      perform set_config('request.jwt.claims', json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
      r := public.rc_tagihan_dokumen(array[a.no_doc]);
      hasil := hasil || jsonb_build_object('uji', 'Dokumen di luar jangkauan depot tidak dikembalikan',
        'lulus', not (r->'data' ? upper(a.no_doc)), 'rinci', '');
    end loop;
    hasil := hasil || jsonb_build_object('uji', 'anon tidak dapat menjalankan rc_tagihan_dokumen',
      'lulus', not has_function_privilege('anon', 'public.rc_tagihan_dokumen(text[])', 'execute'), 'rinci', '');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  insert into _hasil_tg(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_tg order by urut;
