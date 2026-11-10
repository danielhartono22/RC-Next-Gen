-- ==========================================================================================
-- Efisiensi server: hasil tetap sama, biayanya turun
-- ==========================================================================================
-- Pemilik, 9 November 2026: "kerjakan semua efisiensi". Diukur di prod dan dev sebelum diubah:
-- * Pembantu per baris dengan SET search_path tidak dapat di-inline: rekening_tampil dan
--   claim_remark_dari memakan sekitar 0,9 ms per baris pada Analytics, Workflow, Document Center.
--   Kini tanpa SET (nama sudah lengkap, tidak membaca tabel) sehingga menyatu dengan kuerinya.
-- * rc_legacy_workflow memanggil can_tab (±2 ms) per baris di penyaring antrean; kini sekali di awal.
-- * tab_rights memanggil zdage_tab_boleh untuk seluruh tab padahal hanya 5 tab yang terpengaruh.
-- * Open dan Restricted memanggil boleh_open per klaim Not Yet, empat kali per permintaan, dan
--   debtor_info / restricted_info untuk seluruh kandidat. Kini sekali, sebagai satu himpunan.
-- * Analytics: p_tahun membatasi Tahun Campaign di server; layar bawaannya tahun berjalan.
-- * Cron email tiap menit memanggil Google Drive dan menyegarkan token walau antrean kosong (±1.440
--   kali sehari untuk ±26 email). Kini memeriksa antrean dulu; sapu Drive paling sering sejam sekali
--   dan hanya bila ada email terkirim, serta sekali sehari; token di luar 07-19 WIB hanya bila perlu.
-- * Jawaban pg_net tanpa status (mis. database sedang sesak) tidak lagi menggagalkan cron.
-- * cron.job_run_details dibersihkan (30 hari); indeks customers_name_idx yang tidak pernah dipakai dihapus.
-- Butuh 20261163860000. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- Pembantu per baris ------------------------------------------------------------------------
create or replace function rc_private.rekening_tampil(p_s_no text, p_s_nama text, p_s_bank text, p_m_no text, p_m_nama text, p_m_bank text)
returns jsonb language sql stable as $f$
  select case
    when coalesce(btrim(p_s_no), '') <> '' or coalesce(btrim(p_s_nama), '') <> '' or coalesce(btrim(p_s_bank), '') <> '' then
      jsonb_build_object('noRek', coalesce(btrim(p_s_no), ''), 'namaRek', coalesce(btrim(p_s_nama), ''), 'bank', coalesce(btrim(p_s_bank), ''),
                         'sumberRek', 'dokumen')
    when coalesce(btrim(p_m_no), '') <> '' or coalesce(btrim(p_m_nama), '') <> '' or coalesce(btrim(p_m_bank), '') <> '' then
      jsonb_build_object('noRek', coalesce(btrim(p_m_no), ''), 'namaRek', coalesce(btrim(p_m_nama), ''), 'bank', coalesce(btrim(p_m_bank), ''),
                         'sumberRek', 'master')
    else jsonb_build_object('noRek', '', 'namaRek', '', 'bank', '', 'sumberRek', '') end;
$f$;

create or replace function rc_private.claim_remark_amend(p_amend_dari text[])
returns text language sql stable as $f$
  select string_agg('Doc Amendment - ' || t, ', ' order by o)
    from (select t, min(o) o from unnest(p_amend_dari) with ordinality u(t, o) group by t) s;
$f$;

create or replace function rc_private.claim_remark_dari(p_reprocessed_at timestamptz, p_ada_reprocess boolean, p_cb_berubah boolean, p_amended_at timestamptz,
  p_amend_dari text[], p_rek_diubah boolean, p_special boolean, p_dc boolean)
returns text language sql stable as $f$
  select nullif(concat_ws(', ',
    case when coalesce(array_length(p_amend_dari, 1), 0) > 0 then rc_private.claim_remark_amend(p_amend_dari)
         when p_amended_at is not null then 'Doc Amendment' end,
    case when p_reprocessed_at is not null or p_ada_reprocess then 'Document Reprocessed' end,
    case when p_cb_berubah then 'CB Type Changed' end,
    case when coalesce(p_rek_diubah, false) then 'Bank Account Changed' end,
    case when coalesce(p_special, false) then 'Special Claims' end,
    case when coalesce(p_dc, false) then 'DC changed' end), '');
$f$;

