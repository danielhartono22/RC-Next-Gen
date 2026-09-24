-- ==========================================================================================
-- Modul Report: Dashboard, Cost Center 1, Cost Center 2
-- ==========================================================================================
-- Memindahkan FR-05, FR-10 dan FR-11 dari RC_Reporting_AppsScript ke RC, dengan data langsung
-- dari public.claims - bukan dari snapshot yang perlu disinkronkan lebih dulu.
--
-- DEFINISI KPI DIPERTAHANKAN PERSIS SEPERTI PRD, TERMASUK YANG MUDAH SALAH DIBACA
--   Outstanding  = Not Yet + Submitted + Released + Claimed. Done dan Expired TIDAK termasuk.
--   Net CB       = jumlah cb_net seluruh status
--   Net Claimed  = jumlah cb_net berstatus Done
--   CB Expired   = jumlah cb_net berstatus Expired
--   Clearing Rate= (Net Claimed + CB Expired) / Net CB, nol bila penyebutnya nol
--
-- Expired ikut dihitung sebagai cleared secara nominal. Itu memang aturan pada PRD, dan
-- konsekuensinya perlu diingat: Clearing Rate di sini bukan persentase pembayaran yang
-- berhasil saja. Persentase agregat dihitung dari total nominal, bukan rata-rata sederhana
-- persentase depot.
--
-- AGING
-- PRD menghitung aging dari End Time campaign dengan Start Time sebagai cadangan. Di RC,
-- claims.period_end kosong untuk seluruh baris, sehingga yang dipakai adalah periode campaign
-- hasil uraian pada 20261010010000, lalu uploaded_at sebagai cadangan terakhir. Baris tanpa
-- satu pun tanggal acuan tidak masuk aging, bukan dimasukkan ke kelompok pertama.
--
-- Seluruh fungsi di bawah SECURITY INVOKER, sehingga RLS depot tetap berlaku: seorang admin
-- hanya melihat angka depotnya sendiri, dan System Manager melihat seluruhnya. Laporan tidak
-- boleh menjadi pintu belakang yang memperlihatkan depot orang lain.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- Baris laporan: satu tempat yang menyatukan claim, campaign, depot dan aturan exclude
-- ------------------------------------------------------------------------------------------
create or replace view public.rc_report_rows
with (security_invoker = true) as
select
  c.id, c.no_doc, c.status, c.cb_net, c.cleared_at, c.uploaded_at, c.tax_subject,
  d.id   as depot_id,   d.depot_code, d.depot_name, coalesce(d.region,'') as region,
  ca.id  as campaign_id, ca.campaign_code, ca.campaign_name, ca.tax_status,
  ca.period_start, ca.period_end,
  rc_private.gross_claimed(c.cb_net, c.tax_subject, ca.tax_status) as gross_claimed,
  (c.status in ('not_yet','submitted','released','claimed')) as outstanding,
  -- Acuan aging, dengan urutan cadangan seperti dijelaskan di kepala berkas.
  coalesce(ca.period_end, ca.period_start, c.uploaded_at::date) as acuan_aging
from public.claims c
join public.depots d on d.id = c.depot_id
join public.campaigns ca on ca.id = c.campaign_id
where c.archived_at is null
  and not exists(select 1 from public.excluded_campaigns x where x.campaign_id = ca.id);

revoke all on public.rc_report_rows from public,anon;
grant select on public.rc_report_rows to authenticated;

