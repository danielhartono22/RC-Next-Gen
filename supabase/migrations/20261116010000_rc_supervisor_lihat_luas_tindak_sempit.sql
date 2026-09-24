-- ==========================================================================================
-- Supervisor: melihat luas, bertindak sempit
-- ==========================================================================================
-- Pemilik menetapkan, 20 September 2026:
--
--   "tidak boleh supervisor hanya membina osc di bawahnya tapi untuk report dan timetable
--    supervisor bisa lihat semua tetapi untuk action hanya bisa sesuai osc oleh karena itu
--    depot yang hanya lihat ketika action button nya di freeze"
--
-- Tiga hal sekaligus, dan ketiganya berbeda satu sama lain:
--
--   1. Binaan seorang supervisor HANYA boleh akun berperan 'osc'. Bukan admin, bukan others.
--   2. Untuk MELIHAT - Report dan Timetable - supervisor melihat seluruh depot.
--   3. Untuk BERTINDAK - supervisor hanya boleh menyentuh depot milik OSC binaannya.
--
-- Dengan kata lain, seorang supervisor punya DUA jangkauan yang berbeda, dan selama ini sistem
-- hanya mengenal satu. Migration ini memisahkan keduanya.
--
-- ------------------------------------------------------------------------------------------
-- MENGAPA MELEBARKAN BACAAN TIDAK MELONGGARKAN TINDAKAN
-- ------------------------------------------------------------------------------------------
-- Ini yang membuat pemisahan itu aman, dan pantas ditulis supaya tidak perlu ditebak lagi nanti.
-- SELURUH kebijakan RLS pada proyek ini hanya berlaku untuk SELECT - tidak ada satu pun
-- kebijakan untuk INSERT, UPDATE maupun DELETE pada tabel berdepot. Karena RLS aktif, perintah
-- tulis langsung dari pengguna justru DITOLAK seluruhnya secara bawaan.
--
-- Setiap perubahan data melewati fungsi SECURITY DEFINER yang memeriksa wewenangnya sendiri,
-- baris demi baris, dengan rc_private.can_access(depot_id) - bukan dengan RLS:
--
--   rc_private.mutate_claims_unchecked   submit, release, claim, clearing, hold, expire
--   rc_posting_exception                 On Hold dan Expired
--   rc_reprocessing_upload               kembali ke Not Yet
--   rc_timetable_mark                    tandai dan batalkan Not Achieved
--
-- Jadi melebarkan RLS SELECT menambah apa yang TERLIHAT, dan tidak menambah sebutir pun apa yang
-- DAPAT DIUBAH. Tindakan tetap dijaga di tempatnya semula.
--
-- ------------------------------------------------------------------------------------------
-- YANG TETAP SEMPIT MESKI BACAAN DILEBARKAN
-- ------------------------------------------------------------------------------------------
-- rc_private.claim_sensitive - KTP, NPWP, nomor rekening, nama rekening - memakai can_access()
-- SENDIRI di dalam kebijakannya, bukan menumpang kebijakan claims:
--
--   exists(select 1 from claims c where c.id = claim_sensitive.claim_id
--            and rc_private.can_access(c.depot_id))
--
-- Karena itu ia TIDAK ikut melebar. Supervisor melihat angka dan status seluruh depot, tetapi
-- data pribadi pelanggan tetap hanya pada depot yang benar-benar menjadi tanggung jawabnya.
-- Itu perilaku yang benar dan sengaja dipertahankan.
--
-- ------------------------------------------------------------------------------------------
-- LUBANG YANG IKUT DITUTUP
-- ------------------------------------------------------------------------------------------
-- Uji rantai pada 20 September memperlihatkan: ketika sebuah akun OSC dikembalikan menjadi
-- admin, supervisor yang membinanya TETAP mewarisi depot akun itu. Sebabnya effective_depots
-- mewarisi dari akun binaan tanpa memeriksa apakah ia masih OSC.
--
-- Sekarang pewarisan menuntut binaannya berperan 'osc' persis. Begitu akun itu berganti peran,
-- warisannya lepas dengan sendirinya pada pembangunan ulang berikutnya.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Jangkauan MELIHAT, terpisah dari jangkauan BERTINDAK
-- ------------------------------------------------------------------------------------------
-- can_access() tetap menjadi jangkauan bertindak dan tidak disentuh sama sekali.
create or replace function rc_private.can_view(p_depot uuid)
returns boolean language sql stable security definer set search_path='' as $fn$
  -- is_manager() sudah memeriksa status aktif dan kewajiban ganti PIN, jadi akun nonaktif
  -- tidak memperoleh keluasan ini.
  select rc_private.is_manager() or rc_private.can_access(p_depot);
