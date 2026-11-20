-- ==========================================================================================
-- Uji 15 November 2026: indikator online di daftar akun (20261164000000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_kehadiran.sql
-- ==========================================================================================
create temp table if not exists _hasil_kh(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_kh;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_a uuid; v_kode text; v_pending uuid; r jsonb; u jsonb; v_lama jsonb; v_txt text; v_t timestamptz;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and suffix_num ~ '^[0-9]{3}$' order by user_code limit 1;
  select id, upper(user_code) into v_a, v_kode from public.profiles where role = 'admin' and status = 'active' order by user_code limit 1;
  select id into v_pending from public.profiles where status <> 'active' order by user_code limit 1;
  begin
    update public.profiles set must_change_password = false where id in (v_sm, v_a);
    delete from rc_private.kehadiran;

    -- Daftar sebelum ada sinyal: isinya sama dengan daftar lama, ditambah dua kunci.
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    v_lama := rc_private.legacy_users();
    r := public.rc_legacy_manageable();
    hasil := hasil || jsonb_build_object('uji', 'Daftar akun: jumlah, urutan dan isi lama tidak berubah; semua offline sebelum ada sinyal', 'lulus',
      jsonb_array_length(r->'users') = jsonb_array_length(v_lama) and jsonb_array_length(v_lama) > 0
      and (select bool_and((n.x - 'online' - 'terakhirAktif') = l.x and n.x->>'online' = 'false' and n.x->>'terakhirAktif' = '')
             from jsonb_array_elements(r->'users') with ordinality n(x, i) join jsonb_array_elements(v_lama) with ordinality l(x, i) on l.i = n.i),
      'rinci', jsonb_array_length(r->'users') || ' akun');

    -- Sinyal dari admin: tercatat, lalu terlihat hijau oleh System Manager.
    perform set_config('request.jwt.claims', json_build_object('sub', v_a::text, 'role', 'authenticated')::text, true);
    r := public.rc_hadir();
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    select x into u from jsonb_array_elements(public.rc_legacy_manageable()->'users') x where upper(x->>'userId') = v_kode;
    hasil := hasil || jsonb_build_object('uji', 'Sinyal tercatat; akun itu online dengan jam terakhir aktif', 'lulus',
      (r->>'tercatat')::boolean and (u->>'online')::boolean and u->>'terakhirAktif' = to_char(now() at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
      'rinci', coalesce(u->>'online', '-') || ' / ' || coalesce(u->>'terakhirAktif', '-'));

    -- Lebih dari 5 menit tanpa sinyal: offline, jam terakhir tetap tampil.
    update rc_private.kehadiran set terakhir_aktif = now() - interval '6 minutes' where user_id = v_a;
    select x into u from jsonb_array_elements(public.rc_legacy_manageable()->'users') x where upper(x->>'userId') = v_kode;
    hasil := hasil || jsonb_build_object('uji', '6 menit tanpa sinyal: offline, terakhir aktif tetap tampil', 'lulus',
      not (u->>'online')::boolean and u->>'terakhirAktif' = to_char((now() - interval '6 minutes') at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), 'rinci', u->>'terakhirAktif');

    -- Sinyal paling sering sekali per 60 detik.
    perform set_config('request.jwt.claims', json_build_object('sub', v_a::text, 'role', 'authenticated')::text, true);
    update rc_private.kehadiran set terakhir_aktif = now() - interval '30 seconds' where user_id = v_a;
    perform public.rc_hadir();
    select terakhir_aktif into v_t from rc_private.kehadiran where user_id = v_a;
    update rc_private.kehadiran set terakhir_aktif = now() - interval '2 minutes' where user_id = v_a;
    perform public.rc_hadir();
    hasil := hasil || jsonb_build_object('uji', 'Sinyal kurang dari 60 detik tidak menulis ulang; sesudah 2 menit menulis', 'lulus',
      v_t = now() - interval '30 seconds' and (select terakhir_aktif from rc_private.kehadiran where user_id = v_a) = now(), 'rinci', v_t::text);

    -- Logout: langsung offline; sinyal berikutnya (login lagi) online kembali.
    r := public.rc_hadir(true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    select x into u from jsonb_array_elements(public.rc_legacy_manageable()->'users') x where upper(x->>'userId') = v_kode;
    v_txt := u->>'online';
    perform set_config('request.jwt.claims', json_build_object('sub', v_a::text, 'role', 'authenticated')::text, true);
    perform public.rc_hadir();
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    select x into u from jsonb_array_elements(public.rc_legacy_manageable()->'users') x where upper(x->>'userId') = v_kode;
    hasil := hasil || jsonb_build_object('uji', 'Logout langsung offline; sinyal berikutnya online lagi', 'lulus', v_txt = 'false' and (u->>'online')::boolean, 'rinci', v_txt || ' -> ' || (u->>'online'));

    -- Satu baris per akun, tanpa riwayat.
    hasil := hasil || jsonb_build_object('uji', 'Satu baris per akun (tanpa riwayat)', 'lulus',
      (select count(*) from rc_private.kehadiran where user_id = v_a) = 1, 'rinci', (select count(*) from rc_private.kehadiran)::text);

    -- Akun tidak aktif tidak dicatat; tanpa login ditolak.
    if v_pending is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_pending::text, 'role', 'authenticated')::text, true);
      r := public.rc_hadir();
    else r := jsonb_build_object('tercatat', false); end if;
    perform set_config('request.jwt.claims', '', true);
    begin perform public.rc_hadir(); v_txt := 'diterima'; exception when others then v_txt := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Akun tidak aktif tidak dicatat; tanpa login ditolak', 'lulus',
      not (r->>'tercatat')::boolean and v_txt ~ 'Masuk lebih dulu' and (v_pending is null or not exists(select 1 from rc_private.kehadiran where user_id = v_pending)), 'rinci', v_txt);

    hasil := hasil || jsonb_build_object('uji', 'Hak: sinyal hanya untuk pengguna login; tabel kehadiran tidak terbaca langsung', 'lulus',
      has_function_privilege('authenticated', 'public.rc_hadir(boolean)', 'execute') and not has_function_privilege('anon', 'public.rc_hadir(boolean)', 'execute')
      and not has_table_privilege('authenticated', 'rc_private.kehadiran', 'select') and not has_table_privilege('anon', 'rc_private.kehadiran', 'select'), 'rinci', '-');
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_kh(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_kh order by urut;
