-- ==========================================================================================
-- Reprocessing Doc menghitung ulang Gross Up
-- ==========================================================================================
-- Pemilik, 12 Oktober 2026: "hitung gross up buat dan testing".
--
-- SEBELUMNYA. rc_reprocessing_upload mengganti cb_net dokumen On Hold lalu mengembalikannya ke
-- Not Yet, tetapi gross_up dibiarkan milik nominal LAMA. Gross up baru dihitung ulang ketika
-- dokumen itu di-submit lagi (mutate_claims_unchecked). Di antara keduanya Document Center,
-- Analytics, Report dan unduhan menampilkan Gross Up yang tidak sesuai Cashback-nya.
--
-- SEKARANG. Gross up dihitung saat itu juga dengan rumus yang sama dengan compile dan submit:
--   rc_private.gross_claimed(cashback baru, subyek pajak, status pajak campaign)
-- Subyek pajak diambil dari Customer Master (NPWP -> Badan, hanya KTP -> Perorangan); bila
-- master belum memuat keduanya, subyek yang tersimpan pada dokumen dipakai. tax_subject dokumen
-- ikut diselaraskan supaya Gross Up dan subyeknya tidak saling bertentangan.
--
-- Dokumen tanpa Customer Master kini DITOLAK dengan alasan yang jelas. Sebelumnya penjaga
-- jaga_customer_master_klaim melempar galat di tengah perulangan dan seluruh unggahan batal,
-- termasuk baris lain yang sah.
--
-- Nilai lama dan baru Gross Up dicatat di activity_logs bersama Cashback-nya.
-- Ditambal dengan penjaga MD5 pra-citra (sama di dev dan prod, 12 Oktober 2026).
-- ==========================================================================================

do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  ('public.rc_reprocessing_upload(jsonb,text)', '265dca894cbd6d8d63b8afc8ed1df045',
   $p$  r jsonb; v_doc text; c public.claims%rowtype; v_baru numeric;$p$,
   $p$  r jsonb; v_doc text; c public.claims%rowtype; v_baru numeric;
  v_subjek text; v_pajak text; v_gross numeric; -- 20261162240000$p$, 1),

  ('public.rc_reprocessing_upload(jsonb,text)', '265dca894cbd6d8d63b8afc8ed1df045',
   $p$    v_baru := trunc(v_baru);
$p$,
   $p$    v_baru := trunc(v_baru);

    -- 20261162240000: gross up dihitung ulang dari cashback hasil revisi.
    if c.customer_id is null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
        'sebab','Customer Master belum tersedia; lengkapi dulu di Key Master'));
      continue;
    end if;
    select coalesce(cu.tax_subject, c.tax_subject), ca.tax_status into v_subjek, v_pajak
      from public.customers cu, public.campaigns ca
     where cu.id = c.customer_id and ca.id = c.campaign_id;
    v_gross := case when v_subjek is not null then rc_private.gross_claimed(v_baru, v_subjek, v_pajak) end;
$p$, 1),

  ('public.rc_reprocessing_upload(jsonb,text)', '265dca894cbd6d8d63b8afc8ed1df045',
   $p$      cb_net = v_baru,$p$,
   $p$      cb_net = v_baru,
      gross_up = v_gross,
      tax_subject = v_subjek,$p$, 1),

  ('public.rc_reprocessing_upload(jsonb,text)', '265dca894cbd6d8d63b8afc8ed1df045',
   $p$'cbNetLama',c.cb_net,'cbNetBaru',v_baru));$p$,
   $p$'cbNetLama',c.cb_net,'cbNetBaru',v_baru,
      'grossUpLama',c.gross_up,'grossUpBaru',v_gross));$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261162240000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(src, E'\r', '')); end if;
    baru := src;
    for r in select * from _tambal where sig = f.sig order by urut loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> r.n then
        raise exception '%: pola "%" ditemukan % kali, diharapkan %.', f.sig, left(r.lama, 80), n, r.n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
    execute baru;
  end loop;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan, dibatalkan seluruhnya. Dua dokumen Not Yet - satu Badan, satu Perorangan bila
-- ada - ditahan sementara lalu direvisi lewat Reprocessing dengan nominal berdesimal.
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; d record; hasil jsonb; e text := ''; diuji int := 0; v_log jsonb;
begin
  select id into v_sm from public.profiles where role='system manager' and status='active' and not must_change_password order by user_code limit 1;
  if v_sm is null then raise notice 'Tidak ada System Manager aktif; uji dilewati.'; return; end if;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    for d in
      select distinct on (cu.tax_subject) c.id, c.no_doc, c.cb_net, c.gross_up, cu.tax_subject, ca.tax_status
        from public.claims c
        join public.customers cu on cu.id = c.customer_id and cu.tax_subject is not null
        join public.campaigns ca on ca.id = c.campaign_id and ca.status = 'active'
       where c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null and c.cb_net > 0
         and lower(coalesce(ca.tax_status,'')) not like '%nipsea%' and lower(coalesce(ca.tax_status,'')) not like '%non tax%'
       order by cu.tax_subject, c.cb_net desc
    loop
      update public.claims set status = 'on_hold', previous_status = 'not_yet' where id = d.id;
      -- Nominal baru sengaja berbeda jauh dan berdesimal: 3 x lama + 0,75.
      hasil := public.rc_reprocessing_upload(jsonb_build_array(jsonb_build_object('noDoc', d.no_doc,
                 'totalCashback', (d.cb_net * 3 + 0.75)::text)), 'uji gross up');
      if (hasil->>'berhasil')::int <> 1 then e := e || format(' %s tidak diproses: %s;', d.no_doc, hasil); continue; end if;
      if (select cb_net from public.claims where id = d.id) <> trunc(d.cb_net * 3 + 0.75) then
        e := e || format(' %s cashback tidak dipotong;', d.no_doc); end if;
      if (select gross_up from public.claims where id = d.id)
         is distinct from rc_private.gross_claimed(trunc(d.cb_net * 3 + 0.75), d.tax_subject, d.tax_status) then
        e := e || format(' %s (%s) gross up %s, harap %s;', d.no_doc, d.tax_subject,
                         (select gross_up from public.claims where id = d.id),
                         rc_private.gross_claimed(trunc(d.cb_net * 3 + 0.75), d.tax_subject, d.tax_status)); end if;
      if (select gross_up from public.claims where id = d.id) = d.gross_up then
        e := e || format(' %s gross up tidak berubah;', d.no_doc); end if;
      select details into v_log from public.activity_logs where event_type = 'reprocessing_upload' and entity_id = d.id order by id desc limit 1;
      if not (v_log ? 'grossUpLama' and v_log ? 'grossUpBaru') then e := e || format(' %s log tanpa gross up;', d.no_doc); end if;
      diuji := diuji + 1;
    end loop;
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then e := e || ' galat: ' || sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
  if diuji = 0 then raise exception 'GAGAL: tidak ada dokumen yang dapat diuji.'; end if;
  raise notice 'Reprocessing menghitung ulang gross up: % dokumen teruji (dibatalkan).', diuji;
end
$uji$;
