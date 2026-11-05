-- ==========================================================================================
-- Uji Warehouse Rental - migrasi 20261163530000
-- ==========================================================================================
-- Omset uji ditulis ke satu depot, lalu agregasi, rumus (dibandingkan dengan rumus Excel yang
-- dihitung terpisah), Upload Omset, draft / submit / nomor / cancel, override, dan akses diuji.
-- Seluruh perubahan dibatalkan (UJI_SELESAI). Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_warehouse_rental.sql
-- ==========================================================================================
create temp table if not exists _hasil_wr(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_wr;

do $uji$
declare
  hasil jsonb := '[]'; v_sm uuid; v_adm uuid; v_dh uuid; d public.depots%rowtype; d2 public.depots%rowtype;
  r jsonb; x jsonb; v_err text; v_id uuid; v_id2 uuid; v_form jsonb; v_c jsonb; v_abbr text; b integer;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select id into v_adm from public.profiles p where role = 'admin' and status = 'active' and not must_change_password
     and not exists(select 1 from public.user_permissions u where u.user_id = p.id and u.permission_code = 'view_rental') order by user_code limit 1;
  select id into v_dh from public.profiles where role = 'depot head' and status = 'active' and not must_change_password order by user_code limit 1;
  select * into d from public.depots where archived_at is null and not bukan_depot order by depot_code limit 1;
  select * into d2 from public.depots where archived_at is null and not bukan_depot and id <> d.id order by depot_code limit 1;
  v_abbr := upper(coalesce(nullif(btrim(d.abbr), ''), d.depot_code));

  begin
    -- Omset uji: net bulanan = 1000 + (tahun-2024)*100 + bulan - 10; Agustus 2026 sengaja kosong.
    delete from rental.depot_revenue where depot_id = d.id;
    insert into rental.depot_revenue(depot_id, period, omset, pajak)
    select d.id, g::date, 1000 + (extract(year from g) - 2024) * 100 + extract(month from g), 10
      from generate_series(date '2024-01-01', date '2026-10-01', interval '1 month') g where g::date <> date '2026-08-01';

    x := rental.revenue(d.id, date '2026-10-27');
    hasil := hasil || jsonb_build_object('uji', 'Agregasi: PY-1 = Jan-Des 2024, PY = 2025, PY YTD = Jan-Okt 2025, Act YTD = Jan-Okt 2026 (net omset - pajak)',
      'lulus', (x->>'py1')::numeric = 11958 and (x->>'py')::numeric = 13158 and (x->>'pyytd')::numeric = 10955 and (x->>'actytd')::numeric = 10757,
      'rinci', x::text);
    hasil := hasil || jsonb_build_object('uji', 'Bulan tanpa omset dilaporkan (Agustus 2026)', 'lulus', x->'hilang' = '["2026-08"]'::jsonb, 'rinci', (x->'hilang')::text);
    x := rental.revenue(d2.id, date '2026-10-27');
    hasil := hasil || jsonb_build_object('uji', 'Depot tanpa omset: Revenue kosong ("-"), 34 bulan dilaporkan hilang',
      'lulus', x->'py1' = 'null'::jsonb and jsonb_array_length(x->'hilang') = 34, 'rinci', left(x::text, 160));

    -- Rumus, dibandingkan dengan rumus Excel yang ditulis ulang di sini.
    v_form := jsonb_build_object('leaseType', 'renewal', 'rentalYears', 3, 'warehouseSize', 700, 'officeSize', 83, 'offeringPrice', 150000000,
      'revBudget', 15000, 'revEstimate', 16500, 'coveredArea', jsonb_build_array('jakarta barat', '', 'tangerang'), 'pph', 'owner', 'pbb', 'nipsea',
      'notaris', '5050', 'ownerName', 'pt  pemilik  gudang', 'ownerAddress', 'jl. raya 1', 'competitors', jsonb_build_array('AVIAN', 'OTHERS'),
      'competitorOther', 'merek lain', 'facilities', jsonb_build_array('cctv', 'mess'), 'ipl', 2500000, 'sizePy1', 650);
    v_c := rental.hitung(rental.bersihkan(v_form, false, '{}'), rental.revenue_akhir(rental.revenue(d.id, date '2026-10-27'), '{}'));
    hasil := hasil || jsonb_build_object('uji', 'Rumus: Growth E23/H23/K23/L23 sama dengan Excel',
      'lulus', (v_c->>'growthPy')::numeric = 13158::numeric / 11958 - 1 and (v_c->>'growthActYtd')::numeric = 10757::numeric / 10955 - 1
           and (v_c->>'growthBudget')::numeric = 15000::numeric / 13158 - 1 and (v_c->>'growthEstimate')::numeric = 16500::numeric / 15000 - 1,
      'rinci', jsonb_build_object('py', v_c->'growthPy', 'act', v_c->'growthActYtd', 'bud', v_c->'growthBudget', 'est', v_c->'growthEstimate')::text);
    hasil := hasil || jsonb_build_object('uji', 'Rumus: Size Building bawaan = Warehouse + Office (783), PY-1 diisi manual; Revenue/Sqm = Revenue / Size',
      'lulus', (v_c->>'sizePy')::numeric = 783 and (v_c->>'sizePy1')::numeric = 650 and (v_c->>'revSqmPy1')::numeric = 11958::numeric / 650
           and (v_c->>'revSqmPy')::numeric = 13158::numeric / 783 and (v_c->>'revSqmBudget')::numeric = 15000::numeric / 783,
      'rinci', jsonb_build_object('sizePy1', v_c->'sizePy1', 'sizePy', v_c->'sizePy', 'revSqmPy', v_c->'revSqmPy')::text);
    hasil := hasil || jsonb_build_object('uji', 'Rumus: Total Price = 3 x Offering Price (E38); Price per m2/month = Offering / 783 / 12 tanpa IPL (E39); label RE-NEWAL',
      'lulus', (v_c->>'totalPrice')::numeric = 450000000 and (v_c->>'pricePerM2Month')::numeric = 150000000::numeric / 783 / 12
           and v_c->>'labelSewa' = 'RE-NEWAL / PERPANJANG SEWA',
      'rinci', jsonb_build_object('total', v_c->'totalPrice', 'm2', v_c->'pricePerM2Month', 'label', v_c->'labelSewa')::text);
    v_c := rental.hitung(rental.bersihkan(v_form || '{"totalYears":"2.5"}', false, '{}'), rental.revenue_akhir(rental.revenue(d.id, date '2026-10-27'), '{}'));
    hasil := hasil || jsonb_build_object('uji', 'Total Price for N Year diisi sendiri (2,5 tahun): Total = 2,5 x Offering Price; kosong = Rental Plane',
      'lulus', (v_c->>'totalYears')::numeric = 2.5 and (v_c->>'totalPrice')::numeric = 375000000
           and (rental.hitung(rental.bersihkan(v_form, false, '{}'), '{}')->>'totalYears')::numeric = 3,
      'rinci', jsonb_build_object('n', v_c->'totalYears', 'total', v_c->'totalPrice')::text);
    v_err := null; begin perform rental.bersihkan('{"totalYears":0}', false, '{}'); exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Total Price for 0 Year ditolak', 'lulus', coalesce(v_err, '') ~ 'lebih dari 0', 'rinci', coalesce(v_err, 'diterima!'));
    v_c := rental.hitung(rental.bersihkan('{}', false, '{}'), rental.revenue_akhir(rental.revenue(d2.id, date '2026-10-27'), '{}'));
    hasil := hasil || jsonb_build_object('uji', 'Rumus: pembagi kosong / 0 = null ("-", bukan #DIV/0!); label "-" sebelum jenis sewa dipilih',
      'lulus', v_c->'growthPy' = 'null'::jsonb and v_c->'revSqmPy' = 'null'::jsonb and v_c->'pricePerM2Month' = 'null'::jsonb and v_c->>'labelSewa' = '-',
      'rinci', v_c::text);
    x := rental.bersihkan(v_form, false, '{}');
    hasil := hasil || jsonb_build_object('uji', 'Teks otomatis huruf kapital, spasi dirapikan; Covered Area 10 kotak',
      'lulus', x->>'ownerName' = 'PT PEMILIK GUDANG' and x->'coveredArea'->>0 = 'JAKARTA BARAT' and jsonb_array_length(x->'coveredArea') = 10
           and x->>'competitorOther' = 'MEREK LAIN', 'rinci', (x->'coveredArea')::text);
    v_err := null; begin perform rental.bersihkan('{"offeringPrice":"12a"}', false, '{}'); exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Angka tidak valid ditolak, tidak ditebak', 'lulus', coalesce(v_err, '') ~ 'Offering Price harus angka', 'rinci', coalesce(v_err, 'diterima!'));

    -- ---- Upload Omset -------------------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_rental_omset_unggah(jsonb_build_array(
      jsonb_build_object('baris', 2, 'kodeDepot', lower(d.depot_code), 'omset', '2000', 'pajak', '200', 'bulan', '2026-08'),
      jsonb_build_object('baris', 3, 'kodeDepot', d.depot_code, 'omset', 1500, 'pajak', 50, 'bulan', '2026-09'),
      jsonb_build_object('baris', 4, 'kodeDepot', 'TIDAK-ADA', 'omset', 1, 'pajak', 0, 'bulan', '2026-09'),
      jsonb_build_object('baris', 5, 'kodeDepot', d.depot_code, 'omset', 1, 'pajak', -1, 'bulan', '2026-07'),
      jsonb_build_object('baris', 6, 'kodeDepot', d.depot_code, 'omset', 1, 'pajak', 0, 'bulan', '2026-13'),
      jsonb_build_object('baris', 7, 'kodeDepot', d.depot_code, 'omset', 1, 'pajak', 0, 'bulan', '2026-09'),
      jsonb_build_object('baris', 8, 'kodeDepot', d.depot_code, 'omset', '-300', 'pajak', '0', 'bulan', '2026-11')), false);
    hasil := hasil || jsonb_build_object('uji', 'Upload Omset pratinjau: 2 baru (termasuk omset negatif), 1 ditimpa, 4 galat (depot, pajak negatif, bulan, ganda)',
      'lulus', (r->>'baru')::int = 2 and (r->>'ditimpa')::int = 1 and (r->>'galat')::int = 4
           and (select net from rental.depot_revenue where depot_id = d.id and period = date '2026-09-01') = 1190 + 9,
      'rinci', (select string_agg((e->>'baris') || ':' || (e->>'status') || coalesce(' ' || (e->>'galat'), ''), ' | ') from jsonb_array_elements(r->'baris') e));
    r := public.rc_rental_omset_unggah(r->'baris', true, 'omset uji.xlsx');
    x := rental.revenue(d.id, date '2026-10-27');
    hasil := hasil || jsonb_build_object('uji', 'Upload Omset simpan: baris valid masuk (upsert), galat tidak; satu log upload',
      'lulus', (select net from rental.depot_revenue where depot_id = d.id and period = date '2026-08-01') = 1800
           and (select net from rental.depot_revenue where depot_id = d.id and period = date '2026-09-01') = 1450
           and (select net from rental.depot_revenue where depot_id = d.id and period = date '2026-11-01') = -300
           and x->'hilang' = '[]'::jsonb
           and exists(select 1 from rental.revenue_uploads u where u.file_name = 'omset uji.xlsx' and u.rows_inserted = 2 and u.rows_updated = 1 and u.rows_error = 4),
      'rinci', x::text);

    -- ---- Draft, submit, nomor --------------------------------------------------------------------
    r := public.rc_rental_simpan(null, d.id, date '2026-10-27', jsonb_build_object('leaseType', 'new', 'offeringPrice', 100000000), false);
    v_id := (r->'row'->>'id')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Draft tersimpan dengan isi; Revenue dari omset terbaru',
      'lulus', r->'row'->>'status' = 'draft' and (r->'row'->'revenue'->'actytd'->>'nilai')::numeric = (x->>'actytd')::numeric
           and r->'row'->'data'->>'leaseType' = 'new' and r->'row'->>'namaBerkas' = 'F01AW_' || d.depot_code || '_20261027_DRAFT.pdf',
      'rinci', left(((r->'row') - 'data' - 'omset')::text, 200));
    v_err := null; begin perform public.rc_rental_simpan(null, d.id, date '2026-03-01', '{}', false); exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Satu depot satu submission aktif per tahun: draft kedua ditolak', 'lulus', coalesce(v_err, '') ~ 'satu submission aktif', 'rinci', coalesce(v_err, 'tersimpan!'));
    v_err := null; begin perform public.rc_rental_simpan(v_id, d.id, date '2026-10-27', jsonb_build_object('leaseType', 'new'), true); exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Submit form belum lengkap ditolak dengan daftar field wajib',
      'lulus', coalesce(v_err, '') ~ 'belum lengkap' and v_err ~ 'Rental Plane' and v_err ~ 'Warehouse Size' and v_err ~ 'Properties Address', 'rinci', coalesce(v_err, 'tersubmit!'));

    -- Override Revenue: pemegang Upload Omset (SM memegang semua tab) wajib alasan.
    v_err := null; begin perform public.rc_rental_simpan(v_id, d.id, date '2026-10-27', v_form || jsonb_build_object('revOverride', jsonb_build_object('py', jsonb_build_object('nilai', 99999, 'alasan', ''))), false);
    exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Override Revenue tanpa alasan ditolak', 'lulus', coalesce(v_err, '') ~ 'Alasan override', 'rinci', coalesce(v_err, 'tersimpan!'));
    r := public.rc_rental_simpan(v_id, d.id, date '2026-10-27', v_form || jsonb_build_object('revOverride', jsonb_build_object('py', jsonb_build_object('nilai', 20000, 'alasan', 'koreksi SAP'))), true);
    hasil := hasil || jsonb_build_object('uji', 'Submit: nomor F01.AW.2026-' || v_abbr || ', override dipakai (sumber override + alasan), rumus memakai nilai override',
      'lulus', r->'row'->>'docNo' = 'F01.AW.2026-' || v_abbr and r->'row'->>'status' = 'submitted'
           and r->'row'->'revenue'->'py'->>'sumber' = 'override' and (r->'row'->'revenue'->'py'->>'nilai')::numeric = 20000
           and (r->'row'->'calc'->>'growthPy')::numeric = 20000::numeric / (x->>'py1')::numeric - 1
           and r->'row'->>'namaBerkas' = 'F01AW_' || d.depot_code || '_20261027_001.pdf',
      'rinci', coalesce(r->'row'->>'docNo', '-') || ' ' || coalesce(r->'row'->>'namaBerkas', ''));
    -- Angka dikunci saat submit.
    update rental.depot_revenue set omset = omset + 5000 where depot_id = d.id and period = date '2026-01-01';
    r := public.rc_rental_get(v_id);
    hasil := hasil || jsonb_build_object('uji', 'Upload ulang omset tidak mengubah form Submitted (snapshot)',
      'lulus', (r->'row'->'revenue'->'actytd'->>'nilai')::numeric = (x->>'actytd')::numeric, 'rinci', r->'row'->'revenue'->'actytd'->>'nilai');
    v_err := null; begin perform public.rc_rental_simpan(v_id, d.id, date '2026-10-27', v_form, false); exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Form Submitted terkunci', 'lulus', coalesce(v_err, '') ~ 'tidak dapat diubah', 'rinci', coalesce(v_err, 'berubah!'));
    hasil := hasil || jsonb_build_object('uji', 'Kebijakan Storage PDF: tulis sekali di <id>/, jalur lain ditolak, baca sebelum tersimpan ditolak',
      'lulus', public.rc_rental_pdf_boleh(v_id::text || '/F01AW_X.pdf', true) and not public.rc_rental_pdf_boleh(gen_random_uuid()::text || '/F01AW_X.pdf', true)
           and not public.rc_rental_pdf_boleh('../x.pdf', true) and not public.rc_rental_pdf_boleh(v_id::text || '/F01AW_X.pdf', false), 'rinci', '-');

    v_err := null; begin perform public.rc_rental_batal(v_id, ' '); exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Cancel form Submitted wajib alasan', 'lulus', coalesce(v_err, '') ~ 'Alasan pembatalan wajib', 'rinci', coalesce(v_err, 'batal!'));
    r := public.rc_rental_batal(v_id, 'gudang batal');
    r := public.rc_rental_simpan(null, d.id, date '2026-11-02', v_form, true);
    v_id2 := (r->'row'->>'id')::uuid;
    x := public.rc_rental_list('submitted');
    hasil := hasil || jsonb_build_object('uji', 'Sesudah Cancel boleh buat baru: nomor F01.AW.2026-' || v_abbr || '-2; daftar Submitted memuat keduanya',
      'lulus', r->'row'->>'docNo' = 'F01.AW.2026-' || v_abbr || '-2'
           and exists(select 1 from jsonb_array_elements(x->'rows') e where (e->>'id')::uuid = v_id and e->>'status' = 'cancelled' and e->>'alasanBatal' = 'gudang batal')
           and exists(select 1 from jsonb_array_elements(x->'rows') e where (e->>'id')::uuid = v_id2 and e->>'status' = 'submitted'),
      'rinci', coalesce(r->'row'->>'docNo', '-'));
    hasil := hasil || jsonb_build_object('uji', 'Audit: draft, submit, cancel tercatat di Log Activity (modul rental)',
      'lulus', (select count(*) from public.activity_logs where module = 'rental' and entity_id in (v_id, v_id2) and created_at = now()) >= 4
           and exists(select 1 from public.activity_logs where event_type = 'rental_omset_upload' and created_at = now()),
      'rinci', (select string_agg(event_type, ', ') from public.activity_logs where module = 'rental' and created_at = now()));

    -- Draft bukan dari pemegang Upload Omset: override lama dipertahankan, override baru diabaikan.
    x := rental.bersihkan(jsonb_build_object('revOverride', jsonb_build_object('py1', jsonb_build_object('nilai', 1, 'alasan', 'x'))), false,
                          jsonb_build_object('revOverride', jsonb_build_object('py', jsonb_build_object('nilai', 5, 'alasan', 'lama'))));
    hasil := hasil || jsonb_build_object('uji', 'Non-admin tidak dapat mengubah override', 'lulus', x->'revOverride' = '{"py":{"nilai":5,"alasan":"lama"}}'::jsonb, 'rinci', (x->'revOverride')::text);

    -- ---- Akses ----------------------------------------------------------------------------------
    if v_dh is null then
      hasil := hasil || jsonb_build_object('uji', 'Tab bawaan Depot Head', 'lulus', true, 'rinci', 'DILEWATI: tidak ada Depot Head aktif');
    else
      x := rc_private.tab_rights(v_dh);
      hasil := hasil || jsonb_build_object('uji', 'Tab bawaan Depot Head: Fill Form, Draft, Submitted menyala; Upload Omset hanya bila dicentang',
        'lulus', (x->>'rental.form')::boolean and (x->>'rental.draft')::boolean and (x->>'rental.submitted')::boolean and not (x->>'rental.omset')::boolean
             or exists(select 1 from rc_private.user_tab_access u where u.user_id = v_dh and u.tab_code like 'rental.%'),
        'rinci', jsonb_build_object('form', x->'rental.form', 'draft', x->'rental.draft', 'sub', x->'rental.submitted', 'omset', x->'rental.omset')::text);
    end if;
    if v_adm is null then
      hasil := hasil || jsonb_build_object('uji', 'Akun tanpa izin Warehouse Rental', 'lulus', true, 'rinci', 'DILEWATI: tidak ada admin aktif');
    else
      perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
      v_err := null; begin perform public.rc_rental_init(); exception when others then v_err := sqlerrm; end;
      hasil := hasil || jsonb_build_object('uji', 'Akun tanpa izin Warehouse Rental ditolak server', 'lulus', coalesce(v_err, '') ~ 'tidak diizinkan', 'rinci', coalesce(v_err, 'terbuka!'));
      v_err := null; begin perform public.rc_rental_omset_unggah('[{"baris":2}]', false); exception when others then v_err := sqlerrm; end;
      hasil := hasil || jsonb_build_object('uji', 'Upload Omset hanya untuk tab rental.omset', 'lulus', coalesce(v_err, '') ~ 'rental.omset', 'rinci', coalesce(v_err, 'terbuka!'));
      v_err := null; begin perform public.rc_rental_get(v_id2); exception when others then v_err := sqlerrm; end;
      hasil := hasil || jsonb_build_object('uji', 'Form tidak terbuka untuk akun tanpa tab', 'lulus', v_err is not null, 'rinci', coalesce(v_err, 'terbuka!'));
    end if;

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_wr(uji, lulus, rinci) select y->>'uji', (y->>'lulus')::boolean, y->>'rinci' from jsonb_array_elements(hasil) y;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_wr order by urut;
