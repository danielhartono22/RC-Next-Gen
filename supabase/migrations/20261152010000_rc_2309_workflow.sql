-- RC 23 September: Submitted lifecycle, persistent CB override, chronology and limits.
alter table public.claims add column if not exists cashback_type_override text;
alter table public.claims add column if not exists cashback_type_changed boolean not null default false;
alter table public.claims add column if not exists reprocessed_at timestamptz;
alter table public.claims add column if not exists bulk_processed_at timestamptz;
alter table public.claims add column if not exists bulk_processed_by uuid references public.profiles(id);
create or replace function rc_private.jenis_efektif(p_jenis text) returns text language sql immutable set search_path='' as $$
 select case lower(btrim(coalesce(p_jenis,''))) when 'voucher' then 'transfer'
 when 'ra07' then 'rebate manual' when 'ra7' then 'rebate manual' else lower(btrim(coalesce(p_jenis,''))) end;
$$;
create or replace function rc_private.cb_label(p_jenis text) returns text language sql immutable set search_path='' as $$
 select case rc_private.jenis_efektif(p_jenis) when 'rebate manual' then 'Rebate Manual' when 'rebate' then 'Rebate'
 when 'transfer' then 'Transfer' when 'cn' then 'CN' else coalesce(p_jenis,'') end;
