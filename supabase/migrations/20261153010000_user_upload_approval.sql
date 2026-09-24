-- Spreadsheet registrations have a pending profile and no effective grants until reviewed.
-- PINs are handled only by Supabase Auth; the ledger contains the normalized proposal.
create or replace function rc_private.upload_registration_scope(p jsonb, p_active boolean default true)
returns boolean language sql stable security definer set search_path='' as $$
 select rc_private.is_manager()
  and (p->>'role'<>'system manager' or rc_private.is_system_manager())
  and exists(select 1 from public.depots d where d.depot_code=p->>'home_depot'
    and (not p_active or d.archived_at is null) and rc_private.can_access(d.id))
  and not exists(select 1 from jsonb_array_elements_text(p->'depot_codes') c
    where not exists(select 1 from public.depots d where d.depot_code=c
      and (not p_active or d.archived_at is null) and rc_private.can_access(d.id)));
$$;

create or replace function rc_private.upload_registration_plan(p_payload jsonb,p_existing uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p jsonb; code text; peran text; rid uuid; r record;
begin
 perform rc_private.require_tab('access.add');
 if not rc_private.is_manager() then raise exception 'Supervisor atau System Manager diperlukan' using errcode='42501';end if;
 if p_payload is null or jsonb_typeof(p_payload)<>'object' or octet_length(p_payload::text)>8000 then raise exception 'Payload registrasi tidak sah';end if;
 rid:=(p_payload->>'request_id')::uuid;
 if rid is null then raise exception 'Request ID wajib diisi';end if;
 perform pg_advisory_xact_lock(hashtextextended('rc-registration:'||rid::text,0));
 code:=upper(btrim(coalesce(p_payload->>'user_code','')));
 peran:=lower(btrim(coalesce(p_payload->>'role','')));
 if peran='non-osc' then peran:='others';end if;
 if code !~ '^[A-Z0-9._-]{1,100}$' then raise exception 'User ID tidak sah';end if;
 if length(btrim(coalesce(p_payload->>'full_name',''))) not between 1 and 200 then raise exception 'Nama lengkap wajib diisi (maksimal 200 karakter)';end if;
 if length(coalesce(p_payload->>'business_email',''))>320 or btrim(coalesce(p_payload->>'business_email','')) !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'Email kantor tidak sah';end if;
 if not exists(select 1 from jsonb_array_elements(rc_private.registration_roles()) x where x->>'code'=peran) then raise exception 'Role tidak dikenali';end if;
 if jsonb_typeof(p_payload->'depot_codes') is distinct from 'array' then raise exception 'Resource Partner / Area harus berupa daftar kode depot';end if;
 if exists(select 1 from jsonb_array_elements(p_payload->'depot_codes') x where jsonb_typeof(x)<>'string') then raise exception 'Kode depot harus berupa teks';end if;
 p:=jsonb_build_object('source','upload','request_id',rid,'user_code',code,'role',peran,
  'full_name',btrim(p_payload->>'full_name'),'business_email',lower(btrim(p_payload->>'business_email')),
  'home_depot',upper(btrim(coalesce(p_payload->>'home_depot',''))),
  'depot_codes',coalesce((select jsonb_agg(v order by v) from
   (select distinct upper(btrim(value)) v from jsonb_array_elements_text(p_payload->'depot_codes')) t where v<>''),'[]'));
 if peran<>'system manager' and jsonb_array_length(p->'depot_codes')=0 then raise exception 'Isi minimal satu kode depot Resource Partner / Area';end if;
 if not rc_private.upload_registration_scope(p) then raise exception 'Role atau depot di luar yurisdiksi, tidak valid, atau sudah diarsipkan' using errcode='42501';end if;
 select * into r from rc_private.managed_registrations where request_id=rid;
 if found then
  if r.actor_id<>(select auth.uid()) or r.payload<>p then raise exception 'Request ID sudah digunakan untuk data lain';end if;
  return p||jsonb_build_object('completed_id',r.profile_id,'activation',(select status from public.profiles where id=r.profile_id));
 end if;
 if exists(select 1 from public.profiles where upper(user_code)=code and id is distinct from p_existing) then raise exception 'User ID sudah terdaftar';end if;
 return p||jsonb_build_object('activation','pending');
end $$;

create or replace function rc_private.provision_uploaded_registration(p_id uuid,p_envelope jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare actor uuid; p jsonb; home uuid; old_claims text; old_sub text;
begin
 old_claims:=current_setting('request.jwt.claims',true);old_sub:=current_setting('request.jwt.claim.sub',true);
 actor:=(p_envelope->>'actor_id')::uuid;
 if actor is null then raise exception 'Creator identity missing';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',actor::text,true);
 p:=rc_private.upload_registration_plan(p_envelope->'payload',p_id);
 if p ? 'completed_id' then raise exception 'Registration already completed';end if;
 p:=p-'activation';
 select id into home from public.depots where depot_code=p->>'home_depot';
 if exists(select 1 from public.profiles where id=p_id) then
  if not exists(select 1 from public.profiles where id=p_id and status='pending' and user_code=p->>'user_code') then raise exception 'Upload requires a new pending profile';end if;
  update public.profiles set full_name=p->>'full_name',business_email=p->>'business_email',role='others',status='pending',
   suffix_num='000',must_change_password=true,requested_role=p->>'role',requested_depot=p->>'home_depot',
   home_depot_id=home,department='',reviewed_by=null,reviewed_at=null,review_note=null where id=p_id;
  delete from public.activity_logs where actor_id=p_id and entity_id=p_id and event_type='registration_submitted';
 else
  insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,must_change_password,
   requested_role,requested_depot,home_depot_id,department)
  values(p_id,p->>'user_code',p->>'full_name',p->>'business_email','others','pending','000',true,p->>'role',p->>'home_depot',home,'');
 end if;
 -- No module, depot, region, or supervision grants are issued by upload.
 insert into rc_private.managed_registrations(request_id,actor_id,profile_id,payload)
 values((p->>'request_id')::uuid,actor,p_id,p);
 insert into public.activity_logs(actor_id,event_type,entity_id,details,module,tab,process_stage)
 values(actor,'registration_uploaded',p_id,jsonb_build_object('user_code',p->>'user_code','role',p->>'role',
  'depot_codes',p->'depot_codes','request_id',p->>'request_id'),'Access Management','Registrasi / Upload User','Pending');
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);
exception when others then
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);raise;
end $$;

