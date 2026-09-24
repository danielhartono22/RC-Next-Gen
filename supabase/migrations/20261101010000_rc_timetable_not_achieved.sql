-- ==========================================================================================
-- Not Achieved: siapa boleh menandai, siapa boleh membatalkan, dan akibatnya pada upload
-- ==========================================================================================
-- Tiga permintaan pemilik atas modul Timetable:
--
--   2. Admin boleh menandai Not Achieved langsung dari campaign pada Progres per Campaign.
--      OSC hingga System Manager boleh menandai DAN membatalkan, lewat kartu Detail Not
--      Achieved yang baru.
--   3. Pasangan yang ditandai Not Achieved ditolak pada proses compile dan upload, kecuali
--      tandanya sudah dibatalkan oleh minimal OSC.
--
-- MENANDAI DAN MEMBATALKAN BUKAN HAK YANG SAMA
-- Menandai adalah pengakuan "depot ini memang tidak ikut campaign tersebut" - keterangan yang
-- paling tahu justru depotnya sendiri, jadi admin depot boleh melakukannya. Membatalkan
-- berarti membuka kembali jalan masuk klaim, dan itu keputusan atasannya. Bila keduanya
-- disatukan, sebuah depot dapat menandai lalu membatalkan sendiri setiap kali perlu, dan
-- tandanya berhenti berarti apa pun.
--
-- MENGAPA LARANGANNYA TRIGGER, BUKAN PEMERIKSAAN DI TIAP FUNGSI
-- Klaim masuk lewat rc_compile_upload dan berpindah status lewat beberapa fungsi lain.
-- Memasang pemeriksaan di masing-masing berarti aturan yang sama dipelihara di banyak tempat.
-- Trigger pada tabel claims berlaku untuk semua jalan sekaligus, termasuk jalan yang belum ada.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- OSC ke atas. Dipakai untuk membatalkan tanda, dan sebagai batas bawah beberapa tindakan lain.
create or replace function rc_private.is_osc_ke_atas() returns boolean
language sql stable security definer set search_path='' as $fn$
  select exists(select 1 from public.profiles p
                 where p.id=(select auth.uid()) and p.status='active'
                   and not p.must_change_password
                   and p.role in('osc','supervisor','system manager'));
$fn$;
revoke all on function rc_private.is_osc_ke_atas() from public,anon;
grant execute on function rc_private.is_osc_ke_atas() to authenticated;

