-- ==========================================================================================
-- Bukti kesetaraan: kebijakan RLS lama vs usulan baru
-- ==========================================================================================
-- Seluruh berkas ini berakhir dengan exception, sehingga SEMUA perubahan dibatalkan. Produksi
-- tidak berubah sedikit pun.
--
-- JALANKAN LEWAT: node scripts/loadtest/jalankan-bukti.mjs
-- Skrip itu menyisipkan teks kebijakan langsung dari usulan-optimasi-rls.sql, sehingga yang
-- diuji selalu berkas yang akan diterapkan - bukan salinan yang dapat menyimpang.
--
-- Cara membuktikannya: untuk setiap akun dan setiap tabel berkebijakan, ambil HIMPUNAN id yang
-- terlihat, lalu bandingkan sidik jarinya (md5 atas daftar id terurut). Menghitung jumlah baris
-- saja tidak cukup - dua himpunan berbeda bisa berjumlah sama.
--
-- Yang diuji bukan hanya akun yang ada. Tiga keadaan tepi sengaja dibuat, karena justru di
-- situlah kebijakan biasanya menyimpang:
--   * pengguna tanpa depot sama sekali  -> harus melihat NOL baris, bukan semua baris
--   * pengguna berstatus inactive       -> harus melihat NOL baris
--   * pengguna yang wajib ganti PIN     -> harus melihat NOL baris

-- ---------------------------------------------------------------- pengukur
create or replace function pg_temp.sidik(tabel text) returns text
language plpgsql as $f$
declare hasil text;
begin
  execute format(
    'select coalesce(md5(string_agg(id::text, '','' order by id::text)), ''(kosong)'') from %s', tabel)
    into hasil;
  return hasil;
exception when others then
  return 'GALAT: ' || sqlerrm;
end $f$;

create or replace function pg_temp.jumlah(tabel text) returns bigint
language plpgsql as $f$
declare n bigint;
begin
  execute format('select count(*) from %s', tabel) into n;
  return n;
exception when others then return -1;
end $f$;

create temp table hasil_uji(
  akun text, peran text, tabel text, tahap text, jumlah bigint, sidik text);

-- ---------------------------------------------------------------- keadaan tepi
-- auth.users dijaga trigger handle_new_user(), jadi alih-alih membuat akun baru, keadaan tepi
-- dibuat dengan mengubah akun yang ADA - seluruhnya di dalam transaksi yang dibatalkan.
--
--   IQBAL     sudah tanpa depot dan tanpa izin  -> uji "tidak boleh melihat apa pun"
--   AYI       dijadikan inactive sementara      -> uji "akun mati tidak melihat apa pun"
--   ANNA_MDN  diberi bendera wajib ganti PIN    -> uji "belum ganti PIN, belum boleh apa-apa"
--   ANIADMPTI dibiarkan apa adanya (4 depot)    -> jalur normal admin
--   DANIEL    system manager                    -> jalur lihat semua
do $tepi$
begin
  update public.profiles set status='inactive' where user_code='AYI';
  update public.profiles set must_change_password=true where user_code='ANNA_MDN';
end $tepi$;

-- ---------------------------------------------------------------- TAHAP 1: kebijakan LAMA
do $lama$
declare r record; tb text; n bigint; sd text;
begin
  for r in select p.id, p.user_code, p.role from public.profiles p order by p.user_code loop
    foreach tb in array array['public.claims','public.depots','public.campaigns',
                              'public.activity_logs','rc_private.claim_sensitive'] loop
      -- Diukur sebagai pengguna, lalu peran dikembalikan SEBELUM menulis hasil: tabel temp
      -- bukan milik peran authenticated, dan menulisnya dari sana ditolak.
      perform set_config('request.jwt.claims', json_build_object('sub',r.id,'role','authenticated')::text, true);
      perform set_config('role','authenticated',true);
      n := pg_temp.jumlah(tb);
      sd := pg_temp.sidik(tb);
      perform set_config('role','postgres',true);
      insert into hasil_uji values (r.user_code, r.role, tb, 'lama', n, sd);
    end loop;
  end loop;
end $lama$;

-- {{KEBIJAKAN USULAN DISISIPKAN DI SINI}}

-- ---------------------------------------------------------------- TAHAP 2: kebijakan BARU
do $baru$
declare r record; tb text; n bigint; sd text;
begin
  for r in select p.id, p.user_code, p.role from public.profiles p order by p.user_code loop
    foreach tb in array array['public.claims','public.depots','public.campaigns',
                              'public.activity_logs','rc_private.claim_sensitive'] loop
      -- Diukur sebagai pengguna, lalu peran dikembalikan SEBELUM menulis hasil: tabel temp
      -- bukan milik peran authenticated, dan menulisnya dari sana ditolak.
      perform set_config('request.jwt.claims', json_build_object('sub',r.id,'role','authenticated')::text, true);
      perform set_config('role','authenticated',true);
      n := pg_temp.jumlah(tb);
      sd := pg_temp.sidik(tb);
      perform set_config('role','postgres',true);
      insert into hasil_uji values (r.user_code, r.role, tb, 'baru', n, sd);
    end loop;
  end loop;
end $baru$;

-- ---------------------------------------------------------------- laporan
do $lap$
declare r record; keluar text := ''; n_beda int := 0; n_sama int := 0;
begin
  for r in
    select l.akun, l.peran, l.tabel,
           l.jumlah j_lama, b.jumlah j_baru, l.sidik s_lama, b.sidik s_baru
      from hasil_uji l join hasil_uji b
        on b.akun=l.akun and b.tabel=l.tabel and b.tahap='baru'
     where l.tahap='lama'
     order by l.akun, l.tabel
  loop
    if r.s_lama is distinct from r.s_baru then
      n_beda := n_beda + 1;
      keluar := keluar || E'\n  BEDA  ' || rpad(r.akun,12) || rpad(r.tabel,28)
        || ' lama=' || r.j_lama || ' baru=' || r.j_baru;
    else
      n_sama := n_sama + 1;
    end if;
  end loop;

  -- Ringkasan per akun supaya terlihat siapa melihat berapa.
  keluar := keluar || E'\n\n  JUMLAH BARIS TERLIHAT (lama = baru):';
  for r in
    select akun, peran,
           max(case when tabel='public.claims' then jumlah end) claims,
           max(case when tabel='public.depots' then jumlah end) depots,
           max(case when tabel='public.campaigns' then jumlah end) campaigns,
           max(case when tabel='public.activity_logs' then jumlah end) logs,
           max(case when tabel='rc_private.claim_sensitive' then jumlah end) sensitive
      from hasil_uji where tahap='baru' group by akun, peran order by akun
  loop
    keluar := keluar || E'\n    ' || rpad(r.akun,12) || rpad(r.peran,16)
      || 'claims=' || lpad(r.claims::text,5)
      || ' depots=' || lpad(r.depots::text,3)
      || ' campaigns=' || lpad(r.campaigns::text,4)
      || ' logs=' || lpad(r.logs::text,4)
      || ' sensitive=' || lpad(r.sensitive::text,5);
  end loop;

  raise exception E'HASIL: % setara, % berbeda%', n_sama, n_beda, keluar;
end $lap$;
