-- ==========================================================================================
-- Uji 14 November 2026: Clearing file bank dengan No Doc sebagian, mulai dari Abbr depot (20261163990000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_clearing_bank_sebagian.sql
-- ==========================================================================================
create temp table if not exists _hasil_cs(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_cs;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; r jsonb; k1 record; k2 record; k3 record; a record; z record; v_txt text; v_up uuid;
  v_tgl date := (now() at time zone 'Asia/Jakarta')::date - 1; v_sidik text := md5('s1' || clock_timestamp()::text) || md5('s2' || clock_timestamp()::text);
  v_sidik2 text := md5('s3' || clock_timestamp()::text) || md5('s4' || clock_timestamp()::text);
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and suffix_num ~ '^[0-9]{3}$' order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  begin
    update public.profiles set must_change_password = false where id = v_sm;
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'approval_aktif';

    -- Tiga dokumen Pending Finance (Claimed), bukan Rebate, bernomor lima ruas NPC/JENIS/ABBR/CAMPAIGN/URUT.
    for z in select c.id, c.no_doc, c.cb_net, row_number() over (order by c.no_doc) rn from public.claims c join public.campaigns ca on ca.id = c.campaign_id
              where c.status = 'claimed' and c.pending_approval is null and c.archived_at is null and not coalesce(c.jalur_adhoc, false)
                and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) <> 'rebate'
                and c.no_doc ~ '^NPC/[^/]+/[^/]+/[^/]+/[^/]+$' and trunc(c.cb_net) > 0
                and not exists(select 1 from public.rc_clearing_bank_baris b where b.claim_id = c.id and b.diproses)
              order by c.no_doc limit 3 loop
      if z.rn = 1 then k1 := z; elsif z.rn = 2 then k2 := z; else k3 := z; end if;
    end loop;
    if k3.id is null then raise exception 'Fixture: tiga dokumen Claimed bukan Rebate tidak ada'; end if;

    -- 1. Bagian akhir mulai dari Abbr depot (tiga ruas) menunjuk dokumennya.
    select * into a from rc_private.clearing_bank_nilai(array_to_string((string_to_array(k1.no_doc, '/'))[3:5], '/'), v_tgl, trunc(k1.cb_net), true, 'Berhasil', '', 'CS-1', false, null, 'otomatis');
    hasil := hasil || jsonb_build_object('uji', 'Abbr/campaign/urut (tanpa NPC dan jenis) dikenali sebagai dokumennya', 'lulus',
      a.hasil = 'ok' and a.claim_id = k1.id and a.no_doc_rc = k1.no_doc, 'rinci', array_to_string((string_to_array(k1.no_doc, '/'))[3:5], '/') || ' -> ' || a.hasil || ' ' || coalesce(a.no_doc_rc, '-'));
    select * into a from rc_private.clearing_bank_nilai(lower(array_to_string((string_to_array(k1.no_doc, '/'))[3:5], '/')), v_tgl, trunc(k1.cb_net), true, 'Berhasil', '', 'CS-1', false, null, 'otomatis');
    hasil := hasil || jsonb_build_object('uji', 'Huruf kecil tetap dikenali', 'lulus', a.hasil = 'ok' and a.claim_id = k1.id, 'rinci', a.hasil);

    -- 2. No Doc lengkap tetap berlaku, dengan atau tanpa NPC/.
    select * into a from rc_private.clearing_bank_nilai(k1.no_doc, v_tgl, trunc(k1.cb_net), true, 'Berhasil', '', 'CS-1', false, null, 'otomatis');
    v_txt := a.hasil;
    select * into a from rc_private.clearing_bank_nilai(substr(k1.no_doc, 5), v_tgl, trunc(k1.cb_net), true, 'Berhasil', '', 'CS-1', false, null, 'otomatis');
    hasil := hasil || jsonb_build_object('uji', 'No Doc lengkap (dengan dan tanpa NPC/) tetap dikenali', 'lulus', v_txt = 'ok' and a.hasil = 'ok' and a.claim_id = k1.id, 'rinci', v_txt || ' / ' || a.hasil);

    -- 3. Kurang dari tiga ruas, atau terpotong di tengah Abbr: tidak dipakai sebagai acuan.
    select * into a from rc_private.clearing_bank_nilai(array_to_string((string_to_array(k1.no_doc, '/'))[4:5], '/'), v_tgl, trunc(k1.cb_net), true, 'Berhasil', '', 'CS-1', false, null, 'otomatis');
    v_txt := a.hasil || ': ' || a.keterangan;
    select * into a from rc_private.clearing_bank_nilai(substr(array_to_string((string_to_array(k1.no_doc, '/'))[3:5], '/'), 2), v_tgl, trunc(k1.cb_net), true, 'Berhasil', '', 'CS-1', false, null, 'otomatis');
    hasil := hasil || jsonb_build_object('uji', 'Dua ruas saja, atau Abbr yang terpotong: tidak ditemukan (dengan petunjuk)', 'lulus',
      v_txt ~ '^tidak_ditemukan: .*minimal mulai dari Abbr depot' and a.hasil = 'tidak_ditemukan' and a.claim_id is null, 'rinci', v_txt || ' | ' || a.hasil);

    -- 4. Bagian akhir yang cocok dengan dua dokumen ditolak sebagai tidak spesifik.
    update public.claims set no_doc = 'NPC/UJI/' || array_to_string((string_to_array(k1.no_doc, '/'))[3:5], '/') where id = k3.id;
    select * into a from rc_private.clearing_bank_nilai(array_to_string((string_to_array(k1.no_doc, '/'))[3:5], '/'), v_tgl, trunc(k1.cb_net), true, 'Berhasil', '', 'CS-1', false, null, 'otomatis');
    hasil := hasil || jsonb_build_object('uji', 'Cocok dengan dua dokumen: ditolak, kandidat disebutkan', 'lulus',
      a.hasil = 'tidak_spesifik' and a.claim_id is null and a.keterangan ~ 'cocok dengan 2 dokumen' and position(k1.no_doc in a.keterangan) > 0, 'rinci', a.hasil || ': ' || a.keterangan);
    select * into a from rc_private.clearing_bank_nilai(substr(k1.no_doc, 5), v_tgl, trunc(k1.cb_net), true, 'Berhasil', '', 'CS-1', false, null, 'otomatis');
    hasil := hasil || jsonb_build_object('uji', 'No Doc lengkap tetap menang walau bagian akhirnya ganda', 'lulus', a.hasil = 'ok' and a.claim_id = k1.id, 'rinci', a.hasil);
    update public.claims set no_doc = k3.no_doc where id = k3.id;

    -- 5. Dokumen yang diarsipkan tidak pernah cocok.
    update public.claims set archived_at = now() where id = k3.id;
    select * into a from rc_private.clearing_bank_nilai(array_to_string((string_to_array(k3.no_doc, '/'))[3:5], '/'), v_tgl, trunc(k3.cb_net), true, 'Berhasil', '', 'CS-3', false, null, 'otomatis');
    hasil := hasil || jsonb_build_object('uji', 'Dokumen arsip tidak cocok', 'lulus', a.hasil = 'tidak_ditemukan', 'rinci', a.hasil);
    update public.claims set archived_at = null where id = k3.id;

    -- 6. Pratinjau: dua tulisan berbeda untuk dokumen yang sama = duplikat; dokumen lain tetap ok.
    r := public.rc_clearing_bank_preview('MultiTransactionAutoTransferDownload_' || to_char(v_tgl + 1, 'DDMMYYYY') || '120000.txt', v_sidik, extract(year from v_tgl)::int, 'nama_file', jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'CS-101', 'effDate', 'x', 'tglTransfer', v_tgl, 'nominal', trunc(k1.cb_net)::text, 'remark1', substr(k1.no_doc, 5), 'bank', 'BCA', 'toAcc', '111', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 2, 'transId', 'CS-102', 'effDate', 'x', 'tglTransfer', v_tgl, 'nominal', trunc(k1.cb_net)::text, 'remark1', array_to_string((string_to_array(k1.no_doc, '/'))[3:5], '/'), 'bank', 'BCA', 'toAcc', '111', 'status', 'Berhasil', 'reason', ''),
      jsonb_build_object('baris', 3, 'transId', 'CS-103', 'effDate', 'x', 'tglTransfer', v_tgl, 'nominal', trunc(k2.cb_net)::text, 'remark1', array_to_string((string_to_array(k2.no_doc, '/'))[3:5], '/'), 'bank', 'BCA', 'toAcc', '222', 'status', 'Berhasil', 'reason', '')), 'otomatis');
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau: dokumen yang sama ditulis dua cara = duplikat; yang lain ok dengan No Doc RC lengkap', 'lulus',
      (select string_agg(x->>'hasil', ',' order by (x->>'baris')::int) from jsonb_array_elements(r->'rows') x) = 'duplikat,duplikat,ok'
      and (select x->>'noDocRc' from jsonb_array_elements(r->'rows') x where x->>'baris' = '3') = k2.no_doc,
      'rinci', (select string_agg((x->>'baris') || '=' || (x->>'hasil'), ' ' order by (x->>'baris')::int) from jsonb_array_elements(r->'rows') x)
               || ' / ' || coalesce((select x->>'noDocRc' from jsonb_array_elements(r->'rows') x where x->>'baris' = '3'), 'tanpa noDocRc'));

    -- 7. Proses: dokumen yang ditulis sebagian menjadi Done; Bukti Transfer memuat No Doc lengkap.
    r := public.rc_clearing_bank_preview('MultiTransactionAutoTransferDownload_' || to_char(v_tgl + 1, 'DDMMYYYY') || '130000.txt', v_sidik2, extract(year from v_tgl)::int, 'nama_file', jsonb_build_array(
      jsonb_build_object('baris', 1, 'transId', 'CS-201', 'effDate', 'x', 'tglTransfer', v_tgl, 'nominal', trunc(k2.cb_net)::text, 'remark1', array_to_string((string_to_array(k2.no_doc, '/'))[3:5], '/'),
        'bank', 'BCA', 'toAcc', '222', 'status', 'Berhasil', 'reason', '', 'layanan', 'BCA', 'biaya', '0', 'biayaOleh', 'OUR')), 'otomatis');
    v_up := (r->'upload'->>'id')::uuid;
    r := public.rc_clearing_bank_proses(v_up);
    hasil := hasil || jsonb_build_object('uji', 'Proses: dokumen bertulisan sebagian menjadi Done dengan Tgl Transfer dari file', 'lulus',
      (select status = 'done' and cleared_actual_on = v_tgl from public.claims where id = k2.id), 'rinci', (select status || ' ' || coalesce(cleared_actual_on::text, '-') from public.claims where id = k2.id));
    hasil := hasil || jsonb_build_object('uji', 'Bukti Transfer: Berita = No Doc lengkap, bukan potongan dari bank', 'lulus',
      rc_private.bukti_tf(k2.id)->>'berita' = k2.no_doc, 'rinci', coalesce(rc_private.bukti_tf(k2.id)->>'berita', 'tanpa bukti'));
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_cs(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_cs order by urut;
