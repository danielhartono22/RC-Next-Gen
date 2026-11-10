-- ==========================================================================================
-- Upload Debtor bertahap per depot, seperti Customer Master
-- ==========================================================================================
-- Pemilik, 9 November 2026: "saya mau zdage bisa upload dengan timeout yang diperpanjang tadi timeout,
-- buat upload bertahap seperti customer master."
-- Kirim baris sudah per 500. Yang masih satu panggilan besar adalah penilaian dan penerapan, karena
-- seluruh klaim Not Yet dinilai sekaligus. Kini keduanya per depot:
-- * Pratinjau: rc_zdage_preview_awal (ringkasan berkas dan daftar depot), lalu rc_zdage_preview_bagian
--   per depot. Rumus penilaiannya tetap satu: rc_private.zdage_evaluasi, kini dengan p_depot.
-- * Terapkan: rc_zdage_apply_mulai, rc_zdage_apply_bagian per depot, rc_zdage_apply_selesai. Setiap depot
--   satu transaksi dan tercatat di rc_zdage_uploads.progres, jadi bisa diulang atau dilanjutkan bila
--   terputus; depot yang sudah selesai tidak dikerjakan dua kali. Satu baris Log Activity per proses.
-- * rc_zdage_stage mengenali bagian yang sudah tersimpan, supaya aman dikirim ulang.
-- * Status baru 'menerapkan'. Berkas baru dari pengunggah yang sama menutup penerapan lamanya yang
--   terhenti (status applied, hasil sebagian), supaya data lama tidak dilanjutkan menimpa data baru.
-- rc_zdage_preview dan rc_zdage_apply tetap ada dengan hasil yang sama dan memakai bagian yang sama.
-- Butuh 20261163780000. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

alter table public.rc_zdage_uploads add column if not exists progres jsonb;
alter table public.rc_zdage_uploads drop constraint if exists rc_zdage_uploads_status_check;
alter table public.rc_zdage_uploads add constraint rc_zdage_uploads_status_check
  check (status in ('preview', 'menerapkan', 'applied', 'discarded'));

