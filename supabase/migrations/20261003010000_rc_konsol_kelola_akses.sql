-- ==========================================================================================
-- Konsol Kelola Akses: nama field yang benar, dan satu RPC yang benar-benar menyimpan
-- ==========================================================================================
-- Lanjutan dari 20261002010000, yang memasang model yurisdiksinya. Berkas ini menyambungkan
-- model itu ke layar.
--
-- MENGAPA MENGGANTI RPC-NYA, BUKAN MENAMBALNYA
-- rc_legacy_update_access menerima lima parameter posisional (kode, auth, depot, suffix, role).
-- Spesifikasi baru membutuhkan enam hal lagi: depot asal, daftar Resource Partner, daftar
-- depot assignment, daftar OSC yang disupervisi, persetujuan ganti PIN, dan identitas.
-- Menambahkannya sebagai parameter baru akan membuat dua fungsi bernama sama dengan jumlah
-- argumen berbeda, dan PostgREST tidak bisa memilih di antaranya. Karena itu ada satu RPC
-- baru yang menerima satu objek JSON, dan fungsi lama tetap ada sebagai pembungkus tipis
-- supaya pemanggil lama tidak patah.
--
-- DUA KESALAHAN NAMA FIELD YANG MEMBUAT KOLOM KOSONG
-- Layar membaca u.namaLengkap dan u.kodeDepot. Server mengirim nama dan depotCodes. Keduanya
-- kini dikirim dengan nama yang dibaca layar, tanpa menghapus nama lama supaya tidak ada
-- pemakai lain yang patah.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Daftar pengguna untuk konsol
-- ------------------------------------------------------------------------------------------
-- Selain memperbaiki nama field, daftarnya kini dibatasi pada pengguna yang memang boleh
-- dikelola pemanggil. Seorang supervisor tidak lagi melihat nama orang di luar wilayahnya.
create or replace function rc_private.legacy_users()
returns jsonb language sql stable security definer set search_path='' as $fn$
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',p.id,'userId',p.user_code,
   -- Nama lama dipertahankan, nama yang dibaca layar ditambahkan.
   'nama',p.full_name,'namaLengkap',p.full_name,'fullName',p.full_name,
   'email',p.business_email,
   'role',p.role,'sysRole',p.role,'suffix',p.suffix_num,
   'activation',case p.status when 'active' then 'Active' when 'pending' then 'Pending'
     when 'rejected' then 'Rejected' else 'Nonactive' end,
   'mustChangePin',p.must_change_password,
   'requestedRole',coalesce(p.requested_role,''),'requestedDepot',coalesce(p.requested_depot,''),
   'permissions',array(select permission_code from public.user_permissions where user_id=p.id),
   'auth',jsonb_build_object(
     'i',case p.status when 'active' then 'Active' else 'Inactive' end,
     'j',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='upload_claim') then 'Yes' else 'No' end,
     'k',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='release_claim') then 'Yes' else 'No' end,
     'l',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='process_claim') then 'Yes' else 'No' end,
     'm',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='view_analytics') then 'Yes' else 'No' end,
     'n',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='manage_access') then 'Yes' else 'No' end,
     'p',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='view_master_depot') then 'Yes' else 'No' end,
     's',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='bulk_process') then 'Yes' else 'No' end,
     'logs',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='view_logs') then 'Yes' else 'No' end,
     'keyMaster',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='manage_key_master') then 'Yes' else 'No' end,
     'compilation',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='view_compilation') then 'Yes' else 'No' end,
     'archiveCompilation',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='archive_compilation') then 'Yes' else 'No' end),
   -- Depot asal, dipakai layar sebagai identitas pada kolom Depot.
   'kodeDepot',coalesce((select d.depot_code from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='home' limit 1),''),
   'namaDepot',coalesce((select d.depot_name from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='home' limit 1),''),
   'depotName',coalesce((select d.depot_name from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='home' limit 1),''),
   -- Tiga daftar yang kini berdiri sendiri di layar.
   'rpDepots',array(select d.depot_code from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='rp' order by d.depot_code),
   'assignedDepots',array(select d.depot_code from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='assigned' order by d.depot_code),
   'assignedOsc',array(select o.user_code from public.user_supervision s
      join public.profiles o on o.id=s.osc_id where s.supervisor_id=p.id order by o.user_code),
   -- Yurisdiksi yang benar-benar berlaku sesudah semuanya dihitung.
   'depotCodes',array(select d.depot_code from public.user_depot_access a
      join public.depots d on d.id=a.depot_id where a.user_id=p.id order by d.depot_code),
   'depotIds',array(select depot_id from public.user_depot_access where user_id=p.id))
   order by p.status,p.user_code),'[]'::jsonb)
 from public.profiles p
 where rc_private.can_manage_user(p.id) or p.id=(select auth.uid());
