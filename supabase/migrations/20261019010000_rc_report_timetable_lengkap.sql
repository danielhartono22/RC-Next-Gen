-- ==========================================================================================
-- Report dan Timetable disamakan dengan RC_Reporting_AppsScript
-- ==========================================================================================
-- Versi pertama kedua modul hanya menyediakan sebagian angka. Berkas ini melengkapinya supaya
-- layarnya dapat menyerupai Dashboard.html dan TimetableDashboard.html secara utuh.
--
-- YANG DITAMBAHKAN PADA DASHBOARD
--   trenBulanan     jumlah dan nilai klaim per bulan berdasarkan tanggal proses, untuk grafik
--                   "Tren Volume & Nilai Klaim per Bulan"
--   depot           ditambah outstandingRate, untuk grafik "Top 10 Depot - Outstanding %"
--   campaign        ditambah qty, outstanding qty/nilai dan outstanding %, mengikuti kolom
--                   PERF_COLUMNS pada sistem lama
--   kpi             ditambah qtyExpired dan qtyDone, karena pemilik meminta setiap kartu
--                   memuat nilai sekaligus jumlahnya
--
-- YANG DITAMBAHKAN PADA TIMETABLE
--   kpi             completed, notAchieved, cleared, compiled, notYet, total kombinasi, dan
--                   persentasenya - persis kartu pada TimetableDashboard.html
--   perRegion       progres per region
--   perCampaign     progres per campaign
--   topNotYet       sepuluh depot dengan Not Yet terbanyak. Sesuai sistem lama, daftar ini
--                   SENGAJA dihitung dari seluruh data dan tidak mengikuti filter, karena ia
--                   dipakai untuk menentukan prioritas lintas wilayah.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function public.rc_report_dashboard(p_filter jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare v_region text; v_depot text; v_campaign text; hasil jsonb;
begin
  if not rc_private.can_access(null,'view_report') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat modul Report' using errcode='42501'; end if;

  v_region   := nullif(btrim(coalesce(p_filter->>'region','')),'');
  v_depot    := nullif(btrim(coalesce(p_filter->>'depot','')),'');
  v_campaign := nullif(btrim(coalesce(p_filter->>'campaign','')),'');

  with r as (
    select * from public.rc_report_rows
     where (v_region is null or region = v_region)
       and (v_depot is null or depot_code = v_depot)
       and (v_campaign is null or campaign_code = v_campaign)
  )
  select jsonb_build_object(
    'status','success',
    'kpi', (select jsonb_build_object(
        'claimQty',       count(*),
        'netCb',          coalesce(sum(cb_net),0),
        'netClaimed',     coalesce(sum(cb_net) filter (where status='done'),0),
        'qtyDone',        count(*) filter (where status='done'),
        'cbExpired',      coalesce(sum(cb_net) filter (where status='expired'),0),
        'qtyExpired',     count(*) filter (where status='expired'),
        'grossClaimed',   coalesce(sum(gross_claimed) filter (where status='done'),0),
        'outstandingQty', count(*) filter (where outstanding),
        'outstandingValue', coalesce(sum(cb_net) filter (where outstanding),0),
        'clearingRate', case when coalesce(sum(cb_net),0)=0 then 0
          else (coalesce(sum(cb_net) filter (where status in('done','expired')),0) / sum(cb_net)) end,
        'jumlahDepot',    count(distinct depot_id),
        'jumlahCampaign', count(distinct campaign_id)
      ) from r),

    -- Tren bulanan memakai tanggal clearing, padanan "Tanggal Proses" pada sistem lama.
    -- Baris tanpa tanggal itu tidak dimasukkan ke bulan mana pun, bukan ditaruh di bulan
    -- sembarang yang akan menggeser seluruh grafik tanpa disadari.
    'trenBulanan', (select coalesce(jsonb_agg(jsonb_build_object(
        'bulan',t.b,'label',t.lbl,'qty',t.n,'nilai',t.v) order by t.b),'[]'::jsonb)
      from (select to_char(cleared_at at time zone 'Asia/Jakarta','YYYY-MM') b,
                   to_char(cleared_at at time zone 'Asia/Jakarta','Mon YY') lbl,
                   count(*) n, coalesce(sum(cb_net),0) v
              from r where cleared_at is not null group by 1,2) t),

    'status_distribusi', (select coalesce(jsonb_agg(jsonb_build_object(
        'status', rc_private.legacy_status(s.status), 'qty', s.n, 'nilai', s.v) order by s.n desc),'[]'::jsonb)
      from (select status, count(*) n, coalesce(sum(cb_net),0) v from r group by status) s),

    'aging', (select coalesce(jsonb_agg(jsonb_build_object('kelompok',a.k,'qty',a.n,'nilai',a.v)
        order by a.urut),'[]'::jsonb)
      from (select case when (current_date - acuan_aging) <= 30 then '<= 30 Hari'
                        when (current_date - acuan_aging) <= 60 then '31-60 Hari'
                        when (current_date - acuan_aging) <= 90 then '61-90 Hari'
                        else '> 90 Hari' end as k,
                   case when (current_date - acuan_aging) <= 30 then 1
                        when (current_date - acuan_aging) <= 60 then 2
                        when (current_date - acuan_aging) <= 90 then 3 else 4 end as urut,
                   count(*) n, coalesce(sum(cb_net),0) v
              from r where outstanding and acuan_aging is not null group by 1,2) a),

    'depot', (select coalesce(jsonb_agg(jsonb_build_object(
        'kodeDepot',x.depot_code,'namaDepot',x.depot_name,'region',x.region,
        'qty',x.qty,'netCb',x.net_cb,'netClaimed',x.net_claimed,'cbExpired',x.cb_expired,
        'outstandingQty',x.os_qty,'outstandingValue',x.os_val,
        'outstandingRate',x.os_rate,'clearingRate',x.cr)
        order by x.cr, x.os_val desc),'[]'::jsonb)
      from (select depot_code, depot_name, region, count(*) qty,
                   coalesce(sum(cb_net),0) net_cb,
                   coalesce(sum(cb_net) filter (where status='done'),0) net_claimed,
                   coalesce(sum(cb_net) filter (where status='expired'),0) cb_expired,
                   count(*) filter (where outstanding) os_qty,
                   coalesce(sum(cb_net) filter (where outstanding),0) os_val,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where outstanding),0)/sum(cb_net) end os_rate,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where status in('done','expired')),0)/sum(cb_net) end cr
              from r group by depot_code, depot_name, region) x),

    -- Kolomnya mengikuti PERF_COLUMNS pada Dashboard.html, supaya tabel Performa per Campaign
    -- dapat ditampilkan sama persis.
    'campaign', (select coalesce(jsonb_agg(jsonb_build_object(
        'kodeCampaign',y.campaign_code,'namaCampaign',y.campaign_name,
        'qty',y.qty,'netCb',y.net_cb,'netClaimed',y.net_claimed,
        'outstandingQty',y.os_qty,'outstandingValue',y.os_val,
        'outstandingRate',y.os_rate,'clearingRate',y.cr)
        order by y.cr, y.os_val desc),'[]'::jsonb)
      from (select campaign_code, campaign_name, count(*) qty,
                   coalesce(sum(cb_net),0) net_cb,
                   coalesce(sum(cb_net) filter (where status='done'),0) net_claimed,
                   count(*) filter (where outstanding) os_qty,
                   coalesce(sum(cb_net) filter (where outstanding),0) os_val,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where outstanding),0)/sum(cb_net) end os_rate,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where status in('done','expired')),0)/sum(cb_net) end cr
              from r group by campaign_code, campaign_name) y),

    'region', (select coalesce(jsonb_agg(jsonb_build_object(
        'region', case when z.region='' then '(belum diisi)' else z.region end,
        'qty',z.qty,'netCb',z.net_cb,'netClaimed',z.net_claimed,
        'outstandingValue',z.os_val,'clearingRate',z.cr) order by z.region),'[]'::jsonb)
      from (select region, count(*) qty,
                   coalesce(sum(cb_net),0) net_cb,
                   coalesce(sum(cb_net) filter (where status='done'),0) net_claimed,
                   coalesce(sum(cb_net) filter (where outstanding),0) os_val,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where status in('done','expired')),0)/sum(cb_net) end cr
              from r group by region) z),

    'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')
  ) into hasil;
  return hasil;
