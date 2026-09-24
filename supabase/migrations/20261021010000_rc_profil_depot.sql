-- ==========================================================================================
-- Profil Depot: disimpan, diajukan depot, disetujui Supervisor area atau System Manager
-- ==========================================================================================
-- Halaman Profil Depot sudah lama ada di layar dengan seluruh kolomnya, tetapi tidak pernah
-- punya tempat penyimpanan sendiri: isinya dibaca dari data warisan dan tidak dapat disunting
-- siapa pun. Berkas ini memberinya tabel, alur pengajuan, dan persetujuan.
--
-- APA YANG DIISI DEPOT, APA YANG DIHITUNG SENDIRI
-- Empat hal sengaja TIDAK disimpan di tabel ini dan selalu dihitung ulang saat dibaca:
--
--   Region          diambil dari master depot lewat kode depot. Menyimpannya dua kali berarti
--                   suatu saat keduanya berbeda, dan tidak ada yang tahu mana yang benar.
--   Tim Pengawas    diturunkan dari user_supervision: OSC yang memegang depot itu, dan
--   (OSC)           supervisor di atasnya. Berubah sendiri ketika penugasan berubah.
--   Akun terdaftar  diturunkan dari profiles yang memiliki depot itu pada yurisdiksinya.
--   Total karyawan  jumlah dari rincian per fungsi; mengetiknya terpisah hanya mengundang
--                   selisih yang tidak dapat dijelaskan.
--
-- ALUR PERSETUJUAN
-- Depot mengajukan, lalu Supervisor wilayahnya atau System Manager menyetujui. Selama menunggu,
-- nilai lama tetap berlaku - perubahan hanya diterapkan pada saat disetujui, bukan saat
-- diajukan. Dengan begitu pengajuan yang salah tidak pernah sempat memengaruhi laporan.
--
-- EMAIL
-- Empat kolom email: RSM, ASM, SM, dan depot. Masing-masing boleh memuat sampai empat alamat
-- dipisah koma. Batas itu ditegakkan di server, bukan hanya di layar, sehingga unggahan massal
-- maupun pemanggil lain tunduk pada aturan yang sama.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create table if not exists public.depot_profiles(
  depot_id uuid primary key references public.depots(id) on delete cascade,
  tipe_depot text,
  grade text,
  alamat text,
  gmaps_url text,
  foto_url text,
  kepala_depot text,
  kepala_admin text,
  kar_admin integer not null default 0 check(kar_admin >= 0),
  kar_sales integer not null default 0 check(kar_sales >= 0),
  kar_driver integer not null default 0 check(kar_driver >= 0),
  kar_fg integer not null default 0 check(kar_fg >= 0),
  kar_pcc integer not null default 0 check(kar_pcc >= 0),
  kar_teknisi integer not null default 0 check(kar_teknisi >= 0),
  kar_lain integer not null default 0 check(kar_lain >= 0),
  email_rsm text,
  email_asm text,
  email_sm text,
  email_depot text,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);
alter table public.depot_profiles enable row level security;
revoke all on public.depot_profiles from public,anon,authenticated;
grant select on public.depot_profiles to authenticated;
drop policy if exists depot_profiles_baca on public.depot_profiles;
create policy depot_profiles_baca on public.depot_profiles
 for select to authenticated using (rc_private.can_access(depot_id));

-- Grade hanya boleh ditetapkan System Manager, jadi ia tidak pernah ikut dalam pengajuan depot.
comment on column public.depot_profiles.grade is
  'Ditetapkan System Manager lewat tab Grade Depot di Kelola Akses. Tidak dapat diubah lewat pengajuan profil.';

