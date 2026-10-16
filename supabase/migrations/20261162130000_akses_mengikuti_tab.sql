-- ==========================================================================================
-- Akses mengikuti tab: siapa pun yang diberi sebuah modul/tab dapat menjalankan seluruh aksinya
-- ==========================================================================================
-- Diminta pemilik, 6 Oktober 2026:
--   "terdapat user yang aksesnya tidak sinkron, ketika expired dan on hold muncul remark tidak
--    bisa, sinkronisasi semua ketika di kasih akses suatu modul atau tab maka semua langsung
--    bisa di authorize tanpa ada kendala."
--   "ada user yang dia tidak bisa on hold expired dan lainnya. yakni user admin, saya mau
--    ketika sudah dibuka aksesnya maka sudah bisa melakukan semuanya."
--
-- SEBELUMNYA hak sebuah aksi ditentukan DUA hal yang tidak saling mengenal: tab/izin yang
-- dicentang di Access Management, dan daftar PERAN yang ditulis mati di dalam fungsinya.
-- Akibatnya tab tampil, tombolnya ada, tetapi servernya menolak karena perannya "salah":
--   * On Hold & Expired   - hanya OSC/Supervisor/Management/System Manager (boleh_putus_hold)
--   * Overdue             - semua kecuali Depot Head (boleh_approve_overdue)
--   * Arsip Compilation   - hanya Supervisor/System Manager, padahal tombolnya mengikuti izin
--                           archive_compilation
--   * Batal Not Achieved  - hanya OSC ke atas (is_osc_ke_atas)
--   * Depot Master        - non-Supervisor selalu diantrekan, walau ia sendiri pemegang tab
--                           Approval Request
--   * Access Management   - seluruh perubahan hanya Supervisor/System Manager; pemegang izin
--                           manage_access lain hanya melihat
--   * Email, Grade Depot, Arsip Hapus Akun, Email Pengajuan - hanya System Manager/Supervisor
--
-- SEKARANG satu sumber: tab yang diberikan (rc_private.can_tab, yang sudah mensyaratkan izin
-- modulnya). Peran tidak lagi menentukan BOLEH-TIDAKNYA sebuah aksi. Yang tetap dijaga, karena
-- itu bukan soal akses melainkan keselamatan data:
--   1. YURISDIKSI. Setiap aksi tetap hanya mengenai depot yang terjangkau (can_access).
--      Pengembalian arsip Compilation dan Grade Depot kini ikut disaring per depot - dulu
--      keduanya tidak perlu karena hanya Supervisor/System Manager yang dapat memanggilnya.
--   2. TIDAK ADA ESKALASI. Pemegang izin Access Management yang bukan Supervisor/System
--      Manager hanya dapat memberikan peran setingkat dirinya ke bawah (bukan Supervisor,
--      Management, atau System Manager) dan hanya izin modul yang ia miliki sendiri. Tanpa
--      ini, seorang admin dapat mengangkat rekannya menjadi Depot Head, yang memegang seluruh
--      izin, lalu rekannya membalas - dan keduanya melampaui apa yang diberikan kepada mereka.
--   3. Aturan lama yang tetap: hanya System Manager yang mengangkat System Manager; tidak
--      ada yang menyunting akses dirinya sendiri; System Manager aktif terakhir tidak dapat
--      dihapus.
--
-- KEPUTUSAN PEMILIK YANG DIPERTAHANKAN SEBAGAI BAWAAN TAB, BUKAN LAGI SEBAGAI GERBANG PERAN
--   Depot Head menangani Within Payment Term saja (keputusan pemilik). Kini itu berarti tab
--   Overdue dan On Hold & Expired Depot Head BAWAANNYA MATI - dan bila System Manager
--   mencentangnya di Access Management, Depot Head itu langsung dapat menjalankannya. Dengan
--   begitu layar dan server selalu sepakat: centang = bisa, tidak dicentang = tidak tampil.
--
-- Ditambal pada definisi yang hidup dengan penjaga: MD5 pra-citra (akhir baris dinormalkan ke
-- LF, karena prod menyimpan sebagian fungsi dengan CRLF) sama di dev dan di prod setelah
-- migrasi 20261162010000-120000, dan setiap pola harus ditemukan tepat sebanyak yang
-- diharapkan. Fungsi yang sudah memuat penanda 20261162130000 dilewati.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $prasyarat$
begin
  if pg_get_functiondef('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)'::regprocedure) !~ 'reject_bulk' then
    raise exception 'DITOLAK: jalankan 20261162120000_bulk_tolak.sql lebih dulu.'; end if;
end
$prasyarat$;

-- ------------------------------------------------------------------------------------------
-- 1. Pembantu
-- ------------------------------------------------------------------------------------------

-- Peringkat peran, dipakai SEMATA untuk mencegah seseorang memberi peran di atas dirinya.
-- Tidak menentukan akses apa pun.
create or replace function rc_private.peringkat_peran(p_role text)
returns integer language sql immutable set search_path = '' as $fn$
  select case lower(btrim(coalesce(p_role,'')))
    when 'system manager' then 5
    when 'supervisor'     then 4
    when 'management'     then 4
    when 'depot head'     then 3
    when 'osc'            then 2
    else 1 end;
$fn$;
revoke all on function rc_private.peringkat_peran(text) from public, anon;
grant execute on function rc_private.peringkat_peran(text) to authenticated;

-- Boleh mengubah di Access Management: Supervisor/System Manager seperti dulu, ATAU siapa pun
-- yang diberi izin modul Access Management (manage_access; Depot Head dan Management memegang
-- seluruh izin lewat perannya). Tab mana yang boleh dipakai tetap ditentukan require_tab di
-- setiap fungsi.
create or replace function rc_private.boleh_kelola_akses()
returns boolean language sql stable security definer set search_path = '' as $fn$
  select rc_private.is_manager() or rc_private.can_access(null, 'manage_access');
$fn$;
revoke all on function rc_private.boleh_kelola_akses() from public, anon;
grant execute on function rc_private.boleh_kelola_akses() to authenticated;