-- ------------------------------------------------------------------------------------------
-- 1. Dashboard
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_report_dashboard(p_filter jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare
  v_region text; v_depot text; v_campaign text; hasil jsonb;
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
        'cbExpired',      coalesce(sum(cb_net) filter (where status='expired'),0),
        'grossClaimed',   coalesce(sum(gross_claimed) filter (where status='done'),0),
        'outstandingQty', count(*) filter (where outstanding),
        'outstandingValue', coalesce(sum(cb_net) filter (where outstanding),0),
        'clearingRate', case when coalesce(sum(cb_net),0)=0 then 0
          else (coalesce(sum(cb_net) filter (where status in('done','expired')),0)
                / sum(cb_net)) end,
        'jumlahDepot',    count(distinct depot_id),
        'jumlahCampaign', count(distinct campaign_id)
      ) from r),
    'status_distribusi', (select coalesce(jsonb_agg(jsonb_build_object(
        'status', rc_private.legacy_status(s.status), 'qty', s.n, 'nilai', s.v) order by s.n desc),'[]'::jsonb)
      from (select status, count(*) n, coalesce(sum(cb_net),0) v from r group by status) s),
    'aging', (select coalesce(jsonb_agg(jsonb_build_object('kelompok',a.k,'qty',a.n,'nilai',a.v)
        order by a.urut),'[]'::jsonb)
      from (
        select case
                 when (current_date - acuan_aging) <= 30 then '<= 30 Hari'
                 when (current_date - acuan_aging) <= 60 then '31-60 Hari'
                 when (current_date - acuan_aging) <= 90 then '61-90 Hari'
                 else '> 90 Hari' end as k,
               case
                 when (current_date - acuan_aging) <= 30 then 1
                 when (current_date - acuan_aging) <= 60 then 2
                 when (current_date - acuan_aging) <= 90 then 3
                 else 4 end as urut,
               count(*) n, coalesce(sum(cb_net),0) v
          from r
         -- Baris tanpa tanggal acuan sengaja tidak masuk aging, bukan dianggap paling baru.
         where outstanding and acuan_aging is not null
         group by 1,2) a),
    -- Ranking follow-up: clearing rate terendah lebih dahulu, dan bila sama, outstanding
    -- nominal terbesar yang didahulukan. Persis aturan PRD.
    'depot', (select coalesce(jsonb_agg(jsonb_build_object(
        'kodeDepot',x.depot_code,'namaDepot',x.depot_name,'region',x.region,
        'netCb',x.net_cb,'netClaimed',x.net_claimed,'cbExpired',x.cb_expired,
        'outstandingQty',x.os_qty,'outstandingValue',x.os_val,'clearingRate',x.cr)
        order by x.cr, x.os_val desc),'[]'::jsonb)
      from (select depot_code, depot_name, region,
                   coalesce(sum(cb_net),0) net_cb,
                   coalesce(sum(cb_net) filter (where status='done'),0) net_claimed,
                   coalesce(sum(cb_net) filter (where status='expired'),0) cb_expired,
                   count(*) filter (where outstanding) os_qty,
                   coalesce(sum(cb_net) filter (where outstanding),0) os_val,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where status in('done','expired')),0)
                             / sum(cb_net) end cr
              from r group by depot_code, depot_name, region) x),
    'campaign', (select coalesce(jsonb_agg(jsonb_build_object(
        'kodeCampaign',y.campaign_code,'namaCampaign',y.campaign_name,
        'netCb',y.net_cb,'netClaimed',y.net_claimed,'clearingRate',y.cr)
        order by y.net_cb desc),'[]'::jsonb)
      from (select campaign_code, campaign_name,
                   coalesce(sum(cb_net),0) net_cb,
                   coalesce(sum(cb_net) filter (where status='done'),0) net_claimed,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where status in('done','expired')),0)
                             / sum(cb_net) end cr
              from r group by campaign_code, campaign_name) y),
    'region', (select coalesce(jsonb_agg(jsonb_build_object(
        'region', case when z.region='' then '(belum diisi)' else z.region end,
        'netCb',z.net_cb,'netClaimed',z.net_claimed,'outstandingValue',z.os_val,
        'clearingRate',z.cr) order by z.net_cb desc),'[]'::jsonb)
      from (select region,
                   coalesce(sum(cb_net),0) net_cb,
                   coalesce(sum(cb_net) filter (where status='done'),0) net_claimed,
                   coalesce(sum(cb_net) filter (where outstanding),0) os_val,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where status in('done','expired')),0)
                             / sum(cb_net) end cr
              from r group by region) z),
    'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')
  ) into hasil;
  return hasil;