-- ------------------------------------------------------------------------------------------
-- Pengajuan perubahan
-- ------------------------------------------------------------------------------------------
create table if not exists public.depot_profile_requests(
  id uuid primary key default gen_random_uuid(),
  depot_id uuid not null references public.depots(id) on delete cascade,
  requester_id uuid not null references public.profiles(id),
  perubahan jsonb not null,
  status text not null default 'pending' check(status in('pending','approved','rejected')),
  reviewer_id uuid references public.profiles(id),
  catatan text not null default '',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index if not exists depot_profile_requests_pending_idx
  on public.depot_profile_requests(status, created_at desc);
alter table public.depot_profile_requests enable row level security;
revoke all on public.depot_profile_requests from public,anon,authenticated;

-- ------------------------------------------------------------------------------------------
-- Batas empat alamat per kolom
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.periksa_email_maks(p_teks text, p_nama text)
returns text language plpgsql immutable set search_path='' as $fn$
declare n integer;
begin
  if coalesce(btrim(p_teks),'') = '' then return null; end if;
  n := coalesce(array_length(rc_private.pecah_email(p_teks),1),0);
  if n = 0 then
    raise exception 'Kolom % tidak memuat satu pun alamat email yang sah', p_nama; end if;
  if n > 4 then
    raise exception 'Kolom % memuat % alamat; maksimal 4', p_nama, n; end if;
  return btrim(p_teks);
end $fn$;
revoke all on function rc_private.periksa_email_maks(text,text) from public,anon;

-- ------------------------------------------------------------------------------------------
-- Membaca profil, lengkap dengan bagian yang dihitung sendiri
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_depot_profile(p_kode text)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_depot uuid; v_kode text;
begin
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
      'diperbaruiPada', to_char(p.updated_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')
    )
    from public.depots d
    left join public.depot_profiles p on p.depot_id = d.id
   where d.id = v_depot);
