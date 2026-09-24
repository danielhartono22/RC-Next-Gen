-- Approval requests do not change the effective claim status.
-- Upload (including RA07/RA7) waits for approval; Claim Process expiry is immediate.
-- Existing pending exceptions are recovered only when their audit trail identifies Upload.
-- Run the rollback integration suite before applying. No production fixture data is included.
alter table public.claims add column if not exists pending_approval jsonb;
comment on column public.claims.pending_approval is 'Pending upload decision; status remains effective until approval. Never set directly by clients.';
create index if not exists claims_pending_approval_idx on public.claims ((pending_approval->>'kind'),depot_id)
 where pending_approval is not null and archived_at is null;

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
 if jsonb_array_length(p_items) not between 1 and 200 then raise exception 'Satu proses maksimal 200 dokumen'; end if;
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
  if v_jenis_input not in('Transfer','CN','Rebate','RA07','RA7','Voucher') then
   raise exception 'Dokumen %: Jenis CB "%" tidak dikenali. Tulis persis Transfer, CN, Rebate, RA07 atau RA7',
     c.no_doc,v_jenis_input;
  end if;
  jenis:=rc_private.jenis_efektif(v_jenis_input);
 else
  jenis:=rc_private.jenis_efektif(camp.cashback_type);
 end if;

 -- Rebate hanya boleh lewat Bulk Process; jalur bertahap tidak berlaku untuknya, dan
 -- sebaliknya Bulk Process tidak boleh menyentuh campaign non-Rebate.
 if p_action in('release','claim','clearing','reject_release','reject_claim','reject_clearing')
    and jenis='rebate' then
  raise exception 'Dokumen % berjenis Rebate dan hanya dapat diproses lewat Bulk Process',c.no_doc;
 end if;

 target:=null;
 -- Pengajuan tidak mengubah status. RA07/RA7 selesai setelah disetujui.
 if p_action='submit' and c.status='not_yet' and c.pending_approval is null then target:='not_yet';
 elsif p_action='approve' and c.status='not_yet' and c.pending_approval->>'kind'='submit' then
  target:=coalesce(c.pending_approval->>'target_status','approved');
 elsif p_action='reject_approval' and c.status='not_yet' and c.pending_approval->>'kind'='submit' then target:='not_yet';
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
 pending_approval=case
   when p_action in('submit','hold','expire') then jsonb_build_object(
     'kind',p_action,'requested_by',actor,'requested_at',stamp,'reason',p_reason,
     'target_status',case when p_action='hold' then 'on_hold' when p_action='expire' then 'expired'
       when jenis in('ra07','ra7') then 'done' else 'approved' end)
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
 released_at=case when p_action in('release','bulk_rebate') then stamp when p_action='reject_claim' then null else released_at end,
 released_by=case when p_action in('release','bulk_rebate') then actor when p_action='reject_claim' then null else released_by end,
 claimed_at=case when p_action in('claim','bulk_rebate') then stamp when p_action='reject_clearing' then null else claimed_at end,
 claimed_by=case when p_action in('claim','bulk_rebate') then actor when p_action='reject_clearing' then null else claimed_by end,
 cleared_at=case when p_action in('clearing','bulk_rebate') or (p_action='approve' and target='done') then stamp else cleared_at end,
 cleared_by=case when p_action in('clearing','bulk_rebate') or (p_action='approve' and target='done') then actor else cleared_by end,
 batch_upload=case when p_action='submit' then batch when p_action='reject_release' then null else batch_upload end,
 batch_release=case when p_action in('release','bulk_rebate') then batch when p_action='reject_claim' then null else batch_release end,
 batch_claim=case when p_action in('claim','bulk_rebate') then batch when p_action='reject_clearing' then null else batch_claim end,
 batch_clearing=case when p_action in('clearing','bulk_rebate','expire_claim_process') or (p_action='approve_hold' and target='expired') then batch
   when p_action='approve' and target='done' then c.batch_upload else batch_clearing end,
 version_no=version_no+1,updated_at=stamp where id=c.id;
 insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
 values(c.id,actor,c.status,target,p_action,batch,p_reason);
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

