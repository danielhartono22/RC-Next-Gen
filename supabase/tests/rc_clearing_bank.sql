-- ==========================================================================================
-- Uji Clearing lewat Upload File Bank (20261163710000): penilaian per baris, Proses hanya baris
-- OK lewat alur Clearing lama, log upload, file / Trans ID tidak bisa diproses dua kali.
-- ==========================================================================================
-- Klaim uji (Claimed / Done / Released) dipakai apa adanya; seluruh perubahan dibatalkan lewat
-- UJI_SELESAI. Email Done yang ikut terantre juga dibatalkan.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_clearing_bank.sql
-- ==========================================================================================
create temp table if not exists _hasil_cbk(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_cbk;

do $uji$
declare hasil jsonb := '[]'; r jsonb; r2 jsonb; v_sm uuid; v_tanpa uuid; v_galat text; u record; n integer;
  k uuid[]; d1 record; r1 record; pj record; v_hari date := (now() at time zone 'Asia/Jakarta')::date;
  v_sidik text := md5('uji-a' || clock_timestamp()::text) || md5('uji-b' || clock_timestamp()::text);
  v_sidik2 text := md5('uji-c' || clock_timestamp()::text) || md5('uji-d' || clock_timestamp()::text);
  v_sidik3 text := md5('uji-e' || clock_timestamp()::text) || md5('uji-f' || clock_timestamp()::text);
  v_tgl date := (now() at time zone 'Asia/Jakarta')::date - 2; v_baris jsonb; v_upload uuid; kk record;
  -- No Doc tanpa awalan NPC/ (seperti Remark 1 file bank).
  fdoc text[] := '{}'; fnom numeric[] := '{}';
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  for u in select p.id from public.profiles p where p.status = 'active' order by p.user_code limit 200 loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    if not rc_private.can_tab('process.clearing') then v_tanpa := u.id; exit; end if;
  end loop;

  -- 7 klaim Claimed non-Rebate tanpa approval menunggu, No Doc berawalan NPC/ dan <= 22 karakter.
  select array_agg(id order by no_doc) into k from (
    select c.id, c.no_doc from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where c.status = 'claimed' and c.pending_approval is null and c.archived_at is null and c.no_doc like 'NPC/%' and length(c.no_doc) <= 22
       and (rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) <> 'rebate' or c.jalur_adhoc)
     order by c.no_doc limit 7) z;
  select c.id, c.no_doc, c.cb_net into d1 from public.claims c where c.status = 'done' and c.archived_at is null and c.no_doc like 'NPC/%' and length(c.no_doc) <= 22 order by c.no_doc limit 1;
  select c.id, c.no_doc, c.cb_net into r1 from public.claims c where c.status in ('released', 'approved', 'not_yet') and c.archived_at is null and c.no_doc like 'NPC/%' and length(c.no_doc) <= 22 order by c.no_doc limit 1;
  -- No Doc panjang (> 18 karakter tanpa NPC/) untuk kasus terpotong.
  select c.id, c.no_doc, c.cb_net into pj from public.claims c where c.archived_at is null and c.no_doc like 'NPC/%' and length(c.no_doc) > 22 order by c.no_doc limit 1;

  begin
    if coalesce(array_length(k, 1), 0) < 7 or d1.id is null or r1.id is null or pj.id is null then raise exception 'Fixture: klaim Claimed / Done / Released / No Doc panjang tidak cukup'; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    for kk in select cl.no_doc, trunc(cl.cb_net) cb from public.claims cl where cl.id = any(k) order by cl.no_doc loop
      fdoc := fdoc || substr(kk.no_doc, 5); fnom := fnom || kk.cb;
    end loop;

    v_baris := jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'UJI-T001', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', fnom[1]::text, 'remark1', fdoc[1], 'bank', 'BCA', 'toAcc', '111', 'status', 'Berhasil', 'reason', 'HOST_TRAN SUCCESSFUL'),
      jsonb_build_object('baris', 2, 'transId', 'UJI-T002', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', fnom[2]::text, 'remark1', fdoc[2], 'bank', 'BRI', 'toAcc', '222', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 3, 'transId', 'UJI-T003', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', (fnom[3] + 500)::text, 'remark1', fdoc[3], 'bank', 'BCA', 'toAcc', '333', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 4, 'transId', 'UJI-T004', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(d1.cb_net)::text, 'remark1', substr(d1.no_doc, 5), 'bank', 'BCA', 'toAcc', '444', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 5, 'transId', 'UJI-T005', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(r1.cb_net)::text, 'remark1', substr(r1.no_doc, 5), 'bank', 'BCA', 'toAcc', '555', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 6, 'transId', 'UJI-T006', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', '2250000', 'remark1', 'CB/KPO/1425/999', 'bank', 'BCA', 'toAcc', '666', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 7, 'transId', 'UJI-T007', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(pj.cb_net)::text, 'remark1', left(substr(pj.no_doc, 5), 18), 'bank', 'BCA', 'toAcc', '777', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 8, 'transId', 'UJI-T008', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', fnom[4]::text, 'remark1', fdoc[4], 'bank', 'BCA', 'toAcc', '888', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 9, 'transId', 'UJI-T009', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', fnom[4]::text, 'remark1', fdoc[4], 'bank', 'BCA', 'toAcc', '888', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 10, 'transId', 'UJI-T010', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', fnom[5]::text, 'remark1', fdoc[5], 'bank', 'BCA', 'toAcc', '999', 'status', 'Gagal', 'reason', 'REKENING TIDAK AKTIF'),
      jsonb_build_object('baris', 11, 'transId', 'UJI-T011', 'effDate', '09 Nov 202', 'tglTransfer', v_hari + 3, 'nominal', fnom[6]::text, 'remark1', fdoc[6], 'bank', 'BCA', 'toAcc', '000', 'status', 'Berhasil', 'reason', ''));

    -- ---- Pratinjau ----------------------------------------------------------------------
    r := public.rc_clearing_bank_preview('MultiTransactionAutoTransferDownload_05112026090000.txt', v_sidik, 2026, 'nama_file', v_baris);
    v_upload := (r->'upload'->>'id')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau: hasil per baris sesuai aturan',
      'lulus', (select string_agg(x->>'hasil', ',' order by (x->>'baris')::int) from jsonb_array_elements(r->'rows') x)
             = 'ok,ok,nominal_beda,sudah_clearing,belum_siap,tidak_ditemukan,terpotong,duplikat,duplikat,gagal_transfer,tanggal_salah',
      'rinci', (select string_agg((x->>'baris') || '=' || (x->>'hasil'), ', ' order by (x->>'baris')::int) from jsonb_array_elements(r->'rows') x));
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau: No Doc file tanpa NPC/ dicocokkan ke No Doc RC; toko ikut tampil',
      'lulus', (select x->>'noDocRc' from jsonb_array_elements(r->'rows') x where x->>'baris' = '1') = 'NPC/' || fdoc[1]
           and (select x->>'kodeToko' from jsonb_array_elements(r->'rows') x where x->>'baris' = '1') <> '', 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Nominal beda: keterangan memuat nominal klaim dan transfer, tidak diproses',
      'lulus', (select x->>'keterangan' from jsonb_array_elements(r->'rows') x where x->>'baris' = '3') ~ ('Net CB\) Rp ' || replace(rc_private.angka(fnom[3]), '.', '\.') || ', transfer Rp ')
           and (select (x->>'nominalKlaim')::numeric from jsonb_array_elements(r->'rows') x where x->>'baris' = '3') = fnom[3],
      'rinci', (select x->>'keterangan' from jsonb_array_elements(r->'rows') x where x->>'baris' = '3'));
    hasil := hasil || jsonb_build_object('uji', 'Sudah clearing: tanggal clearing sebelumnya ditampilkan',
      'lulus', (select x->>'keterangan' from jsonb_array_elements(r->'rows') x where x->>'baris' = '4') ~ '^Sudah Done; tanggal clearing ',
      'rinci', (select x->>'keterangan' from jsonb_array_elements(r->'rows') x where x->>'baris' = '4'));
    hasil := hasil || jsonb_build_object('uji', 'No Doc terpotong 18 karakter: ditolak dengan kandidat, proses manual',
      'lulus', (select x->>'keterangan' from jsonb_array_elements(r->'rows') x where x->>'baris' = '7') ~ ('Kandidat: .*' || replace(pj.no_doc, '/', '/')) ,
      'rinci', (select x->>'keterangan' from jsonb_array_elements(r->'rows') x where x->>'baris' = '7'));
    hasil := hasil || jsonb_build_object('uji', 'Ringkasan: jumlah baris, total nominal, jumlah per hasil',
      'lulus', (r->'ringkasan'->>'baris')::int = 11 and (r->'ringkasan'->'perHasil'->>'ok')::int = 2 and (r->'ringkasan'->'perHasil'->>'duplikat')::int = 2
           and (r->'ringkasan'->>'totalNominal')::numeric = (select sum((x->>'nominal')::numeric) from jsonb_array_elements(v_baris) x)
           and (r->'ringkasan'->>'totalOk')::numeric = fnom[1] + fnom[2],
      'rinci', (r->'ringkasan')::text);
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau tidak mengubah klaim apa pun',
      'lulus', (select bool_and(status = 'claimed') from public.claims where id = any(k)), 'rinci', '-');

    -- ---- Proses Clearing ---------------------------------------------------------------
    select count(*) into n from public.activity_logs where event_type = 'clearing_upload_bank';
    r := public.rc_clearing_bank_proses(v_upload);
    hasil := hasil || jsonb_build_object('uji', 'Proses: hanya 2 baris OK jadi Done lewat alur Clearing lama (Tgl Transfer = Eff Date, batch Clearing)',
      'lulus', (r->>'diproses')::int = 2
           and (select count(*) from public.claims where id = any(k[1:2]) and status = 'done' and cleared_actual_on = v_tgl
                  and (cleared_at at time zone 'Asia/Jakarta')::date = v_tgl
                  -- Dokumen dengan digit kejadian berbeda mendapat batch berbeda; hasil proses mendaftar semuanya.
                  and position(batch_clearing in r->>'batch') > 0) = 2
           and (select bool_and(status = 'claimed') from public.claims where id = any(k[3:7]))
           and exists (select 1 from public.claim_status_history h where h.claim_id = k[1] and h.action = 'clearing' and h.to_status = 'done'),
      'rinci', coalesce(r->>'message', r::text));
    hasil := hasil || jsonb_build_object('uji', 'Log upload: status diproses, batch, baris OK ditandai; Log Activity satu baris',
      'lulus', (select status = 'diproses' and batch_clearing = r->>'batch' and jumlah_diproses = 2 and diproses_oleh = v_sm from public.rc_clearing_bank_upload where id = v_upload)
           and (select count(*) from public.rc_clearing_bank_baris where upload_id = v_upload and diproses) = 2
           and (select count(*) from public.activity_logs where event_type = 'clearing_upload_bank') = n + 1,
      'rinci', '-');
    begin perform public.rc_clearing_bank_proses(v_upload); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Upload yang sama tidak bisa diproses dua kali', 'lulus', v_galat ~ 'sudah diproses', 'rinci', v_galat);
    begin perform public.rc_clearing_bank_preview('nama-lain.txt', v_sidik, 2026, 'form', v_baris); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'File berisi sama (sidik sama, nama beda) ditolak', 'lulus', v_galat ~ 'sudah diproses', 'rinci', v_galat);

    -- File lain: Trans ID + tanggal yang sama = sudah diproses; No Doc yang sudah Done = sudah clearing.
    r2 := public.rc_clearing_bank_preview('MultiTransactionAutoTransferDownload_05112026100000.txt', v_sidik2, 2026, 'nama_file', jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'UJI-T001', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', fnom[1]::text, 'remark1', fdoc[1], 'bank', 'BCA', 'toAcc', '1', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 2, 'transId', 'UJI-X002', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', fnom[2]::text, 'remark1', fdoc[2], 'bank', 'BCA', 'toAcc', '2', 'status', 'Berhasil', 'reason', '')));
    hasil := hasil || jsonb_build_object('uji', 'File lain: Trans ID sama = sudah diproses; No Doc yang sudah Done = sudah clearing',
      'lulus', (select string_agg(x->>'hasil', ',' order by (x->>'baris')::int) from jsonb_array_elements(r2->'rows') x) = 'sudah_diproses,sudah_clearing',
      'rinci', (select string_agg(x->>'keterangan', ' | ' order by (x->>'baris')::int) from jsonb_array_elements(r2->'rows') x));

    -- Berubah sejak pratinjau: baris yang tidak OK lagi saat Proses dilewati, yang lain tetap diproses.
    r2 := public.rc_clearing_bank_preview('MultiTransactionAutoTransferDownload_05112026110000.txt', v_sidik3, 2026, 'nama_file', jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'UJI-Y001', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', fnom[6]::text, 'remark1', fdoc[6], 'bank', 'BCA', 'toAcc', '1', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 2, 'transId', 'UJI-Y002', 'effDate', '03 Nov 202', 'tglTransfer', v_tgl, 'nominal', fnom[7]::text, 'remark1', fdoc[7], 'bank', 'BCA', 'toAcc', '2', 'status', 'Berhasil', 'reason', '')));
    update public.claims set cb_net = cb_net + 1 where id = k[6];
    r2 := public.rc_clearing_bank_proses((r2->'upload'->>'id')::uuid);
    hasil := hasil || jsonb_build_object('uji', 'Berubah sejak pratinjau: baris itu tidak diproses (nominal beda), baris lain tetap Done',
      'lulus', (r2->>'diproses')::int = 1 and (r2->>'berubah')::int = 1
           and (select status from public.claims where id = k[6]) = 'claimed' and (select status from public.claims where id = k[7]) = 'done'
           and (select x->>'keterangan' from jsonb_array_elements(r2->'rows') x where x->>'baris' = '1') ~ '^Berubah sejak pratinjau: Nominal klaim',
      'rinci', coalesce(r2->>'message', r2::text));

    -- ---- Akses -------------------------------------------------------------------------
    if v_tanpa is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_tanpa::text, 'role', 'authenticated')::text, true);
      begin perform public.rc_clearing_bank_preview('x.txt', v_sidik3, 2026, 'form', v_baris); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
      hasil := hasil || jsonb_build_object('uji', 'User tanpa tab Clearing ditolak', 'lulus', v_galat ~ 'process\.clearing', 'rinci', v_galat);
    end if;
    hasil := hasil || jsonb_build_object('uji', 'Tabel log tertutup bagi authenticated; anon tidak bisa memanggil',
      'lulus', not has_table_privilege('authenticated', 'public.rc_clearing_bank_baris', 'select')
           and not has_function_privilege('anon', 'public.rc_clearing_bank_proses(uuid)', 'execute'), 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_cbk(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_cbk order by urut;