$$;
CREATE OR REPLACE FUNCTION rc_private.legacy_date(d date)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ select case when d is null then '' else to_char(d,'DD-Mon-YYYY') end; $function$
;
CREATE OR REPLACE FUNCTION rc_private.legacy_ts(t timestamp with time zone)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 select case when t is null then '' else to_char(t at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS') end; $function$
;
CREATE OR REPLACE FUNCTION rc_private.mutate_claims_unchecked(p_action text, p_items jsonb, p_request_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid(); perm text; v_payload jsonb; cached rc_private.requests%rowtype;
 c public.claims%rowtype; item jsonb; target text; batch text; stage text; subject text;
 processed jsonb:='[]'; stamp timestamptz:=now(); expire_batch text;
 cust public.customers%rowtype; camp public.campaigns%rowtype; jenis text; v_jenis_input text;
 v_ktp text; v_npwp text; v_bank text; v_norek text; v_namarek text; v_top text; v_gross numeric;
 master_top numeric; input_top numeric; master_changed boolean;
begin
 if p_action not in('submit','release','claim','clearing','reject_release','reject_claim','reject_clearing','hold','unhold','expire','bulk_rebate','approve','reject_approval','approve_hold','reject_hold','expire_claim_process')
 or p_action is null then raise exception 'Unknown action'; end if;
 perm:=case when p_action in('submit','hold','unhold','expire') then 'upload_claim'
 when p_action in('approve','reject_approval','approve_hold','reject_hold') then 'approve_claim'
 when p_action in('release','reject_release') then 'release_claim'
 when p_action='bulk_rebate' then 'bulk_process' else 'process_claim' end;
 if not rc_private.can_access(null,perm) then raise exception 'Access denied' using errcode='42501'; end if;
 -- Menahan dan menghanguskan adalah keputusan yang lebih berat daripada menyetujui tempo
 -- pembayaran, jadi peran yang berwenang memutuskannya dibatasi tersendiri. Jangkauannya
 -- tetap dijaga can_access pada tiap baris di bawah.
 if p_action in('approve_hold','reject_hold') and not rc_private.boleh_putus_hold() then
  raise exception 'Keputusan On Hold dan Expired ditetapkan OSC, Supervisor, Management atau System Manager' using errcode='42501'; end if;
 if p_request_id is null or p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Invalid request'; end if;
 if jsonb_array_length(p_items) not between 1 and 500 then raise exception 'Satu proses maksimal 500 dokumen'; end if;
 if length(coalesce(p_reason,''))>1000 then raise exception 'Reason too long'; end if;
 if p_action in('reject_release','reject_claim','reject_clearing','hold','unhold','expire','expire_claim_process') and btrim(coalesce(p_reason,''))='' then raise exception 'Reason required'; end if;
 if exists(select 1 from jsonb_array_elements(p_items) x where jsonb_typeof(x)<>'object' or coalesce(x->>'no_doc','')='' or x->>'version_no' is null)
 or (select count(distinct x->>'no_doc') from jsonb_array_elements(p_items) x)<>jsonb_array_length(p_items)
 then raise exception 'Each claim must have a unique document number and version'; end if;
 v_payload:=jsonb_build_object('action',p_action,'items',p_items,'reason',p_reason);
 insert into rc_private.requests(actor_id,request_id,payload) values(actor,p_request_id,v_payload) on conflict do nothing;
 select * into strict cached from rc_private.requests where actor_id=actor and request_id=p_request_id for update;
 if cached.payload<>v_payload then raise exception 'Request ID reused for different payload'; end if;
 if cached.result is not null then return cached.result; end if;
 -- Expired kini ikut memperoleh nomor batch, dan nomornya diterbitkan pada tahap Clearing
 -- sesuai permintaan pemilik: dokumen yang di-Expired harus tetap terlihat nomor batch-nya,
 -- dan tempatnya di kolom Clearing.
 stage:=case p_action when 'submit' then '01' when 'release' then '02' when 'claim' then '03'
   when 'clearing' then '04' when 'expire_claim_process' then '04' when 'bulk_rebate' then '02' end;

 for item in select value from jsonb_array_elements(p_items) order by value->>'no_doc' loop
 select * into c from public.claims where no_doc=item->>'no_doc' for update;
 if not found then raise exception 'Document not found'; end if;
 if c.archived_at is not null then raise exception 'Dokumen % sudah diarsipkan',c.no_doc; end if;
 if not rc_private.can_access(c.depot_id,perm) then raise exception 'Depot access denied' using errcode='42501'; end if;
 if c.version_no<>(item->>'version_no')::bigint then raise exception 'Document changed; refresh first' using errcode='40001'; end if;
 if c.pending_approval is not null and not (
   (c.pending_approval->>'kind'='submit' and p_action in('approve','reject_approval'))
   or (c.pending_approval->>'kind' in('hold','expire') and p_action in('approve_hold','reject_hold'))
 ) then raise exception 'Dokumen % masih menunggu approval',c.no_doc; end if;
 select * into camp from public.campaigns where id=c.campaign_id;
 -- Jenis CB berasal dari Campaign Master, tetapi pengguna boleh menimpanya per dokumen.
 -- Nilai yang dikirim layar harus persis salah satu dari daftar resmi; salah ketik ditolak
 -- di sini juga, bukan hanya di browser, supaya pemanggil lain tidak bisa melewatinya.
 v_jenis_input:=btrim(coalesce(item->>'jenis_cashback',''));
 if v_jenis_input<>'' then
  if v_jenis_input not in('Transfer','CN','Rebate','RA07','RA7','Rebate Manual','Voucher') then
   raise exception 'Dokumen %: Jenis CB "%" tidak dikenali. Tulis persis Transfer, CN, Rebate atau Rebate Manual',
     c.no_doc,v_jenis_input;
  end if;
  jenis:=rc_private.jenis_efektif(v_jenis_input);
 else
  jenis:=rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override,''),camp.cashback_type));
 end if;

 -- Rebate hanya boleh lewat Bulk Process; jalur bertahap tidak berlaku untuknya, dan
 -- sebaliknya Bulk Process tidak boleh menyentuh campaign non-Rebate.
 if p_action in('release','claim','clearing','reject_release','reject_claim','reject_clearing')
    and jenis='rebate' then
  raise exception 'Dokumen % berjenis Rebate dan hanya dapat diproses lewat Bulk Process',c.no_doc;
 end if;

 target:=null;
 -- Pengajuan tidak mengubah status. RA07/RA7 selesai setelah disetujui.
 if p_action='submit' and c.status='not_yet' and c.pending_approval is null then target:='submitted';
 elsif p_action='approve' and c.status='submitted' and c.pending_approval->>'kind'='submit' then
  target:=coalesce(c.pending_approval->>'target_status','approved');
 elsif p_action='reject_approval' and c.status='submitted' and c.pending_approval->>'kind'='submit' then target:='not_yet';
 elsif p_action='release' and c.status='approved' then target:='released';
 elsif p_action='claim' and c.status='released' then target:='claimed';
 elsif p_action='clearing' and c.status='claimed' then target:='done';
 elsif p_action='reject_release' and c.status in('submitted','approved') then target:='not_yet';
 elsif p_action='reject_claim' and c.status='released' then target:='approved';
 elsif p_action='reject_clearing' and c.status='claimed' then target:='released';
 elsif p_action='hold' and c.status in('not_yet','submitted','approved','released','claimed') then target:=c.status;
 elsif p_action='unhold' and c.status='on_hold' and c.previous_status in('not_yet','submitted','approved','released','claimed') then target:=c.previous_status;
 elsif p_action='expire' and c.status in('not_yet','approved','released','claimed','on_hold') then target:=c.status;
 elsif p_action='expire_claim_process' and c.status in('released','claimed') then target:='expired';
 elsif p_action='approve_hold' and c.pending_approval->>'kind' in('hold','expire') then target:=c.pending_approval->>'target_status';
 elsif p_action='reject_hold' and c.pending_approval->>'kind' in('hold','expire') then target:=c.status;
 elsif p_action='bulk_rebate' and c.status in('approved','released','claimed') then
  if jenis<>'rebate' then raise exception 'Dokumen % bukan campaign Rebate',c.no_doc; end if;
  target:='done';
 end if;
 if target is null then raise exception 'Invalid status transition for %',c.no_doc; end if;
 if p_action='approve_hold' then
  if target='expired' then
   if expire_batch is null then expire_batch:=rc_private.next_batch('04'); end if;
   batch:=expire_batch;
  else batch:=null; end if;
 end if;
 if stage is not null and batch is null then batch:=rc_private.next_batch(stage); end if;
 -- Approval bekerja ATAS batch unggahan dan tidak menerbitkan nomor sendiri: nomor yang
 -- dicatat riwayat adalah nomor yang benar-benar dilihat penyetujunya di layar.
 if p_action in('approve','reject_approval') then batch:=c.batch_upload; end if;

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
  -- Penjaga "TOP melebihi Customer Master maka Approval wajib" dicabut atas instruksi
  -- pemilik: seluruh dokumen boleh diunggah, dan layak-tidaknya TOP ditentukan di modul
  -- Management of Approval - bukan oleh orang yang mengetik unggahannya. TOP-nya tetap
  -- disimpan di bawah, karena justru nilai itulah yang dipakai modul tersebut.

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

  -- TOP TIDAK lagi ikut diperbarui dari unggahan: ia kesepakatan, bukan data mutakhir,
  -- dan dokumen yang menulis ulang acuannya sendiri membuat persetujuan kehilangan arti.
  if master_changed then
   update public.customers set account_number=v_norek,account_name=v_namarek,bank=v_bank,
     updated_at=now(),updated_by=actor
   where id=cust.id;
   insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
   values(actor,c.depot_id,'customer_master_updated_from_upload',c.id,
     jsonb_build_object('custCode',cust.customer_code,'noDoc',c.no_doc));
  end if;

  v_gross:=rc_private.gross_claimed(c.cb_net,subject,camp.tax_status);
  update public.claims set tax_subject=subject,gross_up=v_gross,
    cashback_type_override=case when v_jenis_input<>'' then rc_private.cb_label(v_jenis_input) else cashback_type_override end,
    cashback_type_changed=cashback_type_changed or (v_jenis_input<>'' and rc_private.jenis_efektif(v_jenis_input)<>rc_private.jenis_efektif(camp.cashback_type)),
    total_billing=case when item ? 'total_billing' then (item->>'total_billing')::numeric else total_billing end,
    period_start=coalesce(nullif(item->>'period_start','')::date,period_start,camp.period_start),
    period_end=coalesce(nullif(item->>'period_end','')::date,period_end,camp.period_end),paid_on=coalesce(nullif(item->>'paid_on','')::date,paid_on),
    approval=coalesce(item->>'approval',approval),billing_months=coalesce(item->'billing_months',billing_months)
   where id=c.id;
  insert into rc_private.claim_sensitive(claim_id) values(c.id) on conflict do nothing;
  update rc_private.claim_sensitive set ktp=v_ktp,npwp=v_npwp,bank=v_bank,
    account_number=v_norek,account_name=v_namarek,top_text=v_top where claim_id=c.id;
 end if;

 update public.claims set status=target,
 bulk_processed_at=case when p_action='bulk_rebate' then stamp else bulk_processed_at end,
 bulk_processed_by=case when p_action='bulk_rebate' then actor else bulk_processed_by end,
 pending_approval=case
   when p_action in('submit','hold','expire') then jsonb_build_object(
     'kind',p_action,'requested_by',actor,'requested_at',stamp,'reason',p_reason,
     'target_status',case when p_action='hold' then 'on_hold' when p_action='expire' then 'expired'
       when jenis='rebate manual' then 'done' else 'approved' end)
   when p_action in('approve','reject_approval','approve_hold','reject_hold') then null else pending_approval end,
 previous_status=case when p_action='approve_hold' and target='on_hold' then c.status
   when p_action='unhold' then null else previous_status end,
 extend_so_start=case when p_action='approve_hold' and target='on_hold' then coalesce((c.pending_approval->>'so_start')::date,extend_so_start) else extend_so_start end,
 extend_so_end=case when p_action='approve_hold' and target='on_hold' then coalesce((c.pending_approval->>'so_end')::date,extend_so_end) else extend_so_end end,
 extend_billing_start=case when p_action='approve_hold' and target='on_hold' then coalesce((c.pending_approval->>'billing_start')::date,extend_billing_start) else extend_billing_start end,
 extend_billing_end=case when p_action='approve_hold' and target='on_hold' then coalesce((c.pending_approval->>'billing_end')::date,extend_billing_end) else extend_billing_end end,
 uploaded_at=case when p_action='submit' then stamp when p_action in('reject_release','reject_approval') then null else uploaded_at end,
 hold_approved_at=case when p_action='approve_hold' then stamp else hold_approved_at end,
 hold_approved_by=case when p_action='approve_hold' then actor else hold_approved_by end,
 submitted_by=case when p_action='submit' then actor when p_action in('reject_release','reject_approval') then null else submitted_by end,
 approved_at=case when p_action='approve' then stamp when p_action in('reject_approval','reject_release') then null else approved_at end,
 approved_by=case when p_action='approve' then actor when p_action in('reject_approval','reject_release') then null else approved_by end,
 released_at=case when p_action='release' then stamp when p_action='reject_claim' then null else released_at end,
 released_by=case when p_action='release' then actor when p_action='reject_claim' then null else released_by end,
 claimed_at=case when p_action='claim' then stamp when p_action='reject_clearing' then null else claimed_at end,
 claimed_by=case when p_action='claim' then actor when p_action='reject_clearing' then null else claimed_by end,
 cleared_at=case when p_action in('clearing','bulk_rebate') or (p_action='approve' and target='done') then stamp else cleared_at end,
 cleared_by=case when p_action in('clearing','bulk_rebate') or (p_action='approve' and target='done') then actor else cleared_by end,
 batch_upload=case when p_action='submit' then batch when p_action='reject_release' then null else batch_upload end,
 batch_release=case when p_action in('release','bulk_rebate') then batch when p_action='reject_claim' then null else batch_release end,
 batch_claim=case when p_action in('claim','bulk_rebate') then batch when p_action='reject_clearing' then null else batch_claim end,
 batch_clearing=case when p_action in('clearing','bulk_rebate','expire_claim_process') or (p_action='approve_hold' and target='expired') then batch
   when p_action='approve' and target='done' then c.batch_upload else batch_clearing end,
 version_no=version_no+1,updated_at=stamp where id=c.id;
 if p_action='approve' and target='done' then
  insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
   values(c.id,actor,c.status,'approved','approve',batch,p_reason),(c.id,actor,'approved','done','manual_complete',batch,'Rebate Manual');
 elsif p_action='bulk_rebate' then
  insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
   values(c.id,actor,c.status,'bulk_processed','bulk_process',batch,p_reason),(c.id,actor,'bulk_processed','done','bulk_rebate',batch,p_reason);
 else
  insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
   values(c.id,actor,c.status,target,p_action,batch,p_reason);
 end if;
 insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
 values(actor,c.depot_id,p_action,c.id,jsonb_build_object('from',c.status,'to',target,'batch',batch));
 processed:=processed||jsonb_build_array(jsonb_build_object('no_doc',c.no_doc,'status',target,
   'version_no',c.version_no+1,'pending_approval',p_action in('submit','hold','expire'),'gross_up',coalesce(v_gross,c.gross_up)));
 end loop;
 v_payload:=jsonb_build_object('processed',processed,'batch',batch,'count',jsonb_array_length(processed));
 update rc_private.requests set result=v_payload where actor_id=actor and request_id=p_request_id;
 return v_payload;