create or replace view rc_private.approval_rows as
 SELECT c.id,
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
    rc_private.jenis_efektif(ca.cashback_type) AS jenis_cb,
    COALESCE(ca.cashback_type, ''::text) AS jenis_cb_label,
    c.submitted_by,
    c.approved_by,
    c.approved_at
   FROM public.claims c
     JOIN public.customers cu ON cu.id = c.customer_id
     JOIN public.campaigns ca ON ca.id = c.campaign_id
     LEFT JOIN rc_private.claim_sensitive s ON s.claim_id = c.id
  WHERE c.pending_approval->>'kind' = 'submit' AND c.archived_at IS NULL;

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
   'approvedBy',coalesce(nama->>(pel.approve_by::text),''),
   'tglApprove',rc_private.legacy_ts(c.approved_at),
   'releasedBy',coalesce(nama->>(pel.release_by::text),''),
   'claimedBy',coalesce(nama->>(pel.claim_by::text),''),
   'clearedBy',coalesce(nama->>(pel.clear_by::text),''),
   'versionNo',c.version_no,
   'rebate',lower(btrim(coalesce(ca.cashback_type,'')))='rebate') as x
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
  where c.status in('approved','released','claimed') and c.pending_approval is null
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
   'jenisCb',coalesce(ca.cashback_type,''),'statusPajakCamp',coalesce(ca.tax_status,''),
   'cbNet',c.cb_net,'dcCode',d.depot_code,'depotName',d.depot_name,
   'top',coalesce(cu.top_text,''),'ktp',coalesce(cu.ktp,''),'npwp',coalesce(cu.npwp,''),
   'noRek',coalesce(cu.account_number,''),'namaRek',coalesce(cu.account_name,''),
   'bank',coalesce(cu.bank,''),'subyekPajak',coalesce(cu.tax_subject,''),
   'contactPerson',coalesce(cu.contact_person,''),
   -- Dua kolom baru yang diminta pemilik.
   'createdOn',to_char(c.created_at at time zone 'Asia/Jakarta','DD/MM/YYYY'),
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

CREATE OR REPLACE FUNCTION rc_private.legacy_status(s text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
 select case coalesce(nullif(btrim(s),''),'not_yet') when 'not_yet' then 'Not Yet' when 'submitted' then 'Submitted'
 when 'approved' then 'Approved'
 when 'released' then 'Released' when 'claimed' then 'Claimed' when 'done' then 'Done'
 when 'on_hold' then 'On Hold' when 'expired' then 'Expired' else s end;
$function$
;

CREATE OR REPLACE FUNCTION public.rc_reprocessing_upload(p_rows jsonb, p_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r jsonb; v_doc text; c public.claims%rowtype; v_baru numeric;
  n_ok integer := 0; gagal jsonb := '[]'::jsonb; actor uuid := (select auth.uid());
begin
  if not rc_private.can_access(null,'view_compilation') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak mengubah Cashback Compilation' using errcode='42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Tidak ada baris yang dikirim'; end if;
  if jsonb_array_length(p_rows) > 2000 then
    raise exception 'Maksimal 2000 baris sekali unggah'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_doc := upper(btrim(coalesce(r->>'noDoc','')));
    if v_doc = '' then continue; end if;

    select * into c from public.claims where upper(no_doc) = v_doc for update;
    if not found then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Dokumen tidak ditemukan'));
      continue;
    end if;
    if c.status <> 'on_hold' or c.pending_approval is not null then
      -- Menolak dokumen yang tidak tertahan penting: berkas unduhan yang dipakai ulang beberapa
      -- hari kemudian dapat memuat dokumen yang sementara itu sudah diproses orang lain.
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
        'sebab','Status saat ini '||rc_private.legacy_status(c.status)||', bukan On Hold'));
      continue;
    end if;
    if not rc_private.can_access(c.depot_id) then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Depot di luar yurisdiksi Anda'));
      continue;
    end if;

    begin
      v_baru := nullif(btrim(coalesce(r->>'totalCashback','')),'')::numeric;
    exception when others then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
        'sebab','Total cashback bukan angka: '||coalesce(r->>'totalCashback','')));
      continue;
    end;
    if v_baru is null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Total cashback kosong'));
      continue;
    end if;
    if v_baru < 0 then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Total cashback tidak boleh negatif'));
      continue;
    end if;

    update public.claims set
      cb_net = v_baru,
      status = 'not_yet',
      previous_status = null,
      -- Perpanjangan hanya berlaku selama dokumennya tertahan.
      extend_so_start = null, extend_so_end = null,
      extend_billing_start = null, extend_billing_end = null,
      version_no = version_no + 1,
      updated_at = now()
    where id = c.id;

    insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,reason)
    values(c.id,actor,'on_hold','not_yet','reprocess',
      left(btrim(coalesce(p_reason,'Revisi nominal lewat Reprocessing Doc')),300));

    insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
    values(actor,c.depot_id,'reprocessing_upload',c.id,jsonb_build_object(
      'noDoc',c.no_doc,'cbNetLama',c.cb_net,'cbNetBaru',v_baru));

    n_ok := n_ok + 1;
  end loop;

  return jsonb_build_object('status','success','berhasil',n_ok,
    'gagal',gagal,'jumlahGagal',jsonb_array_length(gagal),
    'message',n_ok||' dokumen kembali ke Not Yet'
      ||case when jsonb_array_length(gagal) > 0
             then ', '||jsonb_array_length(gagal)||' ditolak' else '' end);
