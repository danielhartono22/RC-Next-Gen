-- ==========================================================================================
-- Outstanding Claim %: tolok ukur baru Report dan Top 5 / Top 10 Depot
-- ==========================================================================================
-- Pemilik, 30 Oktober 2026: "tambahkan 1 field lagi yakni outstanding claim % di modul report dan
-- semua report yang akan menjadi tolak ukur TOP 5 Depo / 10 Depo Outstanding Claim. paradigma ini
-- semua yang udah depo submitted (jika approval belum hidup) tidak jadi outstanding atau kalo
-- approval sudah hidup pointnya dari approval. ... default nya dari clearing rate sekarang
-- outstanding claim", dengan pilihan: tolok ukur dapat dipilih di pengaturan email (bawaan
-- Outstanding Claim); On Hold dan Expired tidak dihitung outstanding; Report menambah Outstanding
-- Claim % dan tetap menampilkan Clearing Rate.
--
--   OUTSTANDING CLAIM  klaim yang belum melewati titik Depot:
--                        approval mati -> status Not Yet (belum diajukan Depot)
--                        approval hidup -> Not Yet + Submitted (belum disetujui)
--                      On Hold, Expired, Approved, Released, Claimed, Done: tidak.
--                      public.rc_report_rows.outstanding_claim; persen = nilai Net CB outstanding
--                      claim / seluruh Net CB (sama dengan dasar Clearing Rate). Makin kecil makin
--                      baik. Kolom outstanding (lama: belum Done / Expired) tidak berubah.
--   REPORT             report_dashboard (KPI, Depot, Campaign, Region) dan Cost Center 1 mengirim
--                      outstandingClaimQty / Value / Rate.
--   EMAIL              email_settings.tolok_ukur ('outstanding_claim' bawaan | 'clearing_rate') untuk
--                      Daily (Top 5) dan Weekly (Top 10): Outstanding Claim % tertinggi atau Clearing
--                      Rate terendah. Diagram, tabel Top Depot, kartu KPI Weekly, tabel Region, dan
--                      lampiran PDF Daily menampilkan Outstanding Claim.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ------------------------------------------------------------------------------------------
-- 1. Pengaturan tolok ukur email
-- ------------------------------------------------------------------------------------------
alter table public.email_settings add column if not exists tolok_ukur text not null default 'outstanding_claim';
do $c$ begin
  if not exists(select 1 from pg_constraint where conname = 'email_settings_tolok_ukur_check') then
    alter table public.email_settings add constraint email_settings_tolok_ukur_check check (tolok_ukur in ('outstanding_claim', 'clearing_rate'));
  end if;
end $c$;
comment on column public.email_settings.tolok_ukur is
  'Tolok ukur Top Depot email Daily / Weekly (20261163570000): outstanding_claim (bawaan) atau clearing_rate.';

-- ------------------------------------------------------------------------------------------
-- 2. Baris Report: kolom outstanding_claim
-- ------------------------------------------------------------------------------------------
do $v$
begin
  if exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'rc_report_rows' and column_name = 'outstanding_claim') then
    raise notice 'rc_report_rows sudah punya outstanding_claim.';
    return;
  end if;
  if left(md5(pg_get_viewdef('public.rc_report_rows'::regclass, true)), 8) <> '996127e5' then
    raise exception 'DITOLAK: definisi rc_report_rows berbeda dari yang diukur (md5 %).', left(md5(pg_get_viewdef('public.rc_report_rows'::regclass, true)), 8);
  end if;
  execute $sql$
  create or replace view public.rc_report_rows as
  select c.id, c.no_doc, c.status, c.cb_net, c.cleared_at, c.uploaded_at, c.tax_subject,
         d.id as depot_id, d.depot_code, d.depot_name, coalesce(d.region, ''::text) as region,
         ca.id as campaign_id, ca.campaign_code, ca.campaign_name, ca.tax_status, ca.period_start, ca.period_end,
         case when c.adhoc_at is not null then c.gross_up
              else rc_private.gross_up_klaim(c.cb_net, c.tax_subject, ca.tax_status, coalesce(nullif(c.cashback_type_override, ''::text), ca.cashback_type))
         end as gross_claimed,
         c.status = any (array['not_yet'::text, 'submitted'::text, 'approved'::text, 'released'::text, 'claimed'::text]) as outstanding,
         coalesce(ca.period_end, ca.period_start, c.uploaded_at::date) as acuan_aging,
         coalesce(c.extend_billing_start, ca.billing_start) as billing_start,
         coalesce(c.extend_billing_end, ca.billing_end) as billing_end,
         coalesce(c.extend_so_start, ca.so_start) as so_start,
         coalesce(c.extend_so_end, ca.so_end) as so_end,
         extract(year from coalesce(ca.period_start, ca.period_end))::integer as campaign_year,
         -- 20261163570000: belum melewati titik Depot (Submit, atau Approval bila approval hidup).
         (c.status = 'not_yet' or (c.status = 'submitted' and (select rc_private.approval_aktif()))) as outstanding_claim
    from public.claims c
    join public.depots d on d.id = c.depot_id
    join public.campaigns ca on ca.id = c.campaign_id
   where c.archived_at is null
     and not exists (select 1 from public.excluded_campaigns x where x.campaign_id = ca.id)
  $sql$;
