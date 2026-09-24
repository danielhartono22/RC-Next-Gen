-- One catalog for tab rendering and database enforcement.
insert into public.permissions(code,description) values('view_people','People Performance') on conflict(code) do update set description=excluded.description;
insert into public.user_permissions(user_id,permission_code) select id,'view_people' from public.profiles where role in('osc','supervisor','system manager') and status='active' on conflict do nothing;
create table if not exists rc_private.tab_catalog(code text primary key,module text not null,label text not null,permission text,key text not null,tab text not null,title text not null);
create table if not exists rc_private.user_tab_access(user_id uuid references public.profiles(id) on delete cascade,tab_code text references rc_private.tab_catalog(code),allowed boolean not null,primary key(user_id,tab_code));
revoke all on rc_private.tab_catalog,rc_private.user_tab_access from public,anon,authenticated;
insert into rc_private.tab_catalog select * from jsonb_to_recordset('[{"code":"upload.mass","module":"upload","label":"Claim Upload","permission":"upload_claim","key":"j","tab":"mass","title":"Mass Upload"},{"code":"upload.single","module":"upload","label":"Claim Upload","permission":"upload_claim","key":"j","tab":"single","title":"Manual Upload"},{"code":"upload.open","module":"upload","label":"Claim Upload","permission":"upload_claim","key":"j","tab":"open","title":"Open"},{"code":"release.list","module":"release","label":"Release","permission":"release_claim","key":"k","tab":"list","title":"Release"},{"code":"process.claimFin","module":"process","label":"Claim Process","permission":"process_claim","key":"l","tab":"claimFin","title":"Claim to Finance"},{"code":"process.clearing","module":"process","label":"Claim Process","permission":"process_claim","key":"l","tab":"clearing","title":"Clearing"},{"code":"bulk.rebate","module":"bulk","label":"Bulk Process","permission":"bulk_process","key":"s","tab":"rebate","title":"Rebate"},{"code":"analytics.history","module":"analytics","label":"Analytics","permission":"view_analytics","key":"m","tab":"history","title":"Cashback List"},{"code":"analytics.summary","module":"analytics","label":"Analytics","permission":"view_analytics","key":"m","tab":"summary","title":"Summary"},{"code":"approval.wpt","module":"approval","label":"Management of Approval","permission":"approve_claim","key":"approval","tab":"wpt","title":"Within Payment Term"},{"code":"approval.ovd","module":"approval","label":"Management of Approval","permission":"approve_claim","key":"approval","tab":"ovd","title":"Overdue"},{"code":"approval.hold","module":"approval","label":"Management of Approval","permission":"approve_claim","key":"approval","tab":"hold","title":"Hold / Expired"},{"code":"approval.history","module":"approval","label":"Management of Approval","permission":"approve_claim","key":"approval","tab":"history","title":"History"},{"code":"keyMaster.customer","module":"keyMaster","label":"Key Master","permission":"manage_key_master","key":"keyMaster","tab":"customer","title":"Customer Master"},{"code":"keyMaster.campaign","module":"keyMaster","label":"Key Master","permission":"manage_key_master","key":"keyMaster","tab":"campaign","title":"Campaign Master"},{"code":"keyMaster.depot","module":"keyMaster","label":"Key Master","permission":"manage_key_master","key":"keyMaster","tab":"depot","title":"Depot Master"},{"code":"compilation.list","module":"compilation","label":"Document Center","permission":"view_compilation","key":"compilation","tab":"list","title":"Cashback List"},{"code":"compilation.compile","module":"compilation","label":"Document Center","permission":"view_compilation","key":"compilation","tab":"compile","title":"Compile"},{"code":"compilation.reprocess","module":"compilation","label":"Document Center","permission":"view_compilation","key":"compilation","tab":"reprocess","title":"Reprocessing"},{"code":"compilation.archive","module":"compilation","label":"Document Center","permission":"view_compilation","key":"compilation","tab":"archive","title":"Archive"},{"code":"report.dashboard","module":"report","label":"Report","permission":"view_report","key":"report","tab":"dashboard","title":"Dashboard"},{"code":"report.cc1","module":"report","label":"Report","permission":"view_report","key":"report","tab":"cc1","title":"Cost Center 1"},{"code":"report.cc2","module":"report","label":"Report","permission":"view_report","key":"report","tab":"cc2","title":"Cost Center 2"},{"code":"timetable.matrix","module":"timetable","label":"Timetable","permission":"manage_timetable","key":"timetable","tab":"matrix","title":"Timetable"},{"code":"access.list","module":"access","label":"Access Management","permission":"manage_access","key":"n","tab":"list","title":"Daftar User"},{"code":"access.add","module":"access","label":"Access Management","permission":"manage_access","key":"n","tab":"add","title":"Registrasi / Upload User"},{"code":"access.req","module":"access","label":"Access Management","permission":"manage_access","key":"n","tab":"req","title":"Approval Request"},{"code":"access.email","module":"access","label":"Access Management","permission":"manage_access","key":"n","tab":"email","title":"Email Otomatis"},{"code":"access.exclude","module":"access","label":"Access Management","permission":"manage_access","key":"n","tab":"exclude","title":"Exclude Campaign"},{"code":"access.arsip","module":"access","label":"Access Management","permission":"manage_access","key":"n","tab":"arsip","title":"Arsip User"},{"code":"access.grade","module":"access","label":"Access Management","permission":"manage_access","key":"n","tab":"grade","title":"Grade Depot"},{"code":"logs.list","module":"logs","label":"Log Activity","permission":"view_logs","key":"logs","tab":"list","title":"Log Activity"},{"code":"profile.view","module":"profile","label":"Profil Depot","permission":null,"key":"profile","tab":"view","title":"Profil"},{"code":"profile.edit","module":"profile","label":"Profil Depot","permission":null,"key":"profile","tab":"edit","title":"Ajukan Perubahan"},{"code":"people.osc","module":"people","label":"People Performance","permission":"view_people","key":"people","tab":"osc","title":"OSC"},{"code":"people.supervisor","module":"people","label":"People Performance","permission":"view_people","key":"people","tab":"supervisor","title":"Supervisor"}]'::jsonb) as t(code text,module text,label text,permission text,key text,tab text,title text)
on conflict(code) do update set module=excluded.module,label=excluded.label,permission=excluded.permission,key=excluded.key,tab=excluded.tab,title=excluded.title;

create or replace function rc_private.tab_rights(p_user uuid) returns jsonb language sql stable security definer set search_path='' as $$
select coalesce(jsonb_object_agg(t.code,p.role='system manager' or
 ((t.permission is null or p.role in('depot head','management') or (t.module='access' and p.role='supervisor')
 or exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code=t.permission))
 and coalesce(u.allowed,true))),'{}') from rc_private.tab_catalog t cross join public.profiles p
left join rc_private.user_tab_access u on u.user_id=p.id and u.tab_code=t.code where p.id=p_user and (p.id=auth.uid() or rc_private.can_view_managed_user(p.id)); $$;
create or replace function rc_private.can_tab(p_tab text) returns boolean language sql stable security definer set search_path='' as $$
select rc_private.can_access(null) and coalesce((rc_private.tab_rights(auth.uid())->>p_tab)::boolean,false); $$;
create or replace function rc_private.require_tab(p_tab text) returns void language plpgsql stable security definer set search_path='' as $$
begin if not rc_private.can_tab(p_tab) then raise exception 'Akses tab % tidak diizinkan',p_tab using errcode='42501';end if;end $$;
revoke all on function rc_private.tab_rights(uuid),rc_private.can_tab(text),rc_private.require_tab(text) from public,anon;
grant execute on function rc_private.tab_rights(uuid),rc_private.can_tab(text),rc_private.require_tab(text) to authenticated;

create or replace function rc_private.save_tab_access(p_user uuid,p_tabs jsonb) returns void language plpgsql security definer set search_path='' as $$
declare r record;begin
 if not rc_private.is_manager() or not rc_private.can_manage_user(p_user) or p_user=auth.uid() then raise exception 'Access denied' using errcode='42501';end if;
 if jsonb_typeof(p_tabs)<>'object' then raise exception 'Izin tab harus berupa objek';end if;
 for r in select key,value from jsonb_each(p_tabs) loop
  if jsonb_typeof(r.value)<>'boolean' or not exists(select 1 from rc_private.tab_catalog where code=r.key) then raise exception 'Izin tab tidak valid: %',r.key;end if;
  insert into rc_private.user_tab_access values(p_user,r.key,(r.value::text)::boolean) on conflict(user_id,tab_code) do update set allowed=excluded.allowed;
 end loop;
end $$;
revoke all on function rc_private.save_tab_access(uuid,jsonb) from public,anon,authenticated;

create or replace function public.rc_permission_catalog() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501';end if;
return jsonb_build_object('status','success','rows',(select jsonb_agg(jsonb_build_object('key',t.key,'code',t.permission,'modul',t.label,'sub','Izin modul dan tab',
'tabs',(select jsonb_agg(jsonb_build_object('code',x.code,'title',x.title) order by x.code) from rc_private.tab_catalog x where x.module=t.module)) order by t.label)
from (select distinct module,label,permission,key from rc_private.tab_catalog) t));end $$;
CREATE OR REPLACE FUNCTION public.rc_update_access(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_target uuid; v_kode text; v_role text; v_role_lama text; v_status text;
  v_perms text[]; v_depot uuid; c text; n_rp int:=0; n_as int:=0; n_osc int:=0;
  v_tersisip int;
  v_diri boolean;
begin
  if not rc_private.is_manager() then
    raise exception 'Hanya System Manager atau Supervisor yang dapat mengubah akses'
      using errcode='42501'; end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then
    raise exception 'Payload tidak sah'; end if;

  v_kode:=upper(btrim(coalesce(p_payload->>'userId','')));
  if v_kode='' then raise exception 'User ID wajib diisi'; end if;
  select id, role into v_target, v_role_lama from public.profiles where user_code=v_kode for update;
  if v_target is null then
    raise exception 'Pengguna "%" tidak ada di daftar akun',v_kode; end if;

  v_diri := (v_target = (select auth.uid()));

  -- Menyunting diri sendiri kini diizinkan, tetapi HANYA untuk System Manager dan HANYA pada
  -- bagian identitas. Seorang supervisor tetap tidak dapat menyunting dirinya sendiri.
  if v_diri and not rc_private.is_system_manager() then
    raise exception 'Tidak dapat mengubah akses sendiri'; end if;
  if not v_diri and not rc_private.can_manage_user(v_target) then
    raise exception 'Pengguna "%" berada di luar wilayah Anda',v_kode using errcode='42501'; end if;
  if (select status from public.profiles where id=v_target)='pending' then
    raise exception 'Setujui pendaftaran ini lebih dahulu di kotak masuk approval'; end if;

  -- Validate every proposed scope before any write, including direct RPC callers.
  if not v_diri then
   for c in select value from jsonb_array_elements_text(coalesce(p_payload->'rpDepots','[]')||coalesce(p_payload->'assignedDepots','[]')) loop
    v_depot:=public.rc_legacy_depot_id(btrim(c));
    if v_depot is null or not rc_private.can_access(v_depot) then raise exception 'Depot di luar yurisdiksi Anda' using errcode='42501'; end if;
   end loop;
   for c in select jsonb_array_elements_text(coalesce(p_payload->'assignedOsc','[]')) loop
    if not exists(select 1 from public.profiles p where p.user_code=upper(btrim(c)) and p.role='osc' and p.status='active' and rc_private.can_manage_user(p.id)) then
     raise exception 'OSC tidak valid atau di luar yurisdiksi Anda' using errcode='42501'; end if;
   end loop;
  end if;
  -- ---- Identitas, satu-satunya bagian yang boleh disunting atas diri sendiri --------------
  if coalesce(btrim(p_payload->>'fullName'),'')<>'' then
    update public.profiles set full_name=btrim(p_payload->>'fullName') where id=v_target;
  end if;
  if coalesce(btrim(p_payload->>'email'),'')<>'' then
    update public.profiles set business_email=lower(btrim(p_payload->>'email')) where id=v_target;
  end if;
  if coalesce(btrim(p_payload->>'suffix'),'')<>'' then
    perform rc_private.set_suffix(v_kode,btrim(p_payload->>'suffix'));
  end if;

  if v_diri then
    -- Berhenti di sini. Peran, status, hak modul dan yurisdiksi sendiri tidak disentuh sama
    -- sekali, sehingga tidak ada jalan untuk mengunci diri keluar lewat layar ini.
    insert into public.activity_logs(actor_id,event_type,entity_id,details)
    values((select auth.uid()),'identity_self_updated',v_target,
           jsonb_build_object('user',v_kode));
    return jsonb_build_object('status','success','role',v_role_lama,
      'jumlahPermission',(select count(*) from public.user_permissions where user_id=v_target),
      'jumlahDepot',(select count(*) from public.user_depot_access where user_id=v_target),
      'pesan','Identitas Anda diperbarui. Peran, hak modul dan yurisdiksi sendiri sengaja tidak dapat diubah dari sini.');
  end if;

  -- ---- Selebihnya hanya berlaku untuk pengguna lain ----------------------------------------
  v_role:=lower(btrim(coalesce(p_payload->>'role','')));
  if v_role<>'' and v_role<>v_role_lama then
    perform rc_private.set_role(v_target,v_role);
  else
    v_role:=v_role_lama;
  end if;

  v_status:=case when not coalesce(p_payload->'auth','{}') ? 'i' then (select status from public.profiles where id=v_target)
    when lower(coalesce(p_payload->'auth'->>'i','')) in('active','approved','ok') then 'active' else 'inactive' end;
  if v_role<>'admin' and jsonb_array_length(coalesce(p_payload->'rpDepots','[]'))>0 then raise exception 'RP hanya untuk Admin'; end if;
  if v_role not in('osc','others','finance','depot head') and jsonb_array_length(coalesce(p_payload->'assignedDepots','[]'))>0 then raise exception 'Mapping depot tidak sesuai role'; end if;
  if v_role<>'supervisor' and jsonb_array_length(coalesce(p_payload->'assignedOsc','[]'))>0 then raise exception 'Mapping OSC hanya untuk Supervisor'; end if;
  if v_role<>'management' and jsonb_array_length(coalesce(p_payload->'regions','[]'))>0 then raise exception 'Region hanya untuk Management'; end if;
  if v_role<>'management' then delete from public.user_region_access where user_id=v_target; end if;

  -- Yurisdiksi milik peran LAIN selalu dilepas, pada setiap penyimpanan. Inilah yang
  -- memastikan sebuah akun tidak pernah memegang dua yurisdiksi sekaligus, termasuk
  -- ketika perannya baru saja berubah dan layar hanya mengirim yurisdiksi yang baru.
  if v_role <> 'supervisor' then
    delete from public.user_supervision where supervisor_id=v_target;
  end if;
  if v_role <> 'admin' then
    delete from public.user_depot_grants where user_id=v_target and kind='rp';
  end if;
  if v_role not in ('osc','others','finance','depot head') then
    delete from public.user_depot_grants where user_id=v_target and kind='assigned';
  end if;
  -- System Manager dan Supervisor memperoleh depot lewat perannya, jadi grant apa pun
  -- pada keduanya hanya menjadi sumber kebenaran kedua yang akan menyimpang.
  if v_role in ('system manager','supervisor') then
    delete from public.user_depot_grants where user_id=v_target;
  end if;

  begin
    if p_payload ? 'homeDepot' then
      -- Depot rumah adalah keterangan identitas, bukan pemberian wewenang, sehingga ia
      -- tidak lagi menjadi baris grant dan tidak ikut menentukan yurisdiksi.
      if coalesce(btrim(p_payload->>'homeDepot'),'')='' then
        update public.profiles set home_depot_id=null where id=v_target;
      else
        update public.profiles
           set home_depot_id=public.rc_legacy_depot_id(btrim(p_payload->>'homeDepot'))
         where id=v_target;
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
          select v_target,p2.id from public.profiles p2
           where p2.user_code=upper(btrim(c)) and p2.id<>v_target and p2.role = 'osc'
          on conflict do nothing;
          -- "insert ... select" TIDAK gagal ketika select-nya kosong; ia hanya menyisipkan
          -- nol baris. Tanpa pemeriksaan ini, kode yang tidak dikenal dilaporkan sebagai
          -- keberhasilan dan tidak ada yang tersimpan.
          get diagnostics v_tersisip = row_count;
          if v_tersisip = 0 then
            if upper(btrim(c)) = v_kode then
              raise exception 'Akun % tidak dapat membina dirinya sendiri sebagai OSC.', btrim(c);
            else
              raise exception 'Akun % tidak dapat dibina: ia harus ada dan berperan OSC. Supervisor hanya membina OSC di bawahnya.', btrim(c);
            end if;
          end if;
          n_osc:=n_osc+v_tersisip;
        end if;
      end loop;
    end if;
  end;

  if v_role='system manager' then
    v_perms:=array(select code from public.permissions);
  else
    v_perms:=array(select code from (values
      ('j','upload_claim'),('k','release_claim'),('l','process_claim'),('m','view_analytics'),
      ('n','manage_access'),('p','view_master_depot'),('s','bulk_process'),('logs','view_logs'),
      ('keyMaster','manage_key_master'),('compilation','view_compilation'),
      ('archiveCompilation','archive_compilation'),
      ('report','view_report'),('timetable','manage_timetable'),('approval','approve_claim'),('people','view_people')
    ) as m(letter,code)
    where lower(coalesce(p_payload->'auth'->>m.letter,'no')) in('yes','true','approved','visible')
      or (not coalesce(p_payload->'auth','{}') ? m.letter and exists(select 1 from public.user_permissions up where up.user_id=v_target and up.permission_code=m.code)));
  end if;

  delete from public.user_permissions where user_id=v_target;
  insert into public.user_permissions select v_target,x from unnest(v_perms) x group by x;
  update public.profiles set status=v_status where id=v_target;

  if p_payload ? 'regions' then
   perform rc_private.tetapkan_region(v_target, p_payload->'regions');
 end if;
 perform rc_private.rebuild_with_supervisors(v_target);

  if coalesce((p_payload->>'approvePin')::boolean,false) then
    update public.profiles set must_change_password=true where id=v_target;
  end if;

  if p_payload ? 'tabs' then perform rc_private.save_tab_access(v_target,p_payload->'tabs');end if;
  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'access_changed',v_target,jsonb_build_object(
    'status',v_status,'role',v_role,'permissions',coalesce(array_length(v_perms,1),0),
    'rp',n_rp,'assigned',n_as,'osc',n_osc));

  return jsonb_build_object('status','success','role',v_role,
    'jumlahPermission',coalesce(array_length(v_perms,1),0),
    'jumlahDepot',(select count(*) from public.user_depot_access where user_id=v_target),
    'pesan','Akses '||v_kode||' berhasil diperbarui');