end $fn$;
revoke all on function public.rc_depot_profile(text) from public,anon;
grant execute on function public.rc_depot_profile(text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Mengajukan perubahan
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_depot_profile_request(p_kode text, p_perubahan jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_depot uuid; v_kode text; v_id uuid; v_bersih jsonb := '{}'::jsonb; k text;
  v_izin text[] := array['tipeDepot','alamat','gmapsUrl','fotoUrl','kepalaDepot','kepalaAdmin',
    'karAdmin','karSales','karDriver','karFg','karPcc','karTeknisi','karLain',
    'emailRsm','emailAsm','emailSm','emailDepot'];
begin
  v_kode := upper(btrim(coalesce(p_kode,'')));
  select id into v_depot from public.depots where depot_code = v_kode;
  if v_depot is null then raise exception 'Depot "%" tidak ditemukan', v_kode; end if;
  if not rc_private.can_access(v_depot) then
    raise exception 'Depot ini di luar yurisdiksi Anda' using errcode='42501'; end if;
  if jsonb_typeof(p_perubahan) <> 'object' then raise exception 'Perubahan tidak sah'; end if;

  -- Hanya kunci yang diizinkan yang diteruskan. Grade sengaja tidak ada di daftar: ia wewenang
  -- System Manager, dan membiarkannya lewat di sini akan menjadi pintu belakang.
  for k in select jsonb_object_keys(p_perubahan) loop
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
end $fn$;
revoke all on function public.rc_depot_profile_request(text,jsonb) from public,anon;
grant execute on function public.rc_depot_profile_request(text,jsonb) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Kotak masuk dan persetujuan
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_depot_profile_requests()
returns jsonb language sql stable security definer set search_path='' as $fn$
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
$fn$;
revoke all on function public.rc_depot_profile_requests() from public,anon;
grant execute on function public.rc_depot_profile_requests() to authenticated;

create or replace function public.rc_depot_profile_review(
  p_id uuid, p_setujui boolean, p_catatan text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare r public.depot_profile_requests; c jsonb; v_kode text;
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

  c := r.perubahan;
  insert into public.depot_profiles(depot_id) values(r.depot_id)
  on conflict(depot_id) do nothing;

  -- Hanya kolom yang benar-benar diajukan yang disentuh; sisanya dibiarkan apa adanya.
  update public.depot_profiles set
    tipe_depot   = case when c ? 'tipeDepot'   then nullif(btrim(c->>'tipeDepot'),'')   else tipe_depot end,
    alamat       = case when c ? 'alamat'      then nullif(btrim(c->>'alamat'),'')      else alamat end,
    gmaps_url    = case when c ? 'gmapsUrl'    then nullif(btrim(c->>'gmapsUrl'),'')    else gmaps_url end,
    foto_url     = case when c ? 'fotoUrl'     then nullif(btrim(c->>'fotoUrl'),'')     else foto_url end,
    kepala_depot = case when c ? 'kepalaDepot' then nullif(btrim(c->>'kepalaDepot'),'') else kepala_depot end,
    kepala_admin = case when c ? 'kepalaAdmin' then nullif(btrim(c->>'kepalaAdmin'),'') else kepala_admin end,
    kar_admin    = case when c ? 'karAdmin'    then greatest(coalesce((c->>'karAdmin')::int,0),0)    else kar_admin end,
    kar_sales    = case when c ? 'karSales'    then greatest(coalesce((c->>'karSales')::int,0),0)    else kar_sales end,
    kar_driver   = case when c ? 'karDriver'   then greatest(coalesce((c->>'karDriver')::int,0),0)   else kar_driver end,
    kar_fg       = case when c ? 'karFg'       then greatest(coalesce((c->>'karFg')::int,0),0)       else kar_fg end,
    kar_pcc      = case when c ? 'karPcc'      then greatest(coalesce((c->>'karPcc')::int,0),0)      else kar_pcc end,
    kar_teknisi  = case when c ? 'karTeknisi'  then greatest(coalesce((c->>'karTeknisi')::int,0),0)  else kar_teknisi end,
    kar_lain     = case when c ? 'karLain'     then greatest(coalesce((c->>'karLain')::int,0),0)     else kar_lain end,
    email_rsm    = case when c ? 'emailRsm'    then rc_private.periksa_email_maks(c->>'emailRsm','Email RSM')     else email_rsm end,
    email_asm    = case when c ? 'emailAsm'    then rc_private.periksa_email_maks(c->>'emailAsm','Email ASM')     else email_asm end,
    email_sm     = case when c ? 'emailSm'     then rc_private.periksa_email_maks(c->>'emailSm','Email SM')       else email_sm end,
    email_depot  = case when c ? 'emailDepot'  then rc_private.periksa_email_maks(c->>'emailDepot','Email Depot') else email_depot end,
    updated_at = now(), updated_by = (select auth.uid())
  where depot_id = r.depot_id;

  -- Email depot juga menjadi tujuan email otomatis, jadi master depot ikut disejalankan.
  if c ? 'emailDepot' then
    update public.depots set email_to = nullif(btrim(c->>'emailDepot'),'') where id = r.depot_id;
  end if;

  update public.depot_profile_requests
     set status='approved', reviewer_id=(select auth.uid()), reviewed_at=now(),
         catatan=left(btrim(coalesce(p_catatan,'')),300)
   where id=p_id;

  insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
  values((select auth.uid()),r.depot_id,'profil_disetujui',p_id,c);

  return jsonb_build_object('status','success','message','Profil '||v_kode||' diperbarui.');
end $fn$;
revoke all on function public.rc_depot_profile_review(uuid,boolean,text) from public,anon;
grant execute on function public.rc_depot_profile_review(uuid,boolean,text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Grade Depot, wewenang System Manager
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_depot_grade_list()
returns jsonb language sql stable security definer set search_path='' as $fn$
  select jsonb_build_object('status','success','rows', coalesce(jsonb_agg(jsonb_build_object(
      'kode',d.depot_code,'nama',d.depot_name,
      'region',coalesce(d.region,''),
      'grade',coalesce(p.grade,''),
      'tipe',coalesce(p.tipe_depot,''))
      order by d.depot_code),'[]'::jsonb))
    from public.depots d
    left join public.depot_profiles p on p.depot_id = d.id
   where rc_private.is_system_manager();
$fn$;
revoke all on function public.rc_depot_grade_list() from public,anon;
grant execute on function public.rc_depot_grade_list() to authenticated;

create or replace function public.rc_depot_grade_set(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare r jsonb; v_depot uuid; n integer := 0;
begin
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
end $fn$;
revoke all on function public.rc_depot_grade_set(jsonb) from public,anon;
grant execute on function public.rc_depot_grade_set(jsonb) to authenticated;

create or replace function rc_private.marker_20261021() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261021() from public,anon;
grant execute on function rc_private.marker_20261021() to authenticated;

select 'Profil Depot terpasang' as hasil,
 (select count(*) from public.depot_profiles) as profil_terisi,
 (select count(*) from public.depots) as depot,
 (select count(*) from public.depot_profile_requests where status='pending') as pengajuan_tertunda;
