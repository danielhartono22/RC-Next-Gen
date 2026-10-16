-- ==========================================================================================
-- "Process by": pelaku setiap tahap - Submitted, Approved, Released, Claimed, Clearing
-- ==========================================================================================
-- Diminta pemilik, 9 Oktober 2026: "untuk kolom Process by saya mau semuanya ditampilkan dari
-- proses submitted approved release, claim dan clearing".
--
-- SEBELUMNYA
--   * Rincian dokumen (Analytics > History) hanya memuat SATU nama: pelaku terakhir apa pun
--     tindakannya (rc_legacy_dashboard -> processBy).
--   * Kartu pelaku di Release / Claim Process memuat empat tahap tanpa Clearing, dan pelakunya
--     dipilih menurut STATUS TUJUAN riwayat. Akibatnya penolakan ikut terhitung: Reject di
--     Claim Process mengembalikan dokumen ke Approved sehingga penolaknya tercatat sebagai
--     "Approved by"; Reject di Clearing mengembalikan ke Released sehingga penolaknya tercatat
--     sebagai "Released by"; dan persetujuan otomatis (approval dimatikan, 20261162180000)
--     mencatat nama pengaju sebagai penyetuju.
--
-- SEKARANG, di kedua fungsi dengan aturan yang sama - pelaku TERAKHIR dari tindakan tahap itu:
--   Submitted  aksi submit
--   Approved   aksi approve; bila persetujuan terakhir otomatis: "Otomatis (approval dimatikan)"
--   Released   aksi release
--   Claimed    aksi claim
--   Clearing   dokumen menjadi Done (clearing, bulk rebate, rebate manual)
-- Tahap tanpa pelaku tercatat (mis. data impor spreadsheet lama) tetap kosong, tidak ditebak.
-- processBy (pelaku terakhir) dipertahankan untuk kompatibilitas.
--
-- Ditambal dengan penjaga MD5 pra-citra (akhir baris dinormalkan), sama di dev dan prod pada
-- 9 Oktober 2026. Aman dijalankan berulang.
-- ==========================================================================================

