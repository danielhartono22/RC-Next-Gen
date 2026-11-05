-- ==========================================================================================
-- Email Timetable: Top 10 Depot & Top 10 Campaign yang belum diupload + dashboard Timetable
-- ==========================================================================================
-- Pemilik, 4 November 2026: "email timetable perbaiki, menjadi : 10 Depot paling banyak campaign
-- yang belum diupload (dihitung dari campaign > billing date yang statusnya masih not yet).
-- 10 Campaign terbanyak yang belum upload ( > billing end) lalu sertakan dashboard time table".
--
-- * Belum diupload = pasangan depot x campaign berstatus Timetable "Not Yet" (belum ada satu
--   dokumen pun di-compile; aturan rc_private.timetable_status) yang Billing End campaign-nya
--   (atau SO End / Period End bila kosong) sudah lewat hari ini (WIB). Pilihan pemilik.
-- * Cakupan sama dengan papan Timetable: depot aktif (bukan HO) x campaign Tahun Campaign bawaan
--   modul Timetable, tanpa Exclude Campaign.
-- * Isi: Top 10 Depot (grafik + tabel), Top 10 Campaign (grafik + tabel), lalu Dashboard Timetable:
--   KPI, Proporsi Progres (Cleared / Compiled / Not Yet) dan Progres per Region - warna sama dengan
--   layar Timetable. Grafik disematkan sebagai gambar inline saat dikirim (20261163460000).
-- * Penerima, jadwal, subjek tidak berubah.
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ---- 1. Isi -----------------------------------------------------------------------------------
create or replace function rc_private.tt_email_isi(p_tahun integer default null) returns jsonb
language sql stable security definer set search_path = '' as $f$
  with t as (select coalesce(p_tahun, rc_private.timetable_tahun_baku()) tahun, (now() at time zone 'Asia/Jakarta')::date hari),
  k as (
    select ca.id, ca.campaign_code, coalesce(ca.campaign_name, '') campaign_name,
           coalesce(ca.billing_end, ca.so_end, ca.period_end) akhir
      from public.campaigns ca, t
     where ca.archived_at is null and coalesce(ca.period_start, ca.period_end) is not null
       and extract(year from coalesce(ca.period_start, ca.period_end))::integer = t.tahun
       and not exists (select 1 from public.excluded_campaigns x where x.campaign_id = ca.id)),
  d as (select dp.id, dp.depot_code, coalesce(dp.depot_name, '') depot_name, coalesce(nullif(btrim(dp.region), ''), '-') region
          from public.depots dp where dp.archived_at is null and not dp.bukan_depot),
  rekap as (
    select c.depot_id, c.campaign_id, count(*) n_dok, count(*) filter (where c.status in ('done', 'expired')) n_selesai
      from public.claims c join k on k.id = c.campaign_id where c.archived_at is null group by 1, 2),
  p as (
    select d.*, k.id campaign_id, k.campaign_code, k.campaign_name, k.akhir,
           rc_private.timetable_status(coalesce(r.n_dok, 0), coalesce(r.n_selesai, 0),
             exists (select 1 from public.timetable_not_achieved na where na.depot_id = d.id and na.campaign_id = k.id),
             rc_private.np_pasangan(d.id, k.id)) status
      from d cross join k left join rekap r on r.depot_id = d.id and r.campaign_id = k.id),
  b as (select p.* from p, t where p.status = 'Not Yet' and p.akhir is not null and p.akhir < t.hari)
  select jsonb_build_object(
    'tahun', (select tahun from t),
    'ringkas', rc_private.timetable_ringkas((select tahun from t)),
    'belum', (select count(*) from b),
    'campaignLewat', (select count(*) from k, t where k.akhir is not null and k.akhir < t.hari),
    'topDepot', coalesce((select jsonb_agg(jsonb_build_object('kode', x.depot_code, 'nama', x.depot_name, 'region', x.region, 'n', x.n)
                                  order by x.n desc, x.depot_code)
        from (select depot_code, depot_name, region, count(*) n from b group by 1, 2, 3 order by 4 desc, 1 limit 10) x), '[]'),
    'topCampaign', coalesce((select jsonb_agg(jsonb_build_object('kode', x.campaign_code, 'nama', x.campaign_name,
                                  'akhir', to_char(x.akhir, 'DD-Mon-YYYY'), 'n', x.n) order by x.n desc, x.campaign_code)
        from (select campaign_code, campaign_name, akhir, count(*) n from b group by 1, 2, 3 order by 4 desc, 1 limit 10) x), '[]'),
    'region', coalesce((select jsonb_agg(jsonb_build_object('region', x.region, 'cleared', x.cleared, 'compiled', x.compiled, 'notYet', x.not_yet)
                               order by x.region)
        from (select region, count(*) filter (where status in ('Completed', 'Not Achieved')) cleared,
                     count(*) filter (where status = 'Compiled') compiled, count(*) filter (where status = 'Not Yet') not_yet
                from p group by 1) x), '[]'));