create or replace function rc_private.claim_remark_dari(p_reprocessed_at timestamptz, p_ada_reprocess boolean, p_cb_berubah boolean, p_amended_at timestamptz,
  p_amend_dari text[], p_rek_diubah boolean, p_special boolean)
returns text language sql stable as $f$
  select rc_private.claim_remark_dari(p_reprocessed_at, p_ada_reprocess, p_cb_berubah, p_amended_at, p_amend_dari, p_rek_diubah, p_special, false);
$f$;

create or replace function rc_private.claim_remark_dari(p_reprocessed_at timestamptz, p_ada_reprocess boolean, p_cb_berubah boolean, p_amended_at timestamptz,
  p_amend_dari text[], p_rek_diubah boolean)
returns text language sql stable as $f$
  select rc_private.claim_remark_dari(p_reprocessed_at, p_ada_reprocess, p_cb_berubah, p_amended_at, p_amend_dari, p_rek_diubah, false, false);
$f$;

create or replace function rc_private.claim_remark(c public.claims)
returns text language sql stable as $f$
  select rc_private.claim_remark_dari(c.reprocessed_at,
    exists(select 1 from public.claim_status_history h where h.claim_id = c.id and h.action like '%reprocess%'),
    c.cashback_type_changed, c.amended_at,
    array(select rc_private.legacy_status(h.from_status) from public.claim_status_history h
           where h.claim_id = c.id and h.action = 'amend' order by h.id) /* 20261163150000 */,
    coalesce((select s.rekening_diubah from rc_private.claim_sensitive s where s.claim_id = c.id), false) /* 20261163400000 */,
    c.adhoc_lanjut = 'done' /* 20261163440000 */, c.dc_changed_at is not null /* 20261163810000 */);
$f$;

-- ---- Himpunan untuk Open dan Restricted (padanan boleh_open dan debtor_info) -------------------
create or replace function rc_private.klaim_open_ids()
returns uuid[] language sql stable security definer set search_path to '' as $f$
  select coalesce(array_agg(z.id), '{}'::uuid[]) from (
    select o.claim_id id from public.rc_clearing_offers o where o.status in ('offered', 'overdue')
    union
    select c.id from public.rc_bad_debt_remarks b join public.claims c on c.customer_id = b.customer_id
     where b.status = 'active' and c.status = 'not_yet' and c.archived_at is null and rc_private.approval_bad_debt_aktif()) z
   where rc_private.zdage_aktif();
$f$;

create or replace function rc_private.tawaran_aktif()
returns table(claim_id uuid, id uuid, status text, deadline_at timestamptz, reason jsonb, result text)
language sql stable security definer set search_path to '' as $f$
  select o.claim_id, o.id, o.status, o.deadline_at, o.reason, o.result from public.rc_clearing_offers o
   where o.status in ('offered', 'overdue') and rc_private.zdage_aktif();
$f$;

create or replace function rc_private.bad_debt_aktif()
returns table(customer_id uuid, reason text)
language sql stable security definer set search_path to '' as $f$
  select b.customer_id, b.reason from public.rc_bad_debt_remarks b where b.status = 'active' and rc_private.zdage_aktif();
$f$;

revoke all on function rc_private.klaim_open_ids(), rc_private.tawaran_aktif(), rc_private.bad_debt_aktif() from public, anon;
grant execute on function rc_private.klaim_open_ids(), rc_private.tawaran_aktif(), rc_private.bad_debt_aktif() to authenticated;

-- ---- Cron email --------------------------------------------------------------------------------
create table if not exists rc_private.email_sapu(id boolean primary key default true check (id), terakhir timestamptz not null default now());
insert into rc_private.email_sapu(id) values (true) on conflict do nothing;

create or replace function rc_private.email_sapu_perlu()
returns boolean language sql stable security definer set search_path to '' as $f$
  select coalesce((select e.terakhir < now() - interval '24 hours'
      or (e.terakhir < now() - interval '1 hour' and exists(select 1 from public.email_outbox o where o.dikirim_pada > e.terakhir))
    from rc_private.email_sapu e), true);
$f$;