end $v$;

-- ------------------------------------------------------------------------------------------
-- 3. Bagian email: judul, diagram, tabel Top Depot
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.email_judul_top(p_ukur text, p_n integer) returns text
language sql immutable set search_path = '' as $f$
  select 'Top ' || p_n || ' Depot dengan '
         || case when p_ukur = 'clearing_rate' then 'Clearing Rate Terendah' else 'Outstanding Claim Tertinggi' end;
$f$;

-- p_ukur 'outstanding_claim': batang = Outstanding Claim %, warna dibalik (makin tinggi makin merah).
create or replace function rc_private.email_chart_depot(p_top jsonb, p_judul text, p_ukur text)
returns text language sql stable set search_path = '' as $f$
  select case when coalesce(jsonb_array_length(p_top),0) = 0 then ''
  else rc_private.email_gambar(
    jsonb_build_object(
      'type','horizontalBar',
      'data', jsonb_build_object(
        'labels', (select jsonb_agg(left(e->>'label',20) order by n)
                     from jsonb_array_elements(p_top) with ordinality t(e,n)),
        'datasets', jsonb_build_array(jsonb_build_object(
          'label', case when p_ukur = 'clearing_rate' then 'Clearing Rate (%)' else 'Outstanding Claim (%)' end,
          'backgroundColor', (select jsonb_agg(case when p_ukur = 'clearing_rate' then rc_private.warna_persen((e->>'cr')::numeric)
                                                    else rc_private.warna_persen(1 - coalesce((e->>'oc')::numeric, 0)) end order by n)
                                from jsonb_array_elements(p_top) with ordinality t(e,n)),
          'data', (select jsonb_agg(round(coalesce((e->>(case when p_ukur = 'clearing_rate' then 'cr' else 'oc' end))::numeric, 0) * 100, 1) order by n)
                     from jsonb_array_elements(p_top) with ordinality t(e,n))))),
      'options', jsonb_build_object(
        'legend', jsonb_build_object('display', false),
        'title', jsonb_build_object('display', true, 'text', p_judul),
        'scales', jsonb_build_object(
          'xAxes', jsonb_build_array(jsonb_build_object(
            'ticks', jsonb_build_object('beginAtZero', true, 'max', 100)))))),
    p_judul,
    greatest(180, 40 + coalesce(jsonb_array_length(p_top),0) * 26))
  end;
$f$;

-- Bentuk lama (dua argumen) tetap: Clearing Rate.
create or replace function rc_private.email_chart_depot(p_top jsonb, p_judul text)
returns text language sql stable set search_path = '' as $f$
  select rc_private.email_chart_depot(p_top, p_judul, 'clearing_rate');
$f$;

-- Tabel Top Depot: kolom Outstanding Claim ditambahkan (warna dibalik: makin tinggi makin merah).
create or replace function rc_private.email_tabel_performa(p_rows jsonb, p_judul text)
returns text language plpgsql stable set search_path = '' as $f$
declare
  th   text := 'style="text-align:left;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;"';
  thn  text := 'style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;"';
  td   text := 'style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;"';
  tdn  text := 'style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;"';
  r jsonb; i integer := 0; isi text := ''; warna text; warna_oc text;
