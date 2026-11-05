-- ==========================================================================================
-- Uji rc_email_tick per jenis (migrasi 20261163250000)
-- ==========================================================================================
-- rc_email_tick dipanggil sungguhan, tetapi di dalam subtransaksi yang DIBATALKAN (UJI_SELESAI)
-- dan dengan tiga fungsi diganti sementara: rc_email_susun (stub: mencatat panggilan, gagal untuk
-- 'weekly'), rc_email_jalankan_antrean dan rc_email_periksa (tanpa kerja) - jadi tidak ada yang
-- disusun maupun dikirim. Penggantian fungsi ikut dibatalkan. Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_tick_per_jenis.sql
-- ==========================================================================================
create temp table if not exists _hasil_tk(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_tk;
create temp table if not exists _panggil_susun(jenis text);
truncate _panggil_susun;

do $uji$
declare hasil jsonb := '[]'; r jsonb; v_jam integer; v_sm uuid; v_log0 integer; v_isi jsonb;
begin
  v_jam := extract(hour from now() at time zone 'Asia/Jakarta')::integer;
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  begin
    execute $s$create or replace function public.rc_email_susun(p_jenis text, p_kirim boolean default false, p_test_email text default '')
      returns jsonb language plpgsql as $b$
      begin
        insert into pg_temp._panggil_susun values (p_jenis);
        if p_jenis = 'weekly' then raise exception 'UJI galat susun weekly'; end if;
        return jsonb_build_object('status', 'success');
      end $b$$s$;
    execute $s$create or replace function public.rc_email_jalankan_antrean(p_maks integer default 20)
      returns jsonb language sql as $b$ select '{}'::jsonb $b$$s$;
    execute $s$create or replace function public.rc_email_periksa()
      returns jsonb language sql as $b$ select '{}'::jsonb $b$$s$;

    -- Jam ini: weekly (gagal), timetable (berhasil), pengajuan (harus dilewati); lainnya mati.
    update public.email_settings set aktif = false where jenis in ('daily', 'kesehatan');
    update public.email_settings set aktif = true, jam = v_jam, hari_list = null where jenis in ('weekly', 'timetable', 'pengajuan');
    v_log0 := (select count(*) from public.activity_logs where event_type = 'email_terjadwal_gagal');

    r := public.rc_email_tick();
    hasil := hasil || jsonb_build_object('uji', 'Tick tetap sukses walau satu jenis gagal; jenis lain tetap disusun',
      'lulus', r->>'status' = 'success' and (r->>'disusun')::int = 1
        and exists(select 1 from pg_temp._panggil_susun where jenis = 'timetable'),
      'rinci', r::text);
    hasil := hasil || jsonb_build_object('uji', '''pengajuan'' (sakelar email saat kejadian) tidak dijadwalkan',
      'lulus', not exists(select 1 from pg_temp._panggil_susun where jenis = 'pengajuan'),
      'rinci', (select string_agg(jenis, ', ') from pg_temp._panggil_susun));
    hasil := hasil || jsonb_build_object('uji', 'Kegagalan jenis dicatat di Log Activity (email_terjadwal_gagal) beserta sebabnya',
      'lulus', (select count(*) from public.activity_logs where event_type = 'email_terjadwal_gagal') = v_log0 + 1
        and exists(select 1 from public.activity_logs where event_type = 'email_terjadwal_gagal'
                    and details->>'jenis' = 'weekly' and details->>'sebab' ~ 'UJI galat susun weekly'),
      'rinci', '');

    v_isi := rc_private.email_kesehatan_isi(now() - interval '1 day');
    hasil := hasil || jsonb_build_object('uji', 'Laporan Kesehatan menampilkan "Scheduled email failed: weekly"',
      'lulus', v_isi->>'html' ~ 'Scheduled email failed: weekly' and v_isi->>'html' ~ 'UJI galat susun weekly', 'rinci', '');

    -- Panel jadwal: baris pengajuan tidak tampil dan tidak dapat diubah dari sana.
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_email_status();
    hasil := hasil || jsonb_build_object('uji', 'Panel Email Otomatis tidak menampilkan baris pengajuan',
      'lulus', not exists(select 1 from jsonb_array_elements(r->'pengaturan') p where p->>'jenis' = 'pengajuan')
        and exists(select 1 from jsonb_array_elements(r->'pengaturan') p where p->>'jenis' = 'daily'),
      'rinci', (select string_agg(p->>'jenis', ', ') from jsonb_array_elements(r->'pengaturan') p));
    perform public.rc_email_settings_simpan(jsonb_build_array(
      jsonb_build_object('jenis', 'pengajuan', 'aktif', false, 'jam', 3),
      jsonb_build_object('jenis', 'daily', 'jam', 6)));
    hasil := hasil || jsonb_build_object('uji', 'Simpan Jadwal tidak mengubah sakelar Email Pengajuan (jenis lain tetap tersimpan)',
      'lulus', (select aktif and jam = v_jam from public.email_settings where jenis = 'pengajuan')
        and (select jam = 6 from public.email_settings where jenis = 'daily'),
      'rinci', '');
    perform set_config('request.jwt.claims', '', true);

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  insert into _hasil_tk(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_tk order by urut;
