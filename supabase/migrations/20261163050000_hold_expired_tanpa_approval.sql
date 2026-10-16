-- ==========================================================================================
-- On Hold / Expired langsung berlaku saat approval dimatikan
-- ==========================================================================================
-- Pemilik, 13 Oktober 2026: "dan untuk on hold / expired ini ga perlu approval kan ketika
-- approval line nya dimatikan?"
--
-- SEBELUMNYA 20261162180000 hanya membuat SUBMIT langsung saat approval dimatikan.
-- rc_posting_exception (tombol On Hold / Expired di modul Claim Upload) tetap selalu membuat
-- pengajuan (pending_approval) yang harus diputuskan di Management of Approval > On Hold &
-- Expired, walaupun approval sudah dimatikan. Prod 13 Oktober 2026: approval_aktif = false
-- sejak 09-Okt-2026.
--
-- SEKARANG bila rc_private.approval_aktif() = false:
--   - status langsung menjadi On Hold / Expired, dengan isi yang sama persis seperti
--     approve_hold: status sebelumnya disimpan (untuk Unhold), perpanjangan SO/Billing dipakai,
--     dan Expired mendapat batch Clearing (04) satu nomor untuk satu proses;
--   - riwayat mencatat request_hold / request_expired (alasannya dibaca Reprocessing Doc) lalu
--     approve_hold_otomatis "Approval dimatikan", sejajar dengan approve_otomatis pada submit;
--   - email On Hold / Expired berangkat saat itu juga lewat email_pengajuan_antre, seperti
--     submit langsung (tunduk pada sakelar Email Pengajuan dan mode ujinya);
--   - jawaban server membawa langsung = true dan pesannya mengatakan statusnya sudah berubah.
-- Saat approval hidup, perilakunya tidak berubah sama sekali.
--
-- Ditambal dengan penjaga MD5 pra-citra (13 Oktober 2026; dev dan prod sama).
-- ==========================================================================================

