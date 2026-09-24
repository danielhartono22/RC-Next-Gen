-- Additional coverage for tab enforcement, profile fields, audit and read-model consistency.
create index if not exists claim_status_history_claim_time_idx on public.claim_status_history(claim_id,created_at desc,id desc);
insert into rc_private.tab_catalog(code,module,label,permission,key,tab,title) values('archive.execute','archive','Document Center — hak arsip','archive_compilation','archiveCompilation','execute','Archive / Restore') on conflict(code) do nothing;
CREATE OR REPLACE FUNCTION public.rc_depot_profile(p_kode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_depot uuid; v_kode text;
begin
 perform rc_private.require_tab('profile.view');
  v_kode := upper(btrim(coalesce(p_kode,'')));
  select id into v_depot from public.depots where depot_code = v_kode;
  if v_depot is null then raise exception 'Depot "%" tidak ditemukan', v_kode; end if;
  if not rc_private.can_access(v_depot) then
    raise exception 'Depot ini di luar yurisdiksi Anda' using errcode='42501'; end if;

  return (
    select jsonb_build_object(
      'status','success',
      'kodeDepot', d.depot_code,
      'namaDepot', d.depot_name,'abbr',coalesce(d.abbr,''),'emailTo',coalesce(d.email_to,''),'emailCc',coalesce(d.email_cc,''),
      -- Region mengikuti master depot; kode depot adalah kuncinya.
      'region', coalesce(nullif(btrim(d.region),''),'(belum diisi)'),
      'tipeDepot', coalesce(p.tipe_depot,''),
      'grade', coalesce(p.grade,''),
      'alamat', coalesce(p.alamat, d.address, ''),
      'gmapsUrl', coalesce(p.gmaps_url,''),
      'fotoUrl', coalesce(p.foto_url,''),
      'kepalaDepot', coalesce(p.kepala_depot, d.head_depot, ''),
      'kepalaAdmin', coalesce(p.kepala_admin, d.kepala_admin, ''),
      'karyawan', jsonb_build_object(
        'admin',   coalesce(p.kar_admin,0),  'sales',  coalesce(p.kar_sales,0),
        'driver',  coalesce(p.kar_driver,0), 'fg',     coalesce(p.kar_fg,0),
        'pcc',     coalesce(p.kar_pcc,0),    'teknisi',coalesce(p.kar_teknisi,0),
        'lain',    coalesce(p.kar_lain,0),
        -- Total dihitung, tidak diketik. Dua angka yang bisa berbeda hanya mengundang
        -- pertanyaan yang tidak bisa dijawab.
        'total',   coalesce(p.kar_admin,0)+coalesce(p.kar_sales,0)+coalesce(p.kar_driver,0)
                  +coalesce(p.kar_fg,0)+coalesce(p.kar_pcc,0)+coalesce(p.kar_teknisi,0)
                  +coalesce(p.kar_lain,0)),
      'emailRsm',   coalesce(p.email_rsm,''),
      'emailAsm',   coalesce(p.email_asm,''),
      'emailSm',    coalesce(p.email_sm,''),
      'emailDepot', coalesce(nullif(p.email_depot,''), d.email_to, ''),

      -- Tim pengawas diturunkan dari penugasan yang berlaku, bukan diketik ulang.
      'timPengawas', coalesce((
        select jsonb_agg(distinct jsonb_build_object(
                 'userId', o.user_code, 'nama', o.full_name, 'peran', o.role)
               )
          from public.user_depot_access a
          join public.profiles o on o.id = a.user_id
         where a.depot_id = d.id and o.role in('osc','supervisor') and o.status='active'
      ), '[]'::jsonb),

      -- Akun terdaftar pada depot ini, juga diturunkan.
      'akunTerdaftar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'userId', u.user_code, 'nama', u.full_name, 'peran', u.role, 'status', u.status)
               order by u.user_code)
          from public.user_depot_access a
          join public.profiles u on u.id = a.user_id
         where a.depot_id = d.id
      ), '[]'::jsonb),

      'pengajuanTertunda', (select count(*) from public.depot_profile_requests r
                             where r.depot_id = d.id and r.status='pending'),
      'diperbaruiPada', to_char(p.updated_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI')
    )
    from public.depots d
    left join public.depot_profiles p on p.depot_id = d.id
   where d.id = v_depot);
end $function$;
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
    email_rsm    = case when c ? 'emailRsm'   then rc_private.periksa_email_maks(c->>'emailRsm','Email RSM',4) else email_rsm end,
    email_asm    = case when c ? 'emailAsm'   then rc_private.periksa_email_maks(c->>'emailAsm','Email ASM',4) else email_asm end,
    email_sm     = case when c ? 'emailSm'    then rc_private.periksa_email_maks(c->>'emailSm','Email SM',4)   else email_sm end,
    grade = case when c ? 'grade' then nullif(btrim(c->>'grade'),'') else grade end,
    email_depot  = case when c ? 'emailDepot' then rc_private.periksa_email_maks(c->>'emailDepot','Email Depot',4) when c ? 'emailTo'    then nullif(btrim(c->>'emailTo'),'') else email_depot end,
    updated_at = now(), updated_by = (select auth.uid())
  where depot_id = p_depot;