end $function$
;

-- Keep an auditable snapshot of only the fields corrected by this migration.
create table if not exists rc_private.approval_status_repair_20261150 (
 claim_id uuid primary key, old_values jsonb not null, pending_request jsonb not null,
 restored_status text not null, repaired_at timestamptz not null default now()
);
revoke all on rc_private.approval_status_repair_20261150 from public,anon,authenticated;

insert into rc_private.approval_status_repair_20261150(claim_id,old_values,pending_request,restored_status)
select c.id,jsonb_build_object('status',c.status,'previous_status',c.previous_status,
 'batch_clearing',c.batch_clearing,'version_no',c.version_no,'updated_at',c.updated_at),
 jsonb_build_object('kind',case when c.status='submitted' then 'submit' when c.status='on_hold' then 'hold' else 'expire' end,
   'target_status',case when c.status='submitted' then 'approved' else c.status end,
   'requested_by',coalesce(h.actor_id,c.submitted_by),'requested_at',coalesce(h.created_at,c.uploaded_at,c.updated_at),
   'reason',coalesce(h.reason,''),'so_start',c.extend_so_start,'so_end',c.extend_so_end,
   'billing_start',c.extend_billing_start,'billing_end',c.extend_billing_end),
 'not_yet'
from public.claims c
left join lateral (select h.* from public.claim_status_history h where h.claim_id=c.id
 order by h.created_at desc,h.id desc limit 1) h on true
where c.pending_approval is null and c.archived_at is null and (
 (c.status='submitted' and c.approved_at is null)
 or (c.status in('on_hold','expired') and c.hold_approved_at is null
   and coalesce(nullif(btrim(h.from_status),''),'not_yet')='not_yet'
   and h.to_status=c.status
   and (h.action in('hold','expired') or (h.action='expire' and h.reason='Posting Exception: Expired via modul Upload')))
)
on conflict (claim_id) do nothing;

