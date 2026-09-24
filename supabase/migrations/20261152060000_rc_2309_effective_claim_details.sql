-- Keep effective CB type and SO chronology consistent in upload and Analytics.
CREATE OR REPLACE FUNCTION rc_private.claim_details(c claims)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select case when not rc_private.can_access(c.depot_id) then '{}'::jsonb else jsonb_build_object(
 'tglUpload',rc_private.legacy_ts(c.uploaded_at),'tglApprove',rc_private.legacy_ts(c.approved_at),
 'tglRelease',rc_private.legacy_ts(c.released_at),'tglClaim',rc_private.legacy_ts(c.claimed_at),
 'tglClearing',rc_private.legacy_ts(c.cleared_at),'tglBulk',rc_private.legacy_ts(c.bulk_processed_at),
 'submittedAt',c.uploaded_at,'approvedAt',c.approved_at,'releasedAt',c.released_at,'claimedAt',c.claimed_at,'doneAt',c.cleared_at,
 'batchUpload',coalesce(c.batch_upload,''),'batchRelease',coalesce(c.batch_release,''),
 'batchClaim',coalesce(c.batch_claim,''),'batchClearing',coalesce(c.batch_clearing,''),
 'soStart',rc_private.legacy_date(coalesce(c.extend_so_start,c.period_start,(select period_start from public.campaigns where id=c.campaign_id))),
 'soEnd',rc_private.legacy_date(coalesce(c.extend_so_end,c.period_end,(select period_end from public.campaigns where id=c.campaign_id))),
 'billingStart',rc_private.legacy_date(c.extend_billing_start),'billingEnd',rc_private.legacy_date(c.extend_billing_end),
 'remark',rc_private.claim_remark(c),'processBy',coalesce((select p.full_name from public.claim_status_history h
   join public.profiles p on p.id=h.actor_id where h.claim_id=c.id order by h.id desc limit 1),''),
 'pendingGroup',case when c.status in('not_yet','submitted') then 'Pending Depot'
 when c.status in('approved','released') then 'Pending OSC' when c.status='claimed' then 'Pending Finance'
 when c.status='done' then 'Done' else rc_private.legacy_status(c.status) end) end;
$function$
;
CREATE OR REPLACE FUNCTION rc_private.legacy_documents()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce(jsonb_agg(x order by x->>'noDoc'),'[]'::jsonb) from (
  select jsonb_build_object(
   'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
   'dcCode',d.depot_code,'depotName',d.depot_name,
   'custCode',cu.customer_code,'custName',cu.customer_name,
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'cbNet',c.cb_net,'netValue',c.net_value,'volume',c.volume,
   'pendingApproval',c.pending_approval is not null,'versionNo',c.version_no) as x
  from public.claims c
  join public.depots d on d.id=c.depot_id
  join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  where rc_private.can_access(c.depot_id)
  order by c.no_doc limit 20000) t;
$function$
;
notify pgrst,'reload schema';
