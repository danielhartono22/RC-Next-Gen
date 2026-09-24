-- ==========================================================================================
-- Report: satu badan agregasi, dua pembungkus
-- ==========================================================================================
-- Permintaan pemilik: dashboard yang dapat dibuka tanpa login harus 100% sama dengan modul
-- Report di dalam aplikasi, "termasuk jika ada perubahan ke depan".
--
-- Kalimat terakhir itulah yang menentukan bentuk perubahan ini. Menyalin kueri ke fungsi publik
-- memenuhi "sama hari ini" tetapi tidak "sama ke depan": begitu salah satu sisi disunting,
-- keduanya menyimpang, dan penyimpangan itu baru ketahuan setelah dibaca orang di luar.
--
-- Karena itu badan agregasinya dipindahkan ke rc_private dan dipanggil dua kali:
--
--   public.rc_report_dashboard  -> memeriksa hak akses, lalu rc_private.report_dashboard
--   public.rc_cost_center       -> memeriksa hak akses, lalu rc_private.cost_center
--   public.rc_cost_center_2     -> memeriksa hak akses, lalu rc_private.cost_center_2
--   public.rc_dashboard_publik  -> SECURITY DEFINER, memanggil ketiganya tanpa filter
--
-- Mengubah sebuah kolom atau rumus sesudah ini cukup dilakukan sekali di rc_private, dan kedua
-- sisi ikut berubah. Tidak ada lagi jalan untuk mengubah salah satunya saja.
--
-- ------------------------------------------------------------------------------------------
-- BADANNYA DISALIN OLEH MESIN, BUKAN OLEH TANGAN
-- ------------------------------------------------------------------------------------------
-- Definisi ketiga fungsi dibaca dari katalog lewat pg_get_functiondef, lalu hanya dua hal yang
-- diubah: namanya, dan blok pemeriksaan hak akses yang dicabut. Sisanya lewat apa adanya. Dengan
-- begitu tidak ada kemungkinan satu koma pun berbeda dari yang selama ini berjalan, dan bila
-- pola yang dicari tidak ditemukan, migration berhenti dengan pesan jelas alih-alih menghasilkan
-- fungsi yang salah diam-diam.
--
-- ------------------------------------------------------------------------------------------
-- HAK AKSES TIDAK IKUT PINDAH
-- ------------------------------------------------------------------------------------------
-- Pemeriksaan 'view_report' tetap berada di pembungkus publik, bukan di rc_private. Fungsi
-- rc_private tidak dapat dipanggil anon maupun authenticated - haknya dicabut di bawah - jadi
-- satu-satunya jalan masuk bagi pengguna aplikasi tetap melewati pemeriksaan itu.
--
-- Halaman publik memang melewatinya, dan itu memang keputusan pemilik. Yang tidak dilonggarkan
-- adalah isinya: ketiga agregasi bekerja pada tingkat Depot, Campaign, Region dan bulan, tidak
-- satu pun menyentuh nama toko, KTP, NPWP atau nomor rekening. Pemeriksaan di akhir berkas ini
-- menolak bila suatu saat ada yang menambahkannya.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $mig$
declare
  v_cek text := '  if not rc_private.can_access(null,''view_report'') and not rc_private.is_system_manager() then'
             || chr(10)
             || '    raise exception ''Tidak punya hak melihat modul Report'' using errcode=''42501''; end if;';
  v_pasang text[][] := array[
    ['rc_report_dashboard', 'report_dashboard'],
    ['rc_cost_center',      'cost_center'],
    ['rc_cost_center_2',    'cost_center_2']
  ];
  v_publik text; v_privat text; src text; baru text; i int;
begin
  for i in 1 .. array_length(v_pasang, 1) loop
    v_publik := v_pasang[i][1];
    v_privat := v_pasang[i][2];

    -- Bila sudah dipindahkan pada penerapan sebelumnya, pembungkusnya tidak memuat kueri lagi.
    select pg_get_functiondef(p.oid) into src from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_publik;
    if src is null then
      raise exception 'public.% tidak ditemukan.', v_publik; end if;

    if position('rc_private.' || v_privat in src) > 0 then
      raise notice '%: sudah memakai rc_private.%; dilewati.', v_publik, v_privat;
      continue;
    end if;

    if position(v_cek in src) = 0 then
      raise exception 'Blok pemeriksaan hak akses tidak ditemukan pada public.%. '
        'Sumbernya sudah berubah - periksa dan perbarui migration ini.', v_publik;
    end if;

    -- 1. Badan agregasi pindah ke rc_private, tanpa pemeriksaan hak akses.
    baru := replace(src, 'FUNCTION public.' || v_publik || '(',
                         'FUNCTION rc_private.' || v_privat || '(');
    baru := replace(baru, v_cek, '');
    if baru = src then
      raise exception 'Nama fungsi tidak dapat diganti pada public.%.', v_publik; end if;
    execute baru;

    -- 2. Pembungkus publik: pemeriksaan hak akses, lalu meneruskan.
    execute format($f$
      create or replace function public.%I(p_filter jsonb default '{}'::jsonb)
      returns jsonb language plpgsql stable set search_path='' as $body$
      begin
        if not rc_private.can_access(null,'view_report') and not rc_private.is_system_manager() then
          raise exception 'Tidak punya hak melihat modul Report' using errcode='42501'; end if;
        return rc_private.%I(p_filter);
      end $body$;
    $f$, v_publik, v_privat);

    raise notice '%: badan pindah ke rc_private.%.', v_publik, v_privat;
  end loop;
