-- ==========================================================================================
-- Koreksi: yurisdiksi supervisor mengalir lewat OSC, bukan langsung ke depot
-- ==========================================================================================
-- Pemilik meluruskan, 20 September 2026:
--
--   "untuk supervisor yuridiksinya ke osc tidak bisa ke depot langsyng oleh karena itu ketika
--    ada perindahan role maka depot nya akan ke reset 0 dan langsung authorize ke osc."
--
-- Migration sebelumnya (20261111010000) keliru pada satu titik: supervisor disamakan dengan
-- System Manager, yaitu memperoleh SELURUH depot lewat perannya. Dasarnya adalah kalimat pemilik
-- terdahulu "system manager spv di blast bisa lihat semua", dan kenyataan bahwa
-- rc_private.is_manager() memang memasukkan supervisor.
--
-- Penafsiran itu salah. Keduanya berdamai begini: seorang supervisor memang melihat luas, TETAPI
-- keluasan itu datang dari OSC yang ia bina - bukan dari daftar depot yang ditempelkan langsung
-- kepadanya. Jadi jangkauannya tetap seluas binaannya, dan bertambah atau menyusut mengikuti
-- binaan itu, bukan mengikuti centang depot.
--
-- Yang dikoreksi di sini HANYA rc_private.effective_depots. Dua hal lain dari migration kemarin
-- justru sudah sesuai dengan maksud pemilik dan sengaja dibiarkan:
--
--   * Supervisor tidak boleh memegang grant depot langsung, dan rc_update_access sudah melepas
--     seluruh grant depot pada peran system manager maupun supervisor setiap kali menyimpan.
--     Itulah "depotnya akan ke reset 0".
--   * user_supervision hanya dipertahankan untuk peran supervisor, dan dilepas begitu perannya
--     berpindah. Itulah "langsung authorize ke osc".
--
-- AKIBAT YANG HARUS DIKETAHUI
-- IQBAL adalah satu-satunya supervisor aktif dan saat ini tidak membina satu pun OSC, sehingga
-- jangkauannya menjadi NOL depot. Itu benar menurut aturan ini, bukan kegagalan: seorang
-- supervisor tanpa binaan memang belum punya wilayah. Yang perlu dilakukan adalah menetapkan OSC
-- binaannya di Access Management.
--
-- SATU KETIDAKCOCOKAN YANG SENGAJA TIDAK DISENTUH
-- rc_timetable_matrix menyaring depot dengan "rc_private.is_manager() or can_access(d.id)", dan
-- is_manager() bernilai benar untuk supervisor. Jadi di layar Timetable seorang supervisor tetap
-- melihat seluruh depot, termasuk yang berada di luar binaannya. Itu bertentangan dengan aturan
-- di migration ini, tetapi memperbaikinya berarti mengubah perilaku sebuah layar yang tidak
-- diminta - jadi ia dilaporkan kepada pemilik, bukan diubah diam-diam.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.effective_depots(p_user uuid)
returns setof uuid language sql stable security definer set search_path='' as $fn$
  -- Hanya System Manager yang memperoleh seluruh depot lewat perannya.
  select d.id from public.depots d
   where (select role from public.profiles where id = p_user) = 'system manager'
  union
  -- Depot yang ditempelkan langsung: 'rp' untuk admin, 'assigned' untuk osc dan others.
  -- Jenis 'home' sudah tidak ada sejak 20261111010000 - depot rumah adalah keterangan
  -- identitas, bukan pemberian wewenang - tetapi disebut tegas supaya baris sisa dari mana pun
  -- tidak diam-diam ikut terhitung.
  select g.depot_id from public.user_depot_grants g
   where g.user_id = p_user and g.kind in ('rp','assigned')
  union
  -- Supervisor: jangkauannya adalah gabungan depot milik OSC yang ia bina. Tidak ada jalan lain
  -- menuju depot bagi peran ini, dan itu memang disengaja.
  select g.depot_id
    from public.user_supervision s
    join public.user_depot_grants g on g.user_id = s.osc_id and g.kind in ('rp','assigned')
   where s.supervisor_id = p_user;
$fn$;
revoke all on function rc_private.effective_depots(uuid) from public,anon;

-- ------------------------------------------------------------------------------------------
-- Menyelaraskan kembali daftar efektif seluruh akun
-- ------------------------------------------------------------------------------------------
do $sinkron$
declare r record; n int := 0;
begin
  -- Supervisor tidak boleh memegang grant depot langsung. Pemeriksaan ini menangkap baris yang
  -- mungkin tersisa dari sebelum aturannya berlaku.
  delete from public.user_depot_grants g
   using public.profiles p
   where p.id = g.user_id and p.role = 'supervisor';
  get diagnostics n = row_count;
  raise notice 'Grant depot langsung pada supervisor dilepas: % baris', n;

  n := 0;
  for r in select id from public.profiles where status <> 'deleted' loop
    perform rc_private.rebuild_depot_access(r.id);
    n := n + 1;
  end loop;
  raise notice 'Daftar depot efektif dibangun ulang untuk % akun.', n;
end
$sinkron$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare n int; r record;
begin
  -- Supervisor tidak boleh memperoleh depot lewat perannya sendiri.
  if exists(select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
             where ns.nspname='rc_private' and p.proname='effective_depots'
               and pg_get_functiondef(p.oid) like '%''system manager'',''supervisor''%') then
    raise exception 'GAGAL: effective_depots masih menyamakan supervisor dengan System Manager.';
  end if;

  -- Tidak boleh ada supervisor yang memegang grant depot langsung.
  select count(*) into n from public.user_depot_grants g
    join public.profiles p on p.id = g.user_id where p.role = 'supervisor';
  if n > 0 then raise exception 'GAGAL: % grant depot masih menempel pada supervisor.', n; end if;

  -- Daftar efektif harus sama persis dengan hitungan effective_depots.
  select count(*) into n from public.profiles p
   where p.status <> 'deleted'
     and (select count(*) from public.user_depot_access a where a.user_id = p.id)
       <> (select count(*) from rc_private.effective_depots(p.id));
  if n > 0 then raise exception 'GAGAL: % akun daftar efektifnya tidak sinkron.', n; end if;

  for r in
    select p.user_code, p.role,
           (select count(*) from public.user_supervision s where s.supervisor_id = p.id) n_osc,
           (select count(*) from public.user_depot_access a where a.user_id = p.id) n_depot
      from public.profiles p where p.status <> 'deleted' order by p.user_code
  loop
    raise notice '  % (%): OSC binaan=%  depot efektif=%', r.user_code, r.role, r.n_osc, r.n_depot;
  end loop;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