$fn$;

-- ------------------------------------------------------------------------------------------
-- 2. Satu RPC yang menyimpan seluruh isi konsol
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_update_access(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_target uuid; v_kode text; v_role text; v_role_lama text; v_status text;
  v_perms text[]; v_depot uuid; c text; n_rp int:=0; n_as int:=0; n_osc int:=0;
begin
  if not rc_private.is_manager() then
    raise exception 'Hanya System Manager atau Supervisor yang dapat mengubah akses'
      using errcode='42501'; end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then
    raise exception 'Payload tidak sah'; end if;

  v_kode:=upper(btrim(coalesce(p_payload->>'userId','')));
  if v_kode='' then raise exception 'User ID wajib diisi'; end if;
  select id, role into v_target, v_role_lama from public.profiles where user_code=v_kode;
  if v_target is null then
    raise exception 'Pengguna "%" tidak ada di daftar akun',v_kode; end if;
  if not rc_private.can_manage_user(v_target) then
    raise exception 'Pengguna "%" berada di luar wilayah Anda',v_kode using errcode='42501'; end if;
  if v_target=(select auth.uid()) then
    raise exception 'Tidak dapat mengubah akses sendiri'; end if;
  if (select status from public.profiles where id=v_target)='pending' then
    raise exception 'Setujui pendaftaran ini lebih dahulu di kotak masuk approval'; end if;

  -- Peran lebih dulu, karena peran menentukan bentuk yurisdiksi yang sah.
  v_role:=lower(btrim(coalesce(p_payload->>'role','')));
  if v_role<>'' and v_role<>v_role_lama then
    perform rc_private.set_role(v_target,v_role);
  else
    v_role:=v_role_lama;
  end if;

  if coalesce(btrim(p_payload->>'suffix'),'')<>'' then
    perform rc_private.set_suffix(v_kode,btrim(p_payload->>'suffix'));
  end if;

  -- Identitas. Nama dan email boleh dikoreksi oleh pengelola; kode pengguna tidak, karena ia
  -- adalah kunci login dan mengubahnya akan memutus akun dari riwayatnya.
  if coalesce(btrim(p_payload->>'fullName'),'')<>'' then
    update public.profiles set full_name=btrim(p_payload->>'fullName') where id=v_target;
  end if;
  if coalesce(btrim(p_payload->>'email'),'')<>'' then
    update public.profiles set business_email=lower(btrim(p_payload->>'email')) where id=v_target;
  end if;

  v_status:=case when lower(coalesce(p_payload->'auth'->>'i','')) in('active','approved','ok')
                 then 'active' else 'inactive' end;

  -- ---- Yurisdiksi -------------------------------------------------------------------------
  -- System Manager tidak pernah diberi yurisdiksi: perannya sudah mencakup seluruh depot,
  -- dan memberinya baris grant hanya akan menyesatkan pembaca konsol.
  if v_role='system manager' then
    delete from public.user_depot_grants where user_id=v_target;
    delete from public.user_supervision where supervisor_id=v_target;
  else
    -- Depot asal. Kunci ada berarti "ganti"; kunci tidak ada berarti "biarkan".
    if p_payload ? 'homeDepot' then
      delete from public.user_depot_grants where user_id=v_target and kind='home';
      if coalesce(btrim(p_payload->>'homeDepot'),'')<>'' then
        v_depot:=public.rc_legacy_depot_id(btrim(p_payload->>'homeDepot'));
        insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
        values(v_target,v_depot,'home',(select auth.uid()))
        on conflict(user_id,depot_id) do update set kind='home';
      end if;
    end if;

    -- Resource Partner: depot lain yang ditagging ke seorang admin. Depot yang ditagging
    -- menjadi haknya sepenuhnya, sama seperti depot asalnya.
    if p_payload ? 'rpDepots' then
      delete from public.user_depot_grants where user_id=v_target and kind='rp';
      for c in select jsonb_array_elements_text(p_payload->'rpDepots') loop
        if btrim(c)<>'' then
          v_depot:=public.rc_legacy_depot_id(btrim(c));
          insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
          values(v_target,v_depot,'rp',(select auth.uid()))
          on conflict(user_id,depot_id) do nothing;
          n_rp:=n_rp+1;
        end if;
      end loop;
    end if;

    if p_payload ? 'assignedDepots' then
      delete from public.user_depot_grants where user_id=v_target and kind='assigned';
      for c in select jsonb_array_elements_text(p_payload->'assignedDepots') loop
        if btrim(c)<>'' then
          v_depot:=public.rc_legacy_depot_id(btrim(c));
          insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
          values(v_target,v_depot,'assigned',(select auth.uid()))
          on conflict(user_id,depot_id) do nothing;
          n_as:=n_as+1;
        end if;
      end loop;
    end if;

    -- Supervisi: seorang supervisor mewarisi seluruh depot milik OSC yang ia pegang.
    if p_payload ? 'assignedOsc' then
      delete from public.user_supervision where supervisor_id=v_target;
      for c in select jsonb_array_elements_text(p_payload->'assignedOsc') loop
        if btrim(c)<>'' then
          insert into public.user_supervision(supervisor_id,osc_id)
          select v_target,id from public.profiles where user_code=upper(btrim(c)) and id<>v_target
          on conflict do nothing;
          n_osc:=n_osc+1;
        end if;
      end loop;
    end if;
  end if;

  -- ---- Hak modul --------------------------------------------------------------------------
  if v_role='system manager' then
    v_perms:=array(select code from public.permissions);
  else
    v_perms:=array(select code from (values
      ('j','upload_claim'),('k','release_claim'),('l','process_claim'),('m','view_analytics'),
      ('n','manage_access'),('p','view_master_depot'),('s','bulk_process'),('logs','view_logs'),
      ('keyMaster','manage_key_master'),('compilation','view_compilation'),
      ('archiveCompilation','archive_compilation')
    ) as m(letter,code)
    where lower(coalesce(p_payload->'auth'->>m.letter,'no')) in('yes','true','approved','visible'));
  end if;

  delete from public.user_permissions where user_id=v_target;
  insert into public.user_permissions select v_target,x from unnest(v_perms) x group by x;
  update public.profiles set status=v_status where id=v_target;

  -- Yurisdiksi yang berlaku dihitung ulang dari grant dan supervisi.
  perform rc_private.rebuild_with_supervisors(v_target);

  if coalesce((p_payload->>'approvePin')::boolean,false) then
    update public.profiles set must_change_password=true where id=v_target;
  end if;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'access_changed',v_target,jsonb_build_object(
    'status',v_status,'role',v_role,'permissions',coalesce(array_length(v_perms,1),0),
    'rp',n_rp,'assigned',n_as,'osc',n_osc));

  return jsonb_build_object('status','success','role',v_role,
    'jumlahPermission',coalesce(array_length(v_perms,1),0),
    'jumlahDepot',(select count(*) from public.user_depot_access where user_id=v_target),
    'pesan','Akses '||v_kode||' berhasil diperbarui');
