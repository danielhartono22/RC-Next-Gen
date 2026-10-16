-- ==========================================================================================
-- Workflow dan Analytics dimuat bertahap dengan kursor, dan murah per baris
-- ==========================================================================================
-- Keadaan di dev, 100 ribu klaim, 30 ribu di antaranya di antrean Release / Claim / Clearing:
--
--   rc_legacy_workflow   Sejak 20261162010000 mengembalikan 1000 baris per panggilan, tetapi
--                        aplikasi hanya pernah memanggil halaman PERTAMA. 29 ribu baris antrean
--                        tidak pernah tampil - tanpa pemberitahuan apa pun.
--   rc_legacy_dashboard  Mengembalikan SELURUH klaim dalam satu panggilan, dua kali (history dan
--                        compileData), dengan can_tab dan can_access dihitung per baris dan
--                        claim_details - fungsi SECURITY DEFINER yang menjalankan empat subkueri -
--                        dipanggil per baris. Selalu melewati batas 8 detik: Analytics kosong.
--
-- PERUBAHAN
--
-- 1. Kedua fungsi menerima kursor (p_setelah_waktu, p_setelah_id) dan mengembalikan
--    "berikutnya" - kursor halaman sesudahnya, atau null bila sudah habis. Aplikasi memanggil
--    berulang sampai habis, menampilkan halaman pertama segera. Kursor dipakai, bukan offset:
--    dokumen yang diproses orang lain selama pemuatan tidak membuat baris lain terlewat atau
--    muncul dua kali, karena posisi halaman berikutnya tidak bergantung pada jumlah baris di
--    depannya. Urutan tidak berubah: updated_at terbaru lebih dulu, id sebagai penentu seri.
--
--    Jumlah total hanya dihitung pada halaman pertama. Untuk Analytics jumlah itu berupa
--    PERKIRAAN (perkiraanTotal: klaim dalam jangkauan, tanpa join customer) yang hanya dipakai
--    untuk indikator kemajuan: hitungan pasti membutuhkan join ke 100 ribu customer dan pada
--    cache dingin dapat memakan beberapa detik. Jumlah yang tampil di layar tetap dihitung dari
--    baris yang benar-benar dimuat.
--
-- 2. Nilai per baris dihitung dengan cara yang lebih murah, HASILNYA SAMA:
--      * jangkauan depot dihitung sekali, bukan can_access per baris (kesetaraannya sudah
--        dibuktikan per pengguna x depot di 20261162020000);
--      * can_tab di WHERE dibuang - fungsi sudah menolak di baris pertamanya bila keduanya
--        salah, jadi di WHERE nilainya selalu benar;
--      * isi claim_details ditulis langsung dengan kolom yang sudah di-join, dan riwayat status
--        dibaca SEKALI per klaim untuk pengaju, pelaku terakhir dan tanda reprocess;
--      * keterangan (remark) disusun oleh rc_private.claim_remark_dari - satu-satunya tempat
--        aturannya, dipakai juga oleh claim_remark sendiri.
--
-- 3. compileData tidak lagi dikirim. Isinya adalah baris-baris history yang sama (join dan
--    penyaring yang sama) dengan enam kolom yang juga ada di history; adaptor menyusunnya dari
--    history. Dibuktikan di bawah: jumlah barisnya sama untuk setiap pengguna.
--
-- DUA KESAMAAN YANG DIJAGA DENGAN SENGAJA
--   * "osc" dibaca dari profiles SEBAGAI PEMANGGIL (dulu left join biasa, tunduk RLS).
--   * "processBy" dibaca SEBAGAI PEMILIK (dulu di dalam claim_details, SECURITY DEFINER).
--   Keduanya dipertahankan persis, termasuk perbedaannya.
--
-- PEMBUKTIAN
--   * Penjaga pra-citra: definisi lama harus persis yang diukur di dev (MD5). Bila berbeda -
--     misalnya di prod ada perubahan lain - migrasi berhenti alih-alih menimpanya.
--   * Workflow: halaman 1 dan 2 dari fungsi LAMA dibandingkan elemen per elemen dengan fungsi
--     BARU, untuk setiap pengguna, sebelum fungsi lama dihapus.
--   * Analytics: tiga jendela (awal, lanjutan, tengah) dari ekspresi LAMA dibandingkan elemen
--     per elemen dengan halaman fungsi BARU, untuk setiap pengguna. Bila datanya kecil
--     (<= 3000), keluaran fungsi lama seluruhnya dibandingkan dengan gabungan semua halaman.
--   * claim_remark: sidik jari keluaran untuk seluruh klaim sebelum dan sesudah.
--
-- Aman dijalankan berulang: bila fungsi lama sudah tidak ada, pembuktian yang membutuhkannya
-- dilewati dan sisanya menulis ulang definisi yang sama.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 0. Penjaga pra-citra
-- ------------------------------------------------------------------------------------------
do $pra$
declare
  f record; md5_kini text;
