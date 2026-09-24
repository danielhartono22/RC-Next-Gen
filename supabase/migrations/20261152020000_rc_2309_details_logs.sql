-- Shared claim chronology and explicit audit context.
create or replace function rc_private.claim_details(c public.claims) returns jsonb
language sql stable security definer set search_path='' as $$
 select case when not rc_private.can_access(c.depot_id) then '{}'::jsonb else jsonb_build_object(
 'tglUpload',rc_private.legacy_ts(c.uploaded_at),'tglApprove',rc_private.legacy_ts(c.approved_at),
 'tglRelease',rc_private.legacy_ts(c.released_at),'tglClaim',rc_private.legacy_ts(c.claimed_at),
 'tglClearing',rc_private.legacy_ts(c.cleared_at),'tglBulk',rc_private.legacy_ts(c.bulk_processed_at),
 'submittedAt',c.uploaded_at,'approvedAt',c.approved_at,'releasedAt',c.released_at,'claimedAt',c.claimed_at,'doneAt',c.cleared_at,
 'batchUpload',coalesce(c.batch_upload,''),'batchRelease',coalesce(c.batch_release,''),
 'batchClaim',coalesce(c.batch_claim,''),'batchClearing',coalesce(c.batch_clearing,''),
 'soStart',rc_private.legacy_date(coalesce(c.extend_so_start,c.period_start)),
 'soEnd',rc_private.legacy_date(coalesce(c.extend_so_end,c.period_end)),
 'billingStart',rc_private.legacy_date(c.extend_billing_start),'billingEnd',rc_private.legacy_date(c.extend_billing_end),
 'remark',rc_private.claim_remark(c),'processBy',coalesce((select p.full_name from public.claim_status_history h
   join public.profiles p on p.id=h.actor_id where h.claim_id=c.id order by h.id desc limit 1),''),
 'pendingGroup',case when c.status in('not_yet','submitted') then 'Pending Depot'
 when c.status in('approved','released') then 'Pending OSC' when c.status='claimed' then 'Pending Finance'
 when c.status='done' then 'Done' else rc_private.legacy_status(c.status) end) end;
$$;

alter table public.activity_logs add column if not exists module text;
alter table public.activity_logs add column if not exists tab text;
alter table public.activity_logs add column if not exists process_stage text;
alter table public.activity_logs add column if not exists batch_no text;
create or replace function rc_private.audit_context() returns trigger
language plpgsql security definer set search_path='' as $$
declare event text:=new.event_type;
begin
 new.created_at:=coalesce(new.created_at,now());
 new.batch_no:=coalesce(nullif(new.batch_no,''),new.details->>'batch',new.details->>'batchNum');
 new.module:=coalesce(nullif(new.module,''),case
  when event in('submit','hold','unhold','expire','posting_exception','customer_master_updated_from_upload') then 'Claim Upload'
  when event in('approve','reject_approval','approve_hold','reject_hold','manual_complete') then 'Management of Approval'
  when event in('release','reject_release') then 'Release'
  when event in('claim','clearing','reject_claim','reject_clearing','expire_claim_process') then 'Claim Process'
  when event like '%bulk%' then 'Bulk Process' when event like '%compile%' then 'Document Center'
  when event like '%profil%' or event like 'depot_%' then 'Profil Depot'
  when event like '%timetable%' then 'Timetable'
  when event like '%account%' or event like '%registration%' or event like '%access%' or event like '%pin%' then 'Access Management'
  when event like '%customer%' or event like '%campaign%' then 'Key Master'
  when event like '%email%' then 'Access Management' else 'System' end);
 new.tab:=coalesce(nullif(new.tab,''),case
  when event in('submit','hold','unhold','expire','posting_exception','customer_master_updated_from_upload') then 'Posting'
  when event in('approve','reject_approval','manual_complete') then 'Approval'
  when event in('approve_hold','reject_hold') then 'Hold / Expired'
  when event in('claim','reject_claim') then 'Claim to Finance'
  when event in('clearing','reject_clearing') then 'Clearing'
  when event like '%compile%' then 'Compile' when event like '%registration%' or event='account_created' then 'Registrasi'
  when event like '%email%' then 'Email Otomatis' else new.module end);
 new.process_stage:=coalesce(nullif(new.process_stage,''),new.details->>'to',event);
 return new;
