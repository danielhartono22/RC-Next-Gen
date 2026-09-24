-- ==========================================================================================
-- Analytics: Cashback List memuat seluruh status, termasuk Not Yet
-- ==========================================================================================
-- rc_legacy_dashboard menyaring "where c.status<>'not_yet'", sehingga dokumen yang belum
-- diproses tidak pernah muncul di Cashback List. Pemilik meminta sebaliknya: seluruh customer
-- masuk ke daftar ini apa pun statusnya, termasuk Not Yet dan sel yang masih kosong, karena
-- daftar itu dibaca sebagai gambaran menyeluruh, bukan sebagai antrean kerja.
--
-- Antrean kerja sendiri tidak terpengaruh: Release, Claim Process dan Bulk Process memakai
-- rc_legacy_workflow yang menyaring statusnya sendiri.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

CREATE OR REPLACE FUNCTION public.rc_legacy_dashboard()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
 if not rc_private.can_access(null,'view_analytics') then raise exception 'Access denied' using errcode='42501'; end if;
 return jsonb_build_object('status','success',
  'history',coalesce((select jsonb_agg(jsonb_build_object(
    'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
    'depot',d.depot_name,'osc',coalesce(p.full_name,''),
    'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
    'codeCampaign',ca.campaign_code,'campaign',ca.campaign_name,
    'totalClaim',c.cb_net,'grossUpCb',c.gross_up,
    'tglUpload',rc_private.legacy_ts(c.uploaded_at),
    'tglClearing',rc_private.legacy_ts(c.cleared_at),
    -- Field yang sebelumnya hilang dan membuat kolom menampilkan "undefined".
    'tglProses',case when c.status='done' and c.cleared_at is not null
                     then rc_private.legacy_ts(c.cleared_at) else '-' end,
    'jenisCb',coalesce(ca.cashback_type,''),
    'batchUpload',coalesce(c.batch_upload,''),'batchClearing',coalesce(c.batch_clearing,''))
    order by c.updated_at desc)
   from public.claims c
   join public.depots d on d.id=c.depot_id
   join public.customers cu on cu.id=c.customer_id
   join public.campaigns ca on ca.id=c.campaign_id
   left join lateral (select h.actor_id from public.claim_status_history h
     where h.claim_id=c.id and h.action='submit' order by h.id desc limit 1) sub on true
   left join public.profiles p on p.id=sub.actor_id
   -- Filter not_yet dibuang. Pemilik meminta Cashback List memuat SELURUH customer apa pun
  -- statusnya, termasuk Not Yet dan sel kosong, karena daftar ini dipakai sebagai gambaran
  -- menyeluruh, bukan hanya antrean yang sedang berjalan.
  ),'[]'::jsonb),
  'compileData',coalesce((select jsonb_agg(jsonb_build_object(
    'depotName',d.depot_name,'codeCampaign',ca.campaign_code,'campaign',ca.campaign_name,
    'reward',c.cb_net,'kodeToko',cu.customer_code))
   from public.claims c
   join public.depots d on d.id=c.depot_id
   join public.customers cu on cu.id=c.customer_id
   join public.campaigns ca on ca.id=c.campaign_id),'[]'::jsonb));
end $function$;


create or replace function rc_private.marker_20261006() returns boolean
language sql immutable set search_path='' as $marker$select true$marker$;
revoke all on function rc_private.marker_20261006() from public,anon;
grant execute on function rc_private.marker_20261006() to authenticated;

select 'Cashback List memuat seluruh status' as hasil,
 (select count(*) from public.claims) as total_claim,
 (select count(*) from public.claims where status='not_yet') as kini_ikut_tampil;