end $function$
;
CREATE OR REPLACE FUNCTION rc_private.mutate_claims(p_action text, p_items jsonb, p_request_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare item jsonb; field record; month_value jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Items must be an array'; end if;
 if octet_length(p_items::text)>4194304 then raise exception 'Payload exceeds 4 MiB'; end if;
 for item in select value from jsonb_array_elements(p_items) loop
  if jsonb_typeof(item)<>'object' then raise exception 'Each item must be an object'; end if;
  if jsonb_typeof(item->'no_doc') is distinct from 'string' or btrim(item->>'no_doc')='' or length(item->>'no_doc')>200
    or jsonb_typeof(item->'version_no') is distinct from 'number' or item->>'version_no' !~ '^[1-9][0-9]{0,17}$'
  then raise exception 'Invalid document or version'; end if;
  for field in select key,value from jsonb_each(item) loop
   if field.key not in('no_doc','version_no','tax_subject','total_billing','period_start','period_end','paid_on','approval','billing_months','ktp','npwp','bank','account_number','account_name','top','jenis_cashback')
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
end $function$
;
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
    uploaded_at,cleared_at,batch_clearing,version_no,cashback_type_override,created_by)
  values(v_doc,v_camp.id,v_cust.id,v_depot.id,v_status,
    case when v_status='done' then v_jenis else null end,
    v_net,v_vol,v_cb,v_gross,v_subject,v_camp.period_start,v_camp.period_end,
    case when v_status='done' then now() else null end,
    case when v_status='done' then now() else null end,
    case when v_status='done' then batch else null end,1,rc_private.cb_label(v_jenis),actor);

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
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_compile_preview(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare r jsonb; baris integer:=0; siap integer:=0; duplikat jsonb:='[]'; ditolak jsonb:='[]';
 terlihat jsonb:='{}'; kunci text; v_code text; v_custcode text;
 v_depot public.depots%rowtype; v_camp public.campaigns%rowtype; v_cust public.customers%rowtype;
begin
 if not rc_private.can_access(null,'view_compilation') then
  raise exception 'Access denied' using errcode='42501'; end if;
 if jsonb_array_length(p_rows)>2000 then raise exception 'Satu compile maksimal 2000 baris'; end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array' then raise exception 'Data harus berupa array'; end if;
 if jsonb_array_length(p_rows) not between 1 and 2000 then
  raise exception 'Satu compile maksimal 2000 baris'; end if;

 for r in select value from jsonb_array_elements(p_rows) loop
  baris:=baris+1;
  v_code:=upper(btrim(coalesce(r->>'codeCampaign','')));
  v_custcode:=upper(btrim(coalesce(r->>'custCode','')));
  select * into v_depot from public.depots where depot_code=btrim(coalesce(r->>'kodeDepot',''));
  if not found or not rc_private.can_access(v_depot.id) then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Depot tidak dikenali atau di luar akses')); continue; end if;
  select * into v_camp from public.campaigns where campaign_code=v_code;
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Campaign "'||v_code||'" belum ada di Campaign Master')); continue; end if;
  select * into v_cust from public.customers where customer_code=v_custcode;
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Customer "'||v_custcode||'" belum ada di Customer Master')); continue; end if;
  kunci:=v_code||'|'||v_custcode;
  if terlihat ? kunci or exists(select 1 from public.claims c where c.campaign_id=v_camp.id
       and c.customer_id=v_cust.id and c.archived_at is null) then
   duplikat:=duplikat||jsonb_build_array(jsonb_build_object('baris',baris,'kunci',kunci)); continue; end if;
  terlihat:=terlihat||jsonb_build_object(kunci,true);
  siap:=siap+1;
 end loop;

 return jsonb_build_object('status','success','siap',siap,'duplikat',duplikat,'ditolak',ditolak,
  'total',baris);
end $function$
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
   'cbNet',c.cb_net,'netValue',c.net_value,'volume',c.volume,
   'pendingApproval',c.pending_approval is not null,'versionNo',c.version_no) as x
  from public.claims c
  join public.depots d on d.id=c.depot_id
  join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  where rc_private.can_access(c.depot_id)
  order by c.no_doc limit 20000) t;
