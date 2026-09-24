-- PENDING: belum diterapkan. Aman dijalankan berulang.
--
-- Menyelesaikan perbaikan yang sebelumnya setengah jadi, dan membuat modul kosong
-- menjelaskan dirinya sendiri.
--
-- MASALAHNYA. Migration 20260924010000 membuat rc_private.can_access mengenali peran System
-- Manager, tetapi dua fungsi lain yang menentukan apa yang terlihat di layar tidak ikut
-- diubah:
--
--   * rc_private.legacy_auth_flags masih membaca baris user_permissions. Bila barisnya tidak
--     lengkap, seluruh flag menjadi 'No', dan applyRoleBasedUI menyembunyikan menu Release,
--     Claim Process serta Bulk Process. Menunya hilang, bukan kosong.
--   * rc_legacy_bootstrap masih mengambil depot dari user_depot_access. Bila kosong,
--     managedDepots ikut kosong, sehingga setiap dokumen ditolak sebagai "Beda DC" dan
--     tampilan depot menjadi kosong.
--
-- Jadi akses ke data sudah terbuka, tetapi layarnya tetap tidak menampilkan apa pun. Setengah
-- perbaikan seperti ini lebih menyesatkan daripada tidak memperbaiki sama sekali, karena
-- gejalanya tidak berubah sementara penyebabnya sudah berpindah.
--
-- Perbaikannya: satu sumber kebenaran untuk peran, dipakai oleh semua.

------------------------------------------------------------------------------------------
-- 1. Satu sumber kebenaran
------------------------------------------------------------------------------------------
create or replace function rc_private.is_system_manager() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles p
   where p.id=(select auth.uid()) and p.role='system manager'
     and p.status='active' and not p.must_change_password);
$$;
revoke all on function rc_private.is_system_manager() from public,anon;
grant execute on function rc_private.is_system_manager() to authenticated;

create or replace function rc_private.can_access(p_depot uuid, p_permission text default null)
returns boolean language sql stable security definer set search_path='' as $$
select exists(
  select 1 from public.profiles p
  where p.id=(select auth.uid())
    and p.status='active'
    and not p.must_change_password
    and (
      p.role='system manager'
      or (
        (p_depot is null
         or exists(select 1 from public.user_depot_access a
                   where a.user_id=p.id and a.depot_id=p_depot))
        and (p_permission is null
         or exists(select 1 from public.user_permissions x
                   where x.user_id=p.id and x.permission_code=p_permission))
      )
    )
);
$$;

-- is_manager() sebelumnya menuntut permission manage_access DAN peran. Kini cukup perannya,
-- konsisten dengan yang lain, sehingga konsol tidak terkunci hanya karena satu baris hilang.
create or replace function rc_private.is_manager() returns boolean
language sql stable security definer set search_path='' as $$
 select rc_private.is_system_manager();
$$;

------------------------------------------------------------------------------------------
-- 2. Flag menu mengikuti peran
------------------------------------------------------------------------------------------
-- Inilah yang membuat menu Release, Claim Process dan Bulk Process hilang dari dashboard.
create or replace function rc_private.legacy_auth_flags() returns jsonb
language sql stable security definer set search_path='' as $$
 select case when rc_private.is_system_manager() then
   -- System Manager memegang seluruh modul. Tidak bergantung pada baris permission.
   jsonb_build_object('j','Yes','k','Yes','l','Yes','m','Yes','d','Yes','n','Yes',
     'p','Yes','s','Yes','q','No','logs','Yes',
     'keyMaster','Yes','compilation','Yes','archiveCompilation','Yes')
 else
   jsonb_build_object(
    'j',case when x.p ? 'upload_claim' then 'Yes' else 'No' end,
    'k',case when x.p ? 'release_claim' then 'Yes' else 'No' end,
    'l',case when x.p ? 'process_claim' then 'Yes' else 'No' end,
    'm',case when x.p ? 'view_analytics' then 'Yes' else 'No' end,
    'd',case when x.p ? 'view_analytics' then 'Yes' else 'No' end,
    'n',case when x.p ? 'manage_access' then 'Yes' else 'No' end,
    'p',case when x.p ? 'view_master_depot' then 'Yes' else 'No' end,
    's',case when x.p ? 'bulk_process' then 'Yes' else 'No' end,
    'q','No',
    'logs',case when x.p ? 'view_logs' then 'Yes' else 'No' end,
    'keyMaster',case when x.p ? 'manage_key_master' then 'Yes' else 'No' end,
    'compilation',case when x.p ? 'view_compilation' then 'Yes' else 'No' end,
    'archiveCompilation',case when x.p ? 'archive_compilation' then 'Yes' else 'No' end)
 end
 from (select coalesce(jsonb_object_agg(permission_code,true),'{}'::jsonb) as p
       from public.user_permissions where user_id=(select auth.uid())) x;
