-- ==========================================================================================
-- Modul Management of Approval: antrean, rincian, dan riwayat
-- ==========================================================================================
-- Tahap approval sudah hidup di mesin status (20261137). Berkas ini menambahkan cara MELIHATNYA,
-- dan sekaligus menutup satu akibat langsung dari tahap baru itu: antrean Release masih
-- mengambil dokumen berstatus Submitted, padahal Release kini hanya menerima yang sudah
-- Approved. Tanpa perbaikan itu Release akan menampilkan dokumen yang pasti ditolaknya sendiri.
--
-- ------------------------------------------------------------------------------------------
-- WITHIN PAYMENT TERM DAN OVERDUE
-- ------------------------------------------------------------------------------------------
-- Pemisahannya memakai TOP yang DIKETIK DEPOT saat mengunggah - tersimpan di
-- rc_private.claim_sensitive.top_text - dihitung sejak tanggal posting (uploaded_at):
--
--   lewat = hari ini - tanggal posting
--   WPT   : lewat <= TOP
--   OVD   : lewat >  TOP
--
-- TOP yang kosong atau bukan angka diperlakukan sebagai WPT, bukan Overdue. Dokumen tidak boleh
-- jatuh ke antrean yang lebih keras hanya karena datanya belum lengkap; yang kurang datanya
-- terlihat di kolom TOP pada rincian, dan itulah tempat memperbaikinya.
--
-- ------------------------------------------------------------------------------------------
-- SIAPA MELIHAT APA
-- ------------------------------------------------------------------------------------------
-- Jangkauan depot tetap ditentukan rc_private.can_access - OSC sesuai depot yang ditempelkan,
-- Supervisor lewat OSC binaannya, Management lewat region, System Manager seluruhnya. Tidak ada
-- aturan jangkauan kedua di sini.
--
-- Yang khusus modul ini hanya satu: Depot Head hanya boleh menyetujui yang Within Payment Term.
-- Aturan itu ditulis sekali di rc_private.boleh_approve_overdue() dan dipakai baik untuk
-- menyembunyikan tabnya maupun untuk menolak permintaannya - sebab menyembunyikan tab saja
-- bukan penjagaan, hanya penyamaran.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Antrean Release mengikuti tahap baru
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rc_legacy_workflow';
  if src is null then raise exception 'public.rc_legacy_workflow tidak ditemukan.'; end if;

  if position($q$v->>'status'='Approved'$q$ in src) > 0 then
    raise notice 'rc_legacy_workflow sudah mengikuti tahap approval; dilewati.';
    return;
  end if;

  baru := src;
  -- Dokumen berstatus approved harus ikut terambil.
  if position($q$where c.status in('submitted','released','claimed')$q$ in baru) = 0 then
    raise exception 'Pola penyaring status tidak ditemukan pada rc_legacy_workflow.'; end if;
  baru := replace(baru, $q$where c.status in('submitted','released','claimed')$q$,
                        $q$where c.status in('submitted','approved','released','claimed')$q$);

  -- Antrean Release berpindah dari Submitted ke Approved.
  if position($q$where v->>'status'='Submitted' and not (v->>'rebate')::boolean$q$ in baru) = 0 then
    raise exception 'Pola antrean Release tidak ditemukan pada rc_legacy_workflow.'; end if;
  baru := replace(baru, $q$where v->>'status'='Submitted' and not (v->>'rebate')::boolean$q$,
                        $q$where v->>'status'='Approved' and not (v->>'rebate')::boolean$q$);

  -- Jejak penyetuju ikut dibawa, supaya kolom Approved by pada Release punya isinya.
  if position($q$filter (where h.to_status='released' and h.actor_id is not null))[1] as release_by$q$ in baru) = 0 then
    raise exception 'Pola jejak pelaku tidak ditemukan pada rc_legacy_workflow.'; end if;
  baru := replace(baru,
    $q$filter (where h.to_status='released' and h.actor_id is not null))[1] as release_by$q$,
    $q$filter (where h.to_status='approved' and h.actor_id is not null))[1] as approve_by,$q$ || chr(10) ||
    $q$         (array_agg(h.actor_id order by h.created_at desc)$q$ || chr(10) ||
    $q$         filter (where h.to_status='released' and h.actor_id is not null))[1] as release_by$q$);

  execute baru;
  raise notice 'rc_legacy_workflow: antrean Release mengikuti tahap approval.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 2. Aturan siapa boleh menyetujui Overdue
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.boleh_approve_overdue()
returns boolean language sql stable security definer set search_path='' as $fn$
  -- Depot Head dibatasi pada Within Payment Term atas keputusan pemilik. Peran lain yang sudah
  -- berhak menyetujui - Management, OSC, Supervisor, System Manager - menangani keduanya.
  select exists(
    select 1 from public.profiles p
     where p.id = (select auth.uid()) and p.status = 'active'
       and not p.must_change_password
       and p.role <> 'depot head');
