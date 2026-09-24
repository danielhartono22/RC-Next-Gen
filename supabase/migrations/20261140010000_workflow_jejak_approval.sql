-- ==========================================================================================
-- Jejak Approval ikut terbawa ke modul Release
-- ==========================================================================================
-- Permintaan pemilik: kolom jejak per tahap tersedia di Approval DAN di Release.
--
-- rc_legacy_workflow sudah mengumpulkan pelaku tiap tahap dari claim_status_history, dan pada
-- migration sebelumnya pelaku tahap 'approved' sudah ikut dikumpulkan - tetapi belum dikeluarkan
-- pada jawabannya, sehingga layar tidak punya apa-apa untuk ditampilkan. Dua field ditambahkan
-- di sini: siapa yang menyetujui, dan kapan.
--
-- Waktunya diambil dari claims.approved_at, bukan dari riwayat. Keduanya ditulis pada saat yang
-- sama, tetapi kolom pada dokumen adalah keadaan SEKARANG - kalau dokumen pernah ditolak lalu
-- disetujui lagi, yang berlaku memang yang terakhir, dan riwayat lengkapnya tetap ada di tab
-- History.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='rc_legacy_workflow';
  if src is null then raise exception 'public.rc_legacy_workflow tidak ditemukan.'; end if;

  if position($q$'approvedBy'$q$ in src) > 0 then
    raise notice 'rc_legacy_workflow sudah memuat jejak approval; dilewati.'; return; end if;

  if position($q$'releasedBy',coalesce(nama->>(pel.release_by::text),''),$q$ in src) = 0 then
    raise exception 'Pola jejak pelaku tidak ditemukan pada rc_legacy_workflow.'; end if;

  baru := replace(src,
    $q$'releasedBy',coalesce(nama->>(pel.release_by::text),''),$q$,
    $q$'approvedBy',coalesce(nama->>(pel.approve_by::text),''),$q$ || chr(10) ||
    $q$   'tglApprove',rc_private.legacy_ts(c.approved_at),$q$ || chr(10) ||
    $q$   'releasedBy',coalesce(nama->>(pel.release_by::text),''),$q$);

  execute baru;
  raise notice 'rc_legacy_workflow memuat approvedBy dan tglApprove.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_uid uuid; r jsonb; contoh jsonb; src text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='rc_legacy_workflow';
  if position($q$'approvedBy'$q$ in src) = 0 or position($q$'tglApprove'$q$ in src) = 0 then
    raise exception 'GAGAL: jejak approval tidak ikut pada jawaban workflow.'; end if;

  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
  r := public.rc_legacy_workflow();
  reset role;

  if (r->>'status') <> 'success' then raise exception 'GAGAL: workflow tidak berhasil.'; end if;

  -- Setiap antrean yang berisi harus memuat kedua field itu pada barisnya, bukan hanya pada
  -- definisi fungsinya.
  contoh := coalesce(r->'releaseData'->0, r->'claimFinData'->0, r->'clearingData'->0);
  if contoh is not null and not (contoh ? 'approvedBy' and contoh ? 'tglApprove') then
    raise exception 'GAGAL: baris antrean tidak memuat jejak approval.'; end if;

  raise notice 'Pemeriksaan lolos.';
exception when others then
  reset role; raise;
end
$periksa$;
