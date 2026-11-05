-- ==========================================================================================
-- Uji Discount Center - migrasi 20261163310000 s.d. 20261163350000
-- ==========================================================================================
-- Kasus runTests spesifikasi (bagian 12) ditambah unggah, kartu, revisi, tarik, monitoring, dan
-- penolakan server. Seluruh uji berjalan di subtransaksi yang DIBATALKAN (UJI_SELESAI): master,
-- kebijakan, kartu, acknowledge, izin, dan jangkauan depot akun uji ikut dibatalkan. Periode uji
-- 2098-10 dan kode berawalan UJI supaya tidak bersinggungan dengan data asli.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_discount_center.sql
-- ==========================================================================================
create temp table if not exists _hasil_dc(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_dc;

create or replace function pg_temp.dc_sebagai(p_user uuid) returns void language sql as $f$
  select set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
$f$;

-- Satu baris KEBIJAKAN.
create or replace function pg_temp.kb(p_baris int, p_jenis text, p_mg text, p_mat text, p_qty text, p_uom text, p_disc text,
  p_wil text default 'NASIONAL', p_untuk text default '', p_dari text default '01.10.2098', p_sampai text default '31.10.2098')
returns jsonb language sql as $f$
  select jsonb_build_object('__BARIS', p_baris, 'PERIODE', '2098-10', 'JENIS', p_jenis, 'NO_MEMO', 'Memo Uji ' || p_jenis,
    'MG', p_mg, 'MATERIAL', p_mat, 'MG1', '', 'MG2', '', 'MG3', '', 'SCALE_QTY', p_qty, 'SCALE_UOM', p_uom, 'DISC', p_disc,
    'VALID_FROM', p_dari, 'VALID_TO', p_sampai, 'WILAYAH', p_wil, 'UNTUK_TARGET', p_untuk, 'CATATAN', '');
$f$;

do $uji$
declare
  v_sm uuid; v_adm uuid; v_adm2 uuid; v_sd uuid; d1 record; d2 record;
  hasil jsonb := '[]'; r jsonb; v_galat text; v_rows jsonb; v_kb jsonb; v_x jsonb; v_ids uuid[]; v_id uuid; v_id596 uuid;
  v_id022 uuid; v_idhawa uuid; v_kunci text; v_run uuid; n integer; v_txt text;
  v_log0 integer := (select count(*) from public.activity_logs where module = 'Discount Center');
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password
   order by user_code limit 1;
  select id into v_adm from public.profiles where role = 'admin' and status = 'active' and not must_change_password
   order by user_code limit 1;
  select id into v_adm2 from public.profiles where role = 'admin' and status = 'active' and id <> v_adm
   order by must_change_password, user_code limit 1;
  select id into v_sd from public.profiles where role in ('osc', 'supervisor', 'finance', 'others') and status = 'active'
     and not must_change_password order by user_code limit 1;
  select d.id, upper(d.depot_code) kode, upper(btrim(d.region)) region into d1 from public.depots d
   where d.archived_at is null and not d.bukan_depot and btrim(coalesce(d.region, '')) <> '' order by d.depot_code limit 1;
  select d.id, upper(d.depot_code) kode, upper(btrim(d.region)) region into d2 from public.depots d
   where d.archived_at is null and not d.bukan_depot and btrim(coalesce(d.region, '')) <> '' and upper(btrim(d.region)) <> d1.region
   order by d.depot_code limit 1;

  begin
    -- Akun uji: dua Admin Depot (depot d1 dan d2) dengan izin modul, satu Sales Distribution lewat tab.
    update public.profiles set must_change_password = false where id = v_adm2 and must_change_password;
    delete from public.user_depot_access where user_id in (v_adm, v_adm2);
    insert into public.user_depot_access(user_id, depot_id) values (v_adm, d1.id), (v_adm2, d2.id);
    insert into public.user_permissions(user_id, permission_code)
    select x, 'view_discount' from unnest(array[v_adm, v_adm2, v_sd]) x
     where not exists(select 1 from public.user_permissions up where up.user_id = x and up.permission_code = 'view_discount');
    delete from rc_private.user_tab_access where user_id in (v_adm, v_adm2, v_sd) and tab_code like 'discount.%';
    insert into rc_private.user_tab_access values (v_sd, 'discount.monitor', true), (v_sd, 'discount.generate', true);

    -- ---- Hak tab ------------------------------------------------------------------------
    perform pg_temp.dc_sebagai(v_sm);
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot: Dashboard + Acknowledge terbuka, 4 tab Sales Distribution tertutup bawaan',
      'lulus', disc.punya_tab(v_adm, 'discount.dashboard') and disc.punya_tab(v_adm, 'discount.ack')
           and not disc.punya_tab(v_adm, 'discount.monitor') and not disc.punya_tab(v_adm, 'discount.kebijakan')
           and not disc.punya_tab(v_adm, 'discount.generate') and not disc.punya_tab(v_adm, 'discount.terbit')
           and not disc.sd_user(v_adm),
      'rinci', rc_private.tab_rights(v_adm)->>'discount.dashboard');
    hasil := hasil || jsonb_build_object('uji', 'Sales Distribution ikut tab: user dengan tab Monitoring = SD', 'lulus', disc.sd_user(v_sd), 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'punya_tab sama dengan tab_rights untuk tab discount',
      'lulus', (select bool_and(disc.punya_tab(u, t) = coalesce((rc_private.tab_rights(u)->>t)::boolean, false))
                  from unnest(array[v_adm, v_sd, v_sm]) u,
                       unnest(array['discount.dashboard','discount.ack','discount.monitor','discount.kebijakan','discount.generate','discount.terbit']) t),
      'rinci', '-');

    -- ---- Rumus (runTests 1-3) -----------------------------------------------------------
    hasil := hasil || jsonb_build_object('uji', 'Vol 10 + CMP 5 + Bulk 5 = 18.775', 'lulus', disc.stack(array[10, 5, 5]) = 18.775,
      'rinci', disc.stack(array[10, 5, 5]));
    hasil := hasil || jsonb_build_object('uji', 'Vol 35 + CMP 5 + Bulk 3 = 40.103', 'lulus', disc.stack(array[35, 5, 3]) = 40.103,
      'rinci', disc.stack(array[35, 5, 3]));

    -- ---- Unggah master (System Manager) ---------------------------------------------------
    perform pg_temp.dc_sebagai(v_sm);
    r := public.rc_disc_unggah('MASTER_MG', jsonb_build_array(
      jsonb_build_object('__BARIS', 2, 'MG', 'uji022', 'NAMA_PRODUK', 'Copper Paint Uji', 'SEGMEN', 'lain-lain', 'JENIS_PRODUK', 'READY MIX', 'UOM_SCALE', 'KG', 'LEVEL_WAJIB', 'MG', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 3, 'MG', 'UJI596', 'NAMA_PRODUK', 'Weatherbond Uji', 'SEGMEN', 'DEKORATIF', 'JENIS_PRODUK', 'READY MIX', 'UOM_SCALE', 'L', 'LEVEL_WAJIB', 'MG', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 4, 'MG', 'UJI247', 'NAMA_PRODUK', 'Pylox Uji', 'SEGMEN', 'CAT SEMPROT', 'JENIS_PRODUK', 'READY MIX', 'UOM_SCALE', 'PC', 'LEVEL_WAJIB', 'KEMASAN', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 5, 'MG', 'UJIVPRO', 'NAMA_PRODUK', 'Vinilex Uji', 'SEGMEN', 'DEKORATIF', 'JENIS_PRODUK', '', 'UOM_SCALE', 'KG', 'LEVEL_WAJIB', 'MG', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 6, 'MG', 'UJIHAWA', 'NAMA_PRODUK', 'Roller Uji', 'SEGMEN', 'PAINTING TOOLS', 'JENIS_PRODUK', 'READY MIX', 'UOM_SCALE', 'PC', 'LEVEL_WAJIB', 'MG', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 7, 'MG', 'UJIBAD', 'NAMA_PRODUK', 'Salah', 'SEGMEN', 'CAT', 'UOM_SCALE', 'M', 'AKTIF', 'Y')), '{}', true);
    hasil := hasil || jsonb_build_object('uji', 'MASTER_MG: 5 disimpan (1 CEK JENIS_PRODUK kosong), 1 error SEGMEN/UOM',
      'lulus', (r->>'ok')::int = 4 and (r->>'cek')::int = 1 and (r->>'error')::int = 1
           and exists(select 1 from disc.master_mg where mg = 'UJI022' and segmen = 'LAIN-LAIN')
           and not exists(select 1 from disc.master_mg where mg = 'UJIBAD'), 'rinci', r->>'pesan');

    r := public.rc_disc_unggah('MASTER_MATERIAL', jsonb_build_array(
      jsonb_build_object('__BARIS', 2, 'MATERIAL', 'UJIM1', 'DESKRIPSI', 'PYLOX UJI Z01 3R', 'MG', 'UJI247', 'MG1', '3R', 'MG2', 'Z01', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 3, 'MATERIAL', 'UJIM2', 'DESKRIPSI', 'PYLOX UJI Z02 3R', 'MG', 'UJI247', 'MG1', '3R', 'MG2', 'Z02', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 4, 'MATERIAL', 'UJI3244', 'DESKRIPSI', '4.5K-VPRO UJI', 'MG', 'UJIVPRO', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 5, 'MATERIAL', 'UJIX', 'DESKRIPSI', 'X', 'MG', 'UJINEW', 'AKTIF', 'Y')), '{"mg":{"UJINEW":{}}}', false);
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau MASTER_MATERIAL mengenali MG baru dari sheet MASTER_MG di berkas yang sama',
      'lulus', (r->>'error')::int = 0 and not (r->>'disimpan')::boolean and not exists(select 1 from disc.master_material where material = 'UJIM1'),
      'rinci', r->>'pesan');
    r := public.rc_disc_unggah('MASTER_MATERIAL', jsonb_build_array(
      jsonb_build_object('__BARIS', 2, 'MATERIAL', 'UJIM1', 'DESKRIPSI', 'PYLOX UJI Z01 3R', 'MG', 'UJI247', 'MG1', '3R', 'MG2', 'Z01', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 3, 'MATERIAL', 'UJIM2', 'DESKRIPSI', 'PYLOX UJI Z02 3R', 'MG', 'UJI247', 'MG1', '3R', 'MG2', 'Z02', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 4, 'MATERIAL', 'UJI3244', 'DESKRIPSI', '4.5K-VPRO UJI', 'MG', 'UJIVPRO', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 5, 'MATERIAL', 'UJIX', 'DESKRIPSI', 'X', 'MG', 'UJINEW', 'AKTIF', 'Y')), '{}', true);
    hasil := hasil || jsonb_build_object('uji', 'MASTER_MATERIAL: MG tidak ada di master = ERROR_MG, sisanya disimpan',
      'lulus', (r->>'ok')::int = 3 and (r->>'error')::int = 1 and r->'pesan'->0->>'pesan' like 'ERROR_MG%', 'rinci', r->>'pesan');

    r := public.rc_disc_unggah('TARGET', jsonb_build_array(
      jsonb_build_object('__BARIS', 2, 'TARGET_ID', 'UJI-TK1', 'TIPE', 'CUSTOMER', 'KODE', '900001', 'NAMA', 'TOKO UJI SATU', 'DC', d1.kode, 'GRUP', 'UJI_TK', 'ATURAN_DISC', 'OPEN_QTY', 'LABEL_OUTPUT', 'Toko Khusus Uji', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 3, 'TARGET_ID', 'UJI-TK2', 'TIPE', 'CUSTOMER', 'KODE', '900002', 'NAMA', 'TOKO UJI DUA', 'DC', d1.kode, 'GRUP', 'UJI_TK', 'ATURAN_DISC', 'OPEN_QTY', 'LABEL_OUTPUT', 'Toko Khusus Uji', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 4, 'TARGET_ID', 'UJI-GAV', 'TIPE', 'CUSTOMER', 'KODE', '900003', 'NAMA', 'GAVINDO UJI', 'DC', d1.kode, 'GRUP', 'UJI_TK', 'ATURAN_DISC', 'OPEN_QTY_TANPA_BULK', 'AKTIF', 'Y'),
      jsonb_build_object('__BARIS', 5, 'TARGET_ID', 'UJI-ORG', 'TIPE', 'SLS_ORG', 'KODE', '1100,1400', 'CUST_GROUP', '5', 'NAMA', 'Sls Org Uji', 'ATURAN_DISC', 'NORMAL', 'AKTIF', 'Y')), '{}', true);
    hasil := hasil || jsonb_build_object('uji', 'TARGET: kode "1100,1400" tetap teks, CustGrp 5 ditulis 05 (CEK)',
      'lulus', (r->>'ok')::int = 3 and (r->>'cek')::int = 1
           and exists(select 1 from disc.target where target_id = 'UJI-ORG' and kode = '1100,1400' and cust_group = '05'), 'rinci', r->>'pesan');

    -- ---- Unggah KEBIJAKAN -------------------------------------------------------------------
    r := public.rc_disc_unggah('KEBIJAKAN', jsonb_build_array(
      pg_temp.kb(2, 'VOL', 'UJI999', '', '10', 'L', '10'),
      pg_temp.kb(3, 'VOL', 'UJI022', '', '12', 'KG', '5', 'NASIONAL', '', '2098-10-01', '31.10.2098'),
      pg_temp.kb(4, 'VOL', 'UJI022', '', '100', 'L', '9'),
      pg_temp.kb(5, 'VOL', 'UJI022', '', '12', 'KG', '5', 'ZZ9')), '{}', false);
    hasil := hasil || jsonb_build_object('uji', 'Validasi KEBIJAKAN: ERROR_MG, ERROR_TANGGAL, wilayah tidak dikenal = error; satuan beda master = CEK_UOM',
      'lulus', (r->>'error')::int = 3 and (r->>'cek')::int = 1
           and exists(select 1 from jsonb_array_elements(r->'pesan') x where x->>'pesan' like 'ERROR_MG%')
           and exists(select 1 from jsonb_array_elements(r->'pesan') x where x->>'pesan' like 'ERROR_TANGGAL%')
           and exists(select 1 from jsonb_array_elements(r->'pesan') x where x->>'status' = 'CEK' and x->>'pesan' like 'CEK_UOM%')
           and not exists(select 1 from disc.kebijakan where periode = '2098-10'), 'rinci', r->>'pesan');

    v_kb := jsonb_build_array(
      pg_temp.kb(2, 'VOL', 'UJI022', '', '12', 'KG', '5'), pg_temp.kb(3, 'VOL', 'UJI022', '', '30', 'KG', '7'),
      pg_temp.kb(4, 'VOL', 'UJI022', '', '50', 'KG', '9'), pg_temp.kb(5, 'CMP', 'UJI022', '', '', '', '5'),
      pg_temp.kb(6, 'FAKTUR', 'UJI022', '', '', '', '3'),
      pg_temp.kb(7, 'VOL', 'UJI596', '', '10', 'L', '15'), pg_temp.kb(8, 'CMP', 'UJI596', '', '', '', '5'),
      pg_temp.kb(9, 'VOL', '', 'UJI3244', '', '', '35', 'NASIONAL', 'UJI_TK'),
      pg_temp.kb(10, 'CMP', '', 'UJI3244', '', '', '5', 'NASIONAL', 'UJI_TK'),
      pg_temp.kb(11, 'BULK', '', 'UJI3244', '', '', '3', 'NASIONAL', 'UJI_TK'),
      pg_temp.kb(12, 'VOL', 'UJI247', '', '', '', '10', 'NASIONAL', 'UJI_TK'),
      pg_temp.kb(13, 'CMP', 'UJI247', '', '', '', '5', 'NASIONAL', 'UJI_TK'),
      pg_temp.kb(14, 'BULK', 'UJI247', '', '', '', '5', 'NASIONAL', 'UJI_TK'),
      pg_temp.kb(15, 'BP', 'UJI247', '', '', '', '2', 'NASIONAL', 'UJI_TK'),
      pg_temp.kb(16, 'PROMO', 'UJIHAWA', '', '24', 'PC', '20', 'REGION ' || d2.region));
    r := public.rc_disc_unggah('KEBIJAKAN', v_kb, '{}', true);
    hasil := hasil || jsonb_build_object('uji', 'KEBIJAKAN: 15 baris valid tersimpan, MG diisi dari MATERIAL',
      'lulus', (r->>'error')::int = 0 and (select count(*) from disc.kebijakan where periode = '2098-10' and diganti_pada is null) = 15
           and exists(select 1 from disc.kebijakan where periode = '2098-10' and material = 'UJI3244' and mg = 'UJIVPRO'), 'rinci', r->>'pesan');

    -- ---- Generate ---------------------------------------------------------------------------
    r := public.rc_disc_generate('2098-10', 'RA08', array['KOSONG:SLS_OFFICE']);
    v_rows := (select jsonb_agg(x) from jsonb_array_elements(r->'rows') x where x->>'mg' = 'UJI022');
    hasil := hasil || jsonb_build_object('uji', 'RA08 PER_SCALE FERT022: 12 = 9.75, 30 = 11.65, 50 = 13.55 (CMP tanpa scale ikut semua tier)',
      'lulus', jsonb_array_length(v_rows) = 3
           and (select string_agg((x->>'scale') || '=' || (x->'f'->>'AMOUNT'), ',' order by (x->>'scale')::numeric) from jsonb_array_elements(v_rows) x)
               = '12=9.75,30=11.65,50=13.55'
           and v_rows->0->>'level' = 'SLSOFF_CG_MG' and v_rows->0->'f'->>'UOM' = 'KG' and v_rows->0->'f'->>'VALID_FROM' = '01.10.2098'
           and v_rows->0->'f'->>'REMARK1' like 'scale 12 KG (Vol 5% + CMP 5%)%' and v_rows->0->'f'->>'DISC_TYPE' = 'Disc Vol + Disc CMP',
      'rinci', (select string_agg((x->>'scale') || '=' || (x->'f'->>'AMOUNT') || ' ' || (x->'f'->>'REMARK1'), ' | ') from jsonb_array_elements(v_rows) x));
    hasil := hasil || jsonb_build_object('uji', 'RA08 (KG) melewati MG satuan L, PROMO bukan komponen RA08, FAKTUR tidak ikut dihitung',
      'lulus', r->'ringkas'->'dilewati' = '["UJI596"]'
           and not exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'mg' in ('UJI596', 'UJIHAWA')),
      'rinci', r->'ringkas'->>'dilewati');

    r := public.rc_disc_generate('2098-10', 'RA01', array['GRUP:UJI_TK'], array['VOL','CMP','BULK','BP'], false, 'SEMUA', false);
    v_rows := r->'rows';
    hasil := hasil || jsonb_build_object('uji', 'OPEN_QTY: tier VOL tertinggi + CMP (FERT022 Toko Khusus = 13.55), BP tidak ikut walau dicentang',
      'lulus', (select bool_and(x->'f'->>'AMOUNT' = '13.55') from jsonb_array_elements(v_rows) x where x->>'mg' = 'UJI022')
           and (select bool_and(x->'f'->>'AMOUNT' = '18.775' and x->'f'->>'REMARK1' not like '%BP%') from jsonb_array_elements(v_rows) x
                 where x->>'mg' = 'UJI247' and x->>'tid' <> 'UJI-GAV')
           and (select bool_and(x->'f'->>'AMOUNT' = '40.103') from jsonb_array_elements(v_rows) x where x->>'material' = 'UJI3244' and x->>'tid' <> 'UJI-GAV'),
      'rinci', (select string_agg((x->>'tid') || ' ' || (x->>'mg') || ' ' || (x->'f'->>'AMOUNT'), ' | ') from jsonb_array_elements(v_rows) x));
    hasil := hasil || jsonb_build_object('uji', 'Target OPEN_QTY_TANPA_BULK (Gavindo) tidak memasukkan BULK',
      'lulus', (select string_agg((x->>'mg') || coalesce('/' || (x->>'material'), '') || '=' || (x->'f'->>'AMOUNT'), ',' order by x->>'mg', x->>'mg2')
                  from jsonb_array_elements(v_rows) x where x->>'tid' = 'UJI-GAV' and x->>'mg' in ('UJI247', 'UJIVPRO'))
               = 'UJI247=14.5,UJI247=14.5,UJIVPRO/UJI3244=38.25'
           and not exists(select 1 from jsonb_array_elements(v_rows) x where x->>'tid' = 'UJI-GAV' and x->'f'->>'REMARK1' like '%Bulk%'),
      'rinci', (select string_agg((x->>'mg') || '=' || (x->'f'->>'AMOUNT') || ' ' || (x->'f'->>'REMARK2'), ' | ') from jsonb_array_elements(v_rows) x where x->>'tid' = 'UJI-GAV'));
    hasil := hasil || jsonb_build_object('uji', 'MG LEVEL_WAJIB=KEMASAN tidak pernah ditulis ke level MG (dipecah ke kombinasi MASTER_MATERIAL)',
      'lulus', not exists(select 1 from jsonb_array_elements(v_rows) x where x->>'mg' = 'UJI247' and x->>'level' = 'CUST_MG')
           and (select count(*) from jsonb_array_elements(v_rows) x where x->>'mg' = 'UJI247' and x->>'level' = 'CUST_MG_MG2_MG1') = 6
           and exists(select 1 from jsonb_array_elements(v_rows) x where x->>'mg' = 'UJI247' and x->'f'->>'MG2' = 'Z02' and x->'f'->>'MG1' = '3R'),
      'rinci', (select string_agg(distinct x->>'level', ',') from jsonb_array_elements(v_rows) x where x->>'mg' = 'UJI247'));
    hasil := hasil || jsonb_build_object('uji', 'Wilayah: kebijakan REGION lain tidak masuk target ber-DC; material ke level CUST_MAT',
      'lulus', not exists(select 1 from jsonb_array_elements(v_rows) x where x->>'mg' = 'UJIHAWA')
           and (select bool_and(x->>'level' = 'CUST_MAT' and x->'f'->>'DESCRIPTION' = '4.5K-VPRO UJI') from jsonb_array_elements(v_rows) x where x->>'material' = 'UJI3244'),
      'rinci', '-');

    r := public.rc_disc_generate('2098-10', 'RA01', array['GRUP:UJI_TK'], null, true, 'KHUSUS', false);
    v_x := (select x from jsonb_array_elements(r->'rows') x where x->>'material' = 'UJI3244' and x->'f'->>'TARGET' = 'Toko Khusus Uji');
    hasil := hasil || jsonb_build_object('uji', 'Per grup: TK1 + TK2 digabung, kolom Customer = LABEL_OUTPUT, Remark 2 "List ... (3 toko), exc Gavindo"',
      'lulus', v_x is not null and v_x->'f'->>'REMARK2' like 'Open Qty, List Toko Khusus Uji (3 toko), exc GAVINDO UJI%'
           and jsonb_array_length(v_x->'tids') = 2 and v_x->'f'->>'DISC_TYPE' = 'Disc Open Qty (Vol, Bulk, CMP)'
           and not exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'mg' in ('UJI022', 'UJI596')),
      'rinci', coalesce(v_x->'f'->>'REMARK2', '-') || ' / ' || (r->'ringkas'->>'baris'));

    -- Snapshot dan BERUBAH (record lama VALID_TO = VALID_FROM - 1 hari).
    r := public.rc_disc_generate('2098-10', 'RA08', array['KOSONG:SLS_OFFICE'], null, false, 'SEMUA', true);
    v_run := (r->>'run')::uuid;
    v_kunci := (select x->>'kunci' from jsonb_array_elements(r->'rows') x where x->>'mg' = 'UJI022' and (x->>'scale')::numeric = 12);
    hasil := hasil || jsonb_build_object('uji', 'Download (catat) menyimpan snapshot generate dan satu Log Activity',
      'lulus', v_run is not null and (select count(*) from disc.generate_baris where run_id = v_run) = 3
           and exists(select 1 from public.activity_logs where event_type = 'discount_generate' and details->>'run' = v_run::text),
      'rinci', r->>'ringkas');
    insert into disc.generate_run(id, periode, condition_type, target, komponen, per_grup) values
      (gen_random_uuid(), '2098-09', 'RA08', 'KOSONG:SLS_OFFICE', '{VOL,CMP}', false) returning id into v_id;
    insert into disc.generate_baris(run_id, kunci, level, condition_type, target_kode, mg, amount, scale_qty, scale_uom, valid_from, valid_to)
    values (v_id, v_kunci, 'SLSOFF_CG_MG', 'RA08', '', 'UJI022', 9.5, 12, 'KG', '2098-09-01', '2098-09-30');
    r := public.rc_disc_generate('2098-10', 'RA08', array['KOSONG:SLS_OFFICE']);
    v_x := (select x from jsonb_array_elements(r->'rows') x where x->>'kunci' = v_kunci);
    hasil := hasil || jsonb_build_object('uji', 'BERUBAH: Amount beda dari record periode sebelumnya (VALID_TO = VALID_FROM - 1)',
      'lulus', v_x->'flags' ? 'BERUBAH' and (v_x->>'amountLama')::numeric = 9.5
           and (select count(*) from jsonb_array_elements(r->'rows') x where x->'flags' ? 'BERUBAH') = 1, 'rinci', v_x->>'ket');

    -- ---- Kartu: draft dan terbit ----------------------------------------------------------
    r := public.rc_disc_draft_buat('2098-10');
    hasil := hasil || jsonb_build_object('uji', 'Draft: 7 kartu (3 semua customer, 2 Toko Khusus open qty, 2 Gavindo tanpa bulk)',
      'lulus', (r->>'baru')::int = 7 and (select count(*) from disc.kartu where periode = '2098-10') = 7, 'rinci', r::text);
    select id into v_id022 from disc.kartu where periode = '2098-10' and kunci_item = 'MG:UJI022' and kunci_target = '*';
    select id into v_id596 from disc.kartu where periode = '2098-10' and kunci_item = 'MG:UJI596';
    select id into v_idhawa from disc.kartu where periode = '2098-10' and kunci_item = 'MG:UJIHAWA';
    v_x := (select draft from disc.kartu where id = v_id022);
    hasil := hasil || jsonb_build_object('uji', 'Kartu semua customer: tier sama dengan generate, FAKTUR tampil tidak dihitung',
      'lulus', (select string_agg((x->>'syarat') || '=' || (x->>'total'), ',') from jsonb_array_elements(v_x->'isi'->'tiers') x)
               = '12 KG=9.75,30 KG=11.65,50 KG=13.55'
           and v_x->'isi'->'faktur'->0->>'d' = '3' and v_x->>'remark' = 'Disc volume + campaign, semua customer'
           and v_x->'tampil_di' = '["NASIONAL"]' and v_x->>'condition_type' = 'RA08' and v_x->>'key_combination' = 'Sls Off / CG / MG',
      'rinci', v_x->>'remark' || ' / ' || (v_x->'isi'->>'tiers') || ' / ' || (v_x->>'condition_type'));
    v_x := (select draft from disc.kartu where periode = '2098-10' and kunci_item = 'MAT:UJI3244' and kunci_target = 'UJI_TK:OPEN_QTY');
    hasil := hasil || jsonb_build_object('uji', 'Kartu Toko Khusus: Open Qty 40.103, kecuali Gavindo, tampil di depot target',
      'lulus', v_x->'isi'->'tiers'->0->>'syarat' = 'Open Qty' and (v_x->'isi'->'tiers'->0->>'total')::numeric = 40.103
           and v_x->>'remark' = 'Toko Khusus Uji (open qty), kecuali GAVINDO UJI' and v_x->'tampil_di' = jsonb_build_array(d1.kode),
      'rinci', coalesce(v_x->>'remark', '-') || ' / ' || coalesce(v_x->>'tampil_di', '-'));
    v_x := (select draft from disc.kartu where periode = '2098-10' and kunci_item = 'MG:UJI247' and kunci_target = 'UJI_TK:OPEN_QTY_TANPA_BULK');
    hasil := hasil || jsonb_build_object('uji', 'Kartu Gavindo: tanpa Bulk dan tanpa BP (14.5)',
      'lulus', (v_x->'isi'->'tiers'->0->>'total')::numeric = 14.5 and v_x->'isi'->'tiers'->0->>'bulk' is null
           and jsonb_array_length(v_x->'isi'->'tiers'->0->'lain') = 0 and v_x->>'remark' = 'GAVINDO UJI (open qty tanpa bulk)',
      'rinci', coalesce(v_x->>'remark', '-') || ' / ' || coalesce(v_x->'isi'->>'tiers', '-'));
    hasil := hasil || jsonb_build_object('uji', 'Kartu promo REGION: tampil di region itu saja',
      'lulus', (select draft->'tampil_di' from disc.kartu where id = v_idhawa) = jsonb_build_array('REGION ' || d2.region), 'rinci', '-');

    v_ids := array(select id from disc.kartu where periode = '2098-10');
    perform pg_temp.dc_sebagai(v_adm);
    begin perform public.rc_disc_terbit(v_ids); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot memanggil Terbitkan langsung: ditolak server', 'lulus', v_galat ~ 'discount\.terbit', 'rinci', v_galat);
    begin perform public.rc_disc_generate('2098-10', 'RA08', array['KOSONG:SLS_OFFICE']); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot memanggil Generate langsung: ditolak server', 'lulus', v_galat ~ 'discount\.generate', 'rinci', v_galat);
    begin perform public.rc_disc_unggah('MASTER_MG', '[]', '{}', true); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot memanggil Unggah langsung: ditolak server', 'lulus', v_galat ~ 'discount\.kebijakan', 'rinci', v_galat);
    begin perform public.rc_disc_monitor(null); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot memanggil Monitoring langsung: ditolak server', 'lulus', v_galat ~ 'discount\.monitor', 'rinci', v_galat);
    r := public.rc_disc_dashboard();
    hasil := hasil || jsonb_build_object('uji', 'Draft tidak terlihat di dashboard', 'lulus',
      not exists(select 1 from jsonb_array_elements(r->'kartu') x where x->>'periode' = '2098-10'), 'rinci', '-');

    perform pg_temp.dc_sebagai(v_sm);
    r := public.rc_disc_terbit(v_ids);
    hasil := hasil || jsonb_build_object('uji', 'Terbit 7 kartu versi 1',
      'lulus', (r->>'baru')::int = 7 and (select bool_and(status = 'TERBIT' and versi = 1 and draft is null) from disc.kartu where id = any(v_ids)),
      'rinci', r::text);

    -- ---- Dashboard per wilayah (runTests 7) -------------------------------------------------
    perform pg_temp.dc_sebagai(v_adm);
    r := public.rc_disc_dashboard();
    v_rows := (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(r->'kartu') x where x->>'periode' = '2098-10');
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot ' || d1.kode || ' tidak menerima kartu yang TAMPIL_DI-nya hanya region lain',
      'lulus', jsonb_array_length(v_rows) = 6 and not exists(select 1 from jsonb_array_elements(v_rows) x where x->>'id' = v_idhawa::text)
           and not (r->>'sd')::boolean,
      'rinci', jsonb_array_length(v_rows));
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot: CT, key combination, wilayah tidak dikirim; Depot = kode depot user',
      'lulus', (select bool_and(x->>'ct' is null and x->>'key' is null and x->>'wilayah' is null and x->'depotTercakup' = jsonb_build_array(d1.kode))
                  from jsonb_array_elements(v_rows) x), 'rinci', v_rows->0->>'depotTercakup');
    perform pg_temp.dc_sebagai(v_adm2);
    r := public.rc_disc_dashboard();
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot ' || d2.kode || ' (region ' || d2.region || '): melihat promo region-nya, tidak melihat kartu depot ' || d1.kode,
      'lulus', (select count(*) from jsonb_array_elements(r->'kartu') x where x->>'periode' = '2098-10') = 3
           and exists(select 1 from jsonb_array_elements(r->'kartu') x where x->>'id' = v_idhawa::text), 'rinci', '-');
    perform pg_temp.dc_sebagai(v_sd);
    r := public.rc_disc_dashboard();
    hasil := hasil || jsonb_build_object('uji', 'Sales Distribution: semua kartu, dengan CT dan wilayah',
      'lulus', (r->>'sd')::boolean and (select count(*) from jsonb_array_elements(r->'kartu') x where x->>'periode' = '2098-10') = 7
           and (select x->>'ct' from jsonb_array_elements(r->'kartu') x where x->>'id' = v_id022::text) = 'RA08', 'rinci', '-');

    -- ---- Acknowledge dan revisi (runTests 8) ---------------------------------------------
    perform pg_temp.dc_sebagai(v_adm);
    r := public.rc_disc_ack((select jsonb_agg(jsonb_build_object('id', x->>'id', 'versi', x->'versi')) from jsonb_array_elements(v_rows) x));
    hasil := hasil || jsonb_build_object('uji', 'Acknowledge 6 kartu tercatat dengan versinya', 'lulus', (r->>'dicatat')::int = 6, 'rinci', r::text);
    r := public.rc_disc_ack(jsonb_build_array(jsonb_build_object('id', v_idhawa, 'versi', 1)));
    hasil := hasil || jsonb_build_object('uji', 'Acknowledge kartu di luar wilayah tidak dicatat', 'lulus', (r->>'dicatat')::int = 0, 'rinci', r::text);

    perform pg_temp.dc_sebagai(v_sm);
    v_kb := (select jsonb_agg(case when x->>'JENIS' = 'CMP' and x->>'MG' = 'UJI022' then x || '{"DISC":"6"}' else x end) from jsonb_array_elements(v_kb) x);
    r := public.rc_disc_unggah('KEBIJAKAN', v_kb, '{}', true);
    hasil := hasil || jsonb_build_object('uji', 'Unggah ulang KEBIJAKAN mengarsipkan baris lama periode itu (tidak dihapus)',
      'lulus', (select count(*) from disc.kebijakan where periode = '2098-10' and diganti_pada is not null) = 15
           and (select count(*) from disc.kebijakan where periode = '2098-10' and diganti_pada is null) = 15, 'rinci', '-');
    r := public.rc_disc_draft_buat('2098-10');
    hasil := hasil || jsonb_build_object('uji', 'Draft ulang: hanya kartu FERT022 berubah', 'lulus', (r->>'berubah')::int = 1 and (r->>'sama')::int = 6,
      'rinci', r::text);
    r := public.rc_disc_terbit_list('2098-10');
    hasil := hasil || jsonb_build_object('uji', 'Daftar Terbitkan menandai kartu itu REVISI',
      'lulus', (select x->>'perubahan' from jsonb_array_elements(r->'kartu') x where x->>'id' = v_id022::text) = 'REVISI', 'rinci', '-');
    r := public.rc_disc_terbit(array[v_id022]);
    hasil := hasil || jsonb_build_object('uji', 'Terbit revisi: versi 2, teks revisi menyebut Disc CMP',
      'lulus', (r->>'revisi')::int = 1 and (select versi = 2 and isi->>'revisi' like 'Disc CMP diperbarui pada versi 2%' from disc.kartu where id = v_id022),
      'rinci', (select isi->>'revisi' from disc.kartu where id = v_id022));
    perform pg_temp.dc_sebagai(v_adm);
    r := public.rc_disc_dashboard();
    hasil := hasil || jsonb_build_object('uji', 'Kartu yang naik versi muncul lagi di antrean user yang sudah acknowledge versi lama',
      'lulus', (select x->>'ack' is null and (x->>'versi')::int = 2 from jsonb_array_elements(r->'kartu') x where x->>'id' = v_id022::text)
           and (select count(*) from jsonb_array_elements(r->'kartu') x where x->>'periode' = '2098-10' and x->>'ack' is not null) = 5,
      'rinci', '-');

    -- ---- Wilayah tampil dan tarik -----------------------------------------------------------
    perform pg_temp.dc_sebagai(v_sm);
    begin perform public.rc_disc_atur_wilayah(array[v_idhawa], 'NASIONAL,ZZ9'); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Atur wilayah: token tidak dikenal ditolak', 'lulus', v_galat ~ 'ZZ9', 'rinci', v_galat);
    r := public.rc_disc_atur_wilayah(array[v_idhawa], 'nasional');
    r := public.rc_disc_terbit(array[v_idhawa]);
    hasil := hasil || jsonb_build_object('uji', 'Ubah wilayah tampil lalu terbit: versi tetap 1',
      'lulus', (r->>'wilayah')::int = 1 and (select versi = 1 and tampil_di = '{NASIONAL}' from disc.kartu where id = v_idhawa), 'rinci', r::text);
    r := public.rc_disc_draft_buat('2098-10');
    hasil := hasil || jsonb_build_object('uji', 'Draft ulang mempertahankan wilayah tampil yang sudah diatur', 'lulus',
      (select draft is null and tampil_di = '{NASIONAL}' from disc.kartu where id = v_idhawa), 'rinci', r::text);
    begin perform public.rc_disc_tarik(array[v_id596], ' '); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Tarik tanpa alasan ditolak', 'lulus', v_galat ~ 'Alasan', 'rinci', v_galat);
    r := public.rc_disc_tarik(array[v_id596], 'Uji tarik');
    perform pg_temp.dc_sebagai(v_adm);
    r := public.rc_disc_dashboard();
    hasil := hasil || jsonb_build_object('uji', 'Kartu DITARIK hilang dari dashboard, catatan acknowledge tetap disimpan',
      'lulus', not exists(select 1 from jsonb_array_elements(r->'kartu') x where x->>'id' = v_id596::text)
           and exists(select 1 from disc.ack where kartu_id = v_id596 and user_id = v_adm)
           and exists(select 1 from jsonb_array_elements(r->'kartu') x where x->>'id' = v_idhawa::text and x->>'ack' is null),
      'rinci', '-');

    -- ---- Monitoring -------------------------------------------------------------------------
    perform pg_temp.dc_sebagai(v_sd);
    r := public.rc_disc_monitor('2098-10');
    hasil := hasil || jsonb_build_object('uji', 'Monitoring: Admin Depot wajib, Sales Distribution tidak; daftar yang belum memuat kartu revisi',
      'lulus', exists(select 1 from jsonb_array_elements(r->'belum') x where x->>'kartuId' = v_id022::text
                        and x->>'userCode' = (select user_code from public.profiles where id = v_adm))
           and not exists(select 1 from jsonb_array_elements(r->'belum') x where x->>'userCode' = (select user_code from public.profiles where id = v_sd))
           and (r->'ringkas'->>'kartu')::int = 6
           and exists(select 1 from jsonb_array_elements(r->'depot') x where x->>'kode' = d1.kode and (x->>'user')::int = 1
                        and (x->>'wajib')::int = 6 and (x->>'sudah')::int = 4),
      'rinci', (r->>'ringkas') || ' / ' || coalesce((select x::text from jsonb_array_elements(r->'depot') x where x->>'kode' = d1.kode), '-'));
    v_x := (select x from jsonb_array_elements(r->'kartu') x where x->>'id' = v_id022::text);
    hasil := hasil || jsonb_build_object('uji', 'Monitoring per kartu: wajib dan sudah dihitung dari user yang melihat kartu',
      'lulus', (v_x->>'wajib')::int >= 2 and (v_x->>'sudah')::int = 0, 'rinci', v_x::text);

    -- ---- Log dan keamanan -------------------------------------------------------------------
    select count(*) - v_log0 into n from public.activity_logs where module = 'Discount Center';
    hasil := hasil || jsonb_build_object('uji', 'Log Activity satu baris per proses (5 simpan unggah + 1 generate + 3 draft + 3 terbit + 1 wilayah + 1 tarik + 1 ack; pratinjau dan penolakan tidak)',
      'lulus', n = 15, 'rinci', n);
    hasil := hasil || jsonb_build_object('uji', 'Schema disc tertutup bagi authenticated dan anon (hanya lewat RPC)',
      'lulus', not has_schema_privilege('authenticated', 'disc', 'usage') and not has_schema_privilege('anon', 'disc', 'usage')
           and not has_table_privilege('authenticated', 'disc.kartu', 'select')
           and not has_function_privilege('anon', 'public.rc_disc_dashboard()', 'execute')
           and has_function_privilege('authenticated', 'public.rc_disc_dashboard()', 'execute'), 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;

  insert into _hasil_dc(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_dc order by urut;
