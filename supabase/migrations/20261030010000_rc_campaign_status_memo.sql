-- ==========================================================================================
-- Campaign Master: status, Created on/by, memo PDF, dan penghapusan campaign tanpa klaim
-- ==========================================================================================
-- Empat permintaan pemilik atas tab Campaign Master pada Key Master:
--
--   1. Campaign dengan nilai klaim 0 boleh dihapus.
--   2. Kolom baru "Status Campaign": active, inactive, cleared. Campaign inactive tidak boleh
--      lagi di-claim maupun di-upload.
--   3. Kolom Created on dan Created by.
--   4. Lampiran memo berbentuk PDF.
--
-- MENGAPA PENGHAPUSAN DIBATASI PADA CAMPAIGN TANPA KLAIM
-- Di basis data ini 72 dari 100 campaign sama sekali belum punya klaim, dan TIDAK ADA satu pun
-- campaign yang punya klaim bernilai nol. Jadi dalam praktiknya "nilai klaim 0" persis sama
-- dengan "belum punya klaim", dan membatasinya di situ menghapus tanpa menyentuh satu baris
-- klaim pun. Andai kelak ada campaign berklaim nol, ia tetap ditolak dengan sebab yang jelas -
-- menghapus campaign berikut klaimnya adalah keputusan yang harus diambil sadar, bukan efek
-- samping dari sebuah tombol di layar master.
--
-- MENGAPA LARANGAN INACTIVE DIPASANG SEBAGAI TRIGGER
-- Klaim lahir dan berpindah status lewat beberapa jalan: rc_compile_upload, rc_process_claims,
-- rc_posting_exception, rc_reprocessing_upload. Menaruh pemeriksaannya di masing-masing berarti
-- aturan yang sama dipelihara di empat tempat, dan jalan kelima yang ditambahkan nanti akan
-- melewatinya tanpa ada yang menyadari. Trigger pada tabel claims berlaku untuk semuanya
-- sekaligus, termasuk jalan yang belum ada.
--
-- Status 'cleared' berarti campaign-nya sudah selesai seluruhnya. Klaim BARU ditolak, tetapi
-- klaim yang sudah telanjur berjalan tetap boleh diselesaikan - kalau tidak, dokumen yang
-- sedang di tengah alur akan terjebak selamanya begitu seseorang menandai campaign-nya selesai.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

alter table public.campaigns add column if not exists status text not null default 'active';
alter table public.campaigns drop constraint if exists campaigns_status_check;
alter table public.campaigns add constraint campaigns_status_check
  check (status in ('active','inactive','cleared'));
comment on column public.campaigns.status is
  'active: berjalan normal. inactive: tidak boleh di-claim maupun di-upload. '
  'cleared: seluruhnya sudah selesai, klaim baru ditolak.';

alter table public.campaigns add column if not exists created_at timestamptz not null default now();
alter table public.campaigns add column if not exists created_by uuid references public.profiles(id);

-- Lampiran memo. Berkasnya sendiri disimpan di Storage; di sini hanya keterangannya, supaya
-- daftar campaign tidak perlu memanggil Storage sekadar untuk tahu ada memo atau tidak.
alter table public.campaigns add column if not exists memo_path text;
alter table public.campaigns add column if not exists memo_name text;
alter table public.campaigns add column if not exists memo_size integer;
alter table public.campaigns add column if not exists memo_uploaded_at timestamptz;
alter table public.campaigns add column if not exists memo_uploaded_by uuid references public.profiles(id);

-- ------------------------------------------------------------------------------------------
-- Tempat penyimpanan memo
-- ------------------------------------------------------------------------------------------
-- Bucket privat. Memo campaign adalah dokumen internal; tautan publik yang bocor sekali akan
-- terbuka selamanya tanpa jejak. Pengunduhannya lewat signed URL berumur pendek.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('campaign-memo', 'campaign-memo', false, 10485760, array['application/pdf'])
on conflict (id) do update set
  public = false, file_size_limit = 10485760, allowed_mime_types = array['application/pdf'];

drop policy if exists campaign_memo_baca on storage.objects;
create policy campaign_memo_baca on storage.objects for select to authenticated
  using (bucket_id = 'campaign-memo' and rc_private.can_access(null));

drop policy if exists campaign_memo_tulis on storage.objects;
create policy campaign_memo_tulis on storage.objects for insert to authenticated
  with check (bucket_id = 'campaign-memo' and rc_private.can_access(null,'manage_key_master'));

drop policy if exists campaign_memo_ganti on storage.objects;
create policy campaign_memo_ganti on storage.objects for update to authenticated
  using (bucket_id = 'campaign-memo' and rc_private.can_access(null,'manage_key_master'))
  with check (bucket_id = 'campaign-memo' and rc_private.can_access(null,'manage_key_master'));

