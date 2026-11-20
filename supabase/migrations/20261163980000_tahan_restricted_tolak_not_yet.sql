-- ==========================================================================================
-- "Pindahkan ke Restricted" (ditahan 7 hari) dan tolak langsung ke Not Yet dari Claim Process
-- ==========================================================================================
-- Pemilik, 14 November 2026:
--   "kembali ke not yet jadi masuk ke restricted aja dan namanya jangan kembalikan ke not yet.
--    'Pindahkan ke Restricted', dan akan tertahan seminggu di restricted tidak mengikuti aturan
--    upload debtor, di hari ke-8 baru mengikuti aturan upload debtor. dan selama seminggu itu bisa
--    dipindahkan dengan 'Pindahkan ke open'."
--   "saya mau dibuatkan bypass tolak langsung ke not yet dari claim process, baik clearing ataupun
--    claim to finance ... pop up tolak ke 'release' atau 'Not Yet'"
--
-- A. Pindahkan ke Restricted (dulu "Kembalikan ke Not Yet", rc_clearing_return)
--    - Dulu dokumen yang dikembalikan tidak pernah ditawarkan lagi sampai OSC menawarkannya ulang.
--      Sekarang ia DITAHAN 7 hari: hari pemindahan = hari ke-1, sampai hari ke-7 tidak mengikuti
--      aturan debtor (tidak ditawarkan walau tokonya lunas); pada hari ke-8 kembali dinilai
--      dengan data debtor yang berlaku (rc_private.zdage_nilai_baru, 20261163950000).
--    - Selama ditahan, dokumen dapat dikembalikan dengan "Pindahkan ke Open" (rc_restricted_pindah)
--      oleh pemegang tab Restricted: masa tahannya diakhiri dan dokumen langsung dinilai lagi -
--      toko lunas kembali ke Open sebagai toko lunas (batas 7 hari baru). Dokumen Restricted lain
--      tetap hanya dapat dipindah pemegang Restricted (Editor), seperti sebelumnya.
--    - Tab Restricted: alasan "Ditahan sementara" beserta tanggal akhirnya.
-- B. Tolak langsung ke Not Yet (rc_private.mutate_claims_unchecked)
--    - Aksi baru reject_claim_not_yet (Claim to Finance, status Released) dan
--      reject_clearing_not_yet (Clearing, status Claimed): dokumen langsung kembali ke depot
--      sebagai Not Yet, dengan pembersihan yang sama seperti tolak dari Bulk Process (tanggal,
--      pelaku dan batch tahap sebelumnya dikosongkan). Hak dan tab sama dengan tolak biasa.
--    - Dokumen yang kembali ke Not Yet lewat tolak apa pun langsung dinilai ulang dengan data
--      debtor yang berlaku, supaya toko lunas kembali muncul di Open tanpa upload ulang.
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- A1. Masa tahan ----------------------------------------------------------------------------
-- Hari terakhir masa tahan (hari ke-7), atau null bila dokumen tidak sedang ditahan.
create or replace function rc_private.zdage_ditahan_sampai(p_claim uuid)
returns date language sql stable security definer set search_path to '' as $f$
  select case when a.status = 'returned' and (now() at time zone 'Asia/Jakarta')::date < (a.acted_at at time zone 'Asia/Jakarta')::date + 7
              then (a.acted_at at time zone 'Asia/Jakarta')::date + 6 end
    from (select o.status, o.acted_at from public.rc_clearing_offers o where o.claim_id = p_claim order by o.created_at desc limit 1) a;
$f$;
revoke all on function rc_private.zdage_ditahan_sampai(uuid) from public, anon, authenticated;

