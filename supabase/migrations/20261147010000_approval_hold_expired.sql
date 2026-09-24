-- ==========================================================================================
-- Tab keempat: On Hold dan Expired disahkan atau dibatalkan oleh Management
-- ==========================================================================================
-- Permintaan pemilik: "buat 1 tab lagi di management of approval semua yang on hold dan expired
-- masuk kesana dengan scope approval yakni management", dengan alasan yang wajib diisi.
--
-- Artinya, sesuai keputusannya:
--
--   Approve : keputusan menahan atau menghanguskan itu SAH. Status dokumen tidak berubah -
--             ia hanya berhenti menunggu.
--   Reject  : keputusan itu DIBATALKAN. Dokumen kembali ke status sebelum ditahan atau
--             dihanguskan, dan melanjutkan alurnya seperti semula.
--
-- ------------------------------------------------------------------------------------------
-- MENGESAHKAN TANPA MENGUBAH STATUS
-- ------------------------------------------------------------------------------------------
-- Mesin status menuntut setiap tindakan menghasilkan status tujuan. Untuk approve_hold
-- tujuannya adalah status itu sendiri - tidak berpindah ke mana-mana - dan yang menandai bahwa
-- keputusannya sudah disahkan adalah sepasang kolom baru, hold_approved_at dan hold_approved_by.
--
-- Penanda itu diperlukan karena kalau tidak ada, dokumen yang sudah disahkan akan terus muncul
-- di antrean selamanya: statusnya tidak berubah, jadi tidak ada yang membedakannya dari yang
-- belum diperiksa. Penandanya dihapus lagi setiap kali dokumen ditahan atau dihanguskan ULANG,
-- supaya keputusan lama tidak diam-diam mengesahkan keputusan baru.
--
-- ------------------------------------------------------------------------------------------
-- MENGHANGUSKAN KINI MENGINGAT ASALNYA
-- ------------------------------------------------------------------------------------------
-- 'expire' sebelumnya MENGOSONGKAN previous_status, sehingga dokumen yang hangus tidak punya
-- jalan pulang - membatalkannya mustahil karena tidak ada yang tahu ia berasal dari mana.
-- Sekarang asalnya disimpan. Bila yang dihanguskan sedang On Hold, yang disimpan adalah status
-- SEBELUM ditahan, bukan 'on_hold' - membatalkan penghangusan seharusnya mengembalikan dokumen
-- ke alurnya, bukan ke penahanan yang juga sudah tidak berlaku.
--
-- ------------------------------------------------------------------------------------------
-- SIAPA YANG BOLEH
-- ------------------------------------------------------------------------------------------
-- Scope-nya Management, sesuai keputusan pemilik. Depot Head, OSC dan Supervisor tetap MELIHAT
-- antreannya dalam jangkauan depotnya - mengetahui dokumen mana yang tertahan adalah bagian
-- dari pekerjaan mereka - tetapi tombolnya tidak aktif. Pola "lihat luas, tindak sempit" yang
-- sama dengan Timetable.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Penanda keputusan
-- ------------------------------------------------------------------------------------------
alter table public.claims
  add column if not exists hold_approved_at timestamptz,
  add column if not exists hold_approved_by uuid references public.profiles(id);

comment on column public.claims.hold_approved_at is
  'Waktu keputusan On Hold / Expired disahkan Management. Dikosongkan lagi setiap kali dokumen '
  'ditahan atau dihanguskan ulang, sehingga keputusan lama tidak mengesahkan keputusan baru.';

create index if not exists claims_hold_menunggu_idx
  on public.claims(status) where status in ('on_hold','expired') and hold_approved_at is null;

-- ------------------------------------------------------------------------------------------
-- 2. Siapa boleh memutuskan
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.boleh_putus_hold()
returns boolean language sql stable security definer set search_path='' as $fn$
  select exists(
    select 1 from public.profiles p
     where p.id = (select auth.uid()) and p.status = 'active'
       and not p.must_change_password
       and p.role in ('management','system manager'));
