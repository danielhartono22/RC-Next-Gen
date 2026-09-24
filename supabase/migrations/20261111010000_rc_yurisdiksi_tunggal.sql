-- ==========================================================================================
-- Yurisdiksi tunggal: satu peran, satu sumber yurisdiksi - dan depot rumah bukan yurisdiksi
-- ==========================================================================================
-- Tiga keluhan pemilik, 20 September 2026, yang ternyata berakar pada satu rancangan yang sama:
--
--   "kok akun yang tidak saya tick tetapi tetep muncul di user?"
--   "jika ganti role maka ke reset semua yuridiksi dan tidak boleh ada 2 yuridiksi"
--   "untuk nama depot daniel, ganti ke depot Head Office"
--
-- ------------------------------------------------------------------------------------------
-- SEBAB 1 - DEPOT RUMAH DIAM-DIAM IKUT MENJADI YURISDIKSI
-- ------------------------------------------------------------------------------------------
-- rc_private.effective_depots menjumlahkan SELURUH baris user_depot_grants tanpa memandang
-- kind-nya:
--
--   select g.depot_id from public.user_depot_grants g where g.user_id=p_user
--
-- Padahal kind ada tiga: 'home', 'rp' dan 'assigned'. 'home' adalah depot tempat orangnya
-- bekerja - sebuah keterangan identitas, bukan pemberian wewenang. Karena ikut terjumlah,
-- depot rumah selalu masuk ke yurisdiksi meskipun tidak pernah dicentang.
--
-- Terbaca langsung pada data: ANIADMPTI dicentang 2 depot (kind='rp') tetapi yurisdiksi
-- efektifnya 3, dan AYI dicentang 3 tetapi efektifnya 4. Selisih satu itu persis depot rumahnya.
-- Itulah "akun yang tidak saya tick tetapi tetep muncul".
--
-- Ada jebakan kedua yang lebih halus pada rancangan lama. Kunci unik user_depot_grants adalah
-- (user_id, depot_id), jadi satu depot hanya boleh punya SATU kind. Penyimpanan depot rumah
-- memakai "on conflict do update set kind='home'" - sehingga menyetel depot rumah ke depot yang
-- juga dicentang sebagai rp akan MENGUBAH baris rp itu menjadi home, dan depotnya hilang dari
-- yurisdiksi tanpa ada yang menyentuh centangnya.
--
-- Keduanya hilang dengan satu perubahan rancangan: depot rumah dipindahkan ke kolomnya sendiri,
-- public.profiles.home_depot_id, dan tidak lagi menjadi baris grant sama sekali.
--
-- ------------------------------------------------------------------------------------------
-- SEBAB 2 - GANTI PERAN TIDAK MENGHAPUS YURISDIKSI PERAN LAMA
-- ------------------------------------------------------------------------------------------
-- rc_update_access hanya menyentuh kunci yang DIKIRIM layar, dan layar hanya mengirim yurisdiksi
-- yang relevan bagi peran barunya. Jadi ketika sebuah akun diubah dari osc menjadi admin, layar
-- mengirim rpDepots tetapi tidak mengirim assignedDepots - dan baris assigned dari masa osc-nya
-- tetap tinggal. Akun itu kini memegang DUA yurisdiksi sekaligus.
--
-- Setiap peran sekarang punya tepat satu sumber, dan sumber milik peran lain selalu dibersihkan
-- pada setiap penyimpanan - bukan hanya ketika perannya berubah:
--
--   system manager  seluruh depot lewat perannya     (tidak ada grant)
--   supervisor      seluruh depot lewat perannya     (tidak ada grant)
--   osc, others     user_depot_grants kind='assigned'
--   admin           user_depot_grants kind='rp'
--
-- Supervisor berubah di sini, dan perubahannya disengaja. Aturan pemilik berbunyi "user system
-- manager spv di blast bisa lihat semua", dan rc_private.is_manager() - yang dipakai Timetable -
-- memang sudah memasukkan supervisor. Tetapi effective_depots hanya mengistimewakan System
-- Manager, sehingga supervisor melihat seluruh depot di Timetable dan nyaris tidak melihat apa
-- pun di layar yang bersandar pada user_depot_access. IQBAL, satu-satunya supervisor aktif,
-- memegang 0 depot efektif. Keduanya kini sepakat.
--
-- user_supervision tetap ada sebagai daftar OSC binaan seorang supervisor - keterangan struktur
-- organisasi - tetapi tidak lagi menjadi sumber yurisdiksi.
--
-- Membersihkan setiap kali menyimpan lebih kuat daripada membersihkan saat peran berubah: ia
-- juga memulihkan akun yang terlanjur rusak sebelum migration ini, tanpa perlu ada yang ingat
-- untuk memperbaikinya.
--
-- ------------------------------------------------------------------------------------------
-- SEBAB 3 - DEPOT YANG DITAMPILKAN DIPILIH MENURUT ABJAD
-- ------------------------------------------------------------------------------------------
-- rc_legacy_bootstrap menentukan depot yang tampil di layar dengan:
--
--   select * into home from public.depots where id=any(depot_ids) order by depot_code limit 1;
--
-- yaitu kode terkecil di antara depot yang boleh dilihat. Untuk System Manager - yang melihat
-- seluruh 51 depot - itu selalu '1A', bukan tempat ia sebenarnya bekerja. Karena akun System
-- Manager pun kehilangan seluruh grant-nya (termasuk home) pada rancangan lama, tidak ada cara
-- menyimpan jawabannya.
--
-- Sekarang depot rumah dibaca dari profiles.home_depot_id lebih dulu, dan urutan abjad hanya
-- dipakai bila kolom itu kosong. Akun DANIEL disetel ke HO - Head Office di bagian 5.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Depot rumah pindah ke kolomnya sendiri
-- ------------------------------------------------------------------------------------------
alter table public.profiles add column if not exists home_depot_id uuid references public.depots(id);

