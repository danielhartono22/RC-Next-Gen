-- PENDING: belum diterapkan.
--
-- Key Master (Customer Master + Campaign Master) dan Cashback Compilation.
--
-- Keputusan pemilik, 17 September 2026:
--  * Master pelanggan menjadi sumber kebenaran. Upload klaim tidak lagi menimpanya.
--  * Klaim yang sudah diproses tetap memakai data master lama; nilainya sudah tersimpan
--    sebagai snapshot pada rc_private.claim_sensitive dan tidak disentuh migration ini.
--  * Mass upload master bulanan memakai aturan "data baru menang" pada kode yang sama.
--  * Penghapusan cashback adalah pengarsipan, bukan penghapusan permanen.

------------------------------------------------------------------------------------------
-- 1. Customer Master
------------------------------------------------------------------------------------------
alter table public.customers add column top_text text;
alter table public.customers add column ktp text;
alter table public.customers add column npwp text;
alter table public.customers add column bank text;
alter table public.customers add column account_number text;
alter table public.customers add column account_name text;
alter table public.customers add column contact_person text;
alter table public.customers add column updated_at timestamptz not null default now();
alter table public.customers add column updated_by uuid references public.profiles(id);

-- Subyek pajak tidak pernah diketik. NPWP ada berarti Badan; hanya KTP berarti Perorangan.
-- Dijadikan generated column supaya tidak mungkin menyimpang dari KTP/NPWP yang tersimpan.
alter table public.customers add column tax_subject text
 generated always as (
   case when nullif(btrim(coalesce(npwp,'')),'') is not null then 'Badan'
        when nullif(btrim(coalesce(ktp,'')),'') is not null then 'Perorangan'
        else null end) stored;

create index customers_name_idx on public.customers using gin (to_tsvector('simple',customer_name));

-- Isi master dari snapshot klaim terakhir per pelanggan, supaya layar Customer Master tidak
-- mulai kosong. Ini memindahkan data yang sudah ada, bukan menciptakan data baru.
with terbaru as (
 select distinct on (c.customer_id) c.customer_id,s.ktp,s.npwp,s.bank,s.account_number,
   s.account_name,s.top_text
 from public.claims c
 join rc_private.claim_sensitive s on s.claim_id=c.id
 order by c.customer_id,c.updated_at desc
)
update public.customers cu set
 ktp=nullif(btrim(coalesce(t.ktp,'')),''),
 npwp=nullif(btrim(coalesce(t.npwp,'')),''),
 bank=nullif(btrim(coalesce(t.bank,'')),''),
 account_number=nullif(btrim(coalesce(t.account_number,'')),''),
 account_name=nullif(btrim(coalesce(t.account_name,'')),''),
 top_text=nullif(btrim(coalesce(t.top_text,'')),'')
from terbaru t where t.customer_id=cu.id;

------------------------------------------------------------------------------------------
-- 2. Permission baru
------------------------------------------------------------------------------------------
insert into public.permissions(code,description) values
 ('manage_key_master','Kelola Customer Master dan Campaign Master'),
 ('view_compilation','Lihat Cashback Compilation'),
 ('archive_compilation','Arsipkan baris cashback');

-- System Manager yang sudah aktif langsung memperoleh permission baru ini, supaya modulnya
-- tidak tersembunyi sesudah migration.
insert into public.user_permissions(user_id,permission_code)
select p.id,x from public.profiles p
cross join unnest(array['manage_key_master','view_compilation','archive_compilation']) x
where p.role='system manager' and p.status='active'
on conflict do nothing;

------------------------------------------------------------------------------------------
-- 3. Arsip cashback, bukan penghapusan
------------------------------------------------------------------------------------------
-- Baris yang diarsipkan hilang dari seluruh layar dan laporan, tetapi tetap dapat ditelusuri
-- dan dikembalikan. Larangan "jangan menghapus data invalid" pada system instruction tetap
-- dipenuhi.
alter table public.claims add column archived_at timestamptz;
alter table public.claims add column archived_by uuid references public.profiles(id);
alter table public.claims add column archive_reason text;
create index claims_archived_idx on public.claims(archived_at) where archived_at is not null;

-- Setiap pembacaan yang sudah ada harus mengabaikan baris terarsip. RLS adalah tempat yang
-- tepat: satu perubahan policy menutup seluruh jalur baca sekaligus.
alter policy claims_scope on public.claims
 using(archived_at is null and rc_private.can_access(depot_id));