end $function$;
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
 perform rc_private.require_tab('profile.edit');
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
  perform rc_private.periksa_email_maks(v_bersih->>'emailRsm','Email RSM',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailAsm','Email ASM',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailSm','Email SM',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailDepot','Email Depot',4);

  perform rc_private.periksa_email_maks(v_bersih->>'emailTo','Email To',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailCc','Email CC',4);
  if v_bersih ? 'nama' and btrim(v_bersih->>'nama')='' then raise exception 'Nama depot wajib diisi';end if;
  if v_bersih ? 'abbr' and btrim(v_bersih->>'abbr')='' then raise exception 'Abbreviation wajib diisi';end if;
  insert into public.depot_profile_requests(depot_id,requester_id,perubahan)
  values(v_depot,(select auth.uid()),v_bersih)
  returning id into v_id;

  insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
  values((select auth.uid()),v_depot,'profil_diajukan',v_id,
         jsonb_build_object('kolom',(select count(*) from jsonb_object_keys(v_bersih))));

  return jsonb_build_object('status','success','id',v_id,
    'message','Pengajuan dikirim. Nilai lama tetap berlaku sampai Supervisor wilayah atau System Manager menyetujui.');
end $function$;
CREATE OR REPLACE FUNCTION public.rc_legacy_bootstrap()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare me public.profiles%rowtype; flags jsonb; depot_ids uuid[]; home public.depots%rowtype;
 may_read_contacts boolean; result jsonb; sm boolean;
begin
 select * into me from public.profiles where id=(select auth.uid());
 if not found then raise exception 'Profile not found' using errcode='42501'; end if;
 if me.status='pending' then
  return jsonb_build_object('status','error','pendingApproval',true,
   'message','Pendaftaran Anda sudah diterima dan menunggu persetujuan System Manager.');
 end if;
 if me.status='rejected' then
  return jsonb_build_object('status','error','message',
   coalesce(nullif(me.review_note,''),'Pendaftaran Anda tidak disetujui. Hubungi System Manager.'));
 end if;
 if me.status<>'active' then
  return jsonb_build_object('status','error','message','Akun dinonaktifkan administrator.');
 end if;
 if me.must_change_password then
  return jsonb_build_object('status','error','message','Ganti PIN sebelum mengakses sistem.','mustChangePassword',true);
 end if;

 sm:=me.role='system manager';
 flags:=rc_private.legacy_auth_flags();

 if sm then
  depot_ids:=array(select id from public.depots);
 else
  select coalesce(array_agg(depot_id),'{}'::uuid[]) into depot_ids
   from public.user_depot_access where user_id=me.id;
 end if;
 -- Depot rumah yang ditetapkan di Access Management menang. Urutan abjad hanya cadangan,
 -- dan bagi System Manager - yang melihat seluruh depot - cadangan itu selalu '1A',
 -- yaitu depot yang tidak ada hubungannya dengan tempat ia bekerja.
 select * into home from public.depots where id=me.home_depot_id;
 if not found then
  select * into home from public.depots where id=any(depot_ids) order by depot_code limit 1;
 end if;
 may_read_contacts:=rc_private.can_access(null,'upload_claim');

 result:=jsonb_build_object(
  'status','success',
  'data',jsonb_build_object(
   'userId',me.user_code,'namaLengkap',me.full_name,'role',me.role,'sysRole',me.role,
   'email',me.business_email,'activation','active','suffix',me.suffix_num,
   'kodeDepot',coalesce(home.depot_code,''),'depot',coalesce(home.depot_name,''),
   'regional',coalesce(home.region,''),'tabs',rc_private.tab_rights(me.id),'auth',flags,
   'managedDepots',coalesce((select jsonb_agg(depot_code order by depot_code)
     from public.depots where id=any(depot_ids)),'[]'::jsonb),
   'depotDetail',jsonb_build_object(
    'kode',coalesce(home.depot_code,''),'nama',coalesce(home.depot_name,''),
    'alamat',coalesce(home.address,''),'link',coalesce(home.master_link,''))),
  'depots',coalesce((select jsonb_agg(jsonb_build_object(
     'kode',depot_code,'nama',depot_name,'link',coalesce(master_link,''))
     order by depot_code) from public.depots where id=any(depot_ids)),'[]'::jsonb),
  'campaigns',coalesce((select jsonb_agg(jsonb_build_object(
     'codeCampaign',campaign_code,'campaignName',campaign_name,
     'jenisCb',rc_private.cb_label(cashback_type),'statusPajak',coalesce(tax_status,''),
     'masterCode','','masterCodeName','',
     'periodStart',rc_private.legacy_date(period_start),'periodEnd',rc_private.legacy_date(period_end))
     order by campaign_code) from public.campaigns),'[]'::jsonb),
  'documents',rc_private.legacy_documents(),
  'customers',rc_private.legacy_customers(may_read_contacts));
 return result;
end $function$;
CREATE OR REPLACE FUNCTION public.rc_compilation_list(p_campaign text DEFAULT ''::text, p_batch text DEFAULT ''::text, p_status text DEFAULT ''::text, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb; jml bigint;
begin
 perform rc_private.require_tab('compilation.list');
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
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'statusPajak',coalesce(ca.tax_status,''),
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
end $function$;
CREATE OR REPLACE FUNCTION public.rc_reprocessing_list(p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb; jml bigint; v_cari text;
begin
 perform rc_private.require_tab('compilation.reprocess');
  if not rc_private.can_access(null,'view_compilation') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak membuka Cashback Compilation' using errcode='42501'; end if;
  v_cari := nullif(btrim(coalesce(p_search,'')),'');

  select count(*) into jml
    from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
    join public.customers cu on cu.id = c.customer_id
   where c.status = 'on_hold' and c.archived_at is null and c.pending_approval is null
     and (v_cari is null or c.no_doc ilike '%'||v_cari||'%'
          or cu.customer_code ilike '%'||v_cari||'%' or cu.customer_name ilike '%'||v_cari||'%');

  select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
    select jsonb_build_object(
      'noDoc',c.no_doc,
      'kodeCampaign',ca.campaign_code,'namaCampaign',ca.campaign_name,
      'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
      'totalCashback',c.cb_net,
      'dcCode',d.depot_code,'depotName',d.depot_name,
      -- Tanggal yang ditetapkan saat On Hold. Ditampilkan supaya penyunting tahu batas baru
      -- dokumen ini, dan ikut terbawa ke berkas unduhan.
      'soStart',c.extend_so_start,'soEnd',c.extend_so_end,
      'billingStart',c.extend_billing_start,'billingEnd',c.extend_billing_end,
      'ditahanPada',to_char(c.updated_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
      'alasan',coalesce((select h.reason from public.claim_status_history h
                          where h.claim_id=c.id and h.action in('hold','request_hold')
                          order by h.id desc limit 1),''),
      'versionNo',c.version_no) as x
    from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
    join public.customers cu on cu.id = c.customer_id
    join public.depots d on d.id = c.depot_id
   where c.status = 'on_hold' and c.archived_at is null and c.pending_approval is null
     and (v_cari is null or c.no_doc ilike '%'||v_cari||'%'
          or cu.customer_code ilike '%'||v_cari||'%' or cu.customer_name ilike '%'||v_cari||'%')
   order by c.updated_at desc, c.no_doc
   limit least(greatest(coalesce(p_limit,200),1),2000)
  offset greatest(coalesce(p_offset,0),0)) t;

  return jsonb_build_object('status','success','rows',v,'total',jml);
end $function$;
CREATE OR REPLACE FUNCTION public.rc_campaign_list(p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb; nama jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 -- Nama pembuat lewat peta SECURITY DEFINER: profiles hanya membuka baris diri sendiri, jadi
 -- join langsung akan membuat kolom Created by kosong bagi hampir semua orang.
 nama := rc_private.peta_nama_pelaku();
 select coalesce(jsonb_agg(x order by x->>'codeCampaign'),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'id',ca.id,'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'periodStart',coalesce(ca.period_start_text,''),'periodEnd',coalesce(ca.period_end_text,''),
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'statusPajak',coalesce(ca.tax_status,''),
   'status',ca.status,
   'createdOn',to_char(ca.created_at at time zone 'Asia/Jakarta','DD/MM/YYYY'),
   'createdBy',coalesce(nama->>(ca.created_by::text),''),
   'memoPath',coalesce(ca.memo_path,''),'memoName',coalesce(ca.memo_name,''),
   'memoSize',coalesce(ca.memo_size,0),
   'memoUploadedOn',case when ca.memo_uploaded_at is null then ''
     else to_char(ca.memo_uploaded_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI') end,
   'jumlahClaim',(select count(*) from public.claims c where c.campaign_id=ca.id and c.archived_at is null),
   'nilaiClaim',(select coalesce(sum(c.cb_net),0) from public.claims c
                  where c.campaign_id=ca.id and c.archived_at is null)) as x
  from public.campaigns ca
  where ca.archived_at is null and (coalesce(btrim(p_search),'')=''
     or ca.campaign_code ilike '%'||btrim(p_search)||'%'
     or ca.campaign_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code
  limit least(greatest(coalesce(p_limit,50),1),200) offset greatest(coalesce(p_offset,0),0)) t;
 return jsonb_build_object('status','success','rows',v,
  'total',(select count(*) from public.campaigns where archived_at is null));
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_legacy_dashboard()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
 if not (rc_private.can_tab('analytics.history') or rc_private.can_tab('analytics.summary')) then raise exception 'Analytics tab access denied' using errcode='42501';end if;
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
   left join public.profiles p on p.id=sub.actor_id where (rc_private.can_tab('analytics.history') or rc_private.can_tab('analytics.summary')) and c.archived_at is null and rc_private.can_access(c.depot_id)
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
end $function$;
CREATE OR REPLACE FUNCTION public.rc_master_archive(p_jenis text, p_kunci jsonb, p_alasan text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  aku uuid := (select auth.uid());
  kunci text; v_id uuid; v_nama text; n_terbuka bigint;
  n_ok integer := 0; gagal jsonb := '[]'::jsonb;
begin
 perform rc_private.require_tab('keyMaster.'||p_jenis);
  if not rc_private.can_access(null,'manage_key_master') then
    raise exception 'Tidak punya hak mengubah Key Master' using errcode='42501'; end if;
  if p_jenis not in ('customer','campaign','depot') then
    raise exception 'Jenis master tidak dikenali: %', coalesce(p_jenis,'(kosong)'); end if;
  if jsonb_typeof(p_kunci) <> 'array' or jsonb_array_length(p_kunci) = 0 then
    raise exception 'Tidak ada baris yang dipilih'; end if;
  if jsonb_array_length(p_kunci) > 200 then
    raise exception 'Maksimal 200 baris sekali arsip'; end if;

  for kunci in select upper(btrim(value)) from jsonb_array_elements_text(p_kunci) loop
    if kunci = '' then continue; end if;

    -- select ... into TIDAK mengosongkan peubah ketika tidak ada baris; dikosongkan sendiri
    -- supaya baris sebelumnya tidak terbawa dan salah diarsipkan.
    v_id := null; v_nama := null;
    if p_jenis = 'customer' then
      select id, customer_name into v_id, v_nama from public.customers
       where upper(customer_code) = kunci and archived_at is null for update;
    elsif p_jenis = 'campaign' then
      select id, campaign_name into v_id, v_nama from public.campaigns
       where upper(campaign_code) = kunci and archived_at is null for update;
    else
      select id, depot_name into v_id, v_nama from public.depots
       where upper(depot_code) = kunci and archived_at is null for update;
    end if;

    if v_id is null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('kode',kunci,
        'sebab','Tidak ditemukan, atau sudah diarsipkan'));
      continue;
    end if;

    select count(*) into n_terbuka from public.claims c
     where c.archived_at is null
       and c.status in ('not_yet','submitted','approved','released','claimed','on_hold')
       and ((p_jenis = 'customer' and c.customer_id = v_id)
         or (p_jenis = 'campaign' and c.campaign_id = v_id)
         or (p_jenis = 'depot'    and c.depot_id    = v_id));
    if n_terbuka > 0 then
      gagal := gagal || jsonb_build_array(jsonb_build_object('kode',kunci,
        'sebab','Masih memegang '||n_terbuka||' dokumen yang belum selesai. '
                ||'Selesaikan atau hanguskan lebih dulu, baru diarsipkan.'));
      continue;
    end if;

    if p_jenis = 'customer' then
      update public.customers set archived_at = now(), archived_by = aku,
        archive_reason = nullif(left(btrim(coalesce(p_alasan,'')),300),'') where id = v_id;
    elsif p_jenis = 'campaign' then
      update public.campaigns set archived_at = now(), archived_by = aku,
        archive_reason = nullif(left(btrim(coalesce(p_alasan,'')),300),'') where id = v_id;
    else
      update public.depots set archived_at = now(), archived_by = aku,
        archive_reason = nullif(left(btrim(coalesce(p_alasan,'')),300),'') where id = v_id;
    end if;

    insert into public.activity_logs(actor_id,event_type,entity_id,details)
    values(aku,'master_archive',v_id,jsonb_build_object(
      'jenis',p_jenis,'kode',kunci,'nama',coalesce(v_nama,''),'alasan',coalesce(p_alasan,'')));
    n_ok := n_ok + 1;
  end loop;

  return jsonb_build_object('status','success','berhasil',n_ok,
    'gagal',gagal,'jumlahGagal',jsonb_array_length(gagal),
    'message',n_ok||' baris diarsipkan'
      ||case when jsonb_array_length(gagal) > 0
             then ', '||jsonb_array_length(gagal)||' ditolak' else '' end);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_master_unarchive(p_jenis text, p_kunci jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  aku uuid := (select auth.uid());
  kunci text; v_id uuid; v_nama text;
  n_ok integer := 0; gagal jsonb := '[]'::jsonb;
begin
 perform rc_private.require_tab('keyMaster.'||p_jenis);
  if not rc_private.can_access(null,'manage_key_master') then
    raise exception 'Tidak punya hak mengubah Key Master' using errcode='42501'; end if;
  if p_jenis not in ('customer','campaign','depot') then
    raise exception 'Jenis master tidak dikenali: %', coalesce(p_jenis,'(kosong)'); end if;
  if jsonb_typeof(p_kunci) <> 'array' or jsonb_array_length(p_kunci) = 0 then
    raise exception 'Tidak ada baris yang dipilih'; end if;
  if jsonb_array_length(p_kunci) > 200 then
    raise exception 'Maksimal 200 baris sekali pulihkan'; end if;

  for kunci in select upper(btrim(value)) from jsonb_array_elements_text(p_kunci) loop
    if kunci = '' then continue; end if;
    v_id := null; v_nama := null;

    if p_jenis = 'customer' then
      select id, customer_name into v_id, v_nama from public.customers
       where upper(customer_code) = kunci and archived_at is not null for update;
      if v_id is not null then
        update public.customers set archived_at = null, archived_by = null,
          archive_reason = null where id = v_id; end if;
    elsif p_jenis = 'campaign' then
      select id, campaign_name into v_id, v_nama from public.campaigns
       where upper(campaign_code) = kunci and archived_at is not null for update;
      if v_id is not null then
        update public.campaigns set archived_at = null, archived_by = null,
          archive_reason = null where id = v_id; end if;
    else
      select id, depot_name into v_id, v_nama from public.depots
       where upper(depot_code) = kunci and archived_at is not null for update;
      if v_id is not null then
        update public.depots set archived_at = null, archived_by = null,
          archive_reason = null where id = v_id; end if;
    end if;

    if v_id is null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('kode',kunci,
        'sebab','Tidak ada di arsip'));
      continue;
    end if;

    insert into public.activity_logs(actor_id,event_type,entity_id,details)
    values(aku,'master_unarchive',v_id,jsonb_build_object(
      'jenis',p_jenis,'kode',kunci,'nama',coalesce(v_nama,'')));
    n_ok := n_ok + 1;
  end loop;

  return jsonb_build_object('status','success','berhasil',n_ok,
    'gagal',gagal,'jumlahGagal',jsonb_array_length(gagal),
    'message',n_ok||' baris dikembalikan dari arsip'
      ||case when jsonb_array_length(gagal) > 0
             then ', '||jsonb_array_length(gagal)||' ditolak' else '' end);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_master_archived(p_jenis text, p_search text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; nama jsonb; cari text;
begin
 perform rc_private.require_tab('keyMaster.'||p_jenis);
  if not rc_private.can_access(null,'manage_key_master') then
    raise exception 'Tidak punya hak membuka Key Master' using errcode='42501'; end if;
  if p_jenis not in ('customer','campaign','depot') then
    raise exception 'Jenis master tidak dikenali: %', coalesce(p_jenis,'(kosong)'); end if;

  cari := nullif(btrim(coalesce(p_search,'')),'');
  nama := rc_private.peta_nama_pelaku();

  if p_jenis = 'customer' then
    select coalesce(jsonb_agg(x order by x->>'diarsipkanPada' desc),'[]'::jsonb) into v from (
      select jsonb_build_object('kode',cu.customer_code,'nama',cu.customer_name,
        'diarsipkanPada',to_char(cu.archived_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
        'diarsipkanOleh',coalesce(nama->>(cu.archived_by::text),''),
        'alasan',coalesce(cu.archive_reason,''),
        'dokumen',(select count(*) from public.claims c where c.customer_id = cu.id)) as x
        from public.customers cu where cu.archived_at is not null
         and (cari is null or cu.customer_code ilike '%'||cari||'%'
                           or cu.customer_name ilike '%'||cari||'%')) t;
  elsif p_jenis = 'campaign' then
    select coalesce(jsonb_agg(x order by x->>'diarsipkanPada' desc),'[]'::jsonb) into v from (
      select jsonb_build_object('kode',ca.campaign_code,'nama',ca.campaign_name,
        'diarsipkanPada',to_char(ca.archived_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
        'diarsipkanOleh',coalesce(nama->>(ca.archived_by::text),''),
        'alasan',coalesce(ca.archive_reason,''),
        'dokumen',(select count(*) from public.claims c where c.campaign_id = ca.id)) as x
        from public.campaigns ca where ca.archived_at is not null
         and (cari is null or ca.campaign_code ilike '%'||cari||'%'
                           or ca.campaign_name ilike '%'||cari||'%')) t;
  else
    select coalesce(jsonb_agg(x order by x->>'diarsipkanPada' desc),'[]'::jsonb) into v from (
      select jsonb_build_object('kode',d.depot_code,'nama',d.depot_name,
        'diarsipkanPada',to_char(d.archived_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
        'diarsipkanOleh',coalesce(nama->>(d.archived_by::text),''),
        'alasan',coalesce(d.archive_reason,''),
        'dokumen',(select count(*) from public.claims c where c.depot_id = d.id)) as x
        from public.depots d where d.archived_at is not null
         and (cari is null or d.depot_code ilike '%'||cari||'%'
                           or d.depot_name ilike '%'||cari||'%')) t;
  end if;

  return jsonb_build_object('status','success','jenis',p_jenis,'rows',v);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_unarchive_compilation(p_ids uuid[])
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$select rc_private.unarchive_claims(p_ids);$function$
;
CREATE OR REPLACE FUNCTION public.rc_depot_upsert(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb; v_kode text; n_baru integer := 0; n_ubah integer := 0; salah text[] := '{}';
  v_to text; v_cc text;
begin
 perform rc_private.require_tab('keyMaster.depot');
  if not rc_private.can_access(null,'manage_key_master') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak mengubah Key Master' using errcode='42501'; end if;
  if jsonb_typeof(p_rows)<>'array' then raise exception 'Data harus berupa daftar baris'; end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'Maksimal 500 baris sekali unggah'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_kode := upper(btrim(coalesce(r->>'kode','')));
    if v_kode = '' then salah := salah || 'baris tanpa kode depot'; continue; end if;

    -- Alamat diperiksa di sini supaya kesalahan ketik tertangkap saat unggah, bukan saat
    -- email pertama gagal terkirim berhari-hari kemudian.
    v_to := btrim(coalesce(r->>'emailTo',''));
    v_cc := btrim(coalesce(r->>'emailCc',''));
    if v_to <> '' and coalesce(array_length(rc_private.pecah_email(v_to),1),0) = 0 then
      salah := salah || (v_kode||': alamat TO tidak sah'); continue; end if;
    if v_cc <> '' and coalesce(array_length(rc_private.pecah_email(v_cc),1),0) = 0 then
      salah := salah || (v_kode||': alamat CC tidak sah'); continue; end if;

    if exists(select 1 from public.depots where depot_code=v_kode) then
      update public.depots set
        depot_name   = coalesce(nullif(btrim(coalesce(r->>'nama','')),''), depot_name),
        abbr         = case when r ? 'abbr'   then nullif(upper(btrim(coalesce(r->>'abbr',''))),'') else abbr end,
        region       = case when r ? 'region' then nullif(btrim(coalesce(r->>'region','')),'') else region end,
        address      = case when r ? 'alamat' then nullif(btrim(coalesce(r->>'alamat','')),'') else address end,
        head_depot   = case when r ? 'headDepot'   then nullif(btrim(coalesce(r->>'headDepot','')),'') else head_depot end,
        kepala_admin = case when r ? 'kepalaAdmin' then nullif(btrim(coalesce(r->>'kepalaAdmin','')),'') else kepala_admin end,
        email_to     = case when r ? 'emailTo' then nullif(v_to,'') else email_to end,
        email_cc     = case when r ? 'emailCc' then nullif(v_cc,'') else email_cc end,
        updated_at   = now(), updated_by = (select auth.uid())
      where depot_code = v_kode;
      n_ubah := n_ubah + 1;
    else
      if coalesce(btrim(r->>'nama'),'') = '' then
        salah := salah || (v_kode||': depot baru wajib punya nama'); continue; end if;
      insert into public.depots(depot_code,depot_name,abbr,region,address,head_depot,
        kepala_admin,email_to,email_cc,updated_at,updated_by)
      values(v_kode, btrim(r->>'nama'), nullif(upper(btrim(coalesce(r->>'abbr',''))),''),
        nullif(btrim(coalesce(r->>'region','')),''), nullif(btrim(coalesce(r->>'alamat','')),''),
        nullif(btrim(coalesce(r->>'headDepot','')),''), nullif(btrim(coalesce(r->>'kepalaAdmin','')),''),
        nullif(v_to,''), nullif(v_cc,''), now(), (select auth.uid()));
      n_baru := n_baru + 1;
    end if;
  end loop;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'depot_master_updated',null,
    jsonb_build_object('baru',n_baru,'ubah',n_ubah,'ditolak',coalesce(array_length(salah,1),0)));

  return jsonb_build_object('status','success','baru',n_baru,'diperbarui',n_ubah,
    'ditolak',coalesce(array_length(salah,1),0),
    'pesanDitolak',to_jsonb(salah),
    'message',n_baru||' depot baru, '||n_ubah||' diperbarui'
      ||case when coalesce(array_length(salah,1),0)>0
             then ', '||array_length(salah,1)||' ditolak' else '' end);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_campaign_delete(p_codes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare kode text; ca public.campaigns%rowtype; jml bigint; nilai numeric;
 n_ok integer:=0; gagal jsonb:='[]'::jsonb; aku uuid:=(select auth.uid());
begin
 perform rc_private.require_tab('keyMaster.campaign');
 if not rc_private.can_access(null,'manage_key_master') then
  raise exception 'Tidak punya hak mengubah Key Master' using errcode='42501'; end if;
 if jsonb_typeof(p_codes) <> 'array' or jsonb_array_length(p_codes) = 0 then
  raise exception 'Tidak ada campaign yang dipilih'; end if;
 if jsonb_array_length(p_codes) > 200 then
  raise exception 'Maksimal 200 campaign sekali hapus'; end if;

 for kode in select upper(btrim(value)) from jsonb_array_elements_text(p_codes) loop
  if kode = '' then continue; end if;
  select * into ca from public.campaigns where upper(campaign_code) = kode for update;
  if not found then
   gagal := gagal || jsonb_build_array(jsonb_build_object('kode',kode,'sebab','Campaign tidak ditemukan'));
   continue;
  end if;

  select count(*), coalesce(sum(cb_net),0) into jml, nilai
    from public.claims where campaign_id = ca.id;
  if jml > 0 then
   -- Termasuk klaim yang sudah diarsipkan: mengarsipkan bukan menghapus, dan campaign-nya
   -- masih menjadi rujukan riwayat dokumen itu.
   gagal := gagal || jsonb_build_array(jsonb_build_object('kode',kode,
     -- Pemisah ribuan dijadikan titik: to_char memakai pemisah menurut lokal server, yang di
     -- sini koma, dan angka rupiah bergaya Inggris di layar berbahasa Indonesia mudah salah baca.
     'sebab','Masih memiliki '||jml||' dokumen (nilai klaim Rp '||
             replace(to_char(nilai,'FM999G999G999G999'),',','.')||
             '). Hanya campaign tanpa dokumen yang dapat dihapus.'));
   continue;
  end if;

  insert into public.activity_logs(actor_id,event_type,details)
  values(aku,'campaign_delete',jsonb_build_object(
    'kode',ca.campaign_code,'nama',ca.campaign_name,'status',ca.status));

  delete from public.campaigns where id = ca.id;
  n_ok := n_ok + 1;
 end loop;

 return jsonb_build_object('status','success','berhasil',n_ok,
   'gagal',gagal,'jumlahGagal',jsonb_array_length(gagal),
   'message',n_ok||' campaign dihapus'
     ||case when jsonb_array_length(gagal) > 0
            then ', '||jsonb_array_length(gagal)||' ditolak' else '' end);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_update_access(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_target uuid; v_kode text; v_role text; v_role_lama text; v_status text;
  v_perms text[]; v_depot uuid; c text; n_rp int:=0; n_as int:=0; n_osc int:=0;
  v_tersisip int;
  v_diri boolean;
begin
 perform rc_private.require_tab('access.list');
  if not rc_private.is_manager() then
    raise exception 'Hanya System Manager atau Supervisor yang dapat mengubah akses'
      using errcode='42501'; end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then
    raise exception 'Payload tidak sah'; end if;

  v_kode:=upper(btrim(coalesce(p_payload->>'userId','')));
  if v_kode='' then raise exception 'User ID wajib diisi'; end if;
  select id, role into v_target, v_role_lama from public.profiles where user_code=v_kode for update;
  if v_target is null then
    raise exception 'Pengguna "%" tidak ada di daftar akun',v_kode; end if;

  v_diri := (v_target = (select auth.uid()));

  -- Menyunting diri sendiri kini diizinkan, tetapi HANYA untuk System Manager dan HANYA pada
  -- bagian identitas. Seorang supervisor tetap tidak dapat menyunting dirinya sendiri.
  if v_diri and not rc_private.is_system_manager() then
    raise exception 'Tidak dapat mengubah akses sendiri'; end if;
  if not v_diri and not rc_private.can_manage_user(v_target) then
    raise exception 'Pengguna "%" berada di luar wilayah Anda',v_kode using errcode='42501'; end if;
  if (select status from public.profiles where id=v_target)='pending' then
    raise exception 'Setujui pendaftaran ini lebih dahulu di kotak masuk approval'; end if;

  -- Validate every proposed scope before any write, including direct RPC callers.
  if not v_diri then
   for c in select value from jsonb_array_elements_text(coalesce(p_payload->'rpDepots','[]')||coalesce(p_payload->'assignedDepots','[]')) loop
    v_depot:=public.rc_legacy_depot_id(btrim(c));
    if v_depot is null or not rc_private.can_access(v_depot) then raise exception 'Depot di luar yurisdiksi Anda' using errcode='42501'; end if;
   end loop;
   for c in select jsonb_array_elements_text(coalesce(p_payload->'assignedOsc','[]')) loop
    if not exists(select 1 from public.profiles p where p.user_code=upper(btrim(c)) and p.role='osc' and p.status='active' and rc_private.can_manage_user(p.id)) then
     raise exception 'OSC tidak valid atau di luar yurisdiksi Anda' using errcode='42501'; end if;
   end loop;
  end if;
  -- ---- Identitas, satu-satunya bagian yang boleh disunting atas diri sendiri --------------
  if coalesce(btrim(p_payload->>'fullName'),'')<>'' then
    update public.profiles set full_name=btrim(p_payload->>'fullName') where id=v_target;
  end if;
  if coalesce(btrim(p_payload->>'email'),'')<>'' then
    update public.profiles set business_email=lower(btrim(p_payload->>'email')) where id=v_target;
  end if;
  if coalesce(btrim(p_payload->>'suffix'),'')<>'' then
    perform rc_private.set_suffix(v_kode,btrim(p_payload->>'suffix'));
  end if;

  if v_diri then
    -- Berhenti di sini. Peran, status, hak modul dan yurisdiksi sendiri tidak disentuh sama
    -- sekali, sehingga tidak ada jalan untuk mengunci diri keluar lewat layar ini.
    insert into public.activity_logs(actor_id,event_type,entity_id,details)
    values((select auth.uid()),'identity_self_updated',v_target,
           jsonb_build_object('user',v_kode));
    return jsonb_build_object('status','success','role',v_role_lama,
      'jumlahPermission',(select count(*) from public.user_permissions where user_id=v_target),
      'jumlahDepot',(select count(*) from public.user_depot_access where user_id=v_target),
      'pesan','Identitas Anda diperbarui. Peran, hak modul dan yurisdiksi sendiri sengaja tidak dapat diubah dari sini.');
  end if;

  -- ---- Selebihnya hanya berlaku untuk pengguna lain ----------------------------------------
  v_role:=lower(btrim(coalesce(p_payload->>'role','')));
  if v_role<>'' and v_role<>v_role_lama then
    perform rc_private.set_role(v_target,v_role);
  else
    v_role:=v_role_lama;
  end if;

  v_status:=case when not coalesce(p_payload->'auth','{}') ? 'i' then (select status from public.profiles where id=v_target)
    when lower(coalesce(p_payload->'auth'->>'i','')) in('active','approved','ok') then 'active' else 'inactive' end;
  if v_role<>'admin' and jsonb_array_length(coalesce(p_payload->'rpDepots','[]'))>0 then raise exception 'RP hanya untuk Admin'; end if;
  if v_role not in('osc','others','finance','depot head') and jsonb_array_length(coalesce(p_payload->'assignedDepots','[]'))>0 then raise exception 'Mapping depot tidak sesuai role'; end if;
  if v_role<>'supervisor' and jsonb_array_length(coalesce(p_payload->'assignedOsc','[]'))>0 then raise exception 'Mapping OSC hanya untuk Supervisor'; end if;
  if v_role<>'management' and jsonb_array_length(coalesce(p_payload->'regions','[]'))>0 then raise exception 'Region hanya untuk Management'; end if;
  if v_role<>'management' then delete from public.user_region_access where user_id=v_target; end if;

  -- Yurisdiksi milik peran LAIN selalu dilepas, pada setiap penyimpanan. Inilah yang
  -- memastikan sebuah akun tidak pernah memegang dua yurisdiksi sekaligus, termasuk
  -- ketika perannya baru saja berubah dan layar hanya mengirim yurisdiksi yang baru.
  if v_role <> 'supervisor' then
    delete from public.user_supervision where supervisor_id=v_target;
  end if;
  if v_role <> 'admin' then
    delete from public.user_depot_grants where user_id=v_target and kind='rp';
  end if;
  if v_role not in ('osc','others','finance','depot head') then
    delete from public.user_depot_grants where user_id=v_target and kind='assigned';
  end if;
  -- System Manager dan Supervisor memperoleh depot lewat perannya, jadi grant apa pun
  -- pada keduanya hanya menjadi sumber kebenaran kedua yang akan menyimpang.
  if v_role in ('system manager','supervisor') then
    delete from public.user_depot_grants where user_id=v_target;
  end if;

  begin
    if p_payload ? 'homeDepot' then
      -- Depot rumah adalah keterangan identitas, bukan pemberian wewenang, sehingga ia
      -- tidak lagi menjadi baris grant dan tidak ikut menentukan yurisdiksi.
      if coalesce(btrim(p_payload->>'homeDepot'),'')='' then
        update public.profiles set home_depot_id=null where id=v_target;
      else
        update public.profiles
           set home_depot_id=public.rc_legacy_depot_id(btrim(p_payload->>'homeDepot'))
         where id=v_target;
      end if;
    end if;

    if p_payload ? 'rpDepots' then
      delete from public.user_depot_grants where user_id=v_target and kind='rp';
      for c in select jsonb_array_elements_text(p_payload->'rpDepots') loop
        if btrim(c)<>'' then
          v_depot:=public.rc_legacy_depot_id(btrim(c));
          insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
          values(v_target,v_depot,'rp',(select auth.uid()))
          on conflict(user_id,depot_id) do nothing;
          n_rp:=n_rp+1;
        end if;
      end loop;
    end if;

    if p_payload ? 'assignedDepots' then
      delete from public.user_depot_grants where user_id=v_target and kind='assigned';
      for c in select jsonb_array_elements_text(p_payload->'assignedDepots') loop
        if btrim(c)<>'' then
          v_depot:=public.rc_legacy_depot_id(btrim(c));
          insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
          values(v_target,v_depot,'assigned',(select auth.uid()))
          on conflict(user_id,depot_id) do nothing;
          n_as:=n_as+1;
        end if;
      end loop;
    end if;

    if p_payload ? 'assignedOsc' then
      delete from public.user_supervision where supervisor_id=v_target;
      for c in select jsonb_array_elements_text(p_payload->'assignedOsc') loop
        if btrim(c)<>'' then
          insert into public.user_supervision(supervisor_id,osc_id)
          select v_target,p2.id from public.profiles p2
           where p2.user_code=upper(btrim(c)) and p2.id<>v_target and p2.role = 'osc'
          on conflict do nothing;
          -- "insert ... select" TIDAK gagal ketika select-nya kosong; ia hanya menyisipkan
          -- nol baris. Tanpa pemeriksaan ini, kode yang tidak dikenal dilaporkan sebagai
          -- keberhasilan dan tidak ada yang tersimpan.
          get diagnostics v_tersisip = row_count;
          if v_tersisip = 0 then
            if upper(btrim(c)) = v_kode then
              raise exception 'Akun % tidak dapat membina dirinya sendiri sebagai OSC.', btrim(c);
            else
              raise exception 'Akun % tidak dapat dibina: ia harus ada dan berperan OSC. Supervisor hanya membina OSC di bawahnya.', btrim(c);
            end if;
          end if;
          n_osc:=n_osc+v_tersisip;
        end if;
      end loop;
    end if;
  end;

  if v_role='system manager' then
    v_perms:=array(select code from public.permissions);
  else
    v_perms:=array(select code from (values
      ('j','upload_claim'),('k','release_claim'),('l','process_claim'),('m','view_analytics'),
      ('n','manage_access'),('p','view_master_depot'),('s','bulk_process'),('logs','view_logs'),
      ('keyMaster','manage_key_master'),('compilation','view_compilation'),
      ('archiveCompilation','archive_compilation'),
      ('report','view_report'),('timetable','manage_timetable'),('approval','approve_claim'),('people','view_people')
    ) as m(letter,code)
    where lower(coalesce(p_payload->'auth'->>m.letter,'no')) in('yes','true','approved','visible')
      or (not coalesce(p_payload->'auth','{}') ? m.letter and exists(select 1 from public.user_permissions up where up.user_id=v_target and up.permission_code=m.code)));
  end if;

  delete from public.user_permissions where user_id=v_target;
  insert into public.user_permissions select v_target,x from unnest(v_perms) x group by x;
  update public.profiles set status=v_status where id=v_target;

  if p_payload ? 'regions' then
   perform rc_private.tetapkan_region(v_target, p_payload->'regions');
 end if;
 perform rc_private.rebuild_with_supervisors(v_target);

  if coalesce((p_payload->>'approvePin')::boolean,false) then
    update public.profiles set must_change_password=true where id=v_target;
  end if;

  if p_payload ? 'tabs' then perform rc_private.save_tab_access(v_target,p_payload->'tabs');end if;
  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'access_changed',v_target,jsonb_build_object(
    'status',v_status,'role',v_role,'permissions',coalesce(array_length(v_perms,1),0),
    'rp',n_rp,'assigned',n_as,'osc',n_osc));

  return jsonb_build_object('status','success','role',v_role,
    'jumlahPermission',coalesce(array_length(v_perms,1),0),
    'jumlahDepot',(select count(*) from public.user_depot_access where user_id=v_target),
    'pesan','Akses '||v_kode||' berhasil diperbarui');
end $function$;
CREATE OR REPLACE FUNCTION public.rc_legacy_manageable()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
 if not rc_private.is_manager() and not rc_private.can_access(null,'manage_access') then
   raise exception 'Manager required' using errcode='42501'; end if;
 return jsonb_build_object('status','success',
  'users',case when rc_private.can_tab('access.list') or rc_private.can_tab('access.add') or rc_private.can_tab('access.req') then rc_private.legacy_users() else '[]'::jsonb end,
  'allDepots',coalesce((select jsonb_agg(jsonb_build_object('kode',depot_code,'nama',depot_name,'link',coalesce(master_link,'')) order by depot_code) from public.depots where archived_at is null and rc_private.can_access(id)),'[]'::jsonb),
  'managedDepots',coalesce((select jsonb_agg(jsonb_build_object('kode',depot_code,'nama',depot_name,'link',coalesce(master_link,'')) order by depot_code) from public.depots where archived_at is null and rc_private.can_access(id)),'[]'::jsonb),
  'isSystemManager',rc_private.is_system_manager(),'canEdit',rc_private.is_manager(),
  'registrationOptions',rc_private.registration_options(),
  'profileRequests',case when rc_private.can_tab('access.req') then rc_private.legacy_profile_requests() else '[]'::jsonb end);
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
 if not (rc_private.can_tab('timetable.matrix') or rc_private.can_tab('access.exclude') or rc_private.can_tab('report.dashboard')) then raise exception 'Timetable access denied' using errcode='42501';end if;
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
end $function$;
CREATE OR REPLACE FUNCTION public.rc_timetable_not_achieved()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; nama jsonb;
begin
 if not (rc_private.can_tab('timetable.matrix') or rc_private.can_tab('access.exclude') or rc_private.can_tab('report.dashboard')) then raise exception 'Timetable access denied' using errcode='42501';end if;
  if not rc_private.can_access(null,'manage_timetable')
     and not rc_private.can_access(null,'view_report')
     and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat Timetable' using errcode='42501'; end if;
  nama := rc_private.peta_nama_pelaku();
  select coalesce(jsonb_agg(x order by x->>'kodeDepot', x->>'kodeCampaign'),'[]'::jsonb) into v from (
    select jsonb_build_object(
      'kodeDepot',d.depot_code,'namaDepot',d.depot_name,'region',coalesce(d.region,''),
      'kodeCampaign',c.campaign_code,'namaCampaign',c.campaign_name,
      'ditandaiOleh',coalesce(nama->>(na.marked_by::text),''),
      'ditandaiPada',to_char(na.marked_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
      'catatan',coalesce(na.note,''),
      'adaKlaim',exists(select 1 from public.claims cl
                         where cl.depot_id=na.depot_id and cl.campaign_id=na.campaign_id
                           and cl.archived_at is null)) as x
      from public.timetable_not_achieved na
      join public.depots d on d.id=na.depot_id
      join public.campaigns c on c.id=na.campaign_id
     where rc_private.is_manager() or rc_private.can_access(na.depot_id)) t;
  return jsonb_build_object('status','success','rows',v,
    'bolehBatalkan',rc_private.is_osc_ke_atas());
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_email_periksa()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record; n_ok integer := 0; n_gagal integer := 0;
begin
 if auth.uid() is not null then perform rc_private.require_tab('access.email');end if;
  for r in
    select o.id, (o.konteks->>'net_request_id')::bigint as req
      from public.email_outbox o
     where o.status='sent' and o.konteks ? 'net_request_id'
       and o.dikirim_pada > now() - interval '2 days'
  loop
    begin
      perform 1 from net._http_response where id = r.req and status_code between 200 and 299;
      if found then n_ok := n_ok + 1; continue; end if;
      update public.email_outbox
         set status='failed',
             galat = coalesce((select left(coalesce(error_msg, 'HTTP '||status_code::text||': '||coalesce(content,'')),300)
                                 from net._http_response where id=r.req),'Tidak ada jawaban dari penyedia')
       where id = r.id and exists(select 1 from net._http_response where id=r.req);
      if found then n_gagal := n_gagal + 1; end if;
    exception when others then
      -- Tabel jawaban pg_net dibersihkan berkala; ketiadaan baris bukan bukti kegagalan.
      continue;
    end;
  end loop;
  return jsonb_build_object('status','success','berhasil',n_ok,'gagal',n_gagal);
end $function$;
CREATE OR REPLACE FUNCTION public.rc_posting_exception(p_action text, p_rows jsonb, p_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_action text; r jsonb; v_doc text; c public.claims%rowtype; camp public.campaigns%rowtype;
  n_ok integer := 0; processed jsonb := '[]'::jsonb; gagal jsonb := '[]'::jsonb; v_target text; batch text;
  so_a date; so_b date; bi_a date; bi_b date; berbeda boolean;
  actor uuid := (select auth.uid());
begin
  v_action := lower(btrim(coalesce(p_action,'')));
  if v_action not in('expired','hold') then
    raise exception 'Tindakan "%" tidak dikenali', p_action; end if;
  if not rc_private.can_access(null,'upload_claim') then
    raise exception 'Tidak punya hak melakukan Posting Exception' using errcode='42501'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Tidak ada baris yang dikirim'; end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'Maksimal 500 baris sekali proses'; end if;

  for r in select value from jsonb_array_elements(p_rows) order by upper(btrim(value->>'noDoc')) loop
    v_doc := upper(btrim(coalesce(r->>'noDoc','')));
    if v_doc = '' then continue; end if;

    select * into c from public.claims where upper(no_doc) = v_doc for update;
    if not found then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Dokumen tidak ditemukan'));
      continue;
    end if;
    if not rc_private.can_access(c.depot_id,'upload_claim') then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Depot di luar yurisdiksi Anda'));
      continue;
    end if;
    if c.archived_at is not null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Dokumen sudah diarsipkan'));
      continue;
    end if;

    if c.pending_approval is not null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Dokumen masih menunggu approval'));
      continue;
    end if;
    if r ? 'versionNo' and (r->>'versionNo')::bigint is distinct from c.version_no then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Dokumen berubah; muat ulang'));
      continue;
    end if;
    select * into camp from public.campaigns where id = c.campaign_id;

    if v_action = 'expired' then
      if c.status not in('not_yet','submitted','released','claimed','on_hold') then
        gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
          'sebab','Status '||rc_private.legacy_status(c.status)||' tidak dapat di-Expired'));
        continue;
      end if;
      v_target := 'expired';
      batch := null; -- batch Clearing hanya diterbitkan saat approval
      so_a := null; so_b := null; bi_a := null; bi_b := null;
    else
      if c.status not in('not_yet','submitted','released','claimed') then
        gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
          'sebab','Status '||rc_private.legacy_status(c.status)||' tidak dapat di-On Hold'));
        continue;
      end if;

      so_a := nullif(btrim(coalesce(r->>'soStart','')),'')::date;
      so_b := nullif(btrim(coalesce(r->>'soEnd','')),'')::date;
      bi_a := nullif(btrim(coalesce(r->>'billingStart','')),'')::date;
      bi_b := nullif(btrim(coalesce(r->>'billingEnd','')),'')::date;

      if so_a is null or so_b is null or bi_a is null or bi_b is null then
        gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
          'sebab','On Hold memerlukan SO Start, SO End, Billing Start dan Billing End'));
        continue;
      end if;
      if so_b < so_a then
        gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
          'sebab','SO End lebih awal daripada SO Start'));
        continue;
      end if;
      if bi_b < bi_a then
        gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
          'sebab','Billing End lebih awal daripada Billing Start'));
        continue;
      end if;

      -- Setidaknya satu tanggal harus berbeda dari periode campaign. Bila campaign itu sendiri
      -- tidak punya periode yang terurai, syarat ini dilewati - tidak ada acuan untuk
      -- membandingkan, dan menolaknya hanya akan memblokir dokumen yang sah.
      if camp.period_start is not null and camp.period_end is not null then
        berbeda := (so_a is distinct from camp.period_start)
                or (so_b is distinct from camp.period_end)
                or (bi_a is distinct from camp.period_start)
                or (bi_b is distinct from camp.period_end);
        if not berbeda then
          gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
            'sebab','Keempat tanggal sama persis dengan periode campaign '
              ||to_char(camp.period_start,'DD.MM.YYYY')||' - '||to_char(camp.period_end,'DD.MM.YYYY')
              ||'; setidaknya satu harus diperpanjang'));
          continue;
        end if;
      end if;

      v_target := 'on_hold';
      batch := null;
    end if;

    update public.claims set
      pending_approval = jsonb_build_object('kind',case when v_action='hold' then 'hold' else 'expire' end,
        'target_status',v_target,'requested_by',actor,'requested_at',now(),
        'reason',left(btrim(coalesce(p_reason,'')),300),
        'so_start',so_a,'so_end',so_b,'billing_start',bi_a,'billing_end',bi_b),
      version_no = version_no + 1,
      updated_at = now()
    where id = c.id;

    insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
    values(c.id,actor,c.status,c.status,'request_'||v_action,batch,left(btrim(coalesce(p_reason,'')),300));

    insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
    values(actor,c.depot_id,'posting_exception',c.id,jsonb_build_object(
      'noDoc',c.no_doc,'tindakan',v_action,'dari',c.status,'menjadi',c.status,'requestedStatus',v_target,
      'soStart',so_a,'soEnd',so_b,'billingStart',bi_a,'billingEnd',bi_b));

    processed := processed || jsonb_build_array(jsonb_build_object('noDoc',c.no_doc,
      'status',rc_private.legacy_status(c.status),'versionNo',c.version_no+1,'pendingApproval',true));
    n_ok := n_ok + 1;
  end loop;

  return jsonb_build_object('status','success','berhasil',n_ok,
    'processed',processed,'gagal',gagal,'jumlahGagal',jsonb_array_length(gagal),
    'message',n_ok||' dokumen '||case when v_action='expired' then 'diajukan untuk Expired; menunggu approval' else 'diajukan untuk On Hold; menunggu approval' end
      ||case when jsonb_array_length(gagal) > 0
             then ', '||jsonb_array_length(gagal)||' ditolak' else '' end);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_dashboard_publik(p_filter jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'status','success',
    'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'),
    'dashboard', rc_private.report_dashboard(coalesce(p_filter,'{}'::jsonb)),
    'cc1',       rc_private.cost_center(coalesce(p_filter,'{}'::jsonb)),
    'cc2',       rc_private.cost_center_2(coalesce(p_filter,'{}'::jsonb))
  );