do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  ('public.rc_posting_exception(text,jsonb,text)', 'a238f57b792738f695d18050aad755ae',
   $p$  actor uuid := (select auth.uid());$p$,
   $p$  actor uuid := (select auth.uid());
  -- 20261163050000: approval dimatikan -> On Hold / Expired langsung berlaku.
  v_langsung boolean := not rc_private.approval_aktif();
  v_ids uuid[] := '{}'; v_batch_exp text;$p$, 1),
  ('public.rc_posting_exception(text,jsonb,text)', 'a238f57b792738f695d18050aad755ae',
   $p$      batch := null; -- batch Clearing hanya diterbitkan saat approval$p$,
   $p$      -- Batch Clearing diterbitkan saat approval; tanpa approval, saat itu juga - satu
      -- nomor untuk seluruh proses, sama dengan approve_hold.
      if v_langsung then
        if v_batch_exp is null then v_batch_exp := rc_private.next_batch('04'); end if;
        batch := v_batch_exp;
      else
        batch := null;
      end if;$p$, 1),
  ('public.rc_posting_exception(text,jsonb,text)', 'a238f57b792738f695d18050aad755ae',
   $p$    update public.claims set
      pending_approval = jsonb_build_object('kind',case when v_action='hold' then 'hold' else 'expire' end,$p$,
   $p$    if v_langsung then
      -- Isinya sama dengan approve_hold di mutate_claims_unchecked.
      update public.claims set
        status = v_target,
        pending_approval = null,
        previous_status = case when v_target = 'on_hold' then c.status else previous_status end,
        extend_so_start = case when v_target = 'on_hold' then coalesce(so_a, extend_so_start) else extend_so_start end,
        extend_so_end = case when v_target = 'on_hold' then coalesce(so_b, extend_so_end) else extend_so_end end,
        extend_billing_start = case when v_target = 'on_hold' then coalesce(bi_a, extend_billing_start) else extend_billing_start end,
        extend_billing_end = case when v_target = 'on_hold' then coalesce(bi_b, extend_billing_end) else extend_billing_end end,
        hold_approved_at = now(),
        batch_clearing = case when v_target = 'expired' then batch else batch_clearing end,
        version_no = version_no + 1,
        updated_at = now()
      where id = c.id;

      insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
      values(c.id,actor,c.status,c.status,'request_'||v_action,null,left(btrim(coalesce(p_reason,'')),300)),
            (c.id,actor,c.status,v_target,'approve_hold_otomatis',batch,'Approval dimatikan');

      insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
      values(actor,c.depot_id,'posting_exception',c.id,jsonb_build_object(
        'noDoc',c.no_doc,'tindakan',v_action,'dari',c.status,'menjadi',v_target,'requestedStatus',v_target,
        'langsung',true,'batch',batch,
        'soStart',so_a,'soEnd',so_b,'billingStart',bi_a,'billingEnd',bi_b));

      processed := processed || jsonb_build_array(jsonb_build_object('noDoc',c.no_doc,
        'status',rc_private.legacy_status(v_target),'versionNo',c.version_no+1,'pendingApproval',false));
      v_ids := v_ids || c.id;
      n_ok := n_ok + 1;
      continue;
    end if;

    update public.claims set
      pending_approval = jsonb_build_object('kind',case when v_action='hold' then 'hold' else 'expire' end,$p$, 1),
  ('public.rc_posting_exception(text,jsonb,text)', 'a238f57b792738f695d18050aad755ae',
   $p$  return jsonb_build_object('status','success','berhasil',n_ok,$p$,
   $p$  -- Status sudah berubah saat itu juga, jadi email On Hold / Expired berangkat sekarang.
  -- Kegagalan email tidak membatalkan perubahan status; jejaknya dicatat.
  if v_langsung and coalesce(array_length(v_ids,1),0) > 0 then
    begin
      perform rc_private.email_pengajuan_antre(case when v_action = 'hold' then 'hold' else 'expire' end,
        v_batch_exp, v_ids, actor, left(btrim(coalesce(p_reason,'')),300));
    exception when others then
      insert into public.activity_logs(actor_id,event_type,details)
      values(actor,'email_pengajuan_gagal',jsonb_build_object(
        'aksi',v_action,'batch',v_batch_exp,'sebab',left(sqlerrm,300)));
    end;
  end if;

  return jsonb_build_object('status','success','berhasil',n_ok,'langsung',v_langsung,$p$, 1),
  ('public.rc_posting_exception(text,jsonb,text)', 'a238f57b792738f695d18050aad755ae',
   $p$    'message',n_ok||' dokumen '||case when v_action='expired' then 'diajukan untuk Expired; menunggu approval' else 'diajukan untuk On Hold; menunggu approval' end$p$,
   $p$    'message',n_ok||' dokumen '||case
        when v_langsung and v_action='expired' then 'langsung Expired (approval dimatikan)'
        when v_langsung then 'langsung On Hold (approval dimatikan)'
        when v_action='expired' then 'diajukan untuk Expired; menunggu approval'
        else 'diajukan untuk On Hold; menunggu approval' end$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261163050000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(src, E'\r', '')); end if;
    baru := replace(src, E'\r', '');
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
-- Pemeriksaan (dibatalkan seluruhnya; email pengajuan dimatikan di dalam uji sehingga tidak
-- ada surat yang diantrekan): approval mati -> langsung; approval hidup -> tetap pengajuan.
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; d1 record; d2 record; d3 record; res jsonb; c public.claims%rowtype; e text := '';
  v_hist text; v_alasan text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- Tiga dokumen Not Yet tanpa pengajuan, campaign berperiode (On Hold butuh perpanjangan).
  select cl.no_doc, cl.version_no, ca.period_start, ca.period_end into d1
    from public.claims cl join public.campaigns ca on ca.id = cl.campaign_id
   where cl.status = 'not_yet' and cl.pending_approval is null and cl.archived_at is null
     and ca.period_start is not null and ca.period_end is not null
   order by cl.no_doc limit 1;
  select cl.no_doc, cl.version_no into d2 from public.claims cl
   where cl.status in ('not_yet','released','claimed') and cl.pending_approval is null and cl.archived_at is null and cl.no_doc <> d1.no_doc
   order by cl.no_doc limit 1;
  select cl.no_doc, cl.version_no into d3 from public.claims cl
   where cl.status = 'not_yet' and cl.pending_approval is null and cl.archived_at is null and cl.no_doc not in (d1.no_doc, d2.no_doc)
   order by cl.no_doc desc limit 1;
  if v_sm is null or d1.no_doc is null or d2.no_doc is null or d3.no_doc is null then
    raise notice 'Fixture tidak lengkap; uji dilewati.'; return; end if;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    update public.email_settings set aktif = false where jenis = 'pengajuan';
    insert into public.pengaturan_sistem(kunci, nilai) values ('approval_aktif', 'false'::jsonb)
    on conflict (kunci) do update set nilai = 'false'::jsonb;

    -- Approval mati: On Hold langsung.
    res := public.rc_posting_exception('hold', jsonb_build_array(jsonb_build_object('noDoc', d1.no_doc, 'versionNo', d1.version_no,
      'soStart', d1.period_start, 'soEnd', d1.period_end + 30, 'billingStart', d1.period_start, 'billingEnd', d1.period_end + 30)), 'uji hold langsung');
    select * into c from public.claims where no_doc = d1.no_doc;
    if (res->>'berhasil')::int <> 1 or (res->>'langsung')::boolean is not true or c.status <> 'on_hold' or c.pending_approval is not null
       or c.previous_status <> 'not_yet' or c.extend_so_end <> d1.period_end + 30 or c.hold_approved_at is null then
      e := e || format(' hold langsung: %s / status %s prev %s pending %s;', res, c.status, c.previous_status, c.pending_approval); end if;
    if res->>'message' !~ 'langsung On Hold' then e := e || ' pesan hold;'; end if;
    select string_agg(action, ',' order by id) into v_hist from public.claim_status_history where claim_id = c.id and created_at >= now();
    if v_hist is distinct from 'request_hold,approve_hold_otomatis' then e := e || format(' riwayat hold %s;', v_hist); end if;
    select h.reason into v_alasan from public.claim_status_history h where h.claim_id = c.id and h.action in ('hold','request_hold') order by h.id desc limit 1;
    if v_alasan is distinct from 'uji hold langsung' then e := e || ' alasan Reprocessing hilang;'; end if;

    -- Approval mati: Expired langsung, dengan batch Clearing.
    res := public.rc_posting_exception('expired', jsonb_build_array(jsonb_build_object('noDoc', d2.no_doc, 'versionNo', d2.version_no)), '');
    select * into c from public.claims where no_doc = d2.no_doc;
    if (res->>'berhasil')::int <> 1 or c.status <> 'expired' or c.pending_approval is not null or coalesce(c.batch_clearing,'') = '' then
      e := e || format(' expired langsung: %s / status %s batch %s;', res, c.status, c.batch_clearing); end if;
    if res->>'message' !~ 'langsung Expired' then e := e || ' pesan expired;'; end if;

    -- Approval hidup: tetap pengajuan, status tidak berubah.
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'approval_aktif';
    res := public.rc_posting_exception('expired', jsonb_build_array(jsonb_build_object('noDoc', d3.no_doc, 'versionNo', d3.version_no)), '');
    select * into c from public.claims where no_doc = d3.no_doc;
    if (res->>'berhasil')::int <> 1 or (res->>'langsung')::boolean or c.status <> 'not_yet' or c.pending_approval->>'kind' <> 'expire'
       or res->>'message' !~ 'menunggu approval' then
      e := e || format(' approval hidup: %s / status %s pending %s;', res, c.status, c.pending_approval); end if;
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then e := e || ' galat: ' || sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
