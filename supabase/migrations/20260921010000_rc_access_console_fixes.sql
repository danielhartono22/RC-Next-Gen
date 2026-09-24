-- PENDING: belum diterapkan.
--
-- Perbaikan konsol Kelola Akses, peran System Manager, dan depot pada pendaftaran.
--
-- Tiga bug nyata pada konsol Otorisasi:
--
--  1. Layar membaca u.auth untuk mengisi seluruh select modul, tetapi rc_private.legacy_users
--     tidak pernah mengirim objek itu. Akibatnya setiap select jatuh ke nilai default yang
--     ditulis di markup, bukan hak akses pengguna yang sebenarnya. Menyimpan lalu menulis
--     nilai default itu, sehingga akses terlihat "tidak berubah" atau berubah keliru.
--  2. Yurisdiksi depot hanya muncul untuk role osc dan non-osc, dan membaca u.assignedDepots
--     yang juga tidak pernah dikirim. Jadi pemetaan teritori tidak pernah terisi.
--  3. Peran tidak dapat diubah menjadi System Manager sama sekali.

------------------------------------------------------------------------------------------
-- 1. Konsol menerima keadaan yang sebenarnya
------------------------------------------------------------------------------------------
create or replace function rc_private.legacy_users() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',p.id,'userId',p.user_code,'nama',p.full_name,'email',p.business_email,
   'role',p.role,'sysRole',p.role,'suffix',p.suffix_num,
   'activation',case p.status when 'active' then 'Active' when 'pending' then 'Pending'
     when 'rejected' then 'Rejected' else 'Nonactive' end,
   'mustChangePin',p.must_change_password,
   'requestedRole',coalesce(p.requested_role,''),'requestedDepot',coalesce(p.requested_depot,''),
   'permissions',array(select permission_code from public.user_permissions where user_id=p.id),
   -- Konsol membaca huruf-huruf ini untuk mengisi select modul. Tanpa objek auth, layar
   -- menampilkan default markup dan menyimpannya kembali sebagai hak akses.
   'auth',jsonb_build_object(
     'i',case p.status when 'active' then 'Active' else 'Inactive' end,
     'j',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='upload_claim') then 'Yes' else 'No' end,
     'k',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='release_claim') then 'Yes' else 'No' end,
     'l',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='process_claim') then 'Yes' else 'No' end,
     'm',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='view_analytics') then 'Yes' else 'No' end,
     'n',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='manage_access') then 'Yes' else 'No' end,
     'p',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='view_master_depot') then 'Yes' else 'No' end,
     's',case when exists(select 1 from public.user_permissions up where up.user_id=p.id and up.permission_code='bulk_process') then 'Yes' else 'No' end,
     'q','No'),
   -- Yurisdiksi depot yang sedang berlaku, memakai nama field yang dibaca layar.
   'assignedDepots',array(select d.depot_code from public.user_depot_access a
     join public.depots d on d.id=a.depot_id where a.user_id=p.id order by d.depot_code),
   'depotCodes',array(select d.depot_code from public.user_depot_access a
     join public.depots d on d.id=a.depot_id where a.user_id=p.id),
   'depotIds',array(select depot_id from public.user_depot_access where user_id=p.id),
   'depotName',coalesce((select d.depot_name from public.user_depot_access a
     join public.depots d on d.id=a.depot_id where a.user_id=p.id order by d.depot_code limit 1),''))
   order by p.status,p.user_code),'[]'::jsonb)
 from public.profiles p;
$$;

-- Seluruh depot dikirim ke konsol supaya daftar yurisdiksi lengkap, bukan hanya depot yang
-- kebetulan sudah dimiliki orang yang sedang membuka layar.
create or replace function public.rc_legacy_manageable() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 return jsonb_build_object('status','success',
  'users',rc_private.legacy_users(),
  'allDepots',rc_private.legacy_all_depots(),
  'managedDepots',rc_private.legacy_all_depots(),
  'isSystemManager',true,
  'profileRequests',rc_private.legacy_profile_requests());
end $$;

