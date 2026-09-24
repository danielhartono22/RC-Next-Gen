-- ==========================================================================================
-- Keputusan On Hold / Expired terbuka untuk OSC dan Supervisor sesuai yurisdiksinya
-- ==========================================================================================
-- Keputusan pemilik: "osc spv sesuai yuridiksi untuk semua tab dan system manager".
--
-- Tab WPT dan Overdue memang sudah demikian sejak semula - jangkauannya ditentukan
-- rc_private.can_access, jadi OSC menyetujui depot yang ditempelkan padanya dan Supervisor
-- menyetujui lewat OSC binaannya. Yang masih tertutup hanyalah tab On Hold & Expired, yang
-- dibatasi Management dan System Manager ketika dibuat.
--
-- Batasan itu dilonggarkan di sini, TANPA menyentuh jangkauan: siapa pun yang boleh memutuskan
-- tetap hanya dapat memutuskan dokumen di dalam depot yang terjangkau olehnya, karena setiap
-- baris tetap melewati can_access(depot,'approve_claim').
--
-- Depot Head TIDAK ikut. Pemilik menetapkannya menangani Within Payment Term saja; menahan dan
-- menghanguskan dokumen adalah keputusan yang lebih berat daripada menyetujui tempo pembayaran
-- yang masih di dalam kesepakatan.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.boleh_putus_hold()
returns boolean language sql stable security definer set search_path='' as $fn$
  select exists(
    select 1 from public.profiles p
     where p.id = (select auth.uid()) and p.status = 'active'
       and not p.must_change_password
       -- Jangkauannya tetap dijaga can_access pada setiap baris; daftar ini hanya menentukan
       -- peran mana yang berwenang memutuskan sama sekali.
       and p.role in ('osc','supervisor','management','system manager'));
$fn$;
revoke all on function rc_private.boleh_putus_hold() from public, anon;
grant execute on function rc_private.boleh_putus_hold() to authenticated;

-- ------------------------------------------------------------------------------------------
-- Mesin status ikut menjaganya, bukan hanya layar
-- ------------------------------------------------------------------------------------------
-- Sebelumnya batasan peran hanya hidup di layar dan di rc_approval_hold. Tombol yang beku bukan
-- penjagaan: siapa pun yang memanggil RPC-nya langsung akan menembusnya. Penjagaannya
-- ditambahkan pada mesin statusnya sendiri.
do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='mutate_claims_unchecked';
  if src is null then raise exception 'rc_private.mutate_claims_unchecked tidak ditemukan.'; end if;

  if position('boleh_putus_hold' in src) > 0 then
    raise notice 'Mesin status sudah menjaga keputusan hold; dilewati.'; return; end if;

  if position($q$ if not rc_private.can_access(null,perm) then raise exception 'Access denied' using errcode='42501'; end if;$q$ in src) = 0 then
    raise exception 'Pola pemeriksaan hak tidak ditemukan pada mutate_claims_unchecked.'; end if;

  baru := replace(src,
    $q$ if not rc_private.can_access(null,perm) then raise exception 'Access denied' using errcode='42501'; end if;$q$,
    $q$ if not rc_private.can_access(null,perm) then raise exception 'Access denied' using errcode='42501'; end if;$q$ || chr(10) ||
    $q$ -- Menahan dan menghanguskan adalah keputusan yang lebih berat daripada menyetujui tempo$q$ || chr(10) ||
    $q$ -- pembayaran, jadi peran yang berwenang memutuskannya dibatasi tersendiri. Jangkauannya$q$ || chr(10) ||
    $q$ -- tetap dijaga can_access pada tiap baris di bawah.$q$ || chr(10) ||
    $q$ if p_action in('approve_hold','reject_hold') and not rc_private.boleh_putus_hold() then$q$ || chr(10) ||
    $q$  raise exception 'Keputusan On Hold dan Expired ditetapkan OSC, Supervisor, Management atau System Manager' using errcode='42501'; end if;$q$);
  execute baru;
  raise notice 'Mesin status menjaga keputusan hold.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text; v_uid uuid; v_role text; b boolean;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='rc_private' and p.proname='boleh_putus_hold';
  foreach v_role in array array['osc','supervisor','management','system manager'] loop
    if position(v_role in src) = 0 then
      raise exception 'GAGAL: peran % belum boleh memutuskan.', v_role; end if;
  end loop;
  if position('depot head' in src) > 0 then
    raise exception 'GAGAL: Depot Head seharusnya tidak memutuskan On Hold / Expired.'; end if;

  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='rc_private' and p.proname='mutate_claims_unchecked';
  if position('boleh_putus_hold' in src) = 0 then
    raise exception 'GAGAL: mesin status tidak menjaga keputusan hold.'; end if;

  -- Dibuktikan dengan peran sungguhan: sebuah akun dijadikan OSC lalu Depot Head di dalam
  -- transaksi ini, jawabannya dibaca, lalu perannya dikembalikan.
  select id, role into v_uid, v_role from public.profiles
   where coalesce(status,'')='active' and lower(coalesce(role,'')) not like '%system%'
   order by user_code limit 1;
  if v_uid is null then
    raise notice 'Tidak ada akun untuk diuji.';
  else
    update public.profiles set role='osc' where id=v_uid;
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
    b := rc_private.boleh_putus_hold();
    reset role;
    if not b then
      update public.profiles set role=v_role where id=v_uid;
      raise exception 'GAGAL: OSC tidak boleh memutuskan.'; end if;

    update public.profiles set role='depot head' where id=v_uid;
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
    b := rc_private.boleh_putus_hold();
    reset role;
    update public.profiles set role=v_role where id=v_uid;
    if b then raise exception 'GAGAL: Depot Head boleh memutuskan, seharusnya tidak.'; end if;

    raise notice 'OSC boleh memutuskan, Depot Head tidak - benar.';
  end if;

  raise notice 'Pemeriksaan lolos.';
exception when others then
  reset role; raise;
end
$periksa$;