-- Nilai yang sudah ada dipindahkan, lalu baris grant-nya dilepas supaya tidak ada dua sumber
-- kebenaran untuk hal yang sama.
update public.profiles p
   set home_depot_id = g.depot_id
  from public.user_depot_grants g
 where g.user_id = p.id and g.kind = 'home' and p.home_depot_id is null;

delete from public.user_depot_grants where kind = 'home';

-- ------------------------------------------------------------------------------------------
-- 2. effective_depots tidak lagi mengenal kind 'home'
-- ------------------------------------------------------------------------------------------
-- Ditulis ulang utuh, bukan ditambal, karena badannya pendek dan seluruhnya tercetak di sini -
-- tidak ada yang tersembunyi yang dapat menyimpang.
create or replace function rc_private.effective_depots(p_user uuid)
returns setof uuid language sql stable security definer set search_path='' as $fn$
  -- System Manager DAN Supervisor memperoleh seluruh depot lewat perannya, sesuai aturan
  -- pemilik: "user system manager spv di blast bisa lihat semua". Sebelumnya hanya System
  -- Manager yang begitu di sini, sementara rc_private.is_manager() - yang dipakai Timetable -
  -- sudah sejak lama memasukkan supervisor juga. Akibatnya seorang supervisor melihat seluruh
  -- depot di Timetable tetapi nyaris tidak melihat apa pun di layar yang bersandar pada
  -- user_depot_access. Keduanya kini sepakat.
  select d.id from public.depots d
   where (select role from public.profiles where id = p_user) in ('system manager','supervisor')
  union
  -- Hanya kind yang memang memberi wewenang. 'home' sudah tidak ada sejak migration ini,
  -- tetapi disebut tegas supaya baris sisa dari mana pun tidak diam-diam ikut terhitung.
  select g.depot_id from public.user_depot_grants g
   where g.user_id = p_user and g.kind in ('rp','assigned');
