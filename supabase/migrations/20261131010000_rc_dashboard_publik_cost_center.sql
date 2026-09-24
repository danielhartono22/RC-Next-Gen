-- ==========================================================================================
-- Dashboard publik melengkapi Cost Center 1 dan Cost Center 2
-- ==========================================================================================
-- Permintaan pemilik: halaman yang dibuka dari tautan email memuat SEMUANYA, termasuk Cost
-- Center 1 dan Cost Center 2, sama persis dengan yang ada di dalam aplikasi.
--
-- Agregatnya disalin apa adanya dari public.rc_cost_center dan public.rc_cost_center_2 -
-- kolom yang sama, pengelompokan yang sama, rumus clearing rate yang sama - supaya angka di
-- halaman publik tidak pernah berbeda dari angka di dalam aplikasi untuk hal yang sama.
--
-- Yang TIDAK ikut disalin hanya penyaringnya. Kedua fungsi asli menerima filter region, depot,
-- campaign dan tahun dari layar; halaman publik tidak punya sesi, jadi ia menampilkan
-- seluruhnya dan penyaringan dilakukan di sisi halaman.
--
-- ------------------------------------------------------------------------------------------
-- BATAS YANG SAMA TETAP BERLAKU
-- ------------------------------------------------------------------------------------------
-- Cost Center bekerja pada tingkat Depot dan Campaign, bukan pelanggan - jadi melengkapinya
-- tidak membuka satu pun nama toko, KTP, NPWP maupun nomor rekening. Pemeriksaan di akhir
-- berkas ini menolak bila suatu saat ada yang menambahkannya.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function public.rc_dashboard_publik()
returns jsonb language sql stable security definer set search_path='' as $fn$
  select jsonb_build_object(
    'status','success',
    'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),

    'kpi', (select jsonb_build_object(
        'claimQty',   count(*),
        'netCb',      coalesce(sum(cb_net),0),
        'doneValue',  coalesce(sum(cb_net) filter (where status='done'),0),
        'osValue',    coalesce(sum(cb_net) filter (where outstanding),0),
        'osQty',      count(*) filter (where outstanding),
        'clearingRate', case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where status in('done','expired')),0)
                             / sum(cb_net) end)
      from public.rc_report_rows),

    'perDepot', (select coalesce(jsonb_agg(jsonb_build_object(
        'kode', q.depot_code, 'nama', q.depot_name, 'region', q.region,
        'qty', q.qty, 'netCb', q.net_cb, 'osValue', q.os_val, 'clearingRate', q.cr)
        order by q.cr, q.os_val desc), '[]'::jsonb)
      from (select d.depot_code, d.depot_name,
                   coalesce(nullif(btrim(d.region),''),'-') region,
                   count(*) qty, coalesce(sum(c.cb_net),0) net_cb,
                   coalesce(sum(c.cb_net) filter (where c.outstanding),0) os_val,
                   case when coalesce(sum(c.cb_net),0)=0 then 0
                        else coalesce(sum(c.cb_net) filter (where c.status in('done','expired')),0)
                             / sum(c.cb_net) end cr
              from public.rc_report_rows c join public.depots d on d.id = c.depot_id
             group by d.depot_code, d.depot_name, d.region) q),

    'perCampaign', (select coalesce(jsonb_agg(jsonb_build_object(
        'kode', q.campaign_code, 'nama', q.campaign_name,
        'qty', q.qty, 'netCb', q.net_cb, 'osValue', q.os_val, 'clearingRate', q.cr)
        order by q.cr, q.os_val desc), '[]'::jsonb)
      from (select c.campaign_code, coalesce(c.campaign_name,'') campaign_name,
                   count(*) qty, coalesce(sum(c.cb_net),0) net_cb,
                   coalesce(sum(c.cb_net) filter (where c.outstanding),0) os_val,
                   case when coalesce(sum(c.cb_net),0)=0 then 0
                        else coalesce(sum(c.cb_net) filter (where c.status in('done','expired')),0)
                             / sum(c.cb_net) end cr
              from public.rc_report_rows c
             group by c.campaign_code, c.campaign_name) q),

    'perRegion', (select coalesce(jsonb_agg(jsonb_build_object(
        'region', q.region, 'netCb', q.net_cb, 'osValue', q.os_val,
        'osQty', q.os_qty, 'clearingRate', q.cr) order by q.os_val desc), '[]'::jsonb)
      from (select coalesce(nullif(btrim(region),''),'(tanpa region)') region,
                   coalesce(sum(cb_net),0) net_cb,
                   coalesce(sum(cb_net) filter (where outstanding),0) os_val,
                   count(*) filter (where outstanding) os_qty,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where status in('done','expired')),0)
                             / sum(cb_net) end cr
              from public.rc_report_rows group by 1
             having coalesce(sum(cb_net),0) > 0) q),

    'sebaranStatus', (select coalesce(jsonb_agg(jsonb_build_object(
        'label', g.label, 'warna', g.warna, 'qty', g.qty, 'nilai', g.nilai)
        order by g.urut), '[]'::jsonb)
      from (select x.urut, x.label, x.warna,
                   count(c.id) qty, coalesce(sum(c.cb_net),0) nilai
              from (values
                (1,'Done','#34A853',array['done']),
                (2,'Expired','#7B1E1E',array['expired']),
                (3,'Pending Depot','#EA4335',array['not_yet']),
                (4,'Pending OSC','#FF9900',array['submitted','released']),
                (5,'Pending Finance','#4285F4',array['claimed']),
                (6,'Lainnya','#9AA0A6',array[]::text[])
              ) as x(urut,label,warna,status_list)
              left join public.rc_report_rows c on
                case when x.urut = 6
                     then c.status <> all(array['done','expired','not_yet','submitted','released','claimed'])
                     else c.status = any(x.status_list) end
             group by x.urut, x.label, x.warna) g),

    -- ---- Cost Center 1: per Depot x Campaign -------------------------------------------
    -- Kolom dan rumusnya disalin dari public.rc_cost_center.
    'costCenter', (select coalesce(jsonb_agg(jsonb_build_object(
        'kodeDepot',t.depot_code,'namaDepot',t.depot_name,'region',t.region,
        'kodeCampaign',t.campaign_code,'namaCampaign',t.campaign_name,
        'qty',t.qty,'netCb',t.net_cb,'netClaimed',t.net_claimed,
        'grossClaimed',t.gross_claimed,'cbExpired',t.cb_expired,'clearingRate',t.cr)
        order by t.depot_code, t.campaign_code), '[]'::jsonb)
      from (select depot_code, depot_name, region, campaign_code, campaign_name,
                   count(*) qty,
                   coalesce(sum(cb_net),0) net_cb,
                   coalesce(sum(cb_net) filter (where status='done'),0) net_claimed,
                   coalesce(sum(gross_claimed) filter (where status='done'),0) gross_claimed,
                   coalesce(sum(cb_net) filter (where status='expired'),0) cb_expired,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where status in('done','expired')),0)
                             / sum(cb_net) end cr
              from public.rc_report_rows
             group by depot_code, depot_name, region, campaign_code, campaign_name) t),

    -- ---- Cost Center 2: per Campaign x Bulan pencairan ---------------------------------
    -- Kolom dan rumusnya disalin dari public.rc_cost_center_2, termasuk catatannya.
    'costCenter2', (select coalesce(jsonb_agg(jsonb_build_object(
        'kodeCampaign',t.campaign_code,'namaCampaign',t.campaign_name,
        'bulan',t.bulan,'namaBulan',t.nama_bulan,
        'qty',t.qty,'netClaimed',t.net_claimed,'grossClaimed',t.gross_claimed,
        'netCb',t.net_cb,'clearingRate',t.cr)
        order by t.bulan, t.campaign_code), '[]'::jsonb)
      from (select campaign_code, campaign_name,
                   to_char(cleared_at at time zone 'Asia/Jakarta','YYYY-MM') bulan,
                   to_char(cleared_at at time zone 'Asia/Jakarta','Mon YYYY') nama_bulan,
                   count(*) qty,
                   coalesce(sum(cb_net),0) net_claimed,
                   coalesce(sum(gross_claimed),0) gross_claimed,
                   coalesce(sum(cb_net),0) net_cb,
                   1::numeric cr
              from public.rc_report_rows
             where status='done' and cleared_at is not null
             group by campaign_code, campaign_name, 3, 4) t),

    'catatanCostCenter2','Bulan diambil dari tanggal clearing baris Done. '
      || 'Baris Done tanpa tanggal clearing tidak masuk bulan mana pun.'
  );
$fn$;

revoke all on function public.rc_dashboard_publik() from public;
grant execute on function public.rc_dashboard_publik() to anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text; v jsonb;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='rc_dashboard_publik';

  -- Batas yang tidak boleh dilanggar meski isinya bertambah.
  if src like '%claim_sensitive%' then
    raise exception 'GAGAL: fungsi publik menyentuh claim_sensitive.'; end if;
  if src like '%customer_name%' or src like '%public.customers%' then
    raise exception 'GAGAL: fungsi publik menyebut data pelanggan.'; end if;

  if not has_function_privilege('anon','public.rc_dashboard_publik()','execute') then
    raise exception 'GAGAL: anon tidak dapat memanggilnya.'; end if;

  v := public.rc_dashboard_publik();
  if v ? 'costCenter' = false or v ? 'costCenter2' = false then
    raise exception 'GAGAL: Cost Center belum ikut.'; end if;

  raise notice 'depot=% campaign=% costCenter=% costCenter2=%',
    jsonb_array_length(v->'perDepot'), jsonb_array_length(v->'perCampaign'),
    jsonb_array_length(v->'costCenter'), jsonb_array_length(v->'costCenter2');
  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