do $tambal$
declare src text;
begin
  -- Penilaian: "dikembalikan" hanya menahan selama 7 hari.
  src := replace(pg_get_functiondef('rc_private.zdage_evaluasi(uuid,text[],numeric,text,uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163980000' then
    src := pg_temp.ganti(src, $p$when ak.id is null and akhir.status = 'returned' then 'SUPPRESSED'$p$,
      $p$when ak.id is null and akhir.status = 'returned' and akhir.ditahan /* 20261163980000: ditahan 7 hari saja */ then 'SUPPRESSED'$p$, 1, 'evaluasi suppressed');
    src := pg_temp.ganti(src, $p$'alasanKembali', case when akhir.status = 'returned' then akhir.return_reason end,$p$,
      $p$'alasanKembali', case when akhir.status = 'returned' and akhir.ditahan then akhir.return_reason end,$p$, 1, 'evaluasi alasan');
    src := pg_temp.ganti(src, $p$(select o.status, o.return_reason from public.rc_clearing_offers o$p$,
      $p$(select o.status, o.return_reason, (now() at time zone 'Asia/Jakarta')::date < (o.acted_at at time zone 'Asia/Jakarta')::date + 7 ditahan from public.rc_clearing_offers o$p$, 1, 'evaluasi akhir');
    execute src;
  end if;

  -- Daftar OSC (Upload Debtor): hanya dokumen yang masih dalam masa tahan.
  src := replace(pg_get_functiondef('public.rc_clearing_dikembalikan()'::regprocedure), E'\r', '');
  if src !~ '20261163980000' then
    src := pg_temp.ganti(src, $p$   where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null), '[]'::jsonb));$p$,
      $p$   where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
     and rc_private.zdage_ditahan_sampai(c.id) is not null /* 20261163980000: masa tahan 7 hari */), '[]'::jsonb));$p$, 1, 'daftar ditahan');
    execute src;
  end if;

  -- Penilaian otomatis: dokumen yang masa tahannya selesai dinilai lagi.
  src := replace(pg_get_functiondef('rc_private.zdage_nilai_baru()'::regprocedure), E'\r', '');
  if src !~ '20261163980000' then
    src := pg_temp.ganti(src, $p$            or h.alasan->>'bulanSo' is distinct from$p$,
      $p$            or (h.hasil = 'SUPPRESSED' and rc_private.zdage_ditahan_sampai(c.id) is null) /* 20261163980000: masa tahan 7 hari selesai */
            or h.alasan->>'bulanSo' is distinct from$p$, 1, 'nilai baru tahan');
    execute src;
  end if;
end $tambal$;

-- Alasan di tab Restricted.
create or replace function rc_private.restricted_info(p_claim uuid, p_customer uuid, p_depot uuid)
returns table(label text, rinci jsonb, dinilai timestamp with time zone)
language sql stable security definer set search_path to '' as $f$
  select case
           when b.id is not null then 'Bad Debt'
           when akhir.sampai is not null then 'Ditahan sementara' -- 20261163980000 (dulu "Dikembalikan depot", tanpa batas waktu)
           when h.hasil = 'GAGAL' then 'Belum lunas'
           when h.hasil = 'PERIODE_SALAH' then 'Periode salah'
           when h.hasil = 'TANPA_MASTER' or p_customer is null then 'Tanpa Customer Master'
           when h.hasil in ('LUNAS','SUDAH_DITAWARKAN') then 'Lunas, menunggu Upload Debtor berikutnya'
           when dd.depot_id is not null then 'Belum dinilai (menunggu Upload Debtor berikutnya)'
           else 'Belum ada data debtor depot' end,
         coalesce(h.alasan, '{}'::jsonb) || jsonb_build_object('badDebt', b.reason,
           'alasanKembali', case when akhir.sampai is not null then akhir.return_reason end,
           'ditahan', akhir.sampai is not null,
           'ditahanSampai', to_char(akhir.sampai, 'DD-Mon-YYYY'), 'ikutDebtorMulai', to_char(akhir.sampai + 1, 'DD-Mon-YYYY')),
         h.dinilai_pada
    from (select 1) x
    left join public.rc_bad_debt_remarks b on b.customer_id = p_customer and b.status = 'active'
    left join public.rc_zdage_hasil h on h.claim_id = p_claim
    left join public.rc_zdage_depot_data dd on dd.depot_id = p_depot
    left join lateral (select o.return_reason,
                              case when o.status = 'returned' and (now() at time zone 'Asia/Jakarta')::date < (o.acted_at at time zone 'Asia/Jakarta')::date + 7
                                   then (o.acted_at at time zone 'Asia/Jakarta')::date + 6 end sampai
                         from public.rc_clearing_offers o where o.claim_id = p_claim
                        order by o.created_at desc limit 1) akhir on true;
