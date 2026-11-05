-- ==========================================================================================
-- Key Master, Claim Process, dan Ad-Hoc Process tanpa yurisdiksi depot
-- ==========================================================================================
-- Pemilik, 27 Oktober 2026:
--   "Untuk Key master tidak perlu yuridiksi, semua yang diizinkan modul bisa akses, hapus
--    yuridiksi untuk modul ini."
--   "Untuk Akses Claim process juga tidak perlu yuridiksi, semua yang diizinkan bisa akses"
--   "Ad-hoc process juga tidak perlu yuridiksi"
--
-- Siapa pun yang diberi tab modul itu kini melihat dan memproses SELURUH depot; penjaga tab /
-- izin modul tetap. Modul lain (Release, Bulk Process, Claim Upload, Analytics, Document Center,
-- Report, Timetable) tidak berubah dan tetap per yurisdiksi.
--
--   KEY MASTER   rc_customer_list dan rc_depot_list menjadi SECURITY DEFINER (RLS tabel customers
--                / depots membatasi per depot); rc_customer_list, rc_depot_save, rc_campaign_np,
--                rc_campaign_np_simpan, dan rc_private.customer_upsert tidak lagi memeriksa
--                can_access / can_view / region_terjangkau per depot.
--   CLAIM PROCESS & AD-HOC
--                rc_legacy_workflow menjadi SECURITY DEFINER (RLS claims membatasi per depot)
--                dengan penyaring eksplisit: dokumen Released/Claimed seluruh depot bagi pemegang
--                tab Claim to Finance / Clearing, dan dokumen Others yang Approved seluruh depot
--                bagi pemegang tab Ad-Hoc. Release dan Bulk Process tetap hanya depot dalam
--                yurisdiksi (bendera "lingkup"). Aksi claim / clearing / reject_claim /
--                reject_clearing / expire_claim_process serta rc_adhoc_proses / rc_adhoc_tolak
--                tidak lagi memeriksa depot.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $tambal$
declare src text; f text;
begin
  -- ---- Key Master -------------------------------------------------------------------------
  f := 'public.rc_customer_list(text,integer,integer)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163490000' then
    src := pg_temp.ganti(src, ' and rc_private.can_access(d.id)', '', 3, f);
    src := pg_temp.ganti(src, $p$ perform rc_private.require_tab('keyMaster.customer');$p$,
      $p$ perform rc_private.require_tab('keyMaster.customer'); -- 20261163490000: seluruh depot bagi pemegang tab$p$, 1, f || ' penanda');
    execute src;
  end if;

  f := 'public.rc_depot_list(text,integer,integer)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163490000' then
    src := pg_temp.ganti(src, $p$ perform rc_private.require_tab('keyMaster.depot');$p$,
      $p$ perform rc_private.require_tab('keyMaster.depot'); -- 20261163490000: seluruh depot bagi pemegang tab$p$, 1, f);
    execute src;
  end if;

  f := 'public.rc_depot_save(text,jsonb)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163490000' then
    src := pg_temp.ganti(src, $p$  if not rc_private.can_access(v_depot) then
    raise exception 'Depot ini di luar yurisdiksi Anda' using errcode='42501'; end if;
$p$, $p$  -- 20261163490000: Key Master tanpa yurisdiksi depot.
$p$, 1, f);
    execute src;
  end if;

  f := 'public.rc_campaign_np(text)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163490000' then
    src := pg_temp.ganti(src, $p$'bolehUbah', rc_private.region_terjangkau(r.region)$p$, $p$'bolehUbah', true /* 20261163490000 */$p$, 1, f || ' region');
    src := pg_temp.ganti(src, ' and rc_private.can_view(d.id)', '', 2, f || ' depot terlihat');
    src := pg_temp.ganti(src, $p$'bolehUbah', rc_private.can_access(d.id)$p$, $p$'bolehUbah', true$p$, 1, f || ' depot ubah');
    src := pg_temp.ganti(src, 'and ((n.depot_id is not null and not rc_private.can_view(n.depot_id))', 'and ((false)', 1, f || ' tanda lain depot');
    src := pg_temp.ganti(src, ' and rc_private.can_view(x.id))))', ')))', 1, f || ' tanda lain region');
    execute src;
  end if;

  f := 'public.rc_campaign_np_simpan(text,jsonb,jsonb,text)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163490000' then
    src := pg_temp.ganti(src, $p$    if not rc_private.can_access(v_id) then raise exception 'Depot % di luar jangkauan Anda', v_kode using errcode = '42501'; end if;
$p$, $p$    -- 20261163490000: Key Master tanpa yurisdiksi depot.
$p$, 1, f || ' depot');
    src := pg_temp.ganti(src, $p$    if not rc_private.region_terjangkau(v_kode) then
      raise exception 'Region % memuat depot di luar jangkauan Anda', v_kode using errcode = '42501'; end if;
$p$, '', 1, f || ' region');
    src := pg_temp.ganti(src, ' and rc_private.can_access(n.depot_id)', '', 1, f || ' hapus depot');
    src := pg_temp.ganti(src, ' and rc_private.region_terjangkau(n.region)', '', 1, f || ' hapus region');
    execute src;
  end if;

  f := 'rc_private.customer_upsert(jsonb)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163490000' then
    src := pg_temp.ganti(src, $p$    if not rc_private.can_access(v_dep.id) then
     raise exception 'Customer %: depot % di luar akses Anda', code, v_kode; end if;
$p$, $p$    -- 20261163490000: Key Master tanpa yurisdiksi depot.
$p$, 1, f || ' depot');
    src := pg_temp.ganti(src, ' and rc_private.can_access(cd.depot_id);', ';', 1, f || ' kaitan');
    execute src;
  end if;

  -- ---- Claim Process & Ad-Hoc -------------------------------------------------------------
  f := 'public.rc_legacy_workflow(integer,timestamp with time zone,uuid)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163490000' then
    src := pg_temp.ganti(src, 'declare rows_json jsonb; nama jsonb;', 'declare rows_json jsonb; nama jsonb;
 v_cp boolean; v_ah boolean; -- 20261163490000', 1, f || ' deklarasi');
    src := pg_temp.ganti(src, 'select l.semua, l.depot into v_semua, v_depot from rc_private.lingkup_depot_saya() l;',
      'select l.semua, l.depot into v_semua, v_depot from rc_private.lingkup_depot_saya() l;
 -- 20261163490000: Claim to Finance / Clearing dan Ad-Hoc tanpa yurisdiksi bagi pemegang tabnya.
 v_cp := rc_private.can_tab(''process.claimFin'') or rc_private.can_tab(''process.clearing'');
 v_ah := rc_private.can_tab(''adhoc.list'');', 1, f || ' bendera');
    src := pg_temp.ganti(src, $p$select count(*) into v_total from public.claims c where c.archived_at is null and c.depot_id = any(v_depot) and c.status in('approved','released','claimed') and c.pending_approval is null;$p$,
      $p$select count(*) into v_total from public.claims c where c.archived_at is null and c.status in('approved','released','claimed') and c.pending_approval is null
     and (c.depot_id = any(v_depot) or (v_cp and c.status in ('released','claimed')) or (v_ah and c.status = 'approved' and c.jalur_adhoc));$p$, 1, f || ' total');
    src := pg_temp.ganti(src, 'where c.archived_at is null and (v_semua or c.depot_id = any(v_depot))',
      'where c.archived_at is null and (v_semua or c.depot_id = any(v_depot)
                 or (v_cp and c.status in (''released'',''claimed'')) or (v_ah and c.status = ''approved'' and c.jalur_adhoc))', 1, f || ' halaman');
    src := pg_temp.ganti(src, $p$|| jsonb_build_object('adhoc',c.jalur_adhoc,$p$,
      $p$|| jsonb_build_object('lingkup', v_semua or c.depot_id = any(v_depot), 'adhoc',c.jalur_adhoc,$p$, 1, f || ' lingkup');
    src := pg_temp.ganti(src, $p$where rc_private.can_tab('release.list') and v->>'status'='Approved' and not (v->>'rebate')::boolean and not (v->>'adhoc')::boolean),$p$,
      $p$where rc_private.can_tab('release.list') and v->>'status'='Approved' and not (v->>'rebate')::boolean and not (v->>'adhoc')::boolean and (v->>'lingkup')::boolean),$p$, 1, f || ' release');
    src := pg_temp.ganti(src, $p$where rc_private.can_tab('bulk.rebate') and (v->>'rebate')::boolean and v->>'status' <> 'Submitted'),$p$,
      $p$where rc_private.can_tab('bulk.rebate') and (v->>'rebate')::boolean and v->>'status' <> 'Submitted' and (v->>'lingkup')::boolean),$p$, 1, f || ' bulk');
    execute src;
  end if;

  f := 'rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163490000' then
    src := pg_temp.ganti(src, $p$ if not rc_private.can_access(c.depot_id,perm) then raise exception 'Depot access denied' using errcode='42501'; end if;$p$,
      $p$ if not (p_action in('claim','clearing','reject_claim','reject_clearing','expire_claim_process') /* 20261163490000: Claim Process tanpa yurisdiksi */
            or rc_private.can_access(c.depot_id,perm)) then raise exception 'Depot access denied' using errcode='42501'; end if;$p$, 1, f);
    execute src;
  end if;

  foreach f in array array['public.rc_adhoc_proses(jsonb,uuid)', 'public.rc_adhoc_tolak(jsonb,uuid,text)'] loop
    src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
    if src !~ '20261163490000' then
      src := pg_temp.ganti(src, $p$    if not rc_private.can_access(c.depot_id) then raise exception 'Depot access denied' using errcode = '42501'; end if;
$p$, $p$    -- 20261163490000: Ad-Hoc Process tanpa yurisdiksi depot (tab adhoc.list sudah diperiksa).
$p$, 1, f);
      execute src;
    end if;
  end loop;
end $tambal$;

-- Fungsi daftar yang dibaca sebagai pengguna dibatasi RLS per depot; jalankan sebagai pemilik.
-- Penjaga tab / izin di dalamnya tetap memakai akun pemanggil (auth.uid()).
alter function public.rc_customer_list(text, integer, integer) security definer;
alter function public.rc_depot_list(text, integer, integer) security definer;
alter function public.rc_legacy_workflow(integer, timestamp with time zone, uuid) security definer;
revoke execute on function public.rc_customer_list(text, integer, integer), public.rc_depot_list(text, integer, integer),
  public.rc_legacy_workflow(integer, timestamp with time zone, uuid) from anon;
