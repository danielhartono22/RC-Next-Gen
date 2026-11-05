-- ==========================================================================================
-- ZDAGE Integration mati = tampilan dan perilaku seperti prod (sebelum ZDAGE)
-- ==========================================================================================
-- Pemilik, 4 November 2026: "kalo di aktifkan on off nya zdage integration maka seperti sekarang
-- di prod tampilannya. normal."
--
-- Saat saklar ZDAGE Integration (20261163620000) MATI, semua yang datang bersama ZDAGE
-- (20261163170000, 20261163270000) disembunyikan dan tidak berlaku:
--   * Tab: Restricted, Restricted (edit), Bad Debt (Claim Upload), Upload Debtor (Document
--     Center) dan Bad Debt (Management of Approval) tertutup lewat rc_private.tab_rights - layar
--     dan server (require_tab) sama-sama mengikutinya.
--       - Upload Debtor tetap terbuka bagi System Manager, untuk menyiapkan data sebelum saklar
--         dihidupkan.
--       - Tab Bad Debt di Management of Approval tetap terbuka selama masih ada pengajuan Bad Debt
--         yang menunggu, supaya tidak ada yang tertahan tanpa bisa diputuskan.
--   * Data: tawaran (Deadline, label Restricted, Kembalikan) dan tanda Bad Debt tidak dibaca lagi -
--     daftar Open, label Bad Debt di Customer Master, jalur approval Bad Debt saat submit dan remark
--     Bad Debt di email pengajuan semuanya seperti tanpa ZDAGE. Datanya tetap tersimpan dan berlaku
--     lagi begitu saklar dihidupkan.
--   * Bootstrap login mengirim zdageAktif; layar menyembunyikan kolom Tagihan, Final Billing Month
--     dan Deadline.
-- Saat HIDUP tidak ada yang berubah. Aman dijalankan berulang.
-- ==========================================================================================

do $pra$ begin
  if to_regprocedure('rc_private.zdage_aktif()') is null then
    raise exception 'DITOLAK: jalankan 20261163620000 (saklar ZDAGE) lebih dulu.'; end if;
end $pra$;

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- Pengajuan Bad Debt yang menunggu (penentu tab Bad Debt saat saklar mati) - indeks parsial kecil.
create index if not exists claims_menunggu_bad_debt_idx on public.claims (id)
  where archived_at is null and pending_approval->>'bad_debt' = 'true';

create or replace function rc_private.zdage_tab_boleh(p_code text, p_role text) returns boolean
language sql stable security definer set search_path to '' as $f$
  select case
    when p_code not in ('upload.restricted', 'upload.restrictedEdit', 'upload.baddebt', 'compilation.debtor', 'approval.baddebt') then true
    when rc_private.zdage_aktif() then true
    when p_code = 'compilation.debtor' and p_role = 'system manager' then true
    when p_code = 'approval.baddebt' then exists (select 1 from public.claims c
                                                   where c.archived_at is null and c.pending_approval->>'bad_debt' = 'true')
    else false end;
$f$;
revoke all on function rc_private.zdage_tab_boleh(text, text) from public, anon;
grant execute on function rc_private.zdage_tab_boleh(text, text) to authenticated;

do $tambal$
declare src text;
begin
  -- Hak tab.
  src := replace(pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163680000' then
    src := pg_temp.ganti(src, $p$select coalesce(jsonb_object_agg(t.code,not (t.code='links.editor'$p$,
      $p$select coalesce(jsonb_object_agg(t.code,rc_private.zdage_tab_boleh(t.code, p.role) /* 20261163680000 */ and not (t.code='links.editor'$p$,
      1, 'tab_rights');
    execute src;
  end if;

  -- Tawaran dan Bad Debt di daftar Open / Kembalikan.
  src := replace(pg_get_functiondef('rc_private.debtor_info(uuid,uuid)'::regprocedure), E'\r', '');
  if src !~ 'zdage_aktif' then
    src := pg_temp.ganti(src, $p$left join public.rc_clearing_offers o on o.claim_id = p_claim and o.status in ('offered','overdue')$p$,
      $p$left join public.rc_clearing_offers o on o.claim_id = p_claim and o.status in ('offered','overdue') and rc_private.zdage_aktif() /* 20261163680000 */$p$, 1, 'debtor_info tawaran');
    src := pg_temp.ganti(src, $p$left join public.rc_bad_debt_remarks b on b.customer_id = p_customer and b.status = 'active';$p$,
      $p$left join public.rc_bad_debt_remarks b on b.customer_id = p_customer and b.status = 'active' and rc_private.zdage_aktif();$p$, 1, 'debtor_info bad debt');
    execute src;
  end if;

  -- Label Bad Debt (Customer Master, email pengajuan).
  src := replace(pg_get_functiondef('rc_private.toko_bad_debt(uuid)'::regprocedure), E'\r', '');
  if src !~ 'zdage_aktif' then
    src := pg_temp.ganti(src, $p$where customer_id = p_customer and status = 'active'$p$,
      $p$where customer_id = p_customer and status = 'active' and rc_private.zdage_aktif() /* 20261163680000 */$p$, 1, 'toko_bad_debt');
    execute src;
  end if;

  -- Jalur approval Bad Debt saat submit.
  src := replace(pg_get_functiondef('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)'::regprocedure), E'\r', '');
  if src !~ '20261163680000' then
    src := pg_temp.ganti(src, $p$select r.id into v_bd from public.rc_bad_debt_remarks r where r.customer_id=c.customer_id and r.status='active';$p$,
      $p$select r.id into v_bd from public.rc_bad_debt_remarks r where r.customer_id=c.customer_id and r.status='active' and rc_private.zdage_aktif() /* 20261163680000 */;$p$,
      1, 'mutate bad debt');
    execute src;
  end if;

  -- Daftar Open memberi tahu layar keadaan saklar (kolom Deadline / Tagihan).
  src := replace(pg_get_functiondef('public.rc_open_claims_filtered(text,text,integer,integer,text)'::regprocedure), E'\r', '');
  if src !~ '20261163680000' then
    src := pg_temp.ganti(src, $p$return jsonb_build_object('status','success','rows',v,'total',jml)$p$,
      $p$return jsonb_build_object('status','success','rows',v,'total',jml,'zdageAktif',rc_private.zdage_aktif() /* 20261163680000 */)$p$, 1, 'open');
    execute src;
  end if;

  -- Bootstrap login.
  src := replace(pg_get_functiondef('public.rc_legacy_bootstrap()'::regprocedure), E'\r', '');
  if src !~ '20261163680000' then
    src := pg_temp.ganti(src, $p$'tabs',rc_private.tab_rights(me.id),'auth',flags,$p$,
      $p$'tabs',rc_private.tab_rights(me.id),'zdageAktif',rc_private.zdage_aktif() /* 20261163680000 */,'auth',flags,$p$, 1, 'bootstrap');
    execute src;
  end if;
end $tambal$;

do $cek$ begin
  if pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure) !~ 'zdage_tab_boleh' then raise exception 'GAGAL: tab_rights'; end if;
  if pg_get_functiondef('public.rc_legacy_bootstrap()'::regprocedure) !~ 'zdageAktif' then raise exception 'GAGAL: bootstrap'; end if;
  raise notice 'ZDAGE mati = tampilan prod terpasang (saklar sekarang %).', case when rc_private.zdage_aktif() then 'HIDUP' else 'MATI' end;
end $cek$;