end $fn$;
revoke all on function public.rc_report_dashboard(jsonb) from public,anon;
grant execute on function public.rc_report_dashboard(jsonb) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Cost Center 1: rekap depot x campaign
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_cost_center(p_filter jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare v_region text; v_depot text; v_campaign text;
begin
  if not rc_private.can_access(null,'view_report') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat modul Report' using errcode='42501'; end if;
  v_region   := nullif(btrim(coalesce(p_filter->>'region','')),'');
  v_depot    := nullif(btrim(coalesce(p_filter->>'depot','')),'');
  v_campaign := nullif(btrim(coalesce(p_filter->>'campaign','')),'');

  return (select jsonb_build_object('status','success','rows',
    coalesce(jsonb_agg(jsonb_build_object(
      'kodeDepot',t.depot_code,'namaDepot',t.depot_name,'region',t.region,
      'kodeCampaign',t.campaign_code,'namaCampaign',t.campaign_name,
      'qty',t.qty,'netCb',t.net_cb,'netClaimed',t.net_claimed,
      'grossClaimed',t.gross_claimed,'cbExpired',t.cb_expired,'clearingRate',t.cr)
      order by t.depot_code, t.campaign_code),'[]'::jsonb),
    'total',(select count(*) from (select 1 from public.rc_report_rows limit 1) z))
  from (
    select depot_code, depot_name, region, campaign_code, campaign_name,
           count(*) qty,
           coalesce(sum(cb_net),0) net_cb,
           coalesce(sum(cb_net) filter (where status='done'),0) net_claimed,
           coalesce(sum(gross_claimed) filter (where status='done'),0) gross_claimed,
           coalesce(sum(cb_net) filter (where status='expired'),0) cb_expired,
           case when coalesce(sum(cb_net),0)=0 then 0
                else coalesce(sum(cb_net) filter (where status in('done','expired')),0)
                     / sum(cb_net) end cr
      from public.rc_report_rows
     where (v_region is null or region = v_region)
       and (v_depot is null or depot_code = v_depot)
       and (v_campaign is null or campaign_code = v_campaign)
     group by depot_code, depot_name, region, campaign_code, campaign_name) t);
end $fn$;
revoke all on function public.rc_cost_center(jsonb) from public,anon;
grant execute on function public.rc_cost_center(jsonb) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Cost Center 2: Net dan Gross Claimed bulanan per campaign
-- ------------------------------------------------------------------------------------------
-- Bulannya diambil dari tanggal clearing baris berstatus Done - padanan "Tanggal Proses" pada
-- sistem lama. Baris Done yang belum punya tanggal clearing tidak dimasukkan ke bulan mana pun,
-- karena menempatkannya di bulan sembarang akan menggeser angka bulanan tanpa disadari.
create or replace function public.rc_cost_center_2(p_filter jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare v_region text; v_depot text; v_campaign text; v_tahun integer;
begin
  if not rc_private.can_access(null,'view_report') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat modul Report' using errcode='42501'; end if;
  v_region   := nullif(btrim(coalesce(p_filter->>'region','')),'');
  v_depot    := nullif(btrim(coalesce(p_filter->>'depot','')),'');
  v_campaign := nullif(btrim(coalesce(p_filter->>'campaign','')),'');
  v_tahun    := nullif(btrim(coalesce(p_filter->>'tahun','')),'')::integer;

  return (select jsonb_build_object('status','success','rows',
    coalesce(jsonb_agg(jsonb_build_object(
      'kodeCampaign',t.campaign_code,'namaCampaign',t.campaign_name,
      'bulan',t.bulan,'namaBulan',t.nama_bulan,
      'qty',t.qty,'netClaimed',t.net_claimed,'grossClaimed',t.gross_claimed,
      'netCb',t.net_cb,'clearingRate',t.cr) order by t.bulan, t.campaign_code),'[]'::jsonb),
    'catatan','Bulan diambil dari tanggal clearing baris Done. Baris Done tanpa tanggal clearing tidak masuk bulan mana pun.')
  from (
    select campaign_code, campaign_name,
           to_char(cleared_at at time zone 'Asia/Jakarta','YYYY-MM') bulan,
           to_char(cleared_at at time zone 'Asia/Jakarta','Mon YYYY') nama_bulan,
           count(*) qty,
           coalesce(sum(cb_net),0) net_claimed,
           coalesce(sum(gross_claimed),0) gross_claimed,
           coalesce(sum(cb_net),0) net_cb,
           1::numeric cr
      from public.rc_report_rows
     where status='done' and cleared_at is not null
       and (v_region is null or region = v_region)
       and (v_depot is null or depot_code = v_depot)
       and (v_campaign is null or campaign_code = v_campaign)
       and (v_tahun is null or extract(year from cleared_at at time zone 'Asia/Jakarta')=v_tahun)
     group by campaign_code, campaign_name, 3, 4) t);
end $fn$;
revoke all on function public.rc_cost_center_2(jsonb) from public,anon;
grant execute on function public.rc_cost_center_2(jsonb) to authenticated;

create or replace function rc_private.marker_20261011() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261011() from public,anon;
grant execute on function rc_private.marker_20261011() to authenticated;

select 'Modul Report terpasang' as hasil,
 (select count(*) from public.rc_report_rows) as baris_laporan,
 (select count(*) from public.excluded_campaigns) as campaign_dikecualikan;