------------------------------------------------------------------------------------------
-- 4. Pembacaan master
------------------------------------------------------------------------------------------
create function public.rc_customer_list(p_search text default '',p_offset integer default 0,
 p_limit integer default 50)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 select coalesce(jsonb_agg(x order by x->>'custCode'),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'id',cu.id,'custCode',cu.customer_code,'custName',cu.customer_name,
   'top',coalesce(cu.top_text,''),'ktp',coalesce(cu.ktp,''),'npwp',coalesce(cu.npwp,''),
   'subyekPajak',coalesce(cu.tax_subject,''),
   'namaRek',coalesce(cu.account_name,''),'noRek',coalesce(cu.account_number,''),
   'bank',coalesce(cu.bank,''),'contactPerson',coalesce(cu.contact_person,''),
   'depotCodes',array(select d.depot_code from public.customer_depots cd
     join public.depots d on d.id=cd.depot_id where cd.customer_id=cu.id order by d.depot_code)) as x
  from public.customers cu
  where (coalesce(btrim(p_search),'')=''
     or cu.customer_code ilike '%'||btrim(p_search)||'%'
     or cu.customer_name ilike '%'||btrim(p_search)||'%')
  order by cu.customer_code
  limit least(greatest(coalesce(p_limit,50),1),200) offset greatest(coalesce(p_offset,0),0)) t;
 return jsonb_build_object('status','success','rows',v,
  'total',(select count(*) from public.customers));
end $$;
revoke all on function public.rc_customer_list(text,integer,integer) from public,anon;
grant execute on function public.rc_customer_list(text,integer,integer) to authenticated;

create function public.rc_campaign_list(p_search text default '',p_offset integer default 0,
 p_limit integer default 50)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 select coalesce(jsonb_agg(x order by x->>'codeCampaign'),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'id',ca.id,'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'periodStart',coalesce(ca.period_start_text,''),'periodEnd',coalesce(ca.period_end_text,''),
   'jenisCb',coalesce(ca.cashback_type,''),'statusPajak',coalesce(ca.tax_status,''),
   'jumlahClaim',(select count(*) from public.claims c where c.campaign_id=ca.id and c.archived_at is null)) as x
  from public.campaigns ca
  where (coalesce(btrim(p_search),'')=''
     or ca.campaign_code ilike '%'||btrim(p_search)||'%'
     or ca.campaign_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code
  limit least(greatest(coalesce(p_limit,50),1),200) offset greatest(coalesce(p_offset,0),0)) t;
 return jsonb_build_object('status','success','rows',v,
  'total',(select count(*) from public.campaigns));
end $$;
revoke all on function public.rc_campaign_list(text,integer,integer) from public,anon;
grant execute on function public.rc_campaign_list(text,integer,integer) to authenticated;

-- Campaign harus dapat dibaca untuk daftar master, bukan hanya campaign yang punya klaim.
alter policy campaigns_scope on public.campaigns
 using(rc_private.can_access(null));

