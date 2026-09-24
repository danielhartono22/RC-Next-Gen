-- ==========================================================================================
-- Approval dan penolakannya tidak lagi menuntut alasan
-- ==========================================================================================
-- Permintaan pemilik: "tidak perlu ada alasan jadi reject atau approve aja".
--
-- Mesin status menuntut alasan untuk setiap tindakan yang membatalkan tahap - reject_release,
-- reject_claim, reject_clearing, hold, unhold, expire - dan reject_approval ikut dimasukkan ke
-- daftar itu ketika tahap approval dibuat. Tuntutan itu dicabut untuk approval saja.
--
-- Tindakan lain TIDAK disentuh. Pada tahap-tahap itu alasan memang menjelaskan sesuatu yang
-- tidak terbaca dari status - mengapa sebuah dokumen ditahan, mengapa dihanguskan - sedangkan
-- pada approval, tindakannya sendiri sudah merupakan keterangan yang lengkap: disetujui, atau
-- tidak.
--
-- Kolom alasannya tetap ada dan tetap disimpan bila suatu saat diisi; yang dicabut hanya
-- kewajibannya. Riwayat pada tab History dan Log Aktivitas tetap mencatat siapa, kapan, dan
-- dari status apa ke status apa - dan itulah yang sebenarnya dicari ketika sebuah penolakan
-- dipertanyakan.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='mutate_claims_unchecked';
  if src is null then raise exception 'rc_private.mutate_claims_unchecked tidak ditemukan.'; end if;

  -- Dicari daftar LENGKAPnya, bukan sepotong. Pasangan 'reject_approval','reject_release'
  -- juga muncul pada baris jejak approved_at dan approved_by, sehingga pencarian sepotong
  -- akan menjawab "masih ada" meski kewajibannya sudah dicabut.
  if position($q$if p_action in('reject_approval','reject_release','reject_claim','reject_clearing','hold','unhold','expire') and btrim$q$ in src) = 0 then
    raise notice 'Alasan sudah tidak diwajibkan untuk approval; dilewati.'; return; end if;

  baru := replace(src,
    $q$if p_action in('reject_approval','reject_release','reject_claim','reject_clearing','hold','unhold','expire') and btrim$q$,
    $q$if p_action in('reject_release','reject_claim','reject_clearing','hold','unhold','expire') and btrim$q$);
  if baru = src then raise exception 'Pola kewajiban alasan tidak ditemukan.'; end if;

  execute baru;
  raise notice 'reject_approval tidak lagi menuntut alasan.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text; v_uid uuid; v_doc text; v_ver bigint; v_status text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='rc_private' and p.proname='mutate_claims_unchecked';

  if position($q$if p_action in('reject_approval','reject_release','reject_claim','reject_clearing','hold','unhold','expire') and btrim$q$ in src) > 0 then
    raise exception 'GAGAL: approval masih menuntut alasan.'; end if;
  -- Tahap lain HARUS tetap menuntutnya.
  foreach v_status in array array['reject_release','reject_claim','reject_clearing','hold','expire'] loop
    if position(v_status in substr(src, position($q$and btrim(coalesce(p_reason,''))=''$q$ in src) - 220, 220)) = 0 then
      raise exception 'GAGAL: % kehilangan kewajiban alasannya.', v_status; end if;
  end loop;

  -- Dibuktikan dengan menolak sebuah dokumen TANPA alasan. Dikerjakan di dalam blok
  -- BEGIN/EXCEPTION tersendiri: blok itu membentuk sub-transaksi, sehingga perubahannya
  -- dibatalkan ketika keluar lewat exception - tanpa ikut membatalkan migration-nya.
  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;
  select no_doc, version_no into v_doc, v_ver from public.claims
   where status='submitted' and archived_at is null order by no_doc limit 1;

  if v_doc is null then
    raise notice 'Tidak ada dokumen submitted untuk diuji.';
  else
    begin
      set local role authenticated;
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
      perform public.rc_process_claims('reject_approval',
        jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)),
        gen_random_uuid(), '');
      reset role;

      select status into v_status from public.claims where no_doc=v_doc;
      if v_status <> 'not_yet' then
        raise exception 'GAGAL: penolakan tanpa alasan menghasilkan %.', v_status; end if;
      raise notice 'Penolakan tanpa alasan berhasil: % -> %', v_doc, v_status;
      raise exception 'BATALKAN_UJI';
    exception when others then
      reset role;
      if sqlerrm like 'GAGAL:%' then raise; end if;
      if sqlerrm <> 'BATALKAN_UJI' then
        raise exception 'GAGAL: penolakan tanpa alasan ditolak -> %', sqlerrm; end if;
    end;
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