$f$;

-- ---- 2. Grafik ---------------------------------------------------------------------------------
create or replace function rc_private.email_tt_bar(p_rows jsonb, p_label text, p_judul text) returns text
language sql stable set search_path = '' as $f$
  select case when coalesce(jsonb_array_length(p_rows), 0) = 0 then ''
  else rc_private.email_gambar(jsonb_build_object(
      'type', 'horizontalBar',
      'data', jsonb_build_object(
        'labels', (select jsonb_agg(left(e->>p_label, 24) order by n) from jsonb_array_elements(p_rows) with ordinality q(e, n)),
        'datasets', jsonb_build_array(jsonb_build_object('label', 'Belum diupload', 'backgroundColor', '#ef4444',
          'data', (select jsonb_agg((e->>'n')::int order by n) from jsonb_array_elements(p_rows) with ordinality q(e, n))))),
      'options', jsonb_build_object('legend', jsonb_build_object('display', false),
        'title', jsonb_build_object('display', true, 'text', p_judul),
        'scales', jsonb_build_object('xAxes', jsonb_build_array(jsonb_build_object('ticks', jsonb_build_object('beginAtZero', true, 'precision', 0)))))),
    p_judul, greatest(180, 40 + jsonb_array_length(p_rows) * 26))
  end;
$f$;

create or replace function rc_private.email_tt_dashboard(p_isi jsonb) returns text
language sql stable set search_path = '' as $f$
  select
    case when coalesce((p_isi->'ringkas'->>'total')::int, 0) = 0 then '' else rc_private.email_gambar(jsonb_build_object(
      'type', 'doughnut',
      'data', jsonb_build_object('labels', jsonb_build_array('Cleared', 'Compiled', 'Not Yet'),
        'datasets', jsonb_build_array(jsonb_build_object(
          'data', jsonb_build_array((p_isi->'ringkas'->>'cleared')::int, (p_isi->'ringkas'->>'compiled')::int, (p_isi->'ringkas'->>'notYet')::int),
          'backgroundColor', jsonb_build_array('#22c55e', '#f97316', '#ef4444'), 'borderColor', '#ffffff', 'borderWidth', 2))),
      'options', jsonb_build_object('title', jsonb_build_object('display', true, 'text', 'Proporsi Progres', 'fontSize', 13),
        'legend', jsonb_build_object('position', 'right', 'labels', jsonb_build_object('fontSize', 11, 'boxWidth', 12)))),
      'Proporsi Progres', 240) end
    || case when coalesce(jsonb_array_length(p_isi->'region'), 0) = 0 then '' else rc_private.email_gambar(jsonb_build_object(
      'type', 'bar',
      'data', jsonb_build_object(
        'labels', (select jsonb_agg(e->>'region' order by n) from jsonb_array_elements(p_isi->'region') with ordinality q(e, n)),
        'datasets', jsonb_build_array(
          jsonb_build_object('label', 'Cleared', 'backgroundColor', '#22c55e',
            'data', (select jsonb_agg((e->>'cleared')::int order by n) from jsonb_array_elements(p_isi->'region') with ordinality q(e, n))),
          jsonb_build_object('label', 'Compiled', 'backgroundColor', '#f97316',
            'data', (select jsonb_agg((e->>'compiled')::int order by n) from jsonb_array_elements(p_isi->'region') with ordinality q(e, n))),
          jsonb_build_object('label', 'Not Yet', 'backgroundColor', '#ef4444',
            'data', (select jsonb_agg((e->>'notYet')::int order by n) from jsonb_array_elements(p_isi->'region') with ordinality q(e, n))))),
      'options', jsonb_build_object('title', jsonb_build_object('display', true, 'text', 'Progres per Region'),
        'scales', jsonb_build_object(
          'xAxes', jsonb_build_array(jsonb_build_object('stacked', true)),
          'yAxes', jsonb_build_array(jsonb_build_object('stacked', true, 'ticks', jsonb_build_object('beginAtZero', true, 'precision', 0)))))),
      'Progres per Region', 260) end;
