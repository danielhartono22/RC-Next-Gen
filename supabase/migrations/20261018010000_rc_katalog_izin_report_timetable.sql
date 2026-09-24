-- ==========================================================================================
-- Report dan Timetable masuk katalog izin
-- ==========================================================================================
-- Kedua permission sudah ditambahkan ke public.permissions pada 20261010010000, tetapi
-- rc_permission_catalog adalah daftar yang ditulis tangan - sehingga keduanya tidak muncul pada
-- kartu "Hak Menu Dashboard" dan tidak dapat diberikan kepada siapa pun lewat layar.
--
-- Ini konsekuensi yang memang ada dari daftar yang ditulis tangan. Membuatnya membaca
-- public.permissions secara otomatis terdengar lebih rapi, tetapi tabel itu hanya memuat kode
-- dan keterangan - tidak memuat nama modul, sub-judul, maupun urutan tampil yang dibaca layar.
-- Menurunkannya dari kode permission akan menghasilkan label seperti "view_report" di layar
-- konsol, yang justru lebih buruk. Jadi daftarnya tetap ditulis tangan, dan berkas ini yang
-- menjaganya tetap sejalan.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function public.rc_permission_catalog()
returns jsonb language plpgsql stable set search_path='' as $fn$
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 return jsonb_build_object('status','success','rows',jsonb_build_array(
  jsonb_build_object('key','j','code','upload_claim','modul','Claim Upload','sub','Mass, Manual, Open'),
  jsonb_build_object('key','k','code','release_claim','modul','Release','sub','Antrean Submitted'),
  jsonb_build_object('key','l','code','process_claim','modul','Claim Process','sub','Claim to Finance dan Clearing'),
  jsonb_build_object('key','s','code','bulk_process','modul','Bulk Process','sub','Rebate langsung Done'),
  jsonb_build_object('key','m','code','view_analytics','modul','Analytics','sub','History dan Summary'),
  jsonb_build_object('key','p','code','view_master_depot','modul','Master Depot','sub','Link master per depot'),
  jsonb_build_object('key','n','code','manage_access','modul','Kelola Akses','sub','Akun, permission, depot'),
  jsonb_build_object('key','keyMaster','code','manage_key_master','modul','Key Master','sub','Customer, Campaign, dan Depot Master'),
  jsonb_build_object('key','compilation','code','view_compilation','modul','Cashback Compilation','sub','Lihat dan compile'),
  jsonb_build_object('key','archiveCompilation','code','archive_compilation','modul','Cashback Compilation','sub','Arsipkan baris'),
  jsonb_build_object('key','report','code','view_report','modul','Report','sub','Dashboard, Cost Center 1 dan 2'),
  jsonb_build_object('key','timetable','code','manage_timetable','modul','Timetable','sub','Tandai Not Achieved dan exclude campaign'),
  jsonb_build_object('key','logs','code','view_logs','modul','Log Aktivitas','sub','Riwayat tindakan')));
end $fn$;

-- Huruf kunci baru harus dikenali juga oleh penyimpan akses; tanpa ini, menyalakan Report di
-- layar tidak akan pernah tersimpan.
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

  v_role:=lower(btrim(coalesce(p_payload->>'role','')));
  if v_role<>'' and v_role<>v_role_lama then
    perform rc_private.set_role(v_target,v_role);
  else
    v_role:=v_role_lama;
  end if;

  if coalesce(btrim(p_payload->>'suffix'),'')<>'' then
    perform rc_private.set_suffix(v_kode,btrim(p_payload->>'suffix'));
  end if;

  if coalesce(btrim(p_payload->>'fullName'),'')<>'' then
    update public.profiles set full_name=btrim(p_payload->>'fullName') where id=v_target;
  end if;
  if coalesce(btrim(p_payload->>'email'),'')<>'' then
    update public.profiles set business_email=lower(btrim(p_payload->>'email')) where id=v_target;
  end if;

  v_status:=case when lower(coalesce(p_payload->'auth'->>'i','')) in('active','approved','ok')
                 then 'active' else 'inactive' end;

  if v_role='system manager' then
    delete from public.user_depot_grants where user_id=v_target;
    delete from public.user_supervision where supervisor_id=v_target;
  else
    if p_payload ? 'homeDepot' then
      delete from public.user_depot_grants where user_id=v_target and kind='home';
      if coalesce(btrim(p_payload->>'homeDepot'),'')<>'' then
        v_depot:=public.rc_legacy_depot_id(btrim(p_payload->>'homeDepot'));
        insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
        values(v_target,v_depot,'home',(select auth.uid()))
        on conflict(user_id,depot_id) do update set kind='home';
      end if;
    end if;

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

  if v_role='system manager' then
    v_perms:=array(select code from public.permissions);
  else
    v_perms:=array(select code from (values
      ('j','upload_claim'),('k','release_claim'),('l','process_claim'),('m','view_analytics'),
      ('n','manage_access'),('p','view_master_depot'),('s','bulk_process'),('logs','view_logs'),
      ('keyMaster','manage_key_master'),('compilation','view_compilation'),
      ('archiveCompilation','archive_compilation'),
      -- Dua kunci baru. Tanpa baris ini, menyalakan Report atau Timetable di layar akan
      -- tersimpan sebagai "tidak diberikan", dan modulnya tidak pernah muncul.
      ('report','view_report'),('timetable','manage_timetable')
    ) as m(letter,code)
    where lower(coalesce(p_payload->'auth'->>m.letter,'no')) in('yes','true','approved','visible'));
  end if;

  delete from public.user_permissions where user_id=v_target;
  insert into public.user_permissions select v_target,x from unnest(v_perms) x group by x;
  update public.profiles set status=v_status where id=v_target;

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