create or replace procedure public.rc_email_proses(p_maks integer default 20)
language plpgsql as $f$
declare v_req bigint; v_token text; v_ada boolean; v_sapu boolean; v_jam integer;
begin
  v_ada := exists(select 1 from public.email_outbox where status = 'pending');
  v_sapu := rc_private.email_sapu_perlu();
  v_jam := extract(hour from now() at time zone 'Asia/Jakarta')::integer;
  -- Tidak ada pekerjaan. Pada 07-19 WIB token tetap dijaga supaya Kirim Sekarang langsung terkirim.
  if not v_ada and not v_sapu and v_jam not between 7 and 18 then return; end if;

  -- Tahap 1: minta token bila cache-nya sudah tidak berlaku.
  v_req := rc_private.gmail_token_minta();
  if v_req is not null then
    commit;                                   -- permintaan menjadi terlihat oleh worker pg_net
    perform pg_catalog.pg_sleep(3);           -- beri worker waktu menyelesaikan panggilannya
    v_token := rc_private.gmail_token_ambil(v_req);
    commit;
  end if;

  -- Tahap 2: jalankan antrean, termasuk membuat dan melampirkan PDF.
  if v_ada then
    perform public.rc_email_jalankan_antrean(coalesce(p_maks, 20));
    commit;
  end if;

  -- Tahap 3: sapu berkas sementara. Paling akhir dan di blok tersendiri, supaya kegagalannya
  -- tidak pernah menahan pengiriman.
  if v_sapu then
    begin
      perform rc_private.sapu_drive();
    exception when others then
      null;
    end;
    update rc_private.email_sapu set terakhir = now();
    commit;
  end if;
end $f$;