------------------------------------------------------------------------------------------
-- 2. Peran, termasuk System Manager
------------------------------------------------------------------------------------------
-- Menjadikan seseorang System Manager adalah pemberian kekuasaan penuh, jadi hanya System
-- Manager yang boleh melakukannya, dan tidak boleh lewat jalur lain seperti persetujuan
-- pendaftaran yang menyalin permintaan mentah.
create or replace function rc_private.set_role(p_user uuid,p_role text) returns void
language plpgsql security definer set search_path='' as $$
declare v_role text; v_lama text;
begin
 if not rc_private.is_manager() then raise exception 'Hanya System Manager' using errcode='42501'; end if;
 v_role:=lower(btrim(coalesce(p_role,'')));
 if v_role not in('admin','osc','non-osc','finance','supervisor','system manager') then
  raise exception 'Role "%" tidak dikenali',p_role; end if;
 select role into v_lama from public.profiles where id=p_user for update;
 if not found then raise exception 'User tidak ditemukan'; end if;
 if v_lama=v_role then return; end if;
 if p_user=(select auth.uid()) then raise exception 'Tidak dapat mengubah peran sendiri'; end if;

 update public.profiles set role=v_role where id=p_user;
 insert into public.activity_logs(actor_id,event_type,entity_id,details)
 values((select auth.uid()),'role_changed',p_user,
   jsonb_build_object('dari',v_lama,'menjadi',v_role));
end $$;
revoke all on function rc_private.set_role(uuid,text) from public,anon;
grant execute on function rc_private.set_role(uuid,text) to authenticated;