end $function$
;
CREATE OR REPLACE FUNCTION rc_private.legacy_users()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce(jsonb_agg(jsonb_build_object(
   'tabs',rc_private.tab_rights(p.id),'id',p.id,'userId',p.user_code,
   'nama',p.full_name,'namaLengkap',p.full_name,'fullName',p.full_name,
   'email',p.business_email,
   'department',coalesce(p.department,''),'role',p.role,'sysRole',p.role,'suffix',p.suffix_num,
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
                        ('report','view_report'),('timetable','manage_timetable'),('approval','approve_claim'),('people','view_people')
                ) as m(letter,code))
         || jsonb_build_object('i',case p.status when 'active' then 'Active' else 'Inactive' end),
   'kodeDepot',coalesce((select d.depot_code from public.depots d where d.id=p.home_depot_id),''),
   'namaDepot',coalesce((select d.depot_name from public.depots d where d.id=p.home_depot_id),''),
   'depotName',coalesce((select d.depot_name from public.depots d where d.id=p.home_depot_id),''),
   'rpDepots',array(select d.depot_code from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='rp' order by d.depot_code),
   'assignedDepots',array(select d.depot_code from public.user_depot_grants g
      join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='assigned' order by d.depot_code),
   'assignedOsc',array(select o.user_code from public.user_supervision s
      join public.profiles o on o.id=s.osc_id where s.supervisor_id=p.id order by o.user_code),
   'regions',array(select region from public.user_region_access where user_id=p.id order by region),
   'depotCodes',array(select d.depot_code from public.user_depot_access a
      join public.depots d on d.id=a.depot_id where a.user_id=p.id order by d.depot_code),
   'depotIds',array(select depot_id from public.user_depot_access where user_id=p.id))
   order by p.status,p.user_code),'[]'::jsonb)
 from public.profiles p
 where p.status<>'deleted' and rc_private.can_view_managed_user(p.id);
$function$
;
CREATE OR REPLACE FUNCTION rc_private.legacy_auth_flags()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with peta(letter, code) as (values
   ('j','upload_claim'), ('k','release_claim'), ('l','process_claim'),
   ('m','view_analytics'), ('d','view_analytics'), ('n','manage_access'),
   ('p','view_master_depot'), ('s','bulk_process'), ('logs','view_logs'),
   ('keyMaster','manage_key_master'), ('compilation','view_compilation'),
   ('archiveCompilation','archive_compilation'),
   ('approval','approve_claim'),('people','view_people'),
   ('report','view_report'), ('timetable','manage_timetable')
 ), milik as (
   select coalesce(jsonb_object_agg(permission_code,true),'{}'::jsonb) as p
     from public.user_permissions where user_id=(select auth.uid())
 ), semua as (
   -- Peran yang "dapat melakukan seluruhnya sesuai yurisdiksi": batasnya jangkauan depot, bukan
   -- daftar izin. Jangkauan itu dijaga can_access pada setiap tindakan, jadi di sini seluruh
   -- kartunya memang ditampilkan.
   select exists(select 1 from public.profiles p
                  where p.id=(select auth.uid()) and p.status='active'
                    and not p.must_change_password
                    and p.role in ('depot head','management')) as ya
 )
 select case when rc_private.is_system_manager() or (select ya from semua) then
   (select jsonb_object_agg(letter,'Yes') from peta) || jsonb_build_object('q','No')
 else
   (select jsonb_object_agg(peta.letter,
      case when milik.p ? peta.code then 'Yes' else 'No' end)
    from peta, milik) || jsonb_build_object('q','No')
 end;
$function$
;
CREATE OR REPLACE FUNCTION public.rc_legacy_bootstrap()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
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
 -- Depot rumah yang ditetapkan di Access Management menang. Urutan abjad hanya cadangan,
 -- dan bagi System Manager - yang melihat seluruh depot - cadangan itu selalu '1A',
 -- yaitu depot yang tidak ada hubungannya dengan tempat ia bekerja.
 select * into home from public.depots where id=me.home_depot_id;
 if not found then
  select * into home from public.depots where id=any(depot_ids) order by depot_code limit 1;
 end if;
 may_read_contacts:=rc_private.can_access(null,'upload_claim');

 result:=jsonb_build_object(
  'status','success',
  'data',jsonb_build_object(
   'userId',me.user_code,'namaLengkap',me.full_name,'role',me.role,'sysRole',me.role,
   'email',me.business_email,'activation','active','suffix',me.suffix_num,
   'kodeDepot',coalesce(home.depot_code,''),'depot',coalesce(home.depot_name,''),
   'regional',coalesce(home.region,''),'tabs',rc_private.tab_rights(me.id),'auth',flags,
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
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_open_claims(p_search text DEFAULT ''::text, p_campaign text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb; jml bigint;
begin
 perform rc_private.require_tab('upload.open');
 if not rc_private.can_access(null,'upload_claim') then
  raise exception 'Access denied' using errcode='42501'; end if;

 select count(*) into jml from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  join public.customers cu on cu.id=c.customer_id
  where c.status='not_yet' and c.pending_approval is null and c.archived_at is null
    and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%');

 select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'noDoc',c.no_doc,'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'statusPajakCamp',coalesce(ca.tax_status,''),
   'cbNet',c.cb_net,'dcCode',d.depot_code,'depotName',d.depot_name,
   'top',coalesce(cu.top_text,''),'ktp',coalesce(cu.ktp,''),'npwp',coalesce(cu.npwp,''),
   'noRek',coalesce(cu.account_number,''),'namaRek',coalesce(cu.account_name,''),
   'bank',coalesce(cu.bank,''),'subyekPajak',coalesce(cu.tax_subject,''),
   'contactPerson',coalesce(cu.contact_person,''),
   -- Dua kolom baru yang diminta pemilik.
   'createdOn',to_char(c.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY'),
   'createdBy',coalesce(p.user_code,''),
   'versionNo',c.version_no) as x
  from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  join public.customers cu on cu.id=c.customer_id
  join public.depots d on d.id=c.depot_id
  left join public.profiles p on p.id=c.created_by
  where c.status='not_yet' and c.pending_approval is null and c.archived_at is null
    and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,200),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 return jsonb_build_object('status','success','rows',v,'total',jml);
end $function$;
CREATE OR REPLACE FUNCTION public.rc_open_claims_filtered(p_search text DEFAULT ''::text, p_campaign text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 200, p_cb_type text DEFAULT '')
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb; jml bigint;
begin
 perform rc_private.require_tab('upload.open');
 if not rc_private.can_access(null,'upload_claim') then
  raise exception 'Access denied' using errcode='42501'; end if;

 select count(*) into jml from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  join public.customers cu on cu.id=c.customer_id
  where c.status='not_yet' and c.pending_approval is null and c.archived_at is null
    and (coalesce(btrim(p_cb_type),'')='' or rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type))=rc_private.jenis_efektif(p_cb_type)) and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%');

 select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'noDoc',c.no_doc,'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'statusPajakCamp',coalesce(ca.tax_status,''),
   'cbNet',c.cb_net,'dcCode',d.depot_code,'depotName',d.depot_name,
   'top',coalesce(cu.top_text,''),'ktp',coalesce(cu.ktp,''),'npwp',coalesce(cu.npwp,''),
   'noRek',coalesce(cu.account_number,''),'namaRek',coalesce(cu.account_name,''),
   'bank',coalesce(cu.bank,''),'subyekPajak',coalesce(cu.tax_subject,''),
   'contactPerson',coalesce(cu.contact_person,''),
   -- Dua kolom baru yang diminta pemilik.
   'createdOn',to_char(c.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY'),
   'createdBy',coalesce(p.user_code,''),
   'versionNo',c.version_no) as x
  from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  join public.customers cu on cu.id=c.customer_id
  join public.depots d on d.id=c.depot_id
  left join public.profiles p on p.id=c.created_by
  where c.status='not_yet' and c.pending_approval is null and c.archived_at is null
    and (coalesce(btrim(p_cb_type),'')='' or rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type))=rc_private.jenis_efektif(p_cb_type)) and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,200),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 return jsonb_build_object('status','success','rows',v,'total',jml);
end $function$;
CREATE OR REPLACE FUNCTION public.rc_compile_preview(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare r jsonb; baris integer:=0; siap integer:=0; duplikat jsonb:='[]'; ditolak jsonb:='[]';
 terlihat jsonb:='{}'; kunci text; v_code text; v_custcode text;
 v_depot public.depots%rowtype; v_camp public.campaigns%rowtype; v_cust public.customers%rowtype;
begin
 perform rc_private.require_tab('compilation.compile');
 if not rc_private.can_access(null,'view_compilation') then
  raise exception 'Access denied' using errcode='42501'; end if;
 if jsonb_array_length(p_rows)>2000 then raise exception 'Satu compile maksimal 2000 baris'; end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array' then raise exception 'Data harus berupa array'; end if;
 if jsonb_array_length(p_rows) not between 1 and 2000 then
  raise exception 'Satu compile maksimal 2000 baris'; end if;

 for r in select value from jsonb_array_elements(p_rows) loop
  baris:=baris+1;
  v_code:=upper(btrim(coalesce(r->>'codeCampaign','')));
  v_custcode:=upper(btrim(coalesce(r->>'custCode','')));
  select * into v_depot from public.depots where depot_code=btrim(coalesce(r->>'kodeDepot',''));
  if not found or not rc_private.can_access(v_depot.id) then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Depot tidak dikenali atau di luar akses')); continue; end if;
  select * into v_camp from public.campaigns where campaign_code=v_code;
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Campaign "'||v_code||'" belum ada di Campaign Master')); continue; end if;
  select * into v_cust from public.customers where customer_code=v_custcode;
  if not found then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Customer "'||v_custcode||'" belum ada di Customer Master')); continue; end if;
  kunci:=v_code||'|'||v_custcode;
  if terlihat ? kunci or exists(select 1 from public.claims c where c.campaign_id=v_camp.id
       and c.customer_id=v_cust.id and c.archived_at is null) then
   duplikat:=duplikat||jsonb_build_array(jsonb_build_object('baris',baris,'kunci',kunci)); continue; end if;
  terlihat:=terlihat||jsonb_build_object(kunci,true);
  siap:=siap+1;
 end loop;

 return jsonb_build_object('status','success','siap',siap,'duplikat',duplikat,'ditolak',ditolak,
  'total',baris);
end $function$;
CREATE OR REPLACE FUNCTION public.rc_compile_upload(p_rows jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$select rc_private.require_tab('compilation.compile');select rc_private.compile_upload(p_rows,p_request_id);$function$
;
CREATE OR REPLACE FUNCTION public.rc_compilation_list(p_campaign text DEFAULT ''::text, p_batch text DEFAULT ''::text, p_status text DEFAULT ''::text, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb; jml bigint;
begin
 perform rc_private.require_tab('compilation.list');
 if not rc_private.can_access(null,'view_compilation') then
  raise exception 'Access denied' using errcode='42501'; end if;

 select count(*) into jml from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  join public.customers cu on cu.id=c.customer_id
  where (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_status),'')='' or c.status=btrim(p_status))
    and (coalesce(btrim(p_batch),'')='' or btrim(p_batch) in
         (c.batch_upload,c.batch_release,c.batch_claim,c.batch_clearing))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%');

 select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'id',c.id,'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
   'depot',d.depot_name,'kodeDepot',d.depot_code,
   'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
   'contactPerson',coalesce(cu.contact_person,''),
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',coalesce(ca.cashback_type,''),'statusPajak',coalesce(ca.tax_status,''),
   'subyekPajak',coalesce(c.tax_subject,coalesce(cu.tax_subject,'')),
   'cbNet',c.cb_net,'grossUpCb',c.gross_up,'totTagih',c.total_billing,
   'batchUpload',coalesce(c.batch_upload,''),'batchRelease',coalesce(c.batch_release,''),
   'batchClaim',coalesce(c.batch_claim,''),'batchClearing',coalesce(c.batch_clearing,''),
   'tglUpload',rc_private.legacy_ts(c.uploaded_at),'tglClearing',rc_private.legacy_ts(c.cleared_at),
   'tglProses',case when c.status='done' and c.cleared_at is not null
                    then rc_private.legacy_ts(c.cleared_at) else '-' end,
   'versionNo',c.version_no) as x
  from public.claims c
  join public.depots d on d.id=c.depot_id
  join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  where (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_status),'')='' or c.status=btrim(p_status))
    and (coalesce(btrim(p_batch),'')='' or btrim(p_batch) in
         (c.batch_upload,c.batch_release,c.batch_claim,c.batch_clearing))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,100),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 return jsonb_build_object('status','success','rows',v,'total',jml,
  'canArchive',rc_private.can_access(null,'archive_compilation'));
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_archived_list(p_offset integer DEFAULT 0, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb;
begin
 perform rc_private.require_tab('compilation.archive');
 if not rc_private.is_manager() then raise exception 'Hanya System Manager' using errcode='42501'; end if;
 select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
  select jsonb_build_object('id',c.id,'noDoc',c.no_doc,'kodeToko',cu.customer_code,
   'codeCampaign',ca.campaign_code,'cbNet',c.cb_net,
   'alasan',coalesce(c.archive_reason,''),'olehUser',coalesce(p.user_code,''),
   'waktu',rc_private.legacy_ts(c.archived_at)) as x
  from public.claims c
  join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  left join public.profiles p on p.id=c.archived_by
  where c.archived_at is not null
  order by c.archived_at desc
  limit least(greatest(coalesce(p_limit,100),1),500) offset greatest(coalesce(p_offset,0),0)) t;
 return jsonb_build_object('status','success','rows',v);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_archive_compilation(p_ids uuid[], p_reason text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$select rc_private.require_tab('compilation.archive');select rc_private.archive_claims(p_ids,p_reason);$function$
;
CREATE OR REPLACE FUNCTION public.rc_reprocessing_list(p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb; jml bigint; v_cari text;
begin
 perform rc_private.require_tab('compilation.reprocess');
  if not rc_private.can_access(null,'view_compilation') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak membuka Cashback Compilation' using errcode='42501'; end if;
  v_cari := nullif(btrim(coalesce(p_search,'')),'');

  select count(*) into jml
    from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
    join public.customers cu on cu.id = c.customer_id
   where c.status = 'on_hold' and c.archived_at is null and c.pending_approval is null
     and (v_cari is null or c.no_doc ilike '%'||v_cari||'%'
          or cu.customer_code ilike '%'||v_cari||'%' or cu.customer_name ilike '%'||v_cari||'%');

  select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
    select jsonb_build_object(
      'noDoc',c.no_doc,
      'kodeCampaign',ca.campaign_code,'namaCampaign',ca.campaign_name,
      'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
      'totalCashback',c.cb_net,
      'dcCode',d.depot_code,'depotName',d.depot_name,
      -- Tanggal yang ditetapkan saat On Hold. Ditampilkan supaya penyunting tahu batas baru
      -- dokumen ini, dan ikut terbawa ke berkas unduhan.
      'soStart',c.extend_so_start,'soEnd',c.extend_so_end,
      'billingStart',c.extend_billing_start,'billingEnd',c.extend_billing_end,
      'ditahanPada',to_char(c.updated_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
      'alasan',coalesce((select h.reason from public.claim_status_history h
                          where h.claim_id=c.id and h.action in('hold','request_hold')
                          order by h.id desc limit 1),''),
      'versionNo',c.version_no) as x
    from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
    join public.customers cu on cu.id = c.customer_id
    join public.depots d on d.id = c.depot_id
   where c.status = 'on_hold' and c.archived_at is null and c.pending_approval is null
     and (v_cari is null or c.no_doc ilike '%'||v_cari||'%'
          or cu.customer_code ilike '%'||v_cari||'%' or cu.customer_name ilike '%'||v_cari||'%')
   order by c.updated_at desc, c.no_doc
   limit least(greatest(coalesce(p_limit,200),1),2000)
  offset greatest(coalesce(p_offset,0),0)) t;

  return jsonb_build_object('status','success','rows',v,'total',jml);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_reprocessing_upload(p_rows jsonb, p_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r jsonb; v_doc text; c public.claims%rowtype; v_baru numeric;
  n_ok integer := 0; gagal jsonb := '[]'::jsonb; actor uuid := (select auth.uid());
begin
 perform rc_private.require_tab('compilation.reprocess');
  if not rc_private.can_access(null,'view_compilation') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak mengubah Cashback Compilation' using errcode='42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Tidak ada baris yang dikirim'; end if;
  if jsonb_array_length(p_rows) > 2000 then
    raise exception 'Maksimal 2000 baris sekali unggah'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_doc := upper(btrim(coalesce(r->>'noDoc','')));
    if v_doc = '' then continue; end if;

    select * into c from public.claims where upper(no_doc) = v_doc for update;
    if not found then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Dokumen tidak ditemukan'));
      continue;
    end if;
    if c.status <> 'on_hold' or c.pending_approval is not null then
      -- Menolak dokumen yang tidak tertahan penting: berkas unduhan yang dipakai ulang beberapa
      -- hari kemudian dapat memuat dokumen yang sementara itu sudah diproses orang lain.
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
        'sebab','Status saat ini '||rc_private.legacy_status(c.status)||', bukan On Hold'));
      continue;
    end if;
    if not rc_private.can_access(c.depot_id) then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Depot di luar yurisdiksi Anda'));
      continue;
    end if;

    begin
      v_baru := nullif(btrim(coalesce(r->>'totalCashback','')),'')::numeric;
    exception when others then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
        'sebab','Total cashback bukan angka: '||coalesce(r->>'totalCashback','')));
      continue;
    end;
    if v_baru is null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Total cashback kosong'));
      continue;
    end if;
    if v_baru < 0 then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Total cashback tidak boleh negatif'));
      continue;
    end if;

    update public.claims set
      cb_net = v_baru,
      status = 'not_yet',
      previous_status = null,
      -- Perpanjangan hanya berlaku selama dokumennya tertahan.
      extend_so_start = null, extend_so_end = null,
      extend_billing_start = null, extend_billing_end = null,
      version_no = version_no + 1,
      updated_at = now()
    where id = c.id;

    insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,reason)
    values(c.id,actor,'on_hold','not_yet','reprocess',
      left(btrim(coalesce(p_reason,'Revisi nominal lewat Reprocessing Doc')),300));

    insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
    values(actor,c.depot_id,'reprocessing_upload',c.id,jsonb_build_object(
      'noDoc',c.no_doc,'cbNetLama',c.cb_net,'cbNetBaru',v_baru));

    n_ok := n_ok + 1;
  end loop;

  return jsonb_build_object('status','success','berhasil',n_ok,
    'gagal',gagal,'jumlahGagal',jsonb_array_length(gagal),
    'message',n_ok||' dokumen kembali ke Not Yet'
      ||case when jsonb_array_length(gagal) > 0
             then ', '||jsonb_array_length(gagal)||' ditolak' else '' end);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_customer_list(p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v jsonb;
begin
 perform rc_private.require_tab('keyMaster.customer');
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 select coalesce(jsonb_agg(x order by x->>'custCode'),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'depotNames',array(select d.depot_name from public.customer_depots cd join public.depots d on d.id=cd.depot_id where cd.customer_id=cu.id and rc_private.can_access(d.id) order by d.depot_code), 'regions',array(select distinct d.region from public.customer_depots cd join public.depots d on d.id=cd.depot_id where cd.customer_id=cu.id and rc_private.can_access(d.id) and d.region is not null), 'id',cu.id,'custCode',cu.customer_code,'custName',cu.customer_name,
   'top',coalesce(cu.top_text,''),'ktp',coalesce(cu.ktp,''),'npwp',coalesce(cu.npwp,''),
   'subyekPajak',coalesce(cu.tax_subject,''),
   'namaRek',coalesce(cu.account_name,''),'noRek',coalesce(cu.account_number,''),
   'bank',coalesce(cu.bank,''),'contactPerson',coalesce(cu.contact_person,''),
   'depotCodes',array(select d.depot_code from public.customer_depots cd
     join public.depots d on d.id=cd.depot_id where cd.customer_id=cu.id and rc_private.can_access(d.id) order by d.depot_code)) as x
  from public.customers cu
  where cu.archived_at is null and (coalesce(btrim(p_search),'')=''
     or cu.customer_code ilike '%'||btrim(p_search)||'%'
     or cu.customer_name ilike '%'||btrim(p_search)||'%')
  order by cu.customer_code
  limit least(greatest(coalesce(p_limit,50),1),200) offset greatest(coalesce(p_offset,0),0)) t;
 return jsonb_build_object('status','success','rows',v,
  'total',(select count(*) from public.customers cu where archived_at is null and (coalesce(btrim(p_search),'')='' or cu.customer_code ilike '%'||btrim(p_search)||'%' or cu.customer_name ilike '%'||btrim(p_search)||'%')));
