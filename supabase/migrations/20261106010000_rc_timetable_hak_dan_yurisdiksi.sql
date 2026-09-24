-- ==========================================================================================
-- Timetable: izin yang benar, dan depot yang sesuai yurisdiksi
-- ==========================================================================================
-- DUA CACAT YANG DIPERBAIKI, KEDUANYA TERBUKTI DARI DATA YANG ADA
--
-- 1. MODULNYA TIDAK DAPAT DIBUKA SIAPA PUN SELAIN SYSTEM MANAGER
--    rc_timetable_matrix menuntut izin 'view_report' - izin modul REPORT. Padahal Access
--    Management memberikan 'manage_timetable' ketika sebuah akun diberi modul Timetable.
--    Akibatnya akun yang jelas-jelas sudah diberi Timetable tetap ditolak.
--
--    Diuji atas kelima akun aktif: keempat admin ditolak dengan "Tidak punya hak melihat
--    Timetable", termasuk ANIADMPTI yang memegang 'manage_timetable'. Hanya System Manager
--    yang lolos. Ini persis pola yang pernah terjadi pada modul Report: konsol memberikan satu
--    izin sementara server memeriksa izin yang lain, dan layar menyalahkan penggunanya.
--
--    Sekarang gerbangnya menerima 'manage_timetable' MAUPUN 'view_report'. Keduanya masuk akal:
--    yang diberi Timetable jelas memerlukannya, dan yang diberi Report memang membaca angka
--    yang sama dari sudut lain.
--
-- 2. SETIAP ORANG MELIHAT SELURUH 52 DEPOT
--    depot_terpilih hanya menyaring menurut region dan depot pada filter layar - tidak ada
--    pemeriksaan yurisdiksi sama sekali. Karena fungsinya SECURITY DEFINER, RLS pada tabel
--    depots pun tidak ikut campur. Jadi begitu seseorang lolos gerbang, ia melihat semua depot.
--
--    Aturan pemilik: System Manager dan Supervisor melihat semuanya; selain itu hanya depot
--    sendiri atau depot yang di-tagging kepadanya. Itulah yang dipasang di sini, memakai
--    rc_private.can_access(depot) yang sudah menjadi satu-satunya penafsiran yurisdiksi di
--    seluruh sistem ini.
--
--    Peringkat "Top Not Yet" pun ikut dibatasi. Sebelumnya ia sengaja lintas wilayah, meniru
--    sistem lama; tetapi memperlihatkan nama depot lain kepada admin yang tidak boleh melihat
--    depot itu adalah kebocoran, betapapun kecil angkanya.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function public.rc_timetable_matrix(p_filter jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_region text; v_depot text; v_campaign text; v_tanggal date;
begin
  -- Izin Timetable ATAU izin Report; keduanya membuka layar yang sama. Sebelumnya hanya
  -- 'view_report' yang diterima, sehingga akun yang justru diberi modul Timetable tetap ditolak.
  if not rc_private.can_access(null,'manage_timetable')
     and not rc_private.can_access(null,'view_report')
     and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat Timetable' using errcode='42501'; end if;

  v_region   := nullif(btrim(coalesce(p_filter->>'region','')),'');
  v_depot    := nullif(btrim(coalesce(p_filter->>'depot','')),'');
  v_campaign := nullif(btrim(coalesce(p_filter->>'campaign','')),'');
  v_tanggal  := coalesce(nullif(btrim(coalesce(p_filter->>'tanggal','')),'')::date, current_date);

  return (
    with campaign_aktif as (
      select ca.id, ca.campaign_code, ca.campaign_name, ca.period_start, ca.period_end
        from public.campaigns ca
       where ca.period_start is not null
         and ca.period_start <= v_tanggal
         and coalesce(ca.period_end, v_tanggal) >= v_tanggal
         and not exists(select 1 from public.excluded_campaigns x where x.campaign_id = ca.id)
         and (v_campaign is null or ca.campaign_code = v_campaign)
    ),
    -- Yurisdiksi. Supervisor dan System Manager melihat seluruh depot; selain itu hanya depot
    -- sendiri atau yang di-tagging. Sebelumnya tidak ada pemeriksaan sama sekali di sini, dan
    -- karena fungsinya SECURITY DEFINER, RLS pada depots pun tidak ikut campur - siapa pun
    -- yang lolos gerbang melihat seluruh 52 depot.
    depot_boleh as (
      select d.id, d.depot_code, d.depot_name, coalesce(d.region,'') as region
        from public.depots d
       where rc_private.is_manager() or rc_private.can_access(d.id)
    ),
    depot_terpilih as (
      select d.id, d.depot_code, d.depot_name, d.region
        from depot_boleh d
       where (v_region is null or d.region = v_region)
         and (v_depot is null or d.depot_code = v_depot)
    ),
    rekap as (
      select c.depot_id, c.campaign_id,
             count(*) filter (where c.status <> 'expired') as n_hidup,
             count(*) filter (where c.status = 'done')     as n_done
        from public.claims c where c.archived_at is null
       group by c.depot_id, c.campaign_id
    ),
    dinilai as (
      select d.id as depot_id, d.depot_code, d.depot_name, d.region,
             k.id as campaign_id, k.campaign_code, k.campaign_name,
             case
               when coalesce(r.n_hidup,0) = 0 and exists(select 1 from public.timetable_not_achieved na
                     where na.depot_id=d.id and na.campaign_id=k.id) then 'Not Achieved'
               when coalesce(r.n_hidup,0) = 0 then 'Not Yet'
               when coalesce(r.n_done,0) = coalesce(r.n_hidup,0) then 'Completed'
               else 'Compiled'
             end as status
        from depot_terpilih d
        cross join campaign_aktif k
        left join rekap r on r.depot_id=d.id and r.campaign_id=k.id
    ),
    -- Seluruh depot YANG BOLEH DILIHAT, tanpa filter layar, khusus untuk peringkat Not Yet.
    -- Sistem lama menghitungnya lintas wilayah; di sini batas yurisdiksi tetap dipasang, karena
    -- peringkat yang memuat nama depot di luar yurisdiksi seseorang adalah kebocoran meski yang
    -- bocor hanya angka.
    global as (
      select d.id as depot_id, d.depot_code, d.depot_name,
             case when coalesce(r.n_hidup,0) = 0
                    and not exists(select 1 from public.timetable_not_achieved na
                                    where na.depot_id=d.id and na.campaign_id=k.id)
                  then 1 else 0 end as not_yet
        from depot_boleh d
        cross join campaign_aktif k
        left join rekap r on r.depot_id=d.id and r.campaign_id=k.id
    )
    select jsonb_build_object(
      'status','success',
      'tanggal', v_tanggal,
      'campaignAktif', (select count(*) from campaign_aktif),
      'campaignTanpaPeriode', (select count(*) from public.campaigns where period_start is null),
      'campaignDikecualikan', (select count(*) from public.excluded_campaigns),

      'kpi', (select jsonb_build_object(
          'total',        count(*),
          'completed',    count(*) filter (where status='Completed'),
          'notAchieved',  count(*) filter (where status='Not Achieved'),
          'compiled',     count(*) filter (where status='Compiled'),
          'notYet',       count(*) filter (where status='Not Yet'),
          'cleared',      count(*) filter (where status in('Completed','Not Achieved')),
          'clearedPct',   case when count(*)=0 then 0 else
            count(*) filter (where status in('Completed','Not Achieved'))::numeric/count(*) end,
          'compiledPct',  case when count(*)=0 then 0 else
            count(*) filter (where status='Compiled')::numeric/count(*) end,
          'notYetPct',    case when count(*)=0 then 0 else
            count(*) filter (where status='Not Yet')::numeric/count(*) end,
          'campaign',     (select count(*) from campaign_aktif),
          'depot',        (select count(*) from depot_terpilih)
        ) from dinilai),

      'perRegion', (select coalesce(jsonb_agg(jsonb_build_object(
          'region', case when g.region='' then '(belum diisi)' else g.region end,
          'total',g.total,'cleared',g.cleared,'compiled',g.compiled,'notYet',g.not_yet,
          'clearedPct', case when g.total=0 then 0 else round(g.cleared::numeric/g.total*100,1) end)
          order by g.region),'[]'::jsonb)
        from (select region, count(*) total,
                     count(*) filter (where status in('Completed','Not Achieved')) cleared,
                     count(*) filter (where status='Compiled') compiled,
                     count(*) filter (where status='Not Yet') not_yet
                from dinilai group by region) g),

      'perCampaign', (select coalesce(jsonb_agg(jsonb_build_object(
          'kode',c.campaign_code,'nama',c.campaign_name,
          'total',c.total,'cleared',c.cleared,'compiled',c.compiled,'notYet',c.not_yet,
          'clearedPct', case when c.total=0 then 0 else round(c.cleared::numeric/c.total*100,1) end)
          order by c.campaign_code),'[]'::jsonb)
        from (select campaign_code, campaign_name, count(*) total,
                     count(*) filter (where status in('Completed','Not Achieved')) cleared,
                     count(*) filter (where status='Compiled') compiled,
                     count(*) filter (where status='Not Yet') not_yet
                from dinilai group by campaign_code, campaign_name) c),

      'topNotYet', (select coalesce(jsonb_agg(jsonb_build_object(
          'kodeDepot',t.depot_code,'namaDepot',t.depot_name,'notYet',t.n)
          order by t.n desc, t.depot_code),'[]'::jsonb)
        from (select depot_code, depot_name, sum(not_yet) n from global
               group by depot_code, depot_name having sum(not_yet) > 0
               order by 3 desc limit 10) t),

      'campaigns', (select coalesce(jsonb_agg(jsonb_build_object(
          'kode',campaign_code,'nama',campaign_name,
          'mulai',period_start,'selesai',period_end) order by campaign_code),'[]'::jsonb)
        from campaign_aktif),

      'depots', (select coalesce(jsonb_agg(jsonb_build_object(
          'kodeDepot',t.depot_code,'namaDepot',t.depot_name,
          'region', case when t.region='' then '(belum diisi)' else t.region end,
          'sel', t.sel,
          'notYet',t.not_yet,'compiled',t.compiled,'completed',t.completed,'notAchieved',t.not_achieved,
          'cleared',t.completed + t.not_achieved,
          'compilePersen', case when t.total=0 then null
            else round(((t.compiled + t.completed + t.not_achieved)::numeric / t.total) * 100, 1) end,
          'completedPersen', case when t.total=0 then null
            else round(((t.completed + t.not_achieved)::numeric / t.total) * 100, 1) end)
          order by t.depot_code),'[]'::jsonb)
        from (select depot_code, depot_name, region, count(*) total,
                     count(*) filter (where status='Not Yet')      not_yet,
                     count(*) filter (where status='Compiled')     compiled,
                     count(*) filter (where status='Completed')    completed,
                     count(*) filter (where status='Not Achieved') not_achieved,
                     jsonb_object_agg(campaign_code, status) sel
                from dinilai group by depot_code, depot_name, region) t),

      'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')
    )
  );