-- Konsol kini mengirim peran juga. System Manager selalu memperoleh seluruh modul dan
-- seluruh depot, karena peran itu memang tidak mengenal pembatasan.
drop function if exists public.rc_legacy_update_access(text,jsonb,text,text);
create or replace function public.rc_legacy_update_access(p_user_code text,p_auth jsonb,
 p_depot_codes text default null,p_suffix text default null,p_role text default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare target uuid; target_status text; perms text[]; depot_ids uuid[]; new_status text;
 code text; final_role text;
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 if p_auth is null or jsonb_typeof(p_auth)<>'object' then raise exception 'Invalid authorization payload'; end if;
 select id,status,role into target,target_status,final_role from public.profiles
  where user_code=btrim(coalesce(p_user_code,''));
 if target is null then raise exception 'User not found'; end if;
 if target_status='pending' then raise exception 'Setujui pendaftaran ini lebih dahulu di kotak masuk approval'; end if;

 if p_role is not null and btrim(p_role)<>'' then
  perform rc_private.set_role(target,btrim(p_role));
  final_role:=lower(btrim(p_role));
 end if;

 if p_suffix is not null and btrim(p_suffix)<>'' then
  perform rc_private.set_suffix(p_user_code,btrim(p_suffix));
 end if;

 new_status:=case when lower(coalesce(p_auth->>'i','')) in('active','approved','ok') then 'active' else 'inactive' end;

 if final_role='system manager' then
  perms:=array(select code from public.permissions);
  depot_ids:=array(select id from public.depots);
 else
  perms:=array(select code from (values
   ('j','upload_claim'),('k','release_claim'),('l','process_claim'),('m','view_analytics'),
   ('n','manage_access'),('p','view_master_depot'),('s','bulk_process'),('logs','view_logs'),
   ('keyMaster','manage_key_master'),('compilation','view_compilation'),
   ('archiveCompilation','archive_compilation')
  ) as m(letter,code) where lower(coalesce(p_auth->>m.letter,'no')) in('yes','true','approved','visible'));

  if p_depot_codes is null then
   depot_ids:=array(select depot_id from public.user_depot_access where user_id=target);
  else
   -- String kosong berarti "tidak ada depot", bukan "biarkan seperti semula". Tanpa
   -- perbedaan ini yurisdiksi tidak akan pernah bisa dikosongkan.
   depot_ids:='{}'::uuid[];
   foreach code in array string_to_array(p_depot_codes,',') loop
    if btrim(code)<>'' then depot_ids:=depot_ids||public.rc_legacy_depot_id(btrim(code)); end if;
   end loop;
  end if;
 end if;

 perform rc_private.manage_user(target,new_status,perms,depot_ids);
 return jsonb_build_object('status','success','role',final_role,
  'jumlahDepot',coalesce(array_length(depot_ids,1),0),
  'jumlahPermission',coalesce(array_length(perms,1),0));
end $$;
revoke all on function public.rc_legacy_update_access(text,jsonb,text,text,text) from public,anon;
grant execute on function public.rc_legacy_update_access(text,jsonb,text,text,text) to authenticated;

-- manage_user() menolak depot di luar scope penyunting. System Manager memegang seluruh
-- depot, jadi aturan itu tetap berlaku; tetapi pesannya dibuat jelas ketika gagal.
create or replace function rc_private.manage_user(p_user uuid,p_status text,p_permissions text[],p_depots uuid[])
returns void language plpgsql security definer set search_path='' as $$
declare luar text;
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 if p_user=auth.uid() then raise exception 'Tidak dapat mengubah akses sendiri'; end if;
 if p_status not in('active','inactive','rejected') or p_status is null
  or p_permissions is null or p_depots is null then raise exception 'Invalid access values'; end if;
 if exists(select 1 from unnest(p_permissions) x where not exists(select 1 from public.permissions where code=x))
 then raise exception 'Permission tidak dikenali'; end if;
 select string_agg(d.depot_code,', ') into luar from unnest(p_depots) x
  join public.depots d on d.id=x where not rc_private.can_access(x);
 if luar is not null then
  raise exception 'Depot di luar akses Anda: %',luar using errcode='42501'; end if;
 perform 1 from public.profiles where id=p_user for update;
 if not found then raise exception 'User not found'; end if;
 update public.profiles set status=p_status where id=p_user;
 delete from public.user_permissions where user_id=p_user;
 insert into public.user_permissions select p_user,x from unnest(p_permissions) x group by x;
 delete from public.user_depot_access where user_id=p_user;
 insert into public.user_depot_access select p_user,x from unnest(p_depots) x group by x;
 insert into public.activity_logs(actor_id,event_type,entity_id,details)
 values(auth.uid(),'access_changed',p_user,jsonb_build_object('status',p_status,
   'permissions',coalesce(array_length(p_permissions,1),0),
   'depots',coalesce(array_length(p_depots,1),0)));
end $$;

-- Persetujuan pendaftaran tidak boleh lagi menaikkan seseorang menjadi System Manager hanya
-- karena ia menuliskannya pada formulir. Peran itu ditetapkan terpisah oleh System Manager.
create or replace function rc_private.review_registration(p_profile uuid,p_approve boolean,p_note text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.profiles%rowtype; assigned text; peran text;
begin
 if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;
 if p_profile=(select auth.uid()) then raise exception 'Tidak dapat menyetujui akun sendiri'; end if;
 select * into target from public.profiles where id=p_profile for update;
 if not found then raise exception 'Pendaftaran tidak ditemukan'; end if;
 if target.status<>'pending' then raise exception 'Pendaftaran ini sudah diproses'; end if;
 if length(coalesce(p_note,''))>1000 then raise exception 'Catatan terlalu panjang'; end if;

 if p_approve then
  assigned:=rc_private.next_suffix();
  peran:=lower(btrim(coalesce(target.requested_role,'')));
  if peran='system manager' or peran='' then peran:='admin'; end if;
  update public.profiles set status='active',suffix_num=assigned,role=peran,
   reviewed_by=(select auth.uid()),reviewed_at=now(),
   review_note=coalesce(p_note,case when lower(btrim(coalesce(target.requested_role,'')))='system manager'
     then 'Permintaan System Manager tidak diberikan otomatis; tetapkan lewat Kelola Akses.' else null end)
   where id=p_profile;
 else
  update public.profiles set status='rejected',
   reviewed_by=(select auth.uid()),reviewed_at=now(),review_note=p_note where id=p_profile;
 end if;

 insert into public.activity_logs(actor_id,event_type,entity_id,details)
 values((select auth.uid()),case when p_approve then 'registration_approved' else 'registration_rejected' end,
   p_profile,jsonb_build_object('user_code',target.user_code,'suffix_num',assigned,'role',peran));
 return jsonb_build_object('status','success','suffix_num',assigned,'role',peran);
end $$;

------------------------------------------------------------------------------------------
-- 3. Depot pada pendaftaran harus berasal dari master
------------------------------------------------------------------------------------------
-- Pemilik menetapkan depot tidak boleh diketik bebas: kodenya kolom B dan namanya kolom C
-- pada berkas master. Formulir pendaftaran karena itu perlu daftar depot sebelum ada sesi.
--
-- Ini satu-satunya endpoint yang dapat dibaca tanpa login, dan isinya hanya kode serta nama
-- depot. Tidak ada data klaim, pelanggan, nilai maupun identitas di dalamnya.
create or replace function public.rc_public_depots() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('kode',depot_code,'nama',depot_name)
   order by depot_code),'[]'::jsonb) from public.depots;
