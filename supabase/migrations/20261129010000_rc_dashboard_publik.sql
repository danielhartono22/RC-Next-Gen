-- ==========================================================================================
-- Dashboard publik: dibuka dari email tanpa login
-- ==========================================================================================
-- Keputusan pemilik, 20 September 2026: tautan Claim Dashboard pada email harus dapat dibuka
-- tanpa login, sebagai halaman publik permanen tanpa token.
--
-- Pilihan itu sudah saya sampaikan konsekuensinya lebih dulu, dan pemilik tetap memilihnya:
--
--   * tautan yang diteruskan keluar tetap membuka halaman ini, selamanya
--   * aturan yurisdiksi tidak berlaku - halaman tidak tahu siapa yang membukanya, jadi isinya
--     sama untuk semua orang
--
-- ------------------------------------------------------------------------------------------
-- SATU BATAS YANG TIDAK DILONGGARKAN
-- ------------------------------------------------------------------------------------------
-- Fungsi ini TIDAK pernah menyentuh rc_private.claim_sensitive - KTP, NPWP, nomor rekening dan
-- nama rekening. Ia juga tidak menyebut satu pun nama pelanggan. Yang dikembalikan hanyalah
-- agregat per Depot, per Campaign, per Region dan sebaran status: persis isi PDF yang selama ini
-- dilampirkan, dan itulah yang dijanjikan kalimat pada email.
--
-- Membuka angka penjualan adalah keputusan bisnis yang boleh diambil pemilik. Membuka nomor
-- rekening dan nomor identitas pelanggan bukan, dan tidak diminta.
--
-- ------------------------------------------------------------------------------------------
-- BAGAIMANA IA MELEWATI RLS
-- ------------------------------------------------------------------------------------------
-- SECURITY DEFINER, sehingga berjalan dengan hak pemiliknya dan tidak tunduk pada kebijakan RLS
-- yang menyaring menurut yurisdiksi pemanggil. Itu memang yang dikehendaki di sini - tetapi
-- karena itu pula isinya dibatasi tangan pada agregat, bukan diserahkan pada RLS.
--
-- Haknya diberikan kepada anon DAN authenticated: halaman publik dipanggil tanpa sesi.
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
             group by x.urut, x.label, x.warna) g)
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

  -- Batas yang tidak boleh dilanggar: data pribadi tidak ikut.
  if src like '%claim_sensitive%' then
    raise exception 'GAGAL: fungsi publik menyentuh claim_sensitive.'; end if;
  if src like '%customer_name%' or src like '%public.customers%' then
    raise exception 'GAGAL: fungsi publik menyebut data pelanggan.'; end if;

  -- anon harus benar-benar boleh memanggilnya.
  if not has_function_privilege('anon','public.rc_dashboard_publik()','execute') then
    raise exception 'GAGAL: anon tidak dapat memanggil dashboard publik.'; end if;

  v := public.rc_dashboard_publik();
  if (v->>'status') <> 'success' then raise exception 'GAGAL: fungsi tidak mengembalikan success.'; end if;
  raise notice 'Depot: %, Campaign: %, Region: %',
    jsonb_array_length(v->'perDepot'), jsonb_array_length(v->'perCampaign'),
    jsonb_array_length(v->'perRegion');

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
