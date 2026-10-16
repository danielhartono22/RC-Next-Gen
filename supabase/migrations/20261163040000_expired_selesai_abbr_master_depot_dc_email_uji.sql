-- ==========================================================================================
-- Expired = tahap akhir, Abbr dari Depot Master, Depot di Document Center, DEV hanya email uji
-- ==========================================================================================
-- Pemilik, 13 Oktober 2026:
--   "Expired itu cleared / done jadi gabisa di klaim lagi udah stage akhir. untuk di dev hanya
--    ada email uji. perbarui template upload tanpa abbr, abbr mengikuti master. di document
--    center tambahkan field depot (kode depot) dan filter depot."
--
-- 1. TIMETABLE - Expired dihitung selesai.
--    Sebelumnya dokumen Expired DIABAIKAN (aturan PRD sistem lama): pasangan depot x campaign
--    yang dokumennya Done + Expired tampil Compiled, dan yang seluruhnya Expired tampil Not Yet
--    seolah depot masih harus mengklaim. Padahal Expired adalah tahap akhir; dokumen itu tidak
--    dapat diklaim lagi (tidak ada transisi keluar dari expired, dan compile ulang ditolak
--    sebagai duplikat campaign + customer). Sekarang:
--        dokumen = semua klaim yang tidak diarsipkan (Expired ikut)
--        selesai = Done + Expired
--    Dipakai rc_timetable_matrix, rc_private.timetable_ringkas (email Timetable) dan
--    rc_private.people_metrics, sehingga ketiganya tetap sama. Clearing Rate di Report sudah
--    sejak awal menghitung done + expired sebagai cleared. rc_campaign_np(_simpan) ikut
--    menghitung dokumen Expired pada "dokumenAda", karena dokumen itulah yang menentukan status.
--    Diukur di prod 13 Oktober 2026 (Tahun 2026): 57 pasangan punya dokumen Expired, 28 di
--    antaranya menjadi Completed (2 di antaranya seluruhnya Expired).
--
-- 2. COMPILE - Abbr selalu dari Depot Master.
--    Template baru tidak punya kolom Abbr. Kolom Abbr pada file template lama diabaikan (tidak
--    lagi ditolak karena berbeda, dan master depot tidak lagi diisi dari file). Depot yang
--    Abbr-nya kosong di master ditolak per baris dengan petunjuk mengisi Depot Master.
--    Prod 13 Oktober 2026: 2 depot aktif tanpa Abbr (5S, 5T).
--
-- 3. DOCUMENT CENTER - filter depot.
--    rc_compilation_list mendapat p_depot (kode depot, default '' = semua; pemanggil lama tetap
--    berjalan). rc_compilation_depots() memberi daftar depot untuk pilihan filter, terbatas
--    pada depot yang boleh dilihat akun itu. Kolom kodeDepot sudah dikirim sejak awal.
--
-- 4. EMAIL - lingkungan DEV hanya mengirim email uji.
--    rc_private.lingkungan_email (satu baris) dengan hanya_uji. Di DEV barisnya diisi oleh
--    supabase/dev/email_hanya_uji_20261013.sql; di PROD tabelnya kosong sehingga perilaku prod
--    tidak berubah. Penjaganya di rc_private.kirim_satu_email, satu-satunya jalan keluar email:
--    surat yang bukan email uji (konteks uji / modeUji) tidak dikirim dan ditandai skipped,
--    apa pun setelan email dan alamat depotnya. Layar Email Otomatis dan Email Pengajuan
--    menerima hanyaUji untuk menampilkan spanduknya.
--
-- Ditambal dengan penjaga MD5 pra-citra (13 Oktober 2026). Harus dipasang SESUDAH
-- 20261163010000, 20261163020000 dan 20261163030000.
-- ==========================================================================================

-- ---- 4. Lingkungan email ------------------------------------------------------------------
create table if not exists rc_private.lingkungan_email (
  id boolean primary key default true check (id),
  hanya_uji boolean not null default false,
  catatan text not null default '',
  diubah_pada timestamptz not null default now()
);
revoke all on table rc_private.lingkungan_email from public, anon, authenticated;

create or replace function rc_private.hanya_email_uji()
 returns boolean
 language sql
 stable
 security definer
 set search_path to ''
as $function$
  -- 20261163040000: true hanya di lingkungan yang ditandai (DEV).
  select coalesce((select hanya_uji from rc_private.lingkungan_email where id), false);