end $fn$;
revoke all on function public.rc_timetable_matrix(jsonb) from public,anon;
grant execute on function public.rc_timetable_matrix(jsonb) to authenticated;

-- Daftar Not Achieved mengikuti gerbang yang sama, supaya tidak ada keadaan di mana matrixnya
-- terbuka sementara kartu Detail Not Achieved di bawahnya menolak.
create or replace function public.rc_timetable_not_achieved()
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v jsonb; nama jsonb;
begin
  if not rc_private.can_access(null,'manage_timetable')
     and not rc_private.can_access(null,'view_report')
     and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat Timetable' using errcode='42501'; end if;
  nama := rc_private.peta_nama_pelaku();
  select coalesce(jsonb_agg(x order by x->>'kodeDepot', x->>'kodeCampaign'),'[]'::jsonb) into v from (
    select jsonb_build_object(
      'kodeDepot',d.depot_code,'namaDepot',d.depot_name,'region',coalesce(d.region,''),
      'kodeCampaign',c.campaign_code,'namaCampaign',c.campaign_name,
      'ditandaiOleh',coalesce(nama->>(na.marked_by::text),''),
      'ditandaiPada',to_char(na.marked_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
      'catatan',coalesce(na.note,''),
      'adaKlaim',exists(select 1 from public.claims cl
                         where cl.depot_id=na.depot_id and cl.campaign_id=na.campaign_id
                           and cl.archived_at is null)) as x
      from public.timetable_not_achieved na
      join public.depots d on d.id=na.depot_id
      join public.campaigns c on c.id=na.campaign_id
     where rc_private.is_manager() or rc_private.can_access(na.depot_id)) t;
  return jsonb_build_object('status','success','rows',v,
    'bolehBatalkan',rc_private.is_osc_ke_atas());
end $fn$;
revoke all on function public.rc_timetable_not_achieved() from public,anon;
grant execute on function public.rc_timetable_not_achieved() to authenticated;

create or replace function rc_private.marker_20261106() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261106() from public,anon;
grant execute on function rc_private.marker_20261106() to authenticated;

select 'Hak dan yurisdiksi Timetable diperbaiki' as hasil,
 (select count(*) from public.user_permissions where permission_code='manage_timetable') as punya_izin_timetable,
 (select count(*) from public.user_permissions where permission_code='view_report') as punya_izin_report;
