-- ==========================================================================================
-- Jenis CB Voucher (alur Rebate Manual), email Done ke Kepala Admin, Abbr di form Ubah Depot
-- ==========================================================================================
-- Pemilik, 14 Oktober 2026: "1 category lagi yakni Jenis CB Voucher. dengan workflow sama
-- persis seperti rebate manual", dan "untuk email 'Done - Pengajuan' hanya diperlukan ke kepala
-- admin saja to nya, dan subject email menampilkan nama depo". Sumber alamat Kepala Admin
-- dipilih pemilik: kolom baru di Depot Master; selama kosong, email Done tetap ke Email TO.
--
-- 1. VOUCHER
--    Sebelumnya "Voucher" hanya nama lain Transfer (jenis_efektif: voucher -> transfer), sehingga
--    berjalan Release -> Claim -> Clearing dan tampil sebagai "Transfer". Sekarang kategori
--    sendiri dengan alur Rebate Manual: submit -> approval -> Done (approval mati: langsung Done),
--    riwayat manual_complete beralasan "Voucher". Seperti Rebate Manual, rekening tidak wajib
--    saat submit (kewajiban itu hanya untuk Transfer). Gross up TIDAK diubah: Voucher tetap
--    dihitung seperti sebelumnya (hanya Rebate dan Rebate Manual yang 0).
--    Prod 14 Oktober 2026: 0 campaign Voucher, jadi tidak ada dokumen berjalan yang berubah alur.
--
-- 2. EMAIL DONE
--    depot_profiles.email_kepala_admin (maks 4 alamat), diisi lewat Depot Master (Ubah dan unggah
--    template). email_pengajuan_antre('clearing'): TO = Email Kepala Admin bila terisi, selain
--    itu tetap Email TO depot; CC tidak berubah (OSC/supervisor + CC tambahan), tanpa alamat yang
--    sudah menjadi TO. Subjek: "Done - Pengajuan Claim Cashback Depo <nama depo>".
--    rc_depot_list membawa emailKepalaAdmin dan tanpaEmailKa untuk peringatan di layar.
--
-- 3. ABBR DI FORM UBAH DEPOT (rc_depot_save / terapkan_depot)
--    20261163090000 memperbaiki jalur unggah saja. Form Ubah memakai terapkan_depot, yang masih
--    MENGHAPUS Abbr bila kolomnya dikosongkan dan membiarkan Abbr salah format/kembar jatuh ke
--    constraint. Sekarang sama dengan jalur unggah: kosong = tetap, format 2-10 huruf/angka,
--    tidak boleh dipakai depot lain - diperiksa juga saat perubahan masih berupa pengajuan.
--
-- Ditambal dengan penjaga MD5 pra-citra (14 Oktober 2026). Harus dipasang SESUDAH
-- 20261163090000 (rc_depot_upsert dan rc_depot_list).
-- ==========================================================================================

alter table public.depot_profiles add column if not exists email_kepala_admin text;
comment on column public.depot_profiles.email_kepala_admin is
  'Tujuan (TO) email Done - Pengajuan. Kosong: email Done ke Email TO depot. 20261163100000';

-- ---- 1. Voucher: kategori sendiri ---------------------------------------------------------
do $jaga$
begin
  if md5(replace(pg_get_functiondef('rc_private.jenis_efektif(text)'::regprocedure), E'\r', '')) <> '8513ed0cb15e2839667d3d26e3f3b6f1'
     and pg_get_functiondef('rc_private.jenis_efektif(text)'::regprocedure) !~ '20261163100000' then
    raise exception 'DITOLAK: rc_private.jenis_efektif berbeda dari yang diukur.'; end if;
  if md5(replace(pg_get_functiondef('rc_private.cb_label(text)'::regprocedure), E'\r', '')) <> '14e8618cd0c64c4f3d068f21be676198'
     and pg_get_functiondef('rc_private.cb_label(text)'::regprocedure) !~ '20261163100000' then
    raise exception 'DITOLAK: rc_private.cb_label berbeda dari yang diukur.'; end if;
  if md5(replace(pg_get_functiondef('rc_private.terapkan_depot(uuid,jsonb)'::regprocedure), E'\r', '')) <> '17a96d934a92962c28f9578b633c3759'
     and pg_get_functiondef('rc_private.terapkan_depot(uuid,jsonb)'::regprocedure) !~ '20261163100000' then
    raise exception 'DITOLAK: rc_private.terapkan_depot berbeda dari yang diukur.'; end if;
