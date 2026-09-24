-- ==========================================================================================
-- Voucher diperlakukan sebagai Transfer di jalur pemrosesan claim
-- ==========================================================================================
-- Keputusan pemilik: jenis "Voucher" pada Campaign Master tidak dihapus, dan dihitung sebagai
-- Transfer. Konsekuensinya nyata dan memang diinginkan - dokumen Voucher kini menuntut Nomor
-- Rekening, Nama Rekening dan Bank persis seperti Transfer, dan mengikuti alur bertahap yang
-- sama.
--
-- Penyeragamannya memakai rc_private.jenis_efektif yang dipasang di 20261007010000, sehingga
-- aturan ini hanya ada di satu tempat dan tidak bisa menyimpang antar fungsi.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

CREATE OR REPLACE FUNCTION rc_private.mutate_claims_unchecked(p_action text, p_items jsonb, p_request_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid(); perm text; v_payload jsonb; cached rc_private.requests%rowtype;
 c public.claims%rowtype; item jsonb; target text; batch text; stage text; subject text;
 processed jsonb:='[]'; stamp timestamptz:=now();
 cust public.customers%rowtype; camp public.campaigns%rowtype; jenis text; v_jenis_input text;
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
 -- Expired kini ikut memperoleh nomor batch, dan nomornya diterbitkan pada tahap Clearing
 -- sesuai permintaan pemilik: dokumen yang di-Expired harus tetap terlihat nomor batch-nya,
 -- dan tempatnya di kolom Clearing.
 stage:=case p_action when 'submit' then '01' when 'release' then '02' when 'claim' then '03'
   when 'clearing' then '04' when 'expire' then '04' when 'bulk_rebate' then '02' end;

 for item in select value from jsonb_array_elements(p_items) order by value->>'no_doc' loop
 select * into c from public.claims where no_doc=item->>'no_doc' for update;
 if not found then raise exception 'Document not found'; end if;
 if c.archived_at is not null then raise exception 'Dokumen % sudah diarsipkan',c.no_doc; end if;
 if not rc_private.can_access(c.depot_id,perm) then raise exception 'Depot access denied' using errcode='42501'; end if;
 if c.version_no<>(item->>'version_no')::bigint then raise exception 'Document changed; refresh first' using errcode='40001'; end if;
 select * into camp from public.campaigns where id=c.campaign_id;
 -- Jenis CB berasal dari Campaign Master, tetapi pengguna boleh menimpanya per dokumen.
 -- Nilai yang dikirim layar harus persis salah satu dari daftar resmi; salah ketik ditolak
 -- di sini juga, bukan hanya di browser, supaya pemanggil lain tidak bisa melewatinya.
 v_jenis_input:=btrim(coalesce(item->>'jenis_cashback',''));
 if v_jenis_input<>'' then
  if v_jenis_input not in('Transfer','CN','Rebate','RA07','RA7') then
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
 -- RA07 dan RA7 tidak melewati antrean mana pun: pemilik menetapkan keduanya langsung
 -- selesai begitu diunggah, sehingga tidak ada yang perlu me-release atau meng-clearing.
 if p_action='submit' and c.status='not_yet' and jenis in('ra07','ra7') then target:='done';
 elsif p_action='submit' and c.status='not_yet' then target:='submitted';
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
 batch_clearing=case when p_action in('clearing','bulk_rebate','expire') then batch
   when p_action='submit' and target='done' then batch else batch_clearing end,
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
end $function$;


create or replace function rc_private.marker_20261008() returns boolean
language sql immutable set search_path='' as $marker$select true$marker$;
revoke all on function rc_private.marker_20261008() from public,anon;
grant execute on function rc_private.marker_20261008() to authenticated;

select 'Voucher dihitung sebagai Transfer' as hasil,
 rc_private.jenis_efektif('Voucher') as voucher_menjadi,
 (select count(*) from public.campaigns where cashback_type='Voucher') as campaign_voucher;
