-- ==========================================================================================
-- Document Center: angka di belakang desimal dibuang
-- ==========================================================================================
-- Diminta pemilik, 12 Oktober 2026: "saya mau normalizing menghapus decimal, jadi ketika di
-- document center ada decimal maka angka di belakang decimal hapus."
--
-- Dua jalan masuk angka di modul Document Center:
--   Compile Cashback   Net Value, Volume, Cashback After Tax  (rc_private.compile_upload)
--   Reprocessing Doc   Total Cashback hasil revisi           (public.rc_reprocessing_upload)
--
-- Angkanya DIPOTONG (trunc), bukan dibulatkan: 4.384.118,58 menjadi 4.384.118, sama dengan cara
-- layar menampilkan nominal selama ini (Math.trunc). Pemotongan dilakukan SESUDAH pemeriksaan
-- negatif, supaya -0,5 tetap ditolak sebagai negatif alih-alih lolos sebagai 0. Gross up compile
-- dihitung dari Cashback yang sudah dipotong.
--
-- Ditambal dengan penjaga MD5 pra-citra (akhir baris dinormalkan), sama di dev dan prod pada
-- 12 Oktober 2026. Aman dijalankan berulang.
-- ==========================================================================================

do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  ('rc_private.compile_upload(jsonb,uuid)', '75b9483d98c85007a2faadbc4c5f6172',
   $p$  -- RA07 dan RA7 menandai cashback yang sudah direalisasi di luar sistem.$p$,
   $p$  -- 20261162210000: angka di belakang desimal dibuang (dipotong, bukan dibulatkan).
  v_net:=trunc(v_net); v_vol:=trunc(v_vol); v_cb:=trunc(v_cb);

  -- RA07 dan RA7 menandai cashback yang sudah direalisasi di luar sistem.$p$, 1),

  ('public.rc_reprocessing_upload(jsonb,text)', '06bd2adfb73511640cc8a4c06d516693',
   $p$    update public.claims set
      cb_net = v_baru,$p$,
   $p$    -- 20261162210000: angka di belakang desimal dibuang (dipotong, bukan dibulatkan).
    v_baru := trunc(v_baru);

    update public.claims set
      cb_net = v_baru,$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261162210000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
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
-- Pemeriksaan: compile dan reprocessing dengan angka berdesimal, dibatalkan seluruhnya.
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; v_dep record; v_camp record; v_cust record; v_hold record;
  hasil jsonb; v_cb numeric; v_net numeric; v_vol numeric; v_gross numeric; v_rep numeric; e text := '';
begin
  select id into v_sm from public.profiles where role='system manager' and status='active' and not must_change_password order by user_code limit 1;
  if v_sm is null then raise notice 'Tidak ada System Manager aktif; uji dilewati.'; return; end if;

  -- Pasangan campaign x customer yang belum punya klaim, di depot yang memetakan customer itu.
  select d.depot_code, d.abbr, ca.campaign_code, cu.customer_code, cu.tax_subject, ca.tax_status
    into v_dep
    from public.customers cu
    join public.customer_depots m on m.customer_id = cu.id
    join public.depots d on d.id = m.depot_id and d.archived_at is null and d.abbr is not null
    cross join lateral (select ca.* from public.campaigns ca
                         where ca.status = 'active' and ca.archived_at is null
                           and not exists(select 1 from public.claims c where c.campaign_id = ca.id and c.customer_id = cu.id)
                           and not rc_private.np_pasangan(d.id, ca.id)
                           and not exists(select 1 from public.timetable_not_achieved na where na.depot_id = d.id and na.campaign_id = ca.id)
                         limit 1) ca
   where cu.archived_at is null and cu.tax_subject is not null
   limit 1;

  select c.no_doc into v_hold from public.claims c where c.status = 'on_hold' and c.pending_approval is null limit 1;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

    if v_dep.depot_code is not null then
      hasil := rc_private.compile_upload(jsonb_build_array(jsonb_build_object(
        'kodeDepot', v_dep.depot_code, 'abbr', v_dep.abbr, 'codeCampaign', v_dep.campaign_code,
        'custCode', v_dep.customer_code, 'custName', '', 'netValue', '10000000.99',
        'volume', '250.75', 'cbNet', '4.384.118,58', 'jenisCb', '')), gen_random_uuid());
      select c.cb_net, c.net_value, c.volume, c.gross_up into v_cb, v_net, v_vol, v_gross
        from public.claims c where c.no_doc = hasil->'dokumen'->0->>'noDoc';
      if (hasil->>'dibuat')::int <> 1 then e := e || ' compile tidak membuat dokumen: ' || hasil::text || ';';
      elsif v_cb <> 4384118 or v_net <> 10000000 or v_vol <> 250 then
        e := e || format(' compile menyimpan %s / %s / %s;', v_cb, v_net, v_vol);
      elsif v_gross is distinct from rc_private.gross_claimed(4384118, v_dep.tax_subject, v_dep.tax_status) then
        e := e || ' gross up compile tidak dihitung dari cashback terpotong;';
      end if;
    else
      raise notice 'Tidak ada pasangan bebas untuk uji compile; dilewati.';
    end if;

    if v_hold.no_doc is not null then
      -- Negatif lebih dulu: dokumen yang berhasil direvisi tidak lagi On Hold.
      hasil := public.rc_reprocessing_upload(jsonb_build_array(jsonb_build_object('noDoc', v_hold.no_doc, 'totalCashback', '-0.5')), 'uji');
      if (hasil->>'berhasil')::int <> 0 then e := e || ' -0,5 lolos pada reprocessing;'; end if;
      hasil := public.rc_reprocessing_upload(jsonb_build_array(jsonb_build_object('noDoc', v_hold.no_doc, 'totalCashback', '1250000.99')), 'uji');
      select cb_net into v_rep from public.claims where no_doc = v_hold.no_doc;
      if (hasil->>'berhasil')::int <> 1 or v_rep <> 1250000 then e := e || format(' reprocessing menyimpan %s (%s);', v_rep, hasil::text); end if;
    else
      raise notice 'Tidak ada dokumen On Hold untuk uji reprocessing; dilewati.';
    end if;

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then e := e || ' galat: ' || sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
  raise notice 'Document Center tanpa desimal teruji (dibatalkan).';
end
$uji$;
