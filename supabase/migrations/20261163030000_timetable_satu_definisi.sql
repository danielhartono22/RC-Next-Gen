-- ==========================================================================================
-- Timetable: satu definisi untuk modul, email ringkasan, dan People Performance
-- ==========================================================================================
-- Pemilik, 13 Oktober 2026: "sinkronisasi timetable masih tidak sinkron."
--
-- 20261162210000/20261162220000 sudah menyamakan komponen DI DALAM modul Timetable (KPI,
-- grafik, Top 10, tabel, matriks) memakai Tahun Campaign. Dua tempat lain masih memakai
-- definisi lamanya sendiri, sehingga angkanya tidak pernah sama dengan modul. Diukur di prod
-- 13 Oktober 2026, data yang sama:
--
--   modul Timetable (Tahun 2026)      39 campaign  x 58 depot = 2.262 pasangan, Not Yet 1.816
--   People Performance (hari ini)     11 campaign  -> 638 pasangan, Not Yet 637
--   email ringkasan Timetable         "Campaign aktif" 11, "Depot dipantau" termasuk depot
--                                      diarsipkan, Not Achieved = semua tanda
--
-- Sebabnya: People Performance dan email memilih campaign yang SEDANG BERLAKU pada satu
-- tanggal, sedangkan modul memilih campaign menurut Tahun Campaign (tahun Periode Start,
-- Periode End sebagai cadangan). Email juga menghitung depot yang sudah diarsipkan.
--
-- SEKARANG
--   rc_private.timetable_status(n_dokumen, n_done, ditandai_na, np)
--       aturan status satu-satunya, dipakai matriks, ringkasan, dan People Performance:
--         tanpa dokumen hidup + ditandai Not Achieved / Not Participating -> Not Achieved
--         tanpa dokumen hidup                                             -> Not Yet
--         semua dokumen hidup Done                                        -> Completed
--         selain itu                                                      -> Compiled
--       "Dokumen hidup" = bukan Expired, tetap sesuai PRD sistem lama (Expired DIABAIKAN).
--   rc_private.timetable_ringkas(tahun)   KPI seluruh depot aktif untuk satu Tahun Campaign,
--       definisi yang sama persis dengan papan umum modul. Dipakai email ringkasan.
--   rc_timetable_matrix                  memakai timetable_status (logika tidak berubah).
--   rc_private.people_metrics            campaign = Tahun Campaign dari tanggal acuan, depot
--       arsip tidak dihitung, status lewat timetable_status.
--   rc_email_susun('timetable')          angka dari timetable_ringkas, dengan rincian yang sama
--       seperti kartu modul.
--
-- Ditambal dengan penjaga MD5 pra-citra (13 Oktober 2026). rc_email_susun diukur sesudah
-- 20261163020000, yang harus dipasang lebih dulu.
-- ==========================================================================================

create or replace function rc_private.timetable_status(p_n_dokumen bigint, p_n_done bigint, p_ditandai_na boolean, p_np boolean)
 returns text
 language sql
 immutable
 set search_path to ''
as $function$
  -- 20261163030000: satu-satunya aturan status Timetable.
  select case
    when coalesce(p_n_dokumen,0)=0 and (coalesce(p_ditandai_na,false) or coalesce(p_np,false)) then 'Not Achieved'
    when coalesce(p_n_dokumen,0)=0 then 'Not Yet'
    when coalesce(p_n_done,0)=coalesce(p_n_dokumen,0) then 'Completed'
    else 'Compiled' end;
$function$;
revoke all on function rc_private.timetable_status(bigint, bigint, boolean, boolean) from public, anon;
grant execute on function rc_private.timetable_status(bigint, bigint, boolean, boolean) to authenticated;

create or replace function rc_private.timetable_tahun_baku()
 returns integer
 language sql
 stable
 set search_path to ''