end $$;
drop trigger if exists rc_audit_context on public.activity_logs;
create trigger rc_audit_context before insert on public.activity_logs for each row execute function rc_private.audit_context();
revoke all on function rc_private.audit_context() from public,anon,authenticated;

create or replace function public.rc_log_context(p_detail text,p_module text,p_tab text,p_batch text default '',p_stage text default '')
returns void language plpgsql security definer set search_path='' as $$
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 insert into public.activity_logs(actor_id,event_type,details,module,tab,process_stage,batch_no)
 values(auth.uid(),'ui_activity',jsonb_build_object('detail',left(p_detail,1000)),left(p_module,100),left(p_tab,100),left(p_stage,100),left(p_batch,200));
end $$;
revoke all on function public.rc_log_context(text,text,text,text,text) from public,anon;
grant execute on function public.rc_log_context(text,text,text,text,text) to authenticated;

create or replace function public.rc_legacy_logs(p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not rc_private.can_access(null,'view_logs') and not rc_private.is_manager() then raise exception 'Access denied' using errcode='42501'; end if;
 return jsonb_build_object('status','success','logs',coalesce((select jsonb_agg(jsonb_build_object(
 'timestamp',to_char(l.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'), 'timestampIso',l.created_at,
 'userId',coalesce(p.user_code,''),'role',coalesce(p.role,''),'detail',coalesce(l.details->>'detail',l.event_type),
 'module',coalesce(l.module,'Legacy'),'tab',coalesce(l.tab,'Tidak tercatat'),
 'stage',coalesce(l.process_stage,l.event_type),'batch',coalesce(l.batch_no,l.details->>'batch','-')) order by l.id desc)
 from (select a.* from public.activity_logs a where a.created_at>=now()-make_interval(days=>least(greatest(coalesce(p_days,30),1),365))
 and (rc_private.is_system_manager() or a.actor_id=auth.uid() or (a.depot_id is not null and rc_private.can_access(a.depot_id))
 or (a.depot_id is null and rc_private.can_manage_user(a.actor_id))) order by a.id desc limit 2000) l
 left join public.profiles p on p.id=l.actor_id),'[]'::jsonb));
end $$;
notify pgrst,'reload schema';

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
    'validYear',extract(year from coalesce(c.period_start,ca.period_start))::text,'totalClaim',c.cb_net,'grossUpCb',c.gross_up,
    'tglUpload',rc_private.legacy_ts(c.uploaded_at),
    'tglClearing',rc_private.legacy_ts(c.cleared_at),
    -- Field yang sebelumnya hilang dan membuat kolom menampilkan "undefined".
    'tglProses',case when c.status='done' and c.cleared_at is not null
                     then rc_private.legacy_ts(c.cleared_at) else '-' end,
    'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),
    'batchUpload',coalesce(c.batch_upload,''),'batchClearing',coalesce(c.batch_clearing,'')) || rc_private.claim_details(c)
    order by c.updated_at desc)
   from public.claims c
   join public.depots d on d.id=c.depot_id
   join public.customers cu on cu.id=c.customer_id
   join public.campaigns ca on ca.id=c.campaign_id
   left join lateral (select h.actor_id from public.claim_status_history h
     where h.claim_id=c.id and h.action='submit' order by h.id desc limit 1) sub on true
   left join public.profiles p on p.id=sub.actor_id where c.archived_at is null and rc_private.can_access(c.depot_id)
   -- Filter not_yet dibuang. Pemilik meminta Cashback List memuat SELURUH customer apa pun
  -- statusnya, termasuk Not Yet dan sel kosong, karena daftar ini dipakai sebagai gambaran
  -- menyeluruh, bukan hanya antrean yang sedang berjalan.
  ),'[]'::jsonb),
  'compileData',coalesce((select jsonb_agg(jsonb_build_object(
    'depotName',d.depot_name,'codeCampaign',ca.campaign_code,'campaign',ca.campaign_name,
    'validYear',extract(year from coalesce(c.period_start,ca.period_start))::text,'reward',c.cb_net,'kodeToko',cu.customer_code))
   from public.claims c
   join public.depots d on d.id=c.depot_id
   join public.customers cu on cu.id=c.customer_id
   join public.campaigns ca on ca.id=c.campaign_id where c.archived_at is null and rc_private.can_access(c.depot_id)),'[]'::jsonb));
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_customer_list(p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 select coalesce(jsonb_agg(x order by x->>'custCode'),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'depotNames',array(select d.depot_name from public.customer_depots cd join public.depots d on d.id=cd.depot_id where cd.customer_id=cu.id and rc_private.can_access(d.id) order by d.depot_code), 'regions',array(select distinct d.region from public.customer_depots cd join public.depots d on d.id=cd.depot_id where cd.customer_id=cu.id and rc_private.can_access(d.id) and d.region is not null), 'id',cu.id,'custCode',cu.customer_code,'custName',cu.customer_name,
   'top',coalesce(cu.top_text,''),'ktp',coalesce(cu.ktp,''),'npwp',coalesce(cu.npwp,''),
   'subyekPajak',coalesce(cu.tax_subject,''),
   'namaRek',coalesce(cu.account_name,''),'noRek',coalesce(cu.account_number,''),
   'bank',coalesce(cu.bank,''),'contactPerson',coalesce(cu.contact_person,''),
   'depotCodes',array(select d.depot_code from public.customer_depots cd
     join public.depots d on d.id=cd.depot_id where cd.customer_id=cu.id and rc_private.can_access(d.id) order by d.depot_code)) as x
  from public.customers cu
  where cu.archived_at is null and (coalesce(btrim(p_search),'')=''
     or cu.customer_code ilike '%'||btrim(p_search)||'%'
     or cu.customer_name ilike '%'||btrim(p_search)||'%')
  order by cu.customer_code
  limit least(greatest(coalesce(p_limit,50),1),200) offset greatest(coalesce(p_offset,0),0)) t;
 return jsonb_build_object('status','success','rows',v,
  'total',(select count(*) from public.customers cu where archived_at is null and (coalesce(btrim(p_search),'')='' or cu.customer_code ilike '%'||btrim(p_search)||'%' or cu.customer_name ilike '%'||btrim(p_search)||'%')));
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_open_claims_filtered(p_search text DEFAULT ''::text, p_campaign text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 200, p_cb_type text DEFAULT '')
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb; jml bigint;
begin
 if not rc_private.can_access(null,'upload_claim') then
  raise exception 'Access denied' using errcode='42501'; end if;

 select count(*) into jml from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  join public.customers cu on cu.id=c.customer_id
  where c.status='not_yet' and c.pending_approval is null and c.archived_at is null
    and (coalesce(btrim(p_cb_type),'')='' or rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type))=rc_private.jenis_efektif(p_cb_type)) and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%');

 select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'noDoc',c.no_doc,'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'statusPajakCamp',coalesce(ca.tax_status,''),
   'cbNet',c.cb_net,'dcCode',d.depot_code,'depotName',d.depot_name,
   'top',coalesce(cu.top_text,''),'ktp',coalesce(cu.ktp,''),'npwp',coalesce(cu.npwp,''),
   'noRek',coalesce(cu.account_number,''),'namaRek',coalesce(cu.account_name,''),
   'bank',coalesce(cu.bank,''),'subyekPajak',coalesce(cu.tax_subject,''),
   'contactPerson',coalesce(cu.contact_person,''),
   -- Dua kolom baru yang diminta pemilik.
   'createdOn',to_char(c.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY'),
   'createdBy',coalesce(p.user_code,''),
   'versionNo',c.version_no) as x
  from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  join public.customers cu on cu.id=c.customer_id
  join public.depots d on d.id=c.depot_id
  left join public.profiles p on p.id=c.created_by
  where c.status='not_yet' and c.pending_approval is null and c.archived_at is null
    and (coalesce(btrim(p_cb_type),'')='' or rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type))=rc_private.jenis_efektif(p_cb_type)) and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,200),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 return jsonb_build_object('status','success','rows',v,'total',jml);
