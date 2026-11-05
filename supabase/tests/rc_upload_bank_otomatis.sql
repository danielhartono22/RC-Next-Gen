-- ==========================================================================================
-- Uji Upload File Bank mode otomatis (20261163750000): satu upload me-Clearing dokumen Pending
-- Finance dan menyimpan Bukti TF dokumen yang sudah Done, tanpa pilihan Mode.
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI (termasuk email Done yang ikut terantre).
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_upload_bank_otomatis.sql
-- ==========================================================================================
create temp table if not exists _hasil_ubo(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_ubo;

do $uji$
declare hasil jsonb := '[]'; r jsonb; r2 jsonb; v_sm uuid; v_galat text; v_up uuid; v_tgl date := (now() at time zone 'Asia/Jakarta')::date - 1;
  k1 record; k2 record; k3 record; d1 record; d2 record; v_status0 text; v_batch0 text;
  v_sidik text := md5('ubo-a' || clock_timestamp()::text) || md5('ubo-b' || clock_timestamp()::text);
  v_sidik2 text := md5('ubo-c' || clock_timestamp()::text) || md5('ubo-d' || clock_timestamp()::text);
  v_sidik3 text := md5('ubo-e' || clock_timestamp()::text) || md5('ubo-f' || clock_timestamp()::text);
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- Tiga klaim Claimed non-Rebate dan dua klaim Done, seluruhnya belum punya Bukti TF.
  create temp table _ubo_c on commit drop as
    select c.id, c.no_doc, c.cb_net from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where c.status = 'claimed' and c.pending_approval is null and c.archived_at is null and c.no_doc like 'NPC/%' and length(c.no_doc) <= 22
       and (rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) <> 'rebate' or c.jalur_adhoc)
       and not exists (select 1 from public.rc_clearing_bank_baris bb where bb.claim_id = c.id and bb.diproses)
     order by c.no_doc limit 3;
  select * into k1 from _ubo_c order by no_doc limit 1;
  select * into k2 from _ubo_c order by no_doc offset 1 limit 1;
  select * into k3 from _ubo_c order by no_doc offset 2 limit 1;
  create temp table _ubo_d on commit drop as
    select c.id, c.no_doc, c.cb_net, c.status, c.batch_clearing from public.claims c
     where c.status = 'done' and c.archived_at is null and c.no_doc like 'NPC/%' and length(c.no_doc) <= 22
       and not exists (select 1 from public.rc_clearing_bank_baris bb where bb.claim_id = c.id and bb.diproses)
     order by c.no_doc limit 2;
  select * into d1 from _ubo_d order by no_doc limit 1;
  select * into d2 from _ubo_d order by no_doc offset 1 limit 1;

  begin
    if k3.id is null or d2.id is null then raise exception 'Fixture: klaim Claimed / Done tanpa Bukti TF tidak cukup'; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

    begin perform public.rc_clearing_bank_preview('x_05112026120000.txt', v_sidik, 2026, 'nama_file', jsonb_build_array(jsonb_build_object('baris', 1)), 'xyz');
      v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Mode tidak dikenal ditolak', 'lulus', v_galat ~ 'Mode upload tidak dikenal', 'rinci', v_galat);

    -- Satu file: Pending Finance (ok), Done (ok_bukti), keduanya dengan nominal beda, dan Pending Finance kedua.
    r := public.rc_clearing_bank_preview('MultiTransactionAutoTransferDownload_05112026120000.txt', v_sidik, 2026, 'nama_file', jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'UBO-001', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(k1.cb_net)::text, 'remark1', substr(k1.no_doc, 5),
        'bank', 'BCA', 'toAcc', '111', 'status', 'Berhasil', 'reason', '', 'layanan', 'BCA', 'biaya', '0', 'biayaOleh', 'OUR'),
      jsonb_build_object('baris', 2, 'transId', 'UBO-002', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(d1.cb_net)::text, 'remark1', substr(d1.no_doc, 5),
        'bank', 'BRI', 'toAcc', '222', 'status', 'Berhasil', 'reason', '', 'layanan', 'LLG', 'namaBank', 'PT. BANK RAKYAT INDONESIA (PERSERO)', 'biaya', '2900', 'biayaOleh', 'OUR'),
      jsonb_build_object('baris', 3, 'transId', 'UBO-003', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', (trunc(k2.cb_net) + 1)::text, 'remark1', substr(k2.no_doc, 5),
        'bank', 'BCA', 'toAcc', '333', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 4, 'transId', 'UBO-004', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', (trunc(d2.cb_net) + 1)::text, 'remark1', substr(d2.no_doc, 5),
        'bank', 'BCA', 'toAcc', '444', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 5, 'transId', 'UBO-005', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(k3.cb_net)::text, 'remark1', substr(k3.no_doc, 5),
        'bank', 'BCA', 'toAcc', '555', 'status', 'Berhasil', 'reason', '')), 'otomatis');
    v_up := (r->'upload'->>'id')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau otomatis: Pending Finance = ok, sudah Done = ok_bukti, nominal beda tetap ditolak',
      'lulus', r->'upload'->>'mode' = 'otomatis'
           and (select string_agg(x->>'hasil', ',' order by (x->>'baris')::int) from jsonb_array_elements(r->'rows') x) = 'ok,ok_bukti,nominal_beda,nominal_beda,ok'
           and (select x->>'keterangan' from jsonb_array_elements(r->'rows') x where x->>'baris' = '2') ~ 'hanya Bukti TF yang disimpan',
      'rinci', (select string_agg((x->>'baris') || '=' || (x->>'hasil') || ' ' || (x->>'keterangan'), ' | ' order by (x->>'baris')::int) from jsonb_array_elements(r->'rows') x));
    hasil := hasil || jsonb_build_object('uji', 'Ringkasan: Nominal OK = Clearing + Bukti TF; pesan menyebut keduanya',
      'lulus', (r->'ringkasan'->>'totalOk')::numeric = trunc(k1.cb_net) + trunc(d1.cb_net) + trunc(k3.cb_net)
           and r->>'message' ~ '2 siap Clearing, 1 sudah Done',
      'rinci', (r->'ringkasan'->>'totalOk') || ' | ' || (r->>'message'));

    -- Dokumen k3 di-Clearing orang lain sesudah pratinjau: tetap diproses sebagai Bukti TF saja.
    update public.claims set status = 'done', cleared_at = now(), cleared_actual_on = v_tgl where id = k3.id;
    select status, batch_clearing into v_status0, v_batch0 from public.claims where id = d1.id;
    r := public.rc_clearing_bank_proses(v_up);
    hasil := hasil || jsonb_build_object('uji', 'Proses: Pending Finance jadi Done (batch Clearing), dokumen Done tidak berubah, keduanya ber-Bukti TF',
      'lulus', (select status = 'done' and batch_clearing = r->>'batch' from public.claims where id = k1.id)
           and (select status = v_status0 and batch_clearing is not distinct from v_batch0 from public.claims where id = d1.id)
           and rc_private.bukti_tf(k1.id) is not null and rc_private.bukti_tf(d1.id) is not null
           and (select status from public.claims where id = k2.id) = 'claimed',
      'rinci', r->>'message');
    hasil := hasil || jsonb_build_object('uji', 'Dokumen yang di-Clearing orang lain sesudah pratinjau: hanya Bukti TF, tidak dihitung berubah',
      'lulus', rc_private.bukti_tf(k3.id) is not null and (r->>'clearing')::int = 1 and (r->>'bukti')::int = 2 and (r->>'berubah')::int = 0
           and (select x->>'keterangan' from jsonb_array_elements(r->'rows') x where x->>'baris' = '5') ~ 'status tidak berubah',
      'rinci', 'clearing ' || (r->>'clearing') || ', bukti ' || (r->>'bukti') || ', berubah ' || (r->>'berubah'));
    hasil := hasil || jsonb_build_object('uji', 'Pesan dan Log Activity menyebut Clearing dan Bukti TF',
      'lulus', r->>'message' ~ '1 dokumen di-Clearing \(Done\), batch' and r->>'message' ~ '2 Bukti TF tersimpan untuk dokumen yang sudah Done'
           and exists (select 1 from public.activity_logs where event_type = 'clearing_upload_bank' and details->>'upload' = v_up::text
                         and (details->>'clearing')::int = 1 and (details->>'bukti')::int = 2),
      'rinci', r->>'message');

    begin perform public.rc_clearing_bank_preview('nama-lain.txt', v_sidik, 2026, 'form', jsonb_build_array(jsonb_build_object('baris', 1, 'remark1', 'X', 'status', 'Berhasil')), 'otomatis');
      v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'File yang sama tidak bisa diproses dua kali', 'lulus', v_galat ~ 'sudah diproses \(mode Upload File Bank\)', 'rinci', v_galat);
    r2 := public.rc_clearing_bank_preview('lain_05112026130000.txt', v_sidik2, 2026, 'nama_file', jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'UBO-LAIN', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(d1.cb_net)::text, 'remark1', substr(d1.no_doc, 5),
        'bank', 'BCA', 'toAcc', '1', 'status', 'Berhasil', 'reason', '')), 'otomatis');
    hasil := hasil || jsonb_build_object('uji', 'Dokumen Done yang sudah ber-Bukti TF: file lain = sudah diproses',
      'lulus', r2->'rows'->0->>'hasil' = 'sudah_diproses', 'rinci', r2->'rows'->0->>'keterangan');

    -- Mode clearing lama tetap: dokumen Done = sudah_clearing.
    r2 := public.rc_clearing_bank_preview('lama_05112026140000.txt', v_sidik3, 2026, 'nama_file', jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'UBO-LAMA', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(d2.cb_net)::text, 'remark1', substr(d2.no_doc, 5),
        'bank', 'BCA', 'toAcc', '1', 'status', 'Berhasil', 'reason', '')), 'clearing');
    hasil := hasil || jsonb_build_object('uji', 'Mode clearing lama tidak berubah (dokumen Done = sudah clearing)',
      'lulus', r2->'rows'->0->>'hasil' = 'sudah_clearing', 'rinci', r2->'rows'->0->>'keterangan');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_ubo(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_ubo order by urut;