$fn$;
revoke all on function rc_private.boleh_approve_overdue() from public, anon;
grant execute on function rc_private.boleh_approve_overdue() to authenticated;

-- Selisih hari sejak posting terhadap TOP yang diketik depot. Dibuat satu fungsi supaya antrean,
-- rincian dan penyaringnya memakai perhitungan yang sama persis.
create or replace function rc_private.approval_overdue(p_uploaded timestamptz, p_top text)
returns boolean language sql immutable set search_path='' as $fn$
  select case
    when p_uploaded is null then false
    when btrim(coalesce(p_top,'')) !~ '^[0-9]+([.][0-9]+)?$' then false
    else (current_date - (p_uploaded at time zone 'Asia/Jakarta')::date) > btrim(p_top)::numeric
  end;
$fn$;
revoke all on function rc_private.approval_overdue(timestamptz, text) from public, anon;
grant execute on function rc_private.approval_overdue(timestamptz, text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Baris yang menunggu persetujuan, sudah tersaring jangkauan pemanggilnya
-- ------------------------------------------------------------------------------------------
create or replace view rc_private.approval_rows as
  select c.id, c.no_doc, c.depot_id, c.batch_upload, c.uploaded_at, c.cb_net,
         c.tax_subject, c.status, c.version_no,
         cu.customer_code, cu.customer_name,
         ca.campaign_code, ca.campaign_name, ca.tax_status,
         coalesce(nullif(btrim(coalesce(s.top_text,'')),''), nullif(btrim(coalesce(cu.top_text,'')),'')) as top_text,
         rc_private.jenis_efektif(ca.cashback_type) as jenis_cb,
         coalesce(ca.cashback_type,'') as jenis_cb_label,
         c.submitted_by, c.approved_by, c.approved_at
    from public.claims c
    join public.customers cu on cu.id = c.customer_id
    join public.campaigns ca on ca.id = c.campaign_id
    left join rc_private.claim_sensitive s on s.claim_id = c.id
   where c.status = 'submitted' and c.archived_at is null;

-- Pembungkus di bawah ini SECURITY INVOKER, jadi ia berjalan sebagai pemanggilnya dan pemanggil
-- itu harus boleh membaca view ini - persis pelajaran yang sudah pernah membuat modul Report
-- berhenti bekerja. Tidak ada yang terbuka karenanya: rc_private bukan skema yang dilayani
-- PostgREST, sehingga satu-satunya jalan masuk tetap fungsi di skema public, dan di sanalah
-- jangkauan depot disaring. Kolom pribadi pelanggan pun tidak ada di dalam view ini.
revoke all on rc_private.approval_rows from public, anon;
grant select on rc_private.approval_rows to authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Tampilan pertama: satu baris per batch
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_approval_batches(p_kind text default 'wpt')
returns jsonb language plpgsql stable set search_path='' as $fn$
declare v_ovd boolean; hasil jsonb;
begin
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak menyetujui dokumen' using errcode='42501'; end if;
  v_ovd := lower(coalesce(p_kind,'wpt')) = 'ovd';
  if v_ovd and not rc_private.boleh_approve_overdue() then
    raise exception 'Depot Head hanya dapat menyetujui dokumen Within Payment Term'
      using errcode='42501'; end if;

  select jsonb_build_object('status','success','kind', case when v_ovd then 'ovd' else 'wpt' end,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'noBatch', t.batch, 'qtyDoc', t.qty_doc, 'qtyCust', t.qty_cust,
      'qtyCampaign', t.qty_camp, 'totalNetCb', t.net_cb,
      'submittedBy', t.submitted_by, 'postingDate', t.posting_date)
      order by t.posting_date desc nulls last, t.batch), '[]'::jsonb))
  into hasil
  from (
    select coalesce(nullif(btrim(r.batch_upload),''),'(tanpa batch)') batch,
           count(*) qty_doc,
           count(distinct r.customer_code) qty_cust,
           count(distinct r.campaign_code) qty_camp,
           coalesce(sum(r.cb_net),0) net_cb,
           coalesce(string_agg(distinct p.full_name, ', '),'-') submitted_by,
           to_char(max(r.uploaded_at) at time zone 'Asia/Jakarta','DD-Mon-YYYY') posting_date
      from rc_private.approval_rows r
      left join public.profiles p on p.id = r.submitted_by
     where rc_private.can_access(r.depot_id,'approve_claim')
       and rc_private.approval_overdue(r.uploaded_at, r.top_text) = v_ovd
     group by 1) t;
  return hasil;