$function$
;
CREATE OR REPLACE FUNCTION public.rc_campaign_list(p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb; nama jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 -- Nama pembuat lewat peta SECURITY DEFINER: profiles hanya membuka baris diri sendiri, jadi
 -- join langsung akan membuat kolom Created by kosong bagi hampir semua orang.
 nama := rc_private.peta_nama_pelaku();
 select coalesce(jsonb_agg(x order by x->>'codeCampaign'),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'id',ca.id,'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'periodStart',coalesce(ca.period_start_text,''),'periodEnd',coalesce(ca.period_end_text,''),
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'statusPajak',coalesce(ca.tax_status,''),
   'status',ca.status,
   'createdOn',to_char(ca.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY'),
   'createdBy',coalesce(nama->>(ca.created_by::text),''),
   'memoPath',coalesce(ca.memo_path,''),'memoName',coalesce(ca.memo_name,''),
   'memoSize',coalesce(ca.memo_size,0),
   'memoUploadedOn',case when ca.memo_uploaded_at is null then ''
     else to_char(ca.memo_uploaded_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS') end,
   'jumlahClaim',(select count(*) from public.claims c where c.campaign_id=ca.id and c.archived_at is null),
   'nilaiClaim',(select coalesce(sum(c.cb_net),0) from public.claims c
                  where c.campaign_id=ca.id and c.archived_at is null)) as x
  from public.campaigns ca
  where ca.archived_at is null and (coalesce(btrim(p_search),'')=''
     or ca.campaign_code ilike '%'||btrim(p_search)||'%'
     or ca.campaign_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code
  limit least(greatest(coalesce(p_limit,50),1),200) offset greatest(coalesce(p_offset,0),0)) t;
 return jsonb_build_object('status','success','rows',v,
  'total',(select count(*) from public.campaigns where archived_at is null));
end $function$;
CREATE OR REPLACE FUNCTION public.rc_pin_requests()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'userId',p.user_code,'namaLengkap',p.full_name,'peran',p.role,
    'jenis',r.kind,'alasan',r.reason,'status',r.status,
    'adaPinDiajukan',(r.requested_secret is not null),
    'diajukan',to_char(r.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'),
    'kodeDepot',coalesce((select d.depot_code from public.depots d where d.id=p.home_depot_id),''))
    order by r.created_at),'[]'::jsonb)
  from public.pin_requests r
  join public.profiles p on p.id=r.requester_id
  where r.status='pending' and rc_private.can_manage_user(p.id);
$function$
;
CREATE OR REPLACE FUNCTION public.rc_timetable_matrix(p_filter jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_region text; v_depot text; v_campaign text; v_tanggal date;
begin
 if not (rc_private.can_tab('timetable.matrix') or rc_private.can_tab('access.exclude') or rc_private.can_tab('report.dashboard')) then raise exception 'Timetable access denied' using errcode='42501';end if;
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

      'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS')
    )
  );