-- Peran yang boleh diberikan pemanggil kepada orang lain.
--   System Manager : semua.
--   Supervisor     : semua kecuali System Manager (tidak berubah).
--   Pemegang izin Access Management lainnya: setingkat dirinya ke bawah, dan tidak pernah
--     Supervisor atau Management - keduanya memperoleh jangkauan lintas depot (Supervisor
--     melihat seluruh depot di Report dan Timetable; Management lewat region) yang tidak
--     dimiliki pemberinya.
create or replace function rc_private.boleh_beri_peran(p_role text)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select case
    when rc_private.is_system_manager() then true
    when lower(btrim(coalesce(p_role,''))) = 'system manager' then false
    when rc_private.is_manager() then true
    when not rc_private.boleh_kelola_akses() then false
    else lower(btrim(coalesce(p_role,''))) not in ('supervisor','management')
     and rc_private.peringkat_peran(p_role) <= rc_private.peringkat_peran(
           (select p.role from public.profiles p where p.id = (select auth.uid())))
  end;
$fn$;
revoke all on function rc_private.boleh_beri_peran(text) from public, anon;
grant execute on function rc_private.boleh_beri_peran(text) to authenticated;

-- Arsip Compilation: tombolnya berada di tab Document Center > Arsip, dan haknya adalah modul
-- Archive Compilation (tab archive.execute). Keduanya harus dipegang.
create or replace function rc_private.boleh_arsip_compilation()
returns boolean language sql stable security definer set search_path = '' as $fn$
  select rc_private.can_tab('compilation.archive') and rc_private.can_tab('archive.execute');
$fn$;
revoke all on function rc_private.boleh_arsip_compilation() from public, anon;
grant execute on function rc_private.boleh_arsip_compilation() to authenticated;

