-- PENDING: belum diterapkan.
--
-- Perbaikan alur workflow dan syarat upload, sesuai instruksi pemilik 17 September 2026.
--
--  1. Submitted muncul di Release, Released di Claim to Finance, Claimed di Clearing,
--     dan Clearing menjadikannya Done.
--  2. Campaign berjenis Rebate TIDAK masuk ketiga antrean itu. Seluruh dokumen Rebate yang
--     berstatus Submitted, Released atau Claimed hanya muncul di Bulk Process, dan Bulk
--     Process mengubahnya langsung menjadi Done.
--  3. Total tagihan dan bulan potong 1-4 tidak wajib.
--  4. TOP diambil otomatis dari Customer Master.
--  5. Approval wajib bila TOP yang diisi melebihi TOP pada Customer Master.
--  6. Jenis CB Transfer: rekening wajib hanya bila Customer Master belum punya. Bila diisi
--     berbeda dari master, isian itu menjadi sumber kebenaran baru dan master diperbarui.
--  7. Satu proses upload maksimal 200 dokumen.

------------------------------------------------------------------------------------------
-- 1. Antrean workflow: Rebate hanya lewat Bulk Process
------------------------------------------------------------------------------------------
-- Sebelumnya dokumen Rebate muncul di Release/Claim/Clearing sekaligus di Bulk Process,
-- sehingga satu dokumen bisa diproses lewat dua jalur berbeda. Itu sumber ketidaksinkronan
-- yang dilaporkan pemilik. Sekarang jalurnya saling lepas.
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
-- 2. Customer Master menjadi sumber isian otomatis di layar upload
------------------------------------------------------------------------------------------
-- Layar Claim Upload mengisi TOP, rekening, KTP dan NPWP dari daftar ini. Sebelumnya isinya
-- diambil dari snapshot klaim terakhir dan tidak memuat TOP sama sekali, sehingga aturan
-- "approval wajib bila TOP melebihi master" tidak pernah dapat dievaluasi dengan benar.
create or replace function rc_private.legacy_customers(p_with_contacts boolean) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object(
   'custCode',cu.customer_code,'custName',cu.customer_name,
   'ktp',case when p_with_contacts then coalesce(cu.ktp,'') else '' end,
   'npwp',case when p_with_contacts then coalesce(cu.npwp,'') else '' end,
   'noRek',case when p_with_contacts then coalesce(cu.account_number,'') else '' end,
   'namaRek',case when p_with_contacts then coalesce(cu.account_name,'') else '' end,
   'bank',case when p_with_contacts then coalesce(cu.bank,'') else '' end,
   'top',coalesce(cu.top_text,''),
   'contactPerson',coalesce(cu.contact_person,''),
   'subyekPajak',coalesce(cu.tax_subject,'')) order by cu.customer_code),'[]'::jsonb)
 from public.customers cu
 where exists(select 1 from public.customer_depots cd
   where cd.customer_id=cu.id and rc_private.can_access(cd.depot_id));
$$;

------------------------------------------------------------------------------------------
-- 3. Dokumen berstatus Not Yet untuk tab Open
------------------------------------------------------------------------------------------
-- Tab Open menampilkan dokumen yang belum pernah diklaim, lalu penggunanya memilih beberapa
-- dan memindahkannya ke grid Mass Upload. Field yang sudah diketahui ikut terbawa sehingga
-- pengguna hanya melengkapi yang benar-benar kosong.
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
   -- Nilai master ikut dikirim supaya grid Mass Upload dan template Excel langsung terisi
   -- dan pengguna hanya melengkapi yang kosong.
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
revoke all on function public.rc_open_claims(text,text,integer,integer) from public,anon;
grant execute on function public.rc_open_claims(text,text,integer,integer) to authenticated;