end $function$;
CREATE OR REPLACE FUNCTION public.rc_depot_profile_requests()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$select rc_private.require_tab('access.req');
  select jsonb_build_object('status','success','rows', coalesce(jsonb_agg(jsonb_build_object(
      'id',r.id,'kodeDepot',d.depot_code,'namaDepot',d.depot_name,
      'pengaju',p.user_code,'namaPengaju',p.full_name,
      'perubahan',r.perubahan,
      'diajukan',to_char(r.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'))
      order by r.created_at),'[]'::jsonb))
    from public.depot_profile_requests r
    join public.depots d on d.id = r.depot_id
    join public.profiles p on p.id = r.requester_id
   where r.status='pending' and rc_private.is_manager() and rc_private.can_access(r.depot_id);
$function$;
CREATE OR REPLACE FUNCTION public.rc_reprocessing_list(p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb; jml bigint; v_cari text;
begin
 perform rc_private.require_tab('compilation.reprocess');
  if not rc_private.can_access(null,'view_compilation') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak membuka Cashback Compilation' using errcode='42501'; end if;
  v_cari := nullif(btrim(coalesce(p_search,'')),'');

  select count(*) into jml
    from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
    join public.customers cu on cu.id = c.customer_id
   where c.status = 'on_hold' and c.archived_at is null and c.pending_approval is null
     and (v_cari is null or c.no_doc ilike '%'||v_cari||'%'
          or cu.customer_code ilike '%'||v_cari||'%' or cu.customer_name ilike '%'||v_cari||'%');

  select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
    select jsonb_build_object(
      'noDoc',c.no_doc,
      'kodeCampaign',ca.campaign_code,'namaCampaign',ca.campaign_name,
      'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
      'totalCashback',c.cb_net,
      'dcCode',d.depot_code,'depotName',d.depot_name,
      -- Tanggal yang ditetapkan saat On Hold. Ditampilkan supaya penyunting tahu batas baru
      -- dokumen ini, dan ikut terbawa ke berkas unduhan.
      'soStart',c.extend_so_start,'soEnd',c.extend_so_end,
      'billingStart',c.extend_billing_start,'billingEnd',c.extend_billing_end,
      'ditahanPada',to_char(c.updated_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'),
      'alasan',coalesce((select h.reason from public.claim_status_history h
                          where h.claim_id=c.id and h.action in('hold','request_hold')
                          order by h.id desc limit 1),''),
      'versionNo',c.version_no) as x
    from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
    join public.customers cu on cu.id = c.customer_id
    join public.depots d on d.id = c.depot_id
   where c.status = 'on_hold' and c.archived_at is null and c.pending_approval is null
     and (v_cari is null or c.no_doc ilike '%'||v_cari||'%'
          or cu.customer_code ilike '%'||v_cari||'%' or cu.customer_name ilike '%'||v_cari||'%')
   order by c.updated_at desc, c.no_doc
   limit least(greatest(coalesce(p_limit,200),1),2000)
  offset greatest(coalesce(p_offset,0),0)) t;

  return jsonb_build_object('status','success','rows',v,'total',jml);
end $function$;
CREATE OR REPLACE FUNCTION public.rc_account_archive()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; nama jsonb;
begin
 perform rc_private.require_tab('access.arsip');
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat membuka Arsip Hapus' using errcode='42501'; end if;
  nama := rc_private.peta_nama_pelaku();
  select coalesce(jsonb_agg(x order by x->>'diarsipkanPada' desc),'[]'::jsonb) into v from (
    select jsonb_build_object(
      'id',p.id,
      'userId',coalesce(p.archived_user_code, p.user_code),
      'namaLengkap',p.full_name,'peran',p.role,
      'email',coalesce(p.business_email,''),
      'diarsipkanPada',case when p.archived_at is null then ''
        else to_char(p.archived_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS') end,
      'diarsipkanOleh',coalesce(nama->>(p.archived_by::text),''),
      'catatan',coalesce(p.review_note,''),
      -- Benar bila User ID aslinya sementara dipakai akun lain; pemulihannya akan ditolak
      -- sampai bentrokan itu dibereskan, dan lebih baik terbaca sebelum tombolnya ditekan.
      'bentrok',exists(select 1 from public.profiles q
                        where q.id <> p.id and q.status <> 'deleted'
                          and upper(q.user_code) = upper(coalesce(p.archived_user_code, p.user_code)))
    ) as x
    from public.profiles p where p.status = 'deleted') t;
  return jsonb_build_object('status','success','rows',v);
end $function$;
CREATE OR REPLACE FUNCTION public.rc_timetable_not_achieved()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; nama jsonb;
begin
 if not (rc_private.can_tab('timetable.matrix') or rc_private.can_tab('access.exclude') or rc_private.can_tab('report.dashboard')) then raise exception 'Timetable access denied' using errcode='42501';end if;
  if not rc_private.can_access(null,'manage_timetable')
     and not rc_private.can_access(null,'view_report')
     and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat Timetable' using errcode='42501'; end if;
  nama := rc_private.peta_nama_pelaku();
  select coalesce(jsonb_agg(x order by x->>'kodeDepot', x->>'kodeCampaign'),'[]'::jsonb) into v from (
    select jsonb_build_object(
      'kodeDepot',d.depot_code,'namaDepot',d.depot_name,'region',coalesce(d.region,''),
      'kodeCampaign',c.campaign_code,'namaCampaign',c.campaign_name,
      'ditandaiOleh',coalesce(nama->>(na.marked_by::text),''),
      'ditandaiPada',to_char(na.marked_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'),
      'catatan',coalesce(na.note,''),
      'adaKlaim',exists(select 1 from public.claims cl
                         where cl.depot_id=na.depot_id and cl.campaign_id=na.campaign_id
                           and cl.archived_at is null)) as x
      from public.timetable_not_achieved na
      join public.depots d on d.id=na.depot_id
      join public.campaigns c on c.id=na.campaign_id
     where rc_private.is_manager() or rc_private.can_access(na.depot_id)) t;
  return jsonb_build_object('status','success','rows',v,
    'bolehBatalkan',rc_private.is_osc_ke_atas());
end $function$;
CREATE OR REPLACE FUNCTION public.rc_master_archived(p_jenis text, p_search text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; nama jsonb; cari text;
begin
 perform rc_private.require_tab('keyMaster.'||p_jenis);
  if not rc_private.can_access(null,'manage_key_master') then
    raise exception 'Tidak punya hak membuka Key Master' using errcode='42501'; end if;
  if p_jenis not in ('customer','campaign','depot') then
    raise exception 'Jenis master tidak dikenali: %', coalesce(p_jenis,'(kosong)'); end if;

  cari := nullif(btrim(coalesce(p_search,'')),'');
  nama := rc_private.peta_nama_pelaku();

  if p_jenis = 'customer' then
    select coalesce(jsonb_agg(x order by x->>'diarsipkanPada' desc),'[]'::jsonb) into v from (
      select jsonb_build_object('kode',cu.customer_code,'nama',cu.customer_name,
        'diarsipkanPada',to_char(cu.archived_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'),
        'diarsipkanOleh',coalesce(nama->>(cu.archived_by::text),''),
        'alasan',coalesce(cu.archive_reason,''),
        'dokumen',(select count(*) from public.claims c where c.customer_id = cu.id)) as x
        from public.customers cu where cu.archived_at is not null
         and (cari is null or cu.customer_code ilike '%'||cari||'%'
                           or cu.customer_name ilike '%'||cari||'%')) t;
  elsif p_jenis = 'campaign' then
    select coalesce(jsonb_agg(x order by x->>'diarsipkanPada' desc),'[]'::jsonb) into v from (
      select jsonb_build_object('kode',ca.campaign_code,'nama',ca.campaign_name,
        'diarsipkanPada',to_char(ca.archived_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'),
        'diarsipkanOleh',coalesce(nama->>(ca.archived_by::text),''),
        'alasan',coalesce(ca.archive_reason,''),
        'dokumen',(select count(*) from public.claims c where c.campaign_id = ca.id)) as x
        from public.campaigns ca where ca.archived_at is not null
         and (cari is null or ca.campaign_code ilike '%'||cari||'%'
                           or ca.campaign_name ilike '%'||cari||'%')) t;
  else
    select coalesce(jsonb_agg(x order by x->>'diarsipkanPada' desc),'[]'::jsonb) into v from (
      select jsonb_build_object('kode',d.depot_code,'nama',d.depot_name,
        'diarsipkanPada',to_char(d.archived_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'),
        'diarsipkanOleh',coalesce(nama->>(d.archived_by::text),''),
        'alasan',coalesce(d.archive_reason,''),
        'dokumen',(select count(*) from public.claims c where c.depot_id = d.id)) as x
        from public.depots d where d.archived_at is not null
         and (cari is null or d.depot_code ilike '%'||cari||'%'
                           or d.depot_name ilike '%'||cari||'%')) t;
  end if;

  return jsonb_build_object('status','success','jenis',p_jenis,'rows',v);
end $function$;
CREATE OR REPLACE FUNCTION public.rc_email_status()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$select rc_private.require_tab('access.email');
  select jsonb_build_object('status','success',
    'pengaturan',(select coalesce(jsonb_agg(jsonb_build_object(
        'jenis',jenis,'aktif',aktif,'jam',jam,
        -- NULL tetap dikirim sebagai null, yang di layar berarti "tiap hari".
        'hariList',to_jsonb(hari_list),
        'subjek',subjek) order by jenis),'[]'::jsonb)
      from public.email_settings),
    'antrean',(select coalesce(jsonb_agg(jsonb_build_object(
        'id',id,'jenis',jenis,'subjek',subjek,'status',status,
        'tujuan',array_length(tujuan,1),'cc',array_length(cc,1),'galat',galat,
        'dibuat',to_char(dibuat_pada at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'),
        'dikirim',to_char(dikirim_pada at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'))
        order by dibuat_pada desc),'[]'::jsonb)
      from (select * from public.email_outbox order by dibuat_pada desc limit 50) x),
    'ringkas',(select jsonb_object_agg(status,n) from
      (select status,count(*) n from public.email_outbox group by status) y),
    'depotBerEmail',(select count(*) from public.depots where coalesce(btrim(email_to),'')<>''),
    'depotTotal',(select count(*) from public.depots));
$function$;
CREATE OR REPLACE FUNCTION rc_private.compile_upload(p_rows jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid(); cached rc_private.requests%rowtype; v_payload jsonb;
 r jsonb; k text; baris integer:=0;
 v_depot public.depots%rowtype; v_camp public.campaigns%rowtype; v_cust public.customers%rowtype;
 v_abbr text; v_code text; v_custcode text; v_jenis text; v_status text;
 v_net numeric; v_vol numeric; v_cb numeric; v_doc text; v_gross numeric; v_subject text;
 dibuat integer:=0; duplikat jsonb:='[]'; ditolak jsonb:='[]'; dibuat_doc jsonb:='[]';
 batch text; kunci text; terlihat jsonb:='{}';
begin
 if not rc_private.can_access(null,'view_compilation') then
  raise exception 'Access denied' using errcode='42501'; end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array' then raise exception 'Data harus berupa array'; end if;
 if jsonb_array_length(p_rows) not between 1 and 2000 then
  raise exception 'Satu compile maksimal 2000 baris'; end if;
 if p_request_id is null then raise exception 'Request id wajib'; end if;

 -- Idempotency: file yang sama dikirim ulang karena timeout tidak membuat baris kedua.
 v_payload:=jsonb_build_object('rows',p_rows);
 insert into rc_private.requests(actor_id,request_id,payload) values(actor,p_request_id,v_payload)
 on conflict do nothing;
 select * into strict cached from rc_private.requests where actor_id=actor and request_id=p_request_id for update;
 if cached.payload<>v_payload then raise exception 'Request id dipakai ulang untuk data berbeda'; end if;
 if cached.result is not null then return cached.result; end if;

 batch:=rc_private.next_batch('05');

 for r in select value from jsonb_array_elements(p_rows) loop
  baris:=baris+1;
  if jsonb_typeof(r)<>'object' then raise exception 'Baris % bukan objek',baris; end if;
  for k in select key from jsonb_each(r) loop
   if k not in('kodeDepot','abbr','codeCampaign','custCode','custName','netValue','volume','cbNet','jenisCb')
   then raise exception 'Baris %: kolom tidak dikenali "%"',baris,k; end if;
  end loop;

  v_abbr    :=upper(btrim(coalesce(r->>'abbr','')));
  v_code    :=upper(btrim(coalesce(r->>'codeCampaign','')));
  v_custcode:=upper(btrim(coalesce(r->>'custCode','')));
  v_jenis   :=upper(btrim(coalesce(r->>'jenisCb','')));
  if v_jenis not in('','TRANSFER','VOUCHER','CN','REBATE','RA07','RA7','REBATE MANUAL') then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,'alasan','Jenis CB tidak valid'));continue; end if;

  select * into v_depot from public.depots where depot_code=btrim(coalesce(r->>'kodeDepot','')) and archived_at is null;
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Kode depot "'||coalesce(r->>'kodeDepot','')||'" tidak ada di master depot, atau sudah diarsipkan'));
   continue; end if;
  if not rc_private.can_access(v_depot.id) then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Depot '||v_depot.depot_code||' di luar akses Anda'));
   continue; end if;

  -- Abbr dikunci ke depot. Bila master belum punya, nilai pertama yang sah dipakai.
  if v_abbr='' then v_abbr:=coalesce(v_depot.abbr,''); end if;
  if v_abbr='' then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Abbr wajib diisi untuk depot '||v_depot.depot_code));
   continue; end if;
  if v_depot.abbr is null then
   update public.depots set abbr=v_abbr where id=v_depot.id;
  elsif v_depot.abbr<>v_abbr then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Abbr "'||v_abbr||'" berbeda dengan master depot '||v_depot.depot_code||' ("'||v_depot.abbr||'")'));
   continue; end if;

  select * into v_camp from public.campaigns where campaign_code=v_code and archived_at is null;
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Campaign "'||v_code||'" belum ada di Campaign Master, atau sudah diarsipkan'));
   continue; end if;

  select * into v_cust from public.customers where customer_code=v_custcode and archived_at is null;
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Customer "'||v_custcode||'" belum ada di Customer Master, atau sudah diarsipkan'));
   continue; end if;

  -- Duplikat di dalam file itu sendiri, sebelum menyentuh database.
  kunci:=v_code||'|'||v_custcode;
  if terlihat ? kunci then
   duplikat:=duplikat||jsonb_build_array(jsonb_build_object('baris',baris,'kunci',kunci,
     'alasan','Duplikat di dalam file'));
   continue; end if;
  terlihat:=terlihat||jsonb_build_object(kunci,true);

  if exists(select 1 from public.claims c where c.campaign_id=v_camp.id
            and c.customer_id=v_cust.id and c.archived_at is null) then
   duplikat:=duplikat||jsonb_build_array(jsonb_build_object('baris',baris,'kunci',kunci,
     'alasan','Kombinasi campaign dan customer sudah ada'));
   continue; end if;

  begin
   v_net:=rc_private.source_number(r->>'netValue');
   v_vol:=rc_private.source_number(r->>'volume');
   v_cb :=rc_private.source_number(r->>'cbNet');
  exception when others then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Nilai angka tidak dapat dibaca; periksa Net Value, Volume dan Cashback'));
   continue; end;
  if v_cb is null or v_cb<0 then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Cashback wajib diisi dan tidak boleh negatif'));
   continue; end if;

  -- RA07 dan RA7 menandai cashback yang sudah direalisasi di luar sistem.
  v_status:='not_yet';

  v_subject:=v_cust.tax_subject;
  v_gross:=case when v_subject is not null
                then rc_private.gross_claimed(v_cb,v_subject,v_camp.tax_status) else null end;

  v_doc:=rc_private.next_document(v_abbr,v_code);

  insert into public.claims(no_doc,campaign_id,customer_id,depot_id,status,legacy_status,
    net_value,volume,cb_net,gross_up,tax_subject,period_start,period_end,
    uploaded_at,cleared_at,batch_clearing,version_no,cashback_type_override,created_by,cashback_type_changed)
  values(v_doc,v_camp.id,v_cust.id,v_depot.id,v_status,
    case when v_status='done' then v_jenis else null end,
    v_net,v_vol,v_cb,v_gross,v_subject,v_camp.period_start,v_camp.period_end,
    case when v_status='done' then now() else null end,
    case when v_status='done' then now() else null end,
    case when v_status='done' then batch else null end,1,rc_private.cb_label(v_jenis),actor,v_jenis<>'' and rc_private.jenis_efektif(v_jenis)<>rc_private.jenis_efektif(v_camp.cashback_type));

  insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
  select id,actor,null,v_status,'compile_import',batch,'Compile cashback'
  from public.claims where no_doc=v_doc;

  dibuat:=dibuat+1;
  dibuat_doc:=dibuat_doc||jsonb_build_array(jsonb_build_object('baris',baris,'noDoc',v_doc,
    'status',rc_private.legacy_status(v_status)));
 end loop;

 insert into public.activity_logs(actor_id,event_type,details)
 values(actor,'compile_upload',jsonb_build_object('dibuat',dibuat,'batch',batch,
   'duplikat',jsonb_array_length(duplikat),'ditolak',jsonb_array_length(ditolak)));

 v_payload:=jsonb_build_object('status','success','dibuat',dibuat,'batch',batch,
   'dokumen',dibuat_doc,'duplikat',duplikat,'ditolak',ditolak);
 update rc_private.requests set result=v_payload where actor_id=actor and request_id=p_request_id;
 return v_payload;
end $function$;
CREATE OR REPLACE FUNCTION public.rc_timetable_matrix(p_filter jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_region text; v_depot text; v_campaign text; v_tanggal date;
begin
 if not (rc_private.can_tab('timetable.matrix') or rc_private.can_tab('access.exclude') or rc_private.can_tab('report.dashboard')) then raise exception 'Timetable access denied' using errcode='42501';end if;
  -- Izin Timetable ATAU izin Report; keduanya membuka layar yang sama. Sebelumnya hanya
  -- 'view_report' yang diterima, sehingga akun yang justru diberi modul Timetable tetap ditolak.
  if not rc_private.can_access(null,'manage_timetable')
     and not rc_private.can_access(null,'view_report')
     and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat Timetable' using errcode='42501'; end if;

  v_region   := nullif(btrim(coalesce(p_filter->>'region','')),'');
  v_depot    := nullif(btrim(coalesce(p_filter->>'depot','')),'');
  v_campaign := nullif(btrim(coalesce(p_filter->>'campaign','')),'');
  v_tanggal  := coalesce(nullif(btrim(coalesce(p_filter->>'tanggal','')),'')::date, (now() at time zone 'Asia/Jakarta')::date);

  return (
    with campaign_aktif as (
      select ca.id, ca.campaign_code, ca.campaign_name, ca.period_start, ca.period_end
        from public.campaigns ca
       where ca.archived_at is null and ca.period_start is not null
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
       where d.archived_at is null and rc_private.can_access(d.id)
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
        from (select id,depot_code,depot_name from public.depots where archived_at is null) d
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
end $function$;
notify pgrst,'reload schema';