do $tambal$
declare src text;
begin
  -- ---- Penilaian dapat dibatasi satu depot ------------------------------------------------------
  if to_regprocedure('rc_private.zdage_evaluasi(uuid,text[],numeric,text)') is not null then
    src := replace(pg_get_functiondef('rc_private.zdage_evaluasi(uuid,text[],numeric,text)'::regprocedure), E'\r', '');
    src := pg_temp.ganti(src, 'p_mode text)', 'p_mode text, p_depot uuid DEFAULT NULL::uuid)', 1, 'evaluasi kepala');
    src := pg_temp.ganti(src, 'where d.archived_at is null /* 20261163780000: seluruh depot */',
      'where d.archived_at is null /* 20261163780000: seluruh depot */ and (p_depot is null or d.id = p_depot) /* 20261163860000 */', 1, 'evaluasi depot');
    drop function rc_private.zdage_evaluasi(uuid, text[], numeric, text);
    execute src;
  end if;

  -- ---- Bagian yang sudah tersimpan tidak ditulis dua kali ---------------------------------------
  src := replace(pg_get_functiondef('public.rc_zdage_stage(text,timestamp with time zone,jsonb,uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163860000' then
    src := pg_temp.ganti(src, $p$  v_bulan := array(select to_char((u.as_of_month$p$,
      $p$  -- 20261163860000: jawaban sebelumnya hilang di jaringan, bagian ini sudah tersimpan.
  if p_upload_id is not null and (select count(*) from public.rc_zdage_rows r where r.upload_id = u.id
        and r.row_no in (select (x->>'rowNo')::integer from jsonb_array_elements(p_rows) x)) = jsonb_array_length(p_rows) then
    return jsonb_build_object('status', 'success', 'uploadId', u.id, 'diterima', 0, 'asOf', to_char(u.as_of_month, 'YYYY-MM'));
  end if;

  v_bulan := array(select to_char((u.as_of_month$p$, 1, 'stage');
    execute src;
  end if;

  -- ---- Riwayat menyebut penerapan yang terhenti -------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_zdage_riwayat()'::regprocedure), E'\r', '');
  if src !~ 'belumSelesai' then
    src := pg_temp.ganti(src, $p$'mode', rc_private.zdage_mode(),
    'upload', coalesce($p$, $p$'mode', rc_private.zdage_mode(),
    'belumSelesai', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'file', b.file_name,
        'selesai', (select count(*) from jsonb_object_keys(b.progres->'depot')), 'total', jsonb_array_length(b.progres->'bagian')) order by b.created_at)
      from public.rc_zdage_uploads b where b.status = 'menerapkan' and (b.uploaded_by = auth.uid() or rc_private.is_system_manager())), '[]'::jsonb),
    'upload', coalesce($p$, 1, 'riwayat');
    execute src;
  end if;
end $tambal$;

-- Depot yang dikerjakan upload ini: ada di berkas, dicentang Tidak ada tagihan, atau memakai data lama dan punya klaim Not Yet.
create or replace function rc_private.zdage_bagian(p_upload uuid, p_kosong text[])
returns table(depot_id uuid, depot_code text, depot_name text, not_yet bigint)
language sql stable security definer set search_path to '' as $f$
  with berkas as (select distinct r.depot_id from public.rc_zdage_rows r where r.upload_id = p_upload and r.depot_id is not null),
  ny as (select c.depot_id, count(*) n from public.claims c where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null group by 1)
  select d.id, d.depot_code, d.depot_name, coalesce(ny.n, 0)
    from public.depots d
    left join ny on ny.depot_id = d.id
    left join public.rc_zdage_depot_data dd on dd.depot_id = d.id
   where d.archived_at is null
     and (d.id in (select b.depot_id from berkas b) or d.depot_code = any(coalesce(p_kosong, '{}')) or (dd.depot_id is not null and coalesce(ny.n, 0) > 0))
   order by d.depot_code;
$f$;

-- Bagian pratinjau yang tidak butuh penilaian klaim.
create or replace function rc_private.zdage_preview_meta(p_upload uuid, p_kosong text[])
returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare u public.rc_zdage_uploads; v_dep_file jsonb; v_tidak jsonb; v_asing jsonb; n_total_beda integer; v_galat text;
begin
  select * into u from public.rc_zdage_uploads where id = p_upload;

  select coalesce(jsonb_agg(jsonb_build_object('kode', z.kode, 'nama', z.nama, 'toko', z.toko,
           'notYet', (select count(*) from public.claims c where c.depot_id = z.id and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null)) order by z.kode), '[]'::jsonb)
    into v_dep_file
    from (select d.id, d.depot_code kode, d.depot_name nama, count(*) toko
            from public.rc_zdage_rows r join public.depots d on d.id = r.depot_id
           where r.upload_id = u.id
           group by d.id, d.depot_code, d.depot_name) z;

  select coalesce(jsonb_agg(jsonb_build_object('kode', z.channel, 'toko', z.n) order by z.channel), '[]'::jsonb) into v_asing
    from (select coalesce(r.channel, '(kosong)') channel, count(*) n from public.rc_zdage_rows r
           where r.upload_id = u.id and r.depot_id is null group by 1) z;

  -- Depot yang punya klaim Not Yet tetapi tidak ada di file (pop up).
  select coalesce(jsonb_agg(jsonb_build_object('kode', d.depot_code, 'nama', d.depot_name,
           'notYet', (select count(*) from public.claims c where c.depot_id = d.id and c.status = 'not_yet'
                       and c.pending_approval is null and c.archived_at is null),
           'dataLama', case when dd.depot_id is null then null else jsonb_build_object(
             'asOf', to_char(dd.as_of_month, 'Mon-YYYY'), 'tarikan', to_char(dd.extracted_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY'),
             'kosong', dd.kosong) end,
           'tidakAdaTagihan', d.depot_code = any(coalesce(p_kosong, '{}'))) order by d.depot_code), '[]'::jsonb)
    into v_tidak
    from public.depots d
    left join public.rc_zdage_depot_data dd on dd.depot_id = d.id
   where d.archived_at is null
     and not exists(select 1 from public.rc_zdage_rows r where r.upload_id = u.id and r.depot_id = d.id)
     and exists(select 1 from public.claims c where c.depot_id = d.id and c.status = 'not_yet'
                 and c.pending_approval is null and c.archived_at is null);

  -- Peringatan: Total <> jumlah G..T. Kode toko yang tidak ada di Customer Master dibiarkan
  -- (keputusan pemilik): toko itu tidak punya klaim, jadi tidak memengaruhi penilaian.
  select count(*) into n_total_beda from public.rc_zdage_rows r
   where r.upload_id = u.id
     and abs(r.total_amt - r.bucket_older - (select coalesce(sum((e.value #>> '{}')::numeric), 0) from jsonb_each(r.buckets) e)) > 1;

  v_galat := rc_private.zdage_galat(u.id);

  return jsonb_build_object('status', 'success',
    'upload', jsonb_build_object('id', u.id, 'file', u.file_name, 'status', u.status, 'baris', u.row_count,
      'tarikan', to_char(u.extracted_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
      'asOf', to_char(u.as_of_month, 'Mon-YYYY')),
    'toleransi', rc_private.zdage_toleransi(), 'mode', rc_private.zdage_mode(),
    'depotFile', v_dep_file, 'depotTidakAda', v_tidak, 'depotLuarJangkauan', '[]'::jsonb, 'kodeDepotAsing', v_asing,
    'totalBeda', n_total_beda,
    'galat', case when v_galat is null then '[]'::jsonb else jsonb_build_array(
      'Bulan tarikan file lebih tua dari data debtor yang sudah berlaku untuk depot: ' || v_galat) end);
end $f$;

-- Baris pratinjau satu depot (atau seluruh depot bila p_depot null).
create or replace function rc_private.zdage_preview_baris(p_upload uuid, p_kosong text[], p_depot uuid)
returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('noDoc', e.no_doc, 'kodeDepot', e.depot_code, 'namaDepot', e.depot_name,
           'kodeToko', e.kode_toko, 'namaToko', e.nama_toko, 'kodeCampaign', e.campaign_code, 'namaCampaign', e.campaign_name,
           'netCb', e.cb_net, 'bulanSo', to_char(e.bulan_so, 'YYYY-MM'), 'bulanBill', to_char(e.bulan_bill, 'YYYY-MM'),
           'hasil', e.hasil, 'alasan', e.alasan) order by e.depot_code, e.hasil, e.no_doc), '[]'::jsonb)
    from rc_private.zdage_evaluasi(p_upload, p_kosong, rc_private.zdage_toleransi(), rc_private.zdage_mode(), p_depot) e;
$f$;

create or replace function public.rc_zdage_preview(p_upload_id uuid, p_kosong text[] default '{}'::text[])
returns jsonb language plpgsql security definer set search_path to '' set statement_timeout to '90s' as $f$
declare u public.rc_zdage_uploads; v_rows jsonb; v_ring jsonb; v_kampanye jsonb;
begin
  perform rc_private.require_tab('compilation.debtor');
  select * into u from public.rc_zdage_uploads where id = p_upload_id;
  if not found or (u.uploaded_by <> auth.uid() and not rc_private.is_system_manager()) then
    raise exception 'Upload tidak ditemukan'; end if;

  v_rows := rc_private.zdage_preview_baris(u.id, p_kosong, null);

  select jsonb_build_object(
      'total', count(*),
      'lunas', count(*) filter (where e->>'hasil' = 'LUNAS'),
      'lunasCb', coalesce(sum((e->>'netCb')::numeric) filter (where e->>'hasil' = 'LUNAS'), 0),
      'gagal', count(*) filter (where e->>'hasil' = 'GAGAL'),
      -- Belum lunas per penyebab UTAMA (aturan gagal dengan prioritas tertinggi).
      'gagal1', count(*) filter (where e->>'hasil' = 'GAGAL' and (e->'alasan'->>'utama')::integer = 1),
      'gagal2', count(*) filter (where e->>'hasil' = 'GAGAL' and (e->'alasan'->>'utama')::integer = 2),
      'gagal3', count(*) filter (where e->>'hasil' = 'GAGAL' and (e->'alasan'->>'utama')::integer = 3),
      'badDebt', count(*) filter (where e->>'hasil' = 'BLOCKED_BAD_DEBT'),
      'suppressed', count(*) filter (where e->>'hasil' = 'SUPPRESSED'),
      'sudahDitawarkan', count(*) filter (where e->>'hasil' = 'SUDAH_DITAWARKAN'),
      'periodeSalah', count(*) filter (where e->>'hasil' = 'PERIODE_SALAH'),
      'campaignBermasalah', count(distinct e->>'kodeCampaign') filter (where e->>'hasil' = 'PERIODE_SALAH'),
      'kembaliRestricted', count(*) filter (where (e->'alasan'->>'tawaranAktif')::boolean and e->>'hasil' <> 'SUDAH_DITAWARKAN'),
      'tanpaMaster', count(*) filter (where e->>'hasil' = 'TANPA_MASTER'))
    into v_ring from jsonb_array_elements(v_rows) e;

  -- Campaign Bermasalah: ringkasan per campaign dari klaim Periode Salah.
  select coalesce(jsonb_agg(jsonb_build_object('kode', z.kode, 'nama', z.nama, 'masalah', z.masalah, 'bulanSo', z.bso, 'bulanBill', z.bbill, 'klaim', z.n, 'netCb', z.cb)
           order by z.n desc, z.kode), '[]'::jsonb) into v_kampanye
    from (select e->>'kodeCampaign' kode, e->>'namaCampaign' nama, e->'alasan'->>'masalah' masalah, min(e->>'bulanSo') bso, min(e->>'bulanBill') bbill,
                 count(*) n, coalesce(sum((e->>'netCb')::numeric), 0) cb
            from jsonb_array_elements(v_rows) e where e->>'hasil' = 'PERIODE_SALAH' group by 1, 2, 3) z;

  return rc_private.zdage_preview_meta(u.id, p_kosong) || jsonb_build_object('ringkasan', v_ring || jsonb_build_object('campaign', v_kampanye), 'rows', v_rows);
end $f$;

create or replace function public.rc_zdage_preview_awal(p_upload_id uuid, p_kosong text[] default '{}'::text[])
returns jsonb language plpgsql stable security definer set search_path to '' set statement_timeout to '90s' as $f$
declare u public.rc_zdage_uploads;
begin
  perform rc_private.require_tab('compilation.debtor');
  select * into u from public.rc_zdage_uploads where id = p_upload_id;
  if not found or (u.uploaded_by <> auth.uid() and not rc_private.is_system_manager()) then
    raise exception 'Upload tidak ditemukan'; end if;
  return rc_private.zdage_preview_meta(u.id, p_kosong) || jsonb_build_object('bagian', coalesce((
    select jsonb_agg(jsonb_build_object('kode', b.depot_code, 'nama', b.depot_name, 'notYet', b.not_yet) order by b.depot_code)
      from rc_private.zdage_bagian(u.id, p_kosong) b where b.not_yet > 0), '[]'::jsonb));
end $f$;

create or replace function public.rc_zdage_preview_bagian(p_upload_id uuid, p_kosong text[], p_depot text)
returns jsonb language plpgsql stable security definer set search_path to '' set statement_timeout to '90s' as $f$
declare u public.rc_zdage_uploads; v_depot uuid;
begin
  perform rc_private.require_tab('compilation.debtor');
  select * into u from public.rc_zdage_uploads where id = p_upload_id;
  if not found or (u.uploaded_by <> auth.uid() and not rc_private.is_system_manager()) then
    raise exception 'Upload tidak ditemukan'; end if;
  select id into v_depot from public.depots where depot_code = btrim(coalesce(p_depot, '')) and archived_at is null;
  if v_depot is null then raise exception 'Depot % tidak ada di Depot Master', p_depot; end if;
  return jsonb_build_object('status', 'success', 'rows', rc_private.zdage_preview_baris(u.id, p_kosong, v_depot));
end $f$;

-- Penerapan satu depot. Aturannya sama persis dengan rc_zdage_apply sebelum dipecah.
create or replace function rc_private.zdage_terapkan_depot(p_upload uuid, p_depot uuid, p_kosong text[], p_tol numeric, p_mode text, p_hari date)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare u public.rc_zdage_uploads; v_deadline timestamptz := ((p_hari + 7)::timestamp + time '23:59:59') at time zone 'Asia/Jakarta';
  v_ids uuid[]; n_tgl integer; n_batal integer := 0; v_hasil jsonb; v_kode text; v_di_berkas boolean;
begin
  select * into u from public.rc_zdage_uploads where id = p_upload;
  select depot_code into v_kode from public.depots where id = p_depot;
  drop table if exists pg_temp._zdage_ev;
  create temp table _zdage_ev on commit drop as select * from rc_private.zdage_evaluasi(u.id, p_kosong, p_tol, p_mode, p_depot);

  with baru as (
    insert into public.rc_clearing_offers(claim_id, upload_id, result, reason, offered_at, offered_by, deadline_at, status)
    select e.claim_id, u.id, 'LUNAS', e.alasan, now(), auth.uid(), v_deadline, 'offered'
      from _zdage_ev e where e.hasil = 'LUNAS'
    on conflict (claim_id) where status in ('offered','overdue') do nothing
    returning claim_id)
  select coalesce(array_agg(claim_id), '{}') into v_ids from baru;

  -- Tawaran aktif yang menurut data baru tidak lunas lagi dibatalkan: klaimnya kembali ke Restricted.
  with batal as (
    update public.rc_clearing_offers o set status = 'cancelled', acted_by = auth.uid(), acted_at = now()
      from _zdage_ev e
     where o.claim_id = e.claim_id and o.status in ('offered','overdue') and o.result <> 'RESTRICTED'
       and (e.alasan->>'tawaranAktif')::boolean and e.hasil <> 'SUDAH_DITAWARKAN'
    returning o.claim_id, e.hasil, e.alasan, e.tgl_tarikan),
  h as (
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    select b.claim_id, auth.uid(), 'not_yet', 'not_yet', 'zdage_cancel',
           left('Tidak lunas lagi menurut debtor ZDAGE tarikan ' || to_char(b.tgl_tarikan at time zone 'Asia/Jakarta', 'DD-Mon-YYYY') || ': '
             || case b.hasil when 'GAGAL' then case (b.alasan->>'utama')::integer when 1 then 'over due' when 2 then 'tagihan selama periode campaign'
                                                   else 'tagihan sebelum periode campaign' end
                             when 'PERIODE_SALAH' then 'periode campaign salah' else lower(b.hasil) end
             || '. Kembali ke Restricted.', 300)
      from batal b returning claim_id)
  select count(*) into n_batal from batal;

  -- Hasil penilaian terakhir per klaim: sumber alasan di tab Restricted.
  insert into public.rc_zdage_hasil(claim_id, upload_id, hasil, alasan, dinilai_pada)
  select e.claim_id, u.id, e.hasil, e.alasan, now() from _zdage_ev e
  on conflict (claim_id) do update set upload_id = excluded.upload_id, hasil = excluded.hasil,
    alasan = excluded.alasan, dinilai_pada = excluded.dinilai_pada;

  -- Tgl Lunas = tanggal tarikan data yang dipakai, hanya bila masih kosong.
  update public.claims c set paid_on = (e.tgl_tarikan at time zone 'Asia/Jakarta')::date,
         version_no = c.version_no + 1, updated_at = now()
    from _zdage_ev e
   where c.id = e.claim_id and c.id = any(v_ids) and c.paid_on is null;
  get diagnostics n_tgl = row_count;

  insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
  select e.claim_id, auth.uid(), 'not_yet', 'not_yet', 'zdage_offer',
         left('Toko lunas menurut debtor ZDAGE tarikan ' || to_char(e.tgl_tarikan at time zone 'Asia/Jakarta', 'DD-Mon-YYYY')
           || case e.sumber when 'lama' then ' (data lama depot)' when 'kosong' then ' (depot tanpa tagihan)'
                            when 'lama_kosong' then ' (depot tanpa tagihan, data lama)' else '' end
           || '. Batas proses ' || to_char(p_hari + 7, 'DD-Mon-YYYY') || '.', 300)
    from _zdage_ev e where e.claim_id = any(v_ids);

  v_di_berkas := exists(select 1 from public.rc_zdage_rows r where r.upload_id = u.id and r.depot_id = p_depot);
  if v_di_berkas or v_kode = any(coalesce(p_kosong, '{}')) then
    insert into public.rc_zdage_depot_data(depot_id, upload_id, kosong, as_of_month, extracted_at, updated_at, updated_by)
    values (p_depot, u.id, not v_di_berkas, u.as_of_month, u.extracted_at, now(), auth.uid())
    on conflict (depot_id) do update set upload_id = excluded.upload_id, kosong = excluded.kosong,
      as_of_month = excluded.as_of_month, extracted_at = excluded.extracted_at, updated_at = now(), updated_by = excluded.updated_by;
  end if;

  select jsonb_build_object(
      'tawaranBaru', coalesce(array_length(v_ids, 1), 0), 'kembaliRestricted', n_batal, 'tglLunasDiisi', n_tgl,
      'lunas', count(*) filter (where hasil = 'LUNAS'), 'gagal', count(*) filter (where hasil = 'GAGAL'),
      'badDebt', count(*) filter (where hasil = 'BLOCKED_BAD_DEBT'), 'suppressed', count(*) filter (where hasil = 'SUPPRESSED'),
      'sudahDitawarkan', count(*) filter (where hasil = 'SUDAH_DITAWARKAN'), 'periodeSalah', count(*) filter (where hasil = 'PERIODE_SALAH'),
      'tanpaMaster', count(*) filter (where hasil = 'TANPA_MASTER'), 'dinilai', count(*),
      'campaignSalah', coalesce(jsonb_agg(distinct campaign_code) filter (where hasil = 'PERIODE_SALAH'), '[]'::jsonb))
    into v_hasil from _zdage_ev;
  return v_hasil;
end $f$;

-- Menutup penerapan: menjumlahkan depot yang selesai, status applied, satu baris Log Activity.
create or replace function rc_private.zdage_tutup(p_upload uuid, p_terhenti boolean)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare u public.rc_zdage_uploads; v_hasil jsonb; n_selesai integer; n_total integer;
begin
  select * into u from public.rc_zdage_uploads where id = p_upload;
  select count(*) into n_selesai from jsonb_object_keys(u.progres->'depot');
  n_total := jsonb_array_length(u.progres->'bagian');

  select jsonb_build_object(
      'tawaranBaru', coalesce(sum((e.value->>'tawaranBaru')::integer), 0), 'kembaliRestricted', coalesce(sum((e.value->>'kembaliRestricted')::integer), 0),
      'tglLunasDiisi', coalesce(sum((e.value->>'tglLunasDiisi')::integer), 0), 'lunas', coalesce(sum((e.value->>'lunas')::integer), 0),
      'gagal', coalesce(sum((e.value->>'gagal')::integer), 0), 'badDebt', coalesce(sum((e.value->>'badDebt')::integer), 0),
      'suppressed', coalesce(sum((e.value->>'suppressed')::integer), 0), 'sudahDitawarkan', coalesce(sum((e.value->>'sudahDitawarkan')::integer), 0),
      'periodeSalah', coalesce(sum((e.value->>'periodeSalah')::integer), 0), 'tanpaMaster', coalesce(sum((e.value->>'tanpaMaster')::integer), 0),
      'dinilai', coalesce(sum((e.value->>'dinilai')::integer), 0),
      'campaignBermasalah', (select count(distinct k) from jsonb_each(u.progres->'depot') d cross join lateral jsonb_array_elements_text(d.value->'campaignSalah') k),
      'deadline', to_char((u.progres->>'hari')::date + 7, 'DD-Mon-YYYY'), 'depotKosong', u.progres->'kosong')
    into v_hasil from jsonb_each(u.progres->'depot') e;
  if p_terhenti then v_hasil := v_hasil || jsonb_build_object('terhenti', true, 'depotSelesai', n_selesai, 'depotTotal', n_total); end if;

  update public.rc_zdage_uploads set status = 'applied', applied_at = now(), applied_by = auth.uid(), hasil = v_hasil, progres = null where id = u.id;

  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), 'zdage_offer', jsonb_build_object(
      'detail', 'Upload Debtor ' || u.file_name || ': ' || (v_hasil->>'tawaranBaru') || ' toko lunas ditawarkan ke depot'
        || case when p_terhenti then ' (terhenti di ' || n_selesai || ' dari ' || n_total || ' depot, digantikan berkas yang lebih baru)' else '' end,
      'uploadId', u.id) || v_hasil, 'compilation', 'debtor', 'debtor');
  return v_hasil;
end $f$;

revoke all on function rc_private.zdage_evaluasi(uuid, text[], numeric, text, uuid), rc_private.zdage_bagian(uuid, text[]), rc_private.zdage_preview_meta(uuid, text[]),
  rc_private.zdage_preview_baris(uuid, text[], uuid), rc_private.zdage_terapkan_depot(uuid, uuid, text[], numeric, text, date), rc_private.zdage_tutup(uuid, boolean) from public, anon, authenticated;

create or replace function public.rc_zdage_apply_mulai(p_upload_id uuid, p_kosong text[] default '{}'::text[])
returns jsonb language plpgsql security definer set search_path to '' set statement_timeout to '90s' set lock_timeout to '30s' as $f$
declare u public.rc_zdage_uploads; v_galat text; v_kosong text[]; v_salah text; s record;
begin
  perform rc_private.require_tab('compilation.debtor');
  perform pg_advisory_xact_lock(hashtextextended('rc-zdage-apply', 0));
  select * into u from public.rc_zdage_uploads where id = p_upload_id for update;
  if not found or (u.uploaded_by <> auth.uid() and not rc_private.is_system_manager()) then
    raise exception 'Upload tidak ditemukan'; end if;
  -- Idempoten: menerapkan ulang tidak membuat tawaran baru dan tidak memperpanjang deadline.
  if u.status = 'applied' then
    return coalesce(u.hasil, '{}'::jsonb) || jsonb_build_object('status', 'success', 'sudahDiterapkan', true,
      'message', 'Upload ini sudah diterapkan pada ' || to_char(u.applied_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || '; tidak ada yang berubah.');
  end if;
  if u.status not in ('preview', 'menerapkan') then raise exception 'Upload ini sudah dibatalkan; unggah ulang berkasnya'; end if;
  if u.row_count = 0 then raise exception 'Upload belum berisi baris'; end if;
  v_galat := rc_private.zdage_galat(u.id);
  if v_galat is not null then
    raise exception 'Upload ditolak: bulan tarikan file lebih tua dari data debtor yang sudah berlaku untuk depot %', v_galat; end if;

  if u.status = 'preview' then
    -- "Tidak ada tagihan" hanya untuk depot yang memang tidak ada di file.
    v_kosong := array(select distinct upper(btrim(x)) from unnest(coalesce(p_kosong, '{}')) x where btrim(x) <> '');
    select string_agg(x, ', ') into v_salah from unnest(v_kosong) x
     where not exists(select 1 from public.depots d where d.depot_code = x and d.archived_at is null
                       and not exists(select 1 from public.rc_zdage_rows r where r.upload_id = u.id and r.depot_id = d.id));
    if v_salah is not null then raise exception 'Depot "Tidak ada tagihan" tidak sah: %', v_salah; end if;

    -- Penerapan lama pengunggah ini yang terhenti ditutup, supaya data lamanya tidak dilanjutkan menimpa berkas ini.
    for s in select id from public.rc_zdage_uploads where status = 'menerapkan' and uploaded_by = u.uploaded_by and id <> u.id loop
      perform rc_private.zdage_tutup(s.id, true);
    end loop;

    update public.rc_zdage_uploads set status = 'menerapkan', depots_kosong = v_kosong, toleransi = rc_private.zdage_toleransi(), mode = rc_private.zdage_mode(),
           progres = jsonb_build_object('hari', (now() at time zone 'Asia/Jakarta')::date, 'kosong', to_jsonb(v_kosong), 'depot', '{}'::jsonb,
             'bagian', coalesce((select jsonb_agg(jsonb_build_object('kode', b.depot_code, 'nama', b.depot_name, 'notYet', b.not_yet) order by b.depot_code)
                                   from rc_private.zdage_bagian(u.id, v_kosong) b), '[]'::jsonb))
     where id = u.id returning * into u;
  end if;

  return jsonb_build_object('status', 'success', 'sudahDiterapkan', false, 'bagian', u.progres->'bagian',
    'selesai', coalesce((select jsonb_agg(k) from jsonb_object_keys(u.progres->'depot') k), '[]'::jsonb));
end $f$;

create or replace function public.rc_zdage_apply_bagian(p_upload_id uuid, p_depot text)
returns jsonb language plpgsql security definer set search_path to '' set statement_timeout to '90s' set lock_timeout to '30s' as $f$
declare u public.rc_zdage_uploads; v_depot uuid; v_kode text := btrim(coalesce(p_depot, '')); v jsonb; v_kosong text[];
begin
  perform rc_private.require_tab('compilation.debtor');
  perform pg_advisory_xact_lock(hashtextextended('rc-zdage-apply', 0));
  select * into u from public.rc_zdage_uploads where id = p_upload_id for update;
  if not found or (u.uploaded_by <> auth.uid() and not rc_private.is_system_manager()) then
    raise exception 'Upload tidak ditemukan'; end if;
  if u.status <> 'menerapkan' then raise exception 'Upload ini tidak sedang diterapkan; unggah ulang berkasnya'; end if;
  -- Jawaban sebelumnya hilang di jaringan: depot ini sudah selesai, tidak dikerjakan dua kali.
  if u.progres->'depot' ? v_kode then
    return (u.progres->'depot'->v_kode) || jsonb_build_object('status', 'success', 'sudah', true);
  end if;
  if not (u.progres->'bagian' @> jsonb_build_array(jsonb_build_object('kode', v_kode))) then
    raise exception 'Depot % bukan bagian upload ini', v_kode; end if;
  select id into v_depot from public.depots where depot_code = v_kode and archived_at is null;
  if v_depot is null then raise exception 'Depot % tidak ada di Depot Master', v_kode; end if;

  v_kosong := array(select jsonb_array_elements_text(u.progres->'kosong'));
  v := rc_private.zdage_terapkan_depot(u.id, v_depot, v_kosong, u.toleransi, u.mode, (u.progres->>'hari')::date);
  update public.rc_zdage_uploads set progres = jsonb_set(progres, array['depot', v_kode], v) where id = u.id;
  return v || jsonb_build_object('status', 'success', 'sudah', false);
end $f$;

create or replace function public.rc_zdage_apply_selesai(p_upload_id uuid)
returns jsonb language plpgsql security definer set search_path to '' set statement_timeout to '90s' set lock_timeout to '30s' as $f$
declare u public.rc_zdage_uploads; v_sisa text; v_hasil jsonb;
begin
  perform rc_private.require_tab('compilation.debtor');
  perform pg_advisory_xact_lock(hashtextextended('rc-zdage-apply', 0));
  select * into u from public.rc_zdage_uploads where id = p_upload_id for update;
  if not found or (u.uploaded_by <> auth.uid() and not rc_private.is_system_manager()) then
    raise exception 'Upload tidak ditemukan'; end if;
  if u.status = 'applied' then
    return coalesce(u.hasil, '{}'::jsonb) || jsonb_build_object('status', 'success', 'sudahDiterapkan', true,
      'message', 'Upload ini sudah diterapkan pada ' || to_char(u.applied_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || '; tidak ada yang berubah.');
  end if;
  if u.status <> 'menerapkan' then raise exception 'Upload ini tidak sedang diterapkan; unggah ulang berkasnya'; end if;
  select string_agg(b->>'kode', ', ') into v_sisa from jsonb_array_elements(u.progres->'bagian') b where not (u.progres->'depot' ? (b->>'kode'));
  if v_sisa is not null then raise exception 'Masih ada depot yang belum diterapkan: %', v_sisa; end if;

  v_hasil := rc_private.zdage_tutup(u.id, false);
  return v_hasil || jsonb_build_object('status', 'success', 'sudahDiterapkan', false,
    'message', (v_hasil->>'tawaranBaru') || ' toko lunas ditawarkan ke depot, batas proses ' || (v_hasil->>'deadline') || '.'
      || case when (v_hasil->>'kembaliRestricted')::integer > 0 then ' ' || (v_hasil->>'kembaliRestricted') || ' tawaran tidak lunas lagi dan kembali ke Restricted.' else '' end);
end $f$;

-- Sekaligus dalam satu transaksi, memakai bagian yang sama.
create or replace function public.rc_zdage_apply(p_upload_id uuid, p_kosong text[] default '{}'::text[])
returns jsonb language plpgsql security definer set search_path to '' set statement_timeout to '90s' set lock_timeout to '30s' as $f$
declare m jsonb; b jsonb;
begin
  m := public.rc_zdage_apply_mulai(p_upload_id, p_kosong);
  if coalesce((m->>'sudahDiterapkan')::boolean, false) then return m; end if;
  for b in select value from jsonb_array_elements(m->'bagian') loop
    perform public.rc_zdage_apply_bagian(p_upload_id, b->>'kode');
  end loop;
  return public.rc_zdage_apply_selesai(p_upload_id);
end $f$;

revoke all on function public.rc_zdage_preview_awal(uuid, text[]), public.rc_zdage_preview_bagian(uuid, text[], text), public.rc_zdage_apply_mulai(uuid, text[]),
  public.rc_zdage_apply_bagian(uuid, text), public.rc_zdage_apply_selesai(uuid) from public, anon;
grant execute on function public.rc_zdage_preview_awal(uuid, text[]), public.rc_zdage_preview_bagian(uuid, text[], text), public.rc_zdage_apply_mulai(uuid, text[]),
  public.rc_zdage_apply_bagian(uuid, text), public.rc_zdage_apply_selesai(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';

do $cek$ begin
  if to_regprocedure('rc_private.zdage_evaluasi(uuid,text[],numeric,text,uuid)') is null then raise exception 'GAGAL: evaluasi'; end if;
  if pg_get_functiondef('public.rc_zdage_stage(text,timestamp with time zone,jsonb,uuid)'::regprocedure) !~ '20261163860000' then raise exception 'GAGAL: stage'; end if;
  if pg_get_functiondef('public.rc_zdage_riwayat()'::regprocedure) !~ 'belumSelesai' then raise exception 'GAGAL: riwayat'; end if;
end $cek$;