$function$;
revoke all on function rc_private.hanya_email_uji() from public, anon, authenticated;

create or replace function rc_private.email_ditahan_lingkungan(p_konteks jsonb)
 returns boolean
 language sql
 stable
 security definer
 set search_path to ''
as $function$
  -- 20261163040000: surat ditahan bila lingkungan hanya boleh email uji dan surat ini bukan
  -- email uji. Email uji = kirim uji dari layar (konteks uji) atau mode uji Email Pengajuan
  -- (konteks modeUji); keduanya hanya beralamat ke alamat uji yang diisi pengguna.
  select rc_private.hanya_email_uji()
     and not (coalesce(p_konteks->>'uji','') = 'true' or coalesce(p_konteks->>'modeUji','') = 'true');
$function$;
revoke all on function rc_private.email_ditahan_lingkungan(jsonb) from public, anon, authenticated;

-- ---- 1. Aturan status Timetable (logika sama; definisi "dokumen" dan "selesai" berubah) -----
create or replace function rc_private.timetable_status(p_n_dokumen bigint, p_n_done bigint, p_ditandai_na boolean, p_np boolean)
 returns text
 language sql
 immutable
 set search_path to ''
as $function$
  -- 20261163030000: satu-satunya aturan status Timetable.
  -- 20261163040000: p_n_dokumen = semua klaim tidak diarsipkan (Expired ikut),
  --                 p_n_done    = Done + Expired (Expired adalah tahap akhir).
  select case
    when coalesce(p_n_dokumen,0)=0 and (coalesce(p_ditandai_na,false) or coalesce(p_np,false)) then 'Not Achieved'
    when coalesce(p_n_dokumen,0)=0 then 'Not Yet'
    when coalesce(p_n_done,0)=coalesce(p_n_dokumen,0) then 'Completed'
    else 'Compiled' end;
$function$;
revoke all on function rc_private.timetable_status(bigint, bigint, boolean, boolean) from public, anon;
grant execute on function rc_private.timetable_status(bigint, bigint, boolean, boolean) to authenticated;

create or replace function rc_private.timetable_ringkas(p_tahun integer default null)
 returns jsonb
 language sql
 stable
 security definer
 set search_path to ''
as $function$
  -- 20261163030000: KPI papan umum Timetable (seluruh depot aktif) untuk satu Tahun Campaign.
  -- 20261163040000: Expired dihitung sebagai dokumen yang sudah selesai.
  with t as (select coalesce(p_tahun, rc_private.timetable_tahun_baku()) tahun),
  campaign_tahun as (
    select ca.id from public.campaigns ca, t
     where ca.archived_at is null and coalesce(ca.period_start,ca.period_end) is not null
       and extract(year from coalesce(ca.period_start,ca.period_end))::integer = t.tahun
       and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)),
  depot_aktif as (select d.id from public.depots d where d.archived_at is null),
  rekap as (
    select c.depot_id, c.campaign_id,
           count(*) n_dokumen,
           count(*) filter (where c.status in ('done','expired')) n_selesai
      from public.claims c join campaign_tahun k on k.id=c.campaign_id
     where c.archived_at is null group by 1,2),
  dinilai as (
    select rc_private.timetable_status(coalesce(r.n_dokumen,0), coalesce(r.n_selesai,0),
             exists(select 1 from public.timetable_not_achieved na where na.depot_id=d.id and na.campaign_id=k.id),
             rc_private.np_pasangan(d.id,k.id)) status
      from depot_aktif d cross join campaign_tahun k
      left join rekap r on r.depot_id=d.id and r.campaign_id=k.id)
  select jsonb_build_object(
    'tahun', (select tahun from t),
    'campaign', (select count(*) from campaign_tahun),
    'depot', (select count(*) from depot_aktif),
    'total', count(*),
    'completed', count(*) filter (where status='Completed'),
    'notAchieved', count(*) filter (where status='Not Achieved'),
    'compiled', count(*) filter (where status='Compiled'),
    'notYet', count(*) filter (where status='Not Yet'),
    'cleared', count(*) filter (where status in ('Completed','Not Achieved')),
    'clearedPct', case when count(*)=0 then 0 else count(*) filter (where status in ('Completed','Not Achieved'))::numeric/count(*) end,
    'compiledPct', case when count(*)=0 then 0 else count(*) filter (where status='Compiled')::numeric/count(*) end,
    'notYetPct', case when count(*)=0 then 0 else count(*) filter (where status='Not Yet')::numeric/count(*) end)
  from dinilai;
