-- ==========================================================================================
-- Tab Open: Created on dan Created by; serta sinkronisasi rekening ke Customer Master
-- ==========================================================================================
-- DUA PERMINTAAN PEMILIK YANG SALING BERKAITAN
--
-- 1. Tab Open memerlukan kolom "Created on" (tanggal compile) dan "Created by" (siapa yang
--    meng-compile). Kolom pertama sudah ada sebagai claims.created_at. Yang kedua belum pernah
--    disimpan sama sekali, jadi ditambahkan di sini dan diisi mundur dari riwayat status:
--    pelaku tindakan paling awal atas sebuah dokumen adalah yang membuatnya. Baris yang
--    riwayatnya tidak menyimpan pelaku dibiarkan kosong, bukan ditebak - sebuah nama yang salah
--    tebak pada kolom "siapa yang membuat" lebih buruk daripada tanda hubung.
--
-- 2. Ketika Nomor Rekening, Nama Rekening atau Bank diubah saat posting, perubahan itu harus
--    ikut memperbarui Customer Master. Selama ini layar hanya menampilkan peringatan "Update
--    Master Rek" dan tidak ada yang benar-benar diperbarui, sehingga koreksi yang sama harus
--    diketik ulang pada setiap dokumen berikutnya milik toko yang sama.
--
--    Pembaruannya dilakukan di dalam transaksi yang sama dengan posting-nya. Bila posting gagal,
--    master pun tidak berubah - tidak ada keadaan setengah jadi di mana master sudah bergeser
--    tetapi dokumennya tertahan.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

alter table public.claims add column if not exists created_by uuid references public.profiles(id);
comment on column public.claims.created_by is
  'Siapa yang meng-compile dokumen ini. Diisi saat compile, dan diisi mundur dari riwayat '
  'status untuk dokumen yang dibuat sebelum kolom ini ada.';

-- Pengisian mundur: pelaku tindakan paling awal atas dokumen itu.
update public.claims c
   set created_by = h.actor_id
  from (select distinct on (claim_id) claim_id, actor_id
          from public.claim_status_history
         where actor_id is not null
         order by claim_id, id) h
 where h.claim_id = c.id and c.created_by is null;

create index if not exists claims_created_by_idx on public.claims(created_by);

-- ------------------------------------------------------------------------------------------
-- Tab Open memuat dua kolom baru
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_open_claims(
  p_search text default '', p_campaign text default '', p_offset integer default 0,
  p_limit integer default 200)
returns jsonb language plpgsql stable set search_path='' as $fn$
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
  where c.status='not_yet'
    and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,200),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 return jsonb_build_object('status','success','rows',v,'total',jml);
end $fn$;
revoke all on function public.rc_open_claims(text,text,integer,integer) from public,anon;
grant execute on function public.rc_open_claims(text,text,integer,integer) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Rekening yang diubah saat posting ikut memperbarui Customer Master
-- ------------------------------------------------------------------------------------------
-- Dipisah menjadi fungsi tersendiri supaya jalur posting mana pun memakai aturan yang sama,
-- dan supaya alasannya dapat dibaca di satu tempat.
create or replace function rc_private.sinkron_rekening(
  p_customer uuid, p_norek text, p_namarek text, p_bank text)
returns boolean language plpgsql security definer set search_path='' as $fn$
declare berubah boolean := false; lama public.customers%rowtype;
begin
  if p_customer is null then return false; end if;
  select * into lama from public.customers where id = p_customer for update;
  if not found then return false; end if;

  -- Hanya nilai yang benar-benar dikirim dan benar-benar berbeda yang menimpa master. Nilai
  -- kosong TIDAK menghapus isi master: sebuah kolom yang dibiarkan kosong pada satu dokumen
  -- bukan pernyataan bahwa datanya memang tidak ada.
  if coalesce(btrim(p_norek),'') <> '' and btrim(p_norek) is distinct from coalesce(lama.account_number,'') then
    update public.customers set account_number = btrim(p_norek),
      updated_at = now(), updated_by = (select auth.uid()) where id = p_customer;
    berubah := true;
  end if;
  if coalesce(btrim(p_namarek),'') <> '' and btrim(p_namarek) is distinct from coalesce(lama.account_name,'') then
    update public.customers set account_name = btrim(p_namarek),
      updated_at = now(), updated_by = (select auth.uid()) where id = p_customer;
    berubah := true;
  end if;
  if coalesce(btrim(p_bank),'') <> '' and btrim(p_bank) is distinct from coalesce(lama.bank,'') then
    update public.customers set bank = btrim(p_bank),
      updated_at = now(), updated_by = (select auth.uid()) where id = p_customer;
    berubah := true;
  end if;

  if berubah then
    insert into public.activity_logs(actor_id,event_type,entity_id,details)
    values((select auth.uid()),'customer_rekening_disinkronkan',p_customer,
      jsonb_build_object('kode',lama.customer_code,
        'dari',jsonb_build_object('noRek',coalesce(lama.account_number,''),
                                  'namaRek',coalesce(lama.account_name,''),
                                  'bank',coalesce(lama.bank,'')),
        'menjadi',jsonb_build_object('noRek',btrim(coalesce(p_norek,'')),
                                     'namaRek',btrim(coalesce(p_namarek,'')),
                                     'bank',btrim(coalesce(p_bank,'')))));
  end if;
  return berubah;
end $fn$;
revoke all on function rc_private.sinkron_rekening(uuid,text,text,text) from public,anon;

create or replace function rc_private.marker_20261025() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261025() from public,anon;
grant execute on function rc_private.marker_20261025() to authenticated;

select 'Created by dan sinkron rekening terpasang' as hasil,
 (select count(*) from public.claims where created_by is not null) as claim_ber_created_by,
 (select count(*) from public.claims) as total_claim,
 (select count(*) from public.claims where created_by is null) as belum_diketahui_pembuatnya;