------------------------------------------------------------------------------------------
-- 4. Syarat upload dan batas 200 dokumen
------------------------------------------------------------------------------------------
-- Batas per proses dinaikkan dari 100 menjadi 200 dokumen.
create or replace function rc_private.mutate_claims(p_action text,p_items jsonb,p_request_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare item jsonb; field record; month_value jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Items must be an array'; end if;
 if octet_length(p_items::text)>524288 then raise exception 'Payload exceeds 512 KiB'; end if;
 for item in select value from jsonb_array_elements(p_items) loop
  if jsonb_typeof(item)<>'object' then raise exception 'Each item must be an object'; end if;
  if jsonb_typeof(item->'no_doc') is distinct from 'string' or btrim(item->>'no_doc')='' or length(item->>'no_doc')>200
    or jsonb_typeof(item->'version_no') is distinct from 'number' or item->>'version_no' !~ '^[1-9][0-9]{0,17}$'
  then raise exception 'Invalid document or version'; end if;
  for field in select key,value from jsonb_each(item) loop
   if field.key not in('no_doc','version_no','tax_subject','total_billing','period_start','period_end','paid_on','approval','billing_months','ktp','npwp','bank','account_number','account_name','top')
   then raise exception 'Unknown item field'; end if;
   if field.key not in('version_no','total_billing','billing_months') then
    if jsonb_typeof(field.value)<>'string' or length(field.value#>>'{}')>2000 then raise exception 'Invalid text field'; end if;
   end if;
  end loop;
  if item ? 'total_billing' and (jsonb_typeof(item->'total_billing')<>'number'
    or item->>'total_billing' !~ '^[0-9]+([.][0-9]+)?$') then raise exception 'Billing must be a finite nonnegative number'; end if;
  if item ? 'period_start' and item->>'period_start'<>'' then
   if item->>'period_start' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Use ISO dates'; end if;
   perform (item->>'period_start')::date;
  end if;
  if item ? 'period_end' and item->>'period_end'<>'' then
   if item->>'period_end' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Use ISO dates'; end if;
   perform (item->>'period_end')::date;
  end if;
  if item ? 'paid_on' and item->>'paid_on'<>'' then
   if item->>'paid_on' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Use ISO dates'; end if;
   perform (item->>'paid_on')::date;
  end if;
  if item ? 'billing_months' then
   if jsonb_typeof(item->'billing_months')<>'array' then raise exception 'Invalid billing months'; end if;
   if jsonb_array_length(item->'billing_months')>4 then raise exception 'Maximum four billing months'; end if;
   for month_value in select value from jsonb_array_elements(item->'billing_months') loop
    if jsonb_typeof(month_value)<>'string' or month_value#>>'{}' !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Use YYYY-MM billing months'; end if;
   end loop;
  end if;
 end loop;
 return rc_private.mutate_claims_unchecked(p_action,p_items,p_request_id,p_reason);
end $$;

-- Aturan bisnis upload berpindah ke server. Browser tetap memvalidasi lebih dulu supaya
-- pesannya cepat, tetapi keputusan akhir tidak boleh bergantung pada browser.
create or replace function rc_private.mutate_claims_unchecked(p_action text,p_items jsonb,p_request_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); perm text; v_payload jsonb; cached rc_private.requests%rowtype;
 c public.claims%rowtype; item jsonb; target text; batch text; stage text; subject text;
 processed jsonb:='[]'; stamp timestamptz:=now();
 cust public.customers%rowtype; camp public.campaigns%rowtype; jenis text;
 v_ktp text; v_npwp text; v_bank text; v_norek text; v_namarek text; v_top text; v_gross numeric;
 master_top numeric; input_top numeric; master_changed boolean;
begin
 if p_action not in('submit','release','claim','clearing','reject_release','reject_claim','reject_clearing','hold','unhold','expire','bulk_rebate')
 or p_action is null then raise exception 'Unknown action'; end if;
 perm:=case when p_action in('submit','hold','unhold','expire') then 'upload_claim'
 when p_action in('release','reject_release') then 'release_claim'
 when p_action='bulk_rebate' then 'bulk_process' else 'process_claim' end;
 if not rc_private.can_access(null,perm) then raise exception 'Access denied' using errcode='42501'; end if;
 if p_request_id is null or p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Invalid request'; end if;
 if jsonb_array_length(p_items) not between 1 and 200 then raise exception 'Satu proses maksimal 200 dokumen'; end if;
 if length(coalesce(p_reason,''))>1000 then raise exception 'Reason too long'; end if;
 if p_action in('reject_release','reject_claim','reject_clearing','hold','unhold','expire') and btrim(coalesce(p_reason,''))='' then raise exception 'Reason required'; end if;
 if exists(select 1 from jsonb_array_elements(p_items) x where jsonb_typeof(x)<>'object' or coalesce(x->>'no_doc','')='' or x->>'version_no' is null)
 or (select count(distinct x->>'no_doc') from jsonb_array_elements(p_items) x)<>jsonb_array_length(p_items)
 then raise exception 'Each claim must have a unique document number and version'; end if;
 v_payload:=jsonb_build_object('action',p_action,'items',p_items,'reason',p_reason);
 insert into rc_private.requests(actor_id,request_id,payload) values(actor,p_request_id,v_payload) on conflict do nothing;
 select * into strict cached from rc_private.requests where actor_id=actor and request_id=p_request_id for update;
 if cached.payload<>v_payload then raise exception 'Request ID reused for different payload'; end if;
 if cached.result is not null then return cached.result; end if;
 stage:=case p_action when 'submit' then '01' when 'release' then '02' when 'claim' then '03' when 'clearing' then '04' when 'bulk_rebate' then '02' end;

 for item in select value from jsonb_array_elements(p_items) order by value->>'no_doc' loop
 select * into c from public.claims where no_doc=item->>'no_doc' for update;
 if not found then raise exception 'Document not found'; end if;
 if c.archived_at is not null then raise exception 'Dokumen % sudah diarsipkan',c.no_doc; end if;
 if not rc_private.can_access(c.depot_id,perm) then raise exception 'Depot access denied' using errcode='42501'; end if;
 if c.version_no<>(item->>'version_no')::bigint then raise exception 'Document changed; refresh first' using errcode='40001'; end if;
 select * into camp from public.campaigns where id=c.campaign_id;
 jenis:=lower(btrim(coalesce(camp.cashback_type,'')));

 -- Rebate hanya boleh lewat Bulk Process; jalur bertahap tidak berlaku untuknya, dan
 -- sebaliknya Bulk Process tidak boleh menyentuh campaign non-Rebate.
 if p_action in('release','claim','clearing','reject_release','reject_claim','reject_clearing')
    and jenis='rebate' then
  raise exception 'Dokumen % berjenis Rebate dan hanya dapat diproses lewat Bulk Process',c.no_doc;
 end if;

 target:=null;
 if p_action='submit' and c.status='not_yet' then target:='submitted';
 elsif p_action='release' and c.status='submitted' then target:='released';
 elsif p_action='claim' and c.status='released' then target:='claimed';
 elsif p_action='clearing' and c.status='claimed' then target:='done';
 elsif p_action='reject_release' and c.status='submitted' then target:='not_yet';
 elsif p_action='reject_claim' and c.status='released' then target:='submitted';
 elsif p_action='reject_clearing' and c.status='claimed' then target:='released';
 elsif p_action='hold' and c.status in('not_yet','submitted','released','claimed') then target:='on_hold';
 elsif p_action='unhold' and c.status='on_hold' and c.previous_status in('not_yet','submitted','released','claimed') then target:=c.previous_status;
 elsif p_action='expire' and c.status in('not_yet','submitted','released','claimed','on_hold') then target:='expired';
 elsif p_action='bulk_rebate' and c.status in('submitted','released','claimed') then
  if jenis<>'rebate' then raise exception 'Dokumen % bukan campaign Rebate',c.no_doc; end if;
  target:='done';
 end if;
 if target is null then raise exception 'Invalid status transition for %',c.no_doc; end if;
 if stage is not null and batch is null then batch:=rc_private.next_batch(stage); end if;

 if p_action='submit' then
  select * into cust from public.customers where id=c.customer_id for update;
  master_changed:=false;

  v_ktp   :=coalesce(nullif(btrim(coalesce(cust.ktp,'')),''),nullif(btrim(coalesce(item->>'ktp','')),''));
  v_npwp  :=coalesce(nullif(btrim(coalesce(cust.npwp,'')),''),nullif(btrim(coalesce(item->>'npwp','')),''));

  -- Rekening: master dipakai bila ada. Bila pengguna mengisi nilai yang BERBEDA, isian itu
  -- menjadi sumber kebenaran baru dan master diperbarui. Ini pengecualian yang diminta
  -- pemilik terhadap aturan umum "master menang".
  v_norek  :=nullif(btrim(coalesce(item->>'account_number','')),'');
  v_namarek:=nullif(btrim(coalesce(item->>'account_name','')),'');
  v_bank   :=nullif(btrim(coalesce(item->>'bank','')),'');
  if v_norek is null then v_norek:=nullif(btrim(coalesce(cust.account_number,'')),'');
  elsif v_norek is distinct from nullif(btrim(coalesce(cust.account_number,'')),'') then master_changed:=true; end if;
  if v_namarek is null then v_namarek:=nullif(btrim(coalesce(cust.account_name,'')),'');
  elsif v_namarek is distinct from nullif(btrim(coalesce(cust.account_name,'')),'') then master_changed:=true; end if;
  if v_bank is null then v_bank:=nullif(btrim(coalesce(cust.bank,'')),'');
  elsif v_bank is distinct from nullif(btrim(coalesce(cust.bank,'')),'') then master_changed:=true; end if;

  -- TOP diambil dari master bila tidak diisi. Bila diisi melebihi TOP master, approval wajib.
  v_top:=coalesce(nullif(btrim(coalesce(item->>'top','')),''),nullif(btrim(coalesce(cust.top_text,'')),''));
  master_top:=case when btrim(coalesce(cust.top_text,'')) ~ '^[0-9]+([.][0-9]+)?$'
                   then btrim(cust.top_text)::numeric else null end;
  input_top :=case when btrim(coalesce(v_top,'')) ~ '^[0-9]+([.][0-9]+)?$'
                   then btrim(v_top)::numeric else null end;
  if input_top is not null and master_top is not null and input_top>master_top
     and nullif(btrim(coalesce(item->>'approval','')),'') is null then
   raise exception 'Dokumen %: TOP % melebihi TOP Customer Master (%), sehingga Approval wajib diisi',
     c.no_doc,input_top,master_top;
  end if;

  subject:=case when v_npwp is not null then 'Badan'
                when v_ktp is not null then 'Perorangan'
                else nullif(btrim(coalesce(item->>'tax_subject',c.tax_subject,'')),'') end;
  if subject is null then
   raise exception 'Dokumen %: KTP atau NPWP pelanggan % belum terisi di Customer Master',c.no_doc,cust.customer_code;
  end if;
  if v_ktp is not null and v_npwp is not null then
   raise exception 'Dokumen %: pelanggan % punya KTP dan NPWP sekaligus; perbaiki di Customer Master',c.no_doc,cust.customer_code;
  end if;

  if jenis='' then
   raise exception 'Dokumen %: Jenis CB campaign % belum ditetapkan di Campaign Master',c.no_doc,camp.campaign_code;
  end if;
  if jenis='transfer' and (v_norek is null or v_namarek is null or v_bank is null) then
   raise exception 'Dokumen %: Jenis CB Transfer memerlukan Nomor Rekening, Nama Rekening dan Bank. Lengkapi di Customer Master atau isi pada baris ini',c.no_doc;
  end if;

  -- Total tagihan dan bulan potong tetap opsional; tidak ada pemeriksaan wajib di sini.

  if master_changed or (v_top is not null and v_top is distinct from nullif(btrim(coalesce(cust.top_text,'')),'')) then
   update public.customers set account_number=v_norek,account_name=v_namarek,bank=v_bank,
     top_text=coalesce(v_top,top_text),updated_at=now(),updated_by=actor
   where id=cust.id;
   insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
   values(actor,c.depot_id,'customer_master_updated_from_upload',c.id,
     jsonb_build_object('custCode',cust.customer_code,'noDoc',c.no_doc));
  end if;

  v_gross:=public.rc_gross_up_legacy(c.cb_net,subject);
  update public.claims set tax_subject=subject,gross_up=v_gross,
    total_billing=case when item ? 'total_billing' then (item->>'total_billing')::numeric else total_billing end,
    period_start=coalesce(nullif(item->>'period_start','')::date,period_start),
    period_end=coalesce(nullif(item->>'period_end','')::date,period_end),paid_on=coalesce(nullif(item->>'paid_on','')::date,paid_on),
    approval=coalesce(item->>'approval',approval),billing_months=coalesce(item->'billing_months',billing_months)
   where id=c.id;
  insert into rc_private.claim_sensitive(claim_id) values(c.id) on conflict do nothing;
  update rc_private.claim_sensitive set ktp=v_ktp,npwp=v_npwp,bank=v_bank,
    account_number=v_norek,account_name=v_namarek,top_text=v_top where claim_id=c.id;
 end if;

 update public.claims set status=target,
 previous_status=case when p_action='hold' then c.status when p_action in('unhold','expire') then null else previous_status end,
 uploaded_at=case when p_action='submit' then stamp when p_action='reject_release' then null else uploaded_at end,
 released_at=case when p_action in('release','bulk_rebate') then stamp when p_action='reject_claim' then null else released_at end,
 claimed_at=case when p_action in('claim','bulk_rebate') then stamp when p_action='reject_clearing' then null else claimed_at end,
 cleared_at=case when p_action in('clearing','bulk_rebate') then stamp else cleared_at end,
 batch_upload=case when p_action='submit' then batch when p_action='reject_release' then null else batch_upload end,
 batch_release=case when p_action in('release','bulk_rebate') then batch when p_action='reject_claim' then null else batch_release end,
 batch_claim=case when p_action in('claim','bulk_rebate') then batch when p_action='reject_clearing' then null else batch_claim end,
 batch_clearing=case when p_action in('clearing','bulk_rebate') then batch else batch_clearing end,
 version_no=version_no+1,updated_at=stamp where id=c.id;
 insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
 values(c.id,actor,c.status,target,p_action,batch,p_reason);
 insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
 values(actor,c.depot_id,p_action,c.id,jsonb_build_object('from',c.status,'to',target,'batch',batch));
 processed:=processed||jsonb_build_array(jsonb_build_object('no_doc',c.no_doc,'status',target,
   'version_no',c.version_no+1,'gross_up',coalesce(v_gross,c.gross_up)));
 end loop;
 v_payload:=jsonb_build_object('processed',processed,'batch',batch,'count',jsonb_array_length(processed));
 update rc_private.requests set result=v_payload where actor_id=actor and request_id=p_request_id;
 return v_payload;
end $$;

------------------------------------------------------------------------------------------
-- 5. Kelola Akses menampilkan seluruh modul dan sub modul
------------------------------------------------------------------------------------------
-- Daftar permission dipusatkan di sini supaya konsol Otorisasi tidak perlu diubah setiap
-- kali ada modul baru: layar membaca daftarnya dari server, bukan dari daftar tetap.
create or replace function public.rc_permission_catalog() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 return jsonb_build_object('status','success','rows',jsonb_build_array(
  jsonb_build_object('key','j','code','upload_claim','modul','Claim Upload','sub','Mass, Manual, Open'),
  jsonb_build_object('key','k','code','release_claim','modul','Release','sub','Antrean Submitted'),
  jsonb_build_object('key','l','code','process_claim','modul','Claim Process','sub','Claim to Finance dan Clearing'),
  jsonb_build_object('key','s','code','bulk_process','modul','Bulk Process','sub','Rebate langsung Done'),
  jsonb_build_object('key','m','code','view_analytics','modul','Analytics','sub','History dan Summary'),
  jsonb_build_object('key','p','code','view_master_depot','modul','Master Depot','sub','Link master per depot'),
  jsonb_build_object('key','n','code','manage_access','modul','Kelola Akses','sub','Akun, permission, depot'),
  jsonb_build_object('key','keyMaster','code','manage_key_master','modul','Key Master','sub','Customer Master dan Campaign Master'),
  jsonb_build_object('key','compilation','code','view_compilation','modul','Cashback Compilation','sub','Lihat dan compile'),
  jsonb_build_object('key','archiveCompilation','code','archive_compilation','modul','Cashback Compilation','sub','Arsipkan baris'),
  jsonb_build_object('key','logs','code','view_logs','modul','Log Aktivitas','sub','Riwayat tindakan')));
end $$;
revoke all on function public.rc_permission_catalog() from public,anon;
grant execute on function public.rc_permission_catalog() to authenticated;

-- view_logs sebelumnya tidak pernah dapat diberikan lewat konsol; sekarang ikut dipetakan.
create or replace function rc_private.legacy_auth_flags() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'j',case when x.p ? 'upload_claim' then 'Yes' else 'No' end,
  'k',case when x.p ? 'release_claim' then 'Yes' else 'No' end,
  'l',case when x.p ? 'process_claim' then 'Yes' else 'No' end,
  'm',case when x.p ? 'view_analytics' then 'Yes' else 'No' end,
  'd',case when x.p ? 'view_analytics' then 'Yes' else 'No' end,
  'n',case when x.p ? 'manage_access' then 'Yes' else 'No' end,
  'p',case when x.p ? 'view_master_depot' then 'Yes' else 'No' end,
  's',case when x.p ? 'bulk_process' then 'Yes' else 'No' end,
  'q','No',
  'logs',case when x.p ? 'view_logs' then 'Yes' else 'No' end,
  'keyMaster',case when x.p ? 'manage_key_master' then 'Yes' else 'No' end,
  'compilation',case when x.p ? 'view_compilation' then 'Yes' else 'No' end,
  'archiveCompilation',case when x.p ? 'archive_compilation' then 'Yes' else 'No' end)
 from (select coalesce(jsonb_object_agg(permission_code,true),'{}'::jsonb) as p
       from public.user_permissions where user_id=(select auth.uid())) x;
$$;

-- Konsol Otorisasi menerima seluruh kunci di atas, termasuk view_logs.
create or replace function public.rc_legacy_update_access(p_user_code text,p_auth jsonb,
 p_depot_codes text default null,p_suffix text default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare target uuid; target_status text; perms text[]; depot_ids uuid[]; new_status text; code text;
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 if p_auth is null or jsonb_typeof(p_auth)<>'object' then raise exception 'Invalid authorization payload'; end if;
 select id,status into target,target_status from public.profiles where user_code=btrim(coalesce(p_user_code,''));
 if target is null then raise exception 'User not found'; end if;
 if target_status='pending' then raise exception 'Setujui pendaftaran ini lebih dahulu di kotak masuk approval'; end if;

 if p_suffix is not null and btrim(p_suffix)<>'' then
  perform rc_private.set_suffix(p_user_code,btrim(p_suffix));
 end if;

 new_status:=case when lower(coalesce(p_auth->>'i','')) in('active','approved','ok') then 'active' else 'inactive' end;

 perms:=array(select code from (values
  ('j','upload_claim'),('k','release_claim'),('l','process_claim'),('m','view_analytics'),
  ('n','manage_access'),('p','view_master_depot'),('s','bulk_process'),('logs','view_logs'),
  ('keyMaster','manage_key_master'),('compilation','view_compilation'),
  ('archiveCompilation','archive_compilation')
 ) as m(letter,code) where lower(coalesce(p_auth->>m.letter,'no')) in('yes','true','approved','visible'));

 if p_depot_codes is null or btrim(p_depot_codes)='' then
  depot_ids:=array(select depot_id from public.user_depot_access where user_id=target);
 else
  depot_ids:='{}'::uuid[];
  foreach code in array string_to_array(p_depot_codes,',') loop
   if btrim(code)<>'' then depot_ids:=depot_ids||public.rc_legacy_depot_id(btrim(code)); end if;
  end loop;
 end if;

 perform rc_private.manage_user(target,new_status,perms,depot_ids);
 return jsonb_build_object('status','success');
end $$;
