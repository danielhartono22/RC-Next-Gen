-- ==========================================================================================
-- Uji Timetable > Details Campaign dan Variant Campaign Master - migrasi 20261163200000
-- ==========================================================================================
-- Seluruh uji berjalan di subtransaksi yang DIBATALKAN (UJI_SELESAI): campaign uji, izin,
-- Not Participating, Exclude, dan centang tab ikut dibatalkan. Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_timetable_campaign.sql
-- ==========================================================================================
create temp table if not exists _hasil_ttc(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_ttc;

create or replace function pg_temp.ttc_sebagai(p_user uuid) returns void language sql as $f$
  select set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
$f$;

do $uji$
declare v_sm uuid; v_tt uuid; v_lain uuid; hasil jsonb := '[]'; r jsonb; v_row jsonb; v_galat text; v_tabs jsonb; n integer; c record;
  v_kode text := 'UJITTC' || to_char(clock_timestamp(), 'HH24MISS'); d1 record; d2 record; d3 record;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- Dua akun biasa: v_tt diberi izin Timetable, v_lain tidak.
  select id into v_tt from public.profiles where role in ('osc', 'admin', 'finance', 'others', 'supervisor') and status = 'active' and not must_change_password
   order by user_code limit 1;
  select id into v_lain from public.profiles where role in ('osc', 'admin', 'finance', 'others', 'supervisor') and status = 'active' and not must_change_password
     and id <> v_tt order by user_code limit 1;
  -- Tiga depot: d1 dan d2 satu region, d3 region lain.
  select d.id, d.depot_code, upper(btrim(d.region)) region into d1 from public.depots d
   where d.archived_at is null and btrim(coalesce(d.region, '')) <> ''
     and (select count(*) from public.depots x where x.archived_at is null and upper(btrim(x.region)) = upper(btrim(d.region))) >= 2
   order by d.depot_code limit 1;
  select d.id, d.depot_code into d2 from public.depots d where d.archived_at is null and upper(btrim(d.region)) = d1.region and d.id <> d1.id order by d.depot_code limit 1;
  select d.id, d.depot_code, upper(btrim(d.region)) region into d3 from public.depots d
   where d.archived_at is null and btrim(coalesce(d.region, '')) <> '' and upper(btrim(d.region)) <> d1.region order by d.depot_code limit 1;

  begin
    delete from public.user_permissions where user_id in (v_tt, v_lain) and permission_code = 'manage_timetable';
    insert into public.user_permissions(user_id, permission_code) values (v_tt, 'manage_timetable');
    delete from rc_private.user_tab_access where user_id in (v_tt, v_lain) and tab_code like 'timetable.%';
    -- Jangkauan v_tt: d1, d2, d3.
    delete from public.user_depot_access where user_id = v_tt;
    insert into public.user_depot_access(user_id, depot_id) values (v_tt, d1.id), (v_tt, d2.id), (v_tt, d3.id);
    update public.profiles set home_depot_id = d2.id where id = v_tt;
    -- Resource Partner: d1 dan d3 di-tag ke akun ini.
    delete from public.user_depot_grants where user_id = v_tt;
    insert into public.user_depot_grants(user_id, depot_id, kind) values (v_tt, d1.id, 'rp'), (v_tt, d3.id, 'rp');

    -- ---- Katalog dan hak tab -----------------------------------------------------------
    hasil := hasil || jsonb_build_object('uji', 'Tab lama bernama Report, tab baru Details Campaign',
      'lulus', (select title from rc_private.tab_catalog where code = 'timetable.matrix') = 'Report'
           and (select title from rc_private.tab_catalog where code = 'timetable.campaign') = 'Details Campaign',
      'rinci', (select string_agg(code || '=' || title, ', ' order by code) from rc_private.tab_catalog where module = 'timetable'));
    perform pg_temp.ttc_sebagai(v_tt);
    v_tabs := rc_private.tab_rights(v_tt);
    hasil := hasil || jsonb_build_object('uji', 'Pemegang izin Timetable: Report dan Details Campaign tercentang bawaan',
      'lulus', (v_tabs->>'timetable.matrix')::boolean and (v_tabs->>'timetable.campaign')::boolean, 'rinci', v_tabs->>'timetable.campaign');
    perform pg_temp.ttc_sebagai(v_lain);
    v_tabs := rc_private.tab_rights(v_lain);
    begin perform public.rc_timetable_campaigns(); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    -- Pemilik, 19 Oktober 2026: Details Campaign terbuka bawaan untuk semua akun; Report tetap ikut izin modul.
    hasil := hasil || jsonb_build_object('uji', 'Tanpa izin Timetable: Details Campaign tetap terbuka (semua akun), Report tidak',
      'lulus', coalesce((v_tabs->>'timetable.campaign')::boolean, false) and not coalesce((v_tabs->>'timetable.matrix')::boolean, false) and v_galat = 'lolos',
      'rinci', 'campaign=' || coalesce(v_tabs->>'timetable.campaign', '?') || ' matrix=' || coalesce(v_tabs->>'timetable.matrix', '?') || ' rpc=' || v_galat);

    -- ---- Campaign Master: Variant Name + Description ------------------------------------
    perform pg_temp.ttc_sebagai(v_sm);
    r := public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object('codeCampaign', v_kode, 'campaignName', 'Uji Details Campaign',
           'soStart', '01-03-2026', 'soEnd', '31-03-2026', 'billingStart', '01-03-2026', 'billingEnd', '30-04-2026', 'jenisCb', 'Transfer', 'statusPajak', 'PT Nipsea Paint and Chemicals',
           'variantZsq04', ' ZQ04-UJI ', 'variantZsq04Desc', 'Laporan ZSQ04 uji', 'variantZsod', 'ZSOD-UJI', 'variantZsodDesc', 'Laporan ZSOD uji',
           'variantMcsi', 'MCSI-UJI', 'variantMcsiDesc', 'Laporan MCSI uji')));
    select * into c from public.campaigns where campaign_code = v_kode;
    hasil := hasil || jsonb_build_object('uji', 'Campaign baru: Variant Name & Description tersimpan (dirapikan)',
      'lulus', (r->>'dibuat')::int = 1 and c.variant_zsq04 = 'ZQ04-UJI' and c.variant_zsq04_desc = 'Laporan ZSQ04 uji' and c.variant_zsod = 'ZSOD-UJI'
        and c.variant_zsod_desc = 'Laporan ZSOD uji' and c.variant_mcsi = 'MCSI-UJI' and c.variant_mcsi_desc = 'Laporan MCSI uji',
      'rinci', concat_ws(' / ', c.variant_zsq04, c.variant_zsq04_desc, c.variant_mcsi, c.variant_mcsi_desc));

    -- Unggahan template lama (tanpa kolom variant) tidak mengosongkan variant.
    perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object('codeCampaign', v_kode, 'campaignName', 'Uji Details Campaign (ubah)')));
    select * into c from public.campaigns where campaign_code = v_kode;
    hasil := hasil || jsonb_build_object('uji', 'Simpan tanpa kolom variant: variant & description lama tetap',
      'lulus', c.campaign_name = 'Uji Details Campaign (ubah)' and c.variant_zsq04 = 'ZQ04-UJI' and c.variant_mcsi_desc = 'Laporan MCSI uji', 'rinci', c.variant_zsq04);

    -- Formulir Ubah mengirim semua kolom: kosong berarti dikosongkan, yang diisi menimpa.
    perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object('codeCampaign', v_kode, 'variantZsq04', '', 'variantZsq04Desc', '',
              'variantZsod', 'ZSOD-BARU', 'variantZsodDesc', 'Deskripsi baru')));
    select * into c from public.campaigns where campaign_code = v_kode;
    hasil := hasil || jsonb_build_object('uji', 'Variant/description dikirim kosong = dikosongkan; diisi = menimpa',
      'lulus', c.variant_zsq04 is null and c.variant_zsq04_desc is null and c.variant_zsod = 'ZSOD-BARU' and c.variant_zsod_desc = 'Deskripsi baru' and c.variant_mcsi = 'MCSI-UJI',
      'rinci', coalesce(c.variant_zsq04, '(kosong)') || ' / ' || c.variant_zsod || ' / ' || c.variant_zsod_desc);

    begin perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object('codeCampaign', v_kode, 'variantMcsiDesc', repeat('x', 2001)))); v_galat := 'lolos'; -- 20261163470000: batas 2.000
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Description lebih dari 2.000 karakter ditolak', 'lulus', v_galat ~ '2000', 'rinci', v_galat);

    r := public.rc_campaign_list(v_kode, 0, 50);
    v_row := r->'rows'->0;
    hasil := hasil || jsonb_build_object('uji', 'Daftar Campaign Master memuat Variant Name & Description',
      'lulus', v_row->>'variantZsq04' = '' and v_row->>'variantZsod' = 'ZSOD-BARU' and v_row->>'variantZsodDesc' = 'Deskripsi baru'
        and v_row->>'variantMcsi' = 'MCSI-UJI' and v_row->>'variantMcsiDesc' = 'Laporan MCSI uji',
      'rinci', concat_ws(' / ', v_row->>'variantZsod', v_row->>'variantZsodDesc', v_row->>'variantMcsiDesc'));

    -- ---- Details Campaign ---------------------------------------------------------------
    perform pg_temp.ttc_sebagai(v_tt);
    r := public.rc_timetable_campaigns();
    select x into v_row from jsonb_array_elements(r->'rows') x where x->>'kode' = v_kode;
    hasil := hasil || jsonb_build_object('uji', 'Details Campaign: kode, nama, status, Jenis CB, Status Pajak, periode SO & Billing (dd-Mmm-yyyy) langsung dari Campaign Master',
      'lulus', v_row->>'nama' = 'Uji Details Campaign (ubah)' and v_row->>'status' = 'active' and v_row->>'jenisCb' = 'Transfer'
        and v_row->>'statusPajak' = 'PT Nipsea Paint and Chemicals' and v_row->>'soStart' = '01-Mar-2026' and v_row->>'soEnd' = '31-Mar-2026'
        and v_row->>'billingStart' = '01-Mar-2026' and v_row->>'billingEnd' = '30-Apr-2026' and v_row->>'soStartIso' = '2026-03-01',
      'rinci', (v_row - 'variant')::text);
    -- 20261163470000: hanya T-code yang punya Variant Name (ZSQ04 dikosongkan di atas).
    hasil := hasil || jsonb_build_object('uji', 'Variant: hanya T-code yang terisi (ZSOD, MCSI) dengan Variant Name & Description',
      'lulus', v_row->'variant' = jsonb_build_array(
                 jsonb_build_object('laporan', 'ZSOD', 'nama', 'ZSOD-BARU', 'deskripsi', 'Deskripsi baru'),
                 jsonb_build_object('laporan', 'MCSI', 'nama', 'MCSI-UJI', 'deskripsi', 'Laporan MCSI uji')),
      'rinci', (v_row->'variant')::text);
    select count(*) into n from public.campaigns where archived_at is null;
    hasil := hasil || jsonb_build_object('uji', 'Seluruh campaign yang tidak diarsip tampil; depot jangkauan, region, depot rumah ikut',
      'lulus', jsonb_array_length(r->'rows') = n and jsonb_array_length(r->'depots') = 3 and r->>'depotSaya' = d2.depot_code
        and r->'regions' ? d1.region and r->'regions' ? d3.region,
      'rinci', jsonb_array_length(r->'rows') || ' vs ' || n || '; depot ' || (r->'depots')::text || '; rumah ' || (r->>'depotSaya'));
    hasil := hasil || jsonb_build_object('uji', 'Catatan akun: depot asal dan depot Resource Partner ikut dikirim',
      'lulus', r->>'depotSaya' = d2.depot_code and r->'depotRp' = jsonb_build_array(least(d1.depot_code, d3.depot_code), greatest(d1.depot_code, d3.depot_code)),
      'rinci', (r->>'depotSaya') || ' + RP ' || (r->'depotRp')::text);
    hasil := hasil || jsonb_build_object('uji', 'Tanpa Not Participating: berlaku di semua depot',
      'lulus', jsonb_array_length(v_row->'tidakBerlakuDepot') = 0 and jsonb_array_length(v_row->'npRegion') = 0 and not (v_row->>'dikecualikan')::boolean, 'rinci', (v_row->'tidakBerlakuDepot')::text);

    -- Not Participating: region d1 (mencakup d1 & d2) dan depot d3 langsung.
    insert into public.campaign_not_participating(campaign_id, region, catatan) values (c.id, d1.region, 'uji');
    r := public.rc_timetable_campaigns();
    select x into v_row from jsonb_array_elements(r->'rows') x where x->>'kode' = v_kode;
    hasil := hasil || jsonb_build_object('uji', 'Exclude region: depot di region itu ditandai tidak berlaku, depot region lain tetap berlaku',
      'lulus', v_row->'tidakBerlakuDepot' = jsonb_build_array(least(d1.depot_code, d2.depot_code), greatest(d1.depot_code, d2.depot_code))
        and v_row->'npRegion' = jsonb_build_array(d1.region),
      'rinci', (v_row->'tidakBerlakuDepot')::text || ' region ' || (v_row->'npRegion')::text);
    insert into public.campaign_not_participating(campaign_id, depot_id, catatan) values (c.id, d3.id, 'uji');
    r := public.rc_timetable_campaigns();
    select x into v_row from jsonb_array_elements(r->'rows') x where x->>'kode' = v_kode;
    hasil := hasil || jsonb_build_object('uji', 'Exclude depot langsung ikut ditandai; daftar depot NP tampil',
      'lulus', v_row->'tidakBerlakuDepot' ? d3.depot_code and jsonb_array_length(v_row->'tidakBerlakuDepot') = 3 and v_row->'npDepot' ? d3.depot_code,
      'rinci', (v_row->'tidakBerlakuDepot')::text || ' depot ' || (v_row->'npDepot')::text);
    hasil := hasil || jsonb_build_object('uji', 'Penanda sama dengan aturan resmi np_pasangan',
      'lulus', rc_private.np_pasangan(d1.id, c.id) and rc_private.np_pasangan(d2.id, c.id) and rc_private.np_pasangan(d3.id, c.id), 'rinci', '-');

    insert into public.excluded_campaigns(campaign_id, excluded_by, reason) values (c.id, v_sm, 'uji exclude');
    r := public.rc_timetable_campaigns();
    select x into v_row from jsonb_array_elements(r->'rows') x where x->>'kode' = v_kode;
    hasil := hasil || jsonb_build_object('uji', 'Exclude Campaign (seluruh laporan) tampil sebagai keterangan',
      'lulus', (v_row->>'dikecualikan')::boolean and v_row->>'alasanDikecualikan' = 'uji exclude', 'rinci', v_row->>'alasanDikecualikan');

    update public.campaigns set memo_path = c.id::text || '/uji.pdf', memo_name = 'Memo Uji.pdf', memo_size = 1234 where campaign_code = v_kode;
    r := public.rc_timetable_campaigns();
    select x into v_row from jsonb_array_elements(r->'rows') x where x->>'kode' = v_kode;
    hasil := hasil || jsonb_build_object('uji', 'Memo PDF ikut (jalur dan nama berkas)',
      'lulus', v_row->>'memoName' = 'Memo Uji.pdf' and v_row->>'memoPath' = c.id::text || '/uji.pdf', 'rinci', v_row->>'memoName');

    update public.campaigns set archived_at = now() where campaign_code = v_kode;
    r := public.rc_timetable_campaigns();
    hasil := hasil || jsonb_build_object('uji', 'Campaign yang diarsip tidak tampil',
      'lulus', not exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'kode' = v_kode), 'rinci', '-');

    -- Tab Details Campaign dimatikan untuk akun ini.
    insert into rc_private.user_tab_access values (v_tt, 'timetable.campaign', false);
    begin perform public.rc_timetable_campaigns(); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Tab Details Campaign dimatikan: ditolak server', 'lulus', v_galat ~ 'timetable\.campaign', 'rinci', v_galat);

    hasil := hasil || jsonb_build_object('uji', 'Kolom variant tidak dapat ditulis langsung oleh authenticated',
      'lulus', not has_column_privilege('authenticated', 'public.campaigns', 'variant_mcsi_desc', 'update'), 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;

  insert into _hasil_ttc(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_ttc order by urut;