$f$;

-- ---- A2. Pindahkan ke Restricted ---------------------------------------------------------------
create or replace function public.rc_clearing_return(p_no_docs text[], p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v_alasan text := left(btrim(coalesce(p_reason, '')), 300); v_docs text[]; n integer; v_gagal text[];
  v_hari date := (now() at time zone 'Asia/Jakarta')::date;
begin
  perform rc_private.require_tab('upload.open');
  if length(v_alasan) < 3 then raise exception 'Alasan memindahkan ke Restricted wajib diisi'; end if;
  v_docs := array(select distinct upper(btrim(x)) from unnest(coalesce(p_no_docs, '{}')) x where btrim(x) <> '');
  if coalesce(array_length(v_docs, 1), 0) = 0 then raise exception 'Pilih dokumen lebih dulu'; end if;
  if array_length(v_docs, 1) > 500 then raise exception 'Maksimal 500 dokumen sekali proses'; end if;

  with t as (
    update public.rc_clearing_offers o set status = 'returned', return_reason = v_alasan, acted_by = auth.uid(), acted_at = now()
      from public.claims c
     where c.id = o.claim_id and upper(c.no_doc) = any(v_docs) and o.status in ('offered','overdue')
       and c.status = 'not_yet' and c.archived_at is null and rc_private.can_access(c.depot_id, 'upload_claim')
    returning o.claim_id, c.no_doc),
  h as (
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    select t.claim_id, auth.uid(), 'not_yet', 'not_yet', 'zdage_return',
           left('Dipindahkan ke Restricted, ditahan sampai ' || to_char(v_hari + 6, 'DD-Mon-YYYY') || ': ' || v_alasan, 300)
      from t returning claim_id)
  select count(*), array(select d from unnest(v_docs) d where d not in (select upper(t2.no_doc) from t t2)) into n, v_gagal from t;

  if n > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'zdage_return', jsonb_build_object(
      'detail', 'Pindahkan ke Restricted (ditahan sampai ' || to_char(v_hari + 6, 'DD-Mon-YYYY') || '): ' || n || ' dokumen',
      'jumlah', n, 'alasan', v_alasan, 'ditahanSampai', to_char(v_hari + 6, 'DD-Mon-YYYY')), 'upload', 'open', 'open');
    -- Hasil penilaian dokumen itu langsung menjadi "ditahan", tanpa menunggu jadwal.
    begin
      perform rc_private.zdage_nilai_baru();
    exception when others then
      insert into public.activity_logs(actor_id, event_type, details)
      values (auth.uid(), 'zdage_nilai_gagal', jsonb_build_object('sebab', left(sqlerrm, 300)));
    end;
  end if;
  return jsonb_build_object('status', 'success', 'berhasil', n, 'gagal', to_jsonb(v_gagal),
    'ditahanSampai', to_char(v_hari + 6, 'DD-Mon-YYYY'),
    'message', n || ' dokumen dipindahkan ke Restricted dan ditahan sampai ' || to_char(v_hari + 6, 'DD-Mon-YYYY')
      || '; mulai ' || to_char(v_hari + 7, 'DD-Mon-YYYY') || ' kembali mengikuti aturan debtor'
      || case when coalesce(array_length(v_gagal, 1), 0) > 0 then '. ' || array_length(v_gagal, 1) || ' dokumen tidak sedang ditawarkan di Open' else '' end);