drop policy if exists campaign_memo_hapus on storage.objects;
create policy campaign_memo_hapus on storage.objects for delete to authenticated
  using (bucket_id = 'campaign-memo' and rc_private.can_access(null,'manage_key_master'));

-- ------------------------------------------------------------------------------------------
-- Larangan claim dan upload pada campaign inactive
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.jaga_status_campaign() returns trigger
language plpgsql security definer set search_path='' as $fn$
declare st text; kode text;
begin
  select c.status, c.campaign_code into st, kode
    from public.campaigns c where c.id = new.campaign_id;
  if st is null then return new; end if;

  if tg_op = 'INSERT' then
    if st in ('inactive','cleared') then
      raise exception 'Campaign % berstatus %; klaim baru tidak dapat dibuat',
        kode, st using errcode='P0001';
    end if;
    return new;
  end if;

  -- Hanya perpindahan MAJU yang dilarang. Menolak, menahan, dan menghanguskan tetap boleh,
  -- supaya dokumen yang telanjur berjalan masih dapat dibereskan setelah campaign-nya dimatikan.
  if new.status is distinct from old.status
     and new.status in ('submitted','released','claimed','done')
     and st = 'inactive' then
    raise exception 'Campaign % berstatus inactive; dokumen tidak dapat diproses lebih lanjut',
      kode using errcode='P0001';
  end if;
  return new;
end $fn$;
revoke all on function rc_private.jaga_status_campaign() from public,anon;

drop trigger if exists jaga_status_campaign on public.claims;
create trigger jaga_status_campaign before insert or update on public.claims
  for each row execute function rc_private.jaga_status_campaign();

-- ------------------------------------------------------------------------------------------
-- Daftar campaign: kolom baru ikut terbawa
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_campaign_list(p_search text default '',p_offset integer default 0,
 p_limit integer default 50)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
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
   'jenisCb',coalesce(ca.cashback_type,''),'statusPajak',coalesce(ca.tax_status,''),
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

