-- ==========================================================================================
-- Document Center: pratinjau compile memeriksa persis seperti saat disimpan
-- ==========================================================================================
-- Pemilik, 13 Oktober 2026: "Document center upload tidak bisa, cari tau penyebabnya muncul
-- tapi remark berhasil 0? kenapa?"
--
-- PENYEBAB (dibaca dari rc_private.requests prod, 13 Oktober 2026): unggahan ADMSLO 15:39 dan
-- DANIEL 16:45 ditolak saat disimpan dengan alasan 'Abbr "SOLO" berbeda dengan master depot 1N
-- ("SLO")'. rc_compile_preview tidak memeriksa Abbr sama sekali, sehingga layar menulis "1 baris
-- siap disimpan"; begitu disimpan barisnya ditolak dan layar hanya menampilkan "0 dibuat"
-- tanpa alasan.
--
-- Pratinjau ternyata melewatkan lebih banyak pemeriksaan dibanding simpan: Jenis CB, depot/
-- campaign/customer yang diarsipkan, Abbr, dan nilai angka. Dua lainnya tidak diperiksa di mana
-- pun dan baru ditolak trigger saat INSERT - campaign inactive/cleared (jaga_status_campaign)
-- dan pasangan Not Achieved (jaga_not_achieved). Galat trigger itu tidak ditangkap, sehingga
-- SATU baris seperti itu membatalkan seluruh unggahan.
--
-- SEKARANG
--   * rc_compile_preview menjalankan pemeriksaan yang sama, dengan urutan dan kalimat yang sama,
--     seperti rc_private.compile_upload - "siap" di pratinjau berarti benar-benar tersimpan.
--   * Kedua fungsi memeriksa campaign inactive/cleared dan Not Achieved per baris, jadi baris itu
--     ditolak dengan alasannya dan baris lain tetap tersimpan.
--   * Alasan Abbr menyebut cara memperbaikinya: kosongkan kolom Abbr atau isi Abbr master.
--   * Duplikat di pratinjau kini membawa alasannya juga.
--
-- Ditambal dengan penjaga MD5 pra-citra (sama di dev dan prod, 13 Oktober 2026).
-- ==========================================================================================

do $tambal$
declare src text; baru text; n int; r record;
begin
  create temp table _tambal(urut serial, lama text, ganti text, n int) on commit drop;
  insert into _tambal(lama, ganti, n) values
  ($p$     'alasan','Abbr "'||v_abbr||'" berbeda dengan master depot '||v_depot.depot_code||' ("'||v_depot.abbr||'")'));$p$,
   $p$     'alasan','Abbr "'||v_abbr||'" berbeda dengan master depot '||v_depot.depot_code||' ("'||v_depot.abbr||'"). '
       ||'Kosongkan kolom Abbr atau isi '||v_depot.abbr||'.')); /* 20261163010000 */$p$, 1),
  ($p$  -- Duplikat di dalam file itu sendiri, sebelum menyentuh database.$p$,
   $p$  -- 20261163010000: dua penjaga INSERT diperiksa per baris di sini. Dulu galat triggernya
  -- (jaga_status_campaign, jaga_not_achieved) membatalkan seluruh unggahan.
  if v_camp.status in ('inactive','cleared') then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Campaign '||v_code||' berstatus '||v_camp.status||'; klaim baru tidak dapat dibuat'));
   continue; end if;
  if exists(select 1 from public.timetable_not_achieved na where na.depot_id=v_depot.id and na.campaign_id=v_camp.id) then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Depot '||v_depot.depot_code||' dan campaign '||v_code||' ditandai Not Achieved di Timetable; batalkan tandanya lebih dulu lewat OSC'));
   continue; end if;

  -- Duplikat di dalam file itu sendiri, sebelum menyentuh database.$p$, 1);

  src := pg_get_functiondef('rc_private.compile_upload(jsonb,uuid)'::regprocedure);
  if src ~ '20261163010000' then raise notice 'compile_upload sudah ditambal.';
  else
    if md5(replace(src, E'\r', '')) <> 'd098ffcdf108b6ce365a7b9b9a24fa8f' then
      raise exception 'DITOLAK: definisi rc_private.compile_upload berbeda dari yang diukur (md5 %).', md5(replace(src, E'\r', '')); end if;
    baru := replace(src, E'\r', '');
    for r in select * from _tambal order by urut loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> r.n then raise exception 'compile_upload: pola "%" ditemukan % kali, diharapkan %.', left(r.lama, 80), n, r.n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
    execute baru;
  end if;

  if md5(replace(pg_get_functiondef('public.rc_compile_preview(jsonb)'::regprocedure), E'\r', '')) not in
     ('c7f8feacff1f622ccc466287bf098c4c') and pg_get_functiondef('public.rc_compile_preview(jsonb)'::regprocedure) !~ '20261163010000' then
    raise exception 'DITOLAK: definisi public.rc_compile_preview berbeda dari yang diukur.'; end if;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- Pratinjau: urutan dan kalimat sama persis dengan rc_private.compile_upload, tanpa menulis apa