do $tambal$
declare src text; v_hak text[]; v_peran text;
begin
  -- ---- Token: jawaban tanpa status bukan penolakan Google ---------------------------------------
  src := replace(pg_get_functiondef('rc_private.gmail_token_ambil(bigint)'::regprocedure), E'\r', '');
  if src !~ '20261163870000' then
    src := pg_temp.ganti(src, $p$  if coalesce((v_res->>'status_code')::int,0) not between 200 and 299 then$p$,
      $p$  -- 20261163870000: pg_net tidak mendapat jawaban (bukan penolakan Google); dicoba lagi giliran berikutnya.
  if v_res->>'status_code' is null then return null; end if;

  if coalesce((v_res->>'status_code')::int,0) not between 200 and 299 then$p$, 1, 'token');
    execute src;
  end if;

  -- ---- Hak tab: zdage_tab_boleh hanya untuk tab yang terpengaruh -------------------------------
  -- can_tab hanya butuh satu tab, jadi hanya tab itu yang dihitung (±1,7 ms menjadi sepersekian).
  if to_regprocedure('rc_private.tab_rights(uuid)') is not null then
    src := replace(pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure), E'\r', '');
    if src !~ '20261163870000' then
      src := pg_temp.ganti(src, $p$rc_private.zdage_tab_boleh(t.code, p.role) /* 20261163680000 */ and$p$,
        $p$(t.code not in ('upload.restricted', 'upload.restrictedEdit', 'upload.baddebt', 'compilation.debtor', 'approval.baddebt') or rc_private.zdage_tab_boleh(t.code, p.role)) /* 20261163680000, 20261163870000 */ and$p$, 1, 'tab_rights');
    end if;
    src := pg_temp.ganti(src, $p$rc_private.tab_rights(p_user uuid)$p$, $p$rc_private.tab_rights(p_user uuid, p_kode text DEFAULT NULL::text)$p$, 1, 'tab_rights kepala');
    src := pg_temp.ganti(src, $p$where p.id=p_user and $p$, $p$where p.id=p_user and (p_kode is null or t.code=p_kode) and $p$, 1, 'tab_rights satu');
    v_hak := array(select r.rolname from pg_proc pr, aclexplode(coalesce(pr.proacl, acldefault('f', pr.proowner))) a join pg_roles r on r.oid = a.grantee
                    where pr.oid = 'rc_private.tab_rights(uuid)'::regprocedure and a.privilege_type = 'EXECUTE');
    drop function rc_private.tab_rights(uuid);
    execute src;
    revoke all on function rc_private.tab_rights(uuid, text) from public;
    foreach v_peran in array v_hak loop
      execute format('grant execute on function rc_private.tab_rights(uuid, text) to %I', v_peran);
    end loop;
    if array_length(v_hak, 1) is null then raise exception 'GAGAL: hak tab_rights tidak terbaca'; end if;
  end if;
  -- plpgsql menyimpan rencana kueri selama sesi; fungsi sql merencanakan ulang di setiap panggilan.
  src := replace(pg_get_functiondef('rc_private.tab_rights(uuid,text)'::regprocedure), E'\r', '');
  if src ~ 'LANGUAGE sql' then
    src := pg_temp.ganti(src, 'LANGUAGE sql', 'LANGUAGE plpgsql', 1, 'tab_rights bahasa');
    src := pg_temp.ganti(src, E'AS $function$\nselect coalesce(', E'AS $function$\nbegin return (select coalesce(', 1, 'tab_rights awal');
    src := pg_temp.ganti(src, E'; $function$', E'); end $function$', 1, 'tab_rights akhir');
    execute src;
  end if;
  src := replace(pg_get_functiondef('rc_private.can_tab(text)'::regprocedure), E'\r', '');
  if src !~ 'auth\.uid\(\), p_tab' then
    src := pg_temp.ganti(src, $p$rc_private.tab_rights(auth.uid())->>p_tab$p$, $p$rc_private.tab_rights(auth.uid(), p_tab)->>p_tab$p$, 1, 'can_tab');
    execute src;
  end if;

  -- ---- Workflow: hak tab sekali, volume dan net value ikut di baris ----------------------------
  src := replace(pg_get_functiondef('public.rc_legacy_workflow(integer,timestamp with time zone,uuid)'::regprocedure), E'\r', '');
  if src !~ 'v_t_rilis' then
    src := pg_temp.ganti(src, $p$ v_cp boolean; v_ah boolean; -- 20261163490000$p$,
      $p$ v_cp boolean; v_ah boolean; -- 20261163490000
 v_t_rilis boolean; v_t_cf boolean; v_t_clr boolean; v_t_bulk boolean; -- 20261163870000: sekali, bukan per baris$p$, 1, 'wf declare');
    src := pg_temp.ganti(src, $p$ v_ah := rc_private.can_tab('adhoc.list');$p$,
      $p$ v_ah := rc_private.can_tab('adhoc.list');
 v_t_rilis := rc_private.can_tab('release.list'); v_t_cf := rc_private.can_tab('process.claimFin');
 v_t_clr := rc_private.can_tab('process.clearing'); v_t_bulk := rc_private.can_tab('bulk.rebate');$p$, 1, 'wf hak');
    src := pg_temp.ganti(src, $p$where rc_private.can_tab('release.list') and v->>'status'$p$, $p$where v_t_rilis and v->>'status'$p$, 1, 'wf rilis');
    src := pg_temp.ganti(src, $p$where rc_private.can_tab('process.claimFin') and v->>'status'$p$, $p$where v_t_cf and v->>'status'$p$, 1, 'wf cf');
    src := pg_temp.ganti(src, $p$where rc_private.can_tab('process.clearing') and v->>'status'$p$, $p$where v_t_clr and v->>'status'$p$, 1, 'wf clr');
    src := pg_temp.ganti(src, $p$where rc_private.can_tab('bulk.rebate') and (v->>'rebate')$p$, $p$where v_t_bulk and (v->>'rebate')$p$, 1, 'wf bulk');
    src := pg_temp.ganti(src, $p$where rc_private.can_tab('adhoc.list') and v->>'status'$p$, $p$where v_ah and v->>'status'$p$, 1, 'wf adhoc');
    src := pg_temp.ganti(src, $p$|| jsonb_build_object('lingkup', v_semua or c.depot_id = any(v_depot),$p$,
      $p$|| jsonb_build_object('volume', c.volume, 'netValue', c.net_value /* 20261163870000: Workflow tidak perlu master dokumen */, 'lingkup', v_semua or c.depot_id = any(v_depot),$p$, 1, 'wf kolom');
    execute src;
  end if;

  -- ---- Analytics: Tahun Campaign di server -----------------------------------------------------
  if to_regprocedure('public.rc_legacy_dashboard(integer,timestamp with time zone,uuid)') is not null then
    src := replace(pg_get_functiondef('public.rc_legacy_dashboard(integer,timestamp with time zone,uuid)'::regprocedure), E'\r', '');
    src := pg_temp.ganti(src, $p$p_setelah_id uuid DEFAULT NULL::uuid)$p$, $p$p_setelah_id uuid DEFAULT NULL::uuid, p_tahun integer[] DEFAULT NULL::integer[])$p$, 1, 'dash kepala');
    src := pg_temp.ganti(src, $p$  select count(*) into v_total from public.claims c
   where c.archived_at is null and (v_semua or c.depot_id = any(v_depot));$p$,
      $p$  select count(*) into v_total from public.claims c join public.campaigns ca on ca.id = c.campaign_id
   where c.archived_at is null and (v_semua or c.depot_id = any(v_depot))
     and (p_tahun is null or coalesce(extract(year from coalesce(c.period_start, ca.period_start))::integer, 0) = any(p_tahun)); /* 20261163870000: 0 = tanpa periode */
  select coalesce(jsonb_agg(z.t order by z.t desc), '[]'::jsonb) into v_tahun
    from (select distinct extract(year from coalesce(c.period_start, ca.period_start))::integer t
            from public.claims c join public.campaigns ca on ca.id = c.campaign_id
           where c.archived_at is null and (v_semua or c.depot_id = any(v_depot))) z where z.t is not null;$p$, 1, 'dash jumlah');
    src := pg_temp.ganti(src, $p$ v_ids uuid[]; v_akhir_waktu timestamptz; v_akhir_id uuid;$p$, $p$ v_ids uuid[]; v_akhir_waktu timestamptz; v_akhir_id uuid; v_tahun jsonb;$p$, 1, 'dash declare');
    src := pg_temp.ganti(src, $p$          where c.archived_at is null and (v_semua or c.depot_id = any(v_depot))
            and (p_setelah_waktu is null$p$,
      $p$          where c.archived_at is null and (v_semua or c.depot_id = any(v_depot))
            and (p_tahun is null or coalesce(extract(year from coalesce(c.period_start, ca.period_start))::integer, 0) = any(p_tahun))
            and (p_setelah_waktu is null$p$, 1, 'dash halaman');
    src := pg_temp.ganti(src, $p$'perkiraanTotal',v_total,$p$, $p$'perkiraanTotal',v_total,'tahunTersedia',v_tahun,$p$, 1, 'dash hasil');
    drop function public.rc_legacy_dashboard(integer, timestamp with time zone, uuid);
    execute src;
    revoke all on function public.rc_legacy_dashboard(integer, timestamp with time zone, uuid, integer[]) from public, anon;
    grant execute on function public.rc_legacy_dashboard(integer, timestamp with time zone, uuid, integer[]) to authenticated, service_role;
  end if;

  -- ---- Open: himpunan sekali, bukan fungsi per klaim -------------------------------------------
  src := replace(pg_get_functiondef('public.rc_open_claims_filtered(text,text,integer,integer,text)'::regprocedure), E'\r', '');
  if src !~ 'v_open' then
    src := pg_temp.ganti(src, $p$declare v jsonb; jml bigint; v_opsi jsonb;$p$,
      $p$declare v jsonb; jml bigint; v_opsi jsonb;
 v_zd boolean := rc_private.zdage_aktif(); v_open uuid[] := rc_private.klaim_open_ids(); -- 20261163870000: padanan boleh_open, dihitung sekali$p$, 1, 'open declare');
    src := pg_temp.ganti(src, $p$rc_private.boleh_open(c.id,c.customer_id)$p$, $p$(not v_zd or c.id in (select unnest(v_open)))$p$, 4, 'open boleh');
    src := pg_temp.ganti(src, $p$  left join lateral rc_private.debtor_info(c.id,c.customer_id) di on true$p$,
      $p$  left join rc_private.tawaran_aktif() o on o.claim_id = c.id
  left join rc_private.bad_debt_aktif() b on b.customer_id = c.customer_id
  cross join lateral (select o.id offer_id, o.status offer_status, o.deadline_at,
      case when o.deadline_at is null then null else (o.deadline_at at time zone 'Asia/Jakarta')::date - (now() at time zone 'Asia/Jakarta')::date end sisa_hari,
      o.reason, b.customer_id is not null bad_debt, b.reason bad_debt_reason, o.result offer_result) di /* 20261163870000: padanan debtor_info */$p$, 1, 'open debtor');
    execute src;
  end if;

  -- ---- Restricted: himpunan sekali; alasan hanya untuk baris halaman ---------------------------
  src := replace(pg_get_functiondef('public.rc_restricted_claims(text,text,integer,integer,text)'::regprocedure), E'\r', '');
  if src !~ 'v_open' then
    src := pg_temp.ganti(src, $p$declare v jsonb; jml bigint; v_opsi jsonb; v_cari text := btrim(coalesce(p_search, ''));$p$,
      $p$declare v jsonb; jml bigint; v_opsi jsonb; v_cari text := btrim(coalesce(p_search, ''));
  v_zd boolean := rc_private.zdage_aktif(); v_open uuid[] := rc_private.klaim_open_ids(); -- 20261163870000: padanan boleh_open, dihitung sekali$p$, 1, 'res declare');
    src := pg_temp.ganti(src, $p$not rc_private.boleh_open(c.id, c.customer_id)$p$, $p$(v_zd and c.id not in (select unnest(v_open)))$p$, 4, 'res boleh');
    src := pg_temp.ganti(src, $p$      from public.claims c
      join public.campaigns ca on ca.id = c.campaign_id
      left join public.customers cu on cu.id = c.customer_id
      join public.depots d on d.id = c.depot_id
      left join lateral rc_private.restricted_info(c.id, c.customer_id, c.depot_id) ri on true
     where c.status = 'not_yet'$p$,
      $p$      from (select c.id from public.claims c
      join public.campaigns ca on ca.id = c.campaign_id
      left join public.customers cu on cu.id = c.customer_id
     where c.status = 'not_yet'$p$, 1, 'res dari');
    src := pg_temp.ganti(src, $p$     order by ca.campaign_code, c.no_doc
     limit least(greatest(coalesce(p_limit, 200), 1), 500) offset greatest(coalesce(p_offset, 0), 0)) t;$p$,
      $p$     order by ca.campaign_code, c.no_doc
     limit least(greatest(coalesce(p_limit, 200), 1), 500) offset greatest(coalesce(p_offset, 0), 0)) hal
      join public.claims c on c.id = hal.id
      join public.campaigns ca on ca.id = c.campaign_id
      left join public.customers cu on cu.id = c.customer_id
      join public.depots d on d.id = c.depot_id
      left join lateral rc_private.restricted_info(c.id, c.customer_id, c.depot_id) ri on true
     order by ca.campaign_code, c.no_doc) t;$p$, 1, 'res halaman');
    execute src;
  end if;

  -- ---- Lookup dokumen: saklar sekali, syaratnya menyatu dengan kueri ----------------------------
  src := replace(pg_get_functiondef('rc_private.legacy_documents(text[])'::regprocedure), E'\r', '');
  if src !~ 'v_zd' then
    src := pg_temp.ganti(src, E'AS $function$\nbegin\n', E'AS $function$\ndeclare v_zd boolean := rc_private.zdage_aktif(); v_bd boolean := rc_private.approval_bad_debt_aktif(); -- 20261163870000\nbegin\n', 1, 'dok declare');
    src := pg_temp.ganti(src, $p$rc_private.boleh_open(c.id, c.customer_id)$p$,
      $p$(not v_zd or exists(select 1 from public.rc_clearing_offers o where o.claim_id = c.id and o.status in ('offered', 'overdue'))
           or (v_bd and exists(select 1 from public.rc_bad_debt_remarks b where b.customer_id = c.customer_id and b.status = 'active')))$p$, 2, 'dok boleh');
    execute src;
  end if;