begin
  for f in select * from (values
      ('public.rc_legacy_workflow(integer,integer)', 'ac2fe1647ccc6235ea2f786ebb69c44d'),
      ('public.rc_legacy_dashboard()',               'e59568b9b4cb8e80c3d4d14d325dd35e'),
      ('rc_private.claim_details(public.claims)',    'f062e977729f0ce7b828388e8202b1ec')) v(sig, harapan)
  loop
    if to_regprocedure(f.sig) is null then
      if f.sig like 'rc_private.claim_details%' then
        raise exception 'rc_private.claim_details tidak ditemukan.'; end if;
      raise notice '% sudah tidak ada - migrasi ini pernah diterapkan.', f.sig;
      continue;
    end if;
    md5_kini := md5(pg_get_functiondef(to_regprocedure(f.sig)));
    if md5_kini <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %, harapan %). '
        'Bandingkan dulu definisinya sebelum menerapkan migrasi ini.', f.sig, md5_kini, f.harapan;
    end if;
  end loop;

  -- claim_remark boleh berupa definisi lama atau yang sudah memakai claim_remark_dari.
  md5_kini := md5(pg_get_functiondef('rc_private.claim_remark(public.claims)'::regprocedure));
  if md5_kini <> 'f3088b8f1083f1551d45c3becddb1e9d'
     and pg_get_functiondef('rc_private.claim_remark(public.claims)'::regprocedure) !~ 'claim_remark_dari' then
    raise exception 'DITOLAK: definisi rc_private.claim_remark berbeda dari yang diukur (md5 %).', md5_kini;
  end if;
end
$pra$;

-- ------------------------------------------------------------------------------------------
-- 1. Pembantu
-- ------------------------------------------------------------------------------------------
-- Aturan keterangan, di satu tempat. Tanpa klausa SET dan tanpa subkueri sehingga PostgreSQL
-- menanamnya langsung ke kueri pemanggil. STABLE karena concat_ws digolongkan STABLE.
create or replace function rc_private.claim_remark_dari(
  p_reprocessed_at timestamptz, p_ada_reprocess boolean, p_cb_berubah boolean)
returns text language sql stable as $fn$
  select concat_ws(', ',
    case when p_reprocessed_at is not null or p_ada_reprocess then 'Reprocessing' end,
    case when p_cb_berubah then 'CB Type Changed' end);
$fn$;
revoke all on function rc_private.claim_remark_dari(timestamptz, boolean, boolean) from public, anon;
grant execute on function rc_private.claim_remark_dari(timestamptz, boolean, boolean) to authenticated, service_role;

create temp table _sidik_remark(tahap text primary key, sidik text, baris bigint) on commit drop;
insert into _sidik_remark
  select 'sebelum', md5(string_agg(c.id::text || '=' || coalesce(rc_private.claim_remark(c), '<null>'), ',' order by c.id)), count(*)
    from public.claims c;

create or replace function rc_private.claim_remark(c public.claims)
returns text language sql stable set search_path to '' as $fn$
  select rc_private.claim_remark_dari(c.reprocessed_at,
    exists(select 1 from public.claim_status_history h
            where h.claim_id = c.id and h.action like '%reprocess%'),
    c.cashback_type_changed);
$fn$;

insert into _sidik_remark
  select 'sesudah', md5(string_agg(c.id::text || '=' || coalesce(rc_private.claim_remark(c), '<null>'), ',' order by c.id)), count(*)
    from public.claims c;