do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  -- Release / Claim Process: pelaku menurut aksi, bukan status tujuan.
  ('public.rc_legacy_workflow(integer,timestamp with time zone,uuid)', '07df1623cedcee97342d214f1ad9970b',
   $p$filter (where h.to_status='approved' and h.actor_id is not null))[1] as approve_by,$p$,
   $p$filter (where h.action='approve' and h.actor_id is not null))[1] as approve_by,
      -- 20261162190000: persetujuan terakhir otomatis (approval dimatikan) atau oleh orang.
      (array_agg(h.action order by h.id desc) filter (where h.action in ('approve','approve_otomatis')))[1] as approve_terakhir,$p$, 1),
  ('public.rc_legacy_workflow(integer,timestamp with time zone,uuid)', '07df1623cedcee97342d214f1ad9970b',
   $p$filter (where h.to_status='released' and h.actor_id is not null))[1] as release_by,$p$,
   $p$filter (where h.action='release' and h.actor_id is not null))[1] as release_by,$p$, 1),
  ('public.rc_legacy_workflow(integer,timestamp with time zone,uuid)', '07df1623cedcee97342d214f1ad9970b',
   $p$filter (where h.to_status='claimed' and h.actor_id is not null))[1] as claim_by,$p$,
   $p$filter (where h.action='claim' and h.actor_id is not null))[1] as claim_by,$p$, 1),
  ('public.rc_legacy_workflow(integer,timestamp with time zone,uuid)', '07df1623cedcee97342d214f1ad9970b',
   $p$   'approvedBy',coalesce(nama->>(pel.approve_by::text),''),$p$,
   $p$   'approvedBy',case when pel.approve_terakhir='approve_otomatis' then 'Otomatis (approval dimatikan)'
                     else coalesce(nama->>(pel.approve_by::text),'') end,$p$, 1),

  -- Analytics > History: pelaku per tahap ditambahkan.
  ('public.rc_legacy_dashboard(integer,timestamp with time zone,uuid)', '96e47d0042575aea26105c20e7c5f5bf',
   $p$(array_agg(h.actor_id order by h.id desc) filter (where h.actor_id is not null))[1] as proses_by,$p$,
   $p$(array_agg(h.actor_id order by h.id desc) filter (where h.actor_id is not null))[1] as proses_by,
           -- 20261162190000: pelaku terakhir setiap tahap, aturan yang sama dengan rc_legacy_workflow.
           (array_agg(h.actor_id order by h.id desc) filter (where h.action='approve' and h.actor_id is not null))[1] as approve_by,
           (array_agg(h.action order by h.id desc) filter (where h.action in ('approve','approve_otomatis')))[1] as approve_terakhir,
           (array_agg(h.actor_id order by h.id desc) filter (where h.action='release' and h.actor_id is not null))[1] as release_by,
           (array_agg(h.actor_id order by h.id desc) filter (where h.action='claim' and h.actor_id is not null))[1] as claim_by,
           (array_agg(h.actor_id order by h.id desc) filter (where h.to_status='done' and h.actor_id is not null))[1] as clear_by,$p$, 1),
  ('public.rc_legacy_dashboard(integer,timestamp with time zone,uuid)', '96e47d0042575aea26105c20e7c5f5bf',
   $p$    'processBy',coalesce(nama_pemilik->>(pel.proses_by::text),''),$p$,
   $p$    'processBy',coalesce(nama_pemilik->>(pel.proses_by::text),''),
    'submittedBy',coalesce(nama_pemilik->>(pel.submit_by::text),''),
    'approvedBy',case when pel.approve_terakhir='approve_otomatis' then 'Otomatis (approval dimatikan)'
                      else coalesce(nama_pemilik->>(pel.approve_by::text),'') end,
    'releasedBy',coalesce(nama_pemilik->>(pel.release_by::text),''),
    'claimedBy',coalesce(nama_pemilik->>(pel.claim_by::text),''),
    'clearedBy',coalesce(nama_pemilik->>(pel.clear_by::text),''),$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261162190000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
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
-- Pemeriksaan: untuk dokumen Done yang melewati semua tahap, kedua fungsi memberi lima nama
-- yang sama, dan nama-nama itu cocok dengan pelaku aksi di riwayat.
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; v_doc record; w jsonb; d jsonb; harap jsonb; e text := '';
begin
  select id into v_sm from public.profiles where role='system manager' and status='active' and not must_change_password order by user_code limit 1;
  select c.id, c.no_doc into v_doc from public.claims c
   where c.archived_at is null and c.status in ('released','claimed','done')
     and exists(select 1 from public.claim_status_history h where h.claim_id=c.id and h.action='submit' and h.actor_id is not null)
     and exists(select 1 from public.claim_status_history h where h.claim_id=c.id and h.action='release' and h.actor_id is not null)
   order by c.updated_at desc limit 1;
  if v_sm is null or v_doc.id is null then raise notice 'Tidak ada dokumen bertahap untuk diuji; dilewati.'; return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  select jsonb_build_object(
    'submittedBy', coalesce((select p.full_name from public.claim_status_history h join public.profiles p on p.id=h.actor_id
                              where h.claim_id=v_doc.id and h.action='submit' order by h.id desc limit 1),''),
    'releasedBy', coalesce((select p.full_name from public.claim_status_history h join public.profiles p on p.id=h.actor_id
                              where h.claim_id=v_doc.id and h.action='release' order by h.id desc limit 1),''))
    into harap;

  -- Dashboard: halaman demi halaman sampai dokumennya ditemukan.
  declare kursor jsonb := null; hal jsonb;
  begin
    for i in 1..200 loop
      hal := public.rc_legacy_dashboard(1000, (kursor->>'waktu')::timestamptz, (kursor->>'id')::uuid);
      select x into d from jsonb_array_elements(hal->'history') x where x->>'noDoc' = v_doc.no_doc;
      exit when d is not null or hal->'berikutnya' = 'null'::jsonb or hal->'berikutnya' is null;
      kursor := hal->'berikutnya';
    end loop;
  end;
  declare kursor jsonb := null; hal jsonb;
  begin
    for i in 1..200 loop
      hal := public.rc_legacy_workflow(1000, (kursor->>'waktu')::timestamptz, (kursor->>'id')::uuid);
      select x into w from jsonb_array_elements(coalesce(hal->'releaseData','[]')||coalesce(hal->'claimFinData','[]')||coalesce(hal->'clearingData','[]')||coalesce(hal->'bulkRebateData','[]')) x
       where x->>'noDoc' = v_doc.no_doc;
      exit when w is not null or hal->'berikutnya' = 'null'::jsonb or hal->'berikutnya' is null;
      kursor := hal->'berikutnya';
    end loop;
  end;
  perform set_config('request.jwt.claims', '', true);

  if d is null then e := e || ' dokumen tidak ditemukan di History;';
  else
    if not (d ? 'submittedBy' and d ? 'approvedBy' and d ? 'releasedBy' and d ? 'claimedBy' and d ? 'clearedBy') then e := e || ' kunci pelaku History;'; end if;
    if d->>'submittedBy' <> harap->>'submittedBy' or d->>'releasedBy' <> harap->>'releasedBy' then e := e || ' isi pelaku History;'; end if;
  end if;
  -- Dokumen Done tidak lagi tampil di antrean Workflow; bila tampil, isinya harus sama.
  if w is not null and (w->>'submittedBy' <> d->>'submittedBy' or w->>'releasedBy' <> d->>'releasedBy'
                        or w->>'approvedBy' <> d->>'approvedBy' or w->>'claimedBy' <> d->>'claimedBy') then
    e := e || ' Workflow dan History berbeda;'; end if;
  if e <> '' then raise exception 'GAGAL pada %:% History %, Workflow %', v_doc.no_doc, e, d, w; end if;
  raise notice 'Process by teruji pada %: %', v_doc.no_doc, d - array['noDoc'];
end
$uji$;