------------------------------------------------------------------------------------------
-- 5. Penulisan master
------------------------------------------------------------------------------------------
-- Satu fungsi melayani perubahan manual satu baris maupun mass upload bulanan: keduanya
-- mengirim array baris. Aturan pemilik: pada kode yang sama, data baru menjadi sumber
-- kebenaran, jadi ini upsert yang menimpa, bukan merge yang mempertahankan nilai lama.
--
-- Field yang tidak dikirim sama sekali tidak diubah. Field yang dikirim kosong berarti
-- dikosongkan, karena itulah cara menghapus nilai yang salah lewat template Excel.
create function rc_private.customer_upsert(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r jsonb; code text; k text; dibuat integer:=0; diperbarui integer:=0; hasil jsonb:='[]';
 sudah boolean;
begin
 if not rc_private.can_access(null,'manage_key_master') then
  raise exception 'Access denied' using errcode='42501'; end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array' then raise exception 'Data harus berupa array'; end if;
 if jsonb_array_length(p_rows) not between 1 and 2000 then raise exception 'Satu unggahan maksimal 2000 baris'; end if;
 if octet_length(p_rows::text)>4194304 then raise exception 'Payload melebihi 4 MiB'; end if;

 for r in select value from jsonb_array_elements(p_rows) loop
  if jsonb_typeof(r)<>'object' then raise exception 'Setiap baris harus berupa objek'; end if;
  for k in select key from jsonb_each(r) loop
   if k not in('custCode','custName','top','ktp','npwp','namaRek','noRek','bank','contactPerson')
   then raise exception 'Kolom tidak dikenali: %',k; end if;
   if jsonb_typeof(r->k)<>'string' or length(r->>k)>200 then
    raise exception 'Nilai kolom % harus teks maksimal 200 karakter',k; end if;
  end loop;
  code:=upper(btrim(coalesce(r->>'custCode','')));
  if code='' then raise exception 'Customer Code wajib diisi pada setiap baris'; end if;
  if btrim(coalesce(r->>'custName',''))='' and not exists(
     select 1 from public.customers where customer_code=code) then
   raise exception 'Nama pelanggan wajib diisi untuk kode baru: %',code; end if;

  select exists(select 1 from public.customers where customer_code=code) into sudah;
  if sudah then
   update public.customers set
    customer_name=case when r ? 'custName' and btrim(r->>'custName')<>'' then btrim(r->>'custName') else customer_name end,
    top_text=case when r ? 'top' then nullif(btrim(r->>'top'),'') else top_text end,
    ktp=case when r ? 'ktp' then nullif(btrim(r->>'ktp'),'') else ktp end,
    npwp=case when r ? 'npwp' then nullif(btrim(r->>'npwp'),'') else npwp end,
    account_name=case when r ? 'namaRek' then nullif(btrim(r->>'namaRek'),'') else account_name end,
    account_number=case when r ? 'noRek' then nullif(btrim(r->>'noRek'),'') else account_number end,
    bank=case when r ? 'bank' then nullif(btrim(r->>'bank'),'') else bank end,
    contact_person=case when r ? 'contactPerson' then nullif(btrim(r->>'contactPerson'),'') else contact_person end,
    updated_at=now(),updated_by=(select auth.uid())
   where customer_code=code;
   diperbarui:=diperbarui+1;
  else
   insert into public.customers(customer_code,customer_name,top_text,ktp,npwp,
     account_name,account_number,bank,contact_person,updated_by)
   values(code,btrim(r->>'custName'),nullif(btrim(coalesce(r->>'top','')),''),
     nullif(btrim(coalesce(r->>'ktp','')),''),nullif(btrim(coalesce(r->>'npwp','')),''),
     nullif(btrim(coalesce(r->>'namaRek','')),''),nullif(btrim(coalesce(r->>'noRek','')),''),
     nullif(btrim(coalesce(r->>'bank','')),''),nullif(btrim(coalesce(r->>'contactPerson','')),''),
     (select auth.uid()));
   dibuat:=dibuat+1;
  end if;
  hasil:=hasil||jsonb_build_array(code);
 end loop;

 insert into public.activity_logs(actor_id,event_type,details)
 values((select auth.uid()),'customer_master_upsert',
   jsonb_build_object('dibuat',dibuat,'diperbarui',diperbarui));
 return jsonb_build_object('status','success','dibuat',dibuat,'diperbarui',diperbarui,'kode',hasil);
end $$;
create function public.rc_customer_upsert(p_rows jsonb) returns jsonb
language sql security invoker set search_path='' as $$select rc_private.customer_upsert(p_rows);$$;
revoke all on function rc_private.customer_upsert(jsonb),public.rc_customer_upsert(jsonb) from public,anon;
grant execute on function rc_private.customer_upsert(jsonb),public.rc_customer_upsert(jsonb) to authenticated;

create function rc_private.campaign_upsert(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r jsonb; code text; k text; dibuat integer:=0; diperbarui integer:=0; sudah boolean;
begin
 if not rc_private.can_access(null,'manage_key_master') then
  raise exception 'Access denied' using errcode='42501'; end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array' then raise exception 'Data harus berupa array'; end if;
 if jsonb_array_length(p_rows) not between 1 and 2000 then raise exception 'Satu unggahan maksimal 2000 baris'; end if;

 for r in select value from jsonb_array_elements(p_rows) loop
  if jsonb_typeof(r)<>'object' then raise exception 'Setiap baris harus berupa objek'; end if;
  for k in select key from jsonb_each(r) loop
   if k not in('codeCampaign','campaignName','periodStart','periodEnd','jenisCb','statusPajak')
   then raise exception 'Kolom tidak dikenali: %',k; end if;
   if jsonb_typeof(r->k)<>'string' or length(r->>k)>200 then
    raise exception 'Nilai kolom % harus teks maksimal 200 karakter',k; end if;
  end loop;
  code:=upper(btrim(coalesce(r->>'codeCampaign','')));
  if code='' then raise exception 'Code Campaign wajib diisi pada setiap baris'; end if;
  -- Jenis CB menentukan syarat upload dan jalur Bulk Process, jadi nilainya dibatasi.
  if r ? 'jenisCb' and btrim(r->>'jenisCb')<>''
     and lower(btrim(r->>'jenisCb')) not in('transfer','cn','rebate')
  then raise exception 'Jenis CB harus Transfer, CN atau Rebate pada %',code; end if;

  select exists(select 1 from public.campaigns where campaign_code=code) into sudah;
  if sudah then
   update public.campaigns set
    campaign_name=case when r ? 'campaignName' and btrim(r->>'campaignName')<>'' then btrim(r->>'campaignName') else campaign_name end,
    period_start_text=case when r ? 'periodStart' then nullif(btrim(r->>'periodStart'),'') else period_start_text end,
    period_end_text=case when r ? 'periodEnd' then nullif(btrim(r->>'periodEnd'),'') else period_end_text end,
    cashback_type=case when r ? 'jenisCb' then nullif(btrim(r->>'jenisCb'),'') else cashback_type end,
    tax_status=case when r ? 'statusPajak' then nullif(btrim(r->>'statusPajak'),'') else tax_status end
   where campaign_code=code;
   diperbarui:=diperbarui+1;
  else
   if btrim(coalesce(r->>'campaignName',''))='' then
    raise exception 'Nama campaign wajib diisi untuk kode baru: %',code; end if;
   insert into public.campaigns(campaign_code,campaign_name,period_start_text,period_end_text,
     cashback_type,tax_status)
   values(code,btrim(r->>'campaignName'),nullif(btrim(coalesce(r->>'periodStart','')),''),
     nullif(btrim(coalesce(r->>'periodEnd','')),''),nullif(btrim(coalesce(r->>'jenisCb','')),''),
     nullif(btrim(coalesce(r->>'statusPajak','')),''));
   dibuat:=dibuat+1;
  end if;
 end loop;

 insert into public.activity_logs(actor_id,event_type,details)
 values((select auth.uid()),'campaign_master_upsert',
   jsonb_build_object('dibuat',dibuat,'diperbarui',diperbarui));
 return jsonb_build_object('status','success','dibuat',dibuat,'diperbarui',diperbarui);
end $$;
create function public.rc_campaign_upsert(p_rows jsonb) returns jsonb
language sql security invoker set search_path='' as $$select rc_private.campaign_upsert(p_rows);$$;
revoke all on function rc_private.campaign_upsert(jsonb),public.rc_campaign_upsert(jsonb) from public,anon;
grant execute on function rc_private.campaign_upsert(jsonb),public.rc_campaign_upsert(jsonb) to authenticated;

------------------------------------------------------------------------------------------
-- 6. Cashback Compilation
------------------------------------------------------------------------------------------
-- Mengikuti pola Print Document: pencarian terarah, batas baris tegas, hasil terpaginate.
create function public.rc_compilation_list(p_campaign text default '',p_batch text default '',
 p_status text default '',p_search text default '',p_offset integer default 0,p_limit integer default 100)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v jsonb; jml bigint;
begin
 if not rc_private.can_access(null,'view_compilation') then
  raise exception 'Access denied' using errcode='42501'; end if;

 select count(*) into jml from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  where (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_status),'')='' or c.status=btrim(p_status))
    and (coalesce(btrim(p_batch),'')='' or btrim(p_batch) in
         (c.batch_upload,c.batch_release,c.batch_claim,c.batch_clearing));
 -- Batas bisnis Print Document dipertahankan: 2000 baris untuk satu penarikan.
 if jml>2000 and coalesce(btrim(p_campaign),'')='' and coalesce(btrim(p_batch),'')='' then
  raise exception 'Hasil % baris melebihi batas 2000. Persempit dengan campaign atau batch.',jml;
 end if;

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
revoke all on function public.rc_compilation_list(text,text,text,text,integer,integer) from public,anon;
grant execute on function public.rc_compilation_list(text,text,text,text,integer,integer) to authenticated;