$fn$;
revoke all on function rc_private.can_view(uuid) from public,anon;
grant execute on function rc_private.can_view(uuid) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Kebijakan baca dilebarkan - keduanya SELECT saja
-- ------------------------------------------------------------------------------------------
alter policy claims_scope on public.claims
  using (archived_at is null and rc_private.can_view(depot_id));

alter policy depots_scoped on public.depots
  using (rc_private.can_view(id));

-- ------------------------------------------------------------------------------------------
-- 3. Pewarisan supervisor hanya dari akun berperan 'osc'
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.effective_depots(p_user uuid)
returns setof uuid language sql stable security definer set search_path='' as $fn$
  -- Hanya System Manager yang memperoleh seluruh depot sebagai jangkauan BERTINDAK.
  select d.id from public.depots d
   where (select role from public.profiles where id = p_user) = 'system manager'
  union
  -- Depot yang ditempelkan langsung: 'rp' untuk admin, 'assigned' untuk osc dan others.
  select g.depot_id from public.user_depot_grants g
   where g.user_id = p_user and g.kind in ('rp','assigned')
  union
  -- Supervisor mewarisi depot OSC binaannya. Binaannya harus BENAR-BENAR berperan 'osc':
  -- tanpa syarat ini, sebuah akun yang dikembalikan menjadi admin tetap mewariskan depotnya
  -- kepada supervisor yang dulu membinanya.
  select g.depot_id
    from public.user_supervision s
    join public.profiles o on o.id = s.osc_id and o.role = 'osc' and o.status = 'active'
    join public.user_depot_grants g on g.user_id = s.osc_id and g.kind in ('rp','assigned')
   where s.supervisor_id = p_user;
$fn$;
revoke all on function rc_private.effective_depots(uuid) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 4. Penetapan binaan menolak akun yang bukan OSC
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rc_update_access';
  if src is null then raise exception 'public.rc_update_access tidak ditemukan.'; end if;

  if position('and p2.role = ''osc''' in src) > 0 then
    raise notice 'rc_update_access sudah menuntut peran osc; dilewati.';
    return;
  end if;

  baru := replace(src,
    '          select v_target,id from public.profiles where user_code=upper(btrim(c)) and id<>v_target',
    '          select v_target,p2.id from public.profiles p2' || chr(10)
      || '           where p2.user_code=upper(btrim(c)) and p2.id<>v_target and p2.role = ''osc''');

  baru := replace(baru,
    '              raise exception ''Akun OSC % tidak ditemukan. Periksa User ID-nya, atau buat akunnya lebih dulu - yurisdiksi supervisor mengalir lewat OSC.'', btrim(c);',
    '              raise exception ''Akun % tidak dapat dibina: ia harus ada dan berperan OSC. Supervisor hanya membina OSC di bawahnya.'', btrim(c);');

  if baru = src then
    raise exception 'Pola penetapan binaan tidak ditemukan pada rc_update_access. '
      'Sumbernya sudah berubah - periksa dan perbarui migration ini.';
  end if;

  execute baru;
  raise notice 'rc_update_access: binaan wajib berperan OSC.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 5. Menyelaraskan daftar efektif
-- ------------------------------------------------------------------------------------------
do $sinkron$
declare r record; n int := 0;
begin
  for r in select id from public.profiles where status <> 'deleted' loop
    perform rc_private.rebuild_depot_access(r.id);
    n := n + 1;
  end loop;
  raise notice 'Daftar depot efektif dibangun ulang untuk % akun.', n;
end
$sinkron$;

-- ------------------------------------------------------------------------------------------
-- 6. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare n int; src text;
begin
  -- Bacaan melebar
  select count(*) into n from pg_policy
   where polname in ('claims_scope','depots_scoped')
     and pg_get_expr(polqual, polrelid) like '%can_view%';
  if n <> 2 then raise exception 'GAGAL: hanya % dari 2 kebijakan baca yang memakai can_view.', n; end if;

  -- Tindakan TIDAK melebar: tidak boleh ada kebijakan tulis pada tabel berdepot
  select count(*) into n from pg_policy p join pg_class c on c.oid = p.polrelid
   where c.relname in ('claims','depots') and p.polcmd <> 'r';
  if n > 0 then
    raise exception 'GAGAL: ada % kebijakan non-SELECT pada claims/depots; tindakan bisa ikut melebar.', n;
  end if;

  -- Data pribadi tetap sempit
  select pg_get_expr(polqual, polrelid) into src from pg_policy where polname = 'claim_sensitive_scoped';
  if src not like '%can_access%' or src like '%can_view%' then
    raise exception 'GAGAL: claim_sensitive tidak lagi memakai jangkauan bertindak.';
  end if;

  -- Pewarisan menuntut peran osc
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'rc_private' and p.proname = 'effective_depots';
  if src not like '%o.role = ''osc''%' then
    raise exception 'GAGAL: effective_depots belum menuntut binaan berperan osc.';
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