do $remark$
declare a record; b record;
begin
  select * into a from _sidik_remark where tahap = 'sebelum';
  select * into b from _sidik_remark where tahap = 'sesudah';
  if a.sidik is distinct from b.sidik then
    raise exception 'GAGAL: keluaran claim_remark berubah pada % klaim.', a.baris; end if;
  raise notice 'claim_remark identik untuk % klaim.', a.baris;
end
$remark$;

-- Nama lengkap seluruh profil, dibaca sebagai pemilik - padanan join ke profiles di dalam
-- claim_details (SECURITY DEFINER). Nama saja, tanpa kolom lain.
create or replace function rc_private.peta_nama_lengkap()
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select coalesce(jsonb_object_agg(id::text, full_name), '{}'::jsonb) from public.profiles;
$fn$;
revoke all on function rc_private.peta_nama_lengkap() from public, anon;
grant execute on function rc_private.peta_nama_lengkap() to authenticated, service_role;

-- Urutan Analytics: seluruh klaim yang belum diarsip, updated_at terbaru lebih dulu.
create index if not exists claims_terbaru_idx on public.claims (updated_at desc, id)
  where archived_at is null;

-- ------------------------------------------------------------------------------------------
-- 2. rc_legacy_workflow dengan kursor
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_legacy_workflow(
  p_limit integer default 1000, p_setelah_waktu timestamptz default null, p_setelah_id uuid default null)
returns jsonb language plpgsql stable set search_path to '' as $function$
declare rows_json jsonb; nama jsonb;
 v_limit int; v_total bigint; v_semua boolean; v_depot uuid[];
 v_ids uuid[]; v_akhir_waktu timestamptz; v_akhir_id uuid;