-- Pengarsipan. Bukan DELETE: baris tetap ada, hilang dari seluruh pembacaan lewat RLS, dan
-- dapat dikembalikan. Hanya System Manager, dan alasan wajib diisi.
create function rc_private.archive_claims(p_ids uuid[],p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare jml integer;
begin
 if not rc_private.is_manager() then raise exception 'Hanya System Manager yang dapat mengarsipkan' using errcode='42501'; end if;
 if p_ids is null or array_length(p_ids,1) is null then raise exception 'Pilih baris terlebih dahulu'; end if;
 if array_length(p_ids,1)>500 then raise exception 'Satu proses maksimal 500 baris'; end if;
 if btrim(coalesce(p_reason,''))='' then raise exception 'Alasan pengarsipan wajib diisi'; end if;
 if length(p_reason)>1000 then raise exception 'Alasan terlalu panjang'; end if;

 -- Depot di luar scope tidak boleh ikut terarsip walaupun id-nya ditebak.
 if exists(select 1 from public.claims where id=any(p_ids) and not rc_private.can_access(depot_id)) then
  raise exception 'Ada baris di luar akses depot Anda' using errcode='42501'; end if;

 update public.claims set archived_at=now(),archived_by=(select auth.uid()),
   archive_reason=btrim(p_reason),updated_at=now(),version_no=version_no+1
 where id=any(p_ids) and archived_at is null;
 get diagnostics jml=row_count;

 insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,reason)
 select id,(select auth.uid()),status,status,'archive',btrim(p_reason)
 from public.claims where id=any(p_ids) and archived_at is not null;

 insert into public.activity_logs(actor_id,event_type,details)
 values((select auth.uid()),'compilation_archived',
   jsonb_build_object('jumlah',jml,'alasan',btrim(p_reason)));
 return jsonb_build_object('status','success','jumlah',jml);