end $fn$;
revoke all on function public.rc_update_access(jsonb) from public,anon;
grant execute on function public.rc_update_access(jsonb) to authenticated;

-- Pembungkus tipis supaya pemanggil lama tetap jalan.
create or replace function public.rc_legacy_update_access(
  p_user_code text, p_auth jsonb, p_depot_codes text default null,
  p_suffix text default null, p_role text default null)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare payload jsonb;
begin
  payload:=jsonb_build_object('userId',p_user_code,'auth',coalesce(p_auth,'{}'::jsonb));
  if p_suffix is not null then payload:=payload||jsonb_build_object('suffix',p_suffix); end if;
  if p_role   is not null then payload:=payload||jsonb_build_object('role',p_role); end if;
  if p_depot_codes is not null then
    payload:=payload||jsonb_build_object('assignedDepots',
      coalesce((select jsonb_agg(btrim(x)) from unnest(string_to_array(p_depot_codes,',')) x
                 where btrim(x)<>''),'[]'::jsonb));
  end if;
  return public.rc_update_access(payload);
end $fn$;
revoke all on function public.rc_legacy_update_access(text,jsonb,text,text,text) from public,anon;
grant execute on function public.rc_legacy_update_access(text,jsonb,text,text,text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Konsol melaporkan wewenang pemanggil dengan jujur
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_legacy_manageable()
returns jsonb language plpgsql stable set search_path='' as $fn$
begin
 if not rc_private.is_manager() then
   raise exception 'Manager required' using errcode='42501'; end if;
 return jsonb_build_object('status','success',
  'users',rc_private.legacy_users(),
  'allDepots',rc_private.legacy_all_depots(),
  'managedDepots',rc_private.legacy_all_depots(),
  'isSystemManager',rc_private.is_system_manager(),
  'profileRequests',rc_private.legacy_profile_requests());
end $fn$;

create or replace function rc_private.marker_20261003() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261003() from public,anon;
grant execute on function rc_private.marker_20261003() to authenticated;

select 'Konsol Kelola Akses tersambung' as hasil,
 (select count(*) from public.profiles) as jumlah_akun,
 (select count(*) from public.permissions) as jumlah_permission;