-- legacy_users juga perlu melaporkan kedua flag baru, supaya select-nya terbuka pada nilai yang
-- benar dan bukan pada default markup.
create or replace function rc_private.legacy_users()
returns jsonb language sql stable security definer set search_path='' as $fn$
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',p.id,'userId',p.user_code,
   'nama',p.full_name,'namaLengkap',p.full_name,'fullName',p.full_name,
   'email',p.business_email,
   'role',p.role,'sysRole',p.role,'suffix',p.suffix_num,
   'activation',case p.status when 'active' then 'Active' when 'pending' then 'Pending'
     when 'rejected' then 'Rejected' else 'Nonactive' end,
   'mustChangePin',p.must_change_password,
   'requestedRole',coalesce(p.requested_role,''),'requestedDepot',coalesce(p.requested_depot,''),
   'permissions',array(select permission_code from public.user_permissions where user_id=p.id),
   'auth',(select jsonb_object_agg(m.letter,
             case when exists(select 1 from public.user_permissions up
                               where up.user_id=p.id and up.permission_code=m.code)
                  then 'Yes' else 'No' end)
           from (values ('j','upload_claim'),('k','release_claim'),('l','process_claim'),
                        ('m','view_analytics'),('n','manage_access'),('p','view_master_depot'),
                        ('s','bulk_process'),('logs','view_logs'),('keyMaster','manage_key_master'),
                        ('compilation','view_compilation'),('archiveCompilation','archive_compilation'),
                        ('report','view_report'),('timetable','manage_timetable')
                ) as m(letter,code))
         || jsonb_build_object('i',case p.status when 'active' then 'Active' else 'Inactive' end),
   'kodeDepot',coalesce((select d.depot_code from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='home' limit 1),''),
   'namaDepot',coalesce((select d.depot_name from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='home' limit 1),''),
   'depotName',coalesce((select d.depot_name from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='home' limit 1),''),
   'rpDepots',array(select d.depot_code from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='rp' order by d.depot_code),
   'assignedDepots',array(select d.depot_code from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='assigned' order by d.depot_code),
   'assignedOsc',array(select o.user_code from public.user_supervision s
      join public.profiles o on o.id=s.osc_id where s.supervisor_id=p.id order by o.user_code),
   'depotCodes',array(select d.depot_code from public.user_depot_access a
      join public.depots d on d.id=a.depot_id where a.user_id=p.id order by d.depot_code),
   'depotIds',array(select depot_id from public.user_depot_access where user_id=p.id))
   order by p.status,p.user_code),'[]'::jsonb)
 from public.profiles p
 where rc_private.can_manage_user(p.id) or p.id=(select auth.uid());
$fn$;

create or replace function rc_private.marker_20261018() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261018() from public,anon;
grant execute on function rc_private.marker_20261018() to authenticated;

select 'Report dan Timetable masuk katalog izin' as hasil,
 (select count(*) from public.permissions) as permission_di_master,
 (select count(*) from public.permissions where code in('view_report','manage_timetable')) as dua_izin_baru,
 -- Katalognya sendiri tidak dipanggil di sini: ia menuntut sesi pengguna, sedangkan migration
 -- berjalan tanpa sesi. Isinya diperiksa dari layar setelah login.
 'Buka Kelola Akses untuk melihat dua modul baru pada Hak Menu Dashboard' as langkah_berikutnya;