-- pun (Abbr yang belum ada di master hanya DIANGGAP sah, tidak disimpan).
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_compile_preview(p_rows jsonb)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
-- 20261163010000: pemeriksaan sama dengan rc_private.compile_upload. SECURITY DEFINER seperti
-- compile_upload: dengan hak pemanggil, rc_private.source_number tidak boleh dijalankan
-- (setiap angka tampak "tidak dapat dibaca") dan pemeriksaan duplikat hanya melihat klaim yang
-- lolos RLS - keduanya membuat pratinjau berbeda dari hasil simpan. Akses tetap diperiksa per
-- baris lewat require_tab dan can_access, persis seperti compile_upload.
declare r jsonb; baris integer:=0; siap integer:=0; duplikat jsonb:='[]'; ditolak jsonb:='[]';
 terlihat jsonb:='{}'; kunci text; v_code text; v_custcode text; v_abbr text; v_jenis text; v_cb numeric;
 v_depot public.depots%rowtype; v_camp public.campaigns%rowtype; v_cust public.customers%rowtype;
begin
 perform rc_private.require_tab('compilation.compile');
 if not rc_private.can_access(null,'view_compilation') then
  raise exception 'Access denied' using errcode='42501'; end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array' then raise exception 'Data harus berupa array'; end if;
 if jsonb_array_length(p_rows) not between 1 and 2000 then
  raise exception 'Satu compile maksimal 2000 baris'; end if;

 for r in select value from jsonb_array_elements(p_rows) loop
  baris:=baris+1;
  v_abbr    :=upper(btrim(coalesce(r->>'abbr','')));
  v_code    :=upper(btrim(coalesce(r->>'codeCampaign','')));
  v_custcode:=upper(btrim(coalesce(r->>'custCode','')));
  v_jenis   :=upper(btrim(coalesce(r->>'jenisCb','')));
  if v_jenis not in('','TRANSFER','VOUCHER','CN','REBATE','RA07','RA7','REBATE MANUAL') then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,'alasan','Jenis CB tidak valid'));continue; end if;

  select * into v_depot from public.depots where depot_code=btrim(coalesce(r->>'kodeDepot','')) and archived_at is null;
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Kode depot "'||coalesce(r->>'kodeDepot','')||'" tidak ada di master depot, atau sudah diarsipkan'));
   continue; end if;
  if not rc_private.can_access(v_depot.id) then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Depot '||v_depot.depot_code||' di luar akses Anda'));
   continue; end if;

  if v_abbr='' then v_abbr:=coalesce(v_depot.abbr,''); end if;
  if v_abbr='' then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Abbr wajib diisi untuk depot '||v_depot.depot_code));
   continue; end if;
  if v_depot.abbr is not null and v_depot.abbr<>v_abbr then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Abbr "'||v_abbr||'" berbeda dengan master depot '||v_depot.depot_code||' ("'||v_depot.abbr||'"). '
       ||'Kosongkan kolom Abbr atau isi '||v_depot.abbr||'.'));
   continue; end if;

  select * into v_camp from public.campaigns where campaign_code=v_code and archived_at is null;
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Campaign "'||v_code||'" belum ada di Campaign Master, atau sudah diarsipkan'));
   continue; end if;

  select * into v_cust from public.customers where customer_code=v_custcode and archived_at is null;
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Customer "'||v_custcode||'" belum ada di Customer Master, atau sudah diarsipkan'));
   continue; end if;

  if rc_private.np_pasangan(v_depot.id, v_camp.id) then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Depot '||v_depot.depot_code||' Not Participating pada campaign '||v_code||' (Campaign Master)'));
   continue; end if;
  if v_camp.status in ('inactive','cleared') then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Campaign '||v_code||' berstatus '||v_camp.status||'; klaim baru tidak dapat dibuat'));
   continue; end if;
  if exists(select 1 from public.timetable_not_achieved na where na.depot_id=v_depot.id and na.campaign_id=v_camp.id) then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Depot '||v_depot.depot_code||' dan campaign '||v_code||' ditandai Not Achieved di Timetable; batalkan tandanya lebih dulu lewat OSC'));
   continue; end if;

  kunci:=v_code||'|'||v_custcode;
  if terlihat ? kunci then
   duplikat:=duplikat||jsonb_build_array(jsonb_build_object('baris',baris,'kunci',kunci,'alasan','Duplikat di dalam file'));
   continue; end if;
  terlihat:=terlihat||jsonb_build_object(kunci,true);
  if exists(select 1 from public.claims c where c.campaign_id=v_camp.id
            and c.customer_id=v_cust.id and c.archived_at is null) then
   duplikat:=duplikat||jsonb_build_array(jsonb_build_object('baris',baris,'kunci',kunci,'alasan','Kombinasi campaign dan customer sudah ada'));
   continue; end if;

  begin
   perform rc_private.source_number(r->>'netValue');
   perform rc_private.source_number(r->>'volume');
   v_cb:=rc_private.source_number(r->>'cbNet');
  exception when others then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Nilai angka tidak dapat dibaca; periksa Net Value, Volume dan Cashback'));
   continue; end;
  if v_cb is null or v_cb<0 then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Cashback wajib diisi dan tidak boleh negatif'));
   continue; end if;

  siap:=siap+1;
 end loop;

 return jsonb_build_object('status','success','siap',siap,'duplikat',duplikat,'ditolak',ditolak,'total',baris);