with repaired as (
 update public.claims c set status=b.restored_status,pending_approval=b.pending_request,
 previous_status=null,
 batch_clearing=case when b.old_values->>'status'='expired' then null else c.batch_clearing end,
 version_no=c.version_no+1,updated_at=now()
 from rc_private.approval_status_repair_20261150 b
 where c.id=b.claim_id and c.version_no=(b.old_values->>'version_no')::bigint
   and c.status=b.old_values->>'status' and c.pending_approval is null
 returning c.id,c.depot_id,c.status,b.old_values
), history as (
 insert into public.claim_status_history(claim_id,from_status,to_status,action,reason)
 select id,old_values->>'status',status,'repair_pending_approval',
   'Koreksi: pengajuan Upload menunggu approval; status efektif belum berubah.' from repaired
)
insert into public.activity_logs(depot_id,event_type,entity_id,details)
select depot_id,'repair_pending_approval',id,
 jsonb_build_object('from',old_values->>'status','to',status,'migration','20261150010000') from repaired;

notify pgrst, 'reload schema';

CREATE OR REPLACE FUNCTION public.rc_reprocessing_list(p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb; jml bigint; v_cari text;
begin
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
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_workflow_diagnostic()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare me public.profiles%rowtype; terlihat jsonb; semua jsonb; sebab text;
 n_depot integer; n_total_depot integer; n_claim_total bigint;
begin
 select * into me from public.profiles where id=(select auth.uid());
 if not found then raise exception 'Access denied' using errcode='42501'; end if;

 -- Yang terlihat oleh akun ini, memakai aturan akses yang sama dengan layar.
 select jsonb_build_object(
   'open',count(*) filter (where c.status='not_yet'),
   'release',count(*) filter (where c.status='approved' and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'),
   'claim',count(*) filter (where c.status='released' and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'),
   'clearing',count(*) filter (where c.status='claimed' and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'),
   'bulk',count(*) filter (where c.status in('approved','released','claimed') and lower(btrim(coalesce(ca.cashback_type,'')))='rebate'))
 into terlihat
 from public.claims c join public.campaigns ca on ca.id=c.campaign_id
 where c.archived_at is null and c.pending_approval is null and rc_private.can_access(c.depot_id);

 -- Yang benar-benar ada di database, mengabaikan akses.
 select jsonb_build_object(
   'open',count(*) filter (where c.status='not_yet'),
   'release',count(*) filter (where c.status='approved' and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'),
   'claim',count(*) filter (where c.status='released' and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'),
   'clearing',count(*) filter (where c.status='claimed' and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'),
   'bulk',count(*) filter (where c.status in('approved','released','claimed') and lower(btrim(coalesce(ca.cashback_type,'')))='rebate'))
 into semua
 from public.claims c join public.campaigns ca on ca.id=c.campaign_id
 where c.archived_at is null and c.pending_approval is null;

 select count(*) into n_depot from public.user_depot_access where user_id=me.id;
 select count(*) into n_total_depot from public.depots;
 select count(*) into n_claim_total from public.claims;

 sebab:=case
   when n_claim_total=0
     then 'Tabel claims kosong. Data klaim belum pernah diimpor ke project ini.'
   when (semua->>'release')::int=0 and (semua->>'claim')::int=0
        and (semua->>'clearing')::int=0 and (semua->>'bulk')::int=0
     then 'Tidak ada satu pun claim berstatus Approved, Released atau Claimed. Modul memang kosong, bukan tersembunyi.'
   when (terlihat->>'release')::int=0 and (semua->>'release')::int>0
     then 'Data ada tetapi tidak terlihat oleh akun ini. Scope depot atau peran belum mencukupi.'
   when me.role<>'system manager' and n_depot=0
     then 'Akun ini tidak memiliki satu pun depot, sehingga seluruh layar akan kosong.'
   else 'Jumlah yang terlihat sama dengan yang ada. Bila layar tetap kosong, periksa filter di layar atau muat ulang sesi.'
 end;

 return jsonb_build_object('status','success',
   'peran',me.role,'statusAkun',me.status,
   'depotDimiliki',n_depot,'totalDepot',n_total_depot,
   'totalClaim',n_claim_total,
   'terlihat',terlihat,'seluruhnya',semua,'sebab',sebab);
end $function$
;