$fn$;
revoke all on function rc_private.boleh_putus_hold() from public, anon;
grant execute on function rc_private.boleh_putus_hold() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Mesin status
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text; i int; n int := 0;
  ubah text[][] := array[
    -- tindakan baru dikenali
    [$p$'bulk_rebate','approve','reject_approval')$p$,
     $p$'bulk_rebate','approve','reject_approval','approve_hold','reject_hold')$p$],
    -- izinnya sama dengan tahap approval
    [$p$ when p_action in('approve','reject_approval') then 'approve_claim'$p$,
     $p$ when p_action in('approve','reject_approval','approve_hold','reject_hold') then 'approve_claim'$p$],
    -- keduanya menuntut alasan, sesuai permintaan pemilik untuk tab ini
    [$p$if p_action in('reject_release','reject_claim','reject_clearing','hold','unhold','expire') and btrim$p$,
     $p$if p_action in('reject_release','reject_claim','reject_clearing','hold','unhold','expire','approve_hold','reject_hold') and btrim$p$],
    -- perpindahannya: mengesahkan tidak memindahkan, membatalkan mengembalikan
    [$p$ elsif p_action='bulk_rebate' and c.status in('submitted','approved','released','claimed') then$p$,
     $p$ elsif p_action='approve_hold' and c.status in('on_hold','expired') then target:=c.status;$p$ || chr(10) ||
     $p$ elsif p_action='reject_hold' and c.status in('on_hold','expired') and c.previous_status is not null then target:=c.previous_status;$p$ || chr(10) ||
     $p$ elsif p_action='bulk_rebate' and c.status in('submitted','approved','released','claimed') then$p$],
    -- menghanguskan mengingat asalnya; membatalkan membersihkannya kembali
    [$p$ previous_status=case when p_action='hold' then c.status when p_action in('unhold','expire') then null else previous_status end,$p$,
     $p$ previous_status=case when p_action='hold' then c.status$p$ || chr(10) ||
     $p$   when p_action='expire' then coalesce(c.previous_status,c.status)$p$ || chr(10) ||
     $p$   when p_action in('unhold','reject_hold') then null else previous_status end,$p$],
    -- penanda keputusan
    [$p$ submitted_by=case when p_action='submit' then actor$p$,
     $p$ hold_approved_at=case when p_action='approve_hold' then stamp when p_action in('hold','expire') then null else hold_approved_at end,$p$ || chr(10) ||
     $p$ hold_approved_by=case when p_action='approve_hold' then actor when p_action in('hold','expire') then null else hold_approved_by end,$p$ || chr(10) ||
     $p$ submitted_by=case when p_action='submit' then actor$p$]
  ];
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname='rc_private' and p.proname='mutate_claims_unchecked';
  if src is null then raise exception 'rc_private.mutate_claims_unchecked tidak ditemukan.'; end if;

  if position($q$p_action='approve_hold'$q$ in src) > 0 then
    raise notice 'Mesin status sudah mengenal approve_hold; dilewati.'; return; end if;

  baru := src;
  for i in 1 .. array_length(ubah,1) loop
    if position(ubah[i][1] in baru) = 0 then
      raise exception 'Pola ke-% tidak ditemukan pada mutate_claims_unchecked: %',
        i, left(ubah[i][1], 90);
    end if;
    baru := replace(baru, ubah[i][1], ubah[i][2]);
    n := n + 1;
  end loop;

  execute baru;
  raise notice 'Mesin status mengenal approve_hold dan reject_hold (% pola).', n;
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 4. Antrean On Hold dan Expired
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_approval_hold(p_depot text default null,
                                                   p_search text default null)
returns jsonb language plpgsql stable set search_path='' as $fn$
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
    select c.no_doc, c.version_no, c.status, c.previous_status, c.cb_net, c.batch_upload,
           d.depot_code, d.depot_name, cu.customer_code, cu.customer_name,
           ca.campaign_code, ca.campaign_name, ca.cashback_type,
           h.reason, h.created_at as changed_at, p.full_name as actor_name
      from public.claims c
      left join public.depots d on d.id = c.depot_id
      left join public.customers cu on cu.id = c.customer_id
      left join public.campaigns ca on ca.id = c.campaign_id
      -- Keterangan terakhir yang membawanya ke keadaan ini: alasan, pelaku, waktunya.
      left join lateral (
        select h2.reason, h2.created_at, h2.actor_id
          from public.claim_status_history h2
         where h2.claim_id = c.id and h2.to_status = c.status
         order by h2.created_at desc limit 1) h on true
      left join public.profiles p on p.id = h.actor_id
     where c.status in ('on_hold','expired')
       and c.archived_at is null
       and c.hold_approved_at is null
       and rc_private.can_access(c.depot_id,'approve_claim')
       and (v_depot is null or d.depot_code = v_depot)
       and (v_cari is null or (
            c.no_doc ilike '%'||v_cari||'%'
         or coalesce(cu.customer_code,'') ilike '%'||v_cari||'%'
         or coalesce(cu.customer_name,'') ilike '%'||v_cari||'%'
         or coalesce(ca.campaign_code,'') ilike '%'||v_cari||'%'
         or coalesce(ca.campaign_name,'') ilike '%'||v_cari||'%'
         or coalesce(d.depot_code,'') ilike '%'||v_cari||'%'
         or coalesce(h.reason,'') ilike '%'||v_cari||'%'))) t;
  return hasil;