$function$;
revoke all on function rc_private.timetable_ringkas(integer) from public, anon, authenticated;

-- ---- 3. Document Center: filter depot ------------------------------------------------------
drop function if exists public.rc_compilation_list(text, text, text, text, integer, integer);
create or replace function public.rc_compilation_list(p_campaign text DEFAULT ''::text, p_batch text DEFAULT ''::text, p_status text DEFAULT ''::text, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 100, p_depot text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
-- 20261163040000: p_depot (kode depot, '' = semua depot yang terlihat).
declare v jsonb; jml bigint;
begin
 perform rc_private.require_tab('compilation.list');
 if not rc_private.can_access(null,'view_compilation') then
  raise exception 'Access denied' using errcode='42501'; end if;

 select count(*) into jml from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  left join public.customers cu on cu.id=c.customer_id
  left join public.depots d on d.id=c.depot_id
  where (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_depot),'')='' or d.depot_code=btrim(p_depot))
    and (coalesce(btrim(p_status),'')='' or c.status=btrim(p_status))
    and (coalesce(btrim(p_batch),'')='' or btrim(p_batch) in
         (c.batch_upload,c.batch_release,c.batch_claim,c.batch_clearing))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||btrim(p_search)||'%'
         or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||btrim(p_search)||'%');

 select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'id',c.id,'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
   'depot',d.depot_name,'kodeDepot',d.depot_code,
   'kodeToko',coalesce(cu.customer_code,c.source_customer_code),'namaToko',coalesce(cu.customer_name,'Customer Master belum ada'),
   'contactPerson',coalesce(cu.contact_person,''),
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'soStart',coalesce(c.extend_so_start,ca.so_start),'soEnd',coalesce(c.extend_so_end,ca.so_end),
   'billingStart',coalesce(c.extend_billing_start,ca.billing_start),
   'billingEnd',coalesce(c.extend_billing_end,ca.billing_end),
   'statusPajak',coalesce(ca.tax_status,''),
   'subyekPajak',coalesce(c.tax_subject,coalesce(cu.tax_subject,'')),
   'cbNet',c.cb_net,'grossUpCb',c.gross_up,'totTagih',c.total_billing,
   'batchUpload',coalesce(c.batch_upload,''),'batchRelease',coalesce(c.batch_release,''),
   'batchClaim',coalesce(c.batch_claim,''),'batchClearing',coalesce(c.batch_clearing,''),
   'tglUpload',rc_private.legacy_ts(c.uploaded_at),'tglClearing',rc_private.legacy_ts(c.cleared_at),
   'tglProses',case when c.status='done' and c.cleared_at is not null
                    then rc_private.legacy_ts(c.cleared_at) else '-' end,
   'versionNo',c.version_no) as x
  from public.claims c
  join public.depots d on d.id=c.depot_id
  left join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  where (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_depot),'')='' or d.depot_code=btrim(p_depot))
    and (coalesce(btrim(p_status),'')='' or c.status=btrim(p_status))
    and (coalesce(btrim(p_batch),'')='' or btrim(p_batch) in
         (c.batch_upload,c.batch_release,c.batch_claim,c.batch_clearing))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or coalesce(cu.customer_code,c.source_customer_code) ilike '%'||btrim(p_search)||'%'
         or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,100),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 return jsonb_build_object('status','success','rows',v,'total',jml,
  'canArchive',rc_private.boleh_arsip_compilation() /* 20261162130000 */);
end $function$;
revoke all on function public.rc_compilation_list(text, text, text, text, integer, integer, text) from public, anon;
grant execute on function public.rc_compilation_list(text, text, text, text, integer, integer, text) to authenticated, service_role;

create or replace function public.rc_compilation_depots()
 returns jsonb
 language plpgsql
 stable
 set search_path to ''
as $function$
-- 20261163040000: pilihan filter Depot di Document Center, hanya depot yang terlihat akun ini.
declare hasil jsonb;
begin
  perform rc_private.require_tab('compilation.list');
  if not rc_private.can_access(null,'view_compilation') then
    raise exception 'Access denied' using errcode='42501'; end if;
  select jsonb_build_object('status','success',
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'kode', d.depot_code, 'nama', d.depot_name, 'region', coalesce(d.region,''))
      order by d.depot_code), '[]'::jsonb))
  into hasil
  from public.depots d
  where d.archived_at is null and rc_private.can_access(d.id,'view_compilation');
  return hasil;