-- ------------------------------------------------------------------------------------------
-- Penandaan
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_timetable_mark(
  p_depots jsonb, p_campaigns jsonb, p_tandai boolean default true, p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare n_tulis integer := 0; n_abai integer := 0; aku uuid := (select auth.uid());
begin
  if jsonb_typeof(p_depots)<>'array' or jsonb_typeof(p_campaigns)<>'array' then
    raise exception 'Depot dan campaign harus berupa daftar'; end if;

  if coalesce(p_tandai,true) then
    -- Menandai: cukup punya akses Timetable atas depot yang bersangkutan. Admin depot ikut,
    -- karena merekalah yang tahu depotnya memang tidak mengikuti campaign itu.
    if not rc_private.can_access(null,'manage_timetable') and not rc_private.is_osc_ke_atas() then
      raise exception 'Tidak punya hak menandai Not Achieved' using errcode='42501'; end if;
  else
    -- Membatalkan: minimal OSC. Membuka kembali jalan masuk klaim adalah keputusan atasan.
    if not rc_private.is_osc_ke_atas() then
      raise exception 'Hanya OSC, Supervisor atau System Manager yang dapat membatalkan tanda Not Achieved'
        using errcode='42501'; end if;
  end if;

  if coalesce(p_tandai,true) then
    -- Pasangan yang sudah punya klaim tidak ditandai: data nyata selalu mengalahkan penanda.
    select count(*) into n_abai
      from jsonb_array_elements_text(p_depots) xd
      join public.depots d on d.depot_code = btrim(xd.value)
      join jsonb_array_elements_text(p_campaigns) xc on true
      join public.campaigns c on c.campaign_code = btrim(xc.value)
     where rc_private.can_access(d.id)
       and exists(select 1 from public.claims cl
                   where cl.depot_id=d.id and cl.campaign_id=c.id and cl.archived_at is null);

    with ditulis as (
      insert into public.timetable_not_achieved(depot_id,campaign_id,marked_by,note)
      select d.id, c.id, aku, left(btrim(coalesce(p_note,'')),200)
        from jsonb_array_elements_text(p_depots) xd
        join public.depots d on d.depot_code = btrim(xd.value)
        join jsonb_array_elements_text(p_campaigns) xc on true
        join public.campaigns c on c.campaign_code = btrim(xc.value)
       where rc_private.can_access(d.id)
      on conflict(depot_id,campaign_id) do update
        set marked_by=excluded.marked_by, marked_at=now(), note=excluded.note
      returning 1)
    select count(*) into n_tulis from ditulis;
  else
    with dihapus as (
      delete from public.timetable_not_achieved na
       using public.depots d, public.campaigns c
       where na.depot_id=d.id and na.campaign_id=c.id
         and d.depot_code = any(select btrim(value) from jsonb_array_elements_text(p_depots))
         and c.campaign_code = any(select btrim(value) from jsonb_array_elements_text(p_campaigns))
         and rc_private.can_access(d.id)
      returning 1)
    select count(*) into n_tulis from dihapus;
  end if;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(aku,'timetable_marked',null,
    jsonb_build_object('tandai',coalesce(p_tandai,true),'jumlah',n_tulis));

  return jsonb_build_object('status','success','jumlah',n_tulis,
    'tertutupDataAktual',n_abai,
    'message',case when coalesce(p_tandai,true)
      then n_tulis||' pasangan ditandai Not Achieved'
      else n_tulis||' tanda Not Achieved dibatalkan' end
      || case when n_abai>0 then '. '||n_abai||' di antaranya sementara tidak berefek karena sudah ada data klaim.' else '' end);
end $fn$;
revoke all on function public.rc_timetable_mark(jsonb,jsonb,boolean,text) from public,anon;
grant execute on function public.rc_timetable_mark(jsonb,jsonb,boolean,text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Daftar untuk kartu Detail Not Achieved
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_timetable_not_achieved()
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v jsonb; nama jsonb;
begin
  if not rc_private.can_access(null) then
    raise exception 'Access denied' using errcode='42501'; end if;
  nama := rc_private.peta_nama_pelaku();
  select coalesce(jsonb_agg(x order by x->>'kodeDepot', x->>'kodeCampaign'),'[]'::jsonb) into v from (
    select jsonb_build_object(
      'kodeDepot',d.depot_code,'namaDepot',d.depot_name,'region',coalesce(d.region,''),
      'kodeCampaign',c.campaign_code,'namaCampaign',c.campaign_name,
      'ditandaiOleh',coalesce(nama->>(na.marked_by::text),''),
      'ditandaiPada',to_char(na.marked_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
      'catatan',coalesce(na.note,''),
      -- Tanda yang tertutup data nyata perlu terlihat: penandanya masih ada, tetapi tidak lagi
      -- berpengaruh, dan tanpa keterangan ini orang akan mengira penandaannya gagal.
      'adaKlaim',exists(select 1 from public.claims cl
                         where cl.depot_id=na.depot_id and cl.campaign_id=na.campaign_id
                           and cl.archived_at is null)) as x
      from public.timetable_not_achieved na
      join public.depots d on d.id=na.depot_id
      join public.campaigns c on c.id=na.campaign_id
     where rc_private.can_access(na.depot_id)) t;
  return jsonb_build_object('status','success','rows',v,
    'bolehBatalkan',rc_private.is_osc_ke_atas());
end $fn$;
revoke all on function public.rc_timetable_not_achieved() from public,anon;
grant execute on function public.rc_timetable_not_achieved() to authenticated;

-- ------------------------------------------------------------------------------------------
-- Not Achieved menolak klaim baru
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.jaga_not_achieved() returns trigger
language plpgsql security definer set search_path='' as $fn$
declare kode_d text; kode_c text;
begin
  if exists(select 1 from public.timetable_not_achieved na
             where na.depot_id = new.depot_id and na.campaign_id = new.campaign_id) then
    select d.depot_code, c.campaign_code into kode_d, kode_c
      from public.depots d, public.campaigns c
     where d.id = new.depot_id and c.id = new.campaign_id;
    raise exception
      'Depot % dan campaign % ditandai Not Achieved; klaim tidak dapat di-compile maupun di-upload. Batalkan tandanya lebih dulu lewat OSC.',
      kode_d, kode_c using errcode='P0001';
  end if;
  return new;
end $fn$;
revoke all on function rc_private.jaga_not_achieved() from public,anon;

drop trigger if exists jaga_not_achieved on public.claims;
create trigger jaga_not_achieved before insert on public.claims
  for each row execute function rc_private.jaga_not_achieved();

create or replace function rc_private.marker_20261101() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261101() from public,anon;
grant execute on function rc_private.marker_20261101() to authenticated;

select 'Aturan Not Achieved terpasang' as hasil,
 (select count(*) from public.timetable_not_achieved) as pasangan_ditandai;