end $f$;

-- ---- A3. Pindahkan ke Open ---------------------------------------------------------------------
create or replace function public.rc_restricted_pindah(p_no_docs text[], p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v_alasan text := left(btrim(coalesce(p_reason, '')), 300); v_docs text[]; v_gagal text[];
  v_editor boolean := rc_private.can_tab('upload.restrictedEdit');
  v_awal uuid[]; v_tahan uuid[]; n_lepas integer := 0; n_pindah integer := 0; n integer := 0; v_lunas text[];
begin
  -- Dokumen yang sedang ditahan boleh dikembalikan pemegang tab Restricted; selain itu hanya Editor.
  if not v_editor then perform rc_private.require_tab('upload.restricted'); end if;
  if length(v_alasan) < 3 then raise exception 'Alasan memindahkan ke Open wajib diisi'; end if;
  v_docs := array(select distinct upper(btrim(x)) from unnest(coalesce(p_no_docs, '{}')) x where btrim(x) <> '');
  if coalesce(array_length(v_docs, 1), 0) = 0 then raise exception 'Pilih dokumen lebih dulu'; end if;
  if array_length(v_docs, 1) > 500 then raise exception 'Maksimal 500 dokumen sekali proses'; end if;

  -- Dokumen terpilih yang boleh disentuh dan saat ini tidak di Open.
  select coalesce(array_agg(c.id), '{}'), coalesce(array_agg(c.id) filter (where rc_private.zdage_ditahan_sampai(c.id) is not null), '{}')
    into v_awal, v_tahan
    from public.claims c
   where upper(c.no_doc) = any(v_docs) and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
     and rc_private.can_access(c.depot_id, 'upload_claim')
     and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = c.id and o.status in ('offered','overdue'));

  -- 1. Dokumen yang ditahan: masa tahannya diakhiri, lalu langsung dinilai dengan aturan debtor.
  if cardinality(v_tahan) > 0 then
    with t as (
      update public.rc_clearing_offers o set status = 'cancelled', acted_by = auth.uid(), acted_at = now()
       where o.id in (select distinct on (x.claim_id) x.id from public.rc_clearing_offers x where x.claim_id = any(v_tahan) order by x.claim_id, x.created_at desc)
         and o.status = 'returned'
      returning o.claim_id),
    h as (
      insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
      select t.claim_id, auth.uid(), 'not_yet', 'not_yet', 'zdage_lepas_tahan', left('Masa tahan diakhiri (Pindahkan ke Open): ' || v_alasan, 300)
        from t returning claim_id)
    select count(*) into n_lepas from t;
    perform rc_private.zdage_nilai_baru();
  end if;

  -- 2. Editor: dokumen Restricted lain (dan dokumen lepas tahan yang ternyata belum lunas) dipindah berlabel Restricted.
  if v_editor then
    with kandidat as (
      select c.id from public.claims c
       where c.id = any(v_awal) and c.customer_id is not null
         and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = c.id and o.status in ('offered','overdue'))),
    baru as (
      insert into public.rc_clearing_offers(claim_id, upload_id, result, reason, offered_at, offered_by, deadline_at, status)
      select k.id, null, 'RESTRICTED', jsonb_build_object('alasanPindah', v_alasan), now(), auth.uid(), null, 'offered'
        from kandidat k
      on conflict (claim_id) where status in ('offered','overdue') do nothing
      returning claim_id),
    h as (
      insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
      select b.claim_id, auth.uid(), 'not_yet', 'not_yet', 'restricted_open', left('Dipindah dari Restricted ke Open: ' || v_alasan, 300)
        from baru b returning claim_id)
    select count(*) into n_pindah from baru;
  end if;

  -- Hasil: dokumen terpilih yang sekarang ada di Open.
  select count(*), coalesce(array_agg(upper(c.no_doc)) filter (where o.result <> 'RESTRICTED'), '{}')
    into n, v_lunas
    from public.claims c join public.rc_clearing_offers o on o.claim_id = c.id and o.status in ('offered','overdue')
   where c.id = any(v_awal);
  v_gagal := array(select d from unnest(v_docs) d where d not in (
    select upper(c.no_doc) from public.claims c join public.rc_clearing_offers o on o.claim_id = c.id and o.status in ('offered','overdue') where c.id = any(v_awal)));

  if n > 0 or n_lepas > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'restricted_open', jsonb_build_object(
      'detail', 'Pindahkan ke Open: ' || n || ' dokumen (' || (n - n_pindah) || ' toko lunas lepas tahan, ' || n_pindah || ' berlabel Restricted)',
      'jumlah', n, 'lepasTahan', n_lepas, 'berlabelRestricted', n_pindah, 'alasan', v_alasan), 'upload', 'restricted', 'restricted');
  end if;
  return jsonb_build_object('status', 'success', 'berhasil', n, 'gagal', to_jsonb(v_gagal), 'lunas', to_jsonb(v_lunas),
    'message', n || ' dokumen dipindahkan ke Open'
      || case when n_pindah > 0 then ' (' || n_pindah || ' berlabel Restricted)' else '' end
      || case when coalesce(array_length(v_gagal, 1), 0) > 0 then '; ' || array_length(v_gagal, 1) || ' dokumen tidak dapat dipindah'
              || case when not v_editor then ' (bukan dokumen yang sedang ditahan, atau tokonya belum lunas menurut data debtor)' else '' end else '' end || '.');