-- ------------------------------------------------------------------------------------------
-- Upsert menerima kolom status, dan mencatat pembuatnya
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.campaign_upsert(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r jsonb; code text; k text; dibuat integer:=0; diperbarui integer:=0; sudah boolean;
 st text; aku uuid:=(select auth.uid());
begin
 if not rc_private.can_access(null,'manage_key_master') then
  raise exception 'Access denied' using errcode='42501'; end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array' then raise exception 'Data harus berupa array'; end if;
 if jsonb_array_length(p_rows) not between 1 and 2000 then raise exception 'Satu unggahan maksimal 2000 baris'; end if;

 for r in select value from jsonb_array_elements(p_rows) loop
  if jsonb_typeof(r)<>'object' then raise exception 'Setiap baris harus berupa objek'; end if;
  for k in select key from jsonb_each(r) loop
   if k not in('codeCampaign','campaignName','periodStart','periodEnd','jenisCb','statusPajak','status')
   then raise exception 'Kolom tidak dikenali: %',k; end if;
   if jsonb_typeof(r->k)<>'string' or length(r->>k)>200 then
    raise exception 'Nilai kolom % harus teks maksimal 200 karakter',k; end if;
  end loop;
  code:=upper(btrim(coalesce(r->>'codeCampaign','')));
  if code='' then raise exception 'Code Campaign wajib diisi pada setiap baris'; end if;
  if r ? 'jenisCb' and btrim(r->>'jenisCb')<>''
     and lower(btrim(r->>'jenisCb')) not in('transfer','cn','rebate','voucher')
  then raise exception 'Jenis CB harus Transfer, CN, Rebate atau Voucher pada %',code; end if;

  st := lower(btrim(coalesce(r->>'status','')));
  if r ? 'status' and st <> '' and st not in('active','inactive','cleared') then
   raise exception 'Status campaign harus active, inactive atau cleared pada %',code; end if;

  select exists(select 1 from public.campaigns where campaign_code=code) into sudah;
  if sudah then
   update public.campaigns set
    campaign_name=case when r ? 'campaignName' and btrim(r->>'campaignName')<>'' then btrim(r->>'campaignName') else campaign_name end,
    period_start_text=case when r ? 'periodStart' then nullif(btrim(r->>'periodStart'),'') else period_start_text end,
    period_end_text=case when r ? 'periodEnd' then nullif(btrim(r->>'periodEnd'),'') else period_end_text end,
    cashback_type=case when r ? 'jenisCb' then nullif(btrim(r->>'jenisCb'),'') else cashback_type end,
    tax_status=case when r ? 'statusPajak' then nullif(btrim(r->>'statusPajak'),'') else tax_status end,
    status=case when st <> '' then st else status end
   where campaign_code=code;
   diperbarui:=diperbarui+1;
  else
   if btrim(coalesce(r->>'campaignName',''))='' then
    raise exception 'Nama campaign wajib diisi untuk kode baru: %',code; end if;
   insert into public.campaigns(campaign_code,campaign_name,period_start_text,period_end_text,
     cashback_type,tax_status,status,created_by)
   values(code,btrim(r->>'campaignName'),nullif(btrim(coalesce(r->>'periodStart','')),''),
     nullif(btrim(coalesce(r->>'periodEnd','')),''),nullif(btrim(coalesce(r->>'jenisCb','')),''),
     nullif(btrim(coalesce(r->>'statusPajak','')),''),
     case when st <> '' then st else 'active' end, aku);
   dibuat:=dibuat+1;
  end if;
 end loop;

 insert into public.activity_logs(actor_id,event_type,details)
 values(aku,'campaign_master_upsert',
   jsonb_build_object('dibuat',dibuat,'diperbarui',diperbarui));
 return jsonb_build_object('status','success','dibuat',dibuat,'diperbarui',diperbarui);
end $$;

-- ------------------------------------------------------------------------------------------
-- Penghapusan campaign yang belum punya klaim
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_campaign_delete(p_codes jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare kode text; ca public.campaigns%rowtype; jml bigint; nilai numeric;
 n_ok integer:=0; gagal jsonb:='[]'::jsonb; aku uuid:=(select auth.uid());
begin
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
end $fn$;
revoke all on function public.rc_campaign_delete(jsonb) from public,anon;
grant execute on function public.rc_campaign_delete(jsonb) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Keterangan memo
-- ------------------------------------------------------------------------------------------
-- Berkasnya diunggah browser langsung ke Storage; fungsi ini hanya mencatat keterangannya.
-- Jalur simpannya ditentukan di sini, bukan diterima dari browser, supaya sebuah baris tidak
-- dapat diarahkan ke berkas milik campaign lain.
create or replace function public.rc_campaign_memo_set(
  p_code text, p_path text, p_name text, p_size integer)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare ca public.campaigns%rowtype; aku uuid:=(select auth.uid());
begin
 if not rc_private.can_access(null,'manage_key_master') then
  raise exception 'Tidak punya hak mengubah Key Master' using errcode='42501'; end if;
 select * into ca from public.campaigns where upper(campaign_code)=upper(btrim(coalesce(p_code,'')));
 if not found then raise exception 'Campaign % tidak ditemukan', p_code; end if;
 if coalesce(p_size,0) <= 0 or p_size > 10485760 then
  raise exception 'Ukuran memo harus antara 1 byte dan 10 MB'; end if;
 if p_path is null or p_path !~ ('^' || ca.id::text || '/[A-Za-z0-9._-]+\.pdf$') then
  raise exception 'Jalur memo tidak sah untuk campaign ini'; end if;

 update public.campaigns set
   memo_path = p_path,
   memo_name = left(btrim(coalesce(p_name,'memo.pdf')),200),
   memo_size = p_size,
   memo_uploaded_at = now(),
   memo_uploaded_by = aku
 where id = ca.id;

 insert into public.activity_logs(actor_id,event_type,details)
 values(aku,'campaign_memo_set',jsonb_build_object('kode',ca.campaign_code,'berkas',p_name));
 return jsonb_build_object('status','success','message','Memo tersimpan');
end $fn$;
revoke all on function public.rc_campaign_memo_set(text,text,text,integer) from public,anon;
grant execute on function public.rc_campaign_memo_set(text,text,text,integer) to authenticated;

create or replace function public.rc_campaign_memo_clear(p_code text)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare ca public.campaigns%rowtype; aku uuid:=(select auth.uid());
begin
 if not rc_private.can_access(null,'manage_key_master') then
  raise exception 'Tidak punya hak mengubah Key Master' using errcode='42501'; end if;
 select * into ca from public.campaigns where upper(campaign_code)=upper(btrim(coalesce(p_code,'')));
 if not found then raise exception 'Campaign % tidak ditemukan', p_code; end if;
 update public.campaigns set memo_path=null, memo_name=null, memo_size=null,
   memo_uploaded_at=null, memo_uploaded_by=null where id=ca.id;
 insert into public.activity_logs(actor_id,event_type,details)
 values(aku,'campaign_memo_clear',jsonb_build_object('kode',ca.campaign_code));
 return jsonb_build_object('status','success','message','Memo dilepas','path',coalesce(ca.memo_path,''));
end $fn$;
revoke all on function public.rc_campaign_memo_clear(text) from public,anon;
grant execute on function public.rc_campaign_memo_clear(text) to authenticated;

create or replace function rc_private.marker_20261030() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261030() from public,anon;
grant execute on function rc_private.marker_20261030() to authenticated;

select 'Campaign status dan memo terpasang' as hasil,
 (select count(*) from public.campaigns where status='active') as aktif,
 (select count(*) from public.campaigns ca
   where not exists(select 1 from public.claims c where c.campaign_id=ca.id)) as dapat_dihapus;
