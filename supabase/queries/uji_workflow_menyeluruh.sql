-- ==========================================================================================
-- UJI MENYELURUH (tidak menyimpan apa pun): apakah alur berjalan sesuai yang seharusnya?
-- ==========================================================================================
-- Menempuh SELURUH rantai sebagai System Manager sungguhan lewat klaim JWT, sehingga can_access,
-- RLS dan pemeriksaan hak akses benar-benar ikut diuji.
--
--   not_yet -> submitted -> approved -> released -> claimed -> done
--
-- beserta setiap penolakannya, dan setiap pintu yang harus TERTUTUP di tiap tahap. Berkas ini
-- selalu berakhir dengan raise exception, jadi seluruh perubahannya dibatalkan.
--
-- Jalankan: node scripts/apply-sql.mjs supabase/queries/uji_workflow_menyeluruh.sql
-- ==========================================================================================
do $uji$
declare
  v_uid uuid; v_doc text; v_ver bigint; v_status text; h jsonb; n int;
  v_lolos int := 0; v_pesan text;

  procedure_note text;
begin
  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  -- Dokumen uji: yang paling awal berstatus not_yet, supaya seluruh rantai dapat ditempuh.
  select no_doc, version_no into v_doc, v_ver
    from public.claims c
    join public.campaigns ca on ca.id = c.campaign_id
   where c.status='not_yet' and c.archived_at is null
     and lower(btrim(coalesce(ca.cashback_type,''))) not in ('rebate','ra07','ra7')
   order by c.no_doc limit 1;
  if v_doc is null then raise exception 'Tidak ada dokumen not_yet non-Rebate untuk diuji.'; end if;
  raise notice 'Dokumen uji: %', v_doc;

  -- ---- Alat bantu: menjalankan satu tindakan sebagai pengguna sungguhan -------------------
  create temporary table if not exists _hasil(langkah text, hasil text) on commit drop;

  -- 1. RELEASE sebelum submit harus DITOLAK
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub',v_uid::text,'role','authenticated')::text, true);
    perform public.rc_process_claims('release',
      jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)), gen_random_uuid(), '');
    reset role;
    raise exception 'GAGAL: Release berhasil atas dokumen Not Yet.';
  exception when others then
    reset role;
    if sqlerrm like 'GAGAL:%' then raise; end if;
    v_lolos := v_lolos + 1;
    raise notice 'OK  1. Release atas Not Yet ditolak';
  end;

  -- 2. APPROVE sebelum submit harus DITOLAK
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub',v_uid::text,'role','authenticated')::text, true);
    perform public.rc_process_claims('approve',
      jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)), gen_random_uuid(), '');
    reset role;
    raise exception 'GAGAL: Approve berhasil atas dokumen Not Yet.';
  exception when others then
    reset role;
    if sqlerrm like 'GAGAL:%' then raise; end if;
    v_lolos := v_lolos + 1;
    raise notice 'OK  2. Approve atas Not Yet ditolak';
  end;

  -- 3. SUBMIT -> submitted, dan muncul di antrean approval
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',v_uid::text,'role','authenticated')::text, true);
  perform public.rc_process_claims('submit',
    jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)), gen_random_uuid(), '');
  reset role;
  select status, version_no into v_status, v_ver from public.claims where no_doc=v_doc;
  if v_status <> 'submitted' then raise exception 'GAGAL: submit menghasilkan %.', v_status; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  3. Submit -> submitted';

  select count(*) into n from rc_private.approval_rows where no_doc = v_doc;
  if n <> 1 then raise exception 'GAGAL: dokumen tidak muncul di antrean approval.'; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  4. Muncul di antrean Management of Approval';

  -- 5. RELEASE sebelum approve harus DITOLAK
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub',v_uid::text,'role','authenticated')::text, true);
    perform public.rc_process_claims('release',
      jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)), gen_random_uuid(), '');
    reset role;
    raise exception 'GAGAL: Release berhasil sebelum approve.';
  exception when others then
    reset role;
    if sqlerrm like 'GAGAL:%' then raise; end if;
    v_lolos := v_lolos + 1;
    raise notice 'OK  5. Release sebelum approve ditolak';
  end;

  -- 6. APPROVE -> approved, jejak terisi, dan HILANG dari antrean approval
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',v_uid::text,'role','authenticated')::text, true);
  perform public.rc_process_claims('approve',
    jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)), gen_random_uuid(), '');
  reset role;
  select status, version_no into v_status, v_ver from public.claims where no_doc=v_doc;
  if v_status <> 'approved' then raise exception 'GAGAL: approve menghasilkan %.', v_status; end if;
  if not exists (select 1 from public.claims where no_doc=v_doc
                  and approved_by = v_uid and approved_at is not null) then
    raise exception 'GAGAL: jejak approval tidak terisi.'; end if;
  select count(*) into n from rc_private.approval_rows where no_doc = v_doc;
  if n <> 0 then raise exception 'GAGAL: dokumen yang sudah disetujui masih di antrean approval.'; end if;
  v_lolos := v_lolos + 2;
  raise notice 'OK  6. Approve -> approved, jejak terisi, keluar dari antrean';

  -- 7. Muncul di antrean RELEASE
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',v_uid::text,'role','authenticated')::text, true);
  h := public.rc_legacy_workflow();
  reset role;
  if not exists (select 1 from jsonb_array_elements(h->'releaseData') v where v->>'noDoc' = v_doc) then
    raise exception 'GAGAL: dokumen approved tidak muncul di antrean Release.'; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  7. Muncul di antrean Release';

  -- 8. CLEARING melompati tahap harus DITOLAK
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub',v_uid::text,'role','authenticated')::text, true);
    perform public.rc_process_claims('clearing',
      jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)), gen_random_uuid(), '');
    reset role;
    raise exception 'GAGAL: Clearing berhasil melompati Release dan Claim.';
  exception when others then
    reset role;
    if sqlerrm like 'GAGAL:%' then raise; end if;
    v_lolos := v_lolos + 1;
    raise notice 'OK  8. Clearing yang melompati tahap ditolak';
  end;

  -- 9..11 RELEASE -> CLAIM -> CLEARING berurutan
  foreach v_pesan in array array['release','claim','clearing'] loop
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub',v_uid::text,'role','authenticated')::text, true);
    perform public.rc_process_claims(v_pesan,
      jsonb_build_array(jsonb_build_object('no_doc',v_doc,'version_no',v_ver)), gen_random_uuid(), '');
    reset role;
    select status, version_no into v_status, v_ver from public.claims where no_doc=v_doc;
    v_lolos := v_lolos + 1;
    raise notice 'OK  %. % -> %', 8 + v_lolos - v_lolos + 0, v_pesan, v_status;
  end loop;
  if v_status <> 'done' then raise exception 'GAGAL: rantai berakhir di %, bukan done.', v_status; end if;

  -- 12. Jejak lengkap tiap tahap terisi pelakunya
  if not exists (select 1 from public.claims where no_doc=v_doc
                  and submitted_by is not null and approved_by is not null
                  and released_by is not null and claimed_by is not null and cleared_by is not null) then
    raise exception 'GAGAL: ada tahap tanpa jejak pelaku.'; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  12. Jejak pelaku lengkap di kelima tahap';

  -- 13. Riwayat dan Log Aktivitas mencatat seluruh tahap
  select count(*) into n from public.claim_status_history h2
    join public.claims c on c.id = h2.claim_id
   where c.no_doc = v_doc and h2.action in ('submit','approve','release','claim','clearing');
  if n < 5 then raise exception 'GAGAL: riwayat hanya % baris dari 5 tahap.', n; end if;
  select count(*) into n from public.activity_logs a
    join public.claims c on c.id = a.entity_id
   where c.no_doc = v_doc and a.event_type in ('submit','approve','release','claim','clearing');
  if n < 5 then raise exception 'GAGAL: Log Aktivitas hanya % baris dari 5 tahap.', n; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  13. Riwayat dan Log Aktivitas lengkap';

  raise exception 'SELESAI: % langkah lolos. Transaksi sengaja dibatalkan.', v_lolos;
end
$uji$;