end $fn$;
revoke all on function public.rc_approval_hold(text,text) from public, anon;
grant execute on function public.rc_approval_hold(text,text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text; v_uid uuid; v_doc text; v_ver bigint; v_status text; v_prev text; h jsonb; n int;
begin
  foreach v_status in array array['hold_approved_at','hold_approved_by'] loop
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='claims' and column_name=v_status) then
      raise exception 'GAGAL: kolom claims.% tidak terbentuk.', v_status; end if;
  end loop;

  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n2 on n2.oid=p.pronamespace
   where n2.nspname='rc_private' and p.proname='mutate_claims_unchecked';
  if position($q$p_action='approve_hold' and c.status in('on_hold','expired') then target:=c.status$q$ in src) = 0 then
    raise exception 'GAGAL: pengesahan tidak mempertahankan status.'; end if;
  if position($q$p_action='reject_hold'$q$ in src) = 0 then
    raise exception 'GAGAL: pembatalan tidak ada.'; end if;
  if position($q$when p_action='expire' then coalesce(c.previous_status,c.status)$q$ in src) = 0 then
    raise exception 'GAGAL: penghangusan masih melupakan asalnya.'; end if;

  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  -- Antrean dapat dipanggil, dan membawa penanda kewenangan.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
  h := public.rc_approval_hold(null, null);
  reset role;
  if (h->>'status') <> 'success' then raise exception 'GAGAL: antrean hold.'; end if;
  if not (h ? 'bolehPutus') then raise exception 'GAGAL: penanda kewenangan tidak ada.'; end if;

  -- Rantai penuh dibuktikan pada sebuah dokumen: tahan, sahkan, lalu batalkan - dan dokumen
  -- harus kembali ke status asalnya. Seluruhnya di dalam sub-transaksi yang dibatalkan.
  select no_doc, version_no, status into v_doc, v_ver, v_prev from public.claims
   where status in ('not_yet','submitted') and archived_at is null order by no_doc limit 1;
  if v_doc is null then
    raise notice 'Tidak ada dokumen untuk menguji rantai hold.';
  else
    begin
      set local role authenticated;
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text,'role','authenticated')::text, true);

      perform public.rc_process_claims('hold',
        jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)),
        gen_random_uuid(), 'Uji tahan');
      select status, version_no into v_status, v_ver from public.claims where no_doc=v_doc;
      if v_status <> 'on_hold' then raise exception 'GAGAL: hold menghasilkan %.', v_status; end if;

      select count(*) into n from jsonb_array_elements(
        (public.rc_approval_hold(null,null))->'rows') x where x->>'noDoc' = v_doc;
      if n <> 1 then raise exception 'GAGAL: dokumen tertahan tidak muncul di antrean.'; end if;

      perform public.rc_process_claims('approve_hold',
        jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)),
        gen_random_uuid(), 'Uji sahkan');
      select status, version_no into v_status, v_ver from public.claims where no_doc=v_doc;
      if v_status <> 'on_hold' then
        raise exception 'GAGAL: pengesahan mengubah status menjadi %.', v_status; end if;
      if not exists (select 1 from public.claims where no_doc=v_doc and hold_approved_at is not null) then
        raise exception 'GAGAL: penanda pengesahan tidak terisi.'; end if;

      select count(*) into n from jsonb_array_elements(
        (public.rc_approval_hold(null,null))->'rows') x where x->>'noDoc' = v_doc;
      if n <> 0 then raise exception 'GAGAL: dokumen yang sudah disahkan masih di antrean.'; end if;

      perform public.rc_process_claims('reject_hold',
        jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)),
        gen_random_uuid(), 'Perubahan SO / billing date');
      select status into v_status from public.claims where no_doc=v_doc;
      if v_status <> v_prev then
        raise exception 'GAGAL: pembatalan mengembalikan ke %, seharusnya %.', v_status, v_prev; end if;
      reset role;

      raise notice 'Rantai hold lolos: % -> on_hold -> disahkan -> dibatalkan -> %', v_prev, v_status;
      raise exception 'BATALKAN_UJI';
    exception when others then
      reset role;
      if sqlerrm like 'GAGAL:%' then raise; end if;
      if sqlerrm <> 'BATALKAN_UJI' then
        raise exception 'GAGAL: rantai hold gagal -> %', sqlerrm; end if;
    end;
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