end $$;
create function public.rc_archive_compilation(p_ids uuid[],p_reason text) returns jsonb
language sql security invoker set search_path='' as $$select rc_private.archive_claims(p_ids,p_reason);$$;
revoke all on function rc_private.archive_claims(uuid[],text),public.rc_archive_compilation(uuid[],text) from public,anon;
grant execute on function rc_private.archive_claims(uuid[],text),public.rc_archive_compilation(uuid[],text) to authenticated;

-- Mengembalikan baris yang terlanjur diarsipkan. Tanpa ini, "arsip bukan hapus" hanya janji.
create function rc_private.unarchive_claims(p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path='' as $$
declare jml integer;
begin
 if not rc_private.is_manager() then raise exception 'Hanya System Manager yang dapat mengembalikan arsip' using errcode='42501'; end if;
 if p_ids is null or array_length(p_ids,1) is null then raise exception 'Pilih baris terlebih dahulu'; end if;
 update public.claims set archived_at=null,archived_by=null,archive_reason=null,
   updated_at=now(),version_no=version_no+1
 where id=any(p_ids) and archived_at is not null;
 get diagnostics jml=row_count;
 insert into public.activity_logs(actor_id,event_type,details)
 values((select auth.uid()),'compilation_unarchived',jsonb_build_object('jumlah',jml));
 return jsonb_build_object('status','success','jumlah',jml);
end $$;
create function public.rc_unarchive_compilation(p_ids uuid[]) returns jsonb
language sql security invoker set search_path='' as $$select rc_private.unarchive_claims(p_ids);$$;
revoke all on function rc_private.unarchive_claims(uuid[]),public.rc_unarchive_compilation(uuid[]) from public,anon;
grant execute on function rc_private.unarchive_claims(uuid[]),public.rc_unarchive_compilation(uuid[]) to authenticated;

-- Daftar arsip, supaya pengembalian bisa dilakukan tanpa membuka SQL Editor.
create function public.rc_archived_list(p_offset integer default 0,p_limit integer default 100)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v jsonb;
begin
 if not rc_private.is_manager() then raise exception 'Hanya System Manager' using errcode='42501'; end if;
 select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
  select jsonb_build_object('id',c.id,'noDoc',c.no_doc,'kodeToko',cu.customer_code,
   'codeCampaign',ca.campaign_code,'cbNet',c.cb_net,
   'alasan',coalesce(c.archive_reason,''),'olehUser',coalesce(p.user_code,''),
   'waktu',rc_private.legacy_ts(c.archived_at)) as x
  from public.claims c
  join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  left join public.profiles p on p.id=c.archived_by
  where c.archived_at is not null
  order by c.archived_at desc
  limit least(greatest(coalesce(p_limit,100),1),500) offset greatest(coalesce(p_offset,0),0)) t;
 return jsonb_build_object('status','success','rows',v);
end $$;
revoke all on function public.rc_archived_list(integer,integer) from public,anon;
grant execute on function public.rc_archived_list(integer,integer) to authenticated;

------------------------------------------------------------------------------------------
-- 7. Upload klaim membaca master, tidak lagi menimpanya
------------------------------------------------------------------------------------------
-- Perubahan perilaku yang disetujui pemilik. Klaim yang sudah diproses tidak disentuh:
-- snapshot lamanya tetap pada rc_private.claim_sensitive. Untuk submit baru, field yang
-- tidak dikirim diambil dari master, dan syarat kelengkapan diperiksa menurut Jenis CB.
create or replace function rc_private.mutate_claims_unchecked(p_action text,p_items jsonb,p_request_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); perm text; v_payload jsonb; cached rc_private.requests%rowtype;
 c public.claims%rowtype; item jsonb; target text; batch text; stage text; subject text;
 processed jsonb:='[]'; stamp timestamptz:=now();
 cust public.customers%rowtype; camp public.campaigns%rowtype; jenis text;
 v_ktp text; v_npwp text; v_bank text; v_norek text; v_namarek text; v_top text; v_gross numeric;