-- Akun di Arsip Hapus tidak lagi punya depot, sehingga can_manage_user selalu menolaknya bagi
-- selain System Manager. Jangkauannya dibaca dari depot asal akun itu.
create or replace function rc_private.boleh_pulihkan_akun(p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select rc_private.is_system_manager() or (
    rc_private.can_tab('access.arsip') and exists(
      select 1 from public.profiles p
       where p.id = p_id and p.status = 'deleted' and p.role <> 'system manager'
         and p.id <> (select auth.uid())
         and p.home_depot_id is not null and rc_private.can_access(p.home_depot_id)
         and rc_private.boleh_beri_peran(p.role)));
$fn$;
revoke all on function rc_private.boleh_pulihkan_akun(uuid) from public, anon;
grant execute on function rc_private.boleh_pulihkan_akun(uuid) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Gerbang peran On Hold & Expired dan Overdue menjadi gerbang tab
-- ------------------------------------------------------------------------------------------
do $pra_gerbang$
declare f record; isi text;
begin
  for f in select * from (values
      ('rc_private.boleh_putus_hold()',      '2267d8525062c7c89b300fd020d2d33d'),
      ('rc_private.boleh_approve_overdue()', '6000975e2d01566ad769b72d6c458a64')) v(sig, harapan)
  loop
    isi := pg_get_functiondef(to_regprocedure(f.sig));
    if isi ~ '20261162130000' then continue; end if;
    if md5(replace(isi, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(isi, E'\r', '')); end if;
  end loop;
end
$pra_gerbang$;

create or replace function rc_private.boleh_putus_hold()
returns boolean language sql stable security definer set search_path = '' as $fn$
  -- 20261162130000: hak memutuskan On Hold & Expired = memegang tab On Hold & Expired.
  -- can_tab sudah mensyaratkan akun aktif dan izin approve_claim. Jangkauannya tetap dijaga
  -- can_access(depot,'approve_claim') pada setiap baris.
  select rc_private.can_tab('approval.hold');
$fn$;

create or replace function rc_private.boleh_approve_overdue()
returns boolean language sql stable security definer set search_path = '' as $fn$
  -- 20261162130000: hak menyetujui Overdue = memegang tab Overdue. Batasan Depot Head (Within
  -- Payment Term saja) kini menjadi bawaan tab-nya di rc_private.tab_rights.
  select rc_private.can_tab('approval.ovd');
$fn$;

-- ------------------------------------------------------------------------------------------
-- 3. Tambalan teks pada fungsi yang hidup
-- ------------------------------------------------------------------------------------------
do $tambal$
declare
  f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;

  insert into _tambal(sig, harapan, lama, ganti, n) values
  -- ---- Bawaan tab Depot Head: Overdue dan On Hold & Expired mati sampai dicentang ---------
  ('rc_private.tab_rights(uuid)', '5222f212689f275c52b5587b7122ea58',
   $p$coalesce(u.allowed,true)$p$,
   $p$coalesce(u.allowed, /* 20261162130000: Depot Head bawaannya Within Payment Term saja */ not (p.role='depot head' and t.code in ('approval.ovd','approval.hold')))$p$, 1),

  -- ---- Pesan mesin status bila tab On Hold & Expired tidak dipegang ----------------------
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '850c9cba9c4b31e12d56c001ddc8b7a2',
   $p$'Keputusan On Hold dan Expired ditetapkan OSC, Supervisor, Management atau System Manager'$p$,
   $p$/* 20261162130000 */ 'Anda belum diberi akses tab On Hold & Expired'$p$, 1),

  -- ---- Arsip Compilation ------------------------------------------------------------------
  ('rc_private.archive_claims(uuid[],text)', '043f152f1acac936de7e533bec34c87b',
   $p$ if not rc_private.is_manager() then raise exception 'Hanya System Manager yang dapat mengarsipkan' using errcode='42501'; end if;$p$,
   $p$ if not rc_private.boleh_arsip_compilation() /* 20261162130000 */ then raise exception 'Anda belum diberi akses Archive Compilation' using errcode='42501'; end if;$p$, 1),
  ('rc_private.unarchive_claims(uuid[])', '12de33c9fe08d0a0586631661fb1e5af',
   $p$ if not rc_private.is_manager() then raise exception 'Hanya System Manager yang dapat mengembalikan arsip' using errcode='42501'; end if;$p$,
   $p$ if not rc_private.boleh_arsip_compilation() /* 20261162130000 */ then raise exception 'Anda belum diberi akses Archive Compilation' using errcode='42501'; end if;
 -- Sama dengan pengarsipan: depot di luar jangkauan tidak ikut dipulihkan walau id-nya ditebak.
 if exists(select 1 from public.claims where id=any(p_ids) and archived_at is not null and not rc_private.can_access(depot_id)) then
  raise exception 'Ada baris di luar akses depot Anda' using errcode='42501'; end if;$p$, 1),
  ('public.rc_archived_list(integer,integer)', '8ce5f9cead07bc8a8dcc4ad3f662107e',
   $p$ if not rc_private.is_manager() then raise exception 'Hanya System Manager' using errcode='42501'; end if;$p$,
   $p$ if not rc_private.boleh_arsip_compilation() /* 20261162130000 */ then raise exception 'Anda belum diberi akses Archive Compilation' using errcode='42501'; end if;$p$, 1),
  ('public.rc_compilation_list(text,text,text,text,integer,integer)', '7656d81cf662027c58bf72dbd2663b46',
   $p$'canArchive',rc_private.can_access(null,'archive_compilation'))$p$,
   $p$'canArchive',rc_private.boleh_arsip_compilation() /* 20261162130000 */)$p$, 1),

  -- ---- Timetable: membatalkan Not Achieved sama syaratnya dengan menandai -----------------
  ('public.rc_timetable_mark(jsonb,jsonb,boolean,text)', '8652ab861a91926c50511fcacbe6b6bb',
   $p$    if not rc_private.can_access(null,'manage_timetable') and not rc_private.is_osc_ke_atas() then$p$,
   $p$    if not rc_private.can_access(null,'manage_timetable') /* 20261162130000 */ then$p$, 1),
  ('public.rc_timetable_mark(jsonb,jsonb,boolean,text)', '8652ab861a91926c50511fcacbe6b6bb',
   $p$    -- Membatalkan: minimal OSC. Membuka kembali jalan masuk klaim adalah keputusan atasan.$p$,
   $p$    -- Membatalkan: cukup memegang akses Timetable, sama dengan menandai (20261162130000).$p$, 1),
  ('public.rc_timetable_mark(jsonb,jsonb,boolean,text)', '8652ab861a91926c50511fcacbe6b6bb',
   $p$    if not rc_private.is_osc_ke_atas() then$p$,
   $p$    if not rc_private.can_access(null,'manage_timetable') then$p$, 1),
  ('public.rc_timetable_mark(jsonb,jsonb,boolean,text)', '8652ab861a91926c50511fcacbe6b6bb',
   $p$'Hanya OSC, Supervisor atau System Manager yang dapat membatalkan tanda Not Achieved'$p$,
   $p$'Anda belum diberi akses Timetable untuk membatalkan tanda Not Achieved'$p$, 1),
  ('public.rc_timetable_not_achieved()', '4d3a4b16668f6a5cabe5114f2acb897c',
   $p$'bolehBatalkan',rc_private.is_osc_ke_atas());$p$,
   $p$'bolehBatalkan',rc_private.can_tab('timetable.matrix') and rc_private.can_access(null,'manage_timetable') /* 20261162130000 */);$p$, 1),

  -- ---- Depot Master dan Persetujuan Depot ---------------------------------------------------
  -- Simpan langsung bila penyimpannya sendiri pemegang tab Approval Request untuk depot itu;
  -- selain itu diantrekan seperti dulu.
  ('public.rc_depot_save(text,jsonb)', '1e5832d4f969a0e74728ed67a238a5a8',
   $p$  if not rc_private.is_manager() then$p$,
   $p$  if not rc_private.can_tab('access.req') /* 20261162130000 */ then$p$, 1),
  ('public.rc_depot_save(text,jsonb)', '1e5832d4f969a0e74728ed67a238a5a8',
   $p$sampai Supervisor wilayah atau System Manager menyetujui.$p$,
   $p$sampai pemegang akses Approval Request depot ini menyetujui.$p$, 1),
  ('public.rc_depot_list(text,integer,integer)', 'b77a7b6a772779008fd4a2e900424c07',
   $p$'bolehLangsung', rc_private.is_manager(),$p$,
   $p$'bolehLangsung', rc_private.can_tab('access.req') /* 20261162130000 */,$p$, 1),
  ('public.rc_depot_profile_requests()', 'd60aa9485d0965e6b908d50c54331f99',
   $p$where r.status='pending' and rc_private.is_manager() and rc_private.can_access(r.depot_id);$p$,
   $p$where r.status='pending' /* 20261162130000 */ and rc_private.can_access(r.depot_id);$p$, 1),
  ('public.rc_depot_profile_review(uuid,boolean,text)', '076be78fbd6657cca2bf5b9d98f7b4fd',
   $p$  if not rc_private.is_manager() then$p$,
   $p$  if not rc_private.can_tab('access.req') /* 20261162130000 */ then$p$, 1),
  ('public.rc_depot_profile_review(uuid,boolean,text)', '076be78fbd6657cca2bf5b9d98f7b4fd',
   $p$'Hanya Supervisor atau System Manager yang dapat menyetujui'$p$,
   $p$'Anda belum diberi akses Approval Request'$p$, 1),

  -- ---- Access Management: pengguna ---------------------------------------------------------
  ('rc_private.can_manage_user(uuid)', 'a14f0235b743a2cc50b59fb319523095',
   $p$select p_target is not null and rc_private.is_manager() and ($p$,
   $p$select p_target is not null and rc_private.boleh_kelola_akses() /* 20261162130000 */ and ($p$, 1),
  ('rc_private.can_manage_user(uuid)', 'a14f0235b743a2cc50b59fb319523095',
   $p$exists(select 1 from public.profiles p where p.id=p_target and p.role<>'system manager' and p.status<>'deleted')$p$,
   $p$exists(select 1 from public.profiles p where p.id=p_target and p.role<>'system manager' and p.status<>'deleted'
     -- Bukan Supervisor: hanya akun yang perannya boleh ia berikan (pendaftaran: peran yang diminta).
     and (rc_private.is_manager() or rc_private.boleh_beri_peran(case when p.status='pending'
       then case p.requested_role when 'non-osc' then 'others' when 'system manager' then 'admin' else coalesce(nullif(p.requested_role,''),p.role) end
       else p.role end)))$p$, 1),
  ('public.rc_update_access(jsonb)', '12c238e3787b4ab156a8794a1638e197',
   $p$  if not rc_private.is_manager() then$p$,
   $p$  if not rc_private.boleh_kelola_akses() /* 20261162130000 */ then$p$, 1),
  ('public.rc_update_access(jsonb)', '12c238e3787b4ab156a8794a1638e197',
   $p$'Hanya System Manager atau Supervisor yang dapat mengubah akses'$p$,
   $p$'Anda belum diberi akses Access Management'$p$, 1),
  ('public.rc_update_access(jsonb)', '12c238e3787b4ab156a8794a1638e197',
   $p$  delete from public.user_permissions where user_id=v_target;$p$,
   $p$  -- Tanpa eskalasi: selain Supervisor/System Manager hanya dapat MEMBERIKAN izin modul yang ia
  -- pegang sendiri. Izin yang sudah dimiliki sasarannya boleh tetap atau dicabut.
  if not rc_private.is_manager() and exists(
       select 1 from unnest(v_perms) x
        where not rc_private.can_access(null, x)
          and not exists(select 1 from public.user_permissions up where up.user_id=v_target and up.permission_code=x)) then
    raise exception 'Anda hanya dapat memberikan izin modul yang Anda miliki sendiri' using errcode='42501'; end if;
  delete from public.user_permissions where user_id=v_target;$p$, 1),
  ('rc_private.set_role(uuid,text)', '88963c4d707fe92c8d33c1c6e30063e2',
   $p$  if not rc_private.can_manage_user(p_user) then$p$,
   $p$  if not rc_private.boleh_beri_peran(v_role) /* 20261162130000 */ then
    raise exception 'Peran "%" di atas kewenangan Anda', v_role using errcode='42501'; end if;
  if not rc_private.can_manage_user(p_user) then$p$, 1),
  ('rc_private.save_tab_access(uuid,jsonb)', '173de54f3e4982ae7b15e43c88c68885',
   $p$ if not rc_private.is_manager() or not rc_private.can_manage_user(p_user)$p$,
   $p$ if not rc_private.boleh_kelola_akses() /* 20261162130000 */ or not rc_private.can_manage_user(p_user)$p$, 1),
  ('rc_private.registration_plan(jsonb,uuid)', 'ea179fbd62e0cd72f76d468d4f925a17',
   $p$ if not rc_private.is_manager() then raise exception 'Supervisor atau System Manager diperlukan' using errcode='42501'; end if;$p$,
   $p$ if not rc_private.boleh_kelola_akses() /* 20261162130000 */ then raise exception 'Anda belum diberi akses Access Management' using errcode='42501'; end if;$p$, 1),
  ('rc_private.registration_plan(jsonb,uuid)', 'ea179fbd62e0cd72f76d468d4f925a17',
   $p$then raise exception 'Hanya System Manager dapat membuat System Manager' using errcode='42501'; end if;$p$,
   $p$then raise exception 'Hanya System Manager dapat membuat System Manager' using errcode='42501'; end if;
 if not rc_private.boleh_beri_peran(peran) then raise exception 'Peran % di atas kewenangan Anda',peran using errcode='42501'; end if;$p$, 1),
  ('rc_private.upload_registration_plan(jsonb,uuid)', '0091dd64026ef05cd71ff0ea562d70f6',
   $p$ if not rc_private.is_manager() then raise exception 'Supervisor atau System Manager diperlukan' using errcode='42501';end if;$p$,
   $p$ if not rc_private.boleh_kelola_akses() /* 20261162130000 */ then raise exception 'Anda belum diberi akses Access Management' using errcode='42501';end if;$p$, 1),
  ('rc_private.upload_registration_scope(jsonb,boolean)', '017d6d1f4b7c1d9e5bcbd134ec8455c0',
   $p$ select rc_private.is_manager()$p$,
   $p$ select rc_private.boleh_kelola_akses() /* 20261162130000 */ and rc_private.boleh_beri_peran(p->>'role')$p$, 1),
  ('rc_private.review_registration(uuid,boolean,text)', '9616d4a930f3b7fdfa809b884e059039',
   $p$ if not rc_private.is_manager() or not rc_private.can_manage_user(p_profile) then$p$,
   $p$ if not rc_private.boleh_kelola_akses() /* 20261162130000 */ or not rc_private.can_manage_user(p_profile) then$p$, 1),
  ('rc_private.review_uploaded_registration(uuid,boolean,text)', '9162915e9056a1c1f4acf846a9ff0c34',
   $p$ if not rc_private.is_manager() or not rc_private.can_manage_user(p_profile) then$p$,
   $p$ if not rc_private.boleh_kelola_akses() /* 20261162130000 */ or not rc_private.can_manage_user(p_profile) then$p$, 1),
  ('rc_private.review_profile(uuid,boolean)', 'd29bdbd4fe11c06c4ffe5e5a65d6125d',
   $p$ if not rc_private.is_manager() then raise exception 'Manager required' using errcode='42501'; end if;$p$,
   $p$ if not rc_private.boleh_kelola_akses() /* 20261162130000 */ then raise exception 'Anda belum diberi akses Access Management' using errcode='42501'; end if;$p$, 1),
  ('public.rc_review_pin(uuid,boolean,text)', '9f3480b492d0ad43e273c7206066be4e',
   $p$  if not rc_private.is_manager() then$p$,
   $p$  if not rc_private.can_tab('access.req') /* 20261162130000 */ then$p$, 1),
  ('public.rc_review_pin(uuid,boolean,text)', '9f3480b492d0ad43e273c7206066be4e',
   $p$'Hanya Supervisor atau System Manager yang dapat menyetujui'$p$,
   $p$'Anda belum diberi akses Approval Request'$p$, 1),
  ('rc_private.set_suffix(text,text)', 'a811f84d0725ce1fc469332be3dda769',
   $p$ if not rc_private.is_manager() then raise exception 'Hanya System Manager' using errcode='42501'; end if;$p$,
   $p$ if not rc_private.boleh_kelola_akses() /* 20261162130000 */ then raise exception 'Anda belum diberi akses Access Management' using errcode='42501'; end if;$p$, 1),
  ('public.rc_suffix_terpakai()', 'a18c7af2ee6bd689a36f035df4e978fc',
   $p$ if not rc_private.is_manager() then raise exception 'Hanya System Manager' using errcode='42501'; end if;$p$,
   $p$ if not rc_private.boleh_kelola_akses() /* 20261162130000 */ then raise exception 'Anda belum diberi akses Access Management' using errcode='42501'; end if;$p$, 1),
  ('rc_private.registration_options()', '0ad262e402778f15ed227654a66a39cc',
   $p$where x->>'code'<>'system manager' or rc_private.is_system_manager()),$p$,
   $p$where rc_private.boleh_beri_peran(x->>'code') /* 20261162130000 */),$p$, 1),
  ('public.rc_legacy_manageable()', '36afd7aafda595454930a350039303d2',
   $p$'canEdit',rc_private.is_manager(),$p$,
   $p$'canEdit',rc_private.boleh_kelola_akses() /* 20261162130000 */,$p$, 1),
  -- Per akun: boleh dikelola pemanggil atau hanya terlihat. Layar memakainya untuk tidak
  -- menyodorkan tombol simpan/hapus pada akun yang pasti ditolak server.
  ('rc_private.legacy_users()', '657afdd8fcc65e41aebb7a9ace2e28b0',
   $p$   'mustChangePin',p.must_change_password,$p$,
   $p$   'mustChangePin',p.must_change_password,
   'bolehKelola',rc_private.can_manage_user(p.id) /* 20261162130000 */,$p$, 1),

  -- ---- Access Management: Arsip Hapus akun --------------------------------------------------
  ('public.rc_account_delete(text,text,boolean)', '5fe6ffee7e947d71ebf400a32496ea1f',
   $p$  if not rc_private.is_system_manager() then$p$,
   $p$  if not rc_private.boleh_kelola_akses() /* 20261162130000 */ then$p$, 1),
  ('public.rc_account_delete(text,text,boolean)', '5fe6ffee7e947d71ebf400a32496ea1f',
   $p$'Hanya System Manager yang dapat menghapus akun'$p$,
   $p$'Anda belum diberi akses Access Management'$p$, 1),
  ('public.rc_account_delete(text,text,boolean)', '5fe6ffee7e947d71ebf400a32496ea1f',
   $p$  if v.id = aku then$p$,
   $p$  if v.id <> aku and not rc_private.can_manage_user(v.id) then
    raise exception 'Akun "%" di luar wilayah atau kewenangan Anda', v.user_code using errcode='42501'; end if;
  if v.id = aku then$p$, 1),
  ('public.rc_account_archive()', 'cad011ac229d568f5ec33d69397f36fe',
   $p$  if not rc_private.is_system_manager() then$p$,
   $p$  if not rc_private.can_tab('access.arsip') /* 20261162130000 */ then$p$, 1),
  ('public.rc_account_archive()', 'cad011ac229d568f5ec33d69397f36fe',
   $p$'Hanya System Manager yang dapat membuka Arsip Hapus'$p$,
   $p$'Anda belum diberi akses Arsip Hapus'$p$, 1),
  ('public.rc_account_archive()', 'cad011ac229d568f5ec33d69397f36fe',
   $p$    from public.profiles p where p.status = 'deleted') t;$p$,
   $p$    from public.profiles p where p.status = 'deleted' and rc_private.boleh_pulihkan_akun(p.id)) t;$p$, 1),
  ('public.rc_account_restore(uuid,text)', 'a9fa82e7aeb05df427362209a115d6b9',
   $p$  if not rc_private.is_system_manager() then$p$,
   $p$  if not rc_private.can_tab('access.arsip') /* 20261162130000 */ then$p$, 1),
  ('public.rc_account_restore(uuid,text)', 'a9fa82e7aeb05df427362209a115d6b9',
   $p$'Hanya System Manager yang dapat mengaktifkan kembali akun'$p$,
   $p$'Anda belum diberi akses Arsip Hapus'$p$, 1),
  ('public.rc_account_restore(uuid,text)', 'a9fa82e7aeb05df427362209a115d6b9',
   $p$  if v.status <> 'deleted' then raise exception 'Akun ini tidak ada di Arsip Hapus'; end if;$p$,
   $p$  if v.status <> 'deleted' then raise exception 'Akun ini tidak ada di Arsip Hapus'; end if;
  if not rc_private.boleh_pulihkan_akun(v.id) then
    raise exception 'Akun ini di luar wilayah atau kewenangan Anda' using errcode='42501'; end if;$p$, 1),

  -- ---- Access Management: Grade Depot (kini per depot dalam jangkauan) -----------------------
  ('public.rc_depot_grade_set(jsonb)', 'b65740c63d3b884816efc7e74b50131a',
   $p$  if not rc_private.is_system_manager() then$p$,
   $p$  if not rc_private.can_tab('access.grade') /* 20261162130000 */ then$p$, 1),
  ('public.rc_depot_grade_set(jsonb)', 'b65740c63d3b884816efc7e74b50131a',
   $p$'Hanya System Manager yang dapat menetapkan Grade Depot'$p$,
   $p$'Anda belum diberi akses Grade Depot'$p$, 1),
  ('public.rc_depot_grade_set(jsonb)', 'b65740c63d3b884816efc7e74b50131a',
   $p$    if v_depot is null then continue; end if;$p$,
   $p$    if v_depot is null then continue; end if;
    if not rc_private.can_access(v_depot) then
      raise exception 'Depot % di luar yurisdiksi Anda', upper(btrim(r->>'kode')) using errcode='42501'; end if;$p$, 1),
  ('public.rc_depot_grade_list()', 'c05c5d444d3cf279fb2581aa2a4a0141',
   $p$   where rc_private.is_system_manager();$p$,
   $p$   where rc_private.is_system_manager() or rc_private.can_access(d.id) /* 20261162130000 */;$p$, 1),

  -- ---- Access Management: Email Otomatis -----------------------------------------------------
  ('public.rc_email_susun(text,boolean,text)', '419e2bd046b5819ca9acf3eb208cd925',
   $p$  if not rc_private.is_manager() then$p$,
   $p$  if not rc_private.can_tab('access.email') /* 20261162130000 */ then$p$, 1),
  ('public.rc_email_susun(text,boolean,text)', '419e2bd046b5819ca9acf3eb208cd925',
   $p$'Hanya Supervisor atau System Manager yang dapat menyusun email'$p$,
   $p$'Anda belum diberi akses Email Otomatis'$p$, 1),
  ('public.rc_email_batalkan(uuid)', '973dff52f89883a6bc5da6c5b05421b3',
   $p$  if not rc_private.is_manager() then$p$,
   $p$  if not rc_private.can_tab('access.email') /* 20261162130000 */ then$p$, 1),
  ('public.rc_email_batalkan(uuid)', '973dff52f89883a6bc5da6c5b05421b3',
   $p$'Hanya Supervisor atau System Manager yang dapat membatalkan email'$p$,
   $p$'Anda belum diberi akses Email Otomatis'$p$, 1),
  ('public.rc_email_settings_simpan(jsonb)', '63d5d7bb9a26ec59d32156aa368aa5ca',
   $p$  if not rc_private.is_system_manager() then$p$,
   $p$  if not rc_private.can_tab('access.email') /* 20261162130000 */ then$p$, 1),
  ('public.rc_email_settings_simpan(jsonb)', '63d5d7bb9a26ec59d32156aa368aa5ca',
   $p$'Hanya System Manager yang dapat mengubah jadwal email'$p$,
   $p$'Anda belum diberi akses Email Otomatis'$p$, 1),
  ('public.rc_email_kirim_sekarang(text,text)', 'dbd8f40cee050abe0a2762238400ea89',
   $p$  if not rc_private.is_system_manager() then$p$,
   $p$  if not rc_private.can_tab('access.email') /* 20261162130000 */ then$p$, 1),
  ('public.rc_email_kirim_sekarang(text,text)', 'dbd8f40cee050abe0a2762238400ea89',
   $p$'Hanya System Manager yang dapat mengirim email'$p$,
   $p$'Anda belum diberi akses Email Otomatis'$p$, 1),
  ('public.rc_email_uji_koneksi()', '21a16b456fbe5ac9cff3d55042f1c867',
   $p$  if not rc_private.is_system_manager() then$p$,
   $p$  if not rc_private.can_tab('access.email') /* 20261162130000 */ then$p$, 1),
  ('public.rc_email_uji_koneksi()', '21a16b456fbe5ac9cff3d55042f1c867',
   $p$    raise exception 'Hanya System Manager' using errcode='42501'; end if;$p$,
   $p$    raise exception 'Anda belum diberi akses Email Otomatis' using errcode='42501'; end if;$p$, 1),

  -- ---- Access Management: Email Pengajuan ----------------------------------------------------
  ('public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text)', '52ad4e33c32b64f23ef8feb148917c0e',
   $p$          or lower(coalesce((select role from public.profiles where id=auth.uid()),'')) = 'supervisor') then$p$,
   $p$          or rc_private.can_tab('access.emailPengajuan') /* 20261162130000 */) then$p$, 1),
  ('public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text)', '52ad4e33c32b64f23ef8feb148917c0e',
   $p$'Hanya Supervisor dan System Manager yang dapat mengubah pengaturan ini'$p$,
   $p$'Anda belum diberi akses Email Pengajuan'$p$, 1),
  ('public.rc_email_pengajuan_uji(text)', '6cc4aa7b9f05b6da28dbd8e139ed41e5',
   $p$          or lower(coalesce((select role from public.profiles where id=auth.uid()),'')) = 'supervisor') then$p$,
   $p$          or rc_private.can_tab('access.emailPengajuan') /* 20261162130000 */) then$p$, 1),
  ('public.rc_email_pengajuan_uji(text)', '6cc4aa7b9f05b6da28dbd8e139ed41e5',
   $p$'Hanya Supervisor dan System Manager yang dapat mengirim email uji'$p$,
   $p$'Anda belum diberi akses Email Pengajuan'$p$, 1),
  ('public.rc_email_pengajuan_baca()', '5c6717b57542c8ec7d7e5a94d226ce06',
   $p$                 or lower(coalesce((select role from public.profiles where id=auth.uid()),'')) = 'supervisor',$p$,
   $p$                 or rc_private.can_tab('access.emailPengajuan') /* 20261162130000 */,$p$, 1);

  for f in select sig, min(harapan) harapan, count(distinct harapan) beda from _tambal group by sig order by min(urut) loop
    if f.beda <> 1 then raise exception 'Daftar tambalan %: MD5 harapan tidak seragam.', f.sig; end if;
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261162130000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(src, E'\r', '')); end if;

    baru := src;
    for r in select * from _tambal where sig = f.sig order by urut loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> r.n then
        raise exception '%: pola "%" ditemukan % kali, diharapkan %.', f.sig, left(r.lama, 80), n, r.n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
    if baru !~ '20261162130000' then raise exception '%: tambalan tidak memuat penanda.', f.sig; end if;
    execute baru;
  end loop;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- 4. Pemeriksaan di dalam subtransaksi yang dibatalkan: tidak ada data yang tertinggal.
