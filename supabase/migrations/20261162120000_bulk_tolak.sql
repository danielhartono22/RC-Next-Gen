-- ==========================================================================================
-- Bulk Process: tombol "Tolak" mengembalikan dokumen Rebate ke depot
-- ==========================================================================================
-- Diminta pemilik, 5 Oktober 2026: "Bulk Process: buat button untuk tolak". Ditetapkan
-- pilihan (a): dokumen yang ditolak KEMBALI KE DEPOT (Not Yet) dari tahap mana pun -
-- Approved, Released atau Claimed - supaya depot memperbaiki dan mengajukan ulang, dan
-- dokumennya pasti keluar dari antrean Bulk. Alasan wajib.
--
-- Aksi baru 'reject_bulk' pada rc_private.mutate_claims_unchecked, jalur yang dipakai
-- seluruh perpindahan status lain:
--   * hak dan tab sama dengan Bulk Process: izin bulk_process, tab bulk.rebate
--   * hanya dokumen Rebate di tahap Approved / Released / Claimed
--   * alasan wajib, tercatat di riwayat status dan log aktivitas
--   * jejak pengajuan, approval, release dan claim dikosongkan beserta nomor batch-nya -
--     persis keadaan dokumen yang dikembalikan ke depot oleh Reject di Release
--   * tidak mengirim email (antrean email hanya bereaksi pada submit/hold/expire/approve/
--     clearing) dan tidak menerbitkan nomor batch baru
--
-- Ditambal pada definisi yang hidup dengan penjaga: MD5 pra-citra sama di dev dan prod pada
-- 5 Oktober 2026, dan setiap pola harus ditemukan tepat sebanyak yang diharapkan.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $tambal$
declare src text; baru text; md5_kini text;
begin
  src := pg_get_functiondef('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)'::regprocedure);
  if src ~ 'reject_bulk' then raise notice 'mutate_claims_unchecked sudah mengenal reject_bulk.'; return; end if;
  md5_kini := md5(src);
  if md5_kini <> '83d94c8b4959f3858ec9fc43fd596eaa' then
    raise exception 'DITOLAK: definisi mutate_claims_unchecked berbeda dari yang diukur (md5 %).', md5_kini; end if;

  baru := src;
  -- Ganti tepat n kemunculan; berhenti bila jumlahnya lain.
  create temp table _pola(lama text, ganti text, n int) on commit drop;
  insert into _pola values
    -- daftar aksi yang dikenal
    ($p$'approve','reject_approval','approve_hold','reject_hold','expire_claim_process')$p$,
     $p$'approve','reject_approval','approve_hold','reject_hold','expire_claim_process','reject_bulk')$p$, 1),
    -- izin
    ($p$when p_action='bulk_rebate' then 'bulk_process' else 'process_claim' end;$p$,
     $p$when p_action in('bulk_rebate','reject_bulk') then 'bulk_process' else 'process_claim' end;$p$, 1),
    -- tab
    ($p$if p_action='bulk_rebate' then perform rc_private.require_tab('bulk.rebate');end if;$p$,
     $p$if p_action in('bulk_rebate','reject_bulk') then perform rc_private.require_tab('bulk.rebate');end if;$p$, 1),
    -- alasan wajib
    ($p$if p_action in('reject_release','reject_claim','reject_clearing','hold','unhold','expire','expire_claim_process') and btrim$p$,
     $p$if p_action in('reject_release','reject_claim','reject_clearing','hold','unhold','expire','expire_claim_process','reject_bulk') and btrim$p$, 1),
    -- jejak pengajuan dan approval dikosongkan
    ($p$in('reject_release','reject_approval') then null$p$,
     $p$in('reject_release','reject_approval','reject_bulk') then null$p$, 2),
    ($p$in('reject_approval','reject_release') then null$p$,
     $p$in('reject_approval','reject_release','reject_bulk') then null$p$, 2),
    -- jejak release dan claim dikosongkan
    ($p$when p_action='reject_claim' then null$p$,
     $p$when p_action in('reject_claim','reject_bulk') then null$p$, 3),
    ($p$when p_action='reject_clearing' then null$p$,
     $p$when p_action in('reject_clearing','reject_bulk') then null$p$, 3),
    -- batch unggahan dikosongkan
    ($p$when p_action='reject_release' then null else batch_upload$p$,
     $p$when p_action in('reject_release','reject_bulk') then null else batch_upload$p$, 1);

  declare r record; n int;
  begin
    for r in select * from _pola loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> r.n then
        raise exception 'mutate_claims_unchecked: pola "%" ditemukan % kali, diharapkan %.', left(r.lama, 70), n, r.n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
  end;

  -- Transisi: Rebate di Approved / Released / Claimed kembali ke Not Yet.
  -- Definisi fungsi dapat tersimpan dengan akhir baris CRLF, maka \r? di setiap baris.
  if (select count(*) from regexp_matches(baru, $r$\r?\n\s*target:='done';\r?\n\s*end if;\r?\n\s*if target is null$r$, 'g')) <> 1 then
    raise exception 'mutate_claims_unchecked: akhir cabang bulk_rebate tidak dikenali.'; end if;
  baru := regexp_replace(baru, $r$(\r?\n\s*target:='done';)(\r?\n\s*end if;\r?\n\s*if target is null)$r$,
    E'\\1\n elsif p_action=''reject_bulk'' and c.status in(''approved'',''released'',''claimed'') then\n'
    || E'  -- Tolak dari Bulk Process: kembali ke depot (20261162120000).\n'
    || E'  if jenis<>''rebate'' then raise exception ''Dokumen % bukan campaign Rebate'',c.no_doc; end if;\n'
    || E'  target:=''not_yet'';\\2');

  execute baru;
  raise notice 'mutate_claims_unchecked mengenal reject_bulk.';
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan di dalam subtransaksi yang dibatalkan: tidak ada data yang tertinggal.
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; v_doc record; h jsonb; v_akhir record; v_tanpa_alasan text; v_non_rebate text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' order by user_code limit 1;
  select c.id, c.no_doc, c.version_no, c.status into v_doc from public.claims c
   where c.status in ('approved','released','claimed') and c.pending_approval is null and c.archived_at is null
   order by case c.status when 'claimed' then 0 when 'released' then 1 else 2 end, c.no_doc limit 1;
  if v_sm is null or v_doc.id is null then raise notice 'Tidak ada data untuk menguji reject_bulk.'; return; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  begin
    -- Tanpa alasan: ditolak.
    begin
      perform rc_private.mutate_claims_unchecked('reject_bulk',
        jsonb_build_array(jsonb_build_object('no_doc', v_doc.no_doc, 'version_no', v_doc.version_no)), gen_random_uuid(), '');
    exception when others then v_tanpa_alasan := sqlerrm; end;
    -- Dokumen non-Rebate: ditolak.
    begin
      update public.claims set cashback_type_override = 'Transfer' where id = v_doc.id;
      perform rc_private.mutate_claims_unchecked('reject_bulk',
        jsonb_build_array(jsonb_build_object('no_doc', v_doc.no_doc, 'version_no', v_doc.version_no)), gen_random_uuid(), 'uji');
    exception when others then v_non_rebate := sqlerrm; end;
    -- Dokumen Rebate: kembali ke depot.
    update public.claims set cashback_type_override = 'Rebate' where id = v_doc.id;
    h := rc_private.mutate_claims_unchecked('reject_bulk',
      jsonb_build_array(jsonb_build_object('no_doc', v_doc.no_doc, 'version_no', v_doc.version_no)), gen_random_uuid(), 'Uji migrasi: tolak dari Bulk');
    select c.status, c.uploaded_at, c.submitted_by, c.approved_at, c.released_at, c.claimed_at,
           c.batch_upload, c.batch_release, c.batch_claim,
           (select h2.action || '/' || h2.from_status || '>' || h2.to_status from public.claim_status_history h2
             where h2.claim_id = c.id order by h2.id desc limit 1) as riwayat
      into v_akhir from public.claims c where c.id = v_doc.id;
    raise exception 'UJI_SELESAI';
  exception when raise_exception then
    if sqlerrm <> 'UJI_SELESAI' then raise; end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  if v_tanpa_alasan is null or v_tanpa_alasan !~ 'Reason required' then
    raise exception 'GAGAL: tolak tanpa alasan tidak ditolak (%).', v_tanpa_alasan; end if;
  if v_non_rebate is null or v_non_rebate !~ 'bukan campaign Rebate' then
    raise exception 'GAGAL: dokumen non-Rebate tidak ditolak (%).', v_non_rebate; end if;
  if v_akhir.status <> 'not_yet' or v_akhir.uploaded_at is not null or v_akhir.submitted_by is not null
     or v_akhir.approved_at is not null or v_akhir.released_at is not null or v_akhir.claimed_at is not null
     or v_akhir.batch_upload is not null or v_akhir.batch_release is not null or v_akhir.batch_claim is not null then
    raise exception 'GAGAL: dokumen % (%) tidak kembali bersih ke depot: %', v_doc.no_doc, v_doc.status, row_to_json(v_akhir); end if;
  if v_akhir.riwayat <> 'reject_bulk/' || v_doc.status || '>not_yet' then
    raise exception 'GAGAL: riwayat status tidak tercatat benar: %', v_akhir.riwayat; end if;
  if (select status from public.claims where id = v_doc.id) <> v_doc.status then
    raise exception 'GAGAL: uji meninggalkan perubahan pada dokumen %.', v_doc.no_doc; end if;
  raise notice 'reject_bulk teruji pada % (%): kembali ke Not Yet, jejak bersih, data dipulihkan.', v_doc.no_doc, v_doc.status;
end
$uji$;