begin
 if not rc_private.can_access(null) then raise exception 'Access denied' using errcode='42501'; end if;
 nama := rc_private.peta_nama_pelaku();
 -- Batas atas dijaga di sini, bukan dipercayakan pada pemanggil.
 v_limit := least(greatest(coalesce(p_limit,1000),1),2000);
 select l.semua, l.depot into v_semua, v_depot from rc_private.lingkup_depot_saya() l;

 -- Jumlah seluruh antrean hanya pada halaman pertama; halaman berikutnya tidak membutuhkannya.
 -- Dua kueri terpisah, bukan satu dengan OR: bagi perencana kueri, OR yang memuat variabel
 -- tidak dapat disederhanakan dan setiap baris tetap diperiksa.
 if p_setelah_waktu is null then
  if v_semua then
   select count(*) into v_total from public.claims c where c.archived_at is null and c.status in('approved','released','claimed') and c.pending_approval is null;
  else
   select count(*) into v_total from public.claims c where c.archived_at is null and c.depot_id = any(v_depot) and c.status in('approved','released','claimed') and c.pending_approval is null;
  end if;
 end if;

 -- Baris halaman ini dipilih lebih dulu, baru di-join. Syarat kursor ditulis dengan
 -- "updated_at <= kursor" di depan supaya menjadi batas awal pemindaian indeks, bukan
 -- penyaring yang memeriksa ulang seluruh halaman sebelumnya.
 select coalesce(array_agg(t.id order by t.updated_at desc, t.id), '{}'::uuid[]),
        (array_agg(t.updated_at order by t.updated_at, t.id desc))[1],
        (array_agg(t.id order by t.updated_at, t.id desc))[1]
   into v_ids, v_akhir_waktu, v_akhir_id
   from (select c.id, c.updated_at from public.claims c
          where c.archived_at is null and (v_semua or c.depot_id = any(v_depot))
            and c.status in('approved','released','claimed') and c.pending_approval is null
            and (p_setelah_waktu is null
                 or (c.updated_at <= p_setelah_waktu
                     and (c.updated_at < p_setelah_waktu or c.id > p_setelah_id)))
          order by c.updated_at desc, c.id
          limit v_limit) t;

 select coalesce(jsonb_agg(t.x order by t.urut),'[]'::jsonb) into rows_json from (
  select u.urut, jsonb_build_object(
   'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
   'depot',d.depot_name,'kodeDepot',d.depot_code,
   'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'statusPajakCamp',coalesce(ca.tax_status,''),
   'statusPajakCust',coalesce(c.tax_subject,''),
   'cbNet',c.cb_net,'grossUpCb',c.gross_up,'totTagih',c.total_billing,
   'periodeStart',rc_private.legacy_date(c.period_start),'periodeEnd',rc_private.legacy_date(c.period_end),
   'tglLunas',rc_private.legacy_date(c.paid_on),
   'tglUpload',rc_private.legacy_ts(c.uploaded_at),'tglRelease',rc_private.legacy_ts(c.released_at),
   'tglClaim',rc_private.legacy_ts(c.claimed_at),'tglClearing',rc_private.legacy_ts(c.cleared_at),
   'tglProses',case when c.status='done' and c.cleared_at is not null
                    then rc_private.legacy_ts(c.cleared_at) else '-' end,
   'batchUpload',coalesce(c.batch_upload,''),'batchRelease',coalesce(c.batch_release,''),
   'batchClaim',coalesce(c.batch_claim,''),'batchClearing',coalesce(c.batch_clearing,''),
   'approval',coalesce(c.approval,''),'top',coalesce(s.top_text,''),
   'ktp',coalesce(s.ktp,''),'npwp',coalesce(s.npwp,''),'bankCust',coalesce(s.bank,''),
   'bank',coalesce(s.bank,''),'noRekening',coalesce(s.account_number,''),
   'namaRekening',coalesce(s.account_name,''),'pemilikRekening',coalesce(s.account_name,''),
   'contactPerson',coalesce(cu.contact_person,''),
   -- Pelaku tiap tahap. Kosong berarti tidak tercatat, bukan tidak pernah terjadi.
   'createdBy',coalesce(nama->>(c.created_by::text),''),
   'submittedBy',coalesce(nama->>(pel.submit_by::text),''),
   'approvedBy',coalesce(nama->>(pel.approve_by::text),''),
   'tglApprove',rc_private.legacy_ts(c.approved_at),
   'releasedBy',coalesce(nama->>(pel.release_by::text),''),
   'claimedBy',coalesce(nama->>(pel.claim_by::text),''),
   'clearedBy',coalesce(nama->>(pel.clear_by::text),''),
   'versionNo',c.version_no,
   'remark',rc_private.claim_remark_dari(c.reprocessed_at, pel.ada_reprocess, c.cashback_type_changed),
   'campaignYear',extract(year from coalesce(c.period_start,ca.period_start)),
   'rebate',lower(btrim(rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type))))='rebate') as x
  from unnest(v_ids) with ordinality as u(id, urut)
  join public.claims c on c.id = u.id
  left join public.depots d on d.id=c.depot_id
  left join public.customers cu on cu.id=c.customer_id
  left join public.campaigns ca on ca.id=c.campaign_id
  left join rc_private.claim_sensitive s on s.claim_id=c.id
  -- Pelaku terakhir untuk tiap tahap, dan tanda reprocess - satu kali baca riwayat per klaim.
  -- Yang diambil yang terbaru: sebuah dokumen dapat ditolak lalu di-release ulang, dan yang
  -- relevan adalah pelaku terakhir.
  left join lateral (
    select
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.action='submit' and h.actor_id is not null))[1] as submit_by,
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='approved' and h.actor_id is not null))[1] as approve_by,
         (array_agg(h.actor_id order by h.created_at desc)
         filter (where h.to_status='released' and h.actor_id is not null))[1] as release_by,
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='claimed' and h.actor_id is not null))[1] as claim_by,
      (array_agg(h.actor_id order by h.id desc)
         filter (where h.to_status='done' and h.actor_id is not null))[1] as clear_by,
      coalesce(bool_or(h.action like '%reprocess%'), false) as ada_reprocess
    from public.claim_status_history h where h.claim_id = c.id) pel on true) t;

 -- Rebate dipisah tegas: tidak muncul di antrean bertahap, hanya di Bulk Process.
 return jsonb_build_object('status','success','total',v_total,'dimuat',jsonb_array_length(rows_json),
  'berikutnya',case when cardinality(v_ids) = v_limit
                    then jsonb_build_object('waktu',v_akhir_waktu,'id',v_akhir_id) end,
  'releaseData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where rc_private.can_tab('release.list') and v->>'status'='Approved' and not (v->>'rebate')::boolean),
  'claimFinData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where rc_private.can_tab('process.claimFin') and v->>'status'='Released' and not (v->>'rebate')::boolean),
  'clearingData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where rc_private.can_tab('process.clearing') and v->>'status'='Claimed' and not (v->>'rebate')::boolean),
  'bulkRebateData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where rc_private.can_tab('bulk.rebate') and (v->>'rebate')::boolean and v->>'status' <> 'Submitted'));
end $function$;

-- Pembuktian: halaman 1 dan 2 fungsi lama = fungsi baru, untuk setiap pengguna.
do $uji_workflow$
declare u record; lama jsonb; baru jsonb; k text; n_pengguna int := 0;
begin
  if to_regprocedure('public.rc_legacy_workflow(integer,integer)') is null then
    raise notice 'Workflow lama sudah tidak ada; pembuktian dilewati.'; return; end if;

  for u in select id, user_code from public.profiles where status = 'active' order by user_code loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    set local role authenticated;
    if not rc_private.can_access(null) then reset role; continue; end if;

    lama := public.rc_legacy_workflow(1000, 0);
    baru := public.rc_legacy_workflow(1000, null::timestamptz, null::uuid);
    if (lama->'total') is distinct from (baru->'total') then
      raise exception 'GAGAL workflow %: total lama %, baru %.', u.user_code, lama->'total', baru->'total'; end if;
    foreach k in array array['releaseData','claimFinData','clearingData','bulkRebateData'] loop
      if (lama->k) is distinct from (baru->k) then
        raise exception 'GAGAL workflow % halaman 1: % berbeda (% vs % baris).',
          u.user_code, k, jsonb_array_length(lama->k), jsonb_array_length(baru->k); end if;
    end loop;

    if baru->'berikutnya' <> 'null'::jsonb then
      lama := public.rc_legacy_workflow(1000, 1000);
      baru := public.rc_legacy_workflow(1000, (baru->'berikutnya'->>'waktu')::timestamptz,
                                              (baru->'berikutnya'->>'id')::uuid);
      foreach k in array array['releaseData','claimFinData','clearingData','bulkRebateData'] loop
        if (lama->k) is distinct from (baru->k) then
          raise exception 'GAGAL workflow % halaman 2: % berbeda (% vs % baris).',
            u.user_code, k, jsonb_array_length(lama->k), jsonb_array_length(baru->k); end if;
      end loop;
    end if;
    reset role;
    n_pengguna := n_pengguna + 1;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'Workflow baru identik dengan lama untuk % pengguna.', n_pengguna;
exception when others then
  reset role; raise;
end
$uji_workflow$;

drop function if exists public.rc_legacy_workflow(integer, integer);
revoke all on function public.rc_legacy_workflow(integer, timestamptz, uuid) from public, anon;
grant execute on function public.rc_legacy_workflow(integer, timestamptz, uuid) to authenticated, service_role;

-- ------------------------------------------------------------------------------------------
-- 3. rc_legacy_dashboard dengan kursor
-- ------------------------------------------------------------------------------------------
-- Fungsi lama diberi nama sementara sebelum versi baru dibuat. Versi baru seluruh argumennya
-- ber-default, sehingga "rc_legacy_dashboard()" cocok dengan keduanya dan pemanggilan di
-- pembuktian menjadi ambigu. Di dev cabang pembuktian yang memanggilnya tidak pernah jalan
-- (datanya di atas 3000 baris); di prod jalan - ditemukan 6 Oktober 2026.
do $ganti_nama$
begin
  if to_regprocedure('public.rc_legacy_dashboard()') is not null then
    alter function public.rc_legacy_dashboard() rename to rc_legacy_dashboard_lama_050000; end if;
end
$ganti_nama$;

create or replace function public.rc_legacy_dashboard(
  p_limit integer default 1000, p_setelah_waktu timestamptz default null, p_setelah_id uuid default null)
returns jsonb language plpgsql stable set search_path to '' as $function$
declare v_limit int; v_semua boolean; v_depot uuid[]; v_total bigint; rows_json jsonb;
 nama_pemilik jsonb; nama_terlihat jsonb;
 v_ids uuid[]; v_akhir_waktu timestamptz; v_akhir_id uuid;
begin
 if not (rc_private.can_tab('analytics.history') or rc_private.can_tab('analytics.summary')) then raise exception 'Analytics tab access denied' using errcode='42501';end if;
 if not rc_private.can_access(null,'view_analytics') then raise exception 'Access denied' using errcode='42501'; end if;
 v_limit := least(greatest(coalesce(p_limit,1000),1),5000);

 -- Padanan can_access(depot) yang dihitung sekali (lihat 20261162020000).
 v_semua := rc_private.saya_sm();
 v_depot := rc_private.depot_akses_saya();
 -- processBy dulu dibaca di dalam claim_details (SECURITY DEFINER): sebagai pemilik.
 nama_pemilik := rc_private.peta_nama_lengkap();
 -- osc dulu dibaca lewat left join biasa: sebagai pemanggil, tunduk RLS profiles.
 select coalesce(jsonb_object_agg(p.id::text, p.full_name),'{}'::jsonb) into nama_terlihat
   from public.profiles p;

 -- Perkiraan untuk indikator kemajuan saja: klaim dalam jangkauan, tanpa join ke customer
 -- dan campaign. Bisa sedikit lebih besar dari jumlah baris yang akhirnya dimuat.
 if p_setelah_waktu is null then
  select count(*) into v_total from public.claims c
   where c.archived_at is null and (v_semua or c.depot_id = any(v_depot));
 end if;

 select coalesce(array_agg(t.id order by t.updated_at desc, t.id), '{}'::uuid[]),
        (array_agg(t.updated_at order by t.updated_at, t.id desc))[1],
        (array_agg(t.id order by t.updated_at, t.id desc))[1]
   into v_ids, v_akhir_waktu, v_akhir_id
   from (select c.id, c.updated_at
           from public.claims c
           join public.depots d on d.id=c.depot_id
           join public.customers cu on cu.id=c.customer_id
           join public.campaigns ca on ca.id=c.campaign_id
          where c.archived_at is null and (v_semua or c.depot_id = any(v_depot))
            and (p_setelah_waktu is null
                 or (c.updated_at <= p_setelah_waktu
                     and (c.updated_at < p_setelah_waktu or c.id > p_setelah_id)))
          order by c.updated_at desc, c.id
          limit v_limit) t;

 select coalesce(jsonb_agg(t.x order by t.urut),'[]'::jsonb) into rows_json from (
  select u.urut, jsonb_build_object(
    'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
    'depot',d.depot_name,'osc',coalesce(nama_terlihat->>(pel.submit_by::text),''),
    'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
    'codeCampaign',ca.campaign_code,'campaign',ca.campaign_name,
    'validYear',extract(year from coalesce(c.period_start,ca.period_start))::text,'totalClaim',c.cb_net,'grossUpCb',c.gross_up,
    'tglUpload',rc_private.legacy_ts(c.uploaded_at),
    'tglClearing',rc_private.legacy_ts(c.cleared_at),
    'tglProses',case when c.status='done' and c.cleared_at is not null
                     then rc_private.legacy_ts(c.cleared_at) else '-' end,
    'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),
    'batchUpload',coalesce(c.batch_upload,''),'batchClearing',coalesce(c.batch_clearing,''))
   -- Padanan rc_private.claim_details(c). Cabang "{}" miliknya tidak pernah terjadi di sini:
   -- setiap baris sudah lolos penyaring jangkauan yang sama.
   || jsonb_build_object(
    'tglUpload',rc_private.legacy_ts(c.uploaded_at),'tglApprove',rc_private.legacy_ts(c.approved_at),
    'tglRelease',rc_private.legacy_ts(c.released_at),'tglClaim',rc_private.legacy_ts(c.claimed_at),
    'tglClearing',rc_private.legacy_ts(c.cleared_at),'tglBulk',rc_private.legacy_ts(c.bulk_processed_at),
    'submittedAt',c.uploaded_at,'approvedAt',c.approved_at,'releasedAt',c.released_at,'claimedAt',c.claimed_at,'doneAt',c.cleared_at,
    'batchUpload',coalesce(c.batch_upload,''),'batchRelease',coalesce(c.batch_release,''),
    'batchClaim',coalesce(c.batch_claim,''),'batchClearing',coalesce(c.batch_clearing,''),
    'soStart',rc_private.legacy_date(coalesce(c.extend_so_start,c.period_start,ca.period_start)),
    'soEnd',rc_private.legacy_date(coalesce(c.extend_so_end,c.period_end,ca.period_end)),
    'billingStart',rc_private.legacy_date(c.extend_billing_start),'billingEnd',rc_private.legacy_date(c.extend_billing_end),
    'remark',rc_private.claim_remark_dari(c.reprocessed_at, pel.ada_reprocess, c.cashback_type_changed),
    'processBy',coalesce(nama_pemilik->>(pel.proses_by::text),''),
    'pendingGroup',case when c.status in('not_yet','submitted') then 'Pending Depot'
      when c.status in('approved','released') then 'Pending OSC' when c.status='claimed' then 'Pending Finance'
      when c.status='done' then 'Done' else rc_private.legacy_status(c.status) end) as x
  from unnest(v_ids) with ordinality as u(id, urut)
  join public.claims c on c.id=u.id
  join public.depots d on d.id=c.depot_id
  join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  -- Riwayat dibaca sekali per klaim: pengaju terakhir (osc), pelaku terakhir (processBy)
  -- dan tanda reprocess (remark).
  left join lateral (
    select (array_agg(h.actor_id order by h.id desc) filter (where h.action='submit'))[1] as submit_by,
           (array_agg(h.actor_id order by h.id desc) filter (where h.actor_id is not null))[1] as proses_by,
           coalesce(bool_or(h.action like '%reprocess%'), false) as ada_reprocess
      from public.claim_status_history h where h.claim_id=c.id) pel on true) t;

 return jsonb_build_object('status','success','history',rows_json,
  'perkiraanTotal',v_total,'dimuat',jsonb_array_length(rows_json),
  'berikutnya',case when cardinality(v_ids) = v_limit
                    then jsonb_build_object('waktu',v_akhir_waktu,'id',v_akhir_id) end);
end $function$;

-- Pembuktian Analytics.
do $uji_dashboard$
declare
  u record; baru jsonb; lama jsonb; gabung jsonb; kursor jsonb; tengah record;
  n_lama bigint; n_baru bigint; n_pengguna int := 0; jendela int;
begin
  if to_regprocedure('public.rc_legacy_dashboard_lama_050000()') is null then
    raise notice 'Dashboard lama sudah tidak ada; pembuktian dilewati.'; return; end if;

  for u in select id, user_code from public.profiles where status = 'active' order by user_code loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    set local role authenticated;
    if not ((rc_private.can_tab('analytics.history') or rc_private.can_tab('analytics.summary'))
            and rc_private.can_access(null,'view_analytics')) then
      reset role; continue; end if;

    -- a. Jumlah baris: compileData lama (penyaring persis) = baris yang dipilih fungsi baru.
    --    Fungsi baru memilih dengan predikat di bawah, dibagi per jendela kursor yang tidak
    --    tumpang-tindih; jadi gabungan seluruh halamannya adalah persis himpunan ini.
    select count(*) into n_lama
      from public.claims c
      join public.depots d on d.id=c.depot_id
      join public.customers cu on cu.id=c.customer_id
      join public.campaigns ca on ca.id=c.campaign_id
     where c.archived_at is null and rc_private.can_access(c.depot_id);
    select count(*) into n_baru
      from public.claims c
      join public.depots d on d.id=c.depot_id
      join public.customers cu on cu.id=c.customer_id
      join public.campaigns ca on ca.id=c.campaign_id
     where c.archived_at is null
       and (rc_private.saya_sm() or c.depot_id = any(rc_private.depot_akses_saya()));
    if n_baru <> n_lama then
      raise exception 'GAGAL dashboard %: baris baru %, compileData lama %.', u.user_code, n_baru, n_lama; end if;
    baru := public.rc_legacy_dashboard(1000, null::timestamptz, null::uuid);

    if n_lama <= 3000 then
      -- b1. Data kecil: seluruh keluaran fungsi lama = gabungan semua halaman baru.
      lama := public.rc_legacy_dashboard_lama_050000();
      gabung := baru->'history'; kursor := baru->'berikutnya';
      while kursor <> 'null'::jsonb loop
        baru := public.rc_legacy_dashboard(1000, (kursor->>'waktu')::timestamptz, (kursor->>'id')::uuid);
        gabung := gabung || (baru->'history'); kursor := baru->'berikutnya';
      end loop;
      -- Urutan lama hanya "updated_at desc" tanpa penentu seri, jadi dibandingkan sebagai
      -- himpunan berurutan menurut noDoc - unik per klaim.
      if (select jsonb_agg(e order by e->>'noDoc') from jsonb_array_elements(lama->'history') e)
         is distinct from (select jsonb_agg(e order by e->>'noDoc') from jsonb_array_elements(gabung) e) then
        raise exception 'GAGAL dashboard %: history lama berbeda dari gabungan halaman baru.', u.user_code; end if;
    else
      -- b2. Data besar: tiga jendela - awal, lanjutan, dan tengah.
      select c.updated_at, c.id into tengah from public.claims c
       where c.archived_at is null order by c.updated_at desc, c.id offset (n_lama / 2) limit 1;
      for jendela in 1..3 loop
        if jendela = 1 then kursor := 'null'::jsonb;
        elsif jendela = 2 then kursor := baru->'berikutnya';
        else kursor := jsonb_build_object('waktu', tengah.updated_at, 'id', tengah.id); end if;
        if kursor = 'null'::jsonb and jendela > 1 then continue; end if;

        baru := public.rc_legacy_dashboard(1000,
                  case when kursor = 'null'::jsonb then null else (kursor->>'waktu')::timestamptz end,
                  case when kursor = 'null'::jsonb then null else (kursor->>'id')::uuid end);

        -- Ekspresi LAMA, disalin persis dari definisi yang dijaga MD5 di bagian 0,
        -- hanya ditambah jendela kursor dan penentu seri yang sama.
        select coalesce(jsonb_agg(t.x order by t.w desc, t.i), '[]'::jsonb) into lama from (
         select c.updated_at w, c.id i, jsonb_build_object(
          'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
          'depot',d.depot_name,'osc',coalesce(p.full_name,''),
          'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
          'codeCampaign',ca.campaign_code,'campaign',ca.campaign_name,
          'validYear',extract(year from coalesce(c.period_start,ca.period_start))::text,'totalClaim',c.cb_net,'grossUpCb',c.gross_up,
          'tglUpload',rc_private.legacy_ts(c.uploaded_at),
          'tglClearing',rc_private.legacy_ts(c.cleared_at),
          'tglProses',case when c.status='done' and c.cleared_at is not null
                           then rc_private.legacy_ts(c.cleared_at) else '-' end,
          'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),
          'batchUpload',coalesce(c.batch_upload,''),'batchClearing',coalesce(c.batch_clearing,'')) || rc_private.claim_details(c) as x
         from public.claims c
         join public.depots d on d.id=c.depot_id
         join public.customers cu on cu.id=c.customer_id
         join public.campaigns ca on ca.id=c.campaign_id
         left join lateral (select h.actor_id from public.claim_status_history h
           where h.claim_id=c.id and h.action='submit' order by h.id desc limit 1) sub on true
         left join public.profiles p on p.id=sub.actor_id
         where (rc_private.can_tab('analytics.history') or rc_private.can_tab('analytics.summary'))
           and c.archived_at is null and rc_private.can_access(c.depot_id)
           and (kursor = 'null'::jsonb
                or c.updated_at < (kursor->>'waktu')::timestamptz
                or (c.updated_at = (kursor->>'waktu')::timestamptz and c.id > (kursor->>'id')::uuid))
         order by c.updated_at desc, c.id
         limit 1000) t;

        if lama is distinct from baru->'history' then
          raise exception 'GAGAL dashboard % jendela %: % baris lama vs % baris baru berbeda.',
            u.user_code, jendela, jsonb_array_length(lama), jsonb_array_length(baru->'history'); end if;
      end loop;
    end if;
    reset role;
    n_pengguna := n_pengguna + 1;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'Analytics baru identik dengan lama untuk % pengguna.', n_pengguna;
exception when others then
  reset role; raise;
end
$uji_dashboard$;

drop function if exists public.rc_legacy_dashboard();
drop function if exists public.rc_legacy_dashboard_lama_050000();
revoke all on function public.rc_legacy_dashboard(integer, timestamptz, uuid) from public, anon;
grant execute on function public.rc_legacy_dashboard(integer, timestamptz, uuid) to authenticated, service_role;