-- ------------------------------------------------------------------------------------------
-- Sasaran uji dipilih dari data yang ada: seorang ADMIN aktif (A) dan admin lain (B) yang
-- seluruh depotnya terjangkau A. Hak A ditambah SEMENTARA di dalam subtransaksi.
do $uji$
declare
  v_a uuid; v_b uuid; v_sm uuid; v_spv uuid; v_dh uuid; v_klaim uuid; v_klaim_luar uuid;
  hasil jsonb := '{}'::jsonb; e text; v jsonb; perm text;
begin
  with akses as (select user_id, array_agg(depot_id order by depot_id) d from public.user_depot_access group by 1)
  select a.id, b.id into v_a, v_b
    from public.profiles a join akses xa on xa.user_id = a.id
    join public.profiles b on b.id <> a.id and b.role = 'admin' and b.status = 'active'
    join akses xb on xb.user_id = b.id and xa.d @> xb.d
   where a.role = 'admin' and a.status = 'active' and not a.must_change_password
   order by a.user_code, b.user_code limit 1;
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select id into v_spv from public.profiles where role = 'supervisor' and status = 'active' and not must_change_password order by user_code limit 1;
  if v_a is null or v_sm is null then raise notice 'Tidak ada pasangan admin untuk menguji; pemeriksaan dilewati.'; return; end if;

  begin
    -- Hak A ditambah: approval, arsip, compilation, timetable, access management.
    foreach perm in array array['approve_claim','archive_compilation','view_compilation','manage_timetable','manage_access','manage_key_master'] loop
      insert into public.user_permissions values (v_a, perm) on conflict do nothing;
    end loop;
    delete from rc_private.user_tab_access where user_id = v_a;
    -- B tidak memegang view_logs; A juga tidak. Itulah izin yang tidak boleh A berikan.
    delete from public.user_permissions where user_id in (v_a, v_b) and permission_code = 'view_logs';
    select c.id into v_klaim from public.claims c
     where c.depot_id in (select depot_id from public.user_depot_access where user_id = v_a)
       and c.archived_at is null and c.pending_approval is null order by c.no_doc limit 1;
    select c.id into v_klaim_luar from public.claims c
     where c.depot_id not in (select depot_id from public.user_depot_access where user_id = v_a)
       and c.archived_at is null order by c.no_doc limit 1;

    perform set_config('request.jwt.claims', json_build_object('sub', v_a::text, 'role', 'authenticated')::text, true);
    hasil := hasil || jsonb_build_object(
      'putusHold', rc_private.boleh_putus_hold(),
      'holdBolehPutus', (public.rc_approval_hold()->>'bolehPutus')::boolean,
      'overdue', rc_private.boleh_approve_overdue(),
      'bolehBatalkanNA', (public.rc_timetable_not_achieved()->>'bolehBatalkan')::boolean,
      'canEdit', (public.rc_legacy_manageable()->>'canEdit')::boolean,
      'kelolaB', rc_private.can_manage_user(v_b),
      'kelolaSpv', coalesce(rc_private.can_manage_user(v_spv), false),
      'beriAdmin', rc_private.boleh_beri_peran('admin'),
      'beriDH', rc_private.boleh_beri_peran('depot head'),
      'beriSpv', rc_private.boleh_beri_peran('supervisor'),
      'beriSM', rc_private.boleh_beri_peran('system manager'),
      'arsip', rc_private.boleh_arsip_compilation(),
      'perananPilihan', (select jsonb_agg(x->>'code' order by x->>'code') from jsonb_array_elements(rc_private.registration_options()->'roles') x));

    begin perform public.rc_archived_list(0, 10); hasil := hasil || '{"daftarArsip":"ok"}';
    exception when others then hasil := hasil || jsonb_build_object('daftarArsip', sqlerrm); end;

    if v_klaim is not null then
      v := rc_private.archive_claims(array[v_klaim], 'Uji migrasi 20261162130000');
      hasil := hasil || jsonb_build_object('arsipkan', v->>'jumlah');
      v := rc_private.unarchive_claims(array[v_klaim]);
      hasil := hasil || jsonb_build_object('pulihkan', v->>'jumlah');
    end if;
    if v_klaim_luar is not null then
      begin perform rc_private.archive_claims(array[v_klaim_luar], 'Uji'); hasil := hasil || '{"arsipLuar":"LOLOS"}';
      exception when others then hasil := hasil || jsonb_build_object('arsipLuar', sqlerrm); end;
    end if;

    -- Memberikan izin yang tidak dimiliki A: ditolak.
    begin
      perform public.rc_update_access(jsonb_build_object('userId', (select user_code from public.profiles where id = v_b),
        'auth', jsonb_build_object('logs', 'yes')));
      hasil := hasil || '{"beriIzinAsing":"LOLOS"}';
    exception when others then hasil := hasil || jsonb_build_object('beriIzinAsing', sqlerrm); end;
    -- Mengangkat B menjadi Supervisor: ditolak.
    begin
      perform public.rc_update_access(jsonb_build_object('userId', (select user_code from public.profiles where id = v_b), 'role', 'supervisor'));
      hasil := hasil || '{"angkatSpv":"LOLOS"}';
    exception when others then hasil := hasil || jsonb_build_object('angkatSpv', sqlerrm); end;
    -- Memberikan izin yang dimiliki A (Timetable): diterima.
    begin
      v := public.rc_update_access(jsonb_build_object('userId', (select user_code from public.profiles where id = v_b),
        'auth', jsonb_build_object('timetable', 'yes')));
      hasil := hasil || jsonb_build_object('beriIzinSendiri', v->>'status');
    exception when others then hasil := hasil || jsonb_build_object('beriIzinSendiri', sqlerrm); end;

    -- Tanpa approve_claim: tab On Hold tidak lagi dipegang, keputusan ditolak.
    perform set_config('request.jwt.claims', '', true);
    delete from public.user_permissions where user_id = v_a and permission_code = 'approve_claim';
    perform set_config('request.jwt.claims', json_build_object('sub', v_a::text, 'role', 'authenticated')::text, true);
    hasil := hasil || jsonb_build_object('putusHoldTanpaIzin', rc_private.boleh_putus_hold());

    -- Depot Head: Overdue dan On Hold bawaannya mati, menyala begitu dicentang.
    perform set_config('request.jwt.claims', '', true);
    select id into v_dh from public.profiles where role = 'depot head' and status = 'active' and not must_change_password order by user_code limit 1;
    if v_dh is not null then
      delete from rc_private.user_tab_access where user_id = v_dh and tab_code in ('approval.ovd','approval.hold','approval.wpt');
      perform set_config('request.jwt.claims', json_build_object('sub', v_dh::text, 'role', 'authenticated')::text, true);
      hasil := hasil || jsonb_build_object('dhBawaanOvd', rc_private.boleh_approve_overdue(),
        'dhBawaanHold', rc_private.boleh_putus_hold(), 'dhBawaanWpt', rc_private.can_tab('approval.wpt'));
      perform set_config('request.jwt.claims', '', true);
      insert into rc_private.user_tab_access values (v_dh, 'approval.ovd', true), (v_dh, 'approval.hold', true);
      perform set_config('request.jwt.claims', json_build_object('sub', v_dh::text, 'role', 'authenticated')::text, true);
      hasil := hasil || jsonb_build_object('dhDicentangOvd', rc_private.boleh_approve_overdue(), 'dhDicentangHold', rc_private.boleh_putus_hold());
    end if;

    -- System Manager dan Supervisor tidak kehilangan apa pun.
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    hasil := hasil || jsonb_build_object('smHold', rc_private.boleh_putus_hold(), 'smOvd', rc_private.boleh_approve_overdue(),
      'smArsip', rc_private.boleh_arsip_compilation(), 'smBeriSM', rc_private.boleh_beri_peran('system manager'),
      'smKelola', rc_private.boleh_kelola_akses());
    if v_spv is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_spv::text, 'role', 'authenticated')::text, true);
      hasil := hasil || jsonb_build_object('spvKelola', rc_private.boleh_kelola_akses(),
        'spvBeriSpv', rc_private.boleh_beri_peran('supervisor'), 'spvBeriSM', rc_private.boleh_beri_peran('system manager'));
    end if;
    raise exception 'UJI_SELESAI';
  exception when raise_exception then
    if sqlerrm <> 'UJI_SELESAI' then raise; end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  e := '';
  if not (hasil->>'putusHold')::boolean or not (hasil->>'holdBolehPutus')::boolean then e := e || ' admin ber-tab On Hold tetap tidak dapat memutuskan;'; end if;
  if not (hasil->>'overdue')::boolean then e := e || ' admin ber-tab Overdue ditolak;'; end if;
  if not (hasil->>'bolehBatalkanNA')::boolean then e := e || ' batal Not Achieved ditolak;'; end if;
  if not (hasil->>'canEdit')::boolean then e := e || ' Access Management tetap hanya-lihat;'; end if;
  if not (hasil->>'kelolaB')::boolean then e := e || ' admin tidak dapat mengelola rekan di depotnya;'; end if;
  if (hasil->>'kelolaSpv')::boolean then e := e || ' admin dapat mengelola Supervisor;'; end if;
  if not (hasil->>'beriAdmin')::boolean or (hasil->>'beriDH')::boolean or (hasil->>'beriSpv')::boolean or (hasil->>'beriSM')::boolean then
    e := e || ' peringkat peran tidak dijaga;'; end if;
  if hasil->'perananPilihan' <> '["admin", "finance", "others"]'::jsonb then e := e || ' pilihan peran ' || (hasil->>'perananPilihan') || ';'; end if;
  if not (hasil->>'arsip')::boolean or hasil->>'daftarArsip' <> 'ok' then e := e || ' arsip Compilation ditolak (' || coalesce(hasil->>'daftarArsip','') || ');'; end if;
  if hasil ? 'arsipkan' and (hasil->>'arsipkan' <> '1' or hasil->>'pulihkan' <> '1') then e := e || ' arsip/pulihkan tidak berjalan;'; end if;
  if hasil ? 'arsipLuar' and hasil->>'arsipLuar' !~ 'di luar akses' then e := e || ' arsip depot luar: ' || (hasil->>'arsipLuar') || ';'; end if;
  if hasil->>'beriIzinAsing' !~ 'izin modul yang Anda miliki' then e := e || ' izin asing: ' || (hasil->>'beriIzinAsing') || ';'; end if;
  if hasil->>'angkatSpv' !~ 'di atas kewenangan' then e := e || ' angkat Supervisor: ' || (hasil->>'angkatSpv') || ';'; end if;
  if hasil->>'beriIzinSendiri' <> 'success' then e := e || ' beri izin sendiri: ' || (hasil->>'beriIzinSendiri') || ';'; end if;
  if (hasil->>'putusHoldTanpaIzin')::boolean then e := e || ' tanpa approve_claim masih dapat memutuskan;'; end if;
  if hasil ? 'dhBawaanOvd' and ((hasil->>'dhBawaanOvd')::boolean or (hasil->>'dhBawaanHold')::boolean
     or not (hasil->>'dhBawaanWpt')::boolean or not (hasil->>'dhDicentangOvd')::boolean or not (hasil->>'dhDicentangHold')::boolean) then
    e := e || ' bawaan Depot Head salah;'; end if;
  if not ((hasil->>'smHold')::boolean and (hasil->>'smOvd')::boolean and (hasil->>'smArsip')::boolean
          and (hasil->>'smBeriSM')::boolean and (hasil->>'smKelola')::boolean) then e := e || ' System Manager kehilangan hak;'; end if;
  if hasil ? 'spvKelola' and (not (hasil->>'spvKelola')::boolean or not (hasil->>'spvBeriSpv')::boolean or (hasil->>'spvBeriSM')::boolean) then
    e := e || ' hak Supervisor berubah;'; end if;
  if e <> '' then raise exception 'GAGAL:% Hasil: %', e, hasil; end if;
  if v_a is not null and exists(select 1 from public.claims where id = v_klaim and archived_at is not null) then
    raise exception 'GAGAL: uji meninggalkan dokumen terarsip.'; end if;
  raise notice 'Akses mengikuti tab teruji, data dipulihkan: %', hasil;
end
$uji$;