$f$;

-- ---- 3. HTML ---------------------------------------------------------------------------------
create or replace function rc_private.email_tt_html(p_isi jsonb) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare
  v_th text := 'padding:7px 9px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;';
  v_td text := 'padding:7px 9px;border-bottom:1px solid #eceff1;font-size:12px;';
  v_tabel text := '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin:4px 0 16px;">';
  r jsonb := p_isi->'ringkas'; v_dep text; v_camp text;
  v_kpi text := 'font-size:13px;padding:5px 16px 5px 0;';
begin
  select string_agg('<tr><td style="' || v_td || '" align="right">' || i::text || '.</td>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(x->>'kode') || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'nama') || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'region') || '</td>'
      || '<td style="' || v_td || 'font-weight:bold;color:#C8102E;" align="right">' || (x->>'n') || '</td></tr>', '' order by i)
    into v_dep from jsonb_array_elements(p_isi->'topDepot') with ordinality q(x, i);
  select string_agg('<tr><td style="' || v_td || '" align="right">' || i::text || '.</td>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(x->>'kode') || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'nama') || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(x->>'akhir') || '</td>'
      || '<td style="' || v_td || 'font-weight:bold;color:#C8102E;" align="right">' || (x->>'n') || '</td></tr>', '' order by i)
    into v_camp from jsonb_array_elements(p_isi->'topCampaign') with ordinality q(x, i);

  return '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:720px;"><tr><td>'
    || '<p>Dear All,</p>'
    || '<p style="line-height:1.6;">Berikut ringkasan <strong>Timetable Compile</strong> per ' || rc_private.tgl_panjang(now())
    || ', Tahun Campaign <strong>' || (p_isi->>'tahun') || '</strong>. Saat ini terdapat <strong>'
    || rc_private.angka((p_isi->>'belum')::numeric) || ' pasangan depot &times; campaign</strong> yang belum diupload padahal Billing End campaign-nya sudah lewat ('
    || rc_private.angka((p_isi->>'campaignLewat')::numeric) || ' campaign sudah lewat Billing End).</p>'

    || '<h3 style="font-size:15px;margin:22px 0 6px;">10 Depot dengan Campaign Belum Diupload Terbanyak</h3>'
    || case when coalesce(jsonb_array_length(p_isi->'topDepot'), 0) = 0
            then '<p style="font-size:13px;color:#1a7f37;">Tidak ada depot dengan campaign yang belum diupload setelah Billing End.</p>'
            else rc_private.email_tt_bar(p_isi->'topDepot', 'kode', 'Top 10 Depot - Campaign Belum Diupload')
              || v_tabel || '<tr style="background:#f5f6f7;"><th align="right" style="' || v_th || '">NO</th><th align="left" style="' || v_th || '">KODE DEPOT</th>'
              || '<th align="left" style="' || v_th || '">NAMA DEPOT</th><th align="left" style="' || v_th || '">REGION</th>'
              || '<th align="right" style="' || v_th || '">CAMPAIGN BELUM DIUPLOAD</th></tr>' || coalesce(v_dep, '') || '</table>' end

    || '<h3 style="font-size:15px;margin:22px 0 6px;">10 Campaign dengan Depot Belum Upload Terbanyak</h3>'
    || case when coalesce(jsonb_array_length(p_isi->'topCampaign'), 0) = 0
            then '<p style="font-size:13px;color:#1a7f37;">Tidak ada campaign yang belum diupload setelah Billing End.</p>'
            else rc_private.email_tt_bar(p_isi->'topCampaign', 'kode', 'Top 10 Campaign - Depot Belum Upload')
              || v_tabel || '<tr style="background:#f5f6f7;"><th align="right" style="' || v_th || '">NO</th><th align="left" style="' || v_th || '">KODE CAMPAIGN</th>'
              || '<th align="left" style="' || v_th || '">NAMA CAMPAIGN</th><th align="left" style="' || v_th || '">BILLING END</th>'
              || '<th align="right" style="' || v_th || '">DEPOT BELUM UPLOAD</th></tr>' || coalesce(v_camp, '') || '</table>' end

    || '<h3 style="font-size:15px;margin:22px 0 6px;">Dashboard Timetable</h3>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:6px 0 10px;">'
    || '<tr><td style="' || v_kpi || '">Campaign</td><td style="font-size:13px;font-weight:bold;">' || rc_private.angka((r->>'campaign')::numeric) || '</td></tr>'
    || '<tr><td style="' || v_kpi || '">Depot dipantau</td><td style="font-size:13px;font-weight:bold;">' || rc_private.angka((r->>'depot')::numeric) || '</td></tr>'
    || '<tr><td style="' || v_kpi || '">Kombinasi Depot x Campaign</td><td style="font-size:13px;font-weight:bold;">' || rc_private.angka((r->>'total')::numeric) || '</td></tr>'
    || '<tr><td style="' || v_kpi || '">Cleared (Completed + Not Achieved)</td><td style="font-size:13px;font-weight:bold;color:#1a7f37;">'
       || rc_private.angka((r->>'cleared')::numeric) || ' (' || rc_private.persen((r->>'clearedPct')::numeric) || ')</td></tr>'
    || '<tr><td style="' || v_kpi || '">Compiled</td><td style="font-size:13px;font-weight:bold;color:#f97316;">'
       || rc_private.angka((r->>'compiled')::numeric) || ' (' || rc_private.persen((r->>'compiledPct')::numeric) || ')</td></tr>'
    || '<tr><td style="' || v_kpi || '">Not Yet</td><td style="font-size:13px;font-weight:bold;color:#EA4335;">'
       || rc_private.angka((r->>'notYet')::numeric) || ' (' || rc_private.persen((r->>'notYetPct')::numeric) || ')</td></tr>'
    || '</table>'
    || rc_private.email_tt_dashboard(p_isi)
    || '<p style="line-height:1.6;font-size:12px;color:#5f6368;">Belum diupload = pasangan depot &times; campaign berstatus Not Yet di Timetable '
    || '(belum ada dokumen yang di-compile) dengan Billing End campaign sudah lewat. Buka modul Timetable pada aplikasi RC untuk matrix lengkapnya.</p>'
    || '<p style="line-height:1.6;">Thank you for your attention and cooperation.</p>'
    || rc_private.email_ttd()
    || '</td></tr></table></div>';