$function$
;
create or replace function rc_private.claim_remark(c public.claims) returns text language sql stable set search_path='' as $$
 select concat_ws(', ',case when c.reprocessed_at is not null or exists(select 1 from public.claim_status_history h where h.claim_id=c.id and h.action like '%reprocess%') then 'Reprocessing' end,
 case when c.cashback_type_changed then 'CB Type Changed' end); $$;
CREATE OR REPLACE FUNCTION public.rc_legacy_workflow()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
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
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'statusPajakCamp',coalesce(ca.tax_status,''),
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
   'approvedBy',coalesce(nama->>(pel.approve_by::text),''),
   'tglApprove',rc_private.legacy_ts(c.approved_at),
   'releasedBy',coalesce(nama->>(pel.release_by::text),''),
   'claimedBy',coalesce(nama->>(pel.claim_by::text),''),
   'clearedBy',coalesce(nama->>(pel.clear_by::text),''),
   'versionNo',c.version_no,'remark',rc_private.claim_remark(c), 'campaignYear',extract(year from coalesce(c.period_start,ca.period_start)),
   'rebate',lower(btrim(rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type))))='rebate') as x
  from public.claims c
  left join public.depots d on d.id=c.depot_id
  left join public.customers cu on cu.id=c.customer_id
  left join public.campaigns ca on ca.id=c.campaign_id
  left join rc_private.claim_sensitive s on s.claim_id=c.id
  -- Pelaku terakhir untuk tiap tahap. Yang diambil yang terbaru: sebuah dokumen dapat
  -- ditolak lalu di-release ulang, dan yang relevan adalah pelaku terakhir.
  left join lateral (
    select
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.action='submit' and h.actor_id is not null))[1] as submit_by,
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='approved' and h.actor_id is not null))[1] as approve_by,
         (array_agg(h.actor_id order by h.created_at desc)
         filter (where h.to_status='released' and h.actor_id is not null))[1] as release_by,
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='claimed' and h.actor_id is not null))[1] as claim_by,
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='done' and h.actor_id is not null))[1] as clear_by
    from public.claim_status_history h where h.claim_id = c.id) pel on true
  where c.archived_at is null and rc_private.can_access(c.depot_id) and c.status in('approved','released','claimed') and c.pending_approval is null
  order by c.updated_at desc,c.id limit 5000) t;

 -- Rebate dipisah tegas: tidak muncul di antrean bertahap, hanya di Bulk Process.
 return jsonb_build_object('status','success',
  'releaseData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where v->>'status'='Approved' and not (v->>'rebate')::boolean),
  'claimFinData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where v->>'status'='Released' and not (v->>'rebate')::boolean),
  'clearingData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where v->>'status'='Claimed' and not (v->>'rebate')::boolean),
  'bulkRebateData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where (v->>'rebate')::boolean and v->>'status' <> 'Submitted'));
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_open_claims(p_search text DEFAULT ''::text, p_campaign text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 200)
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
    and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
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
    and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,200),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 return jsonb_build_object('status','success','rows',v,'total',jml);