end $fn$;
revoke all on function public.rc_approval_batches(text) from public, anon;
grant execute on function public.rc_approval_batches(text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 5. Tampilan kedua: rincian sebuah batch
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_approval_detail(p_batch text, p_kind text default 'wpt')
returns jsonb language plpgsql stable set search_path='' as $fn$
declare v_ovd boolean; hasil jsonb;
begin
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak menyetujui dokumen' using errcode='42501'; end if;
  v_ovd := lower(coalesce(p_kind,'wpt')) = 'ovd';
  if v_ovd and not rc_private.boleh_approve_overdue() then
    raise exception 'Depot Head hanya dapat menyetujui dokumen Within Payment Term'
      using errcode='42501'; end if;

  select jsonb_build_object('status','success','noBatch',p_batch,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'noDoc', r.no_doc, 'versionNo', r.version_no,
      'kodeCust', r.customer_code, 'namaCust', r.customer_name,
      'kodeCampaign', r.campaign_code, 'namaCampaign', coalesce(r.campaign_name,''),
      'netCb', r.cb_net, 'jenisCb', r.jenis_cb_label,
      'top', coalesce(r.top_text,''),
      'statusPajak', coalesce(r.tax_subject,''),
      'statusPajakCampaign', coalesce(r.tax_status,''),
      'submittedBy', coalesce(ps.full_name,''),
      'postingDate', to_char(r.uploaded_at at time zone 'Asia/Jakarta','DD-Mon-YYYY'),
      'overdue', rc_private.approval_overdue(r.uploaded_at, r.top_text))
      order by r.no_doc), '[]'::jsonb))
  into hasil
  from rc_private.approval_rows r
  left join public.profiles ps on ps.id = r.submitted_by
  where coalesce(nullif(btrim(r.batch_upload),''),'(tanpa batch)') = coalesce(p_batch,'')
    and rc_private.can_access(r.depot_id,'approve_claim')
    and rc_private.approval_overdue(r.uploaded_at, r.top_text) = v_ovd;
  return hasil;
