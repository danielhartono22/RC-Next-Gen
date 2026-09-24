-- ==========================================================================================
-- Siapa yang melakukan tiap tahap: submitted by, released by, claimed by
-- ==========================================================================================
-- Pemilik meminta kartu "Nilai Tagihan" pada baris Claim Process diganti menjadi keterangan
-- pelaku: siapa yang men-submit, siapa yang me-release, dan siapa yang meng-claim, dalam satu
-- kartu. Datanya sudah ada di public.claim_status_history, tetapi belum pernah dibawa keluar.
--
-- MENGAPA PENERJEMAHAN NAMA HARUS SECURITY DEFINER
-- public.profiles memiliki RLS yang hanya membuka baris diri sendiri dan baris pengguna yang
-- boleh dikelola. Menjoin profiles langsung dari rc_legacy_workflow - yang SECURITY INVOKER -
-- membuat kolom nama kosong bagi hampir semua orang: seorang pengguna depot tidak boleh
-- membaca baris OSC-nya, sehingga "released by" akan selalu tampil sebagai tanda hubung.
--
-- Yang dibuka di sini hanyalah nama tampilan, dan hanya bagi dokumen yang memang sudah boleh
-- dilihat pemanggilnya - penyaringan depot tetap dikerjakan RLS pada claims. Kolom sensitif
-- pada profiles (email bisnis, status, peran) tidak ikut.
--
-- rc_legacy_workflow SENGAJA TETAP SECURITY INVOKER. Ia menyaring hanya berdasarkan status,
-- bukan depot; pemisahan antardepot sepenuhnya bergantung pada RLS claims. Menjadikannya
-- DEFINER akan membuka seluruh depot kepada siapa pun.
--
-- DOKUMEN WARISAN TIDAK PUNYA PELAKU
-- 2.756 baris riwayat berasal dari 'import_snapshot' tanpa actor_id, karena memang dipindahkan
-- dari spreadsheet lama dan tidak ada catatan siapa yang mengerjakannya. Baris itu tampil
-- sebagai tanda hubung, bukan ditebak dari pengguna mana pun.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- Peta uuid -> nama tampilan. Dipanggil sekali per permintaan, bukan sekali per baris:
-- jumlah profil hanya belasan sementara dokumennya ribuan.
create or replace function rc_private.peta_nama_pelaku() returns jsonb
language sql stable security definer set search_path='' as $fn$
  select coalesce(jsonb_object_agg(id::text,
           coalesce(nullif(btrim(full_name),''), nullif(btrim(user_code),''), '')), '{}'::jsonb)
    from public.profiles;
$fn$;
revoke all on function rc_private.peta_nama_pelaku() from public,anon;
grant execute on function rc_private.peta_nama_pelaku() to authenticated;

create index if not exists claim_status_history_claim_aksi_idx
  on public.claim_status_history(claim_id, to_status, id desc);

create or replace function public.rc_legacy_workflow() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare rows_json jsonb; nama jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 nama := rc_private.peta_nama_pelaku();

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
   -- Pelaku tiap tahap. Kosong berarti tidak tercatat, bukan tidak pernah terjadi.
   'createdBy',coalesce(nama->>(c.created_by::text),''),
   'submittedBy',coalesce(nama->>(pel.submit_by::text),''),
   'releasedBy',coalesce(nama->>(pel.release_by::text),''),
   'claimedBy',coalesce(nama->>(pel.claim_by::text),''),
   'clearedBy',coalesce(nama->>(pel.clear_by::text),''),
   'versionNo',c.version_no,
   'rebate',lower(btrim(coalesce(ca.cashback_type,'')))='rebate') as x
  from public.claims c
  join public.depots d on d.id=c.depot_id
  join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  left join rc_private.claim_sensitive s on s.claim_id=c.id
  -- Pelaku terakhir untuk tiap tahap. Yang diambil yang terbaru: sebuah dokumen dapat
  -- ditolak lalu di-release ulang, dan yang relevan adalah pelaku terakhir.
  left join lateral (
    select
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='submitted' and h.actor_id is not null))[1] as submit_by,
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='released' and h.actor_id is not null))[1] as release_by,
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='claimed' and h.actor_id is not null))[1] as claim_by,
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='done' and h.actor_id is not null))[1] as clear_by
    from public.claim_status_history h where h.claim_id = c.id) pel on true
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
revoke all on function public.rc_legacy_workflow() from public,anon;
grant execute on function public.rc_legacy_workflow() to authenticated;

create or replace function rc_private.marker_20261029() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261029() from public,anon;
grant execute on function rc_private.marker_20261029() to authenticated;

select 'Pelaku workflow terpasang' as hasil,
 (select count(*) from public.claim_status_history where actor_id is not null) as riwayat_berpelaku,
 (select count(*) from public.claim_status_history where actor_id is null) as riwayat_warisan;
