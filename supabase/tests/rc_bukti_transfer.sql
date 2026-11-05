-- ==========================================================================================
-- Uji Bukti Transfer (20261163730000): mode Arsip Bukti TF, isi Bukti TF, Bukti TF di form PDA
-- Tanda Terima, Bukti TF dari Clearing file bank, file / dokumen tidak tersimpan dua kali.
-- 20261163740000: Remark PP + saringan Remark, rekening tidak lagi dikirim, hasil file bank membawa
-- nama campaign dan Gross Up (Laporan Workflow).
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_bukti_transfer.sql
-- ==========================================================================================
create temp table if not exists _hasil_btf(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_btf;

do $uji$
declare hasil jsonb := '[]'; r jsonb; r2 jsonb; v_sm uuid; v_galat text; n integer; b jsonb; v_up uuid; v_kode text;
  d1 record; d2 record; k1 record; v_tgl date := (now() at time zone 'Asia/Jakarta')::date - 1;
  v_sidik text := md5('btf-a' || clock_timestamp()::text) || md5('btf-b' || clock_timestamp()::text);
  v_sidik2 text := md5('btf-c' || clock_timestamp()::text) || md5('btf-d' || clock_timestamp()::text);
  v_sidik3 text := md5('btf-e' || clock_timestamp()::text) || md5('btf-f' || clock_timestamp()::text);
  v_status0 text; v_batch0 text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- Dua klaim Done Transfer / CN (toko bermaster lengkap), satu klaim Claimed Transfer / CN.
  select c.id, c.no_doc, c.cb_net, c.depot_id, c.customer_id into d1 from public.claims c join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'done' and c.archived_at is null and c.no_doc like 'NPC/%' and length(c.no_doc) <= 22 and rc_private.docgen_masalah_master(c.customer_id) is null
     and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('transfer', 'cn')
     and not exists (select 1 from public.rc_clearing_bank_baris bb where bb.claim_id = c.id and bb.diproses)
   order by c.no_doc limit 1;
  select c.id, c.no_doc, c.cb_net into d2 from public.claims c where c.status = 'done' and c.archived_at is null and c.no_doc like 'NPC/%'
     and length(c.no_doc) <= 22 and c.id <> d1.id and not exists (select 1 from public.rc_clearing_bank_baris bb where bb.claim_id = c.id and bb.diproses)
   order by c.no_doc limit 1;
  select c.id, c.no_doc, c.cb_net, c.depot_id, c.customer_id into k1 from public.claims c join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'claimed' and c.pending_approval is null and c.archived_at is null and c.no_doc like 'NPC/%' and length(c.no_doc) <= 22
     and rc_private.docgen_masalah_master(c.customer_id) is null
     and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('transfer', 'cn')
   order by c.no_doc limit 1;

  begin
    if d1.id is null or d2.id is null or k1.id is null then raise exception 'Fixture: klaim Done / Claimed Transfer-CN tidak cukup'; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    select status, batch_clearing into v_status0, v_batch0 from public.claims where id = d1.id;

    -- ---- Arsip Bukti TF ----------------------------------------------------------------------
    r := public.rc_clearing_bank_preview('MultiTransactionAutoTransferDownload_04112026160000.txt', v_sidik, 2026, 'nama_file', jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'BTF-T001', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(d1.cb_net)::text, 'remark1', substr(d1.no_doc, 5),
        'bank', 'BRI', 'toAcc', '0123456789', 'status', 'Berhasil', 'reason', 'HOST_TRAN SUCCESSFUL', 'channel', 'KBB', 'layanan', 'LLG', 'dariRek', '9990001112',
        'dariNama', 'NIPSEA PAINT AND CHEMICA', 'swift', 'BRINIDJA', 'namaBank', 'PT. BANK RAKYAT INDONESIA (PERSERO)', 'biaya', '2900', 'biayaOleh', 'OUR'),
      jsonb_build_object('baris', 2, 'transId', 'BTF-T002', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', (trunc(d2.cb_net) + 1)::text, 'remark1', substr(d2.no_doc, 5),
        'bank', 'BCA', 'toAcc', '111', 'status', 'Berhasil', 'reason', '', 'layanan', 'BCA', 'biaya', '0', 'biayaOleh', 'OUR'),
      jsonb_build_object('baris', 3, 'transId', 'BTF-T003', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(k1.cb_net)::text, 'remark1', substr(k1.no_doc, 5),
        'bank', 'BCA', 'toAcc', '222', 'status', 'Berhasil', 'reason', '', 'layanan', 'BCA', 'biaya', '0', 'biayaOleh', 'OUR')), 'arsip');
    v_up := (r->'upload'->>'id')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Mode Arsip: Done + nominal sama = OK; nominal beda ditolak; belum Done ditolak (pakai mode Clearing)',
      'lulus', r->'upload'->>'mode' = 'arsip'
           and (select string_agg(x->>'hasil', ',' order by (x->>'baris')::int) from jsonb_array_elements(r->'rows') x) = 'ok,nominal_beda,belum_siap'
           and (select x->>'keterangan' from jsonb_array_elements(r->'rows') x where x->>'baris' = '3') ~ 'gunakan mode Clearing',
      'rinci', (select string_agg((x->>'baris') || '=' || (x->>'hasil') || ' ' || (x->>'keterangan'), ' | ' order by (x->>'baris')::int) from jsonb_array_elements(r->'rows') x));
    r := public.rc_clearing_bank_proses(v_up);
    hasil := hasil || jsonb_build_object('uji', 'Proses Arsip: Bukti TF tersimpan, klaim tidak diubah (status, batch), log bukti_tf_arsip',
      'lulus', (r->>'diproses')::int = 1 and r->>'message' ~ 'Bukti TF tersimpan'
           and (select status = v_status0 and batch_clearing is not distinct from v_batch0 from public.claims where id = d1.id)
           and (select status from public.claims where id = k1.id) = 'claimed'
           and exists (select 1 from public.activity_logs where event_type = 'bukti_tf_arsip' and details->>'upload' = v_up::text),
      'rinci', r->>'message');

    b := rc_private.bukti_tf(d1.id);
    hasil := hasil || jsonb_build_object('uji', 'Isi Bukti TF: layanan LLG, pengirim nama lengkap, bank tujuan, nominal, biaya ditanggung pengirim, berita No Doc',
      'lulus', b->>'layanan' = 'Transfer Antarbank (LLG) - KlikBCA Bisnis' and b->>'dariNama' = 'PT NIPSEA PAINT AND CHEMICALS' and b->>'dariRek' = '9990001112'
           and b->>'keRek' = '0123456789' and b->>'bankTujuan' = 'PT. BANK RAKYAT INDONESIA (PERSERO)' and (b->>'nominal')::numeric = trunc(d1.cb_net)
           and (b->>'biaya')::numeric = 2900 and b->>'biayaOleh' = 'ditanggung pengirim' and b->>'berita' = substr(d1.no_doc, 5)
           and b->>'status' = 'BERHASIL' and b->>'tglEfektif' = to_char(v_tgl, 'DD-Mon-YYYY') and b->>'noDoc' = d1.no_doc,
      'rinci', b::text);
    hasil := hasil || jsonb_build_object('uji', 'Nama Penerima dicocokkan lewat No Doc (rekening dokumen, lalu Customer Master)',
      'lulus', b->>'namaPenerima' = coalesce((select nullif(btrim(account_name), '') from rc_private.claim_sensitive where claim_id = d1.id),
                                             (select nullif(btrim(cu.account_name), '') from public.customers cu where cu.id = d1.customer_id), ''),
      'rinci', coalesce(b->>'namaPenerima', '-'));

    -- Tidak tersimpan dua kali.
    begin perform public.rc_clearing_bank_preview('nama-lain.txt', v_sidik, 2026, 'form', jsonb_build_array(jsonb_build_object('baris', 1, 'remark1', 'X', 'status', 'Berhasil')), 'arsip');
      v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'File yang sama di mode Arsip ditolak', 'lulus', v_galat ~ 'sudah diproses \(mode Arsip Bukti TF\)', 'rinci', v_galat);
    r2 := public.rc_clearing_bank_preview('arsip-lain.txt', v_sidik2, 2026, 'form', jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'BTF-LAIN', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(d1.cb_net)::text, 'remark1', substr(d1.no_doc, 5),
        'bank', 'BCA', 'toAcc', '1', 'status', 'Berhasil', 'reason', '')), 'arsip');
    hasil := hasil || jsonb_build_object('uji', 'Dokumen yang sudah punya Bukti TF: file arsip lain ditolak (sudah diproses)',
      'lulus', r2->'rows'->0->>'hasil' = 'sudah_diproses' and r2->'rows'->0->>'keterangan' ~ 'Bukti TF dokumen ini sudah tersimpan', 'rinci', r2->'rows'->0->>'keterangan');
    r2 := public.rc_clearing_bank_preview('MultiTransactionAutoTransferDownload_04112026160000.txt', v_sidik, 2026, 'nama_file', jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'BTF-T001', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(d1.cb_net)::text, 'remark1', substr(d1.no_doc, 5),
        'bank', 'BRI', 'toAcc', '0123456789', 'status', 'Berhasil', 'reason', '')), 'clearing');
    hasil := hasil || jsonb_build_object('uji', 'File yang sama boleh dipratinjau di mode lain (Clearing); Trans ID tersimpan = sudah diproses',
      'lulus', r2->>'status' = 'success' and r2->'rows'->0->>'hasil' = 'sudah_diproses', 'rinci', r2->'rows'->0->>'keterangan');

    -- ---- Clearing file bank juga menyimpan Bukti TF -------------------------------------------
    r2 := public.rc_clearing_bank_preview('MultiTransactionAutoTransferDownload_05112026090000.txt', v_sidik3, 2026, 'nama_file', jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'BTF-K001', 'effDate', '04 Nov 202', 'tglTransfer', v_tgl, 'nominal', trunc(k1.cb_net)::text, 'remark1', substr(k1.no_doc, 5),
        'bank', 'BCA', 'toAcc', '0123456700', 'status', 'Berhasil', 'reason', 'HOST_TRAN SUCCESSFUL', 'layanan', 'BCA', 'dariRek', '9990001112',
        'dariNama', 'NIPSEA PAINT AND CHEMICA', 'biaya', '0', 'biayaOleh', 'OUR')));
    r2 := public.rc_clearing_bank_proses((r2->'upload'->>'id')::uuid);
    b := rc_private.bukti_tf(k1.id);
    hasil := hasil || jsonb_build_object('uji', 'Clearing dari file bank: dokumen Done dan Bukti TF-nya tersedia (sesama BCA)',
      'lulus', (select status from public.claims where id = k1.id) = 'done' and b->>'layanan' = 'Transfer sesama BCA - KlikBCA Bisnis'
           and b->>'bankTujuan' = 'PT. BANK CENTRAL ASIA TBK' and (b->>'biaya')::numeric = 0,
      'rinci', coalesce(r2->>'message', '-') || ' | ' || coalesce(b::text, '-'));
    hasil := hasil || jsonb_build_object('uji', 'Hasil Clearing file bank membawa nama campaign dan Gross Up (Laporan Workflow)',
      'lulus', r2->'rows'->0->>'namaCampaign' = (select ca.campaign_name from public.claims c join public.campaigns ca on ca.id = c.campaign_id where c.id = k1.id)
           and (r2->'rows'->0->>'grossUp')::numeric = (select trunc(coalesce(gross_up, 0)) from public.claims where id = k1.id),
      'rinci', coalesce((r2->'rows'->0)::text, '-'));

    -- ---- Document Generator -------------------------------------------------------------------
    -- d1 dibuat bertanggal Oktober supaya masuk PDA (Transfer / CN mulai 01-Oct-2026).
    update public.claims set cleared_at = (date '2026-10-20' + time '10:00') at time zone 'Asia/Jakarta' where id = d1.id;
    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', d1.depot_id, 'customerId', d1.customer_id)), 'done');
    hasil := hasil || jsonb_build_object('uji', 'Tanda Terima: form PDA membawa Bukti TF dokumen itu; form PDH tanpa Bukti TF',
      'lulus', exists (select 1 from jsonb_array_elements(r->'forms') f, jsonb_array_elements(f->'bukti') x where f->>'kategori' = 'PDA' and x->>'noDoc' = d1.no_doc)
           and not exists (select 1 from jsonb_array_elements(r->'forms') f where f->>'kategori' = 'PDH' and jsonb_array_length(f->'bukti') > 0),
      'rinci', (select string_agg((f->>'kategori') || ': ' || jsonb_array_length(f->'bukti') || ' bukti', ', ') from jsonb_array_elements(r->'forms') f));
    r := public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', k1.depot_id, 'customerId', k1.customer_id)), 'done');
    hasil := hasil || jsonb_build_object('uji', 'Tanda Terima toko yang di-Clearing lewat file bank: Bukti TF ikut di form PDA',
      'lulus', exists (select 1 from jsonb_array_elements(r->'forms') f, jsonb_array_elements(f->'bukti') x where f->>'kategori' = 'PDA' and x->>'noDoc' = k1.no_doc),
      'rinci', (select string_agg((f->>'kategori') || ': ' || jsonb_array_length(f->'bukti') || ' bukti', ', ') from jsonb_array_elements(r->'forms') f));
    r := public.rc_docgen_list('done', jsonb_build_object('cari', (select customer_code from public.customers where id = d1.customer_id)), 0, 500);
    hasil := hasil || jsonb_build_object('uji', 'Daftar Done: jumlah dokumen ber-Bukti TF per toko',
      'lulus', (select (x->>'buktiTf')::int >= 1 from jsonb_array_elements(r->'rows') x where (x->>'customerId')::uuid = d1.customer_id limit 1),
      'rinci', (select x->>'buktiTf' from jsonb_array_elements(r->'rows') x where (x->>'customerId')::uuid = d1.customer_id limit 1));

    -- ---- 20261163740000: Remark PP dan saringan Remark ------------------------------------------
    v_kode := (select customer_code from public.customers where id = d1.customer_id);
    n := (select (x->>'buktiTf')::int from jsonb_array_elements(r->'rows') x where (x->>'customerId')::uuid = d1.customer_id limit 1);
    hasil := hasil || jsonb_build_object('uji', 'Remark toko ber-Bukti TF memuat PP',
      'lulus', (select x->>'remark' ~ '(^| \+ )PP$' and x->>'remark' ~ '^PDA' from jsonb_array_elements(r->'rows') x where (x->>'customerId')::uuid = d1.customer_id limit 1),
      'rinci', (select x->>'remark' from jsonb_array_elements(r->'rows') x where (x->>'customerId')::uuid = d1.customer_id limit 1));
    hasil := hasil || jsonb_build_object('uji', 'Daftar dan form tidak lagi memuat Bank / No. Rekening / Atas Nama',
      'lulus', not exists (select 1 from jsonb_array_elements(r->'rows') x where x ? 'bank' or x ? 'noRek' or x ? 'atasNama')
           and not exists (select 1 from jsonb_array_elements(public.rc_docgen_generate(jsonb_build_array(jsonb_build_object('depotId', d1.depot_id, 'customerId', d1.customer_id)), 'done')->'forms') f
                            where f ? 'rekening'),
      'rinci', '-');
    r := public.rc_docgen_list('done', jsonb_build_object('cari', v_kode, 'remark', 'pp'), 0, 500);
    r2 := public.rc_docgen_list('done', jsonb_build_object('cari', v_kode, 'remark', 'tanpa_pp'), 0, 500);
    hasil := hasil || jsonb_build_object('uji', 'Saringan Remark PP / Tanpa PP',
      'lulus', exists (select 1 from jsonb_array_elements(r->'rows') x where (x->>'customerId')::uuid = d1.customer_id)
           and not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'remark' !~ 'PP')
           and not exists (select 1 from jsonb_array_elements(r2->'rows') x where (x->>'customerId')::uuid = d1.customer_id or x->>'remark' ~ 'PP'),
      'rinci', (r->>'total') || ' / ' || (r2->>'total'));
    r := public.rc_docgen_list('done', jsonb_build_object('remark', 'pda'), 0, 500);
    r2 := public.rc_docgen_list('done', jsonb_build_object('remark', 'pdh'), 0, 500);
    hasil := hasil || jsonb_build_object('uji', 'Saringan Remark PDA saja / PDH saja / PDA + PDH',
      'lulus', not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'remark' !~ '^PDA( \+ PP)?$')
           and not exists (select 1 from jsonb_array_elements(r2->'rows') x where x->>'remark' <> 'PDH')
           and not exists (select 1 from jsonb_array_elements(public.rc_docgen_list('done', jsonb_build_object('remark', 'campur'), 0, 500)->'rows') x
                            where x->>'remark' !~ '^PDA \+ PDH'),
      'rinci', (r->>'total') || ' PDA / ' || (r2->>'total') || ' PDH');
    begin perform public.rc_docgen_list('done', jsonb_build_object('remark', 'xyz')); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Saringan Remark tidak dikenal ditolak', 'lulus', v_galat ~ 'Remark tidak dikenal', 'rinci', v_galat);
    -- Bukti TF dokumen PDH tidak dicetak, jadi tidak dihitung untuk PP.
    update public.claims set cleared_at = (date '2026-09-20' + time '10:00') at time zone 'Asia/Jakarta' where id = d1.id;
    r := public.rc_docgen_list('done', jsonb_build_object('cari', v_kode), 0, 500);
    hasil := hasil || jsonb_build_object('uji', 'Bukti TF dokumen PDH (sebelum Oktober) tidak dihitung untuk PP',
      'lulus', (select (x->>'buktiTf')::int from jsonb_array_elements(r->'rows') x where (x->>'customerId')::uuid = d1.customer_id limit 1) = n - 1,
      'rinci', n || ' -> ' || coalesce((select x->>'buktiTf' from jsonb_array_elements(r->'rows') x where (x->>'customerId')::uuid = d1.customer_id limit 1), '-'));

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_btf(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_btf order by urut;