$$;

------------------------------------------------------------------------------------------
-- 3. Bootstrap: depot mengikuti peran
------------------------------------------------------------------------------------------
-- managedDepots yang kosong membuat layar Claim Upload menolak setiap dokumen sebagai
-- "Beda DC", walaupun datanya terbaca.
create or replace function public.rc_legacy_bootstrap() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
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
 select * into home from public.depots where id=any(depot_ids) order by depot_code limit 1;
 may_read_contacts:=rc_private.can_access(null,'upload_claim');

 result:=jsonb_build_object(
  'status','success',
  'data',jsonb_build_object(
   'userId',me.user_code,'namaLengkap',me.full_name,'role',me.role,'sysRole',me.role,
   'email',me.business_email,'activation','active','suffix',me.suffix_num,
   'kodeDepot',coalesce(home.depot_code,''),'depot',coalesce(home.depot_name,''),
   'regional','','auth',flags,
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
     'jenisCb',coalesce(cashback_type,''),'statusPajak',coalesce(tax_status,''),
     'masterCode','','masterCodeName','',
     'periodStart',coalesce(period_start_text,''),'periodEnd',coalesce(period_end_text,''))
     order by campaign_code) from public.campaigns),'[]'::jsonb),
  'documents',rc_private.legacy_documents(),
  'customers',rc_private.legacy_customers(may_read_contacts));
 return result;
end $$;

------------------------------------------------------------------------------------------
-- 4. Modul kosong menjelaskan dirinya sendiri
------------------------------------------------------------------------------------------
-- Selama ini "kosong" berarti dua hal yang sangat berbeda: tidak ada datanya, atau ada
-- datanya tetapi tidak terlihat oleh akun ini. Keduanya tampak identik di layar, dan itulah
-- sebabnya penyebabnya berkali-kali salah ditebak.
--
-- Fungsi ini menjawabnya dari sudut pandang sesi yang sedang berjalan: berapa yang terlihat,
-- berapa yang sebenarnya ada, dan bila berbeda, kenapa.
create or replace function public.rc_workflow_diagnostic() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare me public.profiles%rowtype; terlihat jsonb; semua jsonb; sebab text;
 n_depot integer; n_total_depot integer; n_claim_total bigint;
begin
 select * into me from public.profiles where id=(select auth.uid());
 if not found then raise exception 'Access denied' using errcode='42501'; end if;

 -- Yang terlihat oleh akun ini, memakai aturan akses yang sama dengan layar.
 select jsonb_build_object(
   'open',count(*) filter (where c.status='not_yet'),
   'release',count(*) filter (where c.status='submitted' and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'),
   'claim',count(*) filter (where c.status='released' and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'),
   'clearing',count(*) filter (where c.status='claimed' and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'),
   'bulk',count(*) filter (where c.status in('submitted','released','claimed') and lower(btrim(coalesce(ca.cashback_type,'')))='rebate'))
 into terlihat
 from public.claims c join public.campaigns ca on ca.id=c.campaign_id
 where c.archived_at is null and rc_private.can_access(c.depot_id);

 -- Yang benar-benar ada di database, mengabaikan akses.
 select jsonb_build_object(
   'open',count(*) filter (where c.status='not_yet'),
   'release',count(*) filter (where c.status='submitted' and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'),
   'claim',count(*) filter (where c.status='released' and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'),
   'clearing',count(*) filter (where c.status='claimed' and lower(btrim(coalesce(ca.cashback_type,'')))<>'rebate'),
   'bulk',count(*) filter (where c.status in('submitted','released','claimed') and lower(btrim(coalesce(ca.cashback_type,'')))='rebate'))
 into semua
 from public.claims c join public.campaigns ca on ca.id=c.campaign_id
 where c.archived_at is null;

 select count(*) into n_depot from public.user_depot_access where user_id=me.id;
 select count(*) into n_total_depot from public.depots;
 select count(*) into n_claim_total from public.claims;

 sebab:=case
   when n_claim_total=0
     then 'Tabel claims kosong. Data klaim belum pernah diimpor ke project ini.'
   when (semua->>'release')::int=0 and (semua->>'claim')::int=0
        and (semua->>'clearing')::int=0 and (semua->>'bulk')::int=0
     then 'Tidak ada satu pun claim berstatus Submitted, Released atau Claimed. Modul memang kosong, bukan tersembunyi.'
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
end $$;
revoke all on function public.rc_workflow_diagnostic() from public,anon;
grant execute on function public.rc_workflow_diagnostic() to authenticated;

create or replace function rc_private.marker_20260925() returns boolean
language sql immutable set search_path='' as $$select true$$;
revoke all on function rc_private.marker_20260925() from public,anon;
grant execute on function rc_private.marker_20260925() to authenticated;