end $fn$;

-- ------------------------------------------------------------------------------------------
-- Timetable: KPI, progres per region dan per campaign, serta Top 10 Not Yet
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_timetable_matrix(p_filter jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare v_region text; v_depot text; v_campaign text; v_tanggal date;
begin
  if not rc_private.can_access(null,'view_report') and not rc_private.is_system_manager() then
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
    depot_terpilih as (
      select d.id, d.depot_code, d.depot_name, coalesce(d.region,'') as region
        from public.depots d
       where (v_region is null or coalesce(d.region,'') = v_region)
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
    -- Seluruh depot, tanpa filter, khusus untuk ranking Not Yet. Sistem lama juga
    -- memperlakukannya begitu: prioritas ditentukan lintas wilayah, bukan di dalam filter.
    global as (
      select d.id as depot_id, d.depot_code, d.depot_name,
             case when coalesce(r.n_hidup,0) = 0
                    and not exists(select 1 from public.timetable_not_achieved na
                                    where na.depot_id=d.id and na.campaign_id=k.id)
                  then 1 else 0 end as not_yet
        from public.depots d
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

create or replace function rc_private.marker_20261019() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261019() from public,anon;
grant execute on function rc_private.marker_20261019() to authenticated;

select 'Report dan Timetable dilengkapi' as hasil,
 (select count(*) from public.rc_report_rows) as baris_laporan,
 (select count(*) from public.campaigns
   where period_start is not null and period_start<=current_date
     and coalesce(period_end,current_date)>=current_date) as campaign_aktif;