end
$mig$;

-- rc_private tertutup bagi pengguna. Satu-satunya jalan masuk adalah pembungkus publik, dan di
-- sanalah hak akses diperiksa.
revoke all on function rc_private.report_dashboard(jsonb) from public, anon, authenticated;
revoke all on function rc_private.cost_center(jsonb)      from public, anon, authenticated;
revoke all on function rc_private.cost_center_2(jsonb)    from public, anon, authenticated;

grant execute on function public.rc_report_dashboard(jsonb) to authenticated;
grant execute on function public.rc_cost_center(jsonb)      to authenticated;
grant execute on function public.rc_cost_center_2(jsonb)    to authenticated;

-- ------------------------------------------------------------------------------------------
-- Dashboard publik memanggil badan yang sama
-- ------------------------------------------------------------------------------------------
-- Bentuk jawabannya sengaja dibuat persis seperti rtData di dalam aplikasi - dashboard, cc1,
-- cc2 - sehingga halaman publik dapat memakai fungsi penggambar yang sama tanpa penyesuaian.
-- Tidak ada filter yang diteruskan: halaman publik tidak mengenal siapa yang membukanya, jadi
-- ia menampilkan seluruhnya dan penyaringan dilakukan di sisi halaman.
create or replace function public.rc_dashboard_publik()
returns jsonb language sql stable security definer set search_path='' as $fn$
  select jsonb_build_object(
    'status','success',
    'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
    'dashboard', rc_private.report_dashboard('{}'::jsonb),
    'cc1',       rc_private.cost_center('{}'::jsonb),
    'cc2',       rc_private.cost_center_2('{}'::jsonb)
  );
$fn$;

revoke all on function public.rc_dashboard_publik() from public;
grant execute on function public.rc_dashboard_publik() to anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text; v jsonb; d jsonb; teks text;
begin
  -- 1. Pembungkus publik benar-benar tidak lagi memuat kueri sendiri.
  foreach src in array array['rc_report_dashboard','rc_cost_center','rc_cost_center_2'] loop
    if (select pg_get_functiondef(p.oid) from pg_proc p
          join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname=src) not like '%rc_private.%' then
      raise exception 'GAGAL: public.% belum meneruskan ke rc_private.', src; end if;
  end loop;

  -- 2. Hak akses tetap dijaga di pembungkus.
  foreach src in array array['rc_report_dashboard','rc_cost_center','rc_cost_center_2'] loop
    if (select pg_get_functiondef(p.oid) from pg_proc p
          join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname=src) not like '%view_report%' then
      raise exception 'GAGAL: public.% kehilangan pemeriksaan hak akses.', src; end if;
  end loop;

  -- 3. rc_private tertutup bagi pengguna.
  foreach src in array array['report_dashboard','cost_center','cost_center_2'] loop
    if has_function_privilege('authenticated','rc_private.'||src||'(jsonb)','execute')
    or has_function_privilege('anon','rc_private.'||src||'(jsonb)','execute') then
      raise exception 'GAGAL: rc_private.% dapat dipanggil langsung.', src; end if;
  end loop;

  -- 4. Halaman publik dapat memanggil dan mendapat ketiga bagiannya.
  if not has_function_privilege('anon','public.rc_dashboard_publik()','execute') then
    raise exception 'GAGAL: anon tidak dapat memanggil dashboard publik.'; end if;

  v := public.rc_dashboard_publik();
  if (v->>'status') <> 'success' then raise exception 'GAGAL: bukan success.'; end if;
  foreach src in array array['dashboard','cc1','cc2'] loop
    if not (v ? src) then raise exception 'GAGAL: bagian % tidak ada.', src; end if;
  end loop;

  d := v->'dashboard';
  foreach src in array array['kpi','trenBulanan','status_distribusi','aging','depot','campaign','region'] loop
    if not (d ? src) then raise exception 'GAGAL: dashboard kehilangan %.', src; end if;
  end loop;

  -- 5. Batas yang tidak boleh dilanggar meski isinya bertambah: tidak ada data pribadi.
  teks := v::text;
  if teks ~* '(namaToko|kodeToko|"ktp"|npwp|noRek|namaRek)' then
    raise exception 'GAGAL: jawaban publik memuat data pelanggan.'; end if;

  raise notice 'dashboard: depot=% campaign=% region=% tren=% | cc1=% | cc2=%',
    jsonb_array_length(d->'depot'), jsonb_array_length(d->'campaign'),
    jsonb_array_length(d->'region'), jsonb_array_length(d->'trenBulanan'),
    jsonb_array_length(v->'cc1'->'rows'), jsonb_array_length(v->'cc2'->'rows');
  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