end $f$;

revoke all on function rc_private.tt_email_isi(integer), rc_private.email_tt_bar(jsonb, text, text),
  rc_private.email_tt_dashboard(jsonb), rc_private.email_tt_html(jsonb) from public, anon, authenticated;

-- ---- 4. rc_email_susun: cabang timetable ---------------------------------------------------------
do $tambal$
declare src text; a integer; b integer;
  v_akhir text := E'  else\n    raise exception ''Jenis email "%" tidak dikenali'', p_jenis;';
begin
  src := replace(pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure), E'\r', '');
  if src ~ '20261163650000' then raise notice 'rc_email_susun sudah ditambal.'; return; end if;
  a := position(E'  elsif v_jenis = ''timetable'' then\n' in src);
  b := position(v_akhir in src);
  if a = 0 or b = 0 or b < a
     or (length(src) - length(replace(src, E'  elsif v_jenis = ''timetable'' then\n', ''))) / length(E'  elsif v_jenis = ''timetable'' then\n') <> 1
     or (length(src) - length(replace(src, v_akhir, ''))) / length(v_akhir) <> 1 then
    raise exception 'DITOLAK: cabang timetable rc_email_susun tidak ditemukan utuh (% / %).', a, b; end if;
  src := left(src, a - 1)
    || $p$  elsif v_jenis = 'timetable' then
    -- 20261163650000: Top 10 Depot / Top 10 Campaign belum diupload (Not Yet, Billing End lewat) + dashboard Timetable.
    v_tt := rc_private.tt_email_isi(null);
    select array_agg(depot_code) into v_depot from public.depots
     where coalesce(btrim(email_to),'') <> '' or coalesce(btrim(email_cc),'') <> '';
    v_penerima := rc_private.penerima_depot(coalesce(v_depot,'{}'));
    v_subjek := v_set.subjek || ' - ' || rc_private.tgl_panjang(now());
    v_html := rc_private.email_tt_html(v_tt);
$p$
    || substr(src, b);
  execute src;
end $tambal$;

do $cek$ begin
  if pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure) !~ 'email_tt_html' then raise exception 'GAGAL: rc_email_susun timetable'; end if;
end $cek$;
