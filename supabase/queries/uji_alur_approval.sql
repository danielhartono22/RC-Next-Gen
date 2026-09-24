-- ==========================================================================================
-- UJI COBA (tidak menyimpan apa pun): alur submitted -> approved -> released dan penolakannya
-- ==========================================================================================
-- Dijalankan sebagai System Manager sungguhan lewat klaim JWT, supaya can_access, RLS dan
-- pemeriksaan hak akses benar-benar ikut diuji - bukan dilewati karena dijalankan sebagai
-- pemilik basis data.
--
-- Berkas ini SELALU berakhir dengan raise exception, sehingga seluruh perubahannya dibatalkan.
-- Jalankan: node scripts/apply-sql.mjs supabase/queries/uji_alur_approval.sql
-- ==========================================================================================
do $uji$
declare
  v_uid uuid; v_doc text; v_ver bigint; v_status text; v_by uuid; v_at timestamptz;
  v_hasil jsonb; v_batch text; v_riwayat int; v_log int;
  function_result jsonb;
begin
  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  select no_doc, version_no into v_doc, v_ver
    from public.claims where status='submitted' and archived_at is null
    order by no_doc limit 1;
  if v_doc is null then raise exception 'Tidak ada dokumen submitted untuk diuji.'; end if;
  raise notice 'Dokumen uji: % (versi %)', v_doc, v_ver;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);

  -- ---- 1. Release harus DITOLAK selama belum disetujui -----------------------------------
  begin
    v_hasil := public.rc_process_claims('release',
      jsonb_build_array(jsonb_build_object('no_doc', v_doc, 'version_no', v_ver)),
      gen_random_uuid(), '');
    reset role;
    raise exception 'GAGAL: Release berhasil padahal dokumen belum disetujui.';
  exception when others then
    if sqlerrm like 'GAGAL:%' then raise; end if;
    raise notice 'OK  Release ditolak selama belum disetujui -> %', left(sqlerrm, 60);
  end;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);

  -- ---- 2. Approve ------------------------------------------------------------------------
  v_hasil := public.rc_process_claims('approve',
    jsonb_build_array(jsonb_build_object('no_doc', v_doc, 'version_no', v_ver)),
    gen_random_uuid(), '');
  reset role;

  select status, approved_by, approved_at, version_no, batch_upload
    into v_status, v_by, v_at, v_ver, v_batch
    from public.claims where no_doc = v_doc;
  if v_status <> 'approved' then raise exception 'GAGAL: status % bukan approved.', v_status; end if;
  if v_by is distinct from v_uid then raise exception 'GAGAL: approved_by tidak terisi pelakunya.'; end if;
  if v_at is null then raise exception 'GAGAL: approved_at kosong.'; end if;
  raise notice 'OK  Approve -> status %, oleh %, pada %', v_status, v_by, v_at;

  -- Riwayat dan Log Aktivitas terisi tanpa kode tambahan.
  select count(*) into v_riwayat from public.claim_status_history h
    join public.claims c on c.id = h.claim_id
   where c.no_doc = v_doc and h.action = 'approve';
  select count(*) into v_log from public.activity_logs a
    join public.claims c on c.id = a.entity_id
   where c.no_doc = v_doc and a.event_type = 'approve';
  if v_riwayat = 0 then raise exception 'GAGAL: riwayat status approve tidak tercatat.'; end if;
  if v_log = 0 then raise exception 'GAGAL: Log Aktivitas approve tidak tercatat.'; end if;
  raise notice 'OK  Riwayat % baris, Log Aktivitas % baris, batch %', v_riwayat, v_log, v_batch;

  -- ---- 3. Release sesudah disetujui harus BERHASIL ----------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
  v_hasil := public.rc_process_claims('release',
    jsonb_build_array(jsonb_build_object('no_doc', v_doc, 'version_no', v_ver)),
    gen_random_uuid(), '');
  reset role;

  select status, released_by, version_no into v_status, v_by, v_ver
    from public.claims where no_doc = v_doc;
  if v_status <> 'released' then raise exception 'GAGAL: status % bukan released.', v_status; end if;
  if v_by is distinct from v_uid then raise exception 'GAGAL: released_by tidak terisi.'; end if;
  raise notice 'OK  Release sesudah approve -> status %, oleh %', v_status, v_by;

  -- ---- 4. Penolakan approval mengembalikan ke Not Yet dan menghapus jejaknya --------------
  update public.claims set status='submitted', released_at=null, released_by=null,
         approved_at=now(), approved_by=v_uid, version_no=version_no+1
   where no_doc = v_doc;
  select version_no into v_ver from public.claims where no_doc = v_doc;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
  v_hasil := public.rc_process_claims('reject_approval',
    jsonb_build_array(jsonb_build_object('no_doc', v_doc, 'version_no', v_ver)),
    gen_random_uuid(), 'Uji coba penolakan');
  reset role;

  select status, approved_by, approved_at into v_status, v_by, v_at
    from public.claims where no_doc = v_doc;
  if v_status <> 'not_yet' then raise exception 'GAGAL: penolakan menghasilkan %, bukan not_yet.', v_status; end if;
  if v_by is not null or v_at is not null then
    raise exception 'GAGAL: jejak approval tidak dihapus saat ditolak.'; end if;
  raise notice 'OK  Reject -> kembali ke % dan jejak approval bersih', v_status;

  raise exception 'SELESAI: seluruh langkah lolos. Transaksi sengaja dibatalkan.';
end
$uji$;