end
$jaga$;

create or replace function rc_private.jenis_efektif(p_jenis text)
 returns text
 language sql
 immutable
as $function$
 -- 20261163100000: voucher kategori sendiri (dulu nama lain transfer).
 select case lower(btrim(coalesce(p_jenis,'')))
 when 'ra07' then 'rebate manual' when 'ra7' then 'rebate manual' else lower(btrim(coalesce(p_jenis,''))) end;
$function$;

create or replace function rc_private.cb_label(p_jenis text)
 returns text
 language sql
 immutable
as $function$
 -- 20261163100000: Voucher.
 select case rc_private.jenis_efektif(p_jenis) when 'rebate manual' then 'Rebate Manual' when 'rebate' then 'Rebate'
 when 'transfer' then 'Transfer' when 'cn' then 'CN' when 'voucher' then 'Voucher' else coalesce(p_jenis,'') end;
$function$;

-- ---- 3. terapkan_depot: Abbr dan Email Kepala Admin --------------------------------------
create or replace function rc_private.terapkan_depot(p_depot uuid, c jsonb)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
-- 20261163100000: Abbr kosong = tetap, format dan keunikan diperiksa dengan pesan jelas (sama
-- dengan rc_depot_upsert sejak 20261163090000); Email Kepala Admin (tujuan TO email Done).
declare v_abbr text;
begin
  if c ? 'abbr' and btrim(coalesce(c->>'abbr','')) <> '' then
    v_abbr := upper(btrim(c->>'abbr'));
    if v_abbr !~ '^[A-Z0-9]{2,10}$' then
      raise exception 'Abbr "%" harus 2-10 huruf atau angka', v_abbr; end if;
    if exists(select 1 from public.depots where abbr = v_abbr and id <> p_depot) then
      raise exception 'Abbr "%" sudah dipakai depot %', v_abbr,
        (select depot_code from public.depots where abbr = v_abbr and id <> p_depot limit 1); end if;
  end if;

  update public.depots set
    depot_name   = case when c ? 'nama'    then coalesce(nullif(btrim(c->>'nama'),''), depot_name) else depot_name end,
    abbr         = coalesce(v_abbr, abbr),
    region       = case when c ? 'region'  then nullif(btrim(coalesce(c->>'region','')),'') else region end,
    address      = case when c ? 'alamat'  then nullif(btrim(coalesce(c->>'alamat','')),'') else address end,
    email_to     = case when c ? 'emailTo' then nullif(btrim(coalesce(c->>'emailTo','')),'') else email_to end,
    email_cc     = case when c ? 'emailCc' then nullif(btrim(coalesce(c->>'emailCc','')),'') else email_cc end,
    updated_at   = now(), updated_by = (select auth.uid())
  where id = p_depot;

  insert into public.depot_profiles(depot_id) values(p_depot) on conflict(depot_id) do nothing;

  update public.depot_profiles set
    tipe_depot   = case when c ? 'tipeDepot'   then nullif(btrim(c->>'tipeDepot'),'')   else tipe_depot end,
    alamat       = case when c ? 'alamat'      then nullif(btrim(c->>'alamat'),'')      else alamat end,
    gmaps_url    = case when c ? 'gmapsUrl'    then nullif(btrim(c->>'gmapsUrl'),'')    else gmaps_url end,
    foto_url     = case when c ? 'fotoUrl'     then nullif(btrim(c->>'fotoUrl'),'')     else foto_url end,
    kepala_depot = case when c ? 'kepalaDepot' then nullif(btrim(c->>'kepalaDepot'),'') else kepala_depot end,
    kepala_admin = case when c ? 'kepalaAdmin' then nullif(btrim(c->>'kepalaAdmin'),'') else kepala_admin end,
    kar_admin    = case when c ? 'karAdmin'   then greatest(coalesce((c->>'karAdmin')::int,0),0)   else kar_admin end,
    kar_sales    = case when c ? 'karSales'   then greatest(coalesce((c->>'karSales')::int,0),0)   else kar_sales end,
    kar_driver   = case when c ? 'karDriver'  then greatest(coalesce((c->>'karDriver')::int,0),0)  else kar_driver end,
    kar_fg       = case when c ? 'karFg'      then greatest(coalesce((c->>'karFg')::int,0),0)      else kar_fg end,
    kar_pcc      = case when c ? 'karPcc'     then greatest(coalesce((c->>'karPcc')::int,0),0)     else kar_pcc end,
    kar_teknisi  = case when c ? 'karTeknisi' then greatest(coalesce((c->>'karTeknisi')::int,0),0) else kar_teknisi end,
    kar_lain     = case when c ? 'karLain'    then greatest(coalesce((c->>'karLain')::int,0),0)    else kar_lain end,
    email_rsm    = case when c ? 'emailRsm'   then rc_private.periksa_email_maks(c->>'emailRsm','Email RSM',4) else email_rsm end,
    email_asm    = case when c ? 'emailAsm'   then rc_private.periksa_email_maks(c->>'emailAsm','Email ASM',4) else email_asm end,
    email_sm     = case when c ? 'emailSm'    then rc_private.periksa_email_maks(c->>'emailSm','Email SM',4)   else email_sm end,
    email_kepala_admin = case when c ? 'emailKepalaAdmin'
                              then rc_private.periksa_email_maks(c->>'emailKepalaAdmin','Email Kepala Admin',4) else email_kepala_admin end,
    grade = case when c ? 'grade' then nullif(btrim(c->>'grade'),'') else grade end,
    email_depot  = case when c ? 'emailDepot' then rc_private.periksa_email_maks(c->>'emailDepot','Email Depot',4) when c ? 'emailTo'    then nullif(btrim(c->>'emailTo'),'') else email_depot end,
    updated_at = now(), updated_by = (select auth.uid())
  where depot_id = p_depot;