begin
  if p_rows is null or jsonb_array_length(p_rows) = 0 then
    return '<p style="color:#5f6368;">Tidak ada data.</p>';
  end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    i := i + 1;
    warna := rc_private.warna_persen((r->>'cr')::numeric);
    warna_oc := rc_private.warna_persen(1 - coalesce((r->>'oc')::numeric, 0));
    isi := isi || '<tr>'
      || '<td ' || td || ' width="24">' || i || '.</td>'
      || '<td ' || td || '>' || rc_private.html_aman(r->>'label') || '</td>'
      || '<td ' || tdn || '>' || rc_private.rupiah((r->>'netCb')::numeric) || '</td>'
      || '<td ' || tdn || '>' || rc_private.angka((r->>'qty')::numeric) || '</td>'
      || '<td ' || tdn || '>' || rc_private.rupiah((r->>'osVal')::numeric) || '</td>'
      || '<td ' || tdn || '>' || rc_private.angka((r->>'osQty')::numeric) || '</td>'
      || '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;'
      || 'white-space:nowrap;background-color:' || warna || ';color:#ffffff;font-weight:bold;" bgcolor="'
      || warna || '">' || rc_private.persen((r->>'cr')::numeric) || '</td>'
      || case when r ? 'oc' then
           '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;'
           || 'white-space:nowrap;background-color:' || warna_oc || ';color:#ffffff;font-weight:bold;" bgcolor="'
           || warna_oc || '">' || rc_private.persen((r->>'oc')::numeric) || '</td>'
         else '<td ' || tdn || '>-</td>' end
      || '</tr>';
  end loop;
  return '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
    || '<thead><tr><th ' || th || ' width="24">#</th><th ' || th || '>' || rc_private.html_aman(p_judul) || '</th>'
    || '<th ' || thn || '>Net CB</th><th ' || thn || '>Claim Qty</th>'
    || '<th ' || thn || '>Outstanding</th><th ' || thn || '>Outstanding Qty</th>'
    || '<th ' || thn || '>Clearing Rate</th><th ' || thn || '>Outstanding Claim</th></tr></thead><tbody>' || isi || '</tbody></table>';
end $f$;

revoke all on function rc_private.email_judul_top(text, integer), rc_private.email_chart_depot(jsonb, text, text) from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Tambalan fungsi Report dan email (pola diperiksa terhadap prod 30 Oktober 2026)
-- ------------------------------------------------------------------------------------------