end $function$;
CREATE OR REPLACE FUNCTION public.rc_customer_upsert(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$select rc_private.require_tab('keyMaster.customer');select rc_private.customer_upsert(p_rows);$function$
;
CREATE OR REPLACE FUNCTION public.rc_campaign_upsert(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$select rc_private.require_tab('keyMaster.campaign');select rc_private.campaign_upsert(p_rows);$function$
;
CREATE OR REPLACE FUNCTION public.rc_depot_list(p_search text DEFAULT NULL::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v_search text; v_limit integer; v_offset integer;
begin
 perform rc_private.require_tab('keyMaster.depot');
  if not rc_private.can_access(null,'manage_key_master') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak membuka Key Master' using errcode='42501'; end if;
  v_search := nullif(btrim(coalesce(p_search,'')),'');
  v_limit  := least(greatest(coalesce(p_limit,50),1),500);
  v_offset := greatest(coalesce(p_offset,0),0);

  return (select jsonb_build_object('status','success',
    'bolehLangsung', rc_private.is_manager(),
    'total',(select count(*) from public.depots d
       where d.archived_at is null and (v_search is null
          or d.depot_code ilike '%'||v_search||'%'
          or d.depot_name ilike '%'||v_search||'%'
          or coalesce(d.region,'') ilike '%'||v_search||'%')),
    'rows',coalesce((select jsonb_agg(jsonb_build_object(
        'kode',t.depot_code,'nama',t.depot_name,'abbr',coalesce(t.abbr,''),
        'region',coalesce(t.region,''),
        'alamat',coalesce(t.p_alamat, t.address, ''),
        'gmapsUrl',coalesce(t.gmaps_url,''),
        'fotoUrl',coalesce(t.foto_url,''),
        'tipeDepot',coalesce(t.tipe_depot,''),
        'grade',coalesce(t.grade,''),
        'kepalaDepot',coalesce(t.kepala_depot, t.head_depot, ''),
        'kepalaAdmin',coalesce(t.p_kepala_admin, t.kepala_admin, ''),
        'karAdmin',coalesce(t.kar_admin,0),   'karSales',coalesce(t.kar_sales,0),
        'karDriver',coalesce(t.kar_driver,0), 'karFg',coalesce(t.kar_fg,0),
        'karPcc',coalesce(t.kar_pcc,0),       'karTeknisi',coalesce(t.kar_teknisi,0),
        'karLain',coalesce(t.kar_lain,0),
        'karTotal',coalesce(t.kar_admin,0)+coalesce(t.kar_sales,0)+coalesce(t.kar_driver,0)
                  +coalesce(t.kar_fg,0)+coalesce(t.kar_pcc,0)+coalesce(t.kar_teknisi,0)
                  +coalesce(t.kar_lain,0),
        'emailRsm',coalesce(t.email_rsm,''),  'emailAsm',coalesce(t.email_asm,''),
        'emailSm',coalesce(t.email_sm,''),
        'emailTo',coalesce(t.email_to,''),    'emailCc',coalesce(t.email_cc,''),
        'jumlahTo',coalesce(array_length(rc_private.pecah_email(t.email_to),1),0),
        'jumlahCc',coalesce(array_length(rc_private.pecah_email(t.email_cc),1),0),
        -- Tim pengawas dan akun terdaftar tidak pernah diketik: keduanya diturunkan dari
        -- penugasan yang berlaku, sehingga berubah sendiri ketika penugasannya berubah.
        'timPengawas',coalesce((select string_agg(distinct o.user_code,', ' order by o.user_code)
            from public.user_depot_access a join public.profiles o on o.id=a.user_id
           where a.depot_id=t.id and o.role in('osc','supervisor') and o.status='active'),''),
        'akunTerdaftar',coalesce((select string_agg(u.user_code,', ' order by u.user_code)
            from public.user_depot_access a join public.profiles u on u.id=a.user_id
           where a.depot_id=t.id),''),
        'pengajuanTertunda',(select count(*) from public.depot_profile_requests r
            where r.depot_id=t.id and r.status='pending'))
        order by t.depot_code)
      from (select d.*, p.alamat as p_alamat, p.kepala_admin as p_kepala_admin,
                   p.gmaps_url, p.foto_url, p.tipe_depot, p.grade, p.kepala_depot,
                   p.kar_admin, p.kar_sales, p.kar_driver, p.kar_fg, p.kar_pcc,
                   p.kar_teknisi, p.kar_lain, p.email_rsm, p.email_asm, p.email_sm
              from public.depots d
              left join public.depot_profiles p on p.depot_id = d.id
             where d.archived_at is null and (v_search is null
                or d.depot_code ilike '%'||v_search||'%'
                or d.depot_name ilike '%'||v_search||'%'
                or coalesce(d.region,'') ilike '%'||v_search||'%')
             order by d.depot_code offset v_offset limit v_limit) t),'[]'::jsonb)));
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_depot_save(p_kode text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_depot uuid; v_kode text; v_id uuid; v_bersih jsonb := '{}'::jsonb; k text;
  v_izin text[] := array['nama','abbr','region','alamat','gmapsUrl','fotoUrl','tipeDepot',
    'kepalaDepot','kepalaAdmin','karAdmin','karSales','karDriver','karFg','karPcc',
    'karTeknisi','karLain','emailRsm','emailAsm','emailSm','emailTo','emailCc'];
begin
 perform rc_private.require_tab('keyMaster.depot');
  if not rc_private.can_access(null,'manage_key_master') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak mengubah Key Master' using errcode='42501'; end if;

  v_kode := upper(btrim(coalesce(p_kode,'')));
  select id into v_depot from public.depots where depot_code = v_kode;
  if v_depot is null then raise exception 'Depot "%" tidak ditemukan', v_kode; end if;
  if not rc_private.can_access(v_depot) then
    raise exception 'Depot ini di luar yurisdiksi Anda' using errcode='42501'; end if;
  if jsonb_typeof(p_data) <> 'object' then raise exception 'Data tidak sah'; end if;

  for k in select jsonb_object_keys(p_data) loop
    if k = any(v_izin) then v_bersih := v_bersih || jsonb_build_object(k, p_data->k); end if;
  end loop;
  if v_bersih = '{}'::jsonb then raise exception 'Tidak ada perubahan yang dapat disimpan'; end if;

  perform rc_private.periksa_email_maks(v_bersih->>'emailRsm','Email RSM',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailAsm','Email ASM',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailSm','Email SM',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailTo','Email Depot (TO)',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailCc','Email CC',20);

  if not rc_private.is_manager() then
    insert into public.depot_profile_requests(depot_id,requester_id,perubahan)
    values(v_depot,(select auth.uid()),v_bersih) returning id into v_id;
    insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
    values((select auth.uid()),v_depot,'depot_diajukan',v_id,v_bersih);
    return jsonb_build_object('status','success','diajukan',true,'id',v_id,
      'message','Perubahan dikirim ke Kelola Akses. Nilai lama tetap berlaku sampai Supervisor wilayah atau System Manager menyetujui.');
  end if;

  perform rc_private.terapkan_depot(v_depot, v_bersih);
  insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
  values((select auth.uid()),v_depot,'depot_disimpan',v_depot,v_bersih);
  return jsonb_build_object('status','success','diajukan',false,
    'message','Depot '||v_kode||' diperbarui.');
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_report_dashboard(p_filter jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
      begin
 perform rc_private.require_tab('report.dashboard');
        if not rc_private.can_access(null,'view_report') and not rc_private.is_system_manager() then
          raise exception 'Tidak punya hak melihat modul Report' using errcode='42501'; end if;
        return rc_private.report_dashboard(p_filter);
      end $function$
;
CREATE OR REPLACE FUNCTION public.rc_cost_center(p_filter jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
      begin
 perform rc_private.require_tab('report.cc1');
        if not rc_private.can_access(null,'view_report') and not rc_private.is_system_manager() then
          raise exception 'Tidak punya hak melihat modul Report' using errcode='42501'; end if;
        return rc_private.cost_center(p_filter);
      end $function$
;
CREATE OR REPLACE FUNCTION public.rc_cost_center_2(p_filter jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
      begin
 perform rc_private.require_tab('report.cc2');
        if not rc_private.can_access(null,'view_report') and not rc_private.is_system_manager() then
          raise exception 'Tidak punya hak melihat modul Report' using errcode='42501'; end if;
        return rc_private.cost_center_2(p_filter);
      end $function$
;
create or replace function public.rc_legacy_logs(p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform rc_private.require_tab('logs.list');
 if not rc_private.can_access(null,'view_logs') and not rc_private.is_manager() then raise exception 'Access denied' using errcode='42501'; end if;
 return jsonb_build_object('status','success','logs',coalesce((select jsonb_agg(jsonb_build_object(
 'timestamp',to_char(l.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS'), 'timestampIso',l.created_at,
 'userId',coalesce(p.user_code,''),'role',coalesce(p.role,''),'detail',coalesce(l.details->>'detail',l.event_type),
 'module',coalesce(l.module,'Legacy'),'tab',coalesce(l.tab,'Tidak tercatat'),
 'stage',coalesce(l.process_stage,l.event_type),'batch',coalesce(l.batch_no,l.details->>'batch','-')) order by l.id desc)
 from (select a.* from public.activity_logs a where a.created_at>=now()-make_interval(days=>least(greatest(coalesce(p_days,30),1),365))
 and (rc_private.is_system_manager() or a.actor_id=auth.uid() or (a.depot_id is not null and rc_private.can_access(a.depot_id))
 or (a.depot_id is null and rc_private.can_manage_user(a.actor_id))) order by a.id desc limit 2000) l
 left join public.profiles p on p.id=l.actor_id),'[]'::jsonb));
end $$;
notify pgrst,'reload schema';

CREATE OR REPLACE FUNCTION public.rc_legacy_dashboard()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
 if not rc_private.can_access(null,'view_analytics') then raise exception 'Access denied' using errcode='42501'; end if;
 return jsonb_build_object('status','success',
  'history',coalesce((select jsonb_agg(jsonb_build_object(
    'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
    'depot',d.depot_name,'osc',coalesce(p.full_name,''),
    'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
    'codeCampaign',ca.campaign_code,'campaign',ca.campaign_name,
    'validYear',extract(year from coalesce(c.period_start,ca.period_start))::text,'totalClaim',c.cb_net,'grossUpCb',c.gross_up,
    'tglUpload',rc_private.legacy_ts(c.uploaded_at),
    'tglClearing',rc_private.legacy_ts(c.cleared_at),
    -- Field yang sebelumnya hilang dan membuat kolom menampilkan "undefined".
    'tglProses',case when c.status='done' and c.cleared_at is not null
                     then rc_private.legacy_ts(c.cleared_at) else '-' end,
    'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),
    'batchUpload',coalesce(c.batch_upload,''),'batchClearing',coalesce(c.batch_clearing,'')) || rc_private.claim_details(c)
    order by c.updated_at desc)
   from public.claims c
   join public.depots d on d.id=c.depot_id
   join public.customers cu on cu.id=c.customer_id
   join public.campaigns ca on ca.id=c.campaign_id
   left join lateral (select h.actor_id from public.claim_status_history h
     where h.claim_id=c.id and h.action='submit' order by h.id desc limit 1) sub on true
   left join public.profiles p on p.id=sub.actor_id where c.archived_at is null and rc_private.can_access(c.depot_id)
   -- Filter not_yet dibuang. Pemilik meminta Cashback List memuat SELURUH customer apa pun
  -- statusnya, termasuk Not Yet dan sel kosong, karena daftar ini dipakai sebagai gambaran
  -- menyeluruh, bukan hanya antrean yang sedang berjalan.
  ),'[]'::jsonb),
  'compileData',coalesce((select jsonb_agg(jsonb_build_object(
    'depotName',d.depot_name,'codeCampaign',ca.campaign_code,'campaign',ca.campaign_name,
    'validYear',extract(year from coalesce(c.period_start,ca.period_start))::text,'reward',c.cb_net,'kodeToko',cu.customer_code))
   from public.claims c
   join public.depots d on d.id=c.depot_id
   join public.customers cu on cu.id=c.customer_id
   join public.campaigns ca on ca.id=c.campaign_id where c.archived_at is null and rc_private.can_access(c.depot_id)),'[]'::jsonb));
end $function$;
CREATE OR REPLACE FUNCTION public.rc_depot_profile(p_kode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_depot uuid; v_kode text;
begin
 perform rc_private.require_tab('profile.view');
  v_kode := upper(btrim(coalesce(p_kode,'')));
  select id into v_depot from public.depots where depot_code = v_kode;
  if v_depot is null then raise exception 'Depot "%" tidak ditemukan', v_kode; end if;
  if not rc_private.can_access(v_depot) then
    raise exception 'Depot ini di luar yurisdiksi Anda' using errcode='42501'; end if;

  return (
    select jsonb_build_object(
      'status','success',
      'kodeDepot', d.depot_code,
      'namaDepot', d.depot_name,
      -- Region mengikuti master depot; kode depot adalah kuncinya.
      'region', coalesce(nullif(btrim(d.region),''),'(belum diisi)'),
      'tipeDepot', coalesce(p.tipe_depot,''),
      'grade', coalesce(p.grade,''),
      'alamat', coalesce(p.alamat, d.address, ''),
      'gmapsUrl', coalesce(p.gmaps_url,''),
      'fotoUrl', coalesce(p.foto_url,''),
      'kepalaDepot', coalesce(p.kepala_depot, d.head_depot, ''),
      'kepalaAdmin', coalesce(p.kepala_admin, d.kepala_admin, ''),
      'karyawan', jsonb_build_object(
        'admin',   coalesce(p.kar_admin,0),  'sales',  coalesce(p.kar_sales,0),
        'driver',  coalesce(p.kar_driver,0), 'fg',     coalesce(p.kar_fg,0),
        'pcc',     coalesce(p.kar_pcc,0),    'teknisi',coalesce(p.kar_teknisi,0),
        'lain',    coalesce(p.kar_lain,0),
        -- Total dihitung, tidak diketik. Dua angka yang bisa berbeda hanya mengundang
        -- pertanyaan yang tidak bisa dijawab.
        'total',   coalesce(p.kar_admin,0)+coalesce(p.kar_sales,0)+coalesce(p.kar_driver,0)
                  +coalesce(p.kar_fg,0)+coalesce(p.kar_pcc,0)+coalesce(p.kar_teknisi,0)
                  +coalesce(p.kar_lain,0)),
      'emailRsm',   coalesce(p.email_rsm,''),
      'emailAsm',   coalesce(p.email_asm,''),
      'emailSm',    coalesce(p.email_sm,''),
      'emailDepot', coalesce(nullif(p.email_depot,''), d.email_to, ''),

      -- Tim pengawas diturunkan dari penugasan yang berlaku, bukan diketik ulang.
      'timPengawas', coalesce((
        select jsonb_agg(distinct jsonb_build_object(
                 'userId', o.user_code, 'nama', o.full_name, 'peran', o.role)
               )
          from public.user_depot_access a
          join public.profiles o on o.id = a.user_id
         where a.depot_id = d.id and o.role in('osc','supervisor') and o.status='active'
      ), '[]'::jsonb),

      -- Akun terdaftar pada depot ini, juga diturunkan.
      'akunTerdaftar', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'userId', u.user_code, 'nama', u.full_name, 'peran', u.role, 'status', u.status)
               order by u.user_code)
          from public.user_depot_access a
          join public.profiles u on u.id = a.user_id
         where a.depot_id = d.id
      ), '[]'::jsonb),

      'pengajuanTertunda', (select count(*) from public.depot_profile_requests r
                             where r.depot_id = d.id and r.status='pending'),
      'diperbaruiPada', to_char(p.updated_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI')
    )
    from public.depots d
    left join public.depot_profiles p on p.depot_id = d.id
   where d.id = v_depot);
end $function$;
CREATE OR REPLACE FUNCTION public.rc_depot_profile_request(p_kode text, p_perubahan jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_depot uuid; v_kode text; v_id uuid; v_bersih jsonb := '{}'::jsonb; k text;
  v_izin text[] := array['tipeDepot','alamat','gmapsUrl','fotoUrl','kepalaDepot','kepalaAdmin',
    'karAdmin','karSales','karDriver','karFg','karPcc','karTeknisi','karLain',
    'emailRsm','emailAsm','emailSm','emailDepot','nama','abbr','region','emailTo','emailCc','grade'];
begin
 perform rc_private.require_tab('profile.edit');
  v_kode := upper(btrim(coalesce(p_kode,'')));
  select id into v_depot from public.depots where depot_code = v_kode;
  if v_depot is null then raise exception 'Depot "%" tidak ditemukan', v_kode; end if;
  if not rc_private.can_access(v_depot) then
    raise exception 'Depot ini di luar yurisdiksi Anda' using errcode='42501'; end if;
  if p_perubahan is null or octet_length(p_perubahan::text)>20000 or jsonb_typeof(p_perubahan) <> 'object' then raise exception 'Perubahan tidak sah'; end if;

  -- Hanya kunci yang diizinkan yang diteruskan. Grade sengaja tidak ada di daftar: ia wewenang
  -- System Manager, dan membiarkannya lewat di sini akan menjadi pintu belakang.
  for k in select jsonb_object_keys(p_perubahan) loop
    if not k=any(v_izin) then raise exception 'Kolom profil tidak dikenali: %',k; end if;
    if jsonb_typeof(p_perubahan->k) not in('string','number','null') then raise exception 'Nilai profil tidak sah'; end if;
    if k like 'kar%' and coalesce(p_perubahan->>k,'') !~ '^[0-9]{1,6}$' then raise exception 'Jumlah karyawan harus bilangan bulat nonnegatif'; end if;
    if k = any(v_izin) then
      v_bersih := v_bersih || jsonb_build_object(k, p_perubahan->k);
    end if;
  end loop;
  if v_bersih = '{}'::jsonb then
    raise exception 'Tidak ada perubahan yang dapat diajukan'; end if;

  -- Alamat email diperiksa saat diajukan, bukan saat disetujui, supaya yang mengetik salah
  -- langsung tahu dan bukan penyetuju yang menemukannya beberapa hari kemudian.
  perform rc_private.periksa_email_maks(v_bersih->>'emailRsm','Email RSM');
  perform rc_private.periksa_email_maks(v_bersih->>'emailAsm','Email ASM');
  perform rc_private.periksa_email_maks(v_bersih->>'emailSm','Email SM');
  perform rc_private.periksa_email_maks(v_bersih->>'emailDepot','Email Depot');

  insert into public.depot_profile_requests(depot_id,requester_id,perubahan)
  values(v_depot,(select auth.uid()),v_bersih)
  returning id into v_id;

  insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
  values((select auth.uid()),v_depot,'profil_diajukan',v_id,
         jsonb_build_object('kolom',(select count(*) from jsonb_object_keys(v_bersih))));

  return jsonb_build_object('status','success','id',v_id,
    'message','Pengajuan dikirim. Nilai lama tetap berlaku sampai Supervisor wilayah atau System Manager menyetujui.');
end $function$;
CREATE OR REPLACE FUNCTION public.rc_depot_profile_requests()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$select rc_private.require_tab('access.req');
  select jsonb_build_object('status','success','rows', coalesce(jsonb_agg(jsonb_build_object(
      'id',r.id,'kodeDepot',d.depot_code,'namaDepot',d.depot_name,
      'pengaju',p.user_code,'namaPengaju',p.full_name,
      'perubahan',r.perubahan,
      'diajukan',to_char(r.created_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'))
      order by r.created_at),'[]'::jsonb))
    from public.depot_profile_requests r
    join public.depots d on d.id = r.depot_id
    join public.profiles p on p.id = r.requester_id
   where r.status='pending' and rc_private.is_manager() and rc_private.can_access(r.depot_id);
$function$
;
CREATE OR REPLACE FUNCTION public.rc_depot_profile_review(p_id uuid, p_setujui boolean, p_catatan text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.depot_profile_requests; v_kode text;
begin
 perform rc_private.require_tab('access.req');
  if not rc_private.is_manager() then
    raise exception 'Hanya Supervisor atau System Manager yang dapat menyetujui' using errcode='42501'; end if;
  select * into r from public.depot_profile_requests where id=p_id and status='pending' for update;
  if not found then raise exception 'Pengajuan tidak ditemukan atau sudah diproses'; end if;
  if not rc_private.can_access(r.depot_id) then
    raise exception 'Depot ini di luar wilayah Anda' using errcode='42501'; end if;
  if r.requester_id=auth.uid() then raise exception 'Reviewer harus berbeda dari pemohon' using errcode='42501'; end if;
  if p_setujui is null then raise exception 'Keputusan wajib diisi'; end if;
  select depot_code into v_kode from public.depots where id=r.depot_id;

  if not coalesce(p_setujui,false) then
    update public.depot_profile_requests
       set status='rejected', reviewer_id=(select auth.uid()), reviewed_at=now(),
           catatan=left(btrim(coalesce(p_catatan,'')),300)
     where id=p_id;
    insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details) values(auth.uid(),r.depot_id,'depot_rejected',p_id,jsonb_build_object('note',left(p_catatan,300)));
    return jsonb_build_object('status','success','message','Pengajuan '||v_kode||' ditolak.');
  end if;

  perform rc_private.terapkan_depot(r.depot_id, r.perubahan);

  update public.depot_profile_requests
     set status='approved', reviewer_id=(select auth.uid()), reviewed_at=now(),
         catatan=left(btrim(coalesce(p_catatan,'')),300)
   where id=p_id;

  insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
  values((select auth.uid()),r.depot_id,'depot_disetujui',p_id,r.perubahan);

  return jsonb_build_object('status','success','message','Depot '||v_kode||' diperbarui.');
end $function$;
CREATE OR REPLACE FUNCTION public.rc_review_request(p_id text, p_approve boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare kind text; ref uuid;
begin
 perform rc_private.require_tab('access.req');
 if p_id is null or p_id !~ '^(signup|profile):[0-9a-f-]{36}$' then raise exception 'Request id tidak valid'; end if;
 kind:=split_part(p_id,':',1); ref:=split_part(p_id,':',2)::uuid;
 if kind='signup' then return rc_private.review_registration(ref,p_approve,null); end if;
 perform rc_private.review_profile(ref,p_approve);
 return jsonb_build_object('status','success');
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_review_registration(p_profile uuid, p_approve boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$select rc_private.require_tab('access.req');
 select rc_private.review_registration(p_profile,p_approve,p_note);$function$
;
CREATE OR REPLACE FUNCTION public.rc_review_pin(p_id uuid, p_approve boolean, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_req public.pin_requests; v_kode text;
begin
 perform rc_private.require_tab('access.req');
  if not rc_private.is_manager() then
    raise exception 'Hanya Supervisor atau System Manager yang dapat menyetujui'
      using errcode='42501'; end if;

  select * into v_req from public.pin_requests where id=p_id and status='pending' for update;
  if not found then raise exception 'Permintaan tidak ditemukan atau sudah diproses'; end if;
  if not rc_private.can_manage_user(v_req.requester_id) then
    raise exception 'Permintaan ini di luar wilayah Anda' using errcode='42501'; end if;

  select user_code into v_kode from public.profiles where id=v_req.requester_id;

  if not coalesce(p_approve,false) then
    update public.pin_requests
       set status='rejected', reviewer_id=(select auth.uid()), reviewed_at=now(),
           review_note=left(btrim(coalesce(p_note,'')),300),
           -- Hash yang diajukan tidak perlu disimpan lagi begitu permintaannya ditolak.
           requested_secret=null
     where id=p_id;
    return jsonb_build_object('status','success','message','Permintaan '||v_kode||' ditolak.');
  end if;

  if v_req.requested_secret is null then
    raise exception 'Permintaan ini tidak memuat PIN yang diajukan; minta pengguna mengajukan ulang';
  end if;

  update auth.users
     set encrypted_password = v_req.requested_secret, updated_at = now()
   where id = v_req.requester_id;

  -- PIN ini dipilih sendiri oleh pemilik akun, jadi tidak ada yang perlu diganti lagi.
  update public.profiles set must_change_password=false where id=v_req.requester_id;

  update public.pin_requests
     set status='approved', reviewer_id=(select auth.uid()), reviewed_at=now(),
         review_note=left(btrim(coalesce(p_note,'')),300), requested_secret=null
   where id=p_id;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'pin_approved',v_req.requester_id,
         jsonb_build_object('jenis',v_req.kind,'user',v_kode));

  return jsonb_build_object('status','success',
    'message','PIN baru untuk '||v_kode||' sudah berlaku. Ia dapat langsung masuk dengan PIN itu.');
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_account_delete(p_user_code text, p_alasan text DEFAULT ''::text, p_hapus_jejak boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v public.profiles%rowtype; aku uuid := (select auth.uid()); v_kode text; v_nisan text;
begin
 perform rc_private.require_tab('access.list');
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat menghapus akun' using errcode='42501'; end if;

  v_kode := upper(btrim(coalesce(p_user_code,'')));
  if v_kode = '' then raise exception 'User ID wajib diisi'; end if;
  select * into v from public.profiles where upper(user_code) = v_kode;
  if not found then raise exception 'Akun "%" tidak ditemukan', p_user_code; end if;

  if v.status = 'deleted' then
    raise exception 'Akun ini sudah ada di Arsip Hapus; pulihkan lebih dulu bila ingin mengubahnya'
      using errcode='42501'; end if;
  if v.id = aku then
    raise exception 'Anda tidak dapat menghapus akun Anda sendiri' using errcode='42501'; end if;
  if lower(v.role) = 'system manager'
     and (select count(*) from public.profiles
           where lower(role)='system manager' and status='active' and id <> v.id) = 0 then
    raise exception 'Ini satu-satunya System Manager aktif yang tersisa; sistem akan terkunci tanpa jalan masuk'
      using errcode='42501'; end if;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(aku,'akun_dihapus',v.id,jsonb_build_object(
    'userCode',v.user_code,'nama',v.full_name,'peran',v.role,'statusLama',v.status,
    'alasan',left(btrim(coalesce(p_alasan,'')),300)));

  -- Semua yang memberi wewenang dilepas. Pemulihan TIDAK mengembalikannya: akun yang kembali
  -- harus diberi hak lagi secara sadar, bukan menghidupkan kembali kewenangan lama diam-diam.
  delete from public.user_permissions   where user_id = v.id;
  delete from public.user_depot_access  where user_id = v.id;
  delete from public.user_depot_grants  where user_id = v.id or granted_by = v.id;
  delete from public.user_supervision   where osc_id = v.id or supervisor_id = v.id;
  delete from public.pin_requests       where requester_id = v.id;
  if coalesce(p_hapus_jejak,false) then
    delete from public.activity_logs where actor_id = v.id;
  end if;

  v_nisan := left(v.user_code || ' (dihapus ' || to_char(now() at time zone 'Asia/Jakarta','DD-MM-YYYY') || ')', 60);

  update public.profiles
     set status = 'deleted',
         archived_user_code = v.user_code,
         archived_at = now(),
         archived_by = aku,
         user_code = v_nisan,
         requested_role = null, requested_depot = null,
         must_change_password = false,
         review_note = left('Akun dihapus System Manager. ' || btrim(coalesce(p_alasan,'')), 300)
   where id = v.id;

  -- Login dimatikan. Alamatnya SENGAJA tidak disentuh, supaya pemulihannya nanti benar-benar
  -- dapat dipakai masuk kembali.
  update auth.users set banned_until = 'infinity'::timestamptz where id = v.id;

  return jsonb_build_object('status','success','cara','diarsipkan',
    'message','Akun ' || v.user_code || ' dipindahkan ke Arsip Hapus: login dimatikan, seluruh izin '
      || 'dan depotnya dilepas, dan akunnya hilang dari daftar. Dapat diaktifkan kembali kapan saja '
      || 'lewat tab Arsip Hapus, tetapi izin dan depotnya harus diberikan lagi.');
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_account_archive()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; nama jsonb;
begin
 perform rc_private.require_tab('access.arsip');
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat membuka Arsip Hapus' using errcode='42501'; end if;
  nama := rc_private.peta_nama_pelaku();
  select coalesce(jsonb_agg(x order by x->>'diarsipkanPada' desc),'[]'::jsonb) into v from (
    select jsonb_build_object(
      'id',p.id,
      'userId',coalesce(p.archived_user_code, p.user_code),
      'namaLengkap',p.full_name,'peran',p.role,
      'email',coalesce(p.business_email,''),
      'diarsipkanPada',case when p.archived_at is null then ''
        else to_char(p.archived_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI') end,
      'diarsipkanOleh',coalesce(nama->>(p.archived_by::text),''),
      'catatan',coalesce(p.review_note,''),
      -- Benar bila User ID aslinya sementara dipakai akun lain; pemulihannya akan ditolak
      -- sampai bentrokan itu dibereskan, dan lebih baik terbaca sebelum tombolnya ditekan.
      'bentrok',exists(select 1 from public.profiles q
                        where q.id <> p.id and q.status <> 'deleted'
                          and upper(q.user_code) = upper(coalesce(p.archived_user_code, p.user_code)))
    ) as x
    from public.profiles p where p.status = 'deleted') t;
  return jsonb_build_object('status','success','rows',v);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_email_periksa()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record; n_ok integer := 0; n_gagal integer := 0;
begin
 perform rc_private.require_tab('access.email');
  for r in
    select o.id, (o.konteks->>'net_request_id')::bigint as req
      from public.email_outbox o
     where o.status='sent' and o.konteks ? 'net_request_id'
       and o.dikirim_pada > now() - interval '2 days'
  loop
    begin
      perform 1 from net._http_response where id = r.req and status_code between 200 and 299;
      if found then n_ok := n_ok + 1; continue; end if;
      update public.email_outbox
         set status='failed',
             galat = coalesce((select left(coalesce(error_msg, 'HTTP '||status_code::text||': '||coalesce(content,'')),300)
                                 from net._http_response where id=r.req),'Tidak ada jawaban dari penyedia')
       where id = r.id and exists(select 1 from net._http_response where id=r.req);
      if found then n_gagal := n_gagal + 1; end if;
    exception when others then
      -- Tabel jawaban pg_net dibersihkan berkala; ketiadaan baris bukan bukti kegagalan.
      continue;
    end;
  end loop;
  return jsonb_build_object('status','success','berhasil',n_ok,'gagal',n_gagal);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_email_settings_simpan(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb; n integer := 0; v_hari smallint[]; v_angka smallint;
begin
 perform rc_private.require_tab('access.email');
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat mengubah jadwal email' using errcode='42501'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    -- hariList tidak dikirim  -> biarkan seperti semula
    -- hariList array kosong   -> tiap hari (NULL)
    -- hariList berisi angka   -> hanya hari itu
    v_hari := null;
    if r ? 'hariList' then
      if jsonb_typeof(r->'hariList') <> 'array' then
        raise exception 'hariList harus berupa daftar angka hari'; end if;
      v_hari := '{}'::smallint[];
      for v_angka in select (value#>>'{}')::smallint from jsonb_array_elements(r->'hariList') loop
        if v_angka < 0 or v_angka > 6 then
          raise exception 'Hari harus 0 (Minggu) sampai 6 (Sabtu), diterima %', v_angka; end if;
        if not (v_angka = any(v_hari)) then v_hari := v_hari || v_angka; end if;
      end loop;
      if array_length(v_hari,1) is null then v_hari := null; end if;
    end if;

    update public.email_settings set
      aktif     = coalesce((r->>'aktif')::boolean, aktif),
      jam       = coalesce((r->>'jam')::integer, jam),
      hari_list = case when r ? 'hariList' then v_hari else hari_list end,
      subjek    = coalesce(nullif(btrim(coalesce(r->>'subjek','')),''), subjek),
      diubah_pada = now(), diubah_oleh = (select auth.uid())
    where jenis = lower(btrim(r->>'jenis'));
    if found then n := n + 1; end if;
  end loop;

  return jsonb_build_object('status','success','jumlah',n,'message',n||' jadwal email disimpan');
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_email_status()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$select rc_private.require_tab('access.email');
  select jsonb_build_object('status','success',
    'pengaturan',(select coalesce(jsonb_agg(jsonb_build_object(
        'jenis',jenis,'aktif',aktif,'jam',jam,
        -- NULL tetap dikirim sebagai null, yang di layar berarti "tiap hari".
        'hariList',to_jsonb(hari_list),
        'subjek',subjek) order by jenis),'[]'::jsonb)
      from public.email_settings),
    'antrean',(select coalesce(jsonb_agg(jsonb_build_object(
        'id',id,'jenis',jenis,'subjek',subjek,'status',status,
        'tujuan',array_length(tujuan,1),'cc',array_length(cc,1),'galat',galat,
        'dibuat',to_char(dibuat_pada at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
        'dikirim',to_char(dikirim_pada at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'))
        order by dibuat_pada desc),'[]'::jsonb)
      from (select * from public.email_outbox order by dibuat_pada desc limit 50) x),
    'ringkas',(select jsonb_object_agg(status,n) from
      (select status,count(*) n from public.email_outbox group by status) y),
    'depotBerEmail',(select count(*) from public.depots where coalesce(btrim(email_to),'')<>''),
    'depotTotal',(select count(*) from public.depots));
$function$
;
CREATE OR REPLACE FUNCTION public.rc_email_uji_koneksi()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_token text; v_from text;
begin
 perform rc_private.require_tab('access.email');
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager' using errcode='42501'; end if;
  v_from := rc_private.rahasia('rc_email_from');
  begin
    v_token := rc_private.gmail_token();
  exception when others then
    return jsonb_build_object('status','error','penyedia','gmail','pesan',sqlerrm);
  end;
  return jsonb_build_object('status','success',
    'pengirim', coalesce(v_from,'(belum diisi)'),
    'gmailSiap', v_token is not null,
    'resendSiap', coalesce(rc_private.rahasia('rc_email_api_key'),'') <> '',
    'pesan', case
      when v_token is not null then 'Gmail siap. Access token berhasil diperoleh.'
      when coalesce(rc_private.rahasia('rc_email_api_key'),'') <> '' then 'Gmail belum dikonfigurasi; akan memakai penyedia cadangan.'
      else 'Belum ada kredensial email sama sekali. Email akan menumpuk di antrean.' end);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_email_kirim_sekarang(p_jenis text, p_test_email text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_susun jsonb; v_id uuid; v_hasil jsonb; v_status text; v_sebab text;
begin
 perform rc_private.require_tab('access.email');
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat mengirim email' using errcode='42501'; end if;

  v_susun := public.rc_email_susun(p_jenis, true, coalesce(p_test_email,''));
  v_id := nullif(v_susun->>'id','')::uuid;
  if v_id is null then
    return jsonb_build_object('status','error',
      'message', coalesce(v_susun->>'message','Email tidak jadi disusun; tidak ada baris antrean.'));
  end if;

  -- Kegagalan pengiriman TIDAK boleh membatalkan baris antreannya: tanpa penangkapan ini,
  -- exception dari kirim_satu_email akan menggulung balik seluruh transaksi termasuk baris
  -- yang baru disusun, dan pengguna tidak punya jejak apa pun untuk diperiksa.
  begin
    v_hasil := rc_private.kirim_satu_email(v_id);
    v_status := coalesce(v_hasil->>'status','');
    if v_status = 'success' then
      return jsonb_build_object('status','success','id',v_id,'terkirim',true,
        'message','Email ' || p_jenis || ' terkirim'
          || case when coalesce(btrim(p_test_email),'') <> ''
                  then ' ke ' || btrim(p_test_email) else '' end || '.');
    end if;
    v_sebab := coalesce(v_hasil->>'sebab','Setelan email belum lengkap.');
    update public.email_outbox set galat = left(v_sebab,500) where id = v_id;
    return jsonb_build_object('status','warning','id',v_id,'terkirim',false,
      'message','Belum terkirim: ' || v_sebab || ' Barisnya tetap di antrean.');
  exception when others then
    v_sebab := sqlerrm;
    update public.email_outbox
       set percobaan = coalesce(percobaan,0) + 1, galat = left(v_sebab,500)
     where id = v_id;
    return jsonb_build_object('status','warning','id',v_id,'terkirim',false,
      'message','Gagal mengirim: ' || left(v_sebab,300));
  end;
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_email_susun(p_jenis text, p_kirim boolean DEFAULT false, p_test_email text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_jenis text; v_set public.email_settings; v_html text; v_subjek text; v_uji text;
  v_depot text[]; v_penerima jsonb; v_id uuid; v_baris integer := 0;
  v_kpi jsonb; v_top jsonb; v_status text; v_region text;
begin
 perform rc_private.require_tab('access.email');
  if not rc_private.is_manager() then
    raise exception 'Hanya Supervisor atau System Manager yang dapat menyusun email'
      using errcode='42501'; end if;
  v_jenis := lower(btrim(coalesce(p_jenis,'')));
  select * into v_set from public.email_settings where jenis = v_jenis;
  if not found then raise exception 'Jenis email "%" tidak dikenali', p_jenis; end if;

  -- Alamat uji hanya diterima bila benar-benar berbentuk alamat email. Sistem lama pernah
  -- mengirim ke "[object Object]" karena argumen trigger ikut dianggap alamat.
  v_uji := btrim(coalesce(p_test_email,''));
  if v_uji <> '' and v_uji !~ '^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$' then
    raise exception 'Alamat uji "%" bukan alamat email yang sah', v_uji;
  end if;

  -- Ringkasan menyeluruh, dipakai kedua jenis email.
  select jsonb_build_object(
    'netCb',coalesce(sum(cb_net),0),
    'netClaimed',coalesce(sum(cb_net) filter (where status='done'),0),
    'osVal',coalesce(sum(cb_net) filter (where outstanding),0),
    'osQty',count(*) filter (where outstanding),
    'cr',case when coalesce(sum(cb_net),0)=0 then 0
         else coalesce(sum(cb_net) filter (where status in('done','expired')),0)/sum(cb_net) end)
    into v_kpi from public.rc_report_rows;

  if v_jenis = 'daily' then
    with r as (
      select d.depot_code, d.depot_name,
             coalesce(sum(c.cb_net),0) net_cb, count(*) qty,
             coalesce(sum(c.cb_net) filter (where c.outstanding),0) os_val,
             count(*) filter (where c.outstanding) os_qty,
             case when coalesce(sum(c.cb_net),0)=0 then 0
                  else coalesce(sum(c.cb_net) filter (where c.status in('done','expired')),0)/sum(c.cb_net) end cr
        from public.rc_report_rows c join public.depots d on d.id=c.depot_id
       group by d.depot_code, d.depot_name
      having coalesce(sum(c.cb_net),0) > 0
         and coalesce(sum(c.cb_net) filter (where c.outstanding),0) > 0
    ), top5 as (select * from r order by cr, os_val desc limit 5)
    select array_agg(depot_code),
           jsonb_agg(jsonb_build_object('label',depot_code||' - '||depot_name,
             'netCb',net_cb,'qty',qty,'osVal',os_val,'osQty',os_qty,'cr',cr)
             order by cr, os_val desc),
           count(*)
      into v_depot, v_top, v_baris from top5;

    if v_baris = 0 then
      insert into public.email_outbox(jenis,tujuan,subjek,isi_html,status,konteks)
      values(v_jenis,'{}','(tidak dikirim)','',
        'skipped',jsonb_build_object('sebab','Tidak ada depot dengan outstanding'))
      returning id into v_id;
      return jsonb_build_object('status','success','dikirim',false,'id',v_id,
        'message','Tidak ada depot dengan outstanding; email tidak disusun.');
    end if;

    v_subjek := coalesce(nullif(btrim(v_set.subjek),''),'Outstanding Claim Report')
                || ' - ' || rc_private.tgl_panjang(now());
    v_html :=
      '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
      ||'<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:720px;"><tr><td>'
      ||'<p>Dear All,</p>'
      ||'<p style="line-height:1.6;">Berikut kami sampaikan <strong>Outstanding Claim Summary per '
        ||rc_private.tgl_panjang(now())||'</strong>.</p>'
      ||'<p style="line-height:1.6;">Saat ini terdapat <strong>'||rc_private.angka((v_kpi->>'osQty')::numeric)
        ||' klaim</strong> yang masih outstanding dengan total nilai sebesar <strong>'
        ||rc_private.rupiah((v_kpi->>'osVal')::numeric)||'</strong>, dengan <strong>overall Clearing Rate sebesar '
        ||rc_private.persen((v_kpi->>'cr')::numeric)||'</strong>.</p>'
      ||'<h3 style="font-size:15px;margin:22px 0 8px;">Top 5 Depot dengan Clearing Rate Terendah</h3>'
      ||rc_private.email_chart_depot(v_top,'Top 5 Depot dengan Clearing Rate Terendah')
      ||rc_private.email_tabel_performa(v_top,'Depot')
      ||'<p style="line-height:1.6;margin-top:22px;">Kami mohon perhatian dan dukungan dari masing-masing '
        ||'<strong>Depot dan Management</strong> untuk dapat segera melakukan <strong>follow-up dan percepatan '
        ||'penyelesaian Outstanding Claim</strong>, khususnya pada Depot dengan Clearing Rate yang masih rendah.</p>'
      ||'<p style="line-height:1.6;">Thank you for your attention and cooperation.</p>'
      ||rc_private.email_ttd()
      ||'</td></tr></table></div>';
    v_penerima := rc_private.penerima_depot(v_depot);

  elsif v_jenis = 'weekly' then
    select array_agg(depot_code) into v_depot from public.depots
     where coalesce(btrim(email_to),'') <> '' or coalesce(btrim(email_cc),'') <> '';
    v_penerima := rc_private.penerima_depot(coalesce(v_depot,'{}'));

    with r as (
      select d.depot_code, d.depot_name,
             coalesce(sum(c.cb_net),0) net_cb, count(*) qty,
             coalesce(sum(c.cb_net) filter (where c.outstanding),0) os_val,
             count(*) filter (where c.outstanding) os_qty,
             case when coalesce(sum(c.cb_net),0)=0 then 0
                  else coalesce(sum(c.cb_net) filter (where c.status in('done','expired')),0)/sum(c.cb_net) end cr
        from public.rc_report_rows c join public.depots d on d.id=c.depot_id
       group by d.depot_code, d.depot_name
      having coalesce(sum(c.cb_net),0) > 0)
    select jsonb_agg(jsonb_build_object('label',depot_code||' - '||depot_name,
             'netCb',net_cb,'qty',qty,'osVal',os_val,'osQty',os_qty,'cr',cr) order by cr, os_val desc)
      into v_top from (select * from r order by cr, os_val desc limit 10) t;

    -- Distribusi status, pengelompokan persis WEEKLY_STATUS_GROUPS.
    select string_agg(
      '<tr><td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;">'
      ||'<span style="display:inline-block;width:10px;height:10px;background:'||g.warna||';margin-right:6px;"></span>'
      ||g.label||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'
      ||rc_private.angka(g.qty)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'
      ||'<strong>'||rc_private.persen(g.pct)||'</strong></td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'
      ||rc_private.rupiah(g.nilai)||'</td></tr>', '' order by g.urut)
      into v_status
    from (
      select x.urut, x.label, x.warna,
             count(c.id) qty, coalesce(sum(c.cb_net),0) nilai,
             case when (select count(*) from public.rc_report_rows)=0 then 0
                  else count(c.id)::numeric/(select count(*) from public.rc_report_rows) end pct
      from (values
        (1,'Done','#34A853',array['done']),
        (2,'Expired','#7B1E1E',array['expired']),
        (3,'Pending Depot','#EA4335',array['not_yet']),
        (4,'Pending OSC','#FF9900',array['submitted','released']),
        (5,'Pending Finance','#4285F4',array['claimed']),
        (6,'Lainnya','#9AA0A6',array[]::text[])
      ) as x(urut,label,warna,status_list)
      left join public.rc_report_rows c on
        case when x.urut = 6
             then c.status <> all(array['done','expired','not_yet','submitted','released','claimed'])
             else c.status = any(x.status_list) end
      group by x.urut, x.label, x.warna) g;

    -- Value dan outstanding per Region, urut dari outstanding terbesar.
    select string_agg(
      '<tr><td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;">Region '
      ||rc_private.html_aman(q.region)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'||rc_private.rupiah(q.net_cb)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'||rc_private.rupiah(q.done_val)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'||rc_private.rupiah(q.os_val)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'||rc_private.angka(q.os_qty)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;background-color:'
      ||rc_private.warna_persen(q.cr)||';color:#ffffff;font-weight:bold;" bgcolor="'||rc_private.warna_persen(q.cr)||'">'
      ||rc_private.persen(q.cr)||'</td></tr>', '' order by q.os_val desc)
      into v_region
    from (
      select coalesce(nullif(btrim(region),''),'(tanpa region)') region,
             coalesce(sum(cb_net),0) net_cb,
             coalesce(sum(cb_net) filter (where status='done'),0) done_val,
             coalesce(sum(cb_net) filter (where outstanding),0) os_val,
             count(*) filter (where outstanding) os_qty,
             case when coalesce(sum(cb_net),0)=0 then 0
                  else coalesce(sum(cb_net) filter (where status in('done','expired')),0)/sum(cb_net) end cr
        from public.rc_report_rows group by 1
       having coalesce(sum(cb_net),0) > 0) q;

    v_subjek := coalesce(nullif(btrim(v_set.subjek),''),'Weekly Outstanding Claim Summary')
                || ' - ' || rc_private.tgl_panjang(now());
    v_html :=
      '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
      ||'<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:760px;"><tr><td>'
      ||'<p>Dear All,</p>'
      ||'<p style="line-height:1.6;">Berikut kami sampaikan <strong>Weekly Outstanding Claim Summary</strong> '
        ||'untuk periode <strong>'||rc_private.tgl_panjang(now() - interval '6 days')||' s/d '
        ||rc_private.tgl_panjang(now())||'</strong>.</p>'
      ||'<p style="line-height:1.6;">Summary ini memberikan overview terkait performa clearing claim, '
        ||'trend claim, distribusi status claim, serta outstanding value berdasarkan Region.</p>'
      -- Kartu KPI (buildWeeklyKpiCardsHtml)
      ||'<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin:18px 0 6px;"><tr>'
      ||'<td width="25%" style="padding:10px 12px;border:1px solid #e0e2e6;vertical-align:top;">'
        ||'<div style="font-size:10px;color:#5f6368;text-transform:uppercase;letter-spacing:.03em;">Total Net CB</div>'
        ||'<div style="font-size:16px;font-weight:bold;color:#202124;margin-top:4px;">'||rc_private.rupiah_ringkas((v_kpi->>'netCb')::numeric)||'</div></td>'
      ||'<td width="25%" style="padding:10px 12px;border:1px solid #e0e2e6;vertical-align:top;">'
        ||'<div style="font-size:10px;color:#5f6368;text-transform:uppercase;letter-spacing:.03em;">Net Claimed (Done)</div>'
        ||'<div style="font-size:16px;font-weight:bold;color:#34A853;margin-top:4px;">'||rc_private.rupiah_ringkas((v_kpi->>'netClaimed')::numeric)||'</div></td>'
      ||'<td width="25%" style="padding:10px 12px;border:1px solid #e0e2e6;vertical-align:top;">'
        ||'<div style="font-size:10px;color:#5f6368;text-transform:uppercase;letter-spacing:.03em;">Outstanding</div>'
        ||'<div style="font-size:16px;font-weight:bold;color:#EA4335;margin-top:4px;">'
        ||rc_private.rupiah_ringkas((v_kpi->>'osVal')::numeric)||' / '||rc_private.angka((v_kpi->>'osQty')::numeric)||' klaim</div></td>'
      ||'<td width="25%" style="padding:10px 12px;border:1px solid #e0e2e6;vertical-align:top;">'
        ||'<div style="font-size:10px;color:#5f6368;text-transform:uppercase;letter-spacing:.03em;">Clearing Rate</div>'
        ||'<div style="font-size:16px;font-weight:bold;color:#1a7f37;margin-top:4px;">'||rc_private.persen((v_kpi->>'cr')::numeric)||'</div></td>'
      ||'</tr></table>'
      ||'<h3 style="font-size:15px;margin:26px 0 8px;border-left:4px solid #4285F4;padding-left:8px;">Tren Qty &amp; Value per Minggu</h3>'
      ||rc_private.email_chart_tren()
      ||rc_private.email_tabel_tren()
      ||'<h3 style="font-size:15px;margin:26px 0 8px;border-left:4px solid #4285F4;padding-left:8px;">Top 10 Depot dengan Clearing Rate Terendah</h3>'
      ||rc_private.email_chart_depot(coalesce(v_top,'[]'::jsonb),'Top 10 Depot dengan Clearing Rate Terendah')
      ||rc_private.email_tabel_performa(coalesce(v_top,'[]'::jsonb),'Depot')
      ||'<h3 style="font-size:15px;margin:26px 0 8px;border-left:4px solid #4285F4;padding-left:8px;">Distribusi Status Claim</h3>'
      ||rc_private.email_chart_status()
      ||'<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
        ||'<thead><tr>'
        ||'<th style="text-align:left;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Status</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Qty</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">%</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Value (Net CB)</th>'
        ||'</tr></thead><tbody>'||coalesce(v_status,'')||'</tbody></table>'
      ||'<p style="font-size:11px;color:#5f6368;margin:6px 0 0;">Pending Depot = menunggu Depot compile ke OSC '
        ||'(status mentah "Not Yet"). Pending OSC = menunggu penyelesaian OSC (Submitted &amp; Released). '
        ||'Pending Finance = menunggu penyelesaian Finance (Claimed). Lainnya = status belum terpetakan.</p>'
      ||'<h3 style="font-size:15px;margin:26px 0 8px;border-left:4px solid #4285F4;padding-left:8px;">Value Claim &amp; Outstanding by Region</h3>'
      ||rc_private.email_chart_region()
      ||case when coalesce(v_region,'') = '' then '<p style="color:#5f6368;">Tidak ada data Region.</p>'
        else '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
        ||'<thead><tr>'
        ||'<th style="text-align:left;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Region</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Net CB</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Claim Value (Done)</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Outstanding</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Outstanding Qty</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Clearing Rate</th>'
        ||'</tr></thead><tbody>'||v_region||'</tbody></table>' end
      ||rc_private.email_tautan_dashboard()
      ||rc_private.email_ttd()
      ||'</td></tr></table></div>';

  elsif v_jenis = 'timetable' then
    select array_agg(depot_code) into v_depot from public.depots
     where coalesce(btrim(email_to),'') <> '' or coalesce(btrim(email_cc),'') <> '';
    v_penerima := rc_private.penerima_depot(coalesce(v_depot,'{}'));
    v_subjek := v_set.subjek || ' - ' || rc_private.tgl_panjang(now());
    v_html :=
      '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
      ||'<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:720px;"><tr><td>'
      ||'<p>Dear All,</p>'
      ||'<p style="line-height:1.6;">Berikut ringkasan <strong>Timetable Compile</strong> per '
        ||rc_private.tgl_panjang(now())||'.</p>'
      ||'<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:14px 0;">'
      ||'<tr><td style="font-size:13px;padding:6px 16px 6px 0;">Campaign aktif</td>'
        ||'<td style="font-size:13px;padding:6px 0;font-weight:bold;">'
        ||(select count(*) from public.campaigns
            where period_start is not null and period_start<=current_date
              and coalesce(period_end,current_date)>=current_date
              and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=campaigns.id))||'</td></tr>'
      ||'<tr><td style="font-size:13px;padding:6px 16px 6px 0;">Depot dipantau</td>'
        ||'<td style="font-size:13px;padding:6px 0;font-weight:bold;">'
        ||(select count(*) from public.depots)||'</td></tr>'
      ||'<tr><td style="font-size:13px;padding:6px 16px 6px 0;">Pasangan ditandai Not Achieved</td>'
        ||'<td style="font-size:13px;padding:6px 0;font-weight:bold;color:#EA4335;">'
        ||(select count(*) from public.timetable_not_achieved)||'</td></tr></table>'
      ||'<p style="line-height:1.6;">Buka modul Timetable pada aplikasi RC untuk matrix lengkapnya.</p>'
      ||'<p style="line-height:1.6;">Thank you for your attention and cooperation.</p>'
      ||rc_private.email_ttd()
      ||'</td></tr></table></div>';
  else
    raise exception 'Jenis email "%" tidak dikenali', p_jenis;
  end if;

  -- Pengujian mengabaikan pemetaan penerima sepenuhnya.
  if v_uji <> '' then
    v_penerima := jsonb_build_object('to', jsonb_build_array(v_uji), 'cc', '[]'::jsonb);
    v_subjek := '[UJI] ' || v_subjek;
  end if;

  if coalesce(jsonb_array_length(v_penerima->'to'),0) = 0 then
    insert into public.email_outbox(jenis,tujuan,subjek,isi_html,status,galat,konteks)
    values(v_jenis,'{}',v_subjek,v_html,'skipped',
      'Belum ada alamat TO pada master depot',jsonb_build_object('depot',to_jsonb(v_depot)))
    returning id into v_id;
    return jsonb_build_object('status','success','dikirim',false,'id',v_id,
      'subjek',v_subjek,'isiHtml',v_html,
      'message','Isi email tersusun, tetapi belum ada satu pun alamat TO di Key Master > Depot Master.');
  end if;

  insert into public.email_outbox(jenis,tujuan,cc,subjek,isi_html,status,konteks)
  values(v_jenis,
    array(select jsonb_array_elements_text(v_penerima->'to')),
    array(select jsonb_array_elements_text(v_penerima->'cc')),
    v_subjek, v_html,
    case when coalesce(p_kirim,false) then 'pending' else 'skipped' end,
    jsonb_build_object('depot',to_jsonb(v_depot),'preview',not coalesce(p_kirim,false),
                       'uji',v_uji <> ''))
  returning id into v_id;

  return jsonb_build_object('status','success','id',v_id,
    'dikirim',coalesce(p_kirim,false),
    'penerima',v_penerima,
    'subjek',v_subjek,
    'isiHtml',v_html,
    'message',case when coalesce(p_kirim,false)
      then case when v_uji <> '' then 'Email uji dimasukkan ke antrean untuk ' || v_uji || '.'
                else 'Email dimasukkan ke antrean pengiriman.' end
      else 'Pratinjau tersusun. Tidak ada yang dikirim.' end);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_email_batalkan(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.email_outbox;
begin
 perform rc_private.require_tab('access.email');
  if not rc_private.is_manager() then
    raise exception 'Hanya Supervisor atau System Manager yang dapat membatalkan email'
      using errcode='42501'; end if;
  select * into v from public.email_outbox where id = p_id for update;
  if not found then raise exception 'Email tidak ditemukan'; end if;
  if v.status not in ('pending','failed') then
    raise exception 'Email berstatus % tidak dapat dibatalkan', v.status; end if;

  update public.email_outbox
     set status = 'skipped', galat = 'Dibatalkan dari layar Access Management'
   where id = p_id;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'email_dibatalkan',p_id,
    jsonb_build_object('jenis',v.jenis,'subjek',v.subjek,'tujuan',to_jsonb(v.tujuan)));

  return jsonb_build_object('status','success','message','Email dibatalkan dan tidak akan dikirim.');
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_campaign_exclude(p_codes jsonb, p_kecualikan boolean DEFAULT true, p_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n integer := 0;
begin
 perform rc_private.require_tab('access.exclude');
  if not rc_private.can_access(null,'manage_timetable') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak mengubah pengecualian campaign' using errcode='42501'; end if;
  if jsonb_typeof(p_codes)<>'array' then raise exception 'Campaign harus berupa daftar'; end if;

  if coalesce(p_kecualikan,true) then
    with ditulis as (
      insert into public.excluded_campaigns(campaign_id,excluded_by,reason)
      select c.id,(select auth.uid()),left(btrim(coalesce(p_reason,'')),200)
        from jsonb_array_elements_text(p_codes) x
        join public.campaigns c on c.campaign_code=btrim(x.value)
      on conflict(campaign_id) do update set excluded_at=now(), reason=excluded.reason
      returning 1)
    select count(*) into n from ditulis;
  else
    with dihapus as (
      delete from public.excluded_campaigns e
       using public.campaigns c
       where e.campaign_id=c.id
         and c.campaign_code = any(select btrim(value) from jsonb_array_elements_text(p_codes))
      returning 1)
    select count(*) into n from dihapus;
  end if;

  return jsonb_build_object('status','success','jumlah',n,
    'message', n||case when coalesce(p_kecualikan,true)
      then ' campaign dikecualikan dari seluruh laporan'
      else ' campaign dikembalikan ke laporan' end);
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_depot_grade_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$select rc_private.require_tab('access.grade');
  select jsonb_build_object('status','success','rows', coalesce(jsonb_agg(jsonb_build_object(
      'kode',d.depot_code,'nama',d.depot_name,
      'region',coalesce(d.region,''),
      'grade',coalesce(p.grade,''),
      'tipe',coalesce(p.tipe_depot,''))
      order by d.depot_code),'[]'::jsonb))
    from public.depots d
    left join public.depot_profiles p on p.depot_id = d.id
   where rc_private.is_system_manager();
$function$
;
CREATE OR REPLACE FUNCTION public.rc_depot_grade_set(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb; v_depot uuid; n integer := 0;
begin
 perform rc_private.require_tab('access.grade');
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat menetapkan Grade Depot' using errcode='42501'; end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    select id into v_depot from public.depots where depot_code = upper(btrim(r->>'kode'));
    if v_depot is null then continue; end if;
    insert into public.depot_profiles(depot_id, grade, tipe_depot)
    values(v_depot, nullif(btrim(coalesce(r->>'grade','')),''), nullif(btrim(coalesce(r->>'tipe','')),''))
    on conflict(depot_id) do update set
      grade = nullif(btrim(coalesce(r->>'grade','')),''),
      tipe_depot = case when r ? 'tipe' then nullif(btrim(coalesce(r->>'tipe','')),'') else public.depot_profiles.tipe_depot end,
      updated_at = now(), updated_by = (select auth.uid());
    n := n + 1;
  end loop;
  return jsonb_build_object('status','success','jumlah',n,'message',n||' depot diperbarui');
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_approval_batches(p_kind text DEFAULT 'wpt'::text, p_depot text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v_ovd boolean; v_depot text; hasil jsonb;
begin
 perform rc_private.require_tab('approval.'||lower(coalesce(p_kind,'wpt')));
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak menyetujui dokumen' using errcode='42501'; end if;
  v_ovd := lower(coalesce(p_kind,'wpt')) = 'ovd';
  if v_ovd and not rc_private.boleh_approve_overdue() then
    raise exception 'Depot Head hanya dapat menyetujui dokumen Within Payment Term'
      using errcode='42501'; end if;
  v_depot := nullif(btrim(coalesce(p_depot,'')),'');

  select jsonb_build_object('status','success','kind', case when v_ovd then 'ovd' else 'wpt' end,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'noBatch', t.batch, 'kodeDepot', t.depot_code, 'namaDepot', t.depot_name,
      'qtyDoc', t.qty_doc, 'qtyCust', t.qty_cust,
      'qtyCampaign', t.qty_camp, 'totalNetCb', t.net_cb,
      'submittedBy', t.submitted_by, 'postingDate', t.posting_date)
      order by t.posting_date desc nulls last, t.batch), '[]'::jsonb))
  into hasil
  from (
    select coalesce(nullif(btrim(r.batch_upload),''),'(tanpa batch)') batch,
           coalesce(d.depot_code,'-') depot_code,
           coalesce(d.depot_name,'-') depot_name,
           count(*) qty_doc,
           count(distinct r.customer_code) qty_cust,
           count(distinct r.campaign_code) qty_camp,
           coalesce(sum(r.cb_net),0) net_cb,
           coalesce(string_agg(distinct p.full_name, ', '),'-') submitted_by,
           to_char(max(r.uploaded_at) at time zone 'Asia/Jakarta','DD-Mon-YYYY') posting_date
      from rc_private.approval_rows r
      left join public.profiles p on p.id = r.submitted_by
      left join public.depots d on d.id = r.depot_id
     where rc_private.can_access(r.depot_id,'approve_claim')
       and rc_private.approval_overdue(r.top_aktual, r.top_setting) = v_ovd
       and (v_depot is null or d.depot_code = v_depot)
     group by 1,2,3) t;
  return hasil;
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_approval_detail(p_batch text, p_kind text DEFAULT 'wpt'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v_ovd boolean; hasil jsonb;
begin
 perform rc_private.require_tab('approval.'||lower(coalesce(p_kind,'wpt')));
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak menyetujui dokumen' using errcode='42501'; end if;
  v_ovd := lower(coalesce(p_kind,'wpt')) = 'ovd';
  if v_ovd and not rc_private.boleh_approve_overdue() then
    raise exception 'Depot Head hanya dapat menyetujui dokumen Within Payment Term'
      using errcode='42501'; end if;

  select jsonb_build_object('status','success','noBatch',p_batch,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'noDoc', r.no_doc, 'versionNo', r.version_no,
      'kodeCust', r.customer_code, 'namaCust', r.customer_name,
      'kodeCampaign', r.campaign_code, 'namaCampaign', coalesce(r.campaign_name,''),
      'netCb', r.cb_net, 'jenisCb', r.jenis_cb_label,
      'topSetting', coalesce(r.top_setting,''),
      'topAktual', coalesce(r.top_aktual,''),
      -- Selisihnya dihitung sekali di sini supaya layar tidak perlu menghitung ulang dan
      -- berisiko memakai aturan yang berbeda.
      'topSelisih', case
        when r.top_aktual ~ '^[0-9]+([.][0-9]+)?$' and r.top_setting ~ '^[0-9]+([.][0-9]+)?$'
        then r.top_aktual::numeric - r.top_setting::numeric else null end,
      'statusPajak', coalesce(r.tax_subject,''),
      'statusPajakCampaign', coalesce(r.tax_status,''),
      'submittedBy', coalesce(ps.full_name,''),
      'postingDate', to_char(r.uploaded_at at time zone 'Asia/Jakarta','DD-Mon-YYYY'),
      'approvedBy', coalesce(pa.full_name,''),
      'approvedAt', to_char(r.approved_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI'),
      'overdue', rc_private.approval_overdue(r.top_aktual, r.top_setting))
      order by r.no_doc), '[]'::jsonb))
  into hasil
  from rc_private.approval_rows r
  left join public.profiles ps on ps.id = r.submitted_by
  left join public.profiles pa on pa.id = r.approved_by
  where coalesce(nullif(btrim(r.batch_upload),''),'(tanpa batch)') = coalesce(p_batch,'')
    and rc_private.can_access(r.depot_id,'approve_claim')
    and rc_private.approval_overdue(r.top_aktual, r.top_setting) = v_ovd;
  return hasil;
end $function$;
CREATE OR REPLACE FUNCTION public.rc_approval_hold(p_depot text DEFAULT NULL::text, p_search text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare hasil jsonb; v_depot text; v_cari text;
begin
 perform rc_private.require_tab('approval.hold');
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
      'statusPengajuan',rc_private.legacy_status(t.pending_approval->>'target_status'),
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
    select c.no_doc, c.version_no, c.status, c.pending_approval, c.previous_status, c.cb_net, c.batch_upload,
           d.depot_code, d.depot_name, cu.customer_code, cu.customer_name,
           ca.campaign_code, ca.campaign_name, ca.cashback_type,
           c.pending_approval->>'reason' as reason, (c.pending_approval->>'requested_at')::timestamptz as changed_at, p.full_name as actor_name
      from public.claims c
      left join public.depots d on d.id = c.depot_id
      left join public.customers cu on cu.id = c.customer_id
      left join public.campaigns ca on ca.id = c.campaign_id
      left join public.profiles p on p.id = (c.pending_approval->>'requested_by')::uuid
     where c.pending_approval->>'kind' in('hold','expire')
       and c.archived_at is null
       and rc_private.can_access(c.depot_id,'approve_claim')
       and (v_depot is null or d.depot_code = v_depot)
       and (v_cari is null or (
            c.no_doc ilike '%'||v_cari||'%'
         or coalesce(cu.customer_code,'') ilike '%'||v_cari||'%'
         or coalesce(cu.customer_name,'') ilike '%'||v_cari||'%'
         or coalesce(ca.campaign_code,'') ilike '%'||v_cari||'%'
         or coalesce(ca.campaign_name,'') ilike '%'||v_cari||'%'
         or coalesce(d.depot_code,'') ilike '%'||v_cari||'%'
         or coalesce(c.pending_approval->>'reason','') ilike '%'||v_cari||'%'))) t;
  return hasil;
end $function$;
CREATE OR REPLACE FUNCTION public.rc_approval_history(p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_search text DEFAULT NULL::text, p_depot text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare hasil jsonb; v_total bigint; v_cari text; v_depot text; v_limit int; v_offset int;
begin
 perform rc_private.require_tab('approval.history');
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat riwayat approval' using errcode='42501'; end if;

  v_cari   := nullif(btrim(coalesce(p_search,'')),'');
  v_depot  := nullif(btrim(coalesce(p_depot,'')),'');
  v_limit  := greatest(1, least(coalesce(p_limit,50), 500));
  v_offset := greatest(0, coalesce(p_offset,0));

  -- Jumlah total dihitung dengan penyaring yang SAMA. Menghitungnya tanpa penyaring akan
  -- membuat nomor halaman menjanjikan baris yang tidak pernah muncul.
  with dasar as (
    select h.created_at, c.no_doc, h.batch, h.action, h.from_status, h.to_status,
           p.full_name, h.reason, d.depot_code, d.depot_name
      from public.claim_status_history h
      join public.claims c on c.id = h.claim_id
      left join public.depots d on d.id = c.depot_id
      left join public.profiles p on p.id = h.actor_id
     where h.action in ('approve','reject_approval')
       and rc_private.can_access(c.depot_id,'approve_claim')
       and (v_depot is null or d.depot_code = v_depot)
       and (v_cari is null or (
            c.no_doc ilike '%'||v_cari||'%'
         or coalesce(h.batch,'') ilike '%'||v_cari||'%'
         or coalesce(p.full_name,'') ilike '%'||v_cari||'%'
         or coalesce(h.reason,'') ilike '%'||v_cari||'%'
         or coalesce(d.depot_code,'') ilike '%'||v_cari||'%'
         or coalesce(d.depot_name,'') ilike '%'||v_cari||'%'))
  )
  select count(*) into v_total from dasar;

  with dasar as (
    select h.created_at, c.no_doc, h.batch, h.action, h.from_status, h.to_status,
           p.full_name, h.reason, d.depot_code, d.depot_name
      from public.claim_status_history h
      join public.claims c on c.id = h.claim_id
      left join public.depots d on d.id = c.depot_id
      left join public.profiles p on p.id = h.actor_id
     where h.action in ('approve','reject_approval')
       and rc_private.can_access(c.depot_id,'approve_claim')
       and (v_depot is null or d.depot_code = v_depot)
       and (v_cari is null or (
            c.no_doc ilike '%'||v_cari||'%'
         or coalesce(h.batch,'') ilike '%'||v_cari||'%'
         or coalesce(p.full_name,'') ilike '%'||v_cari||'%'
         or coalesce(h.reason,'') ilike '%'||v_cari||'%'
         or coalesce(d.depot_code,'') ilike '%'||v_cari||'%'
         or coalesce(d.depot_name,'') ilike '%'||v_cari||'%'))
     order by h.created_at desc
     limit v_limit offset v_offset
  )
  select jsonb_build_object('status','success','total',v_total,
    'limit', v_limit, 'offset', v_offset,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'waktu', to_char(t.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI'),
      'noDoc', t.no_doc, 'noBatch', coalesce(t.batch,''),
      'kodeDepot', coalesce(t.depot_code,'-'),
      'tindakan', case when t.action='approve' then 'Approve' else 'Reject' end,
      'dari', rc_private.legacy_status(t.from_status),
      'ke', rc_private.legacy_status(t.to_status),
      'oleh', coalesce(t.full_name,''), 'alasan', coalesce(t.reason,''))
      order by t.created_at desc), '[]'::jsonb))
  into hasil from dasar t;
  return hasil;
end $function$
;
CREATE OR REPLACE FUNCTION public.rc_legacy_workflow()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare rows_json jsonb; nama jsonb;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 nama := rc_private.peta_nama_pelaku();

 select coalesce(jsonb_agg(x),'[]'::jsonb) into rows_json from (
  select jsonb_build_object(
   'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
   'depot',d.depot_name,'kodeDepot',d.depot_code,
   'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'statusPajakCamp',coalesce(ca.tax_status,''),
   'statusPajakCust',coalesce(c.tax_subject,''),
   'cbNet',c.cb_net,'grossUpCb',c.gross_up,'totTagih',c.total_billing,
   'periodeStart',rc_private.legacy_date(c.period_start),'periodeEnd',rc_private.legacy_date(c.period_end),
   'tglLunas',rc_private.legacy_date(c.paid_on),
   'tglUpload',rc_private.legacy_ts(c.uploaded_at),'tglRelease',rc_private.legacy_ts(c.released_at),
   'tglClaim',rc_private.legacy_ts(c.claimed_at),'tglClearing',rc_private.legacy_ts(c.cleared_at),
   'tglProses',case when c.status='done' and c.cleared_at is not null
                    then rc_private.legacy_ts(c.cleared_at) else '-' end,
   'batchUpload',coalesce(c.batch_upload,''),'batchRelease',coalesce(c.batch_release,''),
   'batchClaim',coalesce(c.batch_claim,''),'batchClearing',coalesce(c.batch_clearing,''),
   'approval',coalesce(c.approval,''),'top',coalesce(s.top_text,''),
   'ktp',coalesce(s.ktp,''),'npwp',coalesce(s.npwp,''),'bankCust',coalesce(s.bank,''),
   'bank',coalesce(s.bank,''),'noRekening',coalesce(s.account_number,''),
   'namaRekening',coalesce(s.account_name,''),'pemilikRekening',coalesce(s.account_name,''),
   'contactPerson',coalesce(cu.contact_person,''),
   -- Pelaku tiap tahap. Kosong berarti tidak tercatat, bukan tidak pernah terjadi.
   'createdBy',coalesce(nama->>(c.created_by::text),''),
   'submittedBy',coalesce(nama->>(pel.submit_by::text),''),
   'approvedBy',coalesce(nama->>(pel.approve_by::text),''),
   'tglApprove',rc_private.legacy_ts(c.approved_at),
   'releasedBy',coalesce(nama->>(pel.release_by::text),''),
   'claimedBy',coalesce(nama->>(pel.claim_by::text),''),
   'clearedBy',coalesce(nama->>(pel.clear_by::text),''),
   'versionNo',c.version_no,'remark',rc_private.claim_remark(c), 'campaignYear',extract(year from coalesce(c.period_start,ca.period_start)),
   'rebate',lower(btrim(rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type))))='rebate') as x
  from public.claims c
  left join public.depots d on d.id=c.depot_id
  left join public.customers cu on cu.id=c.customer_id
  left join public.campaigns ca on ca.id=c.campaign_id
  left join rc_private.claim_sensitive s on s.claim_id=c.id
  -- Pelaku terakhir untuk tiap tahap. Yang diambil yang terbaru: sebuah dokumen dapat
  -- ditolak lalu di-release ulang, dan yang relevan adalah pelaku terakhir.
  left join lateral (
    select
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.action='submit' and h.actor_id is not null))[1] as submit_by,
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='approved' and h.actor_id is not null))[1] as approve_by,
         (array_agg(h.actor_id order by h.created_at desc)
         filter (where h.to_status='released' and h.actor_id is not null))[1] as release_by,
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='claimed' and h.actor_id is not null))[1] as claim_by,
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='done' and h.actor_id is not null))[1] as clear_by
    from public.claim_status_history h where h.claim_id = c.id) pel on true
  where c.archived_at is null and rc_private.can_access(c.depot_id) and c.status in('approved','released','claimed') and c.pending_approval is null
  order by c.updated_at desc,c.id limit 5000) t;

 -- Rebate dipisah tegas: tidak muncul di antrean bertahap, hanya di Bulk Process.
 return jsonb_build_object('status','success',
  'releaseData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where rc_private.can_tab('release.list') and v->>'status'='Approved' and not (v->>'rebate')::boolean),
  'claimFinData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where rc_private.can_tab('process.claimFin') and v->>'status'='Released' and not (v->>'rebate')::boolean),
  'clearingData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where rc_private.can_tab('process.clearing') and v->>'status'='Claimed' and not (v->>'rebate')::boolean),
  'bulkRebateData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where rc_private.can_tab('bulk.rebate') and (v->>'rebate')::boolean and v->>'status' <> 'Submitted'));
end $function$;
CREATE OR REPLACE FUNCTION rc_private.mutate_claims_unchecked(p_action text, p_items jsonb, p_request_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid(); perm text; v_payload jsonb; cached rc_private.requests%rowtype;
 c public.claims%rowtype; item jsonb; target text; batch text; stage text; subject text;
 processed jsonb:='[]'; stamp timestamptz:=now(); expire_batch text;
 cust public.customers%rowtype; camp public.campaigns%rowtype; jenis text; v_jenis_input text;
 v_ktp text; v_npwp text; v_bank text; v_norek text; v_namarek text; v_top text; v_gross numeric;
 master_top numeric; input_top numeric; master_changed boolean;
begin
 if p_action not in('submit','release','claim','clearing','reject_release','reject_claim','reject_clearing','hold','unhold','expire','bulk_rebate','approve','reject_approval','approve_hold','reject_hold','expire_claim_process')
 or p_action is null then raise exception 'Unknown action'; end if;
 perm:=case when p_action in('submit','hold','unhold','expire') then 'upload_claim'
 when p_action in('approve','reject_approval','approve_hold','reject_hold') then 'approve_claim'
 when p_action in('release','reject_release') then 'release_claim'
 when p_action='bulk_rebate' then 'bulk_process' else 'process_claim' end;
 if not rc_private.can_access(null,perm) then raise exception 'Access denied' using errcode='42501'; end if;
 -- Menahan dan menghanguskan adalah keputusan yang lebih berat daripada menyetujui tempo
 -- pembayaran, jadi peran yang berwenang memutuskannya dibatasi tersendiri. Jangkauannya
 -- tetap dijaga can_access pada tiap baris di bawah.
 if p_action in('approve_hold','reject_hold') and not rc_private.boleh_putus_hold() then
  raise exception 'Keputusan On Hold dan Expired ditetapkan OSC, Supervisor, Management atau System Manager' using errcode='42501'; end if;
 if p_action='submit' and (not (rc_private.can_tab('upload.mass') or rc_private.can_tab('upload.single')) or (jsonb_array_length(p_items)>1 and not rc_private.can_tab('upload.mass'))) then raise exception 'Izin Mass Upload diperlukan' using errcode='42501';end if;
 if p_action in('hold','unhold','expire') then perform rc_private.require_tab('upload.mass');end if;
 if p_action in('release','reject_release') then perform rc_private.require_tab('release.list');end if;
 if p_action in('claim','reject_claim') then perform rc_private.require_tab('process.claimFin');end if;
 if p_action in('clearing','reject_clearing') then perform rc_private.require_tab('process.clearing');end if;
 if p_action='bulk_rebate' then perform rc_private.require_tab('bulk.rebate');end if;
 if p_action in('approve_hold','reject_hold') then perform rc_private.require_tab('approval.hold');end if;
 if p_request_id is null or p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Invalid request'; end if;
 if jsonb_array_length(p_items) not between 1 and 500 then raise exception 'Satu proses maksimal 500 dokumen'; end if;
 if length(coalesce(p_reason,''))>1000 then raise exception 'Reason too long'; end if;
 if p_action in('reject_release','reject_claim','reject_clearing','hold','unhold','expire','expire_claim_process') and btrim(coalesce(p_reason,''))='' then raise exception 'Reason required'; end if;
 if exists(select 1 from jsonb_array_elements(p_items) x where jsonb_typeof(x)<>'object' or coalesce(x->>'no_doc','')='' or x->>'version_no' is null)
 or (select count(distinct x->>'no_doc') from jsonb_array_elements(p_items) x)<>jsonb_array_length(p_items)
 then raise exception 'Each claim must have a unique document number and version'; end if;
 v_payload:=jsonb_build_object('action',p_action,'items',p_items,'reason',p_reason);
 insert into rc_private.requests(actor_id,request_id,payload) values(actor,p_request_id,v_payload) on conflict do nothing;
 select * into strict cached from rc_private.requests where actor_id=actor and request_id=p_request_id for update;
 if cached.payload<>v_payload then raise exception 'Request ID reused for different payload'; end if;
 if cached.result is not null then return cached.result; end if;
 -- Expired kini ikut memperoleh nomor batch, dan nomornya diterbitkan pada tahap Clearing
 -- sesuai permintaan pemilik: dokumen yang di-Expired harus tetap terlihat nomor batch-nya,
 -- dan tempatnya di kolom Clearing.
 stage:=case p_action when 'submit' then '01' when 'release' then '02' when 'claim' then '03'
   when 'clearing' then '04' when 'expire_claim_process' then '04' when 'bulk_rebate' then '02' end;

 for item in select value from jsonb_array_elements(p_items) order by value->>'no_doc' loop
 select * into c from public.claims where no_doc=item->>'no_doc' for update;
 if not found then raise exception 'Document not found'; end if;
 if c.archived_at is not null then raise exception 'Dokumen % sudah diarsipkan',c.no_doc; end if;
 if not rc_private.can_access(c.depot_id,perm) then raise exception 'Depot access denied' using errcode='42501'; end if;
 if c.version_no<>(item->>'version_no')::bigint then raise exception 'Document changed; refresh first' using errcode='40001'; end if;
 if c.pending_approval is not null and not (
   (c.pending_approval->>'kind'='submit' and p_action in('approve','reject_approval'))
   or (c.pending_approval->>'kind' in('hold','expire') and p_action in('approve_hold','reject_hold'))
 ) then raise exception 'Dokumen % masih menunggu approval',c.no_doc; end if;
 if p_action='expire_claim_process' then perform rc_private.require_tab(case when c.status='released' then 'process.claimFin' else 'process.clearing' end);end if;
 if p_action in('approve','reject_approval') then
  perform rc_private.require_tab(case when exists(select 1 from rc_private.approval_rows ar where ar.id=c.id and rc_private.approval_overdue(ar.top_aktual,ar.top_setting)) then 'approval.ovd' else 'approval.wpt' end);
 end if;
 select * into camp from public.campaigns where id=c.campaign_id;
 -- Jenis CB berasal dari Campaign Master, tetapi pengguna boleh menimpanya per dokumen.
 -- Nilai yang dikirim layar harus persis salah satu dari daftar resmi; salah ketik ditolak
 -- di sini juga, bukan hanya di browser, supaya pemanggil lain tidak bisa melewatinya.
 v_jenis_input:=btrim(coalesce(item->>'jenis_cashback',''));
 if v_jenis_input<>'' then
  if v_jenis_input not in('Transfer','CN','Rebate','RA07','RA7','Rebate Manual','Voucher') then
   raise exception 'Dokumen %: Jenis CB "%" tidak dikenali. Tulis persis Transfer, CN, Rebate atau Rebate Manual',
     c.no_doc,v_jenis_input;
  end if;
  jenis:=rc_private.jenis_efektif(v_jenis_input);
 else
  jenis:=rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override,''),camp.cashback_type));
 end if;

 -- Rebate hanya boleh lewat Bulk Process; jalur bertahap tidak berlaku untuknya, dan
 -- sebaliknya Bulk Process tidak boleh menyentuh campaign non-Rebate.
 if p_action in('release','claim','clearing','reject_release','reject_claim','reject_clearing')
    and jenis='rebate' then
  raise exception 'Dokumen % berjenis Rebate dan hanya dapat diproses lewat Bulk Process',c.no_doc;
 end if;

 target:=null;
 -- Pengajuan tidak mengubah status. RA07/RA7 selesai setelah disetujui.
 if p_action='submit' and c.status='not_yet' and c.pending_approval is null then target:='submitted';
 elsif p_action='approve' and c.status='submitted' and c.pending_approval->>'kind'='submit' then
  target:=coalesce(c.pending_approval->>'target_status','approved');
 elsif p_action='reject_approval' and c.status='submitted' and c.pending_approval->>'kind'='submit' then target:='not_yet';
 elsif p_action='release' and c.status='approved' then target:='released';
 elsif p_action='claim' and c.status='released' then target:='claimed';
 elsif p_action='clearing' and c.status='claimed' then target:='done';
 elsif p_action='reject_release' and c.status in('submitted','approved') then target:='not_yet';
 elsif p_action='reject_claim' and c.status='released' then target:='approved';
 elsif p_action='reject_clearing' and c.status='claimed' then target:='released';
 elsif p_action='hold' and c.status in('not_yet','submitted','approved','released','claimed') then target:=c.status;
 elsif p_action='unhold' and c.status='on_hold' and c.previous_status in('not_yet','submitted','approved','released','claimed') then target:=c.previous_status;
 elsif p_action='expire' and c.status in('not_yet','approved','released','claimed','on_hold') then target:=c.status;
 elsif p_action='expire_claim_process' and c.status in('released','claimed') then target:='expired';
 elsif p_action='approve_hold' and c.pending_approval->>'kind' in('hold','expire') then target:=c.pending_approval->>'target_status';
 elsif p_action='reject_hold' and c.pending_approval->>'kind' in('hold','expire') then target:=c.status;
 elsif p_action='bulk_rebate' and c.status in('approved','released','claimed') then
  if jenis<>'rebate' then raise exception 'Dokumen % bukan campaign Rebate',c.no_doc; end if;
  target:='done';
 end if;
 if target is null then raise exception 'Invalid status transition for %',c.no_doc; end if;
 if p_action='approve_hold' then
  if target='expired' then
   if expire_batch is null then expire_batch:=rc_private.next_batch('04'); end if;
   batch:=expire_batch;
  else batch:=null; end if;
 end if;
 if stage is not null and batch is null then batch:=rc_private.next_batch(stage); end if;
 -- Approval bekerja ATAS batch unggahan dan tidak menerbitkan nomor sendiri: nomor yang
 -- dicatat riwayat adalah nomor yang benar-benar dilihat penyetujunya di layar.
 if p_action in('approve','reject_approval') then batch:=c.batch_upload; end if;

 if p_action='submit' then
  select * into cust from public.customers where id=c.customer_id for update;
  master_changed:=false;

  v_ktp   :=coalesce(nullif(btrim(coalesce(cust.ktp,'')),''),nullif(btrim(coalesce(item->>'ktp','')),''));
  v_npwp  :=coalesce(nullif(btrim(coalesce(cust.npwp,'')),''),nullif(btrim(coalesce(item->>'npwp','')),''));

  -- Rekening: master dipakai bila ada. Bila pengguna mengisi nilai yang BERBEDA, isian itu
  -- menjadi sumber kebenaran baru dan master diperbarui. Ini pengecualian yang diminta
  -- pemilik terhadap aturan umum "master menang".
  v_norek  :=nullif(btrim(coalesce(item->>'account_number','')),'');
  v_namarek:=nullif(btrim(coalesce(item->>'account_name','')),'');
  v_bank   :=nullif(btrim(coalesce(item->>'bank','')),'');
  if v_norek is null then v_norek:=nullif(btrim(coalesce(cust.account_number,'')),'');
  elsif v_norek is distinct from nullif(btrim(coalesce(cust.account_number,'')),'') then master_changed:=true; end if;
  if v_namarek is null then v_namarek:=nullif(btrim(coalesce(cust.account_name,'')),'');
  elsif v_namarek is distinct from nullif(btrim(coalesce(cust.account_name,'')),'') then master_changed:=true; end if;
  if v_bank is null then v_bank:=nullif(btrim(coalesce(cust.bank,'')),'');
  elsif v_bank is distinct from nullif(btrim(coalesce(cust.bank,'')),'') then master_changed:=true; end if;

  -- TOP diambil dari master bila tidak diisi. Bila diisi melebihi TOP master, approval wajib.
  v_top:=coalesce(nullif(btrim(coalesce(item->>'top','')),''),nullif(btrim(coalesce(cust.top_text,'')),''));
  master_top:=case when btrim(coalesce(cust.top_text,'')) ~ '^[0-9]+([.][0-9]+)?$'
                   then btrim(cust.top_text)::numeric else null end;
  input_top :=case when btrim(coalesce(v_top,'')) ~ '^[0-9]+([.][0-9]+)?$'
                   then btrim(v_top)::numeric else null end;
  -- Penjaga "TOP melebihi Customer Master maka Approval wajib" dicabut atas instruksi
  -- pemilik: seluruh dokumen boleh diunggah, dan layak-tidaknya TOP ditentukan di modul
  -- Management of Approval - bukan oleh orang yang mengetik unggahannya. TOP-nya tetap
  -- disimpan di bawah, karena justru nilai itulah yang dipakai modul tersebut.

  subject:=case when v_npwp is not null then 'Badan'
                when v_ktp is not null then 'Perorangan'
                else nullif(btrim(coalesce(item->>'tax_subject',c.tax_subject,'')),'') end;
  if subject is null then
   raise exception 'Dokumen %: KTP atau NPWP pelanggan % belum terisi di Customer Master',c.no_doc,cust.customer_code;
  end if;
  if v_ktp is not null and v_npwp is not null then
   raise exception 'Dokumen %: pelanggan % punya KTP dan NPWP sekaligus; perbaiki di Customer Master',c.no_doc,cust.customer_code;
  end if;

  if jenis='' then
   raise exception 'Dokumen %: Jenis CB campaign % belum ditetapkan di Campaign Master',c.no_doc,camp.campaign_code;
  end if;
  if jenis='transfer' and (v_norek is null or v_namarek is null or v_bank is null) then
   raise exception 'Dokumen %: Jenis CB Transfer memerlukan Nomor Rekening, Nama Rekening dan Bank. Lengkapi di Customer Master atau isi pada baris ini',c.no_doc;
  end if;

  -- Total tagihan dan bulan potong tetap opsional; tidak ada pemeriksaan wajib di sini.

  -- TOP TIDAK lagi ikut diperbarui dari unggahan: ia kesepakatan, bukan data mutakhir,
  -- dan dokumen yang menulis ulang acuannya sendiri membuat persetujuan kehilangan arti.
  if master_changed then
   update public.customers set account_number=v_norek,account_name=v_namarek,bank=v_bank,
     updated_at=now(),updated_by=actor
   where id=cust.id;
   insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
   values(actor,c.depot_id,'customer_master_updated_from_upload',c.id,
     jsonb_build_object('custCode',cust.customer_code,'noDoc',c.no_doc));
  end if;

  v_gross:=rc_private.gross_claimed(c.cb_net,subject,camp.tax_status);
  update public.claims set tax_subject=subject,gross_up=v_gross,
    cashback_type_override=case when v_jenis_input<>'' then rc_private.cb_label(v_jenis_input) else cashback_type_override end,
    cashback_type_changed=cashback_type_changed or (v_jenis_input<>'' and rc_private.jenis_efektif(v_jenis_input)<>rc_private.jenis_efektif(camp.cashback_type)),
    total_billing=case when item ? 'total_billing' then (item->>'total_billing')::numeric else total_billing end,
    period_start=coalesce(nullif(item->>'period_start','')::date,period_start,camp.period_start),
    period_end=coalesce(nullif(item->>'period_end','')::date,period_end,camp.period_end),paid_on=coalesce(nullif(item->>'paid_on','')::date,paid_on),
    approval=coalesce(item->>'approval',approval),billing_months=coalesce(item->'billing_months',billing_months)
   where id=c.id;
  insert into rc_private.claim_sensitive(claim_id) values(c.id) on conflict do nothing;
  update rc_private.claim_sensitive set ktp=v_ktp,npwp=v_npwp,bank=v_bank,
    account_number=v_norek,account_name=v_namarek,top_text=v_top where claim_id=c.id;
 end if;

 update public.claims set status=target,
 bulk_processed_at=case when p_action='bulk_rebate' then stamp else bulk_processed_at end,
 bulk_processed_by=case when p_action='bulk_rebate' then actor else bulk_processed_by end,
 pending_approval=case
   when p_action in('submit','hold','expire') then jsonb_build_object(
     'kind',p_action,'requested_by',actor,'requested_at',stamp,'reason',p_reason,
     'target_status',case when p_action='hold' then 'on_hold' when p_action='expire' then 'expired'
       when jenis='rebate manual' then 'done' else 'approved' end)
   when p_action in('approve','reject_approval','approve_hold','reject_hold') then null else pending_approval end,
 previous_status=case when p_action='approve_hold' and target='on_hold' then c.status
   when p_action='unhold' then null else previous_status end,
 extend_so_start=case when p_action='approve_hold' and target='on_hold' then coalesce((c.pending_approval->>'so_start')::date,extend_so_start) else extend_so_start end,
 extend_so_end=case when p_action='approve_hold' and target='on_hold' then coalesce((c.pending_approval->>'so_end')::date,extend_so_end) else extend_so_end end,
 extend_billing_start=case when p_action='approve_hold' and target='on_hold' then coalesce((c.pending_approval->>'billing_start')::date,extend_billing_start) else extend_billing_start end,
 extend_billing_end=case when p_action='approve_hold' and target='on_hold' then coalesce((c.pending_approval->>'billing_end')::date,extend_billing_end) else extend_billing_end end,
 uploaded_at=case when p_action='submit' then stamp when p_action in('reject_release','reject_approval') then null else uploaded_at end,
 hold_approved_at=case when p_action='approve_hold' then stamp else hold_approved_at end,
 hold_approved_by=case when p_action='approve_hold' then actor else hold_approved_by end,
 submitted_by=case when p_action='submit' then actor when p_action in('reject_release','reject_approval') then null else submitted_by end,
 approved_at=case when p_action='approve' then stamp when p_action in('reject_approval','reject_release') then null else approved_at end,
 approved_by=case when p_action='approve' then actor when p_action in('reject_approval','reject_release') then null else approved_by end,
 released_at=case when p_action='release' then stamp when p_action='reject_claim' then null else released_at end,
 released_by=case when p_action='release' then actor when p_action='reject_claim' then null else released_by end,
 claimed_at=case when p_action='claim' then stamp when p_action='reject_clearing' then null else claimed_at end,
 claimed_by=case when p_action='claim' then actor when p_action='reject_clearing' then null else claimed_by end,
 cleared_at=case when p_action in('clearing','bulk_rebate') or (p_action='approve' and target='done') then stamp else cleared_at end,
 cleared_by=case when p_action in('clearing','bulk_rebate') or (p_action='approve' and target='done') then actor else cleared_by end,
 batch_upload=case when p_action='submit' then batch when p_action='reject_release' then null else batch_upload end,
 batch_release=case when p_action in('release','bulk_rebate') then batch when p_action='reject_claim' then null else batch_release end,
 batch_claim=case when p_action in('claim','bulk_rebate') then batch when p_action='reject_clearing' then null else batch_claim end,
 batch_clearing=case when p_action in('clearing','bulk_rebate','expire_claim_process') or (p_action='approve_hold' and target='expired') then batch
   when p_action='approve' and target='done' then c.batch_upload else batch_clearing end,
 version_no=version_no+1,updated_at=stamp where id=c.id;
 if p_action='approve' and target='done' then
  insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
   values(c.id,actor,c.status,'approved','approve',batch,p_reason),(c.id,actor,'approved','done','manual_complete',batch,'Rebate Manual');
 elsif p_action='bulk_rebate' then
  insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
   values(c.id,actor,c.status,'bulk_processed','bulk_process',batch,p_reason),(c.id,actor,'bulk_processed','done','bulk_rebate',batch,p_reason);
 else
  insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
   values(c.id,actor,c.status,target,p_action,batch,p_reason);
 end if;
 insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
 values(actor,c.depot_id,p_action,c.id,jsonb_build_object('from',c.status,'to',target,'batch',batch));
 processed:=processed||jsonb_build_array(jsonb_build_object('no_doc',c.no_doc,'status',target,
   'version_no',c.version_no+1,'pending_approval',p_action in('submit','hold','expire'),'gross_up',coalesce(v_gross,c.gross_up)));
 end loop;
 v_payload:=jsonb_build_object('processed',processed,'batch',batch,'count',jsonb_array_length(processed));
 update rc_private.requests set result=v_payload where actor_id=actor and request_id=p_request_id;
 return v_payload;
end $function$;
CREATE OR REPLACE FUNCTION rc_private.registration_plan(p_payload jsonb, p_existing uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p jsonb; code text; peran text; home uuid; item text; target uuid; r record; rid uuid;
begin
 perform rc_private.require_tab('access.add');
 if not rc_private.is_manager() then raise exception 'Supervisor atau System Manager diperlukan' using errcode='42501'; end if;
 if p_payload is null or jsonb_typeof(p_payload)<>'object' or octet_length(p_payload::text)>8000 then raise exception 'Payload registrasi tidak sah'; end if;
 rid:=(p_payload->>'request_id')::uuid;
 if rid is null then raise exception 'Request ID wajib diisi'; end if;
 -- Serialize ledger/profile observations with provisioning for this request.
 perform pg_advisory_xact_lock(hashtextextended('rc-registration:'||rid::text,0));
 code:=upper(btrim(coalesce(p_payload->>'user_code','')));
 peran:=lower(btrim(coalesce(p_payload->>'role','')));
 if peran='non-osc' then peran:='others'; end if;
 if code !~ '^[A-Z0-9._-]{1,100}$' then raise exception 'User ID tidak sah'; end if;
 if length(btrim(coalesce(p_payload->>'full_name',''))) not between 1 and 200 then raise exception 'Nama lengkap wajib diisi (maksimal 200 karakter)'; end if;
 if length(coalesce(p_payload->>'business_email',''))>320 or btrim(coalesce(p_payload->>'business_email','')) !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'Email kantor tidak sah'; end if;
 if not exists(select 1 from jsonb_array_elements(rc_private.registration_roles()) x where x->>'code'=peran) then raise exception 'Role tidak dikenali'; end if;
 if peran='system manager' and not rc_private.is_system_manager() then raise exception 'Hanya System Manager dapat membuat System Manager' using errcode='42501'; end if;
 if length(coalesce(p_payload->>'department',''))>200 then raise exception 'Departemen terlalu panjang'; end if;
 foreach item in array array['depot_codes','osc_codes','regions'] loop
  if p_payload ? item and jsonb_typeof(p_payload->item)<>'array' then raise exception 'Mapping % harus berupa array',item; end if;
  if exists(select 1 from jsonb_array_elements(coalesce(p_payload->item,'[]')) x where jsonb_typeof(x)<>'string') then raise exception 'Mapping % harus berupa teks',item; end if;
 end loop;
 p:=jsonb_build_object('request_id',rid,'user_code',code,'role',peran,
  'full_name',btrim(p_payload->>'full_name'),'business_email',lower(btrim(p_payload->>'business_email')),
  'department',btrim(coalesce(p_payload->>'department','')),'home_depot',upper(btrim(coalesce(p_payload->>'home_depot',''))),
  'depot_codes',coalesce((select jsonb_agg(v order by v) from (select distinct upper(btrim(value)) v from jsonb_array_elements_text(coalesce(p_payload->'depot_codes','[]'))) t where v<>''),'[]'),
  'osc_codes',coalesce((select jsonb_agg(v order by v) from (select distinct upper(btrim(value)) v from jsonb_array_elements_text(coalesce(p_payload->'osc_codes','[]'))) t where v<>''),'[]'),
  'regions',coalesce((select jsonb_agg(v order by v) from (select distinct upper(btrim(value)) v from jsonb_array_elements_text(coalesce(p_payload->'regions','[]'))) t where v<>''),'[]'));
 select * into r from rc_private.managed_registrations where request_id=rid;
 if found then
  if r.actor_id<>(select auth.uid()) or r.payload<>p then raise exception 'Request ID sudah digunakan untuk data lain'; end if;
  return p||jsonb_build_object('completed_id',r.profile_id);
 end if;
 if exists(select 1 from public.profiles where upper(user_code)=code and id is distinct from p_existing) then raise exception 'User ID sudah terdaftar'; end if;
 select id into home from public.depots where depot_code=p->>'home_depot' and archived_at is null;
 if home is null then raise exception 'Pilih depot asal yang valid'; end if;
 if not rc_private.can_access(home) then raise exception 'Depot asal di luar yurisdiksi Anda' using errcode='42501'; end if;
 if peran in('admin','osc','others','finance','depot head') then
  if jsonb_array_length(p->'depot_codes')=0 then raise exception 'Pilih minimal satu depot yurisdiksi'; end if;
  if jsonb_array_length(p->'osc_codes')+jsonb_array_length(p->'regions')>0 then raise exception 'Mapping tidak sesuai role'; end if;
 elsif peran='supervisor' then
  if jsonb_array_length(p->'osc_codes')=0 then raise exception 'Pilih minimal satu OSC binaan'; end if;
  if jsonb_array_length(p->'depot_codes')+jsonb_array_length(p->'regions')>0 then raise exception 'Supervisor memperoleh depot melalui OSC'; end if;
 elsif peran='management' then
  if jsonb_array_length(p->'regions')=0 then raise exception 'Pilih minimal satu region'; end if;
  if jsonb_array_length(p->'depot_codes')+jsonb_array_length(p->'osc_codes')>0 then raise exception 'Management memperoleh depot melalui region'; end if;
 elsif jsonb_array_length(p->'depot_codes')+jsonb_array_length(p->'osc_codes')+jsonb_array_length(p->'regions')>0 then raise exception 'System Manager tidak memerlukan mapping';
 end if;
 for item in select jsonb_array_elements_text(p->'depot_codes') loop
  select id into target from public.depots where depot_code=item and archived_at is null;
  if target is null or not rc_private.can_access(target) then raise exception 'Depot % tidak valid atau di luar yurisdiksi',item using errcode='42501'; end if;
 end loop;
 for item in select jsonb_array_elements_text(p->'osc_codes') loop
  select id into target from public.profiles where user_code=item and role='osc' and status='active';
  if target is null or not rc_private.can_manage_user(target) then raise exception 'OSC % tidak valid atau di luar yurisdiksi',item using errcode='42501'; end if;
 end loop;
 for item in select jsonb_array_elements_text(p->'regions') loop
  if not exists(select 1 from public.depots where upper(btrim(region))=item and archived_at is null)
   or exists(select 1 from public.depots where upper(btrim(region))=item and archived_at is null and not rc_private.can_access(id)) then
   raise exception 'Region % tidak valid atau di luar yurisdiksi',item using errcode='42501'; end if;
 end loop;
 return p;
end $function$
;
notify pgrst,'reload schema';