end $tambal$;

-- ---- Pembersihan --------------------------------------------------------------------------------
drop index if exists public.customers_name_idx;
select cron.schedule('rc_cron_bersih', '30 20 * * *', $c$delete from cron.job_run_details where end_time < now() - interval '30 days'$c$);

notify pgrst, 'reload schema';

do $cek$ begin
  if pg_get_functiondef('public.rc_legacy_workflow(integer,timestamp with time zone,uuid)'::regprocedure) ~ 'where rc_private.can_tab' then raise exception 'GAGAL: can_tab per baris'; end if;
  if pg_get_functiondef('public.rc_open_claims_filtered(text,text,integer,integer,text)'::regprocedure) ~ 'rc_private\.boleh_open' then raise exception 'GAGAL: open'; end if;
  if pg_get_functiondef('public.rc_restricted_claims(text,text,integer,integer,text)'::regprocedure) ~ 'rc_private\.boleh_open' then raise exception 'GAGAL: restricted'; end if;
  if pg_get_functiondef('rc_private.legacy_documents(text[])'::regprocedure) ~ 'rc_private\.boleh_open' then raise exception 'GAGAL: dokumen'; end if;
  if to_regprocedure('public.rc_legacy_dashboard(integer,timestamp with time zone,uuid,integer[])') is null then raise exception 'GAGAL: dashboard'; end if;
end $cek$;