end $f$;

-- ---- B. Tolak langsung ke Not Yet --------------------------------------------------------------
do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)'::regprocedure), E'\r', '');
  if src !~ '20261163980000' then
    src := pg_temp.ganti(src, $p$'approve_hold','reject_hold','expire_claim_process','reject_bulk')
 or p_action is null$p$, $p$'approve_hold','reject_hold','expire_claim_process','reject_bulk','reject_claim_not_yet','reject_clearing_not_yet' /* 20261163980000 */)
 or p_action is null$p$, 1, 'mutate daftar aksi');
    src := pg_temp.ganti(src, $p$if p_action in('claim','reject_claim') then perform rc_private.require_tab('process.claimFin');end if;$p$,
      $p$if p_action in('claim','reject_claim','reject_claim_not_yet') then perform rc_private.require_tab('process.claimFin');end if;$p$, 1, 'mutate tab claim');
    src := pg_temp.ganti(src, $p$if p_action in('clearing','reject_clearing') then perform rc_private.require_tab('process.clearing');end if;$p$,
      $p$if p_action in('clearing','reject_clearing','reject_clearing_not_yet') then perform rc_private.require_tab('process.clearing');end if;$p$, 1, 'mutate tab clearing');
    src := pg_temp.ganti(src, $p$'unhold','expire','expire_claim_process','reject_bulk') and btrim(coalesce(p_reason,''))=''$p$,
      $p$'unhold','expire','expire_claim_process','reject_bulk','reject_claim_not_yet','reject_clearing_not_yet') and btrim(coalesce(p_reason,''))=''$p$, 1, 'mutate alasan');
    src := pg_temp.ganti(src, $p$if not (p_action in('claim','clearing','reject_claim','reject_clearing','expire_claim_process')$p$,
      $p$if not (p_action in('claim','clearing','reject_claim','reject_clearing','expire_claim_process','reject_claim_not_yet','reject_clearing_not_yet')$p$, 1, 'mutate yurisdiksi');
    src := pg_temp.ganti(src, $p$if p_action in('release','claim','clearing','reject_release','reject_claim','reject_clearing')$p$,
      $p$if p_action in('release','claim','clearing','reject_release','reject_claim','reject_clearing','reject_claim_not_yet','reject_clearing_not_yet')$p$, 1, 'mutate rebate');
    src := pg_temp.ganti(src, $p$ elsif p_action='reject_clearing' and c.status='claimed' then target:='released';$p$,
      $p$ elsif p_action='reject_clearing' and c.status='claimed' then target:='released';
 -- 20261163980000: tolak langsung ke depot dari Claim Process, tanpa melewati Release.
 elsif p_action='reject_claim_not_yet' and c.status='released' then target:='not_yet';
 elsif p_action='reject_clearing_not_yet' and c.status='claimed' then target:='not_yet';$p$, 1, 'mutate target');
    -- Pembersihan tanggal, pelaku dan batch: sama dengan tolak dari Bulk Process.
    src := pg_temp.ganti(src, $p$'reject_bulk') then null$p$, $p$'reject_bulk','reject_claim_not_yet','reject_clearing_not_yet') then null$p$, 11, 'mutate pembersihan');
    src := pg_temp.ganti(src, $p$ v_payload:=jsonb_build_object('processed',processed,'batch',batch,'count',jsonb_array_length(processed));$p$,
      $p$ -- 20261163980000: dokumen yang kembali ke Not Yet langsung dinilai dengan data debtor yang berlaku.
 if p_action in('reject_release','reject_approval','reject_bulk','reject_claim_not_yet','reject_clearing_not_yet') and jsonb_array_length(processed) > 0 then
  begin
   perform rc_private.zdage_nilai_baru();
  exception when others then
   insert into public.activity_logs(actor_id,event_type,details)
   values(actor,'zdage_nilai_gagal',jsonb_build_object('sebab',left(sqlerrm,300)));
  end;
 end if;
 v_payload:=jsonb_build_object('processed',processed,'batch',batch,'count',jsonb_array_length(processed));$p$, 1, 'mutate nilai ulang');
    execute src;
  end if;

  -- Log Activity: aksi baru masuk kelompok yang sama dengan tolak biasa.
  src := replace(pg_get_functiondef((select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'rc_private' and p.proname = 'audit_context')::regprocedure), E'\r', '');
  if src !~ 'reject_claim_not_yet' then
    src := pg_temp.ganti(src, $p$when event in('claim','clearing','reject_claim','reject_clearing','expire_claim_process') then 'Claim Process'$p$,
      $p$when event in('claim','clearing','reject_claim','reject_clearing','expire_claim_process','reject_claim_not_yet','reject_clearing_not_yet') then 'Claim Process'$p$, 1, 'audit modul');
    src := pg_temp.ganti(src, $p$when event in('claim','reject_claim') then 'Claim to Finance'$p$,
      $p$when event in('claim','reject_claim','reject_claim_not_yet') then 'Claim to Finance'$p$, 1, 'audit tab claim');
    src := pg_temp.ganti(src, $p$when event in('clearing','reject_clearing') then 'Clearing'$p$,
      $p$when event in('clearing','reject_clearing','reject_clearing_not_yet') then 'Clearing'$p$, 1, 'audit tab clearing');
    execute src;
  end if;
end $tambal$;

do $cek$
declare v text;
begin
  v := pg_get_functiondef('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)'::regprocedure);
  if v !~ 'reject_clearing_not_yet'' and c.status=''claimed''' then raise exception 'GAGAL: target tolak'; end if;
  if v ~ '''reject_bulk''\) then null' then raise exception 'GAGAL: pembersihan belum lengkap'; end if;
  if pg_get_functiondef('rc_private.zdage_evaluasi(uuid,text[],numeric,text,uuid)'::regprocedure) !~ 'akhir.ditahan' then raise exception 'GAGAL: evaluasi'; end if;
  if pg_get_functiondef('rc_private.zdage_nilai_baru()'::regprocedure) !~ 'zdage_ditahan_sampai' then raise exception 'GAGAL: nilai baru'; end if;
  if has_function_privilege('authenticated', 'rc_private.zdage_ditahan_sampai(uuid)', 'execute') then raise exception 'GAGAL: hak'; end if;
end $cek$;
