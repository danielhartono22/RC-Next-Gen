-- ==========================================================================================
-- Timetable: Top 10 Depot Not Yet terlihat oleh siapa pun
-- ==========================================================================================
-- Permintaan pemilik: "untuk timetable top 10 depot biarkan bisa dilihat secara umum oleh
-- siapapun tanpa rls."
--
-- Sebelumnya papan itu dihitung dari CTE `global` di dalam rc_timetable_matrix, yang tunduk pada
-- jangkauan pemanggilnya. Akibatnya seorang OSC yang memegang tiga depot melihat "Top 10" berisi
-- tiga depot - sebuah papan peringkat yang hanya memuat dirinya sendiri, dan karena itu tidak
-- memberi tahu apa pun tentang posisinya.
--
-- ------------------------------------------------------------------------------------------
-- APA YANG DIBUKA, DAN APA YANG TIDAK
-- ------------------------------------------------------------------------------------------
-- Yang dibuka hanya tiga hal per depot: kode, nama, dan jumlah dokumen Not Yet. Tidak ada
-- nilai rupiah, tidak ada nama pelanggan, tidak ada dokumen - jadi papan ini tidak dapat
-- dipakai untuk membaca isi depot lain, hanya untuk mengetahui posisi relatifnya.
--
-- Pintu masuknya tetap satu: rc_timetable_matrix, yang tetap memeriksa hak akses modul
-- Timetable. Yang berubah hanyalah bahwa SATU bagian dari jawabannya dihitung tanpa penyaring
-- jangkauan. Sisa jawaban - matriks, per region, per campaign, tabel depot - tidak disentuh dan
-- tetap tersaring seperti semula.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- Dihitung dengan hak pemiliknya, sehingga tidak tunduk pada jangkauan pemanggil. Ia tidak
-- menerima argumen apa pun: tanpa argumen, tidak ada yang dapat diselipkan untuk membuatnya
-- membocorkan sesuatu yang lain.
create or replace function rc_private.timetable_top_notyet()
returns jsonb language sql stable security definer set search_path='' as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
      'kodeDepot', t.depot_code, 'namaDepot', t.depot_name, 'notYet', t.n)
      order by t.n desc, t.depot_code), '[]'::jsonb)
  from (select d.depot_code, d.depot_name, count(*) n
          from public.claims c
          join public.depots d on d.id = c.depot_id
         where c.status = 'not_yet' and c.archived_at is null
         group by d.depot_code, d.depot_name
        having count(*) > 0
         order by 3 desc, 1
         limit 10) t;
$fn$;
revoke all on function rc_private.timetable_top_notyet() from public, anon;
grant execute on function rc_private.timetable_top_notyet() to authenticated;

do $mig$
declare src text; baru text; awal int; akhir int; blok text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='rc_timetable_matrix';
  if src is null then raise exception 'public.rc_timetable_matrix tidak ditemukan.'; end if;

  if position('timetable_top_notyet' in src) > 0 then
    raise notice 'rc_timetable_matrix sudah memakai papan umum; dilewati.'; return; end if;

  awal := position($q$      'topNotYet', (select coalesce(jsonb_agg($q$ in src);
  if awal = 0 then raise exception 'Pola topNotYet tidak ditemukan pada rc_timetable_matrix.'; end if;
  akhir := position($q$      'campaigns',$q$ in src);
  if akhir = 0 or akhir <= awal then
    raise exception 'Batas akhir blok topNotYet tidak ditemukan.'; end if;

  blok := substr(src, awal, akhir - awal);
  baru := replace(src, blok,
    $q$      'topNotYet', rc_private.timetable_top_notyet(),$q$ || chr(10) || chr(10));
  if baru = src then raise exception 'Penggantian blok topNotYet gagal.'; end if;

  execute baru;
  raise notice 'rc_timetable_matrix: Top 10 Depot dihitung tanpa penyaring jangkauan.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_sm uuid; v_kecil uuid; v_role text; a jsonb; b jsonb; n_semua int; src text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='rc_timetable_matrix';
  if position('timetable_top_notyet' in src) = 0 then
    raise exception 'GAGAL: Timetable belum memakai papan umum.'; end if;

  -- Papan yang sama harus muncul bagi System Manager dan bagi akun berjangkauan sempit.
  select id into v_sm from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;
  select id, role into v_kecil, v_role from public.profiles
   where coalesce(status,'')='active' and lower(coalesce(role,'')) not like '%system%'
   order by user_code limit 1;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_sm::text,'role','authenticated')::text, true);
  a := rc_private.timetable_top_notyet();
  reset role;

  if v_kecil is not null then
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_kecil::text,'role','authenticated')::text, true);
    b := rc_private.timetable_top_notyet();
    reset role;
    if a is distinct from b then
      raise exception 'GAGAL: papan Top 10 masih berbeda menurut siapa yang membukanya.'; end if;
  end if;

  n_semua := jsonb_array_length(a);
  if n_semua > 10 then raise exception 'GAGAL: papan memuat % baris, maksimal 10.', n_semua; end if;

  -- Batasnya: tidak ada nilai rupiah maupun identitas pelanggan yang ikut.
  if a::text ~* '(cb_net|netCb|customer|namaToko|ktp|npwp)' then
    raise exception 'GAGAL: papan umum memuat lebih dari kode, nama depot dan jumlah.'; end if;

  raise notice 'Top 10 Depot: % baris, sama untuk semua peran.', n_semua;
  raise notice 'Pemeriksaan lolos.';
exception when others then
  reset role; raise;
end
$periksa$;