end $function$;
revoke all on function public.rc_compilation_depots() from public, anon;
grant execute on function public.rc_compilation_depots() to authenticated, service_role;

-- ---- Tambalan berpenjaga MD5 ---------------------------------------------------------------
do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  -- 1. Timetable: matriks dan People Performance.
  ('public.rc_timetable_matrix(jsonb)', '94929a83d9db93e929f2cad3a4385ec8',
   $p$             count(*) filter (where c.status<>'expired') n_hidup,
             count(*) filter (where c.status='done') n_done$p$,
   $p$             count(*) n_hidup, /* 20261163040000: semua dokumen, Expired ikut */
             count(*) filter (where c.status in ('done','expired')) n_done /* Expired = tahap akhir */$p$, 1),
  ('rc_private.people_metrics(uuid[],date)', '1976d88ced32e85319d3bbc9a989dfd8',
   $p$count(*) filter(where status<>'expired') alive,count(*) filter(where status='done') done,$p$,
   $p$count(*) alive,count(*) filter(where status in('done','expired')) done /* 20261163040000: Expired = tahap akhir */,$p$, 1),
  ('public.rc_campaign_np(text)', 'e5f1d49b5e757d67e7f0abad998094fd',
   $p$and c.status <> 'expired' and rc_private.np_pasangan(c.depot_id, ca.id)$p$,
   $p$and rc_private.np_pasangan(c.depot_id, ca.id) /* 20261163040000: Expired ikut dihitung */$p$, 1),
  ('public.rc_campaign_np_simpan(text,jsonb,jsonb,text)', '5676cf06f4db2358011b43c895b36bd4',
   $p$and c.status <> 'expired' and rc_private.np_pasangan(c.depot_id, ca.id)$p$,
   $p$and rc_private.np_pasangan(c.depot_id, ca.id) /* 20261163040000: Expired ikut dihitung */$p$, 1),

  -- 2. Compile: Abbr dari Depot Master.
  ('rc_private.compile_upload(jsonb,uuid)', 'dbf3a5b164ddd7acf562745f2e8a9749',
   $p$  -- Abbr dikunci ke depot. Bila master belum punya, nilai pertama yang sah dipakai.
  if v_abbr='' then v_abbr:=coalesce(v_depot.abbr,''); end if;
  if v_abbr='' then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Abbr wajib diisi untuk depot '||v_depot.depot_code));
   continue; end if;
  if v_depot.abbr is null then
   update public.depots set abbr=v_abbr where id=v_depot.id;
  elsif v_depot.abbr<>v_abbr then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Abbr "'||v_abbr||'" berbeda dengan master depot '||v_depot.depot_code||' ("'||v_depot.abbr||'"). '
       ||'Kosongkan kolom Abbr atau isi '||v_depot.abbr||'.')); /* 20261163010000 */
   continue; end if;$p$,
   $p$  -- 20261163040000: Abbr SELALU dari Depot Master. Template baru tidak punya kolom Abbr;
  -- kolom Abbr pada file template lama diabaikan, dan master depot tidak diisi dari file.
  v_abbr:=coalesce(v_depot.abbr,'');
  if btrim(v_abbr)='' then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Abbr depot '||v_depot.depot_code||' belum diisi di Key Master > Depot Master'));
   continue; end if;$p$, 1),
  ('public.rc_compile_preview(jsonb)', '6c29cb807bfe1317e80c486e312e2beb',
   $p$  if v_abbr='' then v_abbr:=coalesce(v_depot.abbr,''); end if;
  if v_abbr='' then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Abbr wajib diisi untuk depot '||v_depot.depot_code));
   continue; end if;
  if v_depot.abbr is not null and v_depot.abbr<>v_abbr then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Abbr "'||v_abbr||'" berbeda dengan master depot '||v_depot.depot_code||' ("'||v_depot.abbr||'"). '
       ||'Kosongkan kolom Abbr atau isi '||v_depot.abbr||'.'));
   continue; end if;$p$,
   $p$  -- 20261163040000: Abbr SELALU dari Depot Master, sama dengan compile_upload.
  v_abbr:=coalesce(v_depot.abbr,'');
  if btrim(v_abbr)='' then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Abbr depot '||v_depot.depot_code||' belum diisi di Key Master > Depot Master'));
   continue; end if;$p$, 1),

  -- 4. Email: penjaga lingkungan di satu-satunya jalan keluar, dan penanda untuk layar.
  ('rc_private.kirim_satu_email(uuid)', '866ef8798a596bdd80af8525f99052b8',
   $p$  if not found then return jsonb_build_object('status','skipped','sebab','Bukan baris pending'); end if;$p$,
   $p$  if not found then return jsonb_build_object('status','skipped','sebab','Bukan baris pending'); end if;

  -- 20261163040000: lingkungan DEV hanya mengirim email uji. Surat ke penerima sungguhan
  -- ditahan DI SINI, sebelum kredensial dibaca, apa pun setelan email dan alamat depotnya.
  if rc_private.email_ditahan_lingkungan(v.konteks) then
    update public.email_outbox
       set status = 'skipped',
           galat = 'Lingkungan DEV hanya mengirim email uji; surat ke penerima sungguhan tidak dikirim.'
     where id = p_id;
    return jsonb_build_object('status','ditahan',
      'sebab','Lingkungan DEV hanya mengirim email uji; surat ke penerima sungguhan tidak dikirim.');
  end if;$p$, 1),
  ('public.rc_email_status()', '48d332f7cbba144fcb7004b179b9ae53',
   $p$    'depotTotal',(select count(*) from public.depots));$p$,
   $p$    'depotTotal',(select count(*) from public.depots),
    'hanyaUji',rc_private.hanya_email_uji() /* 20261163040000 */);$p$, 1),
  ('public.rc_email_pengajuan_baca()', 'ab3bc2e07928e8e81474b084ef75e26d',
   $p$    'modeUji', coalesce(v_s.mode_uji,false),$p$,
   $p$    'hanyaUji', rc_private.hanya_email_uji(), /* 20261163040000 */
    'modeUji', coalesce(v_s.mode_uji,false),$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261163040000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
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
-- Pemeriksaan (semuanya dibatalkan; tidak ada data yang tertinggal, tidak ada email terkirim)
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; d record; k jsonb; k2 jsonb; m jsonb; p jsonb; harap record; pas record;
  rows jsonb; pv jsonb; up jsonb; a jsonb; b jsonb; c jsonb; v_kode text; v_id uuid; v_hasil jsonb;
  v_doc text; e text := ''; kunci text; v_hasil_n bigint;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  if v_sm is null then raise notice 'Tidak ada System Manager aktif; uji dilewati.'; return; end if;

  -- ---- 1. Timetable ----------------------------------------------------------------------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    -- Angka yang diharapkan dihitung langsung dari klaim dengan aturan baru.
    with t as (select rc_private.timetable_tahun_baku() tahun),
    kt as (select ca.id from public.campaigns ca, t
            where ca.archived_at is null and coalesce(ca.period_start,ca.period_end) is not null
              and extract(year from coalesce(ca.period_start,ca.period_end))::integer = t.tahun
              and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)),
    r as (select c.depot_id, c.campaign_id, count(*) n, count(*) filter (where c.status in ('done','expired')) s
            from public.claims c join kt on kt.id=c.campaign_id where c.archived_at is null group by 1,2)
    select count(*) filter (where coalesce(r.n,0)>0 and r.n=r.s) completed,
           count(*) filter (where coalesce(r.n,0)>0 and r.n<>r.s) compiled
      into harap
      from public.depots dp cross join kt left join r on r.depot_id=dp.id and r.campaign_id=kt.id
     where dp.archived_at is null;
    m := public.rc_timetable_matrix('{}'::jsonb)->'kpi';
    k := rc_private.timetable_ringkas(null);
    p := rc_private.people_metrics(array(select id from public.depots where archived_at is null), (now() at time zone 'Asia/Jakarta')::date)->'timetable';
    if (k->>'completed')::bigint <> harap.completed or (k->>'compiled')::bigint <> harap.compiled then
      e := e || format(' ringkasan completed/compiled %s/%s, harap %s/%s;', k->>'completed', k->>'compiled', harap.completed, harap.compiled); end if;
    foreach kunci in array array['total','completed','compiled','notYet','notAchieved','cleared','campaign','depot'] loop
      if (m->>kunci) is distinct from (k->>kunci) then e := e || format(' modul %s=%s, ringkasan %s;', kunci, m->>kunci, k->>kunci); end if;
    end loop;
    if (p->>'total') <> (m->>'total') or (p->>'not_yet') <> (m->>'notYet') or (p->>'compiled') <> (m->>'compiled')
       or (p->>'completed') <> (m->>'completed') or (p->>'not_achieved') <> (m->>'notAchieved') then
      e := e || format(' People Performance %s, modul %s;', p, m); end if;

    -- Satu pasangan Compiled: seluruh dokumennya yang belum Done dijadikan Expired -> Completed.
    select c.depot_id, c.campaign_id into pas
      from public.claims c
      join public.depots dp on dp.id=c.depot_id and dp.archived_at is null
      join public.campaigns ca on ca.id=c.campaign_id and ca.archived_at is null
     where c.archived_at is null and coalesce(ca.period_start,ca.period_end) is not null
       and extract(year from coalesce(ca.period_start,ca.period_end))::integer = (k->>'tahun')::integer
       and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)
     group by 1,2 having count(*) filter (where c.status not in ('done','expired')) > 0
     order by 1,2 limit 1;
    if pas.depot_id is not null then
      update public.claims set status='expired' where depot_id=pas.depot_id and campaign_id=pas.campaign_id
         and archived_at is null and status<>'done';
      k2 := rc_private.timetable_ringkas(null);
      if (k2->>'completed')::bigint <> (k->>'completed')::bigint + 1 or (k2->>'compiled')::bigint <> (k->>'compiled')::bigint - 1 then
        e := e || format(' pasangan Done+Expired bukan Completed (sebelum %s, sesudah %s);', k, k2); end if;
    end if;
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then e := e || ' timetable galat: ' || sqlerrm; end if;
  end;

  -- ---- 2. Compile: Abbr dari master ---------------------------------------------------------
  select dp.id depot_id, dp.depot_code, dp.abbr, cu.customer_code, ca.id campaign_id, ca.campaign_code into d
    from public.customers cu
    join public.customer_depots cd on cd.customer_id = cu.id
    join public.depots dp on dp.id = cd.depot_id and dp.archived_at is null and dp.abbr is not null
    cross join lateral (select ca.* from public.campaigns ca
                         where ca.status = 'active' and ca.archived_at is null
                           and not exists(select 1 from public.claims c where c.campaign_id = ca.id and c.customer_id = cu.id)
                           and not rc_private.np_pasangan(dp.id, ca.id)
                           and not exists(select 1 from public.timetable_not_achieved na where na.depot_id = dp.id and na.campaign_id = ca.id)
                         order by ca.campaign_code limit 1) ca
   where cu.archived_at is null
   order by cu.customer_code, ca.campaign_code limit 1;
  if d.depot_code is null then
    raise notice 'Tidak ada fixture compile; uji Abbr dilewati.';
  else
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
      rows := jsonb_build_array(jsonb_build_object('kodeDepot', d.depot_code, 'abbr', 'SALAH',
        'codeCampaign', d.campaign_code, 'custCode', d.customer_code, 'netValue', '1000000', 'cbNet', '1000'));
      -- Master tanpa Abbr: ditolak per baris, dan master TIDAK diisi dari file.
      update public.depots set abbr = null where id = d.depot_id;
      execute 'set local role authenticated';
      pv := public.rc_compile_preview(rows);
      execute 'reset role';
      up := rc_private.compile_upload(rows, gen_random_uuid());
      if (pv->>'siap')::int <> 0 or (up->>'dibuat')::int <> 0 or pv->'ditolak' <> up->'ditolak'
         or not exists(select 1 from jsonb_array_elements(up->'ditolak') x where x->>'alasan' ~ 'belum diisi di Key Master > Depot Master') then
        e := e || format(' master tanpa Abbr: pratinjau %s | simpan %s;', pv, up); end if;
      if (select abbr from public.depots where id = d.depot_id) is not null then e := e || ' master Abbr terisi dari file;'; end if;
      -- Master ber-Abbr: kolom Abbr file (berbeda) diabaikan, No Doc memakai Abbr master.
      update public.depots set abbr = d.abbr where id = d.depot_id;
      execute 'set local role authenticated';
      pv := public.rc_compile_preview(rows);
      execute 'reset role';
      up := rc_private.compile_upload(rows, gen_random_uuid());
      v_doc := up->'dokumen'->0->>'noDoc';
      if (pv->>'siap')::int <> 1 or (up->>'dibuat')::int <> 1 or jsonb_array_length(pv->'ditolak') <> 0 then
        e := e || format(' Abbr file diabaikan: pratinjau %s | simpan %s;', pv, up); end if;
      if coalesce(v_doc,'') !~ ('/' || d.abbr || '/') or v_doc ~ 'SALAH' then e := e || format(' No Doc %s tidak memakai Abbr master %s;', v_doc, d.abbr); end if;
      if (select abbr from public.depots where id = d.depot_id) is distinct from d.abbr then e := e || ' master Abbr berubah;'; end if;
      raise exception 'UJI_SELESAI';
    exception when others then
      if sqlerrm <> 'UJI_SELESAI' then e := e || ' compile galat: ' || sqlerrm; end if;
    end;
  end if;

  -- ---- 3. Document Center: filter depot ------------------------------------------------------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    select dp.depot_code into v_kode from public.claims c join public.depots dp on dp.id=c.depot_id
     where c.archived_at is null group by 1 order by count(*) desc limit 1;
    -- Dijalankan sebagai pengguna aplikasi; angka pembandingnya dihitung dengan hak yang sama.
    execute 'set local role authenticated';
    a := public.rc_compilation_list('', '', '', '', 0, 500);
    b := public.rc_compilation_list(p_depot => v_kode, p_limit => 500);
    c := public.rc_compilation_depots();
    select count(*) into v_hasil_n from public.claims cl join public.depots dp on dp.id=cl.depot_id
      join public.campaigns ca on ca.id=cl.campaign_id where dp.depot_code = v_kode;
    execute 'reset role';
    if a->>'status' <> 'success' or b->>'status' <> 'success' or c->>'status' <> 'success' then e := e || ' Document Center tidak sukses;'; end if;
    if (b->>'total')::bigint <> v_hasil_n then
      e := e || format(' filter depot %s total %s, harap %s;', v_kode, b->>'total', v_hasil_n); end if;
    if (b->>'total')::bigint > (a->>'total')::bigint then e := e || ' total terfilter melebihi total;'; end if;
    if exists(select 1 from jsonb_array_elements(b->'rows') x where x->>'kodeDepot' <> v_kode) then e := e || ' baris di luar depot terpilih;'; end if;
    if jsonb_array_length(c->'rows') <> (select count(*) from public.depots where archived_at is null) then
      e := e || format(' daftar depot %s, depot aktif %s;', jsonb_array_length(c->'rows'), (select count(*) from public.depots where archived_at is null)); end if;
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then e := e || ' Document Center galat: ' || sqlerrm; end if;
  end;

  -- ---- 4. Email: penjaga lingkungan -----------------------------------------------------------
  -- Hanya jalur yang DITAHAN yang memanggil kirim_satu_email; jalur yang lolos diuji lewat
  -- predikatnya saja, supaya uji ini tidak pernah mengirim apa pun di lingkungan mana pun.
  begin
    insert into rc_private.lingkungan_email(id, hanya_uji) values (true, true)
    on conflict (id) do update set hanya_uji = true;
    insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, konteks)
    values ('pengajuan', array['uji-tidak-dikirim@example.invalid'], '{}', 'UJI PENJAGA', '<p>uji</p>', '{}'::jsonb)
    returning id into v_id;
    v_hasil := rc_private.kirim_satu_email(v_id);
    if v_hasil->>'status' <> 'ditahan' or (select status from public.email_outbox where id = v_id) <> 'skipped' then
      e := e || format(' surat sungguhan tidak ditahan: %s;', v_hasil); end if;
    if rc_private.email_ditahan_lingkungan('{"uji":true}'::jsonb) or rc_private.email_ditahan_lingkungan('{"modeUji":true}'::jsonb)
       or not rc_private.email_ditahan_lingkungan('{"aksi":"submit","modeUji":false}'::jsonb) then
      e := e || ' predikat email uji salah;'; end if;
    update rc_private.lingkungan_email set hanya_uji = false where id;
    if rc_private.email_ditahan_lingkungan('{}'::jsonb) then e := e || ' tanpa tanda DEV surat tetap ditahan;'; end if;
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then e := e || ' email galat: ' || sqlerrm; end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
