-- ==========================================================================================
-- Uji 20 November 2026: Outstanding = Outstanding Claim; Report bawaan hanya campaign berakhir
-- (20261164080000). Hanya membaca; tidak ada yang diubah.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_report_campaign_berakhir.sql
-- ==========================================================================================
create temp table if not exists _hasil_rcb(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_rcb;

do $uji$
declare hasil jsonb := '[]'; v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_n_akhir integer; v_n_semua integer; r jsonb; r2 jsonb;
  v_camp text; v_n_camp integer; v_ok boolean;
begin
  -- 1. Outstanding = Outstanding Claim.
  hasil := hasil || jsonb_build_object('uji', 'rc_report_rows: outstanding sama dengan outstanding_claim (Not Yet, atau Submitted bila approval hidup)', 'lulus',
    not exists(select 1 from public.rc_report_rows where outstanding is distinct from outstanding_claim)
    and not exists(select 1 from public.rc_report_rows where outstanding and status in ('approved', 'released', 'claimed', 'done', 'expired')),
    'rinci', (select count(*) filter (where outstanding) || ' outstanding dari ' || count(*) from public.rc_report_rows));

  -- 2. Bawaan: hanya baris yang campaign-nya sudah berakhir; semuaCampaign = semua.
  select count(*) filter (where coalesce(billing_end, so_end, period_end) is null or coalesce(billing_end, so_end, period_end) < v_hari), count(*)
    into v_n_akhir, v_n_semua from rc_private.report_rows_snap;
  r := rc_private.report_dashboard('{}'::jsonb);
  r2 := rc_private.report_dashboard('{"semuaCampaign":"true"}'::jsonb);
  hasil := hasil || jsonb_build_object('uji', 'Report bawaan = baris campaign yang Billing End-nya sudah lewat; Show All Campaign = semua baris', 'lulus',
    (r->'kpi'->>'claimQty')::int = v_n_akhir and (r2->'kpi'->>'claimQty')::int = v_n_semua
    and (r->'kpi'->>'outstandingQty')::int = (select count(*) from rc_private.report_rows_snap where outstanding and (coalesce(billing_end, so_end, period_end) is null or coalesce(billing_end, so_end, period_end) < v_hari)),
    'rinci', 'bawaan ' || (r->'kpi'->>'claimQty') || ' / semua ' || (r2->'kpi'->>'claimQty'));

  -- 3. Campaign yang belum berakhir: tidak ada di bawaan, tampil bila dipilih.
  select campaign_code, count(*) into v_camp, v_n_camp from rc_private.report_rows_snap
   where coalesce(billing_end, so_end, period_end) >= v_hari group by 1 order by 2 desc limit 1;
  if v_camp is null then
    hasil := hasil || jsonb_build_object('uji', 'Campaign berjalan: (tidak ada data campaign berjalan di lingkungan ini)', 'lulus', true, 'rinci', '-');
  else
    r := rc_private.report_dashboard('{}'::jsonb);
    r2 := rc_private.report_dashboard(jsonb_build_object('campaign', v_camp));
    v_ok := not exists(select 1 from jsonb_array_elements(r->'campaign') x where x->>'kodeCampaign' = v_camp)
        and (r2->'kpi'->>'claimQty')::int = (select count(*) from rc_private.report_rows_snap where campaign_code = v_camp);
    hasil := hasil || jsonb_build_object('uji', 'Campaign berjalan tidak tampil di bawaan, tetapi tampil bila dipilih di penyaring Campaign', 'lulus', v_ok,
      'rinci', v_camp || ' ' || v_n_camp || ' baris');
  end if;

  -- 4. Cost Center 1 dan 2 mengikuti.
  r := rc_private.cost_center('{}'::jsonb); r2 := rc_private.cost_center('{"semuaCampaign":"true"}'::jsonb);
  v_ok := (select coalesce(sum((x->>'qty')::int), 0) from jsonb_array_elements(r->'rows') x) = v_n_akhir
      and (select coalesce(sum((x->>'qty')::int), 0) from jsonb_array_elements(r2->'rows') x) = v_n_semua;
  r := rc_private.cost_center_2('{}'::jsonb); r2 := rc_private.cost_center_2('{"semuaCampaign":"true"}'::jsonb);
  v_ok := v_ok and (select coalesce(sum((x->>'qty')::int), 0) from jsonb_array_elements(r->'rows') x)
                <= (select coalesce(sum((x->>'qty')::int), 0) from jsonb_array_elements(r2->'rows') x);
  hasil := hasil || jsonb_build_object('uji', 'Cost Center 1 dan 2 memakai aturan bawaan yang sama', 'lulus', v_ok, 'rinci', '-');

  -- 5. Dashboard publik: tanpa penyaring = bawaan (cache), sama dengan Report.
  r := public.rc_dashboard_publik('{}'::jsonb);
  hasil := hasil || jsonb_build_object('uji', 'Dashboard publik tanpa penyaring = Report bawaan', 'lulus',
    (r->'dashboard'->'kpi'->>'claimQty')::int = v_n_akhir, 'rinci', r->'dashboard'->'kpi'->>'claimQty');

  -- 6. Outstanding (dok) per region dan per depot.
  r := rc_private.report_dashboard('{"semuaCampaign":"true"}'::jsonb);
  hasil := hasil || jsonb_build_object('uji', 'Performa per Region dan per Depot membawa Outstanding (dok) selain nilai', 'lulus',
    (select coalesce(sum((x->>'outstandingQty')::int), -1) from jsonb_array_elements(r->'region') x) = (select count(*) from rc_private.report_rows_snap where outstanding)
    and (select coalesce(sum((x->>'outstandingQty')::int), -1) from jsonb_array_elements(r->'depot') x) = (select count(*) from rc_private.report_rows_snap where outstanding),
    'rinci', (select count(*) from rc_private.report_rows_snap where outstanding)::text);

  insert into _hasil_rcb(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_rcb order by urut;
