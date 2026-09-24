-- PENDING: belum diterapkan. Aman dijalankan berulang.
--
-- Dua koreksi dari pemeriksaan data sumber.
--
--  1. ListCampaign.csv memuat empat Jenis CB: Transfer (55), Rebate (31), CN (12) dan
--     Voucher (2). Validasi Campaign Master sebelumnya hanya menerima tiga yang pertama,
--     sehingga dua campaign Voucher akan DITOLAK saat mass upload master. Batasan itu
--     saya buat dari asumsi, bukan dari data; sekarang mengikuti data yang sebenarnya.
--  2. Pemetaan kode depot ke Abbr sudah tersedia pada ListCampaign.csv untuk 50 depot.
--     Mengisinya lebih dulu membuat No Document terbentuk konsisten sejak compile pertama,
--     tanpa bergantung pada ketikan Abbr di berkas unggahan.

------------------------------------------------------------------------------------------
-- 1. Jenis CB mengikuti data, bukan asumsi
------------------------------------------------------------------------------------------
create or replace function rc_private.campaign_upsert(p_rows jsonb) returns jsonb
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
  -- Empat nilai ini yang benar-benar dipakai bisnis. Voucher sempat tertinggal.
  if r ? 'jenisCb' and btrim(r->>'jenisCb')<>''
     and lower(btrim(r->>'jenisCb')) not in('transfer','cn','rebate','voucher')
  then raise exception 'Jenis CB harus Transfer, CN, Rebate atau Voucher pada %',code; end if;

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

------------------------------------------------------------------------------------------
-- 2. Abbr depot dari data yang sudah ada
------------------------------------------------------------------------------------------
-- Pemetaan diambil dari kolom DC, Depot Name dan Abbr pada ListCampaign.csv. Hanya depot
-- yang memang ada di master yang terisi, dan yang sudah punya Abbr tidak ditimpa.
do $rc_abbr$
declare pasangan text[][]:=array[
 ['1A','JKT/TU'],['1B','BHG'],['1C','CKP'],['1D','THK'],['1E','CKR'],['1F','BDG'],
 ['1G','LPG'],['1H','JBI'],['1I','PDG'],['1J','PLB'],['1K','BKL'],['1L','BKA'],
 ['1M','BLG'],['1N','SLO'],['1O','YJK'],['1P','SMR'],['1Q','CRB'],['1R','TGR'],
 ['1S','BGR'],['1T','PTN'],['1U','PKB'],['1V','PWT'],['1W','TSM'],['1X','SRG'],
 ['1Y','PTI'],['1Z','BDJ'],['4A','MDN'],['4C','PST'],['4D','RPP'],['4F','PSN'],
 ['5A','PML'],['5B','BKT'],['5C','CJR'],['5D','BRJ'],['5F','SKW'],['5G','STG'],
 ['5H','GUT'],['5I','KPO'],['5J','KTP'],['5K','JAS'],['5L','LLG'],['5M','BLR'],
 ['5N','KBM'],['5O','SPG'],['5P','SBG'],['5Q','MPG'],['5R','MJA'],['5U','MBG'],
 ['5V','SLK'],['5W','SWG']];
 i integer; kode text; ab text;
begin
 for i in 1..array_length(pasangan,1) loop
  kode:=pasangan[i][1]; ab:=pasangan[i][2];
  -- Abbr wajib hanya huruf dan angka untuk membentuk No Document; JKT/TU mengandung garis
  -- miring yang akan merusak pemisah, jadi dilewati dan harus ditetapkan operator.
  if ab ~ '^[A-Z0-9]{2,10}$' then
   update public.depots set abbr=ab
   where depot_code=kode and abbr is null
     and not exists(select 1 from public.depots d2 where d2.abbr=ab and d2.depot_code<>kode);
  end if;
 end loop;
end $rc_abbr$;

create or replace function rc_private.marker_20260923() returns boolean
language sql immutable set search_path='' as $$select true$$;
revoke all on function rc_private.marker_20260923() from public,anon;
grant execute on function rc_private.marker_20260923() to authenticated;