do $tambal$
declare src text; f text;
begin
  f := 'rc_private.report_dashboard(jsonb)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src ~ '20261163570000' then raise notice '% sudah ditambal.', f;
  else
  src := pg_temp.ganti(src, $p$        'jumlahDepot',    count(distinct depot_id),$p$,
    $p$        -- 20261163570000: Outstanding Claim = klaim yang belum melewati titik Depot.
        'outstandingClaimQty',   count(*) filter (where outstanding_claim),
        'outstandingClaimValue', coalesce(sum(cb_net) filter (where outstanding_claim),0),
        'outstandingClaimRate',  case when coalesce(sum(cb_net),0)=0 then 0
          else coalesce(sum(cb_net) filter (where outstanding_claim),0)/sum(cb_net) end,
        'jumlahDepot',    count(distinct depot_id),$p$, 1, 'rc_private.report_dashboard(jsonb) #1');
  src := pg_temp.ganti(src, $p$        'outstandingRate',x.os_rate,'clearingRate',x.cr)$p$,
    $p$        'outstandingRate',x.os_rate,'clearingRate',x.cr,
        'outstandingClaimQty',x.oc_qty,'outstandingClaimValue',x.oc_val,'outstandingClaimRate',x.oc_rate) /* 20261163570000 */$p$, 1, 'rc_private.report_dashboard(jsonb) #2');
  src := pg_temp.ganti(src, $p$                   coalesce(sum(cb_net) filter (where status='expired'),0) cb_expired,
                   count(*) filter (where outstanding) os_qty,$p$,
    $p$                   coalesce(sum(cb_net) filter (where status='expired'),0) cb_expired,
                   count(*) filter (where outstanding_claim) oc_qty,
                   coalesce(sum(cb_net) filter (where outstanding_claim),0) oc_val,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where outstanding_claim),0)/sum(cb_net) end oc_rate,
                   count(*) filter (where outstanding) os_qty,$p$, 1, 'rc_private.report_dashboard(jsonb) #3');
  src := pg_temp.ganti(src, $p$        'outstandingRate',y.os_rate,'clearingRate',y.cr)$p$,
    $p$        'outstandingRate',y.os_rate,'clearingRate',y.cr,
        'outstandingClaimQty',y.oc_qty,'outstandingClaimValue',y.oc_val,'outstandingClaimRate',y.oc_rate) /* 20261163570000 */$p$, 1, 'rc_private.report_dashboard(jsonb) #4');
  src := pg_temp.ganti(src, $p$                   coalesce(sum(cb_net) filter (where status='done'),0) net_claimed,
                   count(*) filter (where outstanding) os_qty,$p$,
    $p$                   coalesce(sum(cb_net) filter (where status='done'),0) net_claimed,
                   count(*) filter (where outstanding_claim) oc_qty,
                   coalesce(sum(cb_net) filter (where outstanding_claim),0) oc_val,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where outstanding_claim),0)/sum(cb_net) end oc_rate,
                   count(*) filter (where outstanding) os_qty,$p$, 1, 'rc_private.report_dashboard(jsonb) #5');
  src := pg_temp.ganti(src, $p$        'outstandingValue',z.os_val,'clearingRate',z.cr) order by z.region)$p$,
    $p$        'outstandingValue',z.os_val,'clearingRate',z.cr,
        'outstandingClaimQty',z.oc_qty,'outstandingClaimValue',z.oc_val,'outstandingClaimRate',z.oc_rate) /* 20261163570000 */ order by z.region)$p$, 1, 'rc_private.report_dashboard(jsonb) #6');
  src := pg_temp.ganti(src, $p$                   coalesce(sum(cb_net) filter (where status='done'),0) net_claimed,
                   coalesce(sum(cb_net) filter (where outstanding),0) os_val,$p$,
    $p$                   coalesce(sum(cb_net) filter (where status='done'),0) net_claimed,
                   count(*) filter (where outstanding_claim) oc_qty,
                   coalesce(sum(cb_net) filter (where outstanding_claim),0) oc_val,
                   case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where outstanding_claim),0)/sum(cb_net) end oc_rate,
                   coalesce(sum(cb_net) filter (where outstanding),0) os_val,$p$, 1, 'rc_private.report_dashboard(jsonb) #7');
    execute src;
  end if;

  f := 'rc_private.cost_center(jsonb)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src ~ '20261163570000' then raise notice '% sudah ditambal.', f;
  else
  src := pg_temp.ganti(src, $p$'cbExpired',t.cb_expired,'clearingRate',t.cr)$p$,
    $p$'cbExpired',t.cb_expired,'clearingRate',t.cr,
      'outstandingClaimValue',t.oc_val,'outstandingClaimRate',t.oc_rate) /* 20261163570000 */$p$, 1, 'rc_private.cost_center(jsonb) #1');
  src := pg_temp.ganti(src, $p$           coalesce(sum(cb_net) filter (where status='expired'),0) cb_expired,$p$,
    $p$           coalesce(sum(cb_net) filter (where status='expired'),0) cb_expired,
           coalesce(sum(cb_net) filter (where outstanding_claim),0) oc_val,
           case when coalesce(sum(cb_net),0)=0 then 0
                else coalesce(sum(cb_net) filter (where outstanding_claim),0)/sum(cb_net) end oc_rate,$p$, 1, 'rc_private.cost_center(jsonb) #2');
    execute src;
  end if;

  f := 'public.rc_email_susun(text,boolean,text)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src ~ '20261163570000' then raise notice '% sudah ditambal.', f;
  else
  src := pg_temp.ganti(src, $p$  v_tt jsonb; -- 20261163030000$p$,
    $p$  v_tt jsonb; -- 20261163030000
  v_ukur text; v_judul_top text; -- 20261163570000$p$, 1, 'public.rc_email_susun(text,boolean,text) #1');
  src := pg_temp.ganti(src, $p$  if not found then raise exception 'Jenis email "%" tidak dikenali', p_jenis; end if;$p$,
    $p$  if not found then raise exception 'Jenis email "%" tidak dikenali', p_jenis; end if;
  -- 20261163570000: tolok ukur Top Depot (Daily, Weekly): Outstanding Claim % tertinggi (bawaan)
  -- atau Clearing Rate terendah.
  v_ukur := case when coalesce(v_set.tolok_ukur, '') = 'clearing_rate' then 'clearing_rate' else 'outstanding_claim' end;$p$, 1, 'public.rc_email_susun(text,boolean,text) #2');
  src := pg_temp.ganti(src, $p$    'osQty',count(*) filter (where outstanding),$p$,
    $p$    'osQty',count(*) filter (where outstanding),
    'ocVal',coalesce(sum(cb_net) filter (where outstanding_claim),0),
    'ocQty',count(*) filter (where outstanding_claim),
    'oc',case when coalesce(sum(cb_net),0)=0 then 0
         else coalesce(sum(cb_net) filter (where outstanding_claim),0)/sum(cb_net) end,$p$, 1, 'public.rc_email_susun(text,boolean,text) #3');
  src := pg_temp.ganti(src, $p$             count(*) filter (where c.outstanding) os_qty,
$p$,
    $p$             count(*) filter (where c.outstanding) os_qty,
             coalesce(sum(c.cb_net) filter (where c.outstanding_claim),0) oc_val,
             count(*) filter (where c.outstanding_claim) oc_qty,
             case when coalesce(sum(c.cb_net),0)=0 then 0
                  else coalesce(sum(c.cb_net) filter (where c.outstanding_claim),0)/sum(c.cb_net) end oc,
$p$, 2, 'public.rc_email_susun(text,boolean,text) #4');
  src := pg_temp.ganti(src, $p$         and coalesce(sum(c.cb_net) filter (where c.outstanding),0) > 0
    ), top5 as (select * from r order by cr, os_val desc limit 5)$p$,
    $p$         and coalesce(sum(c.cb_net) filter (where case when v_ukur = 'clearing_rate' then c.outstanding else c.outstanding_claim end),0) > 0
    ), top5 as (select * from r
                 order by case when v_ukur = 'clearing_rate' then cr else -oc end,
                          case when v_ukur = 'clearing_rate' then os_val else oc_val end desc limit 5)$p$, 1, 'public.rc_email_susun(text,boolean,text) #5');
  src := pg_temp.ganti(src, $p$             'netCb',net_cb,'qty',qty,'osVal',os_val,'osQty',os_qty,'cr',cr)
             order by cr, os_val desc),$p$,
    $p$             'netCb',net_cb,'qty',qty,'osVal',os_val,'osQty',os_qty,'cr',cr,'oc',oc,'ocVal',oc_val,'ocQty',oc_qty)
             order by case when v_ukur = 'clearing_rate' then cr else -oc end,
                      case when v_ukur = 'clearing_rate' then os_val else oc_val end desc),$p$, 1, 'public.rc_email_susun(text,boolean,text) #6');
  src := pg_temp.ganti(src, $p$             'netCb',net_cb,'qty',qty,'osVal',os_val,'osQty',os_qty,'cr',cr) order by cr, os_val desc)
      into v_top from (select * from r order by cr, os_val desc limit 10) t;$p$,
    $p$             'netCb',net_cb,'qty',qty,'osVal',os_val,'osQty',os_qty,'cr',cr,'oc',oc,'ocVal',oc_val,'ocQty',oc_qty)
             order by case when v_ukur = 'clearing_rate' then cr else -oc end,
                      case when v_ukur = 'clearing_rate' then os_val else oc_val end desc)
      into v_top from (select * from r order by case when v_ukur = 'clearing_rate' then cr else -oc end,
                                                 case when v_ukur = 'clearing_rate' then os_val else oc_val end desc limit 10) t;$p$, 1, 'public.rc_email_susun(text,boolean,text) #7');
  src := pg_temp.ganti(src, $p$        'skipped',jsonb_build_object('sebab','Tidak ada depot dengan outstanding'))$p$,
    $p$        'skipped',jsonb_build_object('sebab',case when v_ukur = 'clearing_rate' then 'Tidak ada depot dengan outstanding'
                                                  else 'Tidak ada depot dengan Outstanding Claim' end))$p$, 1, 'public.rc_email_susun(text,boolean,text) #8');
  src := pg_temp.ganti(src, $p$        ||rc_private.persen((v_kpi->>'cr')::numeric)||'</strong>.</p>'
      ||'<h3 style="font-size:15px;margin:22px 0 8px;">Top 5 Depot dengan Clearing Rate Terendah</h3>'
      ||rc_private.email_chart_depot(v_top,'Top 5 Depot dengan Clearing Rate Terendah')$p$,
    $p$        ||rc_private.persen((v_kpi->>'cr')::numeric)||'</strong>, serta <strong>Outstanding Claim sebesar '
        ||rc_private.persen((v_kpi->>'oc')::numeric)||'</strong> ('||rc_private.angka((v_kpi->>'ocQty')::numeric)
        ||' klaim senilai '||rc_private.rupiah((v_kpi->>'ocVal')::numeric)
        ||' yang belum '||case when rc_private.approval_aktif() then 'disetujui' else 'diajukan Depot' end||').</p>'
      ||'<h3 style="font-size:15px;margin:22px 0 8px;">'||rc_private.email_judul_top(v_ukur, 5)||'</h3>'
      ||rc_private.email_chart_depot(v_top,rc_private.email_judul_top(v_ukur, 5),v_ukur)$p$, 1, 'public.rc_email_susun(text,boolean,text) #9');
  src := pg_temp.ganti(src, $p$        ||'penyelesaian Outstanding Claim</strong>, khususnya pada Depot dengan Clearing Rate yang masih rendah.</p>'$p$,
    $p$        ||'penyelesaian Outstanding Claim</strong>, khususnya pada Depot dengan '
        ||case when v_ukur = 'clearing_rate' then 'Clearing Rate yang masih rendah' else 'Outstanding Claim yang masih tinggi' end||'.</p>'$p$, 1, 'public.rc_email_susun(text,boolean,text) #10');
  src := pg_temp.ganti(src, $p$width="25%" style="padding:10px 12px;border:1px solid #e0e2e6;vertical-align:top;">$p$,
    $p$width="20%" style="padding:10px 12px;border:1px solid #e0e2e6;vertical-align:top;">$p$, 4, 'public.rc_email_susun(text,boolean,text) #11');
  src := pg_temp.ganti(src, $p$        ||'<div style="font-size:16px;font-weight:bold;color:#1a7f37;margin-top:4px;">'||rc_private.persen((v_kpi->>'cr')::numeric)||'</div></td>'
      ||'</tr></table>'$p$,
    $p$        ||'<div style="font-size:16px;font-weight:bold;color:#1a7f37;margin-top:4px;">'||rc_private.persen((v_kpi->>'cr')::numeric)||'</div></td>'
      ||'<td width="20%" style="padding:10px 12px;border:1px solid #e0e2e6;vertical-align:top;">'
        ||'<div style="font-size:10px;color:#5f6368;text-transform:uppercase;letter-spacing:.03em;">Outstanding Claim</div>'
        ||'<div style="font-size:16px;font-weight:bold;color:#EA4335;margin-top:4px;">'||rc_private.persen((v_kpi->>'oc')::numeric)
        ||' <span style="font-size:11px;color:#5f6368;font-weight:normal;">'||rc_private.angka((v_kpi->>'ocQty')::numeric)||' klaim</span></div></td>'
      ||'</tr></table>'$p$, 1, 'public.rc_email_susun(text,boolean,text) #12');
  src := pg_temp.ganti(src, $p$      ||'<h3 style="font-size:15px;margin:26px 0 8px;border-left:4px solid #4285F4;padding-left:8px;">Top 10 Depot dengan Clearing Rate Terendah</h3>'
      ||rc_private.email_chart_depot(coalesce(v_top,'[]'::jsonb),'Top 10 Depot dengan Clearing Rate Terendah')$p$,
    $p$      ||'<h3 style="font-size:15px;margin:26px 0 8px;border-left:4px solid #4285F4;padding-left:8px;">'||rc_private.email_judul_top(v_ukur, 10)||'</h3>'
      ||rc_private.email_chart_depot(coalesce(v_top,'[]'::jsonb),rc_private.email_judul_top(v_ukur, 10),v_ukur)$p$, 1, 'public.rc_email_susun(text,boolean,text) #13');
  src := pg_temp.ganti(src, $p$      ||rc_private.persen(q.cr)||'</td></tr>', '' order by q.os_val desc)$p$,
    $p$      ||rc_private.persen(q.cr)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'
      ||rc_private.persen(q.oc)||'</td></tr>', '' order by q.os_val desc)$p$, 1, 'public.rc_email_susun(text,boolean,text) #14');
  src := pg_temp.ganti(src, $p$             count(*) filter (where outstanding) os_qty,
$p$,
    $p$             count(*) filter (where outstanding) os_qty,
             case when coalesce(sum(cb_net),0)=0 then 0
                  else coalesce(sum(cb_net) filter (where outstanding_claim),0)/sum(cb_net) end oc,
$p$, 1, 'public.rc_email_susun(text,boolean,text) #15');
  src := pg_temp.ganti(src, $p$white-space:nowrap;">Clearing Rate</th>'
        ||'</tr></thead><tbody>'||v_region$p$,
    $p$white-space:nowrap;">Clearing Rate</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Outstanding Claim</th>'
        ||'</tr></thead><tbody>'||v_region$p$, 1, 'public.rc_email_susun(text,boolean,text) #16');
    execute src;
  end if;

  f := 'rc_private.pdf_detail_html(text)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src ~ '20261163570000' then raise notice '% sudah ditambal.', f;
  else
  src := pg_temp.ganti(src, $p$  v_html text; v_kpi jsonb; v_baris text;$p$,
    $p$  v_html text; v_kpi jsonb; v_baris text;
  -- 20261163570000: Top 10 mengikuti tolok ukur email Daily.
  v_ukur text := case when (select tolok_ukur from public.email_settings where jenis = 'daily') = 'clearing_rate'
                      then 'clearing_rate' else 'outstanding_claim' end;$p$, 1, 'rc_private.pdf_detail_html(text) #1');
  src := pg_temp.ganti(src, $p$      'osQty',     count(*) filter (where outstanding),$p$,
    $p$      'osQty',     count(*) filter (where outstanding),
      'ocQty',     count(*) filter (where outstanding_claim),
      'oc',        case when coalesce(sum(cb_net),0)=0 then 0
                        else coalesce(sum(cb_net) filter (where outstanding_claim),0)/sum(cb_net) end,$p$, 1, 'rc_private.pdf_detail_html(text) #2');
  src := pg_temp.ganti(src, $p$    || '<tr><td>Overall Clearing Rate</td><td align="right">' || rc_private.persen((v_kpi->>'cr')::numeric) || '</td></tr>'$p$,
    $p$    || '<tr><td>Overall Clearing Rate</td><td align="right">' || rc_private.persen((v_kpi->>'cr')::numeric) || '</td></tr>'
    || '<tr><td>Outstanding Claim (' || rc_private.angka((v_kpi->>'ocQty')::numeric) || ' klaim)</td><td align="right">'
    || rc_private.persen((v_kpi->>'oc')::numeric) || '</td></tr>'$p$, 1, 'rc_private.pdf_detail_html(text) #3');
  src := pg_temp.ganti(src, $p$      || '<td align="right">' || rc_private.persen(q.cr) || '</td></tr>', '' order by q.cr, q.os_val desc), '')
    into v_baris
    from (select d.depot_code || ' - ' || d.depot_name as label,
                 coalesce(sum(c.cb_net),0) net_cb,$p$,
    $p$      || '<td align="right">' || rc_private.persen(q.cr) || '</td>'
      || '<td align="right">' || rc_private.persen(q.oc) || '</td></tr>', '' order by q.urut), '')
    into v_baris
    from (select d.depot_code || ' - ' || d.depot_name as label,
                 row_number() over (order by case when v_ukur = 'clearing_rate' then
                       case when coalesce(sum(c.cb_net),0)=0 then 0
                            else coalesce(sum(c.cb_net) filter (where c.status in('done','expired')),0)/sum(c.cb_net) end
                     else -(case when coalesce(sum(c.cb_net),0)=0 then 0
                                 else coalesce(sum(c.cb_net) filter (where c.outstanding_claim),0)/sum(c.cb_net) end) end,
                   case when v_ukur = 'clearing_rate' then coalesce(sum(c.cb_net) filter (where c.outstanding),0)
                        else coalesce(sum(c.cb_net) filter (where c.outstanding_claim),0) end desc) urut,
                 case when coalesce(sum(c.cb_net),0)=0 then 0
                      else coalesce(sum(c.cb_net) filter (where c.outstanding_claim),0)/sum(c.cb_net) end oc,
                 coalesce(sum(c.cb_net),0) net_cb,$p$, 1, 'rc_private.pdf_detail_html(text) #4');
  src := pg_temp.ganti(src, $p$          having coalesce(sum(c.cb_net),0) > 0
           order by cr, os_val desc limit 10) q;$p$,
    $p$          having coalesce(sum(c.cb_net),0) > 0
           order by 2 limit 10) q;$p$, 1, 'rc_private.pdf_detail_html(text) #5');
  src := pg_temp.ganti(src, $p$  v_html := v_html || '<h2 style="font-size:14px;">Top 10 Depot - Clearing Rate Terendah</h2>'
    || '<table border="1" cellspacing="0" cellpadding="5" style="border-collapse:collapse;font-size:11px;">'
    || '<tr><th align="left">Depot</th><th align="right">Net CB</th><th align="right">Outstanding</th>'
    || '<th align="right">Clearing Rate</th></tr>' || v_baris || '</table>';$p$,
    $p$  v_html := v_html || '<h2 style="font-size:14px;">' || rc_private.email_judul_top(v_ukur, 10) || '</h2>'
    || '<table border="1" cellspacing="0" cellpadding="5" style="border-collapse:collapse;font-size:11px;">'
    || '<tr><th align="left">Depot</th><th align="right">Net CB</th><th align="right">Outstanding</th>'
    || '<th align="right">Clearing Rate</th><th align="right">Outstanding Claim</th></tr>' || v_baris || '</table>';$p$, 1, 'rc_private.pdf_detail_html(text) #6');
    execute src;
  end if;

  f := 'public.rc_email_status()';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src ~ '20261163570000' then raise notice '% sudah ditambal.', f;
  else
  src := pg_temp.ganti(src, $p$'toTetap',jenis = 'kesehatan') order by jenis)$p$,
    $p$'toTetap',jenis = 'kesehatan',
        'tolokUkur',case when jenis in ('daily','weekly') then tolok_ukur end /* 20261163570000 */) order by jenis)$p$, 1, 'public.rc_email_status() #1');
    execute src;
  end if;

  f := 'public.rc_email_settings_simpan(jsonb)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src ~ '20261163570000' then raise notice '% sudah ditambal.', f;
  else
  src := pg_temp.ganti(src, $p$    -- 20261163370000: CC tambahan jadwal lain (daily, weekly, timetable, notachieved).$p$,
    $p$    -- 20261163570000: tolok ukur Top Depot email Daily / Weekly.
    if lower(btrim(r->>'jenis')) in ('daily', 'weekly') and r ? 'tolokUkur' then
      if coalesce(r->>'tolokUkur', '') not in ('outstanding_claim', 'clearing_rate') then
        raise exception 'Tolok ukur Top Depot harus outstanding_claim atau clearing_rate'; end if;
      update public.email_settings set tolok_ukur = r->>'tolokUkur' where jenis = lower(btrim(r->>'jenis'));
    end if;
    -- 20261163370000: CC tambahan jadwal lain (daily, weekly, timetable, notachieved).$p$, 1, 'public.rc_email_settings_simpan(jsonb) #1');
    execute src;
  end if;
end $tambal$;

-- ------------------------------------------------------------------------------------------
-- 5. Pemeriksaan diri
-- ------------------------------------------------------------------------------------------
do $cek$
declare e text := ''; f text;
begin
  if not exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'rc_report_rows' and column_name = 'outstanding_claim') then
    e := e || ' kolom view;'; end if;
  foreach f in array array['rc_private.report_dashboard(jsonb)', 'rc_private.cost_center(jsonb)', 'public.rc_email_susun(text,boolean,text)',
                           'rc_private.pdf_detail_html(text)', 'public.rc_email_status()', 'public.rc_email_settings_simpan(jsonb)'] loop
    if pg_get_functiondef(f::regprocedure) !~ '20261163570000' then e := e || ' ' || f || ';'; end if;
  end loop;
  if (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'email_settings' and column_name = 'tolok_ukur')
     is distinct from '''outstanding_claim''::text' then e := e || ' bawaan tolok ukur;'; end if;
  if rc_private.email_judul_top('outstanding_claim', 5) <> 'Top 5 Depot dengan Outstanding Claim Tertinggi'
     or rc_private.email_judul_top('clearing_rate', 10) <> 'Top 10 Depot dengan Clearing Rate Terendah' then e := e || ' judul;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