begin
 if p_action not in('submit','release','claim','clearing','reject_release','reject_claim','reject_clearing','hold','unhold','expire','bulk_rebate')
 or p_action is null then raise exception 'Unknown action'; end if;
 perm:=case when p_action in('submit','hold','unhold','expire') then 'upload_claim'
 when p_action in('release','reject_release') then 'release_claim'
 when p_action='bulk_rebate' then 'bulk_process' else 'process_claim' end;
 if not rc_private.can_access(null,perm) then raise exception 'Access denied' using errcode='42501'; end if;
 if p_request_id is null or p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Invalid request'; end if;
 if jsonb_array_length(p_items) not between 1 and 100 then raise exception 'Select 1-100 claims'; end if;
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
  if not exists(select 1 from public.campaigns where id=c.campaign_id and lower(btrim(cashback_type))='rebate') then raise exception 'Campaign is not rebate'; end if;
  target:='done';
 end if;
 if target is null then raise exception 'Invalid status transition for %',c.no_doc; end if;
 if stage is not null and batch is null then batch:=rc_private.next_batch(stage); end if;
 if p_action='submit' then
  select * into cust from public.customers where id=c.customer_id;
  select * into camp from public.campaigns where id=c.campaign_id;
  jenis:=lower(btrim(coalesce(camp.cashback_type,'')));

  -- Master adalah sumber kebenaran; isian pengguna hanya dipakai bila master kosong.
  v_ktp   :=coalesce(nullif(btrim(coalesce(cust.ktp,'')),''),nullif(btrim(coalesce(item->>'ktp','')),''));
  v_npwp  :=coalesce(nullif(btrim(coalesce(cust.npwp,'')),''),nullif(btrim(coalesce(item->>'npwp','')),''));
  v_bank  :=coalesce(nullif(btrim(coalesce(cust.bank,'')),''),nullif(btrim(coalesce(item->>'bank','')),''));
  v_norek :=coalesce(nullif(btrim(coalesce(cust.account_number,'')),''),nullif(btrim(coalesce(item->>'account_number','')),''));
  v_namarek:=coalesce(nullif(btrim(coalesce(cust.account_name,'')),''),nullif(btrim(coalesce(item->>'account_name','')),''));
  v_top   :=coalesce(nullif(btrim(coalesce(item->>'top','')),''),nullif(btrim(coalesce(cust.top_text,'')),''));

  -- Subyek pajak ditentukan dokumen identitas, bukan pilihan pengguna.
  subject:=case when v_npwp is not null then 'Badan'
                when v_ktp is not null then 'Perorangan'
                else nullif(btrim(coalesce(item->>'tax_subject',c.tax_subject,'')),'') end;
  if subject is null then
   raise exception 'Dokumen %: KTP atau NPWP pelanggan % belum terisi di Customer Master',c.no_doc,cust.customer_code;
  end if;
  if v_ktp is not null and v_npwp is not null then
   raise exception 'Dokumen %: pelanggan % punya KTP dan NPWP sekaligus; perbaiki di Customer Master',c.no_doc,cust.customer_code;
  end if;

  -- Syarat kelengkapan menurut Jenis CB.
  if jenis='transfer' and (v_norek is null or v_namarek is null or v_bank is null) then
   raise exception 'Dokumen %: Jenis CB Transfer memerlukan Nomor Rekening, Nama Rekening dan Bank pada pelanggan %',c.no_doc,cust.customer_code;
  end if;
  if jenis='' then
   raise exception 'Dokumen %: Jenis CB campaign % belum ditetapkan di Campaign Master',c.no_doc,camp.campaign_code;
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
 -- grossUp ikut dikembalikan supaya laporan hasil di layar menampilkan nilai sebenarnya,
 -- bukan nol seperti sebelumnya.
 processed:=processed||jsonb_build_array(jsonb_build_object('no_doc',c.no_doc,'status',target,
   'version_no',c.version_no+1,'gross_up',coalesce(v_gross,c.gross_up)));
 end loop;
 v_payload:=jsonb_build_object('processed',processed,'batch',batch,'count',jsonb_array_length(processed));
 update rc_private.requests set result=v_payload where actor_id=actor and request_id=p_request_id;
 return v_payload;
end $$;

