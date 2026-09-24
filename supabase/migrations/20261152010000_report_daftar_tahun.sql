-- ==========================================================================================
-- Report membawa daftar tahun campaign yang benar-benar ada pada datanya
-- ==========================================================================================
-- Penyaring Tahun Campaign memerlukan pilihannya. Mengikuti pola yang sudah berlaku pada
-- penyaring Region, Depot dan Campaign - "pilihan diturunkan dari data yang BENAR-BENAR ada pada
-- laporan, bukan dari master" - daftar tahunnya ikut dibawa jawaban Dashboard.
--
-- Sebabnya sama: menawarkan tahun yang pasti menghasilkan tabel kosong hanya membuang waktu
-- pembacanya, dan membuat penyaring terasa rusak padahal ia bekerja.
--
-- Daftarnya sengaja dihitung SEBELUM penyaring tahun diterapkan pada baris - kalau tidak, memilih
-- 2025 akan menyisakan satu-satunya pilihan 2025 dan tidak ada jalan kembali.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='report_dashboard';
  if src is null then raise exception 'rc_private.report_dashboard tidak ditemukan.'; end if;
  if position($q$'tahunTersedia'$q$ in src) > 0 then
    raise notice 'report_dashboard sudah membawa daftar tahun; dilewati.'; return; end if;

  if position($q$    'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')$q$ in src) = 0 then
    raise exception 'Pola akhir jawaban tidak ditemukan pada report_dashboard.'; end if;

  baru := replace(src,
    $q$    'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')$q$,
    $q$    'tahunTersedia', (select coalesce(jsonb_agg(t.y order by t.y desc),'[]'::jsonb)$q$ || chr(10) ||
    $q$       from (select distinct campaign_year y from public.rc_report_rows$q$ || chr(10) ||
    $q$              where campaign_year is not null) t),$q$ || chr(10) ||
    $q$    'dibuatPada', to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')$q$);
  execute baru;
  raise notice 'report_dashboard membawa daftar tahun campaign.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_uid uuid; h jsonb; n_tanpa int; n_dengan int; v_tahun text;
begin
  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);

  h := public.rc_report_dashboard('{}'::jsonb);
  if not (h ? 'tahunTersedia') then
    reset role; raise exception 'GAGAL: daftar tahun tidak ikut pada jawaban.'; end if;
  n_tanpa := jsonb_array_length(h->'tahunTersedia');

  -- Daftarnya harus TETAP lengkap meski penyaring tahun sedang dipakai, supaya masih ada jalan
  -- kembali ke tahun lain.
  if n_tanpa > 0 then
    v_tahun := h->'tahunTersedia'->>0;
    h := public.rc_report_dashboard(jsonb_build_object('tahunCampaign', v_tahun));
    n_dengan := jsonb_array_length(h->'tahunTersedia');
    if n_dengan <> n_tanpa then
      reset role;
      raise exception 'GAGAL: daftar tahun menyusut dari % menjadi % ketika disaring.',
        n_tanpa, n_dengan;
    end if;
  end if;
  reset role;

  raise notice 'Tahun tersedia: % pilihan.', n_tanpa;
  raise notice 'Pemeriksaan lolos.';
exception when others then
  reset role; raise;
end
$periksa$;