end $function$;
revoke all on function rc_private.terapkan_depot(uuid, jsonb) from public, anon, authenticated;

-- ---- Tambalan berpenjaga MD5 ---------------------------------------------------------------
do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  -- 1. Voucher memakai alur Rebate Manual.
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', 'c35a3a68453742197661d1a9011ea19e',
   $p$jenis='rebate manual' then 'done'$p$,
   $p$jenis in ('rebate manual','voucher') then 'done' /* 20261163100000 */$p$, 2),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', 'c35a3a68453742197661d1a9011ea19e',
   $p$'manual_complete',batch,'Rebate Manual')$p$,
   $p$'manual_complete',batch,rc_private.cb_label(jenis))$p$, 2),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', 'c35a3a68453742197661d1a9011ea19e',
   $p$Tulis persis Transfer, CN, Rebate atau Rebate Manual'$p$,
   $p$Tulis persis Transfer, CN, Voucher, Rebate atau Rebate Manual'$p$, 1),

  -- 2. Email Done: TO Kepala Admin, subjek bernama depo.
  ('rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)', 'b7909cdd8004740ce7614e53d9c149d1',
   $p$  v_to text[]; v_cc text[]; v_subjek text; v_spanduk text;$p$,
   $p$  v_to text[]; v_cc text[]; v_subjek text; v_spanduk text;
  v_ka text[]; -- 20261163100000$p$, 1),
  ('rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)', 'b7909cdd8004740ce7614e53d9c149d1',
   $p$    v_cc  := array(select jsonb_array_elements_text(v_pen->'cc'));$p$,
   $p$    v_cc  := array(select jsonb_array_elements_text(v_pen->'cc'));

    -- 20261163100000: email Done hanya ke Kepala Admin depot (Depot Master > Email Kepala Admin).
    -- Selama kolom itu kosong, tetap ke Email TO depot. CC tidak berubah, tanpa alamat TO.
    if p_action = 'clearing' then
      select coalesce(array_agg(distinct lower(btrim(x))), '{}') into v_ka
        from public.depot_profiles dp, unnest(rc_private.pecah_email(dp.email_kepala_admin)) x
       where dp.depot_id = v_dep.depot_id and btrim(x) <> '';
      if coalesce(array_length(v_ka,1),0) > 0 then
        v_to := v_ka;
        v_cc := array(select y from unnest(v_cc) y where not (lower(y) = any(v_ka)));
      end if;
    end if;$p$, 1),
  ('rc_private.email_pengajuan_subjek(text,text[])', '25b17a1ca717ca413f1407358e725ce3',
   $p$    when 'clearing' then 'Done - Pengajuan Claim Cashback'$p$,
   $p$    when 'clearing' then 'Done - Pengajuan Claim Cashback' /* 20261163100000: bernama depo */
      || coalesce(' Depo ' || rc_private.email_daftar_depot(p_depot), '')$p$, 1),

  -- 2. Depot Master: Email Kepala Admin di form Ubah, unggah, dan daftar.
  ('public.rc_depot_save(text,jsonb)', '6f80c2b072f03579386a2b1223720e89',
   $p$'karTeknisi','karLain','emailRsm','emailAsm','emailSm','emailTo','emailCc'];$p$,
   $p$'karTeknisi','karLain','emailRsm','emailAsm','emailSm','emailTo','emailCc','emailKepalaAdmin']; -- 20261163100000$p$, 1),
  ('public.rc_depot_save(text,jsonb)', '6f80c2b072f03579386a2b1223720e89',
   $p$  perform rc_private.periksa_email_maks(v_bersih->>'emailCc','Email CC',20);$p$,
   $p$  perform rc_private.periksa_email_maks(v_bersih->>'emailCc','Email CC',20);
  perform rc_private.periksa_email_maks(v_bersih->>'emailKepalaAdmin','Email Kepala Admin',4);
  -- 20261163100000: Abbr diperiksa sejak diajukan, bukan baru saat disetujui.
  if btrim(coalesce(v_bersih->>'abbr','')) <> '' then
    if upper(btrim(v_bersih->>'abbr')) !~ '^[A-Z0-9]{2,10}$' then
      raise exception 'Abbr "%" harus 2-10 huruf atau angka', upper(btrim(v_bersih->>'abbr')); end if;
    if exists(select 1 from public.depots where abbr = upper(btrim(v_bersih->>'abbr')) and id <> v_depot) then
      raise exception 'Abbr "%" sudah dipakai depot %', upper(btrim(v_bersih->>'abbr')),
        (select depot_code from public.depots where abbr = upper(btrim(v_bersih->>'abbr')) and id <> v_depot limit 1); end if;
  end if;$p$, 1),
  ('public.rc_depot_upsert(jsonb)', 'b0e9a1e3e99ba3ed66422d911749e4c9',
   $p$  v_to text; v_cc text;$p$,
   $p$  v_to text; v_cc text; v_ka text; -- 20261163100000$p$, 1),
  ('public.rc_depot_upsert(jsonb)', 'b0e9a1e3e99ba3ed66422d911749e4c9',
   $p$      salah := salah || (v_kode||': alamat CC tidak sah'); continue; end if;$p$,
   $p$      salah := salah || (v_kode||': alamat CC tidak sah'); continue; end if;
    -- 20261163100000: Email Kepala Admin (tujuan TO email Done), maks 4 alamat.
    v_ka := btrim(coalesce(r->>'emailKepalaAdmin',''));
    if v_ka <> '' and coalesce(array_length(rc_private.pecah_email(v_ka),1),0) = 0 then
      salah := salah || (v_kode||': Email Kepala Admin tidak sah'); continue; end if;
    if v_ka <> '' and array_length(rc_private.pecah_email(v_ka),1) > 4 then
      salah := salah || (v_kode||': Email Kepala Admin maksimal 4 alamat'); continue; end if;$p$, 1),
  ('public.rc_depot_upsert(jsonb)', 'b0e9a1e3e99ba3ed66422d911749e4c9',
   $p$      n_baru := n_baru + 1;
    end if;
  end loop;$p$,
   $p$      n_baru := n_baru + 1;
    end if;
    if r ? 'emailKepalaAdmin' then
      insert into public.depot_profiles(depot_id) select id from public.depots where depot_code = v_kode
      on conflict (depot_id) do nothing;
      update public.depot_profiles set email_kepala_admin = nullif(v_ka,''), updated_at = now(), updated_by = (select auth.uid())
       where depot_id = (select id from public.depots where depot_code = v_kode);
    end if;
  end loop;$p$, 1),
  ('public.rc_depot_list(text,integer,integer)', 'fdb93eb3f3937785d76adf070b382f4c',
   $p$'[]'::jsonb) /* 20261163090000 */,$p$,
   $p$'[]'::jsonb) /* 20261163090000 */,
    'tanpaEmailKa', coalesce((select jsonb_agg(x.depot_code order by x.depot_code) from public.depots x
       left join public.depot_profiles xp on xp.depot_id = x.id
       where x.archived_at is null and coalesce(btrim(xp.email_kepala_admin),'') = ''), '[]'::jsonb) /* 20261163100000 */,$p$, 1),
  ('public.rc_depot_list(text,integer,integer)', 'fdb93eb3f3937785d76adf070b382f4c',
   $p$        'emailSm',coalesce(t.email_sm,''),$p$,
   $p$        'emailSm',coalesce(t.email_sm,''),
        'emailKepalaAdmin',coalesce(t.email_kepala_admin,''), -- 20261163100000$p$, 1),
  ('public.rc_depot_list(text,integer,integer)', 'fdb93eb3f3937785d76adf070b382f4c',
   $p$                   p.kar_teknisi, p.kar_lain, p.email_rsm, p.email_asm, p.email_sm$p$,
   $p$                   p.kar_teknisi, p.kar_lain, p.email_rsm, p.email_asm, p.email_sm, p.email_kepala_admin$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261163100000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
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

notify pgrst, 'reload schema';

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (dibatalkan seluruhnya; email pengajuan hanya diantrekan di dalam subtransaksi
-- yang dibatalkan, tidak ada yang dikirim)
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; d record; c public.claims%rowtype; r jsonb; e text := ''; v_hist text; v_dep record;
  v_ids uuid[]; v_o public.email_outbox%rowtype; v_galat text; v_ver bigint;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  if v_sm is null then raise notice 'Tidak ada System Manager aktif; uji dilewati.'; return; end if;
  if rc_private.jenis_efektif('Voucher') <> 'voucher' or rc_private.cb_label('voucher') <> 'Voucher'
     or rc_private.jenis_efektif('RA07') <> 'rebate manual' or rc_private.cb_label('Transfer') <> 'Transfer' then
    e := e || ' label jenis;'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  -- Dokumen Not Yet ber-campaign CN (tidak menuntut rekening) dengan identitas pajak sah.
  select c2.id, c2.no_doc, c2.version_no into d
    from public.claims c2
    join public.customers cu on cu.id = c2.customer_id
     and (nullif(btrim(coalesce(cu.ktp, '')), '') is null) <> (nullif(btrim(coalesce(cu.npwp, '')), '') is null)
    join public.campaigns ca on ca.id = c2.campaign_id and ca.status = 'active'
   where c2.status = 'not_yet' and c2.archived_at is null and c2.pending_approval is null and c2.cb_net > 0
     and rc_private.jenis_efektif(coalesce(nullif(c2.cashback_type_override, ''), ca.cashback_type)) = 'cn'
   order by c2.no_doc limit 1;
  if d.no_doc is null then
    raise notice 'Tidak ada dokumen CN Not Yet; uji alur Voucher dilewati.';
  else
    -- Approval mati: Voucher langsung Done, seperti Rebate Manual.
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      insert into public.pengaturan_sistem(kunci, nilai) values ('approval_aktif', 'false'::jsonb)
      on conflict (kunci) do update set nilai = 'false'::jsonb;
      r := public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', d.version_no,
             'jenis_cashback', 'Voucher')), gen_random_uuid(), '');
      select * into c from public.claims where id = d.id;
      select string_agg(action || ':' || coalesce(reason,''), ',' order by id) into v_hist from public.claim_status_history where claim_id = d.id and created_at >= now();
      if c.status <> 'done' or c.cashback_type_override <> 'Voucher' or v_hist !~ 'manual_complete:Voucher' then
        e := e || format(' Voucher approval mati: status %s, jenis %s, riwayat %s;', c.status, c.cashback_type_override, v_hist); end if;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' Voucher approval mati: ' || sqlerrm || ';'; end if;
    end;
    -- Approval hidup: Submitted menunggu approval, lalu disetujui -> Done (bukan Approved).
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      insert into public.pengaturan_sistem(kunci, nilai) values ('approval_aktif', 'true'::jsonb)
      on conflict (kunci) do update set nilai = 'true'::jsonb;
      r := public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', d.version_no,
             'jenis_cashback', 'Voucher')), gen_random_uuid(), '');
      select * into c from public.claims where id = d.id;
      if c.status <> 'submitted' or c.pending_approval->>'target_status' <> 'done' then
        e := e || format(' Voucher approval hidup: status %s, target %s;', c.status, c.pending_approval->>'target_status'); end if;
      r := public.rc_process_claims('approve', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', c.version_no)), gen_random_uuid(), '');
      select * into c from public.claims where id = d.id;
      if c.status <> 'done' then e := e || format(' Voucher disetujui menjadi %s, bukan done;', c.status); end if;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' Voucher approval hidup: ' || sqlerrm || ';'; end if;
    end;
  end if;

  -- Email Done: TO Kepala Admin bila diisi, selain itu Email TO depot; subjek bernama depo.
  select c3.depot_id, dp.depot_code, dp.depot_name, dp.email_to into v_dep
    from public.claims c3 join public.depots dp on dp.id = c3.depot_id
   where c3.archived_at is null and coalesce(btrim(dp.email_to),'') like '%@%'
   order by dp.depot_code limit 1;
  if v_dep.depot_id is not null then
    begin
      select array_agg(id) into v_ids from (select id from public.claims where depot_id = v_dep.depot_id and archived_at is null limit 3) x;
      update public.email_settings set aktif = true, mode_uji = false where jenis = 'pengajuan';
      insert into public.depot_profiles(depot_id) values (v_dep.depot_id) on conflict (depot_id) do nothing;
      update public.depot_profiles set email_kepala_admin = null where depot_id = v_dep.depot_id;
      perform rc_private.email_pengajuan_antre('clearing', 'UJI-01', v_ids, v_sm, '');
      select * into v_o from public.email_outbox where konteks->>'batch' = 'UJI-01' order by dibuat_pada desc limit 1;
      if v_o.id is null or v_o.subjek !~ ('Done - Pengajuan Claim Cashback Depo ' || v_dep.depot_name)
         or array_to_string(v_o.tujuan, ',') <> array_to_string(array(select lower(btrim(x)) from unnest(rc_private.pecah_email(v_dep.email_to)) x where btrim(x) <> '' order by 1), ',') then
        e := e || format(' Done tanpa Kepala Admin: subjek %s, TO %s;', v_o.subjek, v_o.tujuan); end if;
      delete from public.email_outbox where konteks->>'batch' = 'UJI-01';
      update public.depot_profiles set email_kepala_admin = 'kepala.admin.uji@example.invalid' where depot_id = v_dep.depot_id;
      perform rc_private.email_pengajuan_antre('clearing', 'UJI-01', v_ids, v_sm, '');
      select * into v_o from public.email_outbox where konteks->>'batch' = 'UJI-01' order by dibuat_pada desc limit 1;
      if v_o.tujuan <> array['kepala.admin.uji@example.invalid'] or 'kepala.admin.uji@example.invalid' = any(v_o.cc) then
        e := e || format(' Done dengan Kepala Admin: TO %s, CC %s;', v_o.tujuan, v_o.cc); end if;
      -- Email lain (Approved) tidak berubah: tetap ke Email TO depot.
      perform rc_private.email_pengajuan_antre('approve', 'UJI-02', v_ids, v_sm, '');
      select * into v_o from public.email_outbox where konteks->>'batch' = 'UJI-02' order by dibuat_pada desc limit 1;
      if 'kepala.admin.uji@example.invalid' = any(v_o.tujuan) then e := e || ' email Approved ikut ke Kepala Admin;'; end if;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' email Done: ' || sqlerrm || ';'; end if;
    end;
    -- Depot Master: Email Kepala Admin & Abbr lewat form Ubah dan unggah.
    begin
      execute 'set local role authenticated';
      r := public.rc_depot_save(v_dep.depot_code, jsonb_build_object('abbr', '', 'emailKepalaAdmin', 'ka.uji@example.invalid'));
      execute 'reset role';
      if (select abbr from public.depots where id = v_dep.depot_id) is null then e := e || ' form Ubah: Abbr kosong menghapus Abbr;'; end if;
      if (select email_kepala_admin from public.depot_profiles where depot_id = v_dep.depot_id) <> 'ka.uji@example.invalid' then
        e := e || ' form Ubah: Email Kepala Admin tidak tersimpan;'; end if;
      execute 'set local role authenticated';
      begin
        r := public.rc_depot_save(v_dep.depot_code, jsonb_build_object('abbr', 'A'));
        e := e || ' form Ubah: Abbr 1 huruf diterima;';
      exception when others then v_galat := sqlerrm;
        if v_galat !~ 'harus 2-10' then e := e || ' pesan Abbr format: ' || v_galat || ';'; end if;
      end;
      begin
        r := public.rc_depot_save(v_dep.depot_code, jsonb_build_object('abbr',
               (select abbr from public.depots where abbr is not null and id <> v_dep.depot_id order by depot_code limit 1)));
        e := e || ' form Ubah: Abbr kembar diterima;';
      exception when others then v_galat := sqlerrm;
        if v_galat !~ 'sudah dipakai depot' then e := e || ' pesan Abbr kembar: ' || v_galat || ';'; end if;
      end;
      r := public.rc_depot_upsert(jsonb_build_array(jsonb_build_object('kode', v_dep.depot_code, 'emailKepalaAdmin', 'ka2.uji@example.invalid'),
             jsonb_build_object('kode', v_dep.depot_code, 'emailKepalaAdmin', 'bukan email')));
      if (r->>'ditolak')::int <> 1 or not exists(select 1 from jsonb_array_elements_text(r->'pesanDitolak') x where x ~ 'Email Kepala Admin tidak sah') then
        e := e || format(' unggah Email Kepala Admin: %s;', r); end if;
      r := public.rc_depot_list(v_dep.depot_code, 0, 5);
      execute 'reset role';
      if (r->'rows'->0->>'emailKepalaAdmin') <> 'ka2.uji@example.invalid' or r->'tanpaEmailKa' is null or (r->'tanpaEmailKa') @> to_jsonb(v_dep.depot_code) then
        e := e || format(' daftar depot: %s / %s;', r->'rows'->0->>'emailKepalaAdmin', r->'tanpaEmailKa'); end if;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' Depot Master: ' || sqlerrm || ';'; end if;
    end;
  end if;

  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