end $function$
;
revoke all on function public.rc_open_claims_filtered(text,text,integer,integer,text) from public,anon;
grant execute on function public.rc_open_claims_filtered(text,text,integer,integer,text) to authenticated;
CREATE OR REPLACE FUNCTION public.rc_depot_profile_request(p_kode text, p_perubahan jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_depot uuid; v_kode text; v_id uuid; v_bersih jsonb := '{}'::jsonb; k text;
  v_izin text[] := array['tipeDepot','alamat','gmapsUrl','fotoUrl','kepalaDepot','kepalaAdmin',
    'karAdmin','karSales','karDriver','karFg','karPcc','karTeknisi','karLain',
    'emailRsm','emailAsm','emailSm','emailDepot','nama','abbr','region','emailTo','emailCc','grade'];
begin
  v_kode := upper(btrim(coalesce(p_kode,'')));
  select id into v_depot from public.depots where depot_code = v_kode;
  if v_depot is null then raise exception 'Depot "%" tidak ditemukan', v_kode; end if;
  if not rc_private.can_access(v_depot) then
    raise exception 'Depot ini di luar yurisdiksi Anda' using errcode='42501'; end if;
  if p_perubahan is null or octet_length(p_perubahan::text)>20000 or jsonb_typeof(p_perubahan) <> 'object' then raise exception 'Perubahan tidak sah'; end if;

  -- Hanya kunci yang diizinkan yang diteruskan. Grade sengaja tidak ada di daftar: ia wewenang
  -- System Manager, dan membiarkannya lewat di sini akan menjadi pintu belakang.
  for k in select jsonb_object_keys(p_perubahan) loop
    if not k=any(v_izin) then raise exception 'Kolom profil tidak dikenali: %',k; end if;
    if jsonb_typeof(p_perubahan->k) not in('string','number','null') then raise exception 'Nilai profil tidak sah'; end if;
    if k like 'kar%' and coalesce(p_perubahan->>k,'') !~ '^[0-9]{1,6}$' then raise exception 'Jumlah karyawan harus bilangan bulat nonnegatif'; end if;
    if k = any(v_izin) then
      v_bersih := v_bersih || jsonb_build_object(k, p_perubahan->k);
    end if;
  end loop;
  if v_bersih = '{}'::jsonb then
    raise exception 'Tidak ada perubahan yang dapat diajukan'; end if;

  -- Alamat email diperiksa saat diajukan, bukan saat disetujui, supaya yang mengetik salah
  -- langsung tahu dan bukan penyetuju yang menemukannya beberapa hari kemudian.
  perform rc_private.periksa_email_maks(v_bersih->>'emailRsm','Email RSM');
  perform rc_private.periksa_email_maks(v_bersih->>'emailAsm','Email ASM');
  perform rc_private.periksa_email_maks(v_bersih->>'emailSm','Email SM');
  perform rc_private.periksa_email_maks(v_bersih->>'emailDepot','Email Depot');

  insert into public.depot_profile_requests(depot_id,requester_id,perubahan)
  values(v_depot,(select auth.uid()),v_bersih)
  returning id into v_id;

  insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
  values((select auth.uid()),v_depot,'profil_diajukan',v_id,
         jsonb_build_object('kolom',(select count(*) from jsonb_object_keys(v_bersih))));

  return jsonb_build_object('status','success','id',v_id,
    'message','Pengajuan dikirim. Nilai lama tetap berlaku sampai Supervisor wilayah atau System Manager menyetujui.');
end $function$
;
CREATE OR REPLACE FUNCTION rc_private.terapkan_depot(p_depot uuid, c jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  update public.depots set
    depot_name   = case when c ? 'nama'    then coalesce(nullif(btrim(c->>'nama'),''), depot_name) else depot_name end,
    abbr         = case when c ? 'abbr'    then nullif(upper(btrim(coalesce(c->>'abbr',''))),'') else abbr end,
    region       = case when c ? 'region'  then nullif(btrim(coalesce(c->>'region','')),'') else region end,
    address      = case when c ? 'alamat'  then nullif(btrim(coalesce(c->>'alamat','')),'') else address end,
    email_to     = case when c ? 'emailTo' then nullif(btrim(coalesce(c->>'emailTo','')),'') else email_to end,
    email_cc     = case when c ? 'emailCc' then nullif(btrim(coalesce(c->>'emailCc','')),'') else email_cc end,
    updated_at   = now(), updated_by = (select auth.uid())
  where id = p_depot;

  insert into public.depot_profiles(depot_id) values(p_depot) on conflict(depot_id) do nothing;

  update public.depot_profiles set
    tipe_depot   = case when c ? 'tipeDepot'   then nullif(btrim(c->>'tipeDepot'),'')   else tipe_depot end,
    alamat       = case when c ? 'alamat'      then nullif(btrim(c->>'alamat'),'')      else alamat end,
    gmaps_url    = case when c ? 'gmapsUrl'    then nullif(btrim(c->>'gmapsUrl'),'')    else gmaps_url end,
    foto_url     = case when c ? 'fotoUrl'     then nullif(btrim(c->>'fotoUrl'),'')     else foto_url end,
    kepala_depot = case when c ? 'kepalaDepot' then nullif(btrim(c->>'kepalaDepot'),'') else kepala_depot end,
    kepala_admin = case when c ? 'kepalaAdmin' then nullif(btrim(c->>'kepalaAdmin'),'') else kepala_admin end,
    kar_admin    = case when c ? 'karAdmin'   then greatest(coalesce((c->>'karAdmin')::int,0),0)   else kar_admin end,
    kar_sales    = case when c ? 'karSales'   then greatest(coalesce((c->>'karSales')::int,0),0)   else kar_sales end,
    kar_driver   = case when c ? 'karDriver'  then greatest(coalesce((c->>'karDriver')::int,0),0)  else kar_driver end,
    kar_fg       = case when c ? 'karFg'      then greatest(coalesce((c->>'karFg')::int,0),0)      else kar_fg end,
    kar_pcc      = case when c ? 'karPcc'     then greatest(coalesce((c->>'karPcc')::int,0),0)     else kar_pcc end,
    kar_teknisi  = case when c ? 'karTeknisi' then greatest(coalesce((c->>'karTeknisi')::int,0),0) else kar_teknisi end,
    kar_lain     = case when c ? 'karLain'    then greatest(coalesce((c->>'karLain')::int,0),0)    else kar_lain end,
    email_rsm    = case when c ? 'emailRsm'   then rc_private.periksa_email_maks(c->>'emailRsm','Email RSM') else email_rsm end,
    email_asm    = case when c ? 'emailAsm'   then rc_private.periksa_email_maks(c->>'emailAsm','Email ASM') else email_asm end,
    email_sm     = case when c ? 'emailSm'    then rc_private.periksa_email_maks(c->>'emailSm','Email SM')   else email_sm end,
    grade = case when c ? 'grade' then nullif(btrim(c->>'grade'),'') else grade end,
    email_depot  = case when c ? 'emailDepot' then rc_private.periksa_email_maks(c->>'emailDepot','Email Depot') when c ? 'emailTo'    then nullif(btrim(c->>'emailTo'),'') else email_depot end,
    updated_at = now(), updated_by = (select auth.uid())
  where depot_id = p_depot;
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_depot_profile_review(p_id uuid, p_setujui boolean, p_catatan text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.depot_profile_requests; v_kode text;
begin
  if not rc_private.is_manager() then
    raise exception 'Hanya Supervisor atau System Manager yang dapat menyetujui' using errcode='42501'; end if;
  select * into r from public.depot_profile_requests where id=p_id and status='pending' for update;
  if not found then raise exception 'Pengajuan tidak ditemukan atau sudah diproses'; end if;
  if not rc_private.can_access(r.depot_id) then
    raise exception 'Depot ini di luar wilayah Anda' using errcode='42501'; end if;
  if r.requester_id=auth.uid() then raise exception 'Reviewer harus berbeda dari pemohon' using errcode='42501'; end if;
  if p_setujui is null then raise exception 'Keputusan wajib diisi'; end if;
  select depot_code into v_kode from public.depots where id=r.depot_id;

  if not coalesce(p_setujui,false) then
    update public.depot_profile_requests
       set status='rejected', reviewer_id=(select auth.uid()), reviewed_at=now(),
           catatan=left(btrim(coalesce(p_catatan,'')),300)
     where id=p_id;
    insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details) values(auth.uid(),r.depot_id,'depot_rejected',p_id,jsonb_build_object('note',left(p_catatan,300)));
    return jsonb_build_object('status','success','message','Pengajuan '||v_kode||' ditolak.');
  end if;

  perform rc_private.terapkan_depot(r.depot_id, r.perubahan);

  update public.depot_profile_requests
     set status='approved', reviewer_id=(select auth.uid()), reviewed_at=now(),
         catatan=left(btrim(coalesce(p_catatan,'')),300)
   where id=p_id;

  insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
  values((select auth.uid()),r.depot_id,'depot_disetujui',p_id,r.perubahan);

  return jsonb_build_object('status','success','message','Depot '||v_kode||' diperbarui.');
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_timetable_matrix(p_filter jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
       where rc_private.can_access(d.id)
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

      'topNotYet', rc_private.timetable_top_notyet(),

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
end $function$
;
