-- PENDING: belum diterapkan. Aman dijalankan berulang.
--
-- Tiga perbaikan yang dilaporkan pemilik:
--
--  1. Kolom Tanggal Proses menampilkan "undefined". Halaman merender ${r.tglProses}, tetapi
--     server tidak pernah mengirim field itu. Backend Apps Script lama mengisinya sebagai
--     tanggal clearing ketika status Done, dan tanda "-" untuk selain itu.
--  2. Tab Open harus memuat dokumen berstatus Not Yet, termasuk yang pada sheet lama berupa
--     sel kosong.
--  3. Cashback Compilation menampilkan seluruh baris dengan pagination, tanpa batas atas.
--     Batas 2000 hanya berlaku untuk unggahan compile, bukan untuk melihat.

------------------------------------------------------------------------------------------
-- 1. Tanggal Proses pada Analytics
------------------------------------------------------------------------------------------
-- Paritas dengan ResourceCollection.handleGetDashboardData baris 1222:
--   tglProses: statRaw === "Done" ? formatDateSafe(TGL_CLEARING) : "-"
-- Tanda hubung dikirim server, bukan ditambal di browser, supaya seluruh pembaca data ini
-- melihat nilai yang sama.
create or replace function public.rc_legacy_dashboard() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
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
   where c.status<>'not_yet'),'[]'::jsonb),
  'compileData',coalesce((select jsonb_agg(jsonb_build_object(
    'depotName',d.depot_name,'codeCampaign',ca.campaign_code,'campaign',ca.campaign_name,
    'reward',c.cb_net,'kodeToko',cu.customer_code))
   from public.claims c
   join public.depots d on d.id=c.depot_id
   join public.customers cu on cu.id=c.customer_id
   join public.campaigns ca on ca.id=c.campaign_id),'[]'::jsonb));
end $$;

-- Antrean workflow juga mengirim tglProses, dengan aturan yang sama, supaya kolom bernama
-- sama tidak berarti dua hal berbeda di dua layar.
create or replace function public.rc_legacy_workflow() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare rows_json jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 select coalesce(jsonb_agg(x),'[]'::jsonb) into rows_json from (
  select jsonb_build_object(
   'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
   'depot',d.depot_name,'kodeDepot',d.depot_code,
   'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',coalesce(ca.cashback_type,''),'statusPajakCamp',coalesce(ca.tax_status,''),
   'statusPajakCust',coalesce(c.tax_subject,''),
   'cbNet',c.cb_net,'grossUpCb',c.gross_up,'totTagih',c.total_billing,
   'periodeStart',rc_private.legacy_date(c.period_start),'periodeEnd',rc_private.legacy_date(c.period_end),
   'tglLunas',rc_private.legacy_date(c.paid_on),
   'tglUpload',rc_private.legacy_ts(c.uploaded_at),'tglRelease',rc_private.legacy_ts(c.released_at),
   'tglClaim',rc_private.legacy_ts(c.claimed_at),'tglClearing',rc_private.legacy_ts(c.cleared_at),
   'tglProses',case when c.status='done' and c.cleared_at is not null
                    then rc_private.legacy_ts(c.cleared_at) else '-' end,
   'batchUpload',coalesce(c.batch_upload,''),'batchRelease',coalesce(c.batch_release,''),
   'batchClaim',coalesce(c.batch_claim,''),'batchClearing',coalesce(c.batch_clearing,''),
   'approval',coalesce(c.approval,''),'top',coalesce(s.top_text,''),
   'ktp',coalesce(s.ktp,''),'npwp',coalesce(s.npwp,''),'bankCust',coalesce(s.bank,''),
   'bank',coalesce(s.bank,''),'noRekening',coalesce(s.account_number,''),
   'namaRekening',coalesce(s.account_name,''),'pemilikRekening',coalesce(s.account_name,''),
   'contactPerson',coalesce(cu.contact_person,''),
   'versionNo',c.version_no,
   'rebate',lower(btrim(coalesce(ca.cashback_type,'')))='rebate') as x
  from public.claims c
  join public.depots d on d.id=c.depot_id
  join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  left join rc_private.claim_sensitive s on s.claim_id=c.id
  where c.status in('submitted','released','claimed')
  order by c.updated_at desc,c.id limit 5000) t;

 -- Rebate dipisah tegas: tidak muncul di antrean bertahap, hanya di Bulk Process.
 return jsonb_build_object('status','success',
  'releaseData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where v->>'status'='Submitted' and not (v->>'rebate')::boolean),
  'claimFinData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where v->>'status'='Released' and not (v->>'rebate')::boolean),
  'clearingData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where v->>'status'='Claimed' and not (v->>'rebate')::boolean),
  'bulkRebateData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where (v->>'rebate')::boolean));
end $$;

------------------------------------------------------------------------------------------
-- 2. Tab Open: Not Yet, termasuk sel kosong pada data lama
------------------------------------------------------------------------------------------
-- "Not Yet atau sel kosong" adalah satu keadaan yang sama di sini. Sel status yang kosong
-- pada sheet Compile lama sudah dinormalisasi menjadi 'not_yet' ketika diimpor, dan kolom
-- status memiliki CHECK sehingga tidak mungkin kosong. Jadi satu syarat sudah mencakup
-- keduanya; menambahkan pemeriksaan legacy_status hanya akan menjadi logika mati yang
-- menyesatkan pembaca berikutnya.
create or replace function public.rc_open_claims(p_search text default '',p_campaign text default '',
 p_offset integer default 0,p_limit integer default 200)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v jsonb; jml bigint;
begin
 if not rc_private.can_access(null,'upload_claim') then
  raise exception 'Access denied' using errcode='42501'; end if;

 select count(*) into jml from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  join public.customers cu on cu.id=c.customer_id
  where c.status='not_yet'
    and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%');

 select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'noDoc',c.no_doc,'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',coalesce(ca.cashback_type,''),'statusPajakCamp',coalesce(ca.tax_status,''),
   'cbNet',c.cb_net,'dcCode',d.depot_code,'depotName',d.depot_name,
   'top',coalesce(cu.top_text,''),'ktp',coalesce(cu.ktp,''),'npwp',coalesce(cu.npwp,''),
   'noRek',coalesce(cu.account_number,''),'namaRek',coalesce(cu.account_name,''),
   'bank',coalesce(cu.bank,''),'subyekPajak',coalesce(cu.tax_subject,''),
   'contactPerson',coalesce(cu.contact_person,''),
   'versionNo',c.version_no) as x
  from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  join public.customers cu on cu.id=c.customer_id
  join public.depots d on d.id=c.depot_id
  where c.status='not_yet'
    and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,200),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 return jsonb_build_object('status','success','rows',v,'total',jml);
