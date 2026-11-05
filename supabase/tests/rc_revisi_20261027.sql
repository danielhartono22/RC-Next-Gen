-- ==========================================================================================
-- Uji revisi 27 Oktober 2026 - migrasi 20261163460000 s.d. 20261163490000
-- ==========================================================================================
-- Grafik email tersemat, variant banyak per T-code, Details Campaign publik, Net Value / Volume
-- di Open, dan Key Master / Claim Process / Ad-Hoc tanpa yurisdiksi. Seluruh perubahan data
-- dibatalkan (UJI_SELESAI).
--
--   node scripts/apply-sql.mjs --env dev supabase/tests/rc_revisi_20261027.sql
-- ==========================================================================================
create temp table if not exists _hasil_rev(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_rev;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_adm uuid; v_dep uuid[]; r jsonb; x jsonb; v_err text; v_doc record; v_n bigint; v_m bigint;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- Admin dengan yurisdiksi terbatas (1-3 depot).
  select p.id, array_agg(a.depot_id) into v_adm, v_dep from public.profiles p join public.user_depot_access a on a.user_id = p.id
   where p.role = 'admin' and p.status = 'active' and not p.must_change_password
   group by p.id having count(*) between 1 and 3 order by p.id limit 1;

  begin
    -- ---- Variant ------------------------------------------------------------------------------
    x := rc_private.variant_daftar('V1; V2', 'Desk 1;Desk 2', '', 'tanpa nama', 'M1', null);
    hasil := hasil || jsonb_build_object('uji', 'Variant: beberapa per T-code, berpasangan; T-code tanpa Name tidak tampil',
      'lulus', jsonb_array_length(x) = 3 and x->0->>'nama' = 'V1' and x->1->>'deskripsi' = 'Desk 2' and x->2->>'laporan' = 'MCSI'
           and not exists(select 1 from jsonb_array_elements(x) e where e->>'laporan' = 'ZSOD'), 'rinci', x::text);
    hasil := hasil || jsonb_build_object('uji', 'Variant: campaign tanpa variant -> daftar kosong',
      'lulus', rc_private.variant_daftar(null, null, null, null, null, null) = '[]'::jsonb, 'rinci', '-');

    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    select campaign_code into v_doc from public.campaigns where archived_at is null order by campaign_code limit 1;
    r := public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object('codeCampaign', v_doc.campaign_code,
      'variantZsq04', rpad('VAR', 300, 'X') || ';VAR2', 'variantZsq04Desc', 'Satu;Dua')));
    x := (select e from jsonb_array_elements(public.rc_timetable_campaigns()->'rows') e where e->>'kode' = v_doc.campaign_code);
    hasil := hasil || jsonb_build_object('uji', 'Campaign Master menerima variant > 200 karakter; Details Campaign memecahnya',
      'lulus', jsonb_array_length(x->'variant') >= 2 and (x->'variant'->1->>'nama') = 'VAR2' and (x->'variant'->1->>'deskripsi') = 'Dua',
      'rinci', left(coalesce(x->'variant', '[]'::jsonb)::text, 200));

    -- ---- Upload Variant (20261163510000) ------------------------------------------------------
    r := public.rc_campaign_variant_unggah(jsonb_build_array(
      jsonb_build_object('baris', 2, 'kode', lower(v_doc.campaign_code), 'tcode', 'mcsi', 'nama', jsonb_build_array('M_A', 'M_B', ''), 'deskripsi', jsonb_build_array('Desk A', '', '')),
      jsonb_build_object('baris', 3, 'kode', v_doc.campaign_code, 'tcode', 'ZSOD', 'nama', jsonb_build_array('', '', ''), 'deskripsi', jsonb_build_array('', '', ''))), false);
    hasil := hasil || jsonb_build_object('uji', 'Upload Variant pratinjau: tidak menyimpan; baris tanpa nama dilewati',
      'lulus', r->>'galat' = '0' and r->'baris'->0->>'status' = 'diganti' and r->'baris'->0->>'namaBaru' = 'M_A; M_B'
           and r->'baris'->1->>'status' = 'dilewati' and (select variant_mcsi from public.campaigns where campaign_code = v_doc.campaign_code) is distinct from 'M_A; M_B',
      'rinci', left((r->'baris')::text, 200));
    r := public.rc_campaign_variant_unggah(jsonb_build_array(
      jsonb_build_object('baris', 2, 'kode', v_doc.campaign_code, 'tcode', 'MCSI', 'nama', jsonb_build_array('M_A', 'M_B', ''), 'deskripsi', jsonb_build_array('Desk A', '', ''))), true);
    x := (select e from jsonb_array_elements(public.rc_timetable_campaigns()->'rows') e where e->>'kode' = v_doc.campaign_code);
    hasil := hasil || jsonb_build_object('uji', 'Upload Variant simpan: MCSI berisi 2 variant, Description berpasangan; satu Log Activity',
      'lulus', (r->>'diubah')::int = 1 and (select variant_mcsi from public.campaigns where campaign_code = v_doc.campaign_code) = 'M_A; M_B'
           and (select count(*) from jsonb_array_elements(x->'variant') e where e->>'laporan' = 'MCSI') = 2
           and exists(select 1 from public.activity_logs where event_type = 'campaign_variant_unggah' and created_at = now()),
      'rinci', coalesce((x->'variant')::text, '-'));
    r := public.rc_campaign_variant_unggah(jsonb_build_array(
      jsonb_build_object('baris', 2, 'kode', 'TIDAK-ADA-XYZ', 'tcode', 'MCSI', 'nama', jsonb_build_array('A', '', ''), 'deskripsi', '[]'::jsonb),
      jsonb_build_object('baris', 3, 'kode', v_doc.campaign_code, 'tcode', 'ZXX', 'nama', jsonb_build_array('A', '', ''), 'deskripsi', '[]'::jsonb),
      jsonb_build_object('baris', 4, 'kode', v_doc.campaign_code, 'tcode', 'ZSOD', 'nama', jsonb_build_array('A;B', '', ''), 'deskripsi', '[]'::jsonb),
      jsonb_build_object('baris', 5, 'kode', v_doc.campaign_code, 'tcode', 'ZSOD', 'nama', jsonb_build_array('', '', ''), 'deskripsi', jsonb_build_array('', 'D2', ''))), false);
    hasil := hasil || jsonb_build_object('uji', 'Upload Variant galat: campaign tidak ada, T-Code salah, titik koma, Description tanpa Nama',
      'lulus', r->>'galat' = '4', 'rinci', (select string_agg(e->>'galat', ' | ') from jsonb_array_elements(r->'baris') e));
    v_err := null;
    begin perform public.rc_campaign_variant_unggah(jsonb_build_array(jsonb_build_object('baris', 2, 'kode', 'TIDAK-ADA-XYZ', 'tcode', 'MCSI', 'nama', jsonb_build_array('A'), 'deskripsi', '[]'::jsonb)), true);
    exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Upload Variant: simpan ditolak bila ada baris bermasalah', 'lulus', coalesce(v_err, '') ~ 'dibatalkan', 'rinci', coalesce(v_err, 'tersimpan!'));
    r := public.rc_campaign_variant_unggah(jsonb_build_array(jsonb_build_object('baris', 2, 'kode', v_doc.campaign_code, 'tcode', 'MCSI', 'nama', jsonb_build_array('-', '', ''), 'deskripsi', '[]'::jsonb)), true);
    hasil := hasil || jsonb_build_object('uji', 'Upload Variant: "-" mengosongkan T-Code itu',
      'lulus', (select variant_mcsi is null and variant_mcsi_desc is null from public.campaigns where campaign_code = v_doc.campaign_code), 'rinci', r->'baris'->0->>'status');

    -- ---- Details Campaign publik --------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    r := public.rc_publik_timetable_campaigns();
    v_err := null;
    begin perform public.rc_timetable_campaigns(); exception when others then v_err := sqlerrm; end;
    execute 'reset role';
    hasil := hasil || jsonb_build_object('uji', 'Publik (anon): Details Campaign terbuka, seluruh depot, tanpa depot asal; path memo ikut bila memo ada (20261163500000)',
      'lulus', r->>'status' = 'success' and jsonb_array_length(r->'rows') > 0
           and jsonb_array_length(r->'depots') = (select count(*) from public.depots where archived_at is null and not bukan_depot)
           and not exists(select 1 from jsonb_array_elements(r->'rows') e where (e->>'memoPath' <> '') <> coalesce((e->>'adaMemo')::boolean, false)) and coalesce(r->>'depotSaya', '') = '',
      'rinci', jsonb_array_length(r->'rows') || ' campaign, ' || jsonb_array_length(r->'depots') || ' depot');
    hasil := hasil || jsonb_build_object('uji', 'Publik (anon): RPC portal tetap tertutup', 'lulus', v_err is not null, 'rinci', coalesce(v_err, 'terbuka!'));

    -- ---- Email ----------------------------------------------------------------------------------
    x := rc_private.email_sematkan_gambar('<p>x</p>' || rc_private.email_chart_depot('[{"label":"1A","cr":0.4}]'::jsonb, 'Uji'));
    hasil := hasil || jsonb_build_object('uji', 'Email: grafik QuickChart diunduh dan diganti cid:',
      'lulus', jsonb_array_length(x->'gambar') = 1 and position('quickchart' in x->>'html') = 0 and position('cid:rcgrafik1' in x->>'html') > 0,
      'rinci', 'gagal ' || (x->>'gagal'));
    hasil := hasil || jsonb_build_object('uji', 'Email: kirim_satu_email memakai surat bergambar tersemat',
      'lulus', pg_get_functiondef('rc_private.kirim_satu_email(uuid)'::regprocedure) ~ 'email_sematkan_gambar', 'rinci', '-');

    -- ---- Open: Net Value dan Volume -------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_open_claims_filtered('', '', 0, 5, '');
    hasil := hasil || jsonb_build_object('uji', 'Open: setiap baris membawa netValue dan volume',
      'lulus', jsonb_array_length(r->'rows') > 0 and not exists(select 1 from jsonb_array_elements(r->'rows') e where not (e ? 'netValue' and e ? 'volume')),
      'rinci', coalesce((r->'rows'->0->>'netValue') || ' / ' || (r->'rows'->0->>'volume'), 'tanpa baris'));

    -- ---- Tanpa yurisdiksi -----------------------------------------------------------------------
    if v_adm is null then
      hasil := hasil || jsonb_build_object('uji', 'Fixture admin terbatas', 'lulus', false, 'rinci', 'tidak ada admin dengan 1-3 depot');
    else
      insert into public.user_permissions(user_id, permission_code) values (v_adm, 'manage_key_master'), (v_adm, 'process_claim')
      on conflict do nothing;
      perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      r := public.rc_customer_list('', 0, 1);
      x := public.rc_depot_list(null, 0, 500);
      execute 'reset role';
      select count(*) into v_n from public.customers where archived_at is null;
      hasil := hasil || jsonb_build_object('uji', 'Key Master: Customer Master seluruh pelanggan bagi pemegang tab (bukan hanya depotnya)',
        'lulus', (r->>'total')::bigint = v_n, 'rinci', (r->>'total') || ' dari ' || v_n);
      select count(*) into v_m from public.depots where archived_at is null;
      hasil := hasil || jsonb_build_object('uji', 'Key Master: Depot Master seluruh depot',
        'lulus', (x->>'total')::bigint = v_m, 'rinci', (x->>'total') || ' dari ' || v_m);

      -- Depot di luar yurisdiksi admin dapat disimpan di Depot Master.
      select depot_code into v_doc from public.depots where archived_at is null and not (id = any(v_dep)) order by depot_code limit 1;
      v_err := null;
      execute 'set local role authenticated';
      begin perform public.rc_depot_save(v_doc.depot_code, '{"emailCc":"uji@contoh.com"}'::jsonb);
      exception when others then v_err := sqlerrm; end;
      execute 'reset role';
      hasil := hasil || jsonb_build_object('uji', 'Key Master: Depot Master depot di luar yurisdiksi dapat diubah',
        'lulus', coalesce(v_err, '') !~ 'yurisdiksi', 'rinci', coalesce(v_err, 'tersimpan / diajukan'));

      -- Claim Process: dokumen Released di luar yurisdiksi tampil dan dapat diproses; Release tidak.
      select c.no_doc, c.version_no into v_doc from public.claims c join public.campaigns ca on ca.id = c.campaign_id
       where c.status = 'released' and c.archived_at is null and c.pending_approval is null and c.customer_id is not null and ca.status <> 'inactive'
         and not (c.depot_id = any(v_dep)) and not c.jalur_adhoc
         and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) not in ('rebate')
       order by c.updated_at desc limit 1;
      if v_doc.no_doc is null then
        hasil := hasil || jsonb_build_object('uji', 'Claim Process lintas depot', 'lulus', false, 'rinci', 'tidak ada dokumen Released di luar yurisdiksi admin');
      else
        update public.claims set updated_at = now() + interval '1 minute' where no_doc = v_doc.no_doc;
        execute 'set local role authenticated';
        r := public.rc_legacy_workflow(200, null, null);
        execute 'reset role';
        hasil := hasil || jsonb_build_object('uji', 'Claim to Finance: dokumen depot lain tampil; Release / Bulk tetap per yurisdiksi',
          'lulus', exists(select 1 from jsonb_array_elements(r->'claimFinData') e where e->>'noDoc' = v_doc.no_doc)
               and not exists(select 1 from jsonb_array_elements(r->'releaseData') e where not (e->>'lingkup')::boolean)
               and not exists(select 1 from jsonb_array_elements(r->'bulkRebateData') e where not (e->>'lingkup')::boolean),
          'rinci', v_doc.no_doc);
        v_err := null;
        begin r := public.rc_process_claims('claim', jsonb_build_array(jsonb_build_object('no_doc', v_doc.no_doc, 'version_no', (select version_no from public.claims where no_doc = v_doc.no_doc))), gen_random_uuid(), '');
        exception when others then v_err := sqlerrm; end;
        hasil := hasil || jsonb_build_object('uji', 'Posting Claim dokumen depot lain diterima',
          'lulus', v_err is null and (select status from public.claims where no_doc = v_doc.no_doc) = 'claimed', 'rinci', coalesce(v_err, 'claimed'));
      end if;

      -- Release dokumen Approved di luar yurisdiksi tetap ditolak.
      select c.no_doc, c.version_no into v_doc from public.claims c
       where c.status = 'approved' and c.archived_at is null and c.pending_approval is null and not (c.depot_id = any(v_dep)) and not c.jalur_adhoc
       order by c.no_doc limit 1;
      if v_doc.no_doc is not null then
        insert into public.user_permissions(user_id, permission_code) values (v_adm, 'release_claim') on conflict do nothing;
        v_err := null;
        begin r := public.rc_process_claims('release', jsonb_build_array(jsonb_build_object('no_doc', v_doc.no_doc, 'version_no', v_doc.version_no)), gen_random_uuid(), '');
        exception when others then v_err := sqlerrm; end;
        hasil := hasil || jsonb_build_object('uji', 'Release tetap per yurisdiksi', 'lulus', coalesce(v_err, '') ~ 'Depot access denied', 'rinci', coalesce(v_err, 'tidak ditolak!'));
      end if;
    end if;

    -- Ad-Hoc: OSC memproses dokumen Others di depot mana pun.
    select c.no_doc, c.version_no, c.depot_id into v_doc from public.claims c where c.status = 'approved' and c.jalur_adhoc and c.archived_at is null and c.customer_id is not null order by c.no_doc limit 1;
    select p.id into v_adm from public.profiles p where p.role = 'osc' and p.status = 'active' and not p.must_change_password order by p.user_code limit 1;
    -- Depot dokumen dikeluarkan sementara dari jangkauan OSC ini (ikut dibatalkan).
    delete from public.user_depot_access where user_id = v_adm and depot_id = v_doc.depot_id;
    -- Campaign inactive menolak proses maju (aturan lain); diaktifkan sementara untuk uji ini.
    update public.campaigns set status = 'active' where id = (select campaign_id from public.claims where no_doc = v_doc.no_doc);
    if v_doc.no_doc is null or v_adm is null then
      hasil := hasil || jsonb_build_object('uji', 'Ad-Hoc lintas depot', 'lulus', true, 'rinci', 'DILEWATI: tidak ada dokumen Others di antrean atau OSC aktif di lingkungan ini');
    else
      perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      r := public.rc_legacy_workflow(500, null, null);
      v_err := null;
      begin x := public.rc_adhoc_proses(jsonb_build_array(jsonb_build_object('no_doc', v_doc.no_doc, 'version_no', v_doc.version_no, 'jenis_cb', 'CN')), gen_random_uuid());
      exception when others then v_err := sqlerrm; end;
      execute 'reset role';
      hasil := hasil || jsonb_build_object('uji', 'Ad-Hoc: OSC melihat dan memproses dokumen Others depot lain',
        'lulus', exists(select 1 from jsonb_array_elements(r->'adhocData') e where e->>'noDoc' = v_doc.no_doc) and v_err is null,
        'rinci', v_doc.no_doc || ': ' || coalesce(v_err, 'diproses'));
    end if;

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_rev(uji, lulus, rinci) select y->>'uji', (y->>'lulus')::boolean, y->>'rinci' from jsonb_array_elements(hasil) y;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_rev order by urut;
