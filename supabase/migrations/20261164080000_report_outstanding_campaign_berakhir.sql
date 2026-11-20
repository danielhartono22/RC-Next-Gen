-- ==========================================================================================
-- Report: Outstanding = Outstanding Claim; bawaan hanya campaign yang Billing End-nya sudah lewat
-- ==========================================================================================
-- Pemilik, 20 November 2026:
--   "samakan aja ketika depot klaim maka tidak jadi outstanding lagi saat submit atau approval saat
--    hidup, kedua oustanding % hapus aja."
--   "saya mau yang ditampilkan di report semua yang campaign sudah berakhir dari billing end nya by
--    default, kecuali kalo minta ditampilkan semua harus tick 1 kolom di header 'Show All Campaign'."
--
-- 1. rc_report_rows.outstanding memakai rumus outstanding_claim: Not Yet, atau Submitted bila
--    approval hidup. Klaim yang sudah diajukan depot (di OSC / Finance) tidak lagi outstanding.
--    Berlaku untuk semua pembaca view lewat snapshot: Report, dashboard publik, Excel, Aging,
--    email Daily / Weekly beserta PDF dan grafiknya. Kolom Outstanding % dihapus di layar.
-- 2. report_dashboard, cost_center, cost_center_2: penyaring baru 'semuaCampaign'. Kosong (bawaan)
--    = hanya baris yang batas campaign-nya (Billing End dokumen, lalu SO End, lalu Period End)
--    sudah LEWAT dari hari ini (WIB); baris tanpa tanggal tetap tampil. 'true' = semua. Memilih
--    satu campaign tertentu menampilkan campaign itu walau belum berakhir. Dashboard publik ikut
--    (fungsi yang sama; cache tanpa penyaring = bawaan).
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $g$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $g$;

-- ---- 1. View ------------------------------------------------------------------------------------
do $view$
declare v_def text := pg_get_viewdef('public.rc_report_rows'::regclass, true);
  v_lama text := $p$    c.status = ANY (ARRAY['not_yet'::text, 'submitted'::text, 'approved'::text, 'released'::text, 'claimed'::text]) AS outstanding,$p$;
  v_baru text := $p$    c.status = 'not_yet'::text OR c.status = 'submitted'::text AND ( SELECT rc_private.approval_aktif() AS approval_aktif) AS outstanding,$p$;
begin
  if position(v_baru in v_def) > 0 then raise notice 'rc_report_rows sudah ditambal.'; return; end if;
  execute 'create or replace view public.rc_report_rows as ' || regexp_replace(pg_temp.ganti(v_def, v_lama, v_baru, 1, 'view outstanding'), ';\s*$', '');
end $view$;

comment on view public.rc_report_rows is
  'Baris Report. 20261163630000: Not Yet dari campaign yang Billing End-nya belum lewat tidak termasuk. 20261164080000: outstanding = outstanding_claim (Not Yet, atau Submitted bila approval hidup).';

-- ---- 2. Penyaring bawaan: campaign yang sudah berakhir ------------------------------------------
do $tambal$
declare src text; f text;
begin
  foreach f in array array['rc_private.report_dashboard(jsonb)', 'rc_private.cost_center(jsonb)', 'rc_private.cost_center_2(jsonb)'] loop
    src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
    continue when src ~ '20261164080000';
    src := pg_temp.ganti(src, $p$  v_bill_b := rc_private.urai_tanggal_rc(nullif(btrim(coalesce(p_filter->>'billingEnd','')),''));$p$,
      $p$  v_bill_b := rc_private.urai_tanggal_rc(nullif(btrim(coalesce(p_filter->>'billingEnd','')),''));
  -- 20261164080000: bawaan hanya campaign yang sudah berakhir; 'semuaCampaign' atau campaign terpilih = semua.
  v_semua_camp := lower(btrim(coalesce(p_filter->>'semuaCampaign', ''))) in ('true', '1', 'ya') or v_campaign is not null;$p$, 1, f || ' semua');
    src := pg_temp.ganti(src, $p$       and (v_bill_b is null or (billing_start is not null and billing_start <= v_bill_b))$p$,
      $p$       and (v_bill_b is null or (billing_start is not null and billing_start <= v_bill_b))
       and (v_semua_camp or coalesce(billing_end, so_end, period_end) is null
            or coalesce(billing_end, so_end, period_end) < (now() at time zone 'Asia/Jakarta')::date) /* 20261164080000 */$p$, 1, f || ' saring');
    src := regexp_replace(src, '\ndeclare\n', E'\ndeclare\n  v_semua_camp boolean; -- 20261164080000\n');
    if src !~ 'v_semua_camp boolean' then raise exception '% : deklarasi tidak terpasang', f; end if;
    execute src;
  end loop;
end $tambal$;

-- ---- 3. Outstanding (dok) per region, seperti per depot / campaign ------------------------------
-- Pemilik, 20-Nov-2026: "di performa per region dan depot tambahkan juga seperti campaign
-- outstanding (qty) nya selain outstanding amt nya."
do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.report_dashboard(jsonb)'::regprocedure), E'', '');
  if src !~ 'os_qty \/\* 20261164080000' then
    src := pg_temp.ganti(src, $p$        'outstandingValue',z.os_val,'clearingRate',z.cr,$p$,
      $p$        'outstandingQty',z.os_qty,'outstandingValue',z.os_val,'clearingRate',z.cr,$p$, 1, 'region qty json');
    src := pg_temp.ganti(src, $p$                   coalesce(sum(cb_net) filter (where outstanding),0) os_val,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where status in('done','expired')),0)/sum(cb_net) end cr
              from r group by region) z),$p$,
      $p$                   count(*) filter (where outstanding) os_qty /* 20261164080000 */,
                   coalesce(sum(cb_net) filter (where outstanding),0) os_val,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where status in('done','expired')),0)/sum(cb_net) end cr
              from r group by region) z),$p$, 1, 'region qty kolom');
    execute src;
  end if;
end $tambal$;

-- Snapshot dan cache dashboard publik langsung mengikuti.
select rc_private.segarkan_report('migrasi 20261164080000');

do $cek$ begin
  if exists (select 1 from public.rc_report_rows where outstanding is distinct from outstanding_claim) then
    raise exception 'GAGAL: outstanding belum sama dengan outstanding_claim'; end if;
  if (select count(*) from rc_private.report_rows_snap) <> (select count(*) from public.rc_report_rows) then
    raise exception 'GAGAL: snapshot belum mengikuti view'; end if;
  if pg_get_functiondef('rc_private.report_dashboard(jsonb)'::regprocedure) !~ 'v_semua_camp'
     or pg_get_functiondef('rc_private.cost_center(jsonb)'::regprocedure) !~ 'v_semua_camp'
     or pg_get_functiondef('rc_private.cost_center_2(jsonb)'::regprocedure) !~ 'v_semua_camp' then raise exception 'GAGAL: penyaring'; end if;
  if pg_get_functiondef('rc_private.report_dashboard(jsonb)'::regprocedure) !~ '''outstandingQty'',z.os_qty' then raise exception 'GAGAL: qty region'; end if;
end $cek$;
