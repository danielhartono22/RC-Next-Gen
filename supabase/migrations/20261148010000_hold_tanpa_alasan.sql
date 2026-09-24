-- ==========================================================================================
-- Keputusan On Hold / Expired tidak lagi menuntut alasan baru
-- ==========================================================================================
-- Permintaan pemilik: "management hanya approve tidak perlu alasan" dan "alasan dibuat saat
-- proses penghangusan / expired / on hold".
--
-- Alasannya memang sudah ada. Tindakan 'hold' dan 'expire' menuntut alasan sejak semula, dan
-- alasan itulah yang tersimpan di claim_status_history serta ditampilkan pada kolom "Alasan
-- Terakhir" di tab On Hold & Expired. Menuntut alasan KEDUA pada saat pengesahan hanya
-- menghasilkan dua keterangan untuk satu peristiwa - dan yang kedua hampir pasti mengulang yang
-- pertama, atau lebih buruk, diisi seadanya supaya tombolnya mau ditekan.
--
-- Yang dicabut hanya kewajibannya pada approve_hold dan reject_hold. 'hold' dan 'expire' TETAP
-- menuntut alasan: di sanalah keterangannya lahir, dan tanpa itu tab ini kehilangan isi kolom
-- yang justru menjadi dasar keputusannya.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $mig$
declare src text; baru text;
  lama text := $p$if p_action in('reject_release','reject_claim','reject_clearing','hold','unhold','expire','approve_hold','reject_hold') and btrim$p$;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='mutate_claims_unchecked';
  if src is null then raise exception 'rc_private.mutate_claims_unchecked tidak ditemukan.'; end if;

  if position(lama in src) = 0 then
    raise notice 'Keputusan hold sudah tidak menuntut alasan; dilewati.'; return; end if;

  baru := replace(src, lama,
    $p$if p_action in('reject_release','reject_claim','reject_clearing','hold','unhold','expire') and btrim$p$);
  execute baru;
  raise notice 'approve_hold dan reject_hold tidak lagi menuntut alasan.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text; v_uid uuid; v_doc text; v_ver bigint; v_status text; v_asal text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='rc_private' and p.proname='mutate_claims_unchecked';

  if position($q$'expire','approve_hold','reject_hold') and btrim$q$ in src) > 0 then
    raise exception 'GAGAL: keputusan hold masih menuntut alasan.'; end if;
  -- 'hold' dan 'expire' HARUS tetap menuntutnya: di sanalah keterangannya lahir.
  if position($q$'reject_clearing','hold','unhold','expire') and btrim(coalesce(p_reason,''))=''$q$ in src) = 0 then
    raise exception 'GAGAL: hold atau expire kehilangan kewajiban alasannya.'; end if;

  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;
  select no_doc, version_no, previous_status into v_doc, v_ver, v_asal
    from public.claims where status='on_hold' and archived_at is null
      and previous_status is not null and hold_approved_at is null
    order by no_doc limit 1;

  if v_doc is null then
    raise notice 'Tidak ada dokumen On Hold untuk diuji.';
  else
    begin
      set local role authenticated;
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text,'role','authenticated')::text, true);

      -- Mengesahkan TANPA alasan harus berhasil.
      perform public.rc_process_claims('approve_hold',
        jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)),
        gen_random_uuid(), '');
      select status, version_no into v_status, v_ver from public.claims where no_doc=v_doc;
      if v_status <> 'on_hold' then
        raise exception 'GAGAL: pengesahan mengubah status menjadi %.', v_status; end if;

      -- Membatalkan TANPA alasan juga harus berhasil, dan mengembalikan ke asalnya.
      perform public.rc_process_claims('reject_hold',
        jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)),
        gen_random_uuid(), '');
      select status into v_status from public.claims where no_doc=v_doc;
      reset role;
      if v_status <> v_asal then
        raise exception 'GAGAL: pembatalan mengembalikan ke %, seharusnya %.', v_status, v_asal; end if;

      raise notice 'Sahkan dan batalkan tanpa alasan berhasil: % -> %', v_doc, v_status;
      raise exception 'BATALKAN_UJI';
    exception when others then
      reset role;
      if sqlerrm like 'GAGAL:%' then raise; end if;
      if sqlerrm <> 'BATALKAN_UJI' then
        raise exception 'GAGAL: keputusan tanpa alasan ditolak -> %', sqlerrm; end if;
    end;
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