as $function$
  -- Tahun bawaan modul Timetable: tahun Jakarta saat ini bila ada campaign-nya, selain itu
  -- tahun terbaru yang ada (sama dengan rc_timetable_matrix tanpa filter).
  with tahun as (
    select distinct extract(year from coalesce(ca.period_start,ca.period_end))::integer nilai
      from public.campaigns ca
     where ca.archived_at is null and coalesce(ca.period_start,ca.period_end) is not null
       and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id))
  select coalesce(min(nilai) filter (where nilai=extract(year from now() at time zone 'Asia/Jakarta')::integer), max(nilai))
    from tahun;
$function$;
revoke all on function rc_private.timetable_tahun_baku() from public, anon, authenticated;

create or replace function rc_private.timetable_ringkas(p_tahun integer default null)
 returns jsonb
 language sql
 stable
 security definer
 set search_path to ''
as $function$
  -- 20261163030000: KPI papan umum Timetable (seluruh depot aktif) untuk satu Tahun Campaign.
  with t as (select coalesce(p_tahun, rc_private.timetable_tahun_baku()) tahun),
  campaign_tahun as (
    select ca.id from public.campaigns ca, t
     where ca.archived_at is null and coalesce(ca.period_start,ca.period_end) is not null
       and extract(year from coalesce(ca.period_start,ca.period_end))::integer = t.tahun
       and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)),
  depot_aktif as (select d.id from public.depots d where d.archived_at is null),
  rekap as (
    select c.depot_id, c.campaign_id,
           count(*) filter (where c.status<>'expired') n_hidup,
           count(*) filter (where c.status='done') n_done
      from public.claims c join campaign_tahun k on k.id=c.campaign_id
     where c.archived_at is null group by 1,2),
  dinilai as (
    select rc_private.timetable_status(coalesce(r.n_hidup,0), coalesce(r.n_done,0),
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

do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  -- Matriks: dua blok status yang sama persis diganti satu fungsi aturan.
  ('public.rc_timetable_matrix(jsonb)', '83c4529ba0bd6a0d0d1d53711ef6ba90',
   $p$             case
               when coalesce(r.n_hidup,0)=0 and exists(
                 select 1 from public.timetable_not_achieved na
                  where na.depot_id=d.id and na.campaign_id=k.id
               ) then 'Not Achieved'
               when coalesce(r.n_hidup,0)=0 and rc_private.np_pasangan(d.id,k.id) then 'Not Achieved'
               when coalesce(r.n_hidup,0)=0 then 'Not Yet'
               when coalesce(r.n_done,0)=coalesce(r.n_hidup,0) then 'Completed'
               else 'Compiled'
             end status$p$,
   $p$             rc_private.timetable_status(coalesce(r.n_hidup,0), coalesce(r.n_done,0), /* 20261163030000 */
               exists(select 1 from public.timetable_not_achieved na where na.depot_id=d.id and na.campaign_id=k.id),
               rc_private.np_pasangan(d.id,k.id)) status$p$, 2),

  -- People Performance: Tahun Campaign dari tanggal acuan, depot aktif, aturan yang sama.
  ('rc_private.people_metrics(uuid[],date)', '2465c52d4b17fb8fe422b2ec1c127894',
   $p$campaigns as (select ca.id from public.campaigns ca where ca.archived_at is null and ca.period_start<=p_asof and coalesce(ca.period_end,p_asof)>=p_asof$p$,
   $p$campaigns as (select ca.id from public.campaigns ca where ca.archived_at is null /* 20261163030000: Tahun Campaign, sama dengan modul Timetable */
 and coalesce(ca.period_start,ca.period_end) is not null and extract(year from coalesce(ca.period_start,ca.period_end))::integer=extract(year from p_asof)::integer$p$, 1),
  ('rc_private.people_metrics(uuid[],date)', '2465c52d4b17fb8fe422b2ec1c127894',
   $p$from public.depots d cross join campaigns ca where d.id=any(p_depots) and rc_private.can_access(d.id)),$p$,
   $p$from public.depots d cross join campaigns ca where d.id=any(p_depots) and d.archived_at is null and rc_private.can_access(d.id)),$p$, 1),
  ('rc_private.people_metrics(uuid[],date)', '2465c52d4b17fb8fe422b2ec1c127894',
   $p$ classified as (select case when coalesce(r.unknown,0)>0 then 'Unknown'
 when coalesce(r.alive,0)=0 and exists(select 1 from public.timetable_not_achieved n where n.depot_id=x.depot_id and n.campaign_id=x.campaign_id and n.marked_at<(p_asof+1)::timestamp at time zone 'Asia/Jakarta') then 'Not Achieved'
 when coalesce(r.alive,0)=0 and rc_private.np_pasangan(x.depot_id,x.campaign_id) /* 20261162170000 */ then 'Not Achieved'
 when coalesce(r.alive,0)=0 then 'Not Yet' when r.done=r.alive then 'Completed' else 'Compiled' end status$p$,
   $p$ classified as (select case when coalesce(r.unknown,0)>0 then 'Unknown'
 else rc_private.timetable_status(coalesce(r.alive,0), coalesce(r.done,0),
   exists(select 1 from public.timetable_not_achieved n where n.depot_id=x.depot_id and n.campaign_id=x.campaign_id and n.marked_at<(p_asof+1)::timestamp at time zone 'Asia/Jakarta'),
   rc_private.np_pasangan(x.depot_id,x.campaign_id)) end status$p$, 1),

  -- Email ringkasan Timetable: angka dari timetable_ringkas.
  ('public.rc_email_susun(text,boolean,text)', '9f2c9f0f26904c3b890216aa65c72103',
   $p$  v_kpi jsonb; v_top jsonb; v_status text; v_region text;$p$,
   $p$  v_kpi jsonb; v_top jsonb; v_status text; v_region text;
  v_tt jsonb; -- 20261163030000$p$, 1),
  ('public.rc_email_susun(text,boolean,text)', '9f2c9f0f26904c3b890216aa65c72103',
   $p$  elsif v_jenis = 'timetable' then$p$,
   $p$  elsif v_jenis = 'timetable' then
    -- 20261163030000: definisi yang sama dengan papan umum modul Timetable.
    v_tt := rc_private.timetable_ringkas(null);$p$, 1),
  ('public.rc_email_susun(text,boolean,text)', '9f2c9f0f26904c3b890216aa65c72103',
   $p$per '
        ||rc_private.tgl_panjang(now())||'.</p>'$p$,
   $p$per '
        ||rc_private.tgl_panjang(now())||', Tahun Campaign <strong>'||(v_tt->>'tahun')||'</strong>.</p>'$p$, 1),
  ('public.rc_email_susun(text,boolean,text)', '9f2c9f0f26904c3b890216aa65c72103',
   $p$">Campaign aktif</td>'$p$,
   $p$">Campaign</td>'$p$, 1),
  ('public.rc_email_susun(text,boolean,text)', '9f2c9f0f26904c3b890216aa65c72103',
   $p$||(select count(*) from public.campaigns
            where period_start is not null and period_start<=current_date
              and coalesce(period_end,current_date)>=current_date
              and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=campaigns.id))$p$,
   $p$||rc_private.angka((v_tt->>'campaign')::numeric)$p$, 1),
  ('public.rc_email_susun(text,boolean,text)', '9f2c9f0f26904c3b890216aa65c72103',
   $p$||(select count(*) from public.depots)||'</td></tr>'$p$,
   $p$||rc_private.angka((v_tt->>'depot')::numeric)||'</td></tr>'
      ||'<tr><td style="font-size:13px;padding:6px 16px 6px 0;">Kombinasi Depot x Campaign</td>'
        ||'<td style="font-size:13px;padding:6px 0;font-weight:bold;">'||rc_private.angka((v_tt->>'total')::numeric)||'</td></tr>'
      ||'<tr><td style="font-size:13px;padding:6px 16px 6px 0;">Cleared (Completed + Not Achieved)</td>'
        ||'<td style="font-size:13px;padding:6px 0;font-weight:bold;color:#1a7f37;">'||rc_private.angka((v_tt->>'cleared')::numeric)
        ||' ('||rc_private.persen((v_tt->>'clearedPct')::numeric)||')</td></tr>'
      ||'<tr><td style="font-size:13px;padding:6px 16px 6px 0;">Completed</td>'
        ||'<td style="font-size:13px;padding:6px 0;font-weight:bold;">'||rc_private.angka((v_tt->>'completed')::numeric)||'</td></tr>'
      ||'<tr><td style="font-size:13px;padding:6px 16px 6px 0;">Compiled</td>'
        ||'<td style="font-size:13px;padding:6px 0;font-weight:bold;color:#f97316;">'||rc_private.angka((v_tt->>'compiled')::numeric)
        ||' ('||rc_private.persen((v_tt->>'compiledPct')::numeric)||')</td></tr>'
      ||'<tr><td style="font-size:13px;padding:6px 16px 6px 0;">Not Yet</td>'
        ||'<td style="font-size:13px;padding:6px 0;font-weight:bold;color:#EA4335;">'||rc_private.angka((v_tt->>'notYet')::numeric)
        ||' ('||rc_private.persen((v_tt->>'notYetPct')::numeric)||')</td></tr>'$p$, 1),
  ('public.rc_email_susun(text,boolean,text)', '9f2c9f0f26904c3b890216aa65c72103',
   $p$||(select count(*) from public.timetable_not_achieved)||'</td></tr></table>'$p$,
   $p$||rc_private.angka((v_tt->>'notAchieved')::numeric)||'</td></tr></table>'$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261163030000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
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
-- Pemeriksaan: untuk System Manager (seluruh depot), modul, ringkasan email, dan People
-- Performance memberi angka yang SAMA untuk Tahun Campaign bawaan.
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; m jsonb; r jsonb; p jsonb; s jsonb; e text := ''; k text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  if v_sm is null then raise notice 'Tidak ada System Manager aktif; uji dilewati.'; return; end if;
  if rc_private.timetable_status(0,0,true,false) <> 'Not Achieved' or rc_private.timetable_status(0,0,false,true) <> 'Not Achieved'
     or rc_private.timetable_status(0,0,false,false) <> 'Not Yet' or rc_private.timetable_status(3,3,true,true) <> 'Completed'
     or rc_private.timetable_status(3,1,false,false) <> 'Compiled' then e := e || ' aturan status;'; end if;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    m := public.rc_timetable_matrix('{}'::jsonb)->'kpi';
    r := rc_private.timetable_ringkas(null);
    p := rc_private.people_metrics(array(select id from public.depots where archived_at is null), (now() at time zone 'Asia/Jakarta')::date)->'timetable';
    foreach k in array array['total','completed','compiled','notYet','notAchieved','cleared','campaign','depot'] loop
      if (m->>k) is distinct from (r->>k) then e := e || format(' modul %s=%s, ringkasan %s;', k, m->>k, r->>k); end if;
    end loop;
    if (p->>'total') <> (m->>'total') or (p->>'not_yet') <> (m->>'notYet') or (p->>'compiled') <> (m->>'compiled')
       or (p->>'completed') <> (m->>'completed') or (p->>'not_achieved') <> (m->>'notAchieved') then
      e := e || format(' People Performance %s, modul %s;', p, m); end if;
    s := public.rc_email_susun('timetable', false, '');
    if coalesce(s->>'isiHtml','') !~ ('Tahun Campaign <strong>' || (r->>'tahun')) then e := e || ' email tanpa Tahun Campaign;'; end if;
    if coalesce(s->>'isiHtml','') !~ ('>' || rc_private.angka((r->>'total')::numeric) || '<') then e := e || ' email: jumlah kombinasi tidak sama;'; end if;
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then e := e || ' galat: ' || sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
