-- ==========================================================================================
-- Uji 9 November 2026: Mass Upload Clearing (790000), arsip (800000), Change DC (810000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_perbaikan_20261109.sql
-- ==========================================================================================
create temp table if not exists _hasil_p1109(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_p1109;

-- 20261163850000: Change DC menerima daftar; pembantu untuk uji satu toko.
create or replace function pg_temp.cdc(k text, d text, a text) returns jsonb language sql as $f$
  select public.rc_change_dc(jsonb_build_array(jsonb_build_object('kodeToko', k, 'depotBaru', d, 'reason', a)));
$f$;

do $uji$
declare hasil jsonb := '[]'; r jsonb; r2 jsonb; v_sm uuid; v_galat text; v_tgl date := (now() at time zone 'Asia/Jakarta')::date - 1; b jsonb; tm record; v_out bigint; v_log bigint;
  kt record; kc record; d1 record; v_sidik text := md5('m1' || clock_timestamp()::text) || md5('m2' || clock_timestamp()::text);
  v_sidik2 text := md5('m3' || clock_timestamp()::text) || md5('m4' || clock_timestamp()::text);
  t record; v_baru record; a1 record; v_lama uuid; n integer; n2 integer;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select c.id, c.no_doc, c.cb_net into kt from public.claims c join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'claimed' and c.pending_approval is null and c.archived_at is null and c.no_doc like 'NPC/%' and c.customer_id is not null
     and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) = 'transfer'
     and not exists (select 1 from public.rc_clearing_bank_baris bb where bb.claim_id = c.id and bb.diproses) order by c.no_doc limit 1;
  select c.id, c.no_doc, c.cb_net into kc from public.claims c join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'claimed' and c.pending_approval is null and c.archived_at is null and c.no_doc like 'NPC/%' and c.customer_id is not null
     and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) = 'cn'
     and not exists (select 1 from public.rc_clearing_bank_baris bb where bb.claim_id = c.id and bb.diproses) order by c.no_doc limit 1;
  select b2.claim_id id, c.no_doc into d1 from public.rc_clearing_bank_baris b2 join public.rc_clearing_bank_upload u on u.id = b2.upload_id join public.claims c on c.id = b2.claim_id
   where b2.diproses and u.mode <> 'template' limit 1;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    if kt.id is null then raise exception 'Fixture: tidak ada Claimed Transfer'; end if;

    -- ---- Mass Upload --------------------------------------------------------------------------
    r := public.rc_clearing_bank_preview('Mass.xlsx', v_sidik, 2026, 'form', jsonb_strip_nulls(jsonb_build_array(
      jsonb_build_object('baris', 2, 'transId', '', 'effDate', '05-Nov-26', 'tglTransfer', v_tgl, 'remark1', kt.no_doc, 'status', 'Berhasil'),
      case when kc.id is not null then jsonb_build_object('baris', 3, 'transId', '', 'effDate', '05-Nov-26', 'tglTransfer', v_tgl, 'remark1', kc.no_doc, 'status', 'Berhasil') else jsonb_build_object('baris', 3, 'remark1', 'NPC/TIDAK/ADA/1', 'status', 'Berhasil', 'tglTransfer', v_tgl) end,
      jsonb_build_object('baris', 4, 'transId', '', 'effDate', '05-Nov-26', 'tglTransfer', v_tgl, 'remark1', coalesce(d1.no_doc, 'NPC/TIDAK/ADA/2'), 'status', 'Berhasil'),
      jsonb_build_object('baris', 5, 'transId', '', 'effDate', 'salah', 'remark1', 'NPC/TIDAK/ADA/3', 'status', 'Berhasil'))), 'template');
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau: Claimed = ok tanpa nominal; sudah di file bank = sudah diupload; tanggal salah ditolak',
      'lulus', r->'rows'->0->>'hasil' = 'ok' and (d1.id is null or r->'rows'->2->>'hasil' = 'sudah_diupload') and r->'rows'->3->>'hasil' = 'tanggal_salah',
      'rinci', (select string_agg((x->>'baris') || '=' || (x->>'hasil'), ' ') from jsonb_array_elements(r->'rows') x));
    r2 := public.rc_clearing_bank_proses((r->'upload'->>'id')::uuid);
    b := rc_private.bukti_tf(kt.id);
    hasil := hasil || jsonb_build_object('uji', 'Proses: Transfer Done, Tgl Aktual dari file, Bukti TF No. Referensi kosong, nominal dari klaim, sumber template',
      'lulus', (select status = 'done' and cleared_actual_on = v_tgl from public.claims where id = kt.id) and b->>'transId' = '' and (b->>'nominal')::numeric = trunc(kt.cb_net)
           and b->>'sumber' = 'template' and b->>'layanan' = 'Transfer' and b->>'status' = 'DIPROSES',
      'rinci', coalesce(b::text, r2::text));
    if kc.id is not null then
      hasil := hasil || jsonb_build_object('uji', 'Jenis selain Transfer: Done tanpa Bukti TF',
        'lulus', (select status = 'done' from public.claims where id = kc.id) and rc_private.bukti_tf(kc.id) is null, 'rinci', kc.no_doc);
    end if;
    r := public.rc_clearing_bank_preview('Mass2.xlsx', v_sidik2, 2026, 'form', jsonb_build_array(
      jsonb_build_object('baris', 2, 'transId', '', 'effDate', '01-Nov-26', 'tglTransfer', v_tgl - 3, 'remark1', kt.no_doc, 'status', 'Berhasil')), 'template');
    hasil := hasil || jsonb_build_object('uji', 'Upload ulang: sudah diupload, nilai lama tetap',
      'lulus', r->'rows'->0->>'hasil' = 'sudah_diupload' and (select cleared_actual_on = v_tgl from public.claims where id = kt.id), 'rinci', r->'rows'->0->>'keterangan');
    r := public.rc_clearing_bank_preview('MultiTransactionAutoTransferDownload_05112026120000.txt', md5(random()::text) || md5(random()::text), 2026, 'nama_file', jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'P1109-1', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(kt.cb_net)::text, 'remark1', substr(kt.no_doc, 5),
        'bank', 'BCA', 'toAcc', '0123456700', 'status', 'Berhasil', 'reason', '', 'layanan', 'BCA', 'biaya', '0', 'biayaOleh', 'OUR')), 'otomatis');
    r2 := public.rc_clearing_bank_proses((r->'upload'->>'id')::uuid);
    b := rc_private.bukti_tf(kt.id);
    hasil := hasil || jsonb_build_object('uji', 'File bank menyusul: menggantikan Bukti TF template (ada No. Referensi), status tetap',
      'lulus', r->'rows'->0 is null or (b->>'transId' = 'P1109-1' and b->>'sumber' = 'bank'), 'rinci', coalesce(r->'rows'->0->>'hasil', '-') || ' ' || coalesce(b->>'transId', '-'));

    -- ---- Arsip ----------------------------------------------------------------------------------
    select c.id, c.no_doc, c.campaign_id, c.customer_id, c.cb_net, c.depot_id into a1 from public.claims c
     where c.status = 'not_yet' and c.archived_at is null and c.customer_id is not null and c.pending_approval is null order by c.no_doc limit 1;
    perform public.rc_archive_compilation(array[a1.id], 'Uji arsip');
    r := public.rc_archived_list(0, 100, a1.no_doc);
    hasil := hasil || jsonb_build_object('uji', 'Pencarian arsip menemukan dokumen; belum ada pengganti',
      'lulus', (r->>'total')::int = 1 and r->'rows'->0->>'noDoc' = a1.no_doc and r->'rows'->0->>'pengganti' is null, 'rinci', r->>'total');
    r := public.rc_archived_list(0, 100, 'TIDAK-ADA-XYZ');
    hasil := hasil || jsonb_build_object('uji', 'Pencarian arsip tanpa hasil', 'lulus', (r->>'total')::int = 0, 'rinci', r->>'total');
    insert into public.claims(no_doc, campaign_id, customer_id, depot_id, status, cb_net, version_no)
    values ('NPC/UJI/P1109/1', a1.campaign_id, a1.customer_id, a1.depot_id, 'not_yet', a1.cb_net, 1);
    r := public.rc_archived_list(0, 100, a1.no_doc);
    begin perform public.rc_unarchive_compilation(array[a1.id]); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Sudah dicompile ulang: arsip tidak dapat dikembalikan',
      'lulus', v_galat ~ 'tidak dapat dikembalikan' and r->'rows'->0->>'pengganti' = 'NPC/UJI/P1109/1', 'rinci', v_galat);
    delete from public.claims where no_doc = 'NPC/UJI/P1109/1';
    r := public.rc_unarchive_compilation(array[a1.id]);
    hasil := hasil || jsonb_build_object('uji', 'Tanpa pengganti: arsip tetap dapat dikembalikan', 'lulus', (select archived_at is null from public.claims where id = a1.id), 'rinci', r::text);

    -- ---- Change DC ------------------------------------------------------------------------------
    -- Toko dengan dokumen Not Yet dan Done di depot yang sama.
    select cu.id, cu.customer_code, c.depot_id into t from public.customers cu join public.claims c on c.customer_id = cu.id
     where cu.archived_at is null and c.archived_at is null and c.status = 'not_yet' and c.pending_approval is null
       and exists (select 1 from public.claims z where z.customer_id = cu.id and z.depot_id = c.depot_id and z.status = 'done')
       and not exists (select 1 from public.claims z where z.customer_id = cu.id and z.depot_id <> c.depot_id) limit 1;
    if t.id is null then raise exception 'Fixture: toko Not Yet + Done tidak ada'; end if;
    select d.id, d.depot_code into v_baru from public.depots d where d.id <> t.depot_id and d.archived_at is null and not coalesce(d.bukan_depot, false)
       and not exists (select 1 from public.claims c where c.customer_id = t.id and rc_private.np_pasangan(d.id, c.campaign_id))
       and not exists (select 1 from public.claims c join public.timetable_not_achieved na on na.campaign_id = c.campaign_id and na.depot_id = d.id where c.customer_id = t.id) order by d.depot_code limit 1;
    r := public.rc_change_dc_cek(jsonb_build_array(jsonb_build_object('kodeToko', t.customer_code, 'depotBaru', v_baru.depot_code)))->'rows'->0;
    hasil := hasil || jsonb_build_object('uji', 'Cek: menampilkan depot asal, jumlah dokumen', 'lulus', jsonb_array_length(r->'asal') >= 1, 'rinci', (r->'asal')::text);
    begin perform pg_temp.cdc(t.customer_code, v_baru.depot_code, 'x'); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Reason wajib', 'lulus', v_galat ~ 'Reason wajib', 'rinci', v_galat);
    select count(*) filter (where status not in ('done', 'expired')), count(*) filter (where status in ('done', 'expired')) into n, n2 from public.claims where customer_id = t.id;
    r := pg_temp.cdc(t.customer_code, v_baru.depot_code, 'Uji Change DC');
    hasil := hasil || jsonb_build_object('uji', 'Dokumen aktif pindah, master pindah; Done tetap di depot lama dengan Remark DC changed',
      'lulus', (r->>'dipindah')::int = n and (r->>'tetap')::int = n2
           and not exists (select 1 from public.claims where customer_id = t.id and status not in ('done', 'expired') and depot_id <> v_baru.id)
           and not exists (select 1 from public.claims where customer_id = t.id and status in ('done', 'expired') and depot_id <> t.depot_id)
           and (select array_agg(depot_id) from public.customer_depots where customer_id = t.id) = array[v_baru.id]
           and not exists (select 1 from public.claims c where c.customer_id = t.id and c.status = 'done' and coalesce(rc_private.claim_remark(c), '') !~ 'DC changed'),
      'rinci', r->>'message');
    hasil := hasil || jsonb_build_object('uji', 'Dokumen aktif tanpa Remark DC changed; riwayat per dokumen; Log Activity satu baris',
      'lulus', not exists (select 1 from public.claims c where c.customer_id = t.id and c.status not in ('done', 'expired') and coalesce(rc_private.claim_remark(c), '') ~ 'DC changed')
           and (select count(*) from public.claim_status_history h join public.claims c on c.id = h.claim_id where c.customer_id = t.id and h.action = 'change_dc') = n + n2
           and (select count(*) from public.activity_logs where event_type = 'change_dc' and entity_id = t.id) = 1, 'rinci', '-');
    update public.claims set updated_at = now() where customer_id = t.id and status = 'done';
    hasil := hasil || jsonb_build_object('uji', 'Dokumen Done tersentuh: toko tidak tertaut kembali ke depot lama',
      'lulus', not exists (select 1 from public.customer_depots where customer_id = t.id and depot_id = t.depot_id), 'rinci', '-');
    begin perform pg_temp.cdc(t.customer_code, v_baru.depot_code, 'Uji lagi'); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Toko sudah di depot itu: ditolak', 'lulus', v_galat ~* 'sudah berada', 'rinci', v_galat);
    -- 20261163830000: abbr No Doc, nomor lama, Expired, tanpa yurisdiksi, bawaan OSC.
    hasil := hasil || jsonb_build_object('uji', 'Dokumen pindah: No Doc mengikuti abbr depot baru, nomor lama tersimpan; Done tetap nomor lama',
      'lulus', not exists (select 1 from public.claims c join public.depots d on d.id = c.depot_id where c.customer_id = t.id and c.status not in ('done', 'expired') and split_part(c.no_doc, '/', 3) <> d.abbr)
           and exists (select 1 from public.claims c where c.customer_id = t.id and c.status not in ('done', 'expired') and c.no_doc_lama is not null)
           and not exists (select 1 from public.claims c where c.customer_id = t.id and c.status in ('done', 'expired') and c.no_doc_lama is not null),
      'rinci', (select string_agg(c.no_doc || ' <- ' || coalesce(c.no_doc_lama, '-'), ', ') from public.claims c where c.customer_id = t.id and c.status not in ('done', 'expired')));
    update public.claims set status = 'claimed' where id = (select id from public.claims where customer_id = t.id and no_doc_lama is not null limit 1) returning no_doc, no_doc_lama, cb_net into a1;
    r := public.rc_clearing_bank_preview('Lama.xlsx', md5(random()::text) || md5(random()::text), 2026, 'form', jsonb_build_array(
      jsonb_build_object('baris', 2, 'transId', '', 'effDate', '03-Nov-26', 'tglTransfer', v_tgl, 'remark1', a1.no_doc_lama, 'status', 'Berhasil')), 'template');
    hasil := hasil || jsonb_build_object('uji', 'Upload memakai No Doc lama tetap dikenali',
      'lulus', r->'rows'->0->>'noDocRc' = a1.no_doc, 'rinci', (r->'rows'->0)::text);
    v_lama := (select p.id from public.profiles p where lower(p.role) = 'osc' and p.status = 'active'
                and exists (select 1 from public.user_permissions up where up.user_id = p.id and up.permission_code = 'view_compilation')
                and not exists (select 1 from rc_private.user_tab_access u where u.user_id = p.id and u.tab_code = 'compilation.changedc' and not u.allowed) limit 1);
    if v_lama is not null then
      select c.customer_id id, cu.customer_code, c.depot_id into t from public.claims c join public.customers cu on cu.id = c.customer_id
       where c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null and cu.archived_at is null
         and not exists (select 1 from public.user_depot_access x where x.user_id = v_lama and x.depot_id = c.depot_id)
         and not exists (select 1 from public.claims z join public.timetable_not_achieved na on na.campaign_id = z.campaign_id and na.depot_id = v_baru.id where z.customer_id = c.customer_id)
         and not exists (select 1 from public.claims z where z.customer_id = c.customer_id and rc_private.np_pasangan(v_baru.id, z.campaign_id))
         and c.depot_id <> v_baru.id limit 1;
      perform set_config('request.jwt.claims', json_build_object('sub', v_lama::text, 'role', 'authenticated')::text, true);
      hasil := hasil || jsonb_build_object('uji', 'OSC: Change Value dan Change DC bawaan hidup',
        'lulus', coalesce((rc_private.tab_rights(v_lama)->>'compilation.amend')::boolean, false) and coalesce((rc_private.tab_rights(v_lama)->>'compilation.changedc')::boolean, false), 'rinci', '-');
      if t.id is not null then
        r := pg_temp.cdc(t.customer_code, v_baru.depot_code, 'Uji tanpa yurisdiksi');
        hasil := hasil || jsonb_build_object('uji', 'Change DC toko di luar jangkauan pemanggil: berhasil (tanpa yurisdiksi)', 'lulus', r->>'status' = 'success', 'rinci', r->>'message');
      end if;
      perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    end if;
    -- 20261163840000: kepala batch 6 (compile ulang) dan 7 (nilai diubah).
    select c.id, c.no_doc, c.campaign_id, c.customer_id, c.cb_net, c.depot_id, c.version_no, ca.campaign_code, cu.customer_code, d.depot_code into a1
      from public.claims c join public.campaigns ca on ca.id = c.campaign_id join public.customers cu on cu.id = c.customer_id join public.depots d on d.id = c.depot_id
     where c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null and ca.status not in ('inactive', 'cleared') and ca.archived_at is null and cu.archived_at is null and d.abbr is not null
       and not rc_private.np_pasangan(c.depot_id, c.campaign_id)
       and not exists (select 1 from public.timetable_not_achieved na where na.depot_id = c.depot_id and na.campaign_id = c.campaign_id) order by c.no_doc limit 1;
    perform public.rc_archive_compilation(array[a1.id], 'Uji compile ulang');
    r := public.rc_compile_upload(jsonb_build_array(jsonb_build_object('kodeDepot', a1.depot_code, 'codeCampaign', a1.campaign_code, 'custCode', a1.customer_code, 'cbNet', '1000', 'netValue', '1000', 'volume', '1')), gen_random_uuid());
    hasil := hasil || jsonb_build_object('uji', 'Compile ulang dokumen arsip: kode 6, batch compile berkepala 6, dokumen baru',
      'lulus', (r->>'dibuat')::int = 1 and r->>'batch' ~ '^65'
           and (select c.batch_event_code = '6' from public.claims c where c.no_doc = r->'dokumen'->0->>'noDoc')
           and (select h.batch ~ '^65' from public.claim_status_history h join public.claims c on c.id = h.claim_id where c.no_doc = r->'dokumen'->0->>'noDoc' and h.action = 'compile_import'), 'rinci', r::text);
    update public.claims set status = 'released', batch_release = '022000911260001', batch_upload = '012000911260001', batch_event_code = '0' where id = (select c.id from public.claims c where c.no_doc = r->'dokumen'->0->>'noDoc') returning no_doc, version_no into a1.no_doc, a1.version_no;
    r2 := public.rc_amend_doc(jsonb_build_array(jsonb_build_object('noDoc', a1.no_doc, 'cbNet', '2000', 'versionNo', a1.version_no)), 'Uji Change Value');
    hasil := hasil || jsonb_build_object('uji', 'Change Value: kode 7; batch stage saat ini berkepala 7, stage sebelumnya tetap',
      'lulus', (select batch_event_code = '7' and batch_release = '722000911260001' and batch_upload = '012000911260001' from public.claims where no_doc = a1.no_doc), 'rinci', r2->>'message');
    hasil := hasil || jsonb_build_object('uji', 'batch_kejadian menerima 6 dan 7', 'lulus', rc_private.batch_kejadian('032000911260001', '7') = '732000911260001' and rc_private.batch_kejadian('032000911260001', '6') = '632000911260001', 'rinci', '-');
    -- 20261163850000: banyak toko sekali proses (template).
    select d.id depot_id, d.depot_code, (array_agg(x.customer_code order by x.customer_code))[1:2] kode, (array_agg(x.id order by x.customer_code))[1:2] ids into tm
      from (select cu.id, cu.customer_code, min(c.depot_id::text)::uuid depot_id from public.customers cu join public.claims c on c.customer_id = cu.id
             where cu.archived_at is null and c.archived_at is null and c.status = 'not_yet'
               and not exists (select 1 from public.claims z where z.customer_id = cu.id and z.depot_id <> c.depot_id)
               and not exists (select 1 from public.customer_depots cd where cd.customer_id = cu.id and cd.depot_id <> c.depot_id)
             group by cu.id) x
      join public.depots d on d.id = x.depot_id
     where d.id <> v_baru.id group by d.id, d.depot_code having count(*) >= 2 order by d.depot_code limit 1;
    if tm.depot_id is null then raise exception 'Fixture: dua toko satu depot tidak ada'; end if;
    r := public.rc_change_dc_cek(jsonb_build_array(
      jsonb_build_object('kodeToko', tm.kode[1], 'depotBaru', v_baru.depot_code),
      jsonb_build_object('kodeToko', 'TIDAKADA999', 'depotBaru', v_baru.depot_code),
      jsonb_build_object('kodeToko', tm.kode[2], 'depotBaru', ''),
      jsonb_build_object('kodeToko', tm.kode[2], 'depotBaru', 'ZZ9')));
    hasil := hasil || jsonb_build_object('uji', 'Cek banyak baris: hasil berurutan, galat per baris',
      'lulus', r->'rows'->0->>'kodeToko' = tm.kode[1] and not (r->'rows'->0 ? 'galat') and r->'rows'->1->>'galat' ~ 'Customer Master' and r->'rows'->2->>'galat' ~ 'wajib diisi' and r->'rows'->3->>'galat' ~ 'Depot Master', 'rinci', (r->'rows')::text);
    begin
      perform public.rc_change_dc(jsonb_build_array(
        jsonb_build_object('kodeToko', tm.kode[1], 'depotBaru', v_baru.depot_code),
        jsonb_build_object('kodeToko', tm.kode[2], 'depotBaru', v_baru.depot_code),
        jsonb_build_object('kodeToko', 'TIDAKADA999', 'depotBaru', v_baru.depot_code)), 'Uji satu salah');
      v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Satu baris salah: seluruhnya ditolak, tidak ada toko yang pindah',
      'lulus', v_galat ~ 'TIDAKADA999: Tidak ada di Customer Master' and not exists (select 1 from public.claims c where c.customer_id = any(tm.ids) and c.depot_id <> tm.depot_id), 'rinci', v_galat);
    begin
      perform public.rc_change_dc(jsonb_build_array(
        jsonb_build_object('kodeToko', tm.kode[1], 'depotBaru', v_baru.depot_code), jsonb_build_object('kodeToko', lower(tm.kode[1]), 'depotBaru', tm.depot_code)), 'Uji ganda');
      v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Kode Toko ganda di daftar: ditolak', 'lulus', v_galat ~ 'ganda', 'rinci', v_galat);
    begin
      perform public.rc_change_dc(jsonb_build_array(jsonb_build_object('kodeToko', tm.kode[1], 'depotBaru', v_baru.depot_code, 'reason', 'Reason baris'),
        jsonb_build_object('kodeToko', tm.kode[2], 'depotBaru', v_baru.depot_code)), '');
      v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Baris tanpa Reason dan tanpa Reason umum: ditolak', 'lulus', v_galat ~ (tm.kode[2] || ': Reason wajib'), 'rinci', v_galat);
    begin
      perform public.rc_change_dc((select jsonb_agg(jsonb_build_object('kodeToko', 'T' || g, 'depotBaru', v_baru.depot_code)) from generate_series(1, 201) g), 'Uji batas');
      v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Lebih dari 200 baris: ditolak', 'lulus', v_galat ~ 'Maksimal 200', 'rinci', v_galat);
    update public.email_settings set aktif = true, mode_uji = true, email_uji = 'uji@example.com' where jenis = 'pengajuan';
    select count(*) into v_out from public.email_outbox where konteks->>'aksi' = 'changedc';
    select count(*) into v_log from public.activity_logs where event_type = 'change_dc';
    -- Depot Baru boleh huruf kecil atau nama depot; baris tanpa Reason memakai Reason umum.
    r := public.rc_change_dc(jsonb_build_array(
      jsonb_build_object('kodeToko', lower(tm.kode[1]), 'depotBaru', lower(v_baru.depot_code), 'reason', 'Reason baris'),
      jsonb_build_object('kodeToko', tm.kode[2], 'depotBaru', (select depot_name from public.depots where id = v_baru.id))), 'Reason umum');
    hasil := hasil || jsonb_build_object('uji', 'Dua toko pindah sekali proses; master dan dokumen ikut depot baru',
      'lulus', (r->>'toko')::int = 2 and not exists (select 1 from public.claims c where c.customer_id = any(tm.ids) and c.status not in ('done', 'expired') and c.depot_id <> v_baru.id)
           and not exists (select 1 from public.customer_depots cd where cd.customer_id = any(tm.ids) and cd.depot_id <> v_baru.id), 'rinci', r->>'message');
    hasil := hasil || jsonb_build_object('uji', 'Reason per baris, sisanya Reason umum',
      'lulus', not exists (select 1 from public.claim_status_history h join public.claims c on c.id = h.claim_id where h.action = 'change_dc' and c.customer_id = tm.ids[1] and h.reason !~ 'Reason baris')
           and not exists (select 1 from public.claim_status_history h join public.claims c on c.id = h.claim_id where h.action = 'change_dc' and c.customer_id = tm.ids[2] and h.reason !~ 'Reason umum'), 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Email: satu per pasangan depot, ke depot asal dan tujuan, memuat kedua toko',
      'lulus', (select count(*) from public.email_outbox where konteks->>'aksi' = 'changedc') = v_out + 2
           and not exists (select 1 from public.email_outbox e where e.konteks->>'aksi' = 'changedc' and e.konteks->>'kodeToko' = tm.kode[1] || ', ' || tm.kode[2] and (e.isi_html !~ tm.kode[1] or e.isi_html !~ tm.kode[2] or e.isi_html !~ 'Reason umum' or e.subjek !~ '2 Toko'))
           and exists (select 1 from public.email_outbox e where e.konteks->>'kodeToko' = tm.kode[1] || ', ' || tm.kode[2]),
      'rinci', (select string_agg(e.subjek, ' | ') from public.email_outbox e where e.konteks->>'kodeToko' = tm.kode[1] || ', ' || tm.kode[2]));
    hasil := hasil || jsonb_build_object('uji', 'Log Activity satu baris per proses, rincian per toko',
      'lulus', (select count(*) from public.activity_logs where event_type = 'change_dc') = v_log + 1
           and exists (select 1 from public.activity_logs l where l.event_type = 'change_dc' and l.details->>'jumlah' = '2' and l.entity_id is null and l.depot_id = v_baru.id
                          and l.details->'toko' @> jsonb_build_array(jsonb_build_object('kodeToko', tm.kode[1]), jsonb_build_object('kodeToko', tm.kode[2]))
                          and not (l.details->'toko'->0 ? 'customerId')), 'rinci', '-');
    r := public.rc_change_dc_riwayat();
    hasil := hasil || jsonb_build_object('uji', 'Riwayat: satu baris per toko dari satu proses',
      'lulus', exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'kodeToko' = tm.kode[1] and x->>'dari' = tm.depot_code and x->>'reason' = 'Reason baris')
           and exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'kodeToko' = tm.kode[2] and x->>'reason' = 'Reason umum'), 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Riwayat dan pilihan depot', 'lulus', jsonb_array_length(r->'rows') >= 1 and jsonb_array_length(r->'depot') > 1, 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Tab Change DC: SM punya; hanya bila dicentang',
      'lulus', coalesce((rc_private.tab_rights(v_sm)->>'compilation.changedc')::boolean, false)
        and not coalesce((select (rc_private.tab_rights(p.id)->>'compilation.changedc')::boolean from public.profiles p where p.role = 'admin' and p.status = 'active' limit 1), false), 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_p1109(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_p1109 order by urut;
