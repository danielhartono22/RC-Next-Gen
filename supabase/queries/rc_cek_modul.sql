-- Kenapa modul Release / Claim Process / Bulk Process kosong, dan apa isi tab Open.
--
-- Hanya membaca, tidak mengubah apa pun.
-- Supabase Dashboard -> SQL Editor -> tempel seluruh isi ini -> Run.
--
-- Seluruhnya SATU query, karena SQL Editor hanya menampilkan hasil pernyataan terakhir.
-- Versi sebelumnya berisi lima select terpisah, sehingga empat bagian pertamanya tidak
-- pernah terlihat. Salin seluruh tabel hasilnya.
--
-- Dijalankan lewat SQL Editor berarti RLS TIDAK berlaku, jadi angka di sini adalah seluruh
-- data. Bila bagian "Isi modul" tidak nol tetapi layar tetap kosong, penyebabnya ada pada
-- scope depot atau permission, bukan pada datanya. Bagian "Akses akun" memeriksa itu.

with
status_claim as (
  select status, count(*) as jumlah,
         count(*) filter (where archived_at is not null) as terarsip
  from public.claims group by status
),
isi_modul as (
  select 1 as urut, 'Tab Open (Not Yet)' as label, count(*)::bigint as jumlah, ''::text as info
    from public.claims where status='not_yet' and archived_at is null
  union all
  select 2, 'Release (Submitted, non-Rebate)', count(*), ''
    from public.claims c join public.campaigns ca on ca.id=c.campaign_id
    where c.status='submitted' and c.archived_at is null
      and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'
  union all
  select 3, 'Claim to Finance (Released, non-Rebate)', count(*), ''
    from public.claims c join public.campaigns ca on ca.id=c.campaign_id
    where c.status='released' and c.archived_at is null
      and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'
  union all
  select 4, 'Clearing (Claimed, non-Rebate)', count(*), ''
    from public.claims c join public.campaigns ca on ca.id=c.campaign_id
    where c.status='claimed' and c.archived_at is null
      and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'
  union all
  select 5, 'Bulk Process (Rebate: Submitted/Released/Claimed)', count(*), ''
    from public.claims c join public.campaigns ca on ca.id=c.campaign_id
    where c.status in('submitted','released','claimed') and c.archived_at is null
      and lower(btrim(coalesce(ca.cashback_type,'')))='rebate'
),
jenis_cb as (
  select coalesce(nullif(btrim(ca.cashback_type),''),'(KOSONG)') as jenis,
         count(distinct ca.id) as jumlah_campaign,
         count(c.id) as jumlah_claim
  from public.campaigns ca
  left join public.claims c on c.campaign_id=ca.id and c.archived_at is null
  group by coalesce(nullif(btrim(ca.cashback_type),''),'(KOSONG)')
),
depot as (
  select d.depot_code, d.depot_name, coalesce(d.abbr,'(belum ada)') as abbr,
         (select count(*) from public.claims c where c.depot_id=d.id) as jumlah_claim
  from public.depots d
),
akun as (
  select p.user_code, p.role, p.status, p.must_change_password,
         (select count(*) from public.user_depot_access a where a.user_id=p.id) as jml_depot,
         (select count(*) from public.depots) as total_depot,
         (select count(*) from public.user_permissions up where up.user_id=p.id) as jml_permission
  from public.profiles p
)
select * from (
  select 1 as bagian_urut, 'A. Sebaran status claim' as bagian,
         status as kunci, jumlah::text as nilai,
         case when terarsip>0 then terarsip||' terarsip' else '' end as catatan
  from status_claim
  union all
  select 2, 'B. Isi tiap modul', label, jumlah::text,
         case when jumlah=0 then 'KOSONG' else '' end
  from isi_modul
  union all
  select 3, 'C. Jenis CB campaign', jenis,
         jumlah_campaign||' campaign', jumlah_claim||' claim'
  from jenis_cb
  union all
  select 4, 'D. Depot di master', depot_code||' - '||depot_name,
         jumlah_claim||' claim', 'abbr: '||abbr
  from depot
  union all
  select 5, 'E. Akses akun', user_code||' ('||role||')',
         jml_depot||'/'||total_depot||' depot',
         status||', '||jml_permission||' permission'
         ||case when must_change_password then ', WAJIB GANTI PIN' else '' end
  from akun
  union all
  -- Ringkasan supaya penyebab paling umum langsung terbaca tanpa menafsir angka di atas.
  select 6, 'F. Kesimpulan', 'Total claim',
         (select count(*)::text from public.claims),
         case
           when (select count(*) from public.claims)=0
             then 'Tabel claims KOSONG; data belum pernah diimpor'
           when (select count(*) from public.claims where status in('submitted','released','claimed'))=0
             then 'Tidak ada claim berstatus Submitted/Released/Claimed; modul memang kosong'
           when (select count(*) from public.profiles where status='active')=0
             then 'Tidak ada akun aktif'
           when exists(select 1 from public.profiles p where p.status='active'
                       and (select count(*) from public.user_depot_access a where a.user_id=p.id)=0)
             then 'Ada akun aktif TANPA depot; layarnya akan kosong walaupun data ada'
           else 'Data dan akses terlihat wajar; periksa filter di layar atau muat ulang sesi'
         end
) hasil
order by bagian_urut, kunci;
