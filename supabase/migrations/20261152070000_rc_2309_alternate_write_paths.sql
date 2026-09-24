-- Cover remaining alternate write paths with the same tab grants.
CREATE OR REPLACE FUNCTION public.rc_account_restore(p_id uuid, p_alasan text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.profiles%rowtype; aku uuid := (select auth.uid()); v_kode text; v_teracak boolean;
begin
 perform rc_private.require_tab('access.arsip');
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat mengaktifkan kembali akun' using errcode='42501'; end if;
  select * into v from public.profiles where id = p_id for update;
  if not found then raise exception 'Akun tidak ditemukan'; end if;
  if v.status <> 'deleted' then raise exception 'Akun ini tidak ada di Arsip Hapus'; end if;

  v_kode := coalesce(nullif(btrim(v.archived_user_code),''), v.user_code);
  if exists(select 1 from public.profiles q
             where q.id <> v.id and q.status <> 'deleted' and upper(q.user_code) = upper(v_kode)) then
    raise exception 'User ID "%" sekarang dipakai akun lain; ganti dulu salah satunya', v_kode;
  end if;

  update public.profiles
     set status = 'active',
         user_code = v_kode,
         archived_user_code = null, archived_at = null, archived_by = null,
         review_note = left('Diaktifkan kembali. ' || btrim(coalesce(p_alasan,'')), 300)
   where id = v.id;

  -- Alamat login dipulihkan HANYA bila ia teracak oleh versi kemarin (berawalan "dihapus-").
  -- Alamat itu diturunkan dari SHA-256 User ID PERSIS SEPERTI YANG DIKETIK orangnya, bukan dari
  -- user_code di tabel ini. Pemeriksaan atas akun yang ada memperlihatkan keempatnya mengetik
  -- dengan huruf kecil, jadi bentuk itulah yang dipakai membangun ulang - sebuah DUGAAN yang
  -- dinyatakan terbuka pada pesan balasan, bukan diam-diam. Akun yang alamatnya tidak teracak
  -- tidak disentuh sama sekali, karena menimpanya justru akan mematikan login yang masih sehat.
  update auth.users
     set banned_until = null,
         email = case when email like 'dihapus-%'
                   then encode(extensions.digest(lower(v_kode),'sha256'),'hex') || '@rc-login.invalid'
                   else email end
   where id = v.id;
  select (email like 'dihapus-%') into v_teracak from auth.users where id = v.id;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(aku,'akun_dipulihkan',v.id,jsonb_build_object(
    'userCode',v_kode,'nama',v.full_name,'alasan',left(btrim(coalesce(p_alasan,'')),300)));

  return jsonb_build_object('status','success','userId',v_kode,'alamatDibangunUlang',coalesce(v_teracak,false),
    'message','Akun ' || v_kode || ' aktif kembali dan dapat masuk memakai PIN lamanya. '
      || 'Izin dan depotnya TIDAK ikut kembali - berikan lagi lewat tombol Kelola.');
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_campaign_memo_clear(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ca public.campaigns%rowtype; aku uuid:=(select auth.uid());
begin
 perform rc_private.require_tab('keyMaster.campaign');
 if not rc_private.can_access(null,'manage_key_master') then
  raise exception 'Tidak punya hak mengubah Key Master' using errcode='42501'; end if;
 select * into ca from public.campaigns where upper(campaign_code)=upper(btrim(coalesce(p_code,'')));
 if not found then raise exception 'Campaign % tidak ditemukan', p_code; end if;
 update public.campaigns set memo_path=null, memo_name=null, memo_size=null,
   memo_uploaded_at=null, memo_uploaded_by=null where id=ca.id;
 insert into public.activity_logs(actor_id,event_type,details)
 values(aku,'campaign_memo_clear',jsonb_build_object('kode',ca.campaign_code));
 return jsonb_build_object('status','success','message','Memo dilepas','path',coalesce(ca.memo_path,''));
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_campaign_memo_set(p_code text, p_path text, p_name text, p_size integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ca public.campaigns%rowtype; aku uuid:=(select auth.uid());
begin
 perform rc_private.require_tab('keyMaster.campaign');
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
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_request_profile(p_depot uuid, p_changes jsonb)
 RETURNS uuid
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select rc_private.require_tab('profile.edit');select rc_private.profile_request(p_depot,p_changes);$function$
;
CREATE OR REPLACE FUNCTION public.rc_timetable_mark(p_depots jsonb, p_campaigns jsonb, p_tandai boolean DEFAULT true, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n_tulis integer := 0; n_abai integer := 0; aku uuid := (select auth.uid());
begin
 perform rc_private.require_tab('timetable.matrix');
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
end $function$
;
notify pgrst,'reload schema';
