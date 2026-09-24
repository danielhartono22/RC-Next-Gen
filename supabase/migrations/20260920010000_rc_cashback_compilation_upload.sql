-- PENDING: belum diterapkan.
--
-- Cashback Compilation: membuat baris cashback baru dari Excel, mengikuti pola Print
-- Document (pencarian terarah, batas baris tegas, hasil terpaginate), dan hasilnya langsung
-- terlihat di modul Analytics karena keduanya membaca tabel claims yang sama.
--
-- Format No Document ditetapkan pemilik 17 September 2026:
--   NPC/CMP/<abbr depot>/<kode campaign, maksimal 6 karakter dari belakang>/<no urut>
--   contoh: NPC/CMP/MDN/CA3222/25029
-- Abbr diambil dari kolom "Abbr" pada Excel, dengan kode depot sebagai kunci referensi.
-- No urut minimal empat angka, tidak boleh terulang.
--
-- Jenis CB "RA07" atau "RA7" berarti cashback itu sudah direalisasi di luar sistem, jadi
-- barisnya langsung berstatus Done. Nilainya bukan jenis cashback dan tidak pernah ditulis
-- ke Campaign Master.

------------------------------------------------------------------------------------------
-- 1. Abbr depot
------------------------------------------------------------------------------------------
-- Abbr dibawa oleh file upload, tetapi disimpan juga di master depot supaya nomor dokumen
-- satu depot tidak berubah-ubah hanya karena file berikutnya mengetiknya berbeda.
alter table public.depots add column if not exists abbr text;
create unique index if not exists depots_abbr_idx on public.depots(abbr) where abbr is not null;

------------------------------------------------------------------------------------------
-- 2. Penerbitan No Document
------------------------------------------------------------------------------------------
create table if not exists rc_private.document_counters(
 abbr text primary key,
 counter integer not null check(counter between 1 and 999999)
);
alter table rc_private.document_counters enable row level security;
revoke all on rc_private.document_counters from public,anon,authenticated;
grant all on rc_private.document_counters to service_role;

-- Nomor tidak pernah dipakai ulang. Penghitung naik lalu hasilnya diperiksa terhadap seluruh
-- dokumen yang ada; kalau ternyata sudah terpakai, penghitung naik lagi. Dengan begitu data
-- historis yang memakai penomoran lama tidak akan pernah bertabrakan dengan yang baru.
create or replace function rc_private.next_document(p_abbr text,p_campaign_code text) returns text
language plpgsql security definer set search_path='' as $$
declare a text; seg text; n integer; doc text; putaran integer:=0;
begin
 a:=upper(btrim(coalesce(p_abbr,'')));
 if a='' or a !~ '^[A-Z0-9]{2,10}$' then
  raise exception 'Abbr depot "%" tidak valid; gunakan 2-10 huruf atau angka',p_abbr; end if;
 seg:=upper(btrim(coalesce(p_campaign_code,'')));
 if seg='' then raise exception 'Kode campaign wajib diisi untuk membentuk No Document'; end if;
 -- Maksimal enam karakter dari belakang, sesuai ketentuan pemilik.
 seg:=right(seg,6);

 loop
  putaran:=putaran+1;
  if putaran>1000 then raise exception 'Tidak dapat menerbitkan No Document unik untuk %',a; end if;
  insert into rc_private.document_counters values(a,1)
  on conflict(abbr) do update set counter=rc_private.document_counters.counter+1
  returning counter into n;
  doc:='NPC/CMP/'||a||'/'||seg||'/'||lpad(n::text,4,'0');
  exit when not exists(select 1 from public.claims where no_doc=doc);
 end loop;
 return doc;
end $$;
revoke all on function rc_private.next_document(text,text) from public,anon,authenticated;

------------------------------------------------------------------------------------------
-- 3. Compile upload
------------------------------------------------------------------------------------------
-- Satu transaksi. Seluruh file diterima atau seluruhnya dibatalkan, sehingga tidak pernah
-- ada kompilasi setengah jadi yang membuat total Analytics salah.
--
-- Kunci duplikat mengikuti sistem lama: kode campaign + kode pelanggan. Baris yang sudah ada
-- dilaporkan sebagai duplikat, bukan digandakan dan bukan menimpa nilai yang sudah berjalan
-- dalam workflow.
create or replace function rc_private.compile_upload(p_rows jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
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

  select * into v_depot from public.depots where depot_code=btrim(coalesce(r->>'kodeDepot',''));
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Kode depot "'||coalesce(r->>'kodeDepot','')||'" tidak ada di master depot'));
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

  select * into v_camp from public.campaigns where campaign_code=v_code;
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Campaign "'||v_code||'" belum ada di Campaign Master'));
   continue; end if;

  select * into v_cust from public.customers where customer_code=v_custcode;
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Customer "'||v_custcode||'" belum ada di Customer Master'));
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
  v_status:=case when v_jenis in('RA07','RA7') then 'done' else 'not_yet' end;

  v_subject:=v_cust.tax_subject;
  v_gross:=case when v_status='done' and v_subject is not null
                then public.rc_gross_up_legacy(v_cb,v_subject) else null end;

  v_doc:=rc_private.next_document(v_abbr,v_code);

  insert into public.claims(no_doc,campaign_id,customer_id,depot_id,status,legacy_status,
    net_value,volume,cb_net,gross_up,tax_subject,
    uploaded_at,cleared_at,batch_clearing,version_no)
  values(v_doc,v_camp.id,v_cust.id,v_depot.id,v_status,
    case when v_status='done' then v_jenis else null end,
    v_net,v_vol,v_cb,v_gross,case when v_status='done' then v_subject else null end,
    case when v_status='done' then now() else null end,
    case when v_status='done' then now() else null end,
    case when v_status='done' then batch else null end,1);

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
end $$;
create or replace function public.rc_compile_upload(p_rows jsonb,p_request_id uuid) returns jsonb
language sql security invoker set search_path='' as $$select rc_private.compile_upload(p_rows,p_request_id);$$;
revoke all on function rc_private.compile_upload(jsonb,uuid),public.rc_compile_upload(jsonb,uuid) from public,anon;
grant execute on function rc_private.compile_upload(jsonb,uuid),public.rc_compile_upload(jsonb,uuid) to authenticated;

-- Pratinjau tanpa menulis apa pun, supaya pengguna melihat penolakan sebelum berkomitmen.
create or replace function public.rc_compile_preview(p_rows jsonb) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare r jsonb; baris integer:=0; siap integer:=0; duplikat jsonb:='[]'; ditolak jsonb:='[]';
 terlihat jsonb:='{}'; kunci text; v_code text; v_custcode text;
 v_depot public.depots%rowtype; v_camp public.campaigns%rowtype; v_cust public.customers%rowtype;
begin
 if not rc_private.can_access(null,'view_compilation') then
  raise exception 'Access denied' using errcode='42501'; end if;
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
end $$;
revoke all on function public.rc_compile_preview(jsonb) from public,anon;
grant execute on function public.rc_compile_preview(jsonb) to authenticated;