end $fn$;
revoke all on function public.rc_approval_detail(text, text) from public, anon;
grant execute on function public.rc_approval_detail(text, text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 6. Tab History
-- ------------------------------------------------------------------------------------------
-- Sumbernya public.claim_status_history, yang sudah diisi mesin status - jadi riwayat di sini
-- dan Log Aktivitas menceritakan hal yang sama, karena keduanya ditulis pada saat yang sama.
create or replace function public.rc_approval_history(p_limit integer default 200,
                                                      p_offset integer default 0)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare hasil jsonb; v_total bigint;
begin
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat riwayat approval' using errcode='42501'; end if;

  select count(*) into v_total
    from public.claim_status_history h
    join public.claims c on c.id = h.claim_id
   where h.action in ('approve','reject_approval')
     and rc_private.can_access(c.depot_id,'approve_claim');

  select jsonb_build_object('status','success','total',v_total,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'waktu', to_char(t.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI'),
      'noDoc', t.no_doc, 'noBatch', coalesce(t.batch,''),
      'tindakan', case when t.action='approve' then 'Approve' else 'Reject' end,
      'dari', rc_private.legacy_status(t.from_status),
      'ke', rc_private.legacy_status(t.to_status),
      'oleh', coalesce(t.full_name,''), 'alasan', coalesce(t.reason,''))
      order by t.created_at desc), '[]'::jsonb))
  into hasil
  from (
    select h.created_at, c.no_doc, h.batch, h.action, h.from_status, h.to_status,
           p.full_name, h.reason
      from public.claim_status_history h
      join public.claims c on c.id = h.claim_id
      left join public.profiles p on p.id = h.actor_id
     where h.action in ('approve','reject_approval')
       and rc_private.can_access(c.depot_id,'approve_claim')
     order by h.created_at desc
     limit greatest(1, least(coalesce(p_limit,200), 1000))
    offset greatest(0, coalesce(p_offset,0))) t;
  return hasil;
end $fn$;
revoke all on function public.rc_approval_history(integer, integer) from public, anon;
grant execute on function public.rc_approval_history(integer, integer) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 7. Modul baru masuk katalog izin
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='rc_permission_catalog';
  if position('approve_claim' in src) > 0 then
    raise notice 'Katalog izin sudah memuat approve_claim; dilewati.'; return; end if;

  if position($q$jsonb_build_object('key','report'$q$ in src) = 0 then
    raise exception 'Pola katalog izin tidak ditemukan.'; end if;
  baru := replace(src, $q$jsonb_build_object('key','report'$q$,
    $q$jsonb_build_object('key','approval','code','approve_claim','modul','Management of Approval','sub','Approve dan reject sebelum Release'),$q$
    || chr(10) || $q$  jsonb_build_object('key','report'$q$);
  execute baru;
  raise notice 'Katalog izin memuat Management of Approval.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_uid uuid; h jsonb; src text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='rc_legacy_workflow';
  if position($q$v->>'status'='Approved'$q$ in src) = 0 then
    raise exception 'GAGAL: antrean Release belum memakai Approved.'; end if;
  if position($q$v->>'status'='Submitted' and not$q$ in src) > 0 then
    raise exception 'GAGAL: antrean Release lama masih ada.'; end if;

  if not rc_private.approval_overdue(now() - interval '40 days', '30') then
    raise exception 'GAGAL: 40 hari dengan TOP 30 seharusnya Overdue.'; end if;
  if rc_private.approval_overdue(now() - interval '10 days', '30') then
    raise exception 'GAGAL: 10 hari dengan TOP 30 seharusnya WPT.'; end if;
  if rc_private.approval_overdue(now() - interval '400 days', '') then
    raise exception 'GAGAL: TOP kosong seharusnya tidak dianggap Overdue.'; end if;

  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);

  h := public.rc_approval_batches('wpt');
  if (h->>'status') <> 'success' then raise exception 'GAGAL: antrean WPT.'; end if;
  perform public.rc_approval_batches('ovd');
  perform public.rc_approval_history(10, 0);
  reset role;

  raise notice 'Antrean WPT: % batch.', jsonb_array_length(h->'rows');
  raise notice 'Pemeriksaan lolos.';
exception when others then
  reset role; raise;
end
$periksa$;
