-- ==========================================================================================
-- Satu pintu: seluruh data depot lewat Key Master > Depot Master, approval di Kelola Akses
-- ==========================================================================================
-- Keputusan pemilik menyederhanakan rancangan sebelumnya. Tidak ada lagi halaman Profil Depot
-- tersendiri untuk menyunting: Depot Master pada Key Master menjadi satu-satunya tempat data
-- depot diisi, dan kotak masuk persetujuannya berada di Kelola Akses bersama persetujuan lain.
--
-- SATU FUNGSI, DUA PERILAKU - DAN ITU DISENGAJA
-- rc_depot_save menerima isian dari siapa pun yang berhak atas depot itu, lalu memutuskan
-- sendiri apa yang terjadi:
--
--   Supervisor atau System Manager  perubahan langsung diterapkan
--   Selain itu                      perubahan masuk antrean persetujuan, dan nilai lama
--                                   tetap berlaku sampai disetujui
--
-- Alternatifnya adalah dua tombol berbeda di layar, dan itu justru lebih rawan: seseorang akan
-- menekan tombol yang salah, atau layar akan menampilkan tombol yang sebenarnya tidak berhak ia
-- pakai. Dengan satu pintu, wewenang diputuskan server, bukan ditebak layar.
--
-- GRADE TETAP TERPISAH. Ia hanya dapat ditetapkan System Manager lewat tab tersendiri, dan
-- tidak pernah ikut dalam pengajuan - lihat daftar kunci yang diizinkan di bawah.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- Daftar depot kini memuat seluruh isian profil sekaligus bagian yang dihitung sendiri
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_depot_list(
  p_search text default null, p_offset integer default 0, p_limit integer default 50)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare v_search text; v_limit integer; v_offset integer;
begin
  if not rc_private.can_access(null,'manage_key_master') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak membuka Key Master' using errcode='42501'; end if;
  v_search := nullif(btrim(coalesce(p_search,'')),'');
  v_limit  := least(greatest(coalesce(p_limit,50),1),500);
  v_offset := greatest(coalesce(p_offset,0),0);

  return (select jsonb_build_object('status','success',
    'bolehLangsung', rc_private.is_manager(),
    'total',(select count(*) from public.depots d
       where v_search is null
          or d.depot_code ilike '%'||v_search||'%'
          or d.depot_name ilike '%'||v_search||'%'
          or coalesce(d.region,'') ilike '%'||v_search||'%'),
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
             where v_search is null
                or d.depot_code ilike '%'||v_search||'%'
                or d.depot_name ilike '%'||v_search||'%'
                or coalesce(d.region,'') ilike '%'||v_search||'%'
             order by d.depot_code offset v_offset limit v_limit) t),'[]'::jsonb)));
