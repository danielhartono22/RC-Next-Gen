-- ==========================================================================================
-- Perbaikan: modul Report galat "permission denied for function report_dashboard"
-- ==========================================================================================
-- Sesudah badan agregasi dipindahkan ke rc_private (20261132), modul Report di dalam aplikasi
-- berhenti bekerja sementara dashboard publik baik-baik saja. Pemilik melaporkannya persis
-- seperti itu: "kenapa jadi modul report yang error sementara yg open tidak?"
--
-- ------------------------------------------------------------------------------------------
-- SEBABNYA
-- ------------------------------------------------------------------------------------------
-- Kedua pembungkus memanggil badan yang sama, tetapi dengan hak yang berbeda:
--
--   public.rc_report_dashboard   SECURITY INVOKER -> berjalan sebagai 'authenticated'
--   public.rc_dashboard_publik   SECURITY DEFINER -> berjalan sebagai pemilik fungsi
--
-- Migration sebelumnya mencabut EXECUTE atas rc_private.report_dashboard dari 'authenticated',
-- dengan maksud menutup jalan pintas ke badan agregasi. Niatnya benar, akibatnya tidak: yang
-- tertutup justru jalur yang sah. Pembungkus INVOKER berjalan sebagai pemanggilnya, jadi
-- pemanggil itu harus boleh mengeksekusi apa pun yang dipanggil di dalamnya. Pembungkus DEFINER
-- tidak terkena karena ia berjalan sebagai pemilik - itulah sebabnya hanya satu sisi yang rusak.
--
-- Terbukti dengan menjalankannya sebagai authenticated:
--
--   42501 :: permission denied for function report_dashboard
--
-- ------------------------------------------------------------------------------------------
-- PERBAIKANNYA, DAN MENGAPA INI MEMANG AMAN
-- ------------------------------------------------------------------------------------------
-- EXECUTE dikembalikan kepada 'authenticated', sama seperti rc_private.can_access dan
-- rc_private.is_system_manager yang sejak semula memang demikian - keduanya juga dipanggil dari
-- dalam fungsi INVOKER dan karenanya harus dapat dieksekusi pemanggilnya.
--
-- Dua hal membuat ini tidak membuka apa pun:
--
--   1. rc_private BUKAN skema yang dibuka PostgREST. Tidak ada cara memanggil fungsinya lewat
--      HTTP; satu-satunya jalan masuk tetap pembungkus di skema public, dan di sanalah
--      pemeriksaan 'view_report' berada.
--
--   2. Ketiga fungsi rc_private itu SECURITY INVOKER. Seandainya seseorang dapat memanggilnya
--      langsung, RLS tetap berlaku atas dirinya: yang terlihat hanyalah baris yang memang sudah
--      boleh ia baca. Yang dilewati hanya pemeriksaan hak modul, bukan batas yurisdiksi.
--
-- ------------------------------------------------------------------------------------------
-- PELAJARAN YANG DITERAPKAN PADA PEMERIKSAANNYA
-- ------------------------------------------------------------------------------------------
-- Migration sebelumnya LOLOS pemeriksaan sendiri, karena yang diperiksanya adalah "authenticated
-- tidak boleh mengeksekusi rc_private" - sifat yang saya inginkan, bukan perilaku yang
-- dibutuhkan aplikasi. Pemeriksaan di bawah karena itu tidak lagi memeriksa hak, melainkan
-- MENJALANKAN jalur aplikasi sebagai pengguna sungguhan dan menuntut jawabannya benar.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

grant execute on function rc_private.report_dashboard(jsonb) to authenticated;
grant execute on function rc_private.cost_center(jsonb)      to authenticated;
grant execute on function rc_private.cost_center_2(jsonb)    to authenticated;

-- anon tetap tidak boleh: halaman publik masuk lewat rc_dashboard_publik yang SECURITY DEFINER,
-- jadi ia tidak memerlukan hak ini, dan memberikannya hanya memperluas permukaan tanpa guna.
revoke execute on function rc_private.report_dashboard(jsonb) from anon;
revoke execute on function rc_private.cost_center(jsonb)      from anon;
revoke execute on function rc_private.cost_center_2(jsonb)    from anon;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan: menempuh jalur aplikasi sebagai pengguna sungguhan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare
  v_uid uuid; v_kode text; v_hasil jsonb; v_galat text;
begin
  select id, user_code into v_uid, v_kode from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'') = 'active'
   order by user_code limit 1;
  if v_uid is null then
    raise exception 'GAGAL: tidak ada akun System Manager aktif untuk diuji.'; end if;

  -- Ketiga modul dipanggil persis seperti PostgREST memanggilnya: peran authenticated, dengan
  -- klaim JWT milik akun itu, sehingga can_access() dan RLS benar-benar bekerja.
  for v_galat in
    select x from unnest(array['rc_report_dashboard','rc_cost_center','rc_cost_center_2']) x
  loop
    begin
      set local role authenticated;
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

      execute format('select public.%I(%L::jsonb)', v_galat, '{}') into v_hasil;

      reset role;
      if v_hasil is null or (v_hasil->>'status') <> 'success' then
        raise exception 'GAGAL: public.% tidak mengembalikan success untuk akun %.',
          v_galat, v_kode;
      end if;
      raise notice 'OK public.% sebagai % ', v_galat, v_kode;
    exception when insufficient_privilege then
      reset role;
      raise exception 'GAGAL: public.% masih ditolak untuk akun % -> %', v_galat, v_kode, sqlerrm;
    end;
  end loop;
  reset role;

  -- Halaman publik harus tetap bekerja tanpa sesi sama sekali.
  begin
    set local role anon;
    v_hasil := public.rc_dashboard_publik();
    reset role;
  exception when others then
    reset role;
    raise exception 'GAGAL: dashboard publik ditolak untuk anon -> %', sqlerrm;
  end;
  if (v_hasil->>'status') <> 'success' or not (v_hasil ? 'cc1') then
    raise exception 'GAGAL: jawaban dashboard publik tidak utuh.'; end if;

  -- anon tetap tidak boleh menembus ke badan agregasi.
  if has_function_privilege('anon','rc_private.report_dashboard(jsonb)','execute') then
    raise exception 'GAGAL: anon dapat memanggil rc_private.report_dashboard.'; end if;

  raise notice 'Pemeriksaan lolos: aplikasi dan halaman publik sama-sama bekerja.';
end
$periksa$;