------------------------------------------------------------------------------------------
-- 8. Flag modul baru untuk UI lama
------------------------------------------------------------------------------------------
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
  -- Modul baru memakai nama yang jelas, bukan huruf warisan.
  'keyMaster',case when x.p ? 'manage_key_master' then 'Yes' else 'No' end,
  'compilation',case when x.p ? 'view_compilation' then 'Yes' else 'No' end,
  'archiveCompilation',case when x.p ? 'archive_compilation' then 'Yes' else 'No' end)
 from (select coalesce(jsonb_object_agg(permission_code,true),'{}'::jsonb) as p
       from public.user_permissions where user_id=(select auth.uid())) x;
$$;

------------------------------------------------------------------------------------------
-- 9. Pendaftaran boleh meminta peran System Manager
------------------------------------------------------------------------------------------
-- Tetap hanya permintaan. Statusnya pending dan tidak memberi hak apa pun sampai disetujui.
create or replace function rc_private.handle_new_user() returns trigger
language plpgsql security definer set search_path='' as $$
declare meta jsonb:=coalesce(new.raw_user_meta_data,'{}'::jsonb);
 v_code text; v_name text; v_email text; v_role text; v_depot text; is_first boolean;
begin
 if meta->>'user_code' is null then
  raise exception 'Akun harus dibuat lewat portal RC (tombol Daftar), atau lewat SQL/Admin API yang menyertakan user_metadata berisi user_code, full_name, business_email dan requested_role. Tombol Add user pada Dashboard tidak menyertakan data itu.';
 end if;
 v_code:=upper(btrim(coalesce(meta->>'user_code','')));
 v_name:=btrim(coalesce(meta->>'full_name',''));
 v_email:=lower(btrim(coalesce(meta->>'business_email','')));
 v_role:=lower(btrim(coalesce(meta->>'requested_role','')));
 v_depot:=btrim(coalesce(meta->>'requested_depot',''));

 if v_code='' or length(v_code)>100 or v_code !~ '^[A-Z0-9._-]+$' then
  raise exception 'User ID wajib diisi, maksimal 100 karakter, hanya huruf, angka, titik, garis bawah dan strip';
 end if;
 if v_name='' or length(v_name)>200 then raise exception 'Nama lengkap wajib diisi'; end if;
 if v_email='' or length(v_email)>320 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
  then raise exception 'Email kantor tidak valid'; end if;
 if v_role not in('admin','osc','non-osc','finance','supervisor','system manager') then
  raise exception 'Role yang diminta tidak dikenali'; end if;
 if length(v_depot)>200 then raise exception 'Depot terlalu panjang'; end if;
 if exists(select 1 from public.profiles where user_code=v_code) then
  raise exception 'User ID sudah terdaftar'; end if;

 lock table public.profiles in exclusive mode;
 select not exists(select 1 from public.profiles) into is_first;

 if is_first then
  insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,
    must_change_password,requested_role,requested_depot,reviewed_at,review_note)
  values(new.id,v_code,v_name,v_email,'system manager','active','001',
    false,v_role,v_depot,now(),'Pendaftar pertama; otomatis menjadi System Manager.');
  insert into public.user_permissions(user_id,permission_code) select new.id,code from public.permissions;
  insert into public.user_depot_access(user_id,depot_id) select new.id,id from public.depots;
  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(new.id,'bootstrap_manager',new.id,
    jsonb_build_object('user_code',v_code,'alasan','pendaftar pertama'));
 else
  insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,
    must_change_password,requested_role,requested_depot)
  values(new.id,v_code,v_name,v_email,v_role,'pending','000',false,v_role,v_depot);
  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(new.id,'registration_submitted',new.id,
    jsonb_build_object('user_code',v_code,'requested_role',v_role,'requested_depot',v_depot));
 end if;
 return new;
end $$;

