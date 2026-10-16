-- ==========================================================================================
-- KTP dan NPWP terisi keduanya: dokumen diterima sebagai Badan (KTP tidak dipakai)
-- ==========================================================================================
-- Pemilik, 14 Oktober 2026: "untuk subjek pajak ketika ada NPWP akan dianggap badan dan no ktp
-- ... hanya tampil di master tapi tidak dipakai, tetapi kalo hanya ktp maka perorangan."
--
-- SEBELUMNYA submit menolak dokumen bila customer punya KTP dan NPWP sekaligus ("punya KTP dan
-- NPWP sekaligus; perbaiki di Customer Master"), walaupun Customer Master sendiri sudah
-- mencatatnya sebagai Badan (kolom turunan customers.tax_subject mendahulukan NPWP).
--
-- SEKARANG NPWP terisi -> Badan, dan KTP tidak dibawa ke dokumen (claim_sensitive.ktp kosong);
-- KTP tetap tersimpan dan tampil di Customer Master. Hanya KTP -> Perorangan. Tanpa keduanya
-- tetap ditolak seperti sebelumnya ("KTP atau NPWP ... belum terisi").
-- Prod 14 Oktober 2026: tidak ada customer aktif dengan KTP dan NPWP sekaligus.
--
-- Ditambal dengan penjaga MD5 pra-citra (dev, sesudah 20261163100000).
-- ==========================================================================================

do $tambal$
declare src text; baru text; n int;
  lama text := $p$  if v_ktp is not null and v_npwp is not null then
   raise exception 'Dokumen %: pelanggan % punya KTP dan NPWP sekaligus; perbaiki di Customer Master',c.no_doc,cust.customer_code;
  end if;$p$;
  ganti text := $p$  -- 20261163110000: NPWP terisi -> Badan; KTP (bila ada) hanya tampil di Customer Master dan
  -- tidak dipakai dokumen. Dulu dokumen ditolak "punya KTP dan NPWP sekaligus".
  if v_npwp is not null then v_ktp := null; end if;$p$;
begin
  src := pg_get_functiondef('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)'::regprocedure);
  if src ~ '20261163110000' then raise notice 'mutate_claims_unchecked sudah ditambal.'; return; end if;
  if md5(replace(src, E'\r', '')) <> 'abdfc89d9678ef6b8f8b199900af7bb3' then
    raise exception 'DITOLAK: mutate_claims_unchecked berbeda dari yang diukur (md5 %); pasang 20261163100000 lebih dulu.', md5(replace(src, E'\r', '')); end if;
  baru := replace(src, E'\r', '');
  n := (length(baru) - length(replace(baru, lama, ''))) / length(lama);
  if n <> 1 then raise exception 'mutate_claims_unchecked: pola ditemukan % kali, diharapkan 1.', n; end if;
  execute replace(baru, lama, ganti);
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (dibatalkan): customer ber-KTP dan ber-NPWP -> submit diterima sebagai Badan, KTP
-- tidak terbawa ke dokumen; tanpa keduanya -> tetap ditolak.
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; d record; c public.claims%rowtype; s rc_private.claim_sensitive%rowtype; e text := ''; v_galat text; harap numeric;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select c2.id, c2.no_doc, c2.version_no, c2.cb_net, c2.customer_id, ca.tax_status,
         coalesce(nullif(c2.cashback_type_override, ''), ca.cashback_type) jenis into d
    from public.claims c2
    join public.customers cu on cu.id = c2.customer_id
    join public.campaigns ca on ca.id = c2.campaign_id and ca.status = 'active'
   where c2.status = 'not_yet' and c2.archived_at is null and c2.pending_approval is null and c2.cb_net > 0
     and rc_private.jenis_efektif(coalesce(nullif(c2.cashback_type_override, ''), ca.cashback_type)) = 'cn'
   order by c2.no_doc limit 1;
  if v_sm is null or d.no_doc is null then raise notice 'Tidak ada fixture; uji dilewati.'; return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  begin
    update public.email_settings set aktif = false where jenis = 'pengajuan';
    update public.customers set ktp = '3201010101010001', npwp = '012345678901234' where id = d.customer_id;
    perform public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', d.version_no)), gen_random_uuid(), '');
    select * into c from public.claims where id = d.id;
    select * into s from rc_private.claim_sensitive where claim_id = d.id;
    harap := rc_private.gross_up_klaim(d.cb_net, 'Badan', d.tax_status, d.jenis);
    if c.status not in ('submitted', 'approved') or c.tax_subject <> 'Badan' or s.ktp is not null
       or s.npwp <> '012345678901234' or c.gross_up is distinct from harap then
      e := e || format(' KTP+NPWP: status %s, subyek %s, ktp dokumen %s, npwp %s, gross up %s (harap %s);',
        c.status, c.tax_subject, s.ktp, s.npwp, c.gross_up, harap); end if;
    if (select ktp from public.customers where id = d.customer_id) <> '3201010101010001' then
      e := e || ' KTP di Customer Master ikut terhapus;'; end if;
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' KTP+NPWP galat: ' || sqlerrm || ';'; end if;
  end;

  begin
    update public.email_settings set aktif = false where jenis = 'pengajuan';
    update public.customers set ktp = null, npwp = null where id = d.customer_id;
    update public.claims set tax_subject = null where id = d.id;
    begin
      perform public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', d.version_no)), gen_random_uuid(), '');
      e := e || ' tanpa KTP/NPWP diterima;';
    exception when others then v_galat := sqlerrm;
      if v_galat !~ 'KTP atau NPWP' then e := e || ' pesan tanpa KTP/NPWP: ' || v_galat || ';'; end if;
    end;
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' tanpa KTP/NPWP galat: ' || sqlerrm || ';'; end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