$fn$;
revoke all on function rc_private.effective_depots(uuid) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 3. rc_update_access: satu yurisdiksi per peran, dibersihkan setiap kali menyimpan
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rc_update_access';
  if src is null then raise exception 'public.rc_update_access tidak ditemukan.'; end if;

  if position('home_depot_id' in src) > 0 then
    raise notice 'rc_update_access sudah diperbarui; dilewati.';
    return;
  end if;

  baru := src;

  -- 3a. Pembersihan menurut peran menggantikan cabang "kalau system manager hapus semua".
  baru := replace(baru,
    '  if v_role=''system manager'' then' || chr(10)
      || '    delete from public.user_depot_grants where user_id=v_target;' || chr(10)
      || '    delete from public.user_supervision where supervisor_id=v_target;' || chr(10)
      || '  else' || chr(10)
      || '    if p_payload ? ''homeDepot'' then',
    '  -- Yurisdiksi milik peran LAIN selalu dilepas, pada setiap penyimpanan. Inilah yang' || chr(10)
      || '  -- memastikan sebuah akun tidak pernah memegang dua yurisdiksi sekaligus, termasuk' || chr(10)
      || '  -- ketika perannya baru saja berubah dan layar hanya mengirim yurisdiksi yang baru.' || chr(10)
      || '  if v_role <> ''supervisor'' then' || chr(10)
      || '    delete from public.user_supervision where supervisor_id=v_target;' || chr(10)
      || '  end if;' || chr(10)
      || '  if v_role <> ''admin'' then' || chr(10)
      || '    delete from public.user_depot_grants where user_id=v_target and kind=''rp'';' || chr(10)
      || '  end if;' || chr(10)
      || '  if v_role not in (''osc'',''others'') then' || chr(10)
      || '    delete from public.user_depot_grants where user_id=v_target and kind=''assigned'';' || chr(10)
      || '  end if;' || chr(10)
      || '  -- System Manager dan Supervisor memperoleh depot lewat perannya, jadi grant apa pun' || chr(10)
      || '  -- pada keduanya hanya menjadi sumber kebenaran kedua yang akan menyimpang.' || chr(10)
      || '  if v_role in (''system manager'',''supervisor'') then' || chr(10)
      || '    delete from public.user_depot_grants where user_id=v_target;' || chr(10)
      || '  end if;' || chr(10)
      || '' || chr(10)
      || '  begin' || chr(10)
      || '    if p_payload ? ''homeDepot'' then');

  -- 3b. Depot rumah ditulis ke kolom profil, bukan sebagai grant.
  baru := replace(baru,
    '      delete from public.user_depot_grants where user_id=v_target and kind=''home'';' || chr(10)
      || '      if coalesce(btrim(p_payload->>''homeDepot''),'''')<>'''' then' || chr(10)
      || '        v_depot:=public.rc_legacy_depot_id(btrim(p_payload->>''homeDepot''));' || chr(10)
      || '        insert into public.user_depot_grants(user_id,depot_id,kind,granted_by)' || chr(10)
      || '        values(v_target,v_depot,''home'',(select auth.uid()))' || chr(10)
      || '        on conflict(user_id,depot_id) do update set kind=''home'';' || chr(10)
      || '      end if;',
    '      -- Depot rumah adalah keterangan identitas, bukan pemberian wewenang, sehingga ia' || chr(10)
      || '      -- tidak lagi menjadi baris grant dan tidak ikut menentukan yurisdiksi.' || chr(10)
      || '      if coalesce(btrim(p_payload->>''homeDepot''),'''')='''' then' || chr(10)
      || '        update public.profiles set home_depot_id=null where id=v_target;' || chr(10)
      || '      else' || chr(10)
      || '        update public.profiles' || chr(10)
      || '           set home_depot_id=public.rc_legacy_depot_id(btrim(p_payload->>''homeDepot''))' || chr(10)
      || '         where id=v_target;' || chr(10)
      || '      end if;');

  -- 3c. Blok penerapan payload tidak lagi berada di dalam cabang "else", jadi satu end if
  --     ditukar menjadi penutup blok begin.
  baru := replace(baru,
    '    end if;' || chr(10) || '  end if;' || chr(10) || chr(10)
      || '  if v_role=''system manager'' then' || chr(10)
      || '    v_perms:=array(select code from public.permissions);',
    '    end if;' || chr(10) || '  end;' || chr(10) || chr(10)
      || '  if v_role=''system manager'' then' || chr(10)
      || '    v_perms:=array(select code from public.permissions);');

  if baru = src then
    raise exception 'Tidak satu pun pola ditemukan pada public.rc_update_access. '
      'Sumbernya sudah berubah - periksa dan perbarui migration ini.';
  end if;
  if position('kind=''home''' in baru) > 0 then
    raise exception 'rc_update_access masih menulis grant kind=home sesudah penggantian.';
  end if;

  execute baru;
  raise notice 'rc_update_access: yurisdiksi tunggal per peran, depot rumah ke kolom profil.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 4. Bootstrap membaca depot rumah dari profil
-- ------------------------------------------------------------------------------------------
do $boot$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rc_legacy_bootstrap';
  if src is null then raise exception 'public.rc_legacy_bootstrap tidak ditemukan.'; end if;

  if position('me.home_depot_id' in src) > 0 then
    raise notice 'rc_legacy_bootstrap sudah membaca home_depot_id; dilewati.';
    return;
  end if;

  baru := replace(src,
    ' select * into home from public.depots where id=any(depot_ids) order by depot_code limit 1;',
    ' -- Depot rumah yang ditetapkan di Access Management menang. Urutan abjad hanya cadangan,' || chr(10)
      || ' -- dan bagi System Manager - yang melihat seluruh depot - cadangan itu selalu ''1A'',' || chr(10)
      || ' -- yaitu depot yang tidak ada hubungannya dengan tempat ia bekerja.' || chr(10)
      || ' select * into home from public.depots where id=me.home_depot_id;' || chr(10)
      || ' if not found then' || chr(10)
      || '  select * into home from public.depots where id=any(depot_ids) order by depot_code limit 1;' || chr(10)
      || ' end if;');

  if baru = src then
    raise exception 'Pola pemilihan depot rumah tidak ditemukan pada rc_legacy_bootstrap.';
  end if;
  execute baru;
  raise notice 'rc_legacy_bootstrap: depot rumah dibaca dari profil.';