create or replace function rc_private.review_uploaded_registration(p_profile uuid,p_approve boolean,p_note text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.profiles%rowtype;p jsonb;assigned text;home uuid;
begin
 perform rc_private.require_tab('access.req');
 if not rc_private.is_manager() or not rc_private.can_manage_user(p_profile) then raise exception 'Pendaftaran di luar kewenangan Anda' using errcode='42501';end if;
 if p_profile=(select auth.uid()) then raise exception 'Tidak dapat menyetujui akun sendiri';end if;
 if p_approve is null then raise exception 'Keputusan wajib diisi';end if;
 if length(coalesce(p_note,''))>1000 then raise exception 'Catatan terlalu panjang';end if;
 select * into target from public.profiles where id=p_profile for update;
 if not found or target.status<>'pending' then raise exception 'Pendaftaran tidak ditemukan atau sudah diproses';end if;
 select payload into p from rc_private.managed_registrations where profile_id=p_profile and payload->>'source'='upload';
 if p is null or not rc_private.upload_registration_scope(p,p_approve) then raise exception 'Role atau depot pendaftaran di luar kewenangan atau tidak valid' using errcode='42501';end if;
 if p_approve then
  select id into home from public.depots where depot_code=p->>'home_depot';
  assigned:=rc_private.next_suffix();
  update public.profiles set status='active',role=p->>'role',suffix_num=assigned,home_depot_id=home,
   reviewed_by=(select auth.uid()),reviewed_at=now(),review_note=p_note where id=p_profile;
  if p->>'role'='system manager' then
   insert into public.user_permissions select p_profile,code from public.permissions on conflict do nothing;
  else
   insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
   select p_profile,d.id,case when p->>'role'='admin' then 'rp' else 'assigned' end,(select auth.uid())
   from public.depots d where d.depot_code in(select jsonb_array_elements_text(p->'depot_codes'));
  end if;
  perform rc_private.rebuild_with_supervisors(p_profile);
 else
  update public.profiles set status='rejected',reviewed_by=(select auth.uid()),reviewed_at=now(),review_note=p_note where id=p_profile;
 end if;
 insert into public.activity_logs(actor_id,event_type,entity_id,details,module,tab,process_stage)
 values((select auth.uid()),case when p_approve then 'registration_approved' else 'registration_rejected' end,p_profile,
  jsonb_build_object('source','upload','role',p->>'role','suffix_num',assigned,'depot_codes',p->'depot_codes'),
  'Access Management','Approval Request',case when p_approve then 'Active' else 'Rejected' end);
 return jsonb_build_object('status','success','role',p->>'role','suffix_num',assigned,
  'message',case when p_approve then 'User upload disetujui. Area depot telah disinkronkan; lengkapi izin modul melalui Edit Akses.' else 'User upload ditolak; akses tetap tidak aktif.' end);
end $$;

revoke all on function rc_private.upload_registration_scope(jsonb,boolean),
 rc_private.upload_registration_plan(jsonb,uuid),rc_private.provision_uploaded_registration(uuid,jsonb),
 rc_private.review_uploaded_registration(uuid,boolean,text) from public,anon,authenticated;

-- Integration with existing registration and Access Management.
CREATE OR REPLACE FUNCTION rc_private.registration_plan(p_payload jsonb, p_existing uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p jsonb; code text; peran text; home uuid; item text; target uuid; r record; rid uuid;
begin
 if p_payload->>'source'='upload' then return rc_private.upload_registration_plan(p_payload,p_existing);end if;
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
CREATE OR REPLACE FUNCTION rc_private.provision_managed_registration(p_id uuid, p_envelope jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid; p jsonb; item text; old_claims text; old_sub text; home uuid;
begin
 if p_envelope#>>'{payload,source}'='upload' then perform rc_private.provision_uploaded_registration(p_id,p_envelope);return;end if;
 actor:=(p_envelope->>'actor_id')::uuid;
 if actor is null then raise exception 'Creator identity missing'; end if;
 old_claims:=current_setting('request.jwt.claims',true); old_sub:=current_setting('request.jwt.claim.sub',true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',actor::text,true);
 p:=rc_private.registration_plan(p_envelope->'payload',p_id);
 if p ? 'completed_id' then raise exception 'Registration already completed'; end if;
 select id into home from public.depots where depot_code=p->>'home_depot';
 if exists(select 1 from public.profiles where id=p_id) then
  if not exists(select 1 from public.profiles where id=p_id and status='pending' and user_code=p->>'user_code') then
   raise exception 'Managed registration requires a new pending profile'; end if;
  update public.profiles set full_name=p->>'full_name',business_email=p->>'business_email',role=p->>'role',status='active',
   suffix_num=rc_private.next_suffix(),must_change_password=true,requested_role=p->>'role',requested_depot=p->>'home_depot',
   home_depot_id=home,department=p->>'department',reviewed_by=actor,reviewed_at=now() where id=p_id;
  -- This event was produced by the insert trigger earlier in the same Auth Admin transaction.
  delete from public.activity_logs where actor_id=p_id and entity_id=p_id and event_type='registration_submitted';
 else
 insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,must_change_password,
   requested_role,requested_depot,home_depot_id,department,reviewed_by,reviewed_at)
 values(p_id,p->>'user_code',p->>'full_name',p->>'business_email',p->>'role','active',rc_private.next_suffix(),true,
   p->>'role',p->>'home_depot',home,p->>'department',actor,now());
 end if;
 for item in select jsonb_array_elements_text(p->'depot_codes') loop
  insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
   select p_id,id,case when p->>'role'='admin' then 'rp' else 'assigned' end,actor from public.depots where depot_code=item;
 end loop;
 for item in select jsonb_array_elements_text(p->'osc_codes') loop
  insert into public.user_supervision(supervisor_id,osc_id) select p_id,id from public.profiles where user_code=item;
 end loop;
 for item in select jsonb_array_elements_text(p->'regions') loop
  insert into public.user_region_access(user_id,region,granted_by) values(p_id,item,actor);
 end loop;
 if p->>'role'='system manager' then insert into public.user_permissions select p_id,code from public.permissions; end if;
 perform rc_private.rebuild_with_supervisors(p_id);
 insert into rc_private.managed_registrations(request_id,actor_id,profile_id,payload) values((p->>'request_id')::uuid,actor,p_id,p);
 insert into public.activity_logs(actor_id,event_type,entity_id,details) values(actor,'account_created',p_id,
   jsonb_build_object('user_code',p->>'user_code','role',p->>'role','request_id',p->>'request_id'));
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);
exception when others then
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true); raise;
end $function$
;
CREATE OR REPLACE FUNCTION rc_private.review_registration(p_profile uuid, p_approve boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare target public.profiles%rowtype; assigned text; peran text; depot uuid;
begin
 if exists(select 1 from rc_private.managed_registrations where profile_id=p_profile and payload->>'source'='upload') then return rc_private.review_uploaded_registration(p_profile,p_approve,p_note);end if;
 if not rc_private.is_manager() or not rc_private.can_manage_user(p_profile) then raise exception 'Pendaftaran di luar kewenangan Anda' using errcode='42501'; end if;
 if p_profile=(select auth.uid()) then raise exception 'Tidak dapat menyetujui akun sendiri'; end if;
 if p_approve is null then raise exception 'Keputusan wajib diisi'; end if;
 select * into target from public.profiles where id=p_profile for update;
 if not found or target.status<>'pending' then raise exception 'Pendaftaran tidak ditemukan atau sudah diproses'; end if;
 if length(coalesce(p_note,''))>1000 then raise exception 'Catatan terlalu panjang'; end if;
 if p_approve then
  select id into depot from public.depots where depot_code=target.requested_depot and archived_at is null;
  if depot is null or not rc_private.can_access(depot) then raise exception 'Depot pendaftaran tidak valid atau di luar yurisdiksi' using errcode='42501'; end if;
  peran:=case when target.requested_role='non-osc' then 'others' when target.requested_role='system manager' then 'admin' else target.requested_role end;
  if not exists(select 1 from jsonb_array_elements(rc_private.registration_roles()) x where x->>'code'=peran) then raise exception 'Role pendaftaran tidak valid'; end if;
  assigned:=rc_private.next_suffix();
  update public.profiles set status='active',role=peran,suffix_num=assigned,home_depot_id=depot,
    reviewed_by=(select auth.uid()),reviewed_at=now(),review_note=p_note where id=p_profile;
  if peran in('admin','osc','others','finance','depot head') then
   insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)
    values(p_profile,depot,case when peran='admin' then 'rp' else 'assigned' end,(select auth.uid())) on conflict do nothing;
  end if;
  -- Supervisor/Management require explicit OSC/region selection in Edit Access.
  perform rc_private.rebuild_with_supervisors(p_profile);
 else
  update public.profiles set status='rejected',reviewed_by=(select auth.uid()),reviewed_at=now(),review_note=p_note where id=p_profile;
 end if;
 insert into public.activity_logs(actor_id,event_type,entity_id,details) values((select auth.uid()),
  case when p_approve then 'registration_approved' else 'registration_rejected' end,p_profile,jsonb_build_object('role',peran,'suffix_num',assigned));
 return jsonb_build_object('status','success','suffix_num',assigned,'role',peran,
  'message',case when p_approve then 'Pendaftaran disetujui. Lengkapi hak modul dan yurisdiksi melalui Edit Akses.' else 'Pendaftaran ditolak.' end);
end $function$
;
CREATE OR REPLACE FUNCTION rc_private.legacy_profile_requests()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce(jsonb_agg(x order by x->>'tglRequest' desc),'[]'::jsonb) from (
  select jsonb_build_object(
    'id','signup:'||p.id,'namaDepot',coalesce(nullif(p.requested_depot,''),'Depot belum ditentukan'),
    'kodeDepot',p.requested_depot,'kind','registration','uploaded',coalesce(m.payload->>'source'='upload',false),
    'requesterId',coalesce((select u.user_code from public.profiles u where u.id=m.actor_id),p.user_code),
    'changes',jsonb_strip_nulls(jsonb_build_object(
      'Pendaftaran akun baru',p.full_name,'Email kantor',p.business_email,
      'Role diminta',p.requested_role,'Depot diminta',nullif(p.requested_depot,''),'User ID',p.user_code,
      'Resource Partner / Area',case when m.payload->>'source'='upload' then (select string_agg(value,', ' order by value) from jsonb_array_elements_text(m.payload->'depot_codes')) end)),
    'tglRequest',to_char(p.registered_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS')) as x
  from public.profiles p left join rc_private.managed_registrations m on m.profile_id=p.id
  where p.status='pending' and rc_private.can_view_managed_user(p.id)
   and (m.payload->>'source' is distinct from 'upload' or rc_private.upload_registration_scope(m.payload,false))
  union all
  select jsonb_build_object(
    'id','profile:'||r.id,'namaDepot',d.depot_name,'kodeDepot',d.depot_code,
    'requesterId',coalesce(p.user_code,''),'changes',r.changes,
    'tglRequest',to_char(r.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS')) as x
  from public.profile_change_requests r
  join public.depots d on d.id=r.depot_id
  left join public.profiles p on p.id=r.requester_id
  where r.status='pending' and rc_private.can_access(r.depot_id)) t;
$function$
;
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
 perform rc_private.require_tab('access.list');
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
  if (select status from public.profiles where id=v_target)='rejected'
    and exists(select 1 from rc_private.managed_registrations where profile_id=v_target and payload->>'source'='upload') then
    raise exception 'Pengajuan upload telah ditolak; tidak dapat diaktifkan melalui Edit Akses';end if;

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
  if v_role not in('osc','others','finance','depot head','supervisor','management') and jsonb_array_length(coalesce(p_payload->'assignedDepots','[]'))>0 then raise exception 'Mapping depot tidak sesuai role'; end if;
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
  if v_role not in ('osc','others','finance','depot head','supervisor','management') then
    delete from public.user_depot_grants where user_id=v_target and kind='assigned';
  end if;
  -- Only System Manager has intrinsic global scope; depot areas remain explicit for other roles.
  if v_role='system manager' then
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
notify pgrst,'reload schema';