-- Persetujuan pendaftaran yang meminta System Manager harus memberi peran itu, bukan
-- menyalin string permintaan mentah ke kolom role.
create or replace function rc_private.review_registration(p_profile uuid,p_approve boolean,p_note text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.profiles%rowtype; assigned text;
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 if p_profile=(select auth.uid()) then raise exception 'Tidak dapat menyetujui akun sendiri'; end if;
 select * into target from public.profiles where id=p_profile for update;
 if not found then raise exception 'Pendaftaran tidak ditemukan'; end if;
 if target.status<>'pending' then raise exception 'Pendaftaran ini sudah diproses'; end if;
 if length(coalesce(p_note,''))>1000 then raise exception 'Catatan terlalu panjang'; end if;

 if p_approve then
  assigned:=rc_private.next_suffix();
  update public.profiles set status='active',suffix_num=assigned,
   role=coalesce(nullif(btrim(coalesce(target.requested_role,'')),''),target.role),
   reviewed_by=(select auth.uid()),reviewed_at=now(),review_note=p_note where id=p_profile;
 else
  update public.profiles set status='rejected',
   reviewed_by=(select auth.uid()),reviewed_at=now(),review_note=p_note where id=p_profile;
 end if;

 insert into public.activity_logs(actor_id,event_type,entity_id,details)
 values((select auth.uid()),case when p_approve then 'registration_approved' else 'registration_rejected' end,
   p_profile,jsonb_build_object('user_code',target.user_code,'suffix_num',assigned));
 return jsonb_build_object('status','success','suffix_num',assigned);
end $$;

------------------------------------------------------------------------------------------
-- 10. Suffix batch dikelola, bukan sekadar diberikan otomatis
------------------------------------------------------------------------------------------
-- Suffix membentuk nomor batch: stage(2) + suffix(3) + tanggal(6) + urutan(4). Jadi suffix
-- adalah data bisnis, bukan angka acak. Pemberian otomatis saat persetujuan hanya mencegah
-- akun aktif tanpa suffix; System Manager tetap harus dapat menetapkan nilai yang benar.
--
-- Suffix yang sudah pernah dipakai membuat nomor batch tidak boleh dipindahkan ke orang
-- lain, karena nomor batch lama akan menjadi ambigu. Itu ditolak di sini.
create function rc_private.set_suffix(p_user_code text,p_suffix text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target public.profiles%rowtype; lama text;
begin
 if not rc_private.is_manager() then raise exception 'Hanya System Manager' using errcode='42501'; end if;
 if p_suffix is null or p_suffix !~ '^[0-9]{3}$' then
  raise exception 'Suffix harus tepat tiga digit angka, contoh 007'; end if;
 select * into target from public.profiles where user_code=btrim(coalesce(p_user_code,'')) for update;
 if not found then raise exception 'User tidak ditemukan'; end if;
 lama:=target.suffix_num;
 if lama=p_suffix then return jsonb_build_object('status','success','suffix',p_suffix,'berubah',false); end if;

 if exists(select 1 from public.profiles where suffix_num=p_suffix and status='active' and id<>target.id) then
  raise exception 'Suffix % sudah dipakai akun aktif lain',p_suffix; end if;
 if exists(select 1 from rc_private.batch_counters where suffix=p_suffix) then
  raise exception 'Suffix % sudah pernah menerbitkan nomor batch, sehingga tidak dapat dipindahkan ke akun lain',p_suffix; end if;

 update public.profiles set suffix_num=p_suffix where id=target.id;
 insert into public.activity_logs(actor_id,event_type,entity_id,details)
 values((select auth.uid()),'suffix_changed',target.id,
   jsonb_build_object('user_code',target.user_code,'dari',lama,'menjadi',p_suffix));
 return jsonb_build_object('status','success','suffix',p_suffix,'berubah',true);
end $$;
revoke all on function rc_private.set_suffix(text,text) from public,anon;
grant execute on function rc_private.set_suffix(text,text) to authenticated;

-- Konsol Otorisasi kini ikut mengirim suffix. Fungsi lama dibuang lebih dulu supaya
-- PostgREST tidak menghadapi dua kandidat dengan nama sama.
drop function public.rc_legacy_update_access(text,jsonb,text);
create function public.rc_legacy_update_access(p_user_code text,p_auth jsonb,
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
  ('n','manage_access'),('p','view_master_depot'),('s','bulk_process'),
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
revoke all on function public.rc_legacy_update_access(text,jsonb,text,text) from public,anon;
grant execute on function public.rc_legacy_update_access(text,jsonb,text,text) to authenticated;

-- Daftar suffix yang sudah terpakai, supaya System Manager tidak menebak saat menetapkan.
create function public.rc_suffix_terpakai() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare v jsonb;
begin
 if not rc_private.is_manager() then raise exception 'Hanya System Manager' using errcode='42501'; end if;
 select coalesce(jsonb_agg(x order by x->>'suffix'),'[]'::jsonb) into v from (
  select jsonb_build_object('suffix',p.suffix_num,'userId',p.user_code,'nama',p.full_name,
    'status',p.status,
    'pernahTerbitBatch',exists(select 1 from rc_private.batch_counters b where b.suffix=p.suffix_num)) as x
  from public.profiles p where p.suffix_num<>'000') t;
 return jsonb_build_object('status','success','rows',v);
end $$;
revoke all on function public.rc_suffix_terpakai() from public,anon;
grant execute on function public.rc_suffix_terpakai() to authenticated;