end $function$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (dibatalkan seluruhnya): pratinjau dan simpan memberi hasil yang sama untuk enam
-- jenis baris, dan baris yang ditolak trigger tidak lagi membatalkan baris lain.
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; d record; v_inaktif record; rows jsonb; pv jsonb; up jsonb; e text := '';
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select dp.id depot_id, dp.depot_code, dp.abbr, cu.customer_code, ca.id campaign_id, ca.campaign_code into d
    from public.customers cu
    join public.customer_depots m on m.customer_id = cu.id
    join public.depots dp on dp.id = m.depot_id and dp.archived_at is null and dp.abbr is not null
    cross join lateral (select ca.* from public.campaigns ca
                         where ca.status = 'active' and ca.archived_at is null
                           and not exists(select 1 from public.claims c where c.campaign_id = ca.id and c.customer_id = cu.id)
                           and not rc_private.np_pasangan(dp.id, ca.id)
                           and not exists(select 1 from public.timetable_not_achieved na where na.depot_id = dp.id and na.campaign_id = ca.id)
                         order by ca.campaign_code limit 3) ca
   where cu.archived_at is null
   order by cu.customer_code, ca.campaign_code limit 1;
  if v_sm is null or d.depot_code is null then raise notice 'Tidak ada fixture; uji dilewati.'; return; end if;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    -- Campaign kedua dan ketiga untuk customer yang sama: satu dijadikan inactive, satu Not Achieved.
    select ca.id, ca.campaign_code into v_inaktif from public.campaigns ca
     where ca.status = 'active' and ca.archived_at is null and ca.id <> d.campaign_id
       and not exists(select 1 from public.claims c join public.customers cu on cu.id = c.customer_id where c.campaign_id = ca.id and cu.customer_code = d.customer_code)
       and not rc_private.np_pasangan(d.depot_id, ca.id)
     order by ca.campaign_code limit 1;
    update public.campaigns set status = 'inactive' where id = v_inaktif.id;
    rows := jsonb_build_array(
      jsonb_build_object('kodeDepot', d.depot_code, 'abbr', '', 'codeCampaign', d.campaign_code, 'custCode', d.customer_code, 'netValue', '10000000.75', 'cbNet', '500000.9'),
      jsonb_build_object('kodeDepot', d.depot_code, 'abbr', 'SALAH', 'codeCampaign', d.campaign_code, 'custCode', d.customer_code, 'cbNet', '1000000'),
      jsonb_build_object('kodeDepot', d.depot_code, 'abbr', d.abbr, 'codeCampaign', v_inaktif.campaign_code, 'custCode', d.customer_code, 'cbNet', '1000000'),
      jsonb_build_object('kodeDepot', d.depot_code, 'abbr', d.abbr, 'codeCampaign', d.campaign_code, 'custCode', d.customer_code, 'cbNet', '1000000'),
      jsonb_build_object('kodeDepot', d.depot_code, 'abbr', d.abbr, 'codeCampaign', d.campaign_code, 'custCode', 'TIDAK-ADA-123', 'cbNet', '5'),
      jsonb_build_object('kodeDepot', d.depot_code, 'abbr', d.abbr, 'codeCampaign', d.campaign_code, 'custCode', d.customer_code, 'cbNet', 'abc'));
    -- Pratinjau dipanggil sebagai pengguna aplikasi (role authenticated), seperti dari layar.
    execute 'set local role authenticated';
    pv := public.rc_compile_preview(rows);
    execute 'reset role';
    up := rc_private.compile_upload(rows, gen_random_uuid());
    if (pv->>'siap')::int <> (up->>'dibuat')::int then e := e || format(' siap %s tetapi dibuat %s;', pv->>'siap', up->>'dibuat'); end if;
    if (pv->>'siap')::int <> 1 then e := e || format(' siap %s (harap 1);', pv->>'siap'); end if;
    if pv->'ditolak' <> up->'ditolak' then e := e || format(' ditolak berbeda: pratinjau %s | simpan %s;', pv->'ditolak', up->'ditolak'); end if;
    if (select jsonb_agg(x - 'kunci') from jsonb_array_elements(pv->'duplikat') x) is distinct from (select jsonb_agg(x - 'kunci') from jsonb_array_elements(up->'duplikat') x) then
      e := e || ' duplikat berbeda;'; end if;
    if not exists(select 1 from jsonb_array_elements(up->'ditolak') x where x->>'alasan' ~ 'berstatus inactive') then e := e || ' campaign inactive tidak ditolak per baris;'; end if;
    if not exists(select 1 from jsonb_array_elements(up->'ditolak') x where x->>'alasan' ~ 'Kosongkan kolom Abbr') then e := e || ' petunjuk Abbr hilang;'; end if;

    -- Not Achieved: ditandai lalu dicompile ulang dengan baris yang sama; harus ditolak per baris.
    insert into public.timetable_not_achieved(depot_id, campaign_id, marked_by, note)
    select d.depot_id, ca.id, v_sm, 'uji' from public.campaigns ca
     where ca.status = 'active' and ca.archived_at is null and ca.id not in (d.campaign_id, v_inaktif.id)
       and not exists(select 1 from public.claims c join public.customers cu on cu.id = c.customer_id where c.campaign_id = ca.id and cu.customer_code = d.customer_code)
       and not rc_private.np_pasangan(d.depot_id, ca.id)
     order by ca.campaign_code limit 1
    returning campaign_id into v_inaktif.id;
    rows := jsonb_build_array(jsonb_build_object('kodeDepot', d.depot_code, 'abbr', d.abbr,
      'codeCampaign', (select campaign_code from public.campaigns where id = v_inaktif.id), 'custCode', d.customer_code, 'cbNet', '1000'));
    execute 'set local role authenticated';
    pv := public.rc_compile_preview(rows);
    execute 'reset role';
    up := rc_private.compile_upload(rows, gen_random_uuid());
    if (pv->>'siap')::int <> 0 or (up->>'dibuat')::int <> 0 or pv->'ditolak' <> up->'ditolak'
       or not exists(select 1 from jsonb_array_elements(up->'ditolak') x where x->>'alasan' ~ 'Not Achieved') then
      e := e || format(' Not Achieved: pratinjau %s | simpan %s;', pv, up); end if;
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then e := e || ' galat: ' || sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