end
$boot$;

-- ------------------------------------------------------------------------------------------
-- 5. Menyelaraskan data yang sudah ada
-- ------------------------------------------------------------------------------------------
do $sinkron$
declare r record; n_bersih int := 0; n_rebuild int := 0; v_ho uuid;
begin
  -- 5a. Yurisdiksi yang bukan milik perannya dilepas.
  delete from public.user_supervision s
   using public.profiles p
   where p.id = s.supervisor_id and p.role <> 'supervisor';
  get diagnostics n_bersih = row_count;
  raise notice 'Supervisi yang bukan milik supervisor dilepas: % baris', n_bersih;

  delete from public.user_depot_grants g
   using public.profiles p
   where p.id = g.user_id and g.kind = 'rp' and p.role <> 'admin';
  get diagnostics n_bersih = row_count;
  raise notice 'Grant rp pada akun non-admin dilepas: % baris', n_bersih;

  delete from public.user_depot_grants g
   using public.profiles p
   where p.id = g.user_id and g.kind = 'assigned' and p.role not in ('osc','others');
  get diagnostics n_bersih = row_count;
  raise notice 'Grant assigned pada akun di luar osc/others dilepas: % baris', n_bersih;

  delete from public.user_depot_grants g
   using public.profiles p
   where p.id = g.user_id and p.role in ('system manager','supervisor');
  get diagnostics n_bersih = row_count;
  raise notice 'Grant pada System Manager/Supervisor dilepas: % baris', n_bersih;

  -- 5b. Depot rumah akun DANIEL ditetapkan ke HO - Head Office, atas permintaan pemilik.
  select id into v_ho from public.depots where upper(depot_code) = 'HO';
  if v_ho is null then
    raise notice 'Depot HO tidak ditemukan; depot rumah DANIEL dilewati.';
  else
    update public.profiles set home_depot_id = v_ho where user_code = 'DANIEL';
    raise notice 'Depot rumah DANIEL disetel ke HO - Head Office.';
  end if;

  -- 5c. Daftar efektif dibangun ulang untuk semua akun, supaya user_depot_access benar-benar
  --     mencerminkan aturan yang baru dan bukan sisa perhitungan lama.
  for r in select id from public.profiles where status <> 'deleted' loop
    perform rc_private.rebuild_depot_access(r.id);
    n_rebuild := n_rebuild + 1;
  end loop;
  raise notice 'Daftar depot efektif dibangun ulang untuk % akun.', n_rebuild;
end
$sinkron$;

-- ------------------------------------------------------------------------------------------
-- 6. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare n int; r record;
begin
  if not exists(select 1 from information_schema.columns
                 where table_schema='public' and table_name='profiles' and column_name='home_depot_id') then
    raise exception 'GAGAL: kolom profiles.home_depot_id tidak ada.';
  end if;

  select count(*) into n from public.user_depot_grants where kind = 'home';
  if n > 0 then raise exception 'GAGAL: masih ada % grant kind=home.', n; end if;

  -- Tidak boleh ada akun yang memegang dua sumber yurisdiksi sekaligus.
  for r in
    select p.user_code, p.role,
           (select count(*) from public.user_depot_grants g where g.user_id=p.id and g.kind='rp') n_rp,
           (select count(*) from public.user_depot_grants g where g.user_id=p.id and g.kind='assigned') n_as,
           (select count(*) from public.user_supervision s where s.supervisor_id=p.id) n_sv
      from public.profiles p where p.status <> 'deleted'
  loop
    if (case when r.n_rp > 0 then 1 else 0 end
      + case when r.n_as > 0 then 1 else 0 end
      + case when r.n_sv > 0 then 1 else 0 end) > 1 then
      raise exception 'GAGAL: akun % (%) memegang lebih dari satu yurisdiksi.', r.user_code, r.role;
    end if;
    if r.role in ('system manager','supervisor') and (r.n_rp + r.n_as) > 0 then
      raise exception 'GAGAL: % (%) masih memegang grant depot padahal memperoleh lewat peran.',
        r.user_code, r.role;
    end if;
  end loop;

  -- Daftar efektif harus sama dengan hitungan effective_depots, tanpa selisih.
  select count(*) into n from public.profiles p
   where p.status <> 'deleted'
     and (select count(*) from public.user_depot_access a where a.user_id = p.id)
       <> (select count(*) from rc_private.effective_depots(p.id));
  if n > 0 then
    raise exception 'GAGAL: % akun daftar efektifnya tidak sinkron.', n;
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