end $function$
;
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
    'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),
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
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_depot_profile(p_kode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_depot uuid; v_kode text;
begin
  v_kode := upper(btrim(coalesce(p_kode,'')));
  select id into v_depot from public.depots where depot_code = v_kode;
  if v_depot is null then raise exception 'Depot "%" tidak ditemukan', v_kode; end if;
  if not rc_private.can_access(v_depot) then
    raise exception 'Depot ini di luar yurisdiksi Anda' using errcode='42501'; end if;

  return (
    select jsonb_build_object(
      'status','success',
      'kodeDepot', d.depot_code,
      'namaDepot', d.depot_name,
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
end $function$
;
CREATE OR REPLACE FUNCTION rc_private.legacy_profile_requests()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce(jsonb_agg(x order by x->>'tglRequest' desc),'[]'::jsonb) from (
  select jsonb_build_object(
    'id','signup:'||p.id,'namaDepot',coalesce(nullif(p.requested_depot,''),'Depot belum ditentukan'),
    'kodeDepot','','requesterId',p.user_code,
    'changes',jsonb_strip_nulls(jsonb_build_object(
      'Pendaftaran akun baru',p.full_name,'Email kantor',p.business_email,
      'Role diminta',p.requested_role,'Depot diminta',nullif(p.requested_depot,''))),
    'tglRequest',to_char(p.registered_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI')) as x
  from public.profiles p where p.status='pending' and rc_private.can_view_managed_user(p.id)
  union all
  select jsonb_build_object(
    'id','profile:'||r.id,'namaDepot',d.depot_name,'kodeDepot',d.depot_code,
    'requesterId',coalesce(p.user_code,''),'changes',r.changes,
    'tglRequest',to_char(r.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI')) as x
  from public.profile_change_requests r
  join public.depots d on d.id=r.depot_id
  left join public.profiles p on p.id=r.requester_id
  where r.status='pending' and rc_private.can_access(r.depot_id)) t;
$function$
;
CREATE OR REPLACE FUNCTION public.rc_approval_detail(p_batch text, p_kind text DEFAULT 'wpt'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v_ovd boolean; hasil jsonb;
begin
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak menyetujui dokumen' using errcode='42501'; end if;
  v_ovd := lower(coalesce(p_kind,'wpt')) = 'ovd';
  if v_ovd and not rc_private.boleh_approve_overdue() then
    raise exception 'Depot Head hanya dapat menyetujui dokumen Within Payment Term'
      using errcode='42501'; end if;

  select jsonb_build_object('status','success','noBatch',p_batch,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'noDoc', r.no_doc, 'versionNo', r.version_no,
      'kodeCust', r.customer_code, 'namaCust', r.customer_name,
      'kodeCampaign', r.campaign_code, 'namaCampaign', coalesce(r.campaign_name,''),
      'netCb', r.cb_net, 'jenisCb', r.jenis_cb_label,
      'topSetting', coalesce(r.top_setting,''),
      'topAktual', coalesce(r.top_aktual,''),
      -- Selisihnya dihitung sekali di sini supaya layar tidak perlu menghitung ulang dan
      -- berisiko memakai aturan yang berbeda.
      'topSelisih', case
        when r.top_aktual ~ '^[0-9]+([.][0-9]+)?$' and r.top_setting ~ '^[0-9]+([.][0-9]+)?$'
        then r.top_aktual::numeric - r.top_setting::numeric else null end,
      'statusPajak', coalesce(r.tax_subject,''),
      'statusPajakCampaign', coalesce(r.tax_status,''),
      'submittedBy', coalesce(ps.full_name,''),
      'postingDate', to_char(r.uploaded_at at time zone 'Asia/Jakarta','DD-Mon-YYYY'),
      'approvedBy', coalesce(pa.full_name,''),
      'approvedAt', to_char(r.approved_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI'),
      'overdue', rc_private.approval_overdue(r.top_aktual, r.top_setting))
      order by r.no_doc), '[]'::jsonb))
  into hasil
  from rc_private.approval_rows r
  left join public.profiles ps on ps.id = r.submitted_by
  left join public.profiles pa on pa.id = r.approved_by
  where coalesce(nullif(btrim(r.batch_upload),''),'(tanpa batch)') = coalesce(p_batch,'')
    and rc_private.can_access(r.depot_id,'approve_claim')
    and rc_private.approval_overdue(r.top_aktual, r.top_setting) = v_ovd;
  return hasil;
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_approval_hold(p_depot text DEFAULT NULL::text, p_search text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare hasil jsonb; v_depot text; v_cari text;
begin
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat antrean ini' using errcode='42501'; end if;
  v_depot := nullif(btrim(coalesce(p_depot,'')),'');
  v_cari  := nullif(btrim(coalesce(p_search,'')),'');

  select jsonb_build_object('status','success',
    -- Layar memakai penanda ini untuk membekukan tombolnya. Penjagaan sebenarnya tetap di
    -- mesin status; ini hanya supaya orang tidak menekan tombol yang pasti ditolak.
    'bolehPutus', rc_private.boleh_putus_hold(),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'noDoc', t.no_doc, 'versionNo', t.version_no,
      'statusKini', rc_private.legacy_status(t.status),
      'statusPengajuan',rc_private.legacy_status(t.pending_approval->>'target_status'),
      'asal', case when t.previous_status is null then ''
                   else rc_private.legacy_status(t.previous_status) end,
      'kodeDepot', t.depot_code, 'namaDepot', t.depot_name,
      'kodeCust', t.customer_code, 'namaCust', t.customer_name,
      'kodeCampaign', t.campaign_code, 'namaCampaign', coalesce(t.campaign_name,''),
      'netCb', t.cb_net, 'jenisCb', coalesce(t.cashback_type,''),
      'noBatch', coalesce(nullif(btrim(t.batch_upload),''),'-'),
      'alasanTerakhir', coalesce(t.reason,''),
      'olehTerakhir', coalesce(t.actor_name,''),
      'waktuTerakhir', case when t.changed_at is null then ''
        else to_char(t.changed_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI') end)
      order by t.changed_at desc nulls last, t.no_doc), '[]'::jsonb))
  into hasil
  from (
    select c.no_doc, c.version_no, c.status, c.pending_approval, c.previous_status, c.cb_net, c.batch_upload,
           d.depot_code, d.depot_name, cu.customer_code, cu.customer_name,
           ca.campaign_code, ca.campaign_name, ca.cashback_type,
           c.pending_approval->>'reason' as reason, (c.pending_approval->>'requested_at')::timestamptz as changed_at, p.full_name as actor_name
      from public.claims c
      left join public.depots d on d.id = c.depot_id
      left join public.customers cu on cu.id = c.customer_id
      left join public.campaigns ca on ca.id = c.campaign_id
      left join public.profiles p on p.id = (c.pending_approval->>'requested_by')::uuid
     where c.pending_approval->>'kind' in('hold','expire')
       and c.archived_at is null
       and rc_private.can_access(c.depot_id,'approve_claim')
       and (v_depot is null or d.depot_code = v_depot)
       and (v_cari is null or (
            c.no_doc ilike '%'||v_cari||'%'
         or coalesce(cu.customer_code,'') ilike '%'||v_cari||'%'
         or coalesce(cu.customer_name,'') ilike '%'||v_cari||'%'
         or coalesce(ca.campaign_code,'') ilike '%'||v_cari||'%'
         or coalesce(ca.campaign_name,'') ilike '%'||v_cari||'%'
         or coalesce(d.depot_code,'') ilike '%'||v_cari||'%'
         or coalesce(c.pending_approval->>'reason','') ilike '%'||v_cari||'%'))) t;
  return hasil;
end $function$
;
insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,reason)
 select id,null,status,'submitted','workflow_alignment','23 September: pending submit becomes Submitted'
 from public.claims where status='not_yet' and pending_approval->>'kind'='submit';
update public.claims set status='submitted',version_no=version_no+1,updated_at=now()
 where status='not_yet' and pending_approval->>'kind'='submit';
create or replace view rc_private.approval_rows as  SELECT c.id,
    c.no_doc,
    c.depot_id,
    c.batch_upload,
    c.uploaded_at,
    c.cb_net,
    c.tax_subject,
    c.status,
    c.version_no,
    cu.customer_code,
    cu.customer_name,
    ca.campaign_code,
    ca.campaign_name,
    ca.tax_status,
    NULLIF(btrim(COALESCE(cu.top_text, ''::text)), ''::text) AS top_setting,
    NULLIF(btrim(COALESCE(s.top_text, ''::text)), ''::text) AS top_aktual,
    rc_private.jenis_efektif(rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type))) AS jenis_cb,
    COALESCE(rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)), ''::text) AS jenis_cb_label,
    c.submitted_by,
    c.approved_by,
    c.approved_at
   FROM (((claims c
     JOIN customers cu ON ((cu.id = c.customer_id)))
     JOIN campaigns ca ON ((ca.id = c.campaign_id)))
     LEFT JOIN rc_private.claim_sensitive s ON ((s.claim_id = c.id)))
  WHERE (((c.pending_approval ->> 'kind'::text) = 'submit'::text) AND (c.archived_at IS NULL));;
create or replace function rc_private.mark_reprocessing() returns trigger language plpgsql security definer set search_path='' as $$
begin if new.action like '%reprocess%' then update public.claims set reprocessed_at=new.created_at where id=new.claim_id; end if; return new; end $$;
drop trigger if exists rc_mark_reprocessing on public.claim_status_history;
create trigger rc_mark_reprocessing after insert on public.claim_status_history for each row execute function rc_private.mark_reprocessing();
revoke all on function rc_private.mark_reprocessing() from public,anon,authenticated;
notify pgrst,'reload schema';