end $$;

------------------------------------------------------------------------------------------
-- 3. Cashback Compilation: tampilkan semua, pagination tanpa batas atas
------------------------------------------------------------------------------------------
-- Batas 2000 dicabut dari pembacaan. Melihat data tidak pernah merusak apa pun, dan menolak
-- menampilkannya hanya memaksa pengguna menebak filter. Batas itu tetap berlaku pada
-- rc_compile_upload dan rc_compile_preview, karena di sanalah baris benar-benar dibuat.
--
-- Satu halaman tetap dibatasi agar respons tidak membengkak; yang dicabut adalah penolakan
-- atas jumlah total.
create or replace function public.rc_compilation_list(p_campaign text default '',p_batch text default '',
 p_status text default '',p_search text default '',p_offset integer default 0,p_limit integer default 100)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v jsonb; jml bigint;
begin
 if not rc_private.can_access(null,'view_compilation') then
  raise exception 'Access denied' using errcode='42501'; end if;

 select count(*) into jml from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  join public.customers cu on cu.id=c.customer_id
  where (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_status),'')='' or c.status=btrim(p_status))
    and (coalesce(btrim(p_batch),'')='' or btrim(p_batch) in
         (c.batch_upload,c.batch_release,c.batch_claim,c.batch_clearing))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%');

 select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'id',c.id,'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
   'depot',d.depot_name,'kodeDepot',d.depot_code,
   'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
   'contactPerson',coalesce(cu.contact_person,''),
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',coalesce(ca.cashback_type,''),'statusPajak',coalesce(ca.tax_status,''),
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
  join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  where (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_status),'')='' or c.status=btrim(p_status))
    and (coalesce(btrim(p_batch),'')='' or btrim(p_batch) in
         (c.batch_upload,c.batch_release,c.batch_claim,c.batch_clearing))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,100),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 return jsonb_build_object('status','success','rows',v,'total',jml,
  'canArchive',rc_private.can_access(null,'archive_compilation'));
end $$;

------------------------------------------------------------------------------------------
-- 4. Penanda versi
------------------------------------------------------------------------------------------
-- Migration ini hanya memakai CREATE OR REPLACE, jadi tidak ada objek baru yang dapat
-- dijadikan tanda "sudah diterapkan". Penanda kecil ini membuat npm run diagnose dapat
-- membedakannya, alih-alih salah melaporkan migration ini sudah masuk.
create or replace function rc_private.marker_20260922() returns boolean
language sql immutable set search_path='' as $$select true$$;
revoke all on function rc_private.marker_20260922() from public,anon;
grant execute on function rc_private.marker_20260922() to authenticated;