end $fn$;
revoke all on function public.rc_depot_list(text,integer,integer) from public,anon;
grant execute on function public.rc_depot_list(text,integer,integer) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Satu pintu penyimpanan
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_depot_save(p_kode text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_depot uuid; v_kode text; v_id uuid; v_bersih jsonb := '{}'::jsonb; k text;
  -- Grade sengaja TIDAK ada di daftar ini. Ia wewenang System Manager lewat tab tersendiri,
  -- dan membiarkannya lewat di sini akan menjadi pintu belakang.
  v_izin text[] := array['nama','abbr','region','alamat','gmapsUrl','fotoUrl','tipeDepot',
    'kepalaDepot','kepalaAdmin','karAdmin','karSales','karDriver','karFg','karPcc',
    'karTeknisi','karLain','emailRsm','emailAsm','emailSm','emailTo','emailCc'];
begin
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

  -- Alamat email diperiksa sekarang, baik perubahannya akan langsung diterapkan maupun masuk
  -- antrean, supaya kesalahan ketik tidak menunggu sampai persetujuan untuk ketahuan.
  perform rc_private.periksa_email_maks(v_bersih->>'emailRsm','Email RSM');
  perform rc_private.periksa_email_maks(v_bersih->>'emailAsm','Email ASM');
  perform rc_private.periksa_email_maks(v_bersih->>'emailSm','Email SM');
  perform rc_private.periksa_email_maks(v_bersih->>'emailTo','Email Depot (TO)');
  perform rc_private.periksa_email_maks(v_bersih->>'emailCc','Email Depot (CC)');

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
end $fn$;
revoke all on function public.rc_depot_save(text,jsonb) from public,anon;
grant execute on function public.rc_depot_save(text,jsonb) to authenticated;

-- Penerapan sebenarnya, dipakai baik oleh penyimpanan langsung maupun oleh persetujuan,
-- supaya keduanya tidak mungkin menyimpang satu sama lain.
create or replace function rc_private.terapkan_depot(p_depot uuid, c jsonb)
returns void language plpgsql security definer set search_path='' as $fn$
begin
  update public.depots set
    depot_name   = case when c ? 'nama'    then coalesce(nullif(btrim(c->>'nama'),''), depot_name) else depot_name end,
    abbr         = case when c ? 'abbr'    then nullif(upper(btrim(coalesce(c->>'abbr',''))),'') else abbr end,
    region       = case when c ? 'region'  then nullif(btrim(coalesce(c->>'region','')),'') else region end,
    address      = case when c ? 'alamat'  then nullif(btrim(coalesce(c->>'alamat','')),'') else address end,
    email_to     = case when c ? 'emailTo' then nullif(btrim(coalesce(c->>'emailTo','')),'') else email_to end,
    email_cc     = case when c ? 'emailCc' then nullif(btrim(coalesce(c->>'emailCc','')),'') else email_cc end,
    updated_at   = now(), updated_by = (select auth.uid())
  where id = p_depot;

  insert into public.depot_profiles(depot_id) values(p_depot) on conflict(depot_id) do nothing;

  update public.depot_profiles set
    tipe_depot   = case when c ? 'tipeDepot'   then nullif(btrim(c->>'tipeDepot'),'')   else tipe_depot end,
    alamat       = case when c ? 'alamat'      then nullif(btrim(c->>'alamat'),'')      else alamat end,
    gmaps_url    = case when c ? 'gmapsUrl'    then nullif(btrim(c->>'gmapsUrl'),'')    else gmaps_url end,
    foto_url     = case when c ? 'fotoUrl'     then nullif(btrim(c->>'fotoUrl'),'')     else foto_url end,
    kepala_depot = case when c ? 'kepalaDepot' then nullif(btrim(c->>'kepalaDepot'),'') else kepala_depot end,
    kepala_admin = case when c ? 'kepalaAdmin' then nullif(btrim(c->>'kepalaAdmin'),'') else kepala_admin end,
    kar_admin    = case when c ? 'karAdmin'   then greatest(coalesce((c->>'karAdmin')::int,0),0)   else kar_admin end,
    kar_sales    = case when c ? 'karSales'   then greatest(coalesce((c->>'karSales')::int,0),0)   else kar_sales end,
    kar_driver   = case when c ? 'karDriver'  then greatest(coalesce((c->>'karDriver')::int,0),0)  else kar_driver end,
    kar_fg       = case when c ? 'karFg'      then greatest(coalesce((c->>'karFg')::int,0),0)      else kar_fg end,
    kar_pcc      = case when c ? 'karPcc'     then greatest(coalesce((c->>'karPcc')::int,0),0)     else kar_pcc end,
    kar_teknisi  = case when c ? 'karTeknisi' then greatest(coalesce((c->>'karTeknisi')::int,0),0) else kar_teknisi end,
    kar_lain     = case when c ? 'karLain'    then greatest(coalesce((c->>'karLain')::int,0),0)    else kar_lain end,
    email_rsm    = case when c ? 'emailRsm'   then rc_private.periksa_email_maks(c->>'emailRsm','Email RSM') else email_rsm end,
    email_asm    = case when c ? 'emailAsm'   then rc_private.periksa_email_maks(c->>'emailAsm','Email ASM') else email_asm end,
    email_sm     = case when c ? 'emailSm'    then rc_private.periksa_email_maks(c->>'emailSm','Email SM')   else email_sm end,
    email_depot  = case when c ? 'emailTo'    then nullif(btrim(c->>'emailTo'),'') else email_depot end,
    updated_at = now(), updated_by = (select auth.uid())
  where depot_id = p_depot;
end $fn$;
revoke all on function rc_private.terapkan_depot(uuid,jsonb) from public,anon,authenticated;

-- Persetujuan memakai penerapan yang sama.
create or replace function public.rc_depot_profile_review(
  p_id uuid, p_setujui boolean, p_catatan text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare r public.depot_profile_requests; v_kode text;
begin
  if not rc_private.is_manager() then
    raise exception 'Hanya Supervisor atau System Manager yang dapat menyetujui' using errcode='42501'; end if;
  select * into r from public.depot_profile_requests where id=p_id and status='pending' for update;
  if not found then raise exception 'Pengajuan tidak ditemukan atau sudah diproses'; end if;
  if not rc_private.can_access(r.depot_id) then
    raise exception 'Depot ini di luar wilayah Anda' using errcode='42501'; end if;
  select depot_code into v_kode from public.depots where id=r.depot_id;

  if not coalesce(p_setujui,false) then
    update public.depot_profile_requests
       set status='rejected', reviewer_id=(select auth.uid()), reviewed_at=now(),
           catatan=left(btrim(coalesce(p_catatan,'')),300)
     where id=p_id;
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
end $fn$;
revoke all on function public.rc_depot_profile_review(uuid,boolean,text) from public,anon;
grant execute on function public.rc_depot_profile_review(uuid,boolean,text) to authenticated;

create or replace function rc_private.marker_20261022() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261022() from public,anon;
grant execute on function rc_private.marker_20261022() to authenticated;

select 'Depot Master menjadi satu pintu' as hasil,
 (select count(*) from public.depots) as depot,
 (select count(*) from public.depot_profiles) as profil_terisi,
 (select count(*) from public.depot_profile_requests where status='pending') as pengajuan_tertunda;