$$;
revoke all on function public.rc_public_depots() from public;
grant execute on function public.rc_public_depots() to anon,authenticated;

-- Trigger pendaftaran menolak depot yang tidak ada di master, apa pun yang dikirim browser.
create or replace function rc_private.handle_new_user() returns trigger
language plpgsql security definer set search_path='' as $$
declare meta jsonb:=coalesce(new.raw_user_meta_data,'{}'::jsonb);
 v_code text; v_name text; v_email text; v_role text; v_depot text; is_first boolean;
 v_depot_id uuid;
begin
 if meta->>'user_code' is null then
  raise exception 'Akun harus dibuat lewat portal RC (tombol Daftar), atau lewat SQL/Admin API yang menyertakan user_metadata berisi user_code, full_name, business_email dan requested_role. Tombol Add user pada Dashboard tidak menyertakan data itu.';
 end if;
 v_code:=upper(btrim(coalesce(meta->>'user_code','')));
 v_name:=btrim(coalesce(meta->>'full_name',''));
 v_email:=lower(btrim(coalesce(meta->>'business_email','')));
 v_role:=lower(btrim(coalesce(meta->>'requested_role','')));
 v_depot:=btrim(coalesce(meta->>'requested_depot',''));

 if v_code='' or length(v_code)>100 or v_code !~ '^[A-Z0-9._-]+$' then
  raise exception 'User ID wajib diisi, maksimal 100 karakter, hanya huruf, angka, titik, garis bawah dan strip';
 end if;
 if v_name='' or length(v_name)>200 then raise exception 'Nama lengkap wajib diisi'; end if;
 if v_email='' or length(v_email)>320 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
  then raise exception 'Email kantor tidak valid'; end if;
 if v_role not in('admin','osc','non-osc','finance','supervisor','system manager') then
  raise exception 'Role yang diminta tidak dikenali'; end if;
 if exists(select 1 from public.profiles where user_code=v_code) then
  raise exception 'User ID sudah terdaftar'; end if;

 lock table public.profiles in exclusive mode;
 select not exists(select 1 from public.profiles) into is_first;

 -- Pendaftar pertama boleh tanpa depot, karena ia menjadi System Manager atas seluruh depot.
 if not is_first then
  select id into v_depot_id from public.depots where depot_code=v_depot;
  if v_depot_id is null then
   raise exception 'Depot "%" tidak ada di master depot. Pilih depot dari daftar yang tersedia.',v_depot;
  end if;
 end if;

 if is_first then
  insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,
    must_change_password,requested_role,requested_depot,reviewed_at,review_note)
  values(new.id,v_code,v_name,v_email,'system manager','active','001',
    false,v_role,v_depot,now(),'Pendaftar pertama; otomatis menjadi System Manager.');
  insert into public.user_permissions(user_id,permission_code) select new.id,code from public.permissions;
  insert into public.user_depot_access(user_id,depot_id) select new.id,id from public.depots;
  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(new.id,'bootstrap_manager',new.id,
    jsonb_build_object('user_code',v_code,'alasan','pendaftar pertama'));
 else
  insert into public.profiles(id,user_code,full_name,business_email,role,status,suffix_num,
    must_change_password,requested_role,requested_depot)
  values(new.id,v_code,v_name,v_email,v_role,'pending','000',false,v_role,v_depot);
  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(new.id,'registration_submitted',new.id,
    jsonb_build_object('user_code',v_code,'requested_role',v_role,'requested_depot',v_depot));
 end if;
 return new;
end $$;

------------------------------------------------------------------------------------------
-- 4. System Manager yang sudah ada memperoleh seluruh modul dan depot
------------------------------------------------------------------------------------------
-- Migration sebelumnya menambah modul baru tanpa memberikannya ke System Manager yang sudah
-- aktif, dan yurisdiksi depot bisa tertinggal dari ketika depot baru ditambahkan.
insert into public.user_permissions(user_id,permission_code)
select p.id,c.code from public.profiles p cross join public.permissions c
where p.role='system manager' and p.status='active'
on conflict do nothing;

insert into public.user_depot_access(user_id,depot_id)
select p.id,d.id from public.profiles p cross join public.depots d
where p.role='system manager' and p.status='active'
on conflict do nothing;
