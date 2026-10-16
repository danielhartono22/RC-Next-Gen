-- ==========================================================================================
-- Uji pascatransport 14 Oktober 2026 (migrasi 20261163090000 - 20261163110000)
-- ==========================================================================================
-- Sebagai System Manager, memanggil fungsi yang sama dengan layar. Setiap uji di subtransaksi
-- yang DIBATALKAN; hasil dikumpulkan di variabel lalu dicatat di akhir. Email pengajuan
-- dimatikan di uji yang mengubah status; uji email Done hanya mengantrekan di subtransaksi yang
-- dibatalkan (tidak ada yang terkirim). Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_transport_20261014.sql
-- ==========================================================================================
create temp table if not exists _hasil_1014(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_1014;

do $uji$
declare v_sm uuid; r jsonb; l jsonb; hasil jsonb := '[]'; d1 text; d2 text; v_galat text; n bigint; v_hari date;
  d record; c public.claims%rowtype; s rc_private.claim_sensitive%rowtype; v_dep record; v_ids uuid[]; v_o public.email_outbox%rowtype;
  v_ok boolean;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select depot_code into d1 from public.depots where archived_at is null and abbr is not null order by depot_code limit 1;
  select depot_code into d2 from public.depots where archived_at is null and abbr is not null order by depot_code offset 1 limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  -- ---- Customer Master: Kode Depot ------------------------------------------------------
  begin
    execute 'set local role authenticated';
    r := public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode','UJI1014A','custName','TOKO UJI 1014','kodeDepot', d1 || ', ' || d2)));
    l := public.rc_customer_list('UJI1014A', 0, 5);
    hasil := hasil || jsonb_build_array(jsonb_build_array('Customer baru + Kode Depot tersimpan dan terlihat',
      (r->>'dibuat')::int = 1 and (l->>'total')::int = 1 and (l->'rows'->0->'depotCodes') = jsonb_build_array(d1, d2),
      format('dibuat %s, terlihat %s, depot %s', r->>'dibuat', l->>'total', l->'rows'->0->'depotCodes')));
    begin
      r := public.rc_customer_upsert('[{"custCode":"UJI1014B","custName":"TANPA DEPOT"}]'::jsonb); v_galat := 'diterima';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Customer baru tanpa Kode Depot ditolak', v_galat ~ 'Kode Depot wajib', v_galat));
    hasil := hasil || jsonb_build_array(jsonb_build_array('Peringatan customer tanpa Kode Depot', (l->'tanpaDepot') ? 'jumlah',
      format('%s customer tanpa depot: %s', l->'tanpaDepot'->>'jumlah', left((l->'tanpaDepot'->'kode')::text, 160))));
    l := public.rc_campaign_list((select campaign_code from public.campaigns where archived_at is null order by campaign_code limit 1), 0, 50);
    hasil := hasil || jsonb_build_array(jsonb_build_array('Campaign Master: total mengikuti pencarian',
      (l->>'total')::int = jsonb_array_length(l->'rows'), format('total %s, baris %s', l->>'total', jsonb_array_length(l->'rows'))));
    execute 'reset role';
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_array(jsonb_build_array('Customer/Campaign', false, sqlerrm)); end if;
  end;

  -- ---- Depot Master: Abbr dan Email Kepala Admin ------------------------------------------
  begin
    execute 'set local role authenticated';
    r := public.rc_depot_upsert(jsonb_build_array(
      jsonb_build_object('kode','ZQ1','nama','UJI TANPA ABBR'),
      jsonb_build_object('kode','ZQ2','nama','UJI ABBR SALAH','abbr','A'),
      jsonb_build_object('kode','ZQ3','nama','UJI ABBR KEMBAR','abbr',(select abbr from public.depots where depot_code = d1)),
      jsonb_build_object('kode', d1, 'abbr', '', 'emailKepalaAdmin', 'kepala.admin.uji@example.invalid')));
    hasil := hasil || jsonb_build_array(jsonb_build_array('Depot: tanpa Abbr / salah format / kembar ditolak per baris',
      (r->>'ditolak')::int = 3 and (r->>'baru')::int = 0, left((r->'pesanDitolak')::text, 260)));
    l := public.rc_depot_list(d1, 0, 5);
    hasil := hasil || jsonb_build_array(jsonb_build_array('Depot: Abbr kosong tidak menghapus; Email Kepala Admin tersimpan (unggah)',
      (l->'rows'->0->>'abbr') <> '' and (l->'rows'->0->>'emailKepalaAdmin') = 'kepala.admin.uji@example.invalid',
      format('%s: Abbr %s, Email KA %s', d1, l->'rows'->0->>'abbr', l->'rows'->0->>'emailKepalaAdmin')));
    begin
      r := public.rc_depot_save(d1, jsonb_build_object('abbr', 'A')); v_galat := 'diterima';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Depot (form Ubah): Abbr salah format ditolak dengan pesan', v_galat ~ 'harus 2-10', v_galat));
    hasil := hasil || jsonb_build_array(jsonb_build_array('Depot: peringatan tanpa Abbr / tanpa Email Kepala Admin',
      (l ? 'tanpaAbbr') and (l ? 'tanpaEmailKa'),
      format('tanpa Abbr: %s; tanpa Email Kepala Admin: %s depot', l->'tanpaAbbr', jsonb_array_length(l->'tanpaEmailKa'))));
    execute 'reset role';
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_array(jsonb_build_array('Depot Master', false, sqlerrm)); end if;
  end;

  -- ---- Document Center: Created On ----------------------------------------------------------
  begin
    select (created_at at time zone 'Asia/Jakarta')::date into v_hari from public.claims where archived_at is null order by created_at desc limit 1;
    execute 'set local role authenticated';
    r := public.rc_compilation_list(p_dibuat_dari => v_hari, p_dibuat_sampai => v_hari, p_limit => 100);
    execute 'reset role';
    select count(*) into n from public.claims k join public.campaigns ca on ca.id = k.campaign_id join public.depots dp on dp.id = k.depot_id
     where k.archived_at is null and (k.created_at at time zone 'Asia/Jakarta')::date = v_hari;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Document Center: filter Created On ' || to_char(v_hari, 'DD-Mon-YYYY'),
      (r->>'total')::bigint = n and not exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'createdOn' <> to_char(v_hari, 'DD-Mon-YYYY')),
      format('total %s (harap %s)', r->>'total', n)));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_array(jsonb_build_array('Created On', false, sqlerrm)); end if;
  end;

  -- ---- Voucher (alur Rebate Manual) dan KTP + NPWP ----------------------------------------
  select c2.id, c2.no_doc, c2.version_no, c2.cb_net, c2.customer_id, ca.tax_status into d
    from public.claims c2
    join public.customers cu on cu.id = c2.customer_id
     and (nullif(btrim(coalesce(cu.ktp,'')),'') is null) <> (nullif(btrim(coalesce(cu.npwp,'')),'') is null)
    join public.campaigns ca on ca.id = c2.campaign_id and ca.status = 'active'
   where c2.status = 'not_yet' and c2.archived_at is null and c2.pending_approval is null and c2.cb_net > 0
     and rc_private.jenis_efektif(coalesce(nullif(c2.cashback_type_override,''), ca.cashback_type)) = 'cn'
   order by c2.no_doc limit 1;
  hasil := hasil || jsonb_build_array(jsonb_build_array('Voucher: label dan kategori sendiri',
    rc_private.cb_label('voucher') = 'Voucher' and rc_private.jenis_efektif('Voucher') = 'voucher',
    format('cb_label(voucher)=%s, jenis_efektif(Voucher)=%s', rc_private.cb_label('voucher'), rc_private.jenis_efektif('Voucher'))));
  if d.no_doc is not null then
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      insert into public.pengaturan_sistem(kunci, nilai) values ('approval_aktif', 'false'::jsonb) on conflict (kunci) do update set nilai = 'false'::jsonb;
      perform public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', d.version_no, 'jenis_cashback', 'Voucher')), gen_random_uuid(), '');
      select * into c from public.claims where id = d.id;
      hasil := hasil || jsonb_build_array(jsonb_build_array('Voucher, approval MATI: langsung Done', c.status = 'done', d.no_doc || ' -> ' || c.status));
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_array(jsonb_build_array('Voucher approval mati', false, sqlerrm)); end if;
    end;
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      insert into public.pengaturan_sistem(kunci, nilai) values ('approval_aktif', 'true'::jsonb) on conflict (kunci) do update set nilai = 'true'::jsonb;
      perform public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', d.version_no, 'jenis_cashback', 'Voucher')), gen_random_uuid(), '');
      select * into c from public.claims where id = d.id;
      v_ok := c.status = 'submitted' and c.pending_approval->>'target_status' = 'done';
      perform public.rc_process_claims('approve', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', c.version_no)), gen_random_uuid(), '');
      select * into c from public.claims where id = d.id;
      hasil := hasil || jsonb_build_array(jsonb_build_array('Voucher, approval HIDUP: Submitted lalu disetujui -> Done', v_ok and c.status = 'done', d.no_doc || ' -> ' || c.status));
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_array(jsonb_build_array('Voucher approval hidup', false, sqlerrm)); end if;
    end;
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      update public.customers set ktp = '3201010101010001', npwp = '012345678901234' where id = d.customer_id;
      perform public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', d.version_no)), gen_random_uuid(), '');
      select * into c from public.claims where id = d.id;
      select * into s from rc_private.claim_sensitive where claim_id = d.id;
      hasil := hasil || jsonb_build_array(jsonb_build_array('KTP + NPWP: diterima sebagai Badan, KTP tidak di dokumen',
        c.tax_subject = 'Badan' and s.ktp is null and s.npwp = '012345678901234',
        format('%s: status %s, subyek %s, KTP dokumen %s', d.no_doc, c.status, c.tax_subject, coalesce(s.ktp, '(kosong)'))));
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_array(jsonb_build_array('KTP + NPWP', false, sqlerrm)); end if;
    end;
  end if;

  -- ---- Email Done: TO Kepala Admin, subjek bernama depo --------------------------------------
  select k.depot_id, dp.depot_code, dp.depot_name, dp.email_to into v_dep
    from public.claims k join public.depots dp on dp.id = k.depot_id
   where k.archived_at is null and coalesce(btrim(dp.email_to),'') like '%@%' order by dp.depot_code limit 1;
  begin
    select array_agg(id) into v_ids from (select id from public.claims where depot_id = v_dep.depot_id and archived_at is null limit 3) x;
    update public.email_settings set aktif = true, mode_uji = false where jenis = 'pengajuan';
    insert into public.depot_profiles(depot_id) values (v_dep.depot_id) on conflict (depot_id) do nothing;
    update public.depot_profiles set email_kepala_admin = 'kepala.admin.uji@example.invalid' where depot_id = v_dep.depot_id;
    perform rc_private.email_pengajuan_antre('clearing', 'UJI-1014', v_ids, v_sm, '');
    select * into v_o from public.email_outbox where konteks->>'batch' = 'UJI-1014' order by dibuat_pada desc limit 1;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Email Done: TO hanya Kepala Admin, subjek bernama depo',
      v_o.tujuan = array['kepala.admin.uji@example.invalid'] and v_o.subjek ~ ('Depo ' || v_dep.depot_name),
      format('TO %s | subjek "%s"', v_o.tujuan, v_o.subjek)));
    delete from public.email_outbox where konteks->>'batch' = 'UJI-1014';
    update public.depot_profiles set email_kepala_admin = null where depot_id = v_dep.depot_id;
    perform rc_private.email_pengajuan_antre('clearing', 'UJI-1014', v_ids, v_sm, '');
    select * into v_o from public.email_outbox where konteks->>'batch' = 'UJI-1014' order by dibuat_pada desc limit 1;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Email Done: tanpa Email Kepala Admin tetap ke Email TO depot',
      coalesce(array_length(v_o.tujuan, 1), 0) > 0 and not ('kepala.admin.uji@example.invalid' = any(v_o.tujuan)),
      format('%s: TO %s alamat', v_dep.depot_code, coalesce(array_length(v_o.tujuan, 1), 0))));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_array(jsonb_build_array('Email Done', false, sqlerrm)); end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_1014(uji, lulus, rinci) select x->>0, (x->>1)::boolean, x->>2 from jsonb_array_elements(hasil) x;
end
$uji$;

select urut, uji, lulus, rinci from _hasil_1014 order by urut;
