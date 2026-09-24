-- ==========================================================================================
-- Isi email dibuat persis seperti DailyEmail.gs dan WeeklyEmail.gs
-- ==========================================================================================
-- Pemilik meminta body dan content email sama persis dengan yang dikirim sistem lama, dan
-- meminta adanya pengujian dengan memasukkan satu alamat penerima.
--
-- Susunan di bawah ini disalin dari RC_Reporting_AppsScript:
--   Daily   -> buildEmailHtml() dan buildEmailPerfTableHtml() pada DailyEmail.gs
--   Weekly  -> buildWeeklyEmailHtml(), buildWeeklyKpiCardsHtml(), buildStatusGroupTableHtml()
--              dan buildRegionBreakdownTableHtml() pada WeeklyEmail.gs
-- termasuk kalimat pembuka, urutan bagian, gaya inline tiap sel, gradasi warna clearing rate
-- merah #EA4335 -> hijau #34A853, dan blok tanda tangan "SA & SD Operation".
--
-- SATU HAL YANG TIDAK DAPAT DISALIN: GAMBAR GRAFIK
-- Sistem lama menyisipkan grafik sebagai gambar inline (cid:top5Chart dan seterusnya) yang
-- digambar Apps Script lewat QuickChart. Di sini email disusun di dalam PostgreSQL dan dikirim
-- lewat pg_net; tidak ada yang dapat menggambar PNG. Karena itu bagian gambarnya dilewati,
-- sedangkan seluruh TABEL di bawah tiap grafik dipertahankan utuh - dan tabel itulah yang
-- memuat angkanya. Pembaca yang gambarnya diblokir mail client - keadaan yang lumrah di
-- Outlook - sejak dulu memang hanya melihat tabel ini.
--
-- Gaya ditulis inline pada setiap elemen, bukan sebagai blok <style>, karena banyak mail
-- client - terutama Outlook - membuang <style> di dalam badan email.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- Pemisah ribuan titik, seperti groupThousands() pada DailyEmail.gs.
create or replace function rc_private.angka(n numeric)
returns text language sql immutable set search_path='' as $fn$
  select case when coalesce(n,0) < 0 then '-' else '' end
      || replace(to_char(abs(round(coalesce(n,0))), 'FM999G999G999G999G990'), ',', '.');
$fn$;
revoke all on function rc_private.angka(numeric) from public,anon;

create or replace function rc_private.rupiah(n numeric)
returns text language sql immutable set search_path='' as $fn$
  select case when coalesce(n,0) < 0 then '-' else '' end || 'Rp ' || rc_private.angka(abs(coalesce(n,0)));
$fn$;
revoke all on function rc_private.rupiah(numeric) from public,anon;

-- Rupiah ringkas untuk kartu KPI: Rp1,2 M / Rp850 Jt / Rp250 Rb - sama seperti
-- formatRupiahCompact() pada DailyEmail.gs, termasuk koma sebagai pemisah desimal.
create or replace function rc_private.rupiah_ringkas(n numeric)
returns text language sql immutable set search_path='' as $fn$
  select case when coalesce(n,0) < 0 then '-' else '' end || 'Rp' ||
    case
      when abs(coalesce(n,0)) >= 1000000000 then replace(to_char(abs(n)/1000000000,'FM990.0'),'.',',') || ' M'
      when abs(coalesce(n,0)) >= 1000000    then replace(to_char(abs(n)/1000000,'FM990.0'),'.',',') || ' Jt'
      when abs(coalesce(n,0)) >= 1000       then replace(to_char(abs(n)/1000,'FM990.0'),'.',',') || ' Rb'
      else to_char(abs(coalesce(n,0)),'FM999990')
    end;
$fn$;
revoke all on function rc_private.rupiah_ringkas(numeric) from public,anon;

-- formatPercent(): satu angka di belakang koma, memakai titik seperti aslinya.
create or replace function rc_private.persen(p numeric)
returns text language sql immutable set search_path='' as $fn$
  select to_char(round(coalesce(p,0) * 1000) / 10, 'FM999990.0') || '%';
$fn$;
revoke all on function rc_private.persen(numeric) from public,anon;

-- "19 September 2026". Nama bulan ditulis di sini, bukan diambil dari lokal server, persis
-- seperti COST_CENTER_DETAIL_MONTHS pada Config.gs.
create or replace function rc_private.tgl_panjang(t timestamptz)
returns text language sql stable set search_path='' as $fn$
  select to_char(t at time zone 'Asia/Jakarta','DD') || ' ' ||
    (array['Januari','Februari','Maret','April','Mei','Juni',
           'Juli','Agustus','September','Oktober','November','Desember'])
      [extract(month from t at time zone 'Asia/Jakarta')::int] || ' ' ||
    to_char(t at time zone 'Asia/Jakarta','YYYY');
$fn$;
revoke all on function rc_private.tgl_panjang(timestamptz) from public,anon;

-- percentToColor(): gradasi linear merah -> hijau, skala yang sama dengan Cost Center 2.
create or replace function rc_private.warna_persen(p numeric)
returns text language sql immutable set search_path='' as $fn$
  select '#' ||
    lpad(to_hex((234 + (52  - 234) * greatest(0,least(1,coalesce(p,0))))::int), 2, '0') ||
    lpad(to_hex((67  + (168 - 67 ) * greatest(0,least(1,coalesce(p,0))))::int), 2, '0') ||
    lpad(to_hex((53  + (83  - 53 ) * greatest(0,least(1,coalesce(p,0))))::int), 2, '0');
$fn$;
revoke all on function rc_private.warna_persen(numeric) from public,anon;

-- Blok tanda tangan, sama untuk Daily maupun Weekly (buildEmailSignatureHtml).
create or replace function rc_private.email_ttd()
returns text language sql stable set search_path='' as $fn$
  select '<p style="margin-top:18px;">Best Regards,<br><strong>SA &amp; SD Operation</strong></p>'
    || '<p style="color:#5f6368;font-size:11px;border-top:1px solid #e0e2e6;padding-top:8px;margin-top:20px;">'
    || 'Data ditarik pada ' || rc_private.tgl_panjang(now()) || ' '
    || to_char(now() at time zone 'Asia/Jakarta','HH24:MI') || '.<br>'
    || 'Email ini dikirimkan secara otomatis dan Laporkan ke '
    || 'sa_sd1@nipponpaint-indonesia.com (Daniel) jika terdapat kesalahan teknis.</p>';
$fn$;
revoke all on function rc_private.email_ttd() from public,anon;

-- ------------------------------------------------------------------------------------------
-- Tabel performa depot, persis buildEmailPerfTableHtml()
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.email_tabel_performa(p_rows jsonb, p_judul text)
returns text language plpgsql stable set search_path='' as $fn$
declare
  th   text := 'style="text-align:left;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;"';
  thn  text := 'style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;"';
  td   text := 'style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;"';
  tdn  text := 'style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;"';
  r jsonb; i integer := 0; isi text := ''; warna text;
begin
  if p_rows is null or jsonb_array_length(p_rows) = 0 then
    return '<p style="color:#5f6368;">Tidak ada data.</p>';
  end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    i := i + 1;
    warna := rc_private.warna_persen((r->>'cr')::numeric);
    isi := isi || '<tr>'
      || '<td ' || td || ' width="24">' || i || '.</td>'
      || '<td ' || td || '>' || rc_private.html_aman(r->>'label') || '</td>'
      || '<td ' || tdn || '>' || rc_private.rupiah((r->>'netCb')::numeric) || '</td>'
      || '<td ' || tdn || '>' || rc_private.angka((r->>'qty')::numeric) || '</td>'
      || '<td ' || tdn || '>' || rc_private.rupiah((r->>'osVal')::numeric) || '</td>'
      || '<td ' || tdn || '>' || rc_private.angka((r->>'osQty')::numeric) || '</td>'
      || '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;'
      || 'white-space:nowrap;background-color:' || warna || ';color:#ffffff;font-weight:bold;" bgcolor="'
      || warna || '">' || rc_private.persen((r->>'cr')::numeric) || '</td></tr>';
  end loop;
  return '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
    || '<thead><tr><th ' || th || ' width="24">#</th><th ' || th || '>' || rc_private.html_aman(p_judul) || '</th>'
    || '<th ' || thn || '>Net CB</th><th ' || thn || '>Claim Qty</th>'
    || '<th ' || thn || '>Outstanding</th><th ' || thn || '>Outstanding Qty</th>'
    || '<th ' || thn || '>Clearing Rate</th></tr></thead><tbody>' || isi || '</tbody></table>';
end $fn$;
revoke all on function rc_private.email_tabel_performa(jsonb,text) from public,anon;

create or replace function rc_private.html_aman(t text)
returns text language sql immutable set search_path='' as $fn$
  select replace(replace(replace(replace(coalesce(t,''),
    '&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;');
$fn$;
revoke all on function rc_private.html_aman(text) from public,anon;

-- ------------------------------------------------------------------------------------------
-- Penyusun isi
-- ------------------------------------------------------------------------------------------
-- p_test_email: bila diisi, email HANYA dikirim ke alamat itu dan pemetaan penerima depot
-- tidak dipakai sama sekali - sama seperti normalizeTestRecipient() pada DailyEmail.gs.
drop function if exists public.rc_email_susun(text,boolean);

create or replace function public.rc_email_susun(
  p_jenis text, p_kirim boolean default false, p_test_email text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_jenis text; v_set public.email_settings; v_html text; v_subjek text; v_uji text;
  v_depot text[]; v_penerima jsonb; v_id uuid; v_baris integer := 0;
  v_kpi jsonb; v_top jsonb; v_status text; v_region text;
begin
  if not rc_private.is_manager() then
    raise exception 'Hanya Supervisor atau System Manager yang dapat menyusun email'
      using errcode='42501'; end if;
  v_jenis := lower(btrim(coalesce(p_jenis,'')));
  select * into v_set from public.email_settings where jenis = v_jenis;
  if not found then raise exception 'Jenis email "%" tidak dikenali', p_jenis; end if;

  -- Alamat uji hanya diterima bila benar-benar berbentuk alamat email. Sistem lama pernah
  -- mengirim ke "[object Object]" karena argumen trigger ikut dianggap alamat.
  v_uji := btrim(coalesce(p_test_email,''));
  if v_uji <> '' and v_uji !~ '^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$' then
    raise exception 'Alamat uji "%" bukan alamat email yang sah', v_uji;
  end if;

  -- Ringkasan menyeluruh, dipakai kedua jenis email.
  select jsonb_build_object(
    'netCb',coalesce(sum(cb_net),0),
    'netClaimed',coalesce(sum(cb_net) filter (where status='done'),0),
    'osVal',coalesce(sum(cb_net) filter (where outstanding),0),
    'osQty',count(*) filter (where outstanding),
    'cr',case when coalesce(sum(cb_net),0)=0 then 0
         else coalesce(sum(cb_net) filter (where status in('done','expired')),0)/sum(cb_net) end)
    into v_kpi from public.rc_report_rows;

  if v_jenis = 'daily' then
    with r as (
      select d.depot_code, d.depot_name,
             coalesce(sum(c.cb_net),0) net_cb, count(*) qty,
             coalesce(sum(c.cb_net) filter (where c.outstanding),0) os_val,
             count(*) filter (where c.outstanding) os_qty,
             case when coalesce(sum(c.cb_net),0)=0 then 0
                  else coalesce(sum(c.cb_net) filter (where c.status in('done','expired')),0)/sum(c.cb_net) end cr
        from public.rc_report_rows c join public.depots d on d.id=c.depot_id
       group by d.depot_code, d.depot_name
      having coalesce(sum(c.cb_net),0) > 0
         and coalesce(sum(c.cb_net) filter (where c.outstanding),0) > 0
    ), top5 as (select * from r order by cr, os_val desc limit 5)
    select array_agg(depot_code),
           jsonb_agg(jsonb_build_object('label',depot_code||' - '||depot_name,
             'netCb',net_cb,'qty',qty,'osVal',os_val,'osQty',os_qty,'cr',cr)
             order by cr, os_val desc),
           count(*)
      into v_depot, v_top, v_baris from top5;

    if v_baris = 0 then
      insert into public.email_outbox(jenis,tujuan,subjek,isi_html,status,konteks)
      values(v_jenis,'{}','(tidak dikirim)','',
        'skipped',jsonb_build_object('sebab','Tidak ada depot dengan outstanding'))
      returning id into v_id;
      return jsonb_build_object('status','success','dikirim',false,'id',v_id,
        'message','Tidak ada depot dengan outstanding; email tidak disusun.');
    end if;

    v_subjek := 'Outstanding Claim Report - ' || rc_private.tgl_panjang(now());
    v_html :=
      '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
      ||'<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:720px;"><tr><td>'
      ||'<p>Dear All,</p>'
      ||'<p style="line-height:1.6;">Berikut kami sampaikan <strong>Outstanding Claim Summary per '
        ||rc_private.tgl_panjang(now())||'</strong>.</p>'
      ||'<p style="line-height:1.6;">Saat ini terdapat <strong>'||rc_private.angka((v_kpi->>'osQty')::numeric)
        ||' klaim</strong> yang masih outstanding dengan total nilai sebesar <strong>'
        ||rc_private.rupiah((v_kpi->>'osVal')::numeric)||'</strong>, dengan <strong>overall Clearing Rate sebesar '
        ||rc_private.persen((v_kpi->>'cr')::numeric)||'</strong>.</p>'
      ||'<h3 style="font-size:15px;margin:22px 0 8px;">Top 5 Depot dengan Clearing Rate Terendah</h3>'
      ||rc_private.email_tabel_performa(v_top,'Depot')
      ||'<p style="line-height:1.6;margin-top:22px;">Kami mohon perhatian dan dukungan dari masing-masing '
        ||'<strong>Depot dan Management</strong> untuk dapat segera melakukan <strong>follow-up dan percepatan '
        ||'penyelesaian Outstanding Claim</strong>, khususnya pada Depot dengan Clearing Rate yang masih rendah.</p>'
      ||'<p style="line-height:1.6;">Thank you for your attention and cooperation.</p>'
      ||rc_private.email_ttd()
      ||'</td></tr></table></div>';
    v_penerima := rc_private.penerima_depot(v_depot);

  elsif v_jenis = 'weekly' then
    select array_agg(depot_code) into v_depot from public.depots
     where coalesce(btrim(email_to),'') <> '' or coalesce(btrim(email_cc),'') <> '';
    v_penerima := rc_private.penerima_depot(coalesce(v_depot,'{}'));

    with r as (
      select d.depot_code, d.depot_name,
             coalesce(sum(c.cb_net),0) net_cb, count(*) qty,
             coalesce(sum(c.cb_net) filter (where c.outstanding),0) os_val,
             count(*) filter (where c.outstanding) os_qty,
             case when coalesce(sum(c.cb_net),0)=0 then 0
                  else coalesce(sum(c.cb_net) filter (where c.status in('done','expired')),0)/sum(c.cb_net) end cr
        from public.rc_report_rows c join public.depots d on d.id=c.depot_id
       group by d.depot_code, d.depot_name
      having coalesce(sum(c.cb_net),0) > 0)
    select jsonb_agg(jsonb_build_object('label',depot_code||' - '||depot_name,
             'netCb',net_cb,'qty',qty,'osVal',os_val,'osQty',os_qty,'cr',cr) order by cr, os_val desc)
      into v_top from (select * from r order by cr, os_val desc limit 10) t;

    -- Distribusi status, pengelompokan persis WEEKLY_STATUS_GROUPS.
    select string_agg(
      '<tr><td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;">'
      ||'<span style="display:inline-block;width:10px;height:10px;background:'||g.warna||';margin-right:6px;"></span>'
      ||g.label||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'
      ||rc_private.angka(g.qty)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'
      ||'<strong>'||rc_private.persen(g.pct)||'</strong></td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'
      ||rc_private.rupiah(g.nilai)||'</td></tr>', '' order by g.urut)
      into v_status
    from (
      select x.urut, x.label, x.warna,
             count(c.id) qty, coalesce(sum(c.cb_net),0) nilai,
             case when (select count(*) from public.rc_report_rows)=0 then 0
                  else count(c.id)::numeric/(select count(*) from public.rc_report_rows) end pct
      from (values
        (1,'Done','#34A853',array['done']),
        (2,'Expired','#7B1E1E',array['expired']),
        (3,'Pending Depot','#EA4335',array['not_yet']),
        (4,'Pending OSC','#FF9900',array['submitted','released']),
        (5,'Pending Finance','#4285F4',array['claimed']),
        (6,'Lainnya','#9AA0A6',array[]::text[])
      ) as x(urut,label,warna,status_list)
      left join public.rc_report_rows c on
        case when x.urut = 6
             then c.status <> all(array['done','expired','not_yet','submitted','released','claimed'])
             else c.status = any(x.status_list) end
      group by x.urut, x.label, x.warna) g;

    -- Value dan outstanding per Region, urut dari outstanding terbesar.
    select string_agg(
      '<tr><td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;">Region '
      ||rc_private.html_aman(q.region)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'||rc_private.rupiah(q.net_cb)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'||rc_private.rupiah(q.done_val)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'||rc_private.rupiah(q.os_val)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;">'||rc_private.angka(q.os_qty)||'</td>'
      ||'<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;background-color:'
      ||rc_private.warna_persen(q.cr)||';color:#ffffff;font-weight:bold;" bgcolor="'||rc_private.warna_persen(q.cr)||'">'
      ||rc_private.persen(q.cr)||'</td></tr>', '' order by q.os_val desc)
      into v_region
    from (
      select coalesce(nullif(btrim(region),''),'(tanpa region)') region,
             coalesce(sum(cb_net),0) net_cb,
             coalesce(sum(cb_net) filter (where status='done'),0) done_val,
             coalesce(sum(cb_net) filter (where outstanding),0) os_val,
             count(*) filter (where outstanding) os_qty,
             case when coalesce(sum(cb_net),0)=0 then 0
                  else coalesce(sum(cb_net) filter (where status in('done','expired')),0)/sum(cb_net) end cr
        from public.rc_report_rows group by 1
       having coalesce(sum(cb_net),0) > 0) q;

    v_subjek := 'Weekly Outstanding Claim Summary - ' || rc_private.tgl_panjang(now());
    v_html :=
      '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
      ||'<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:760px;"><tr><td>'
      ||'<p>Dear All,</p>'
      ||'<p style="line-height:1.6;">Berikut kami sampaikan <strong>Weekly Outstanding Claim Summary</strong> '
        ||'untuk periode <strong>'||rc_private.tgl_panjang(now() - interval '6 days')||' s/d '
        ||rc_private.tgl_panjang(now())||'</strong>.</p>'
      ||'<p style="line-height:1.6;">Summary ini memberikan overview terkait performa clearing claim, '
        ||'trend claim, distribusi status claim, serta outstanding value berdasarkan Region.</p>'
      -- Kartu KPI (buildWeeklyKpiCardsHtml)
      ||'<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin:18px 0 6px;"><tr>'
      ||'<td width="25%" style="padding:10px 12px;border:1px solid #e0e2e6;vertical-align:top;">'
        ||'<div style="font-size:10px;color:#5f6368;text-transform:uppercase;letter-spacing:.03em;">Total Net CB</div>'
        ||'<div style="font-size:16px;font-weight:bold;color:#202124;margin-top:4px;">'||rc_private.rupiah_ringkas((v_kpi->>'netCb')::numeric)||'</div></td>'
      ||'<td width="25%" style="padding:10px 12px;border:1px solid #e0e2e6;vertical-align:top;">'
        ||'<div style="font-size:10px;color:#5f6368;text-transform:uppercase;letter-spacing:.03em;">Net Claimed (Done)</div>'
        ||'<div style="font-size:16px;font-weight:bold;color:#34A853;margin-top:4px;">'||rc_private.rupiah_ringkas((v_kpi->>'netClaimed')::numeric)||'</div></td>'
      ||'<td width="25%" style="padding:10px 12px;border:1px solid #e0e2e6;vertical-align:top;">'
        ||'<div style="font-size:10px;color:#5f6368;text-transform:uppercase;letter-spacing:.03em;">Outstanding</div>'
        ||'<div style="font-size:16px;font-weight:bold;color:#EA4335;margin-top:4px;">'
        ||rc_private.rupiah_ringkas((v_kpi->>'osVal')::numeric)||' / '||rc_private.angka((v_kpi->>'osQty')::numeric)||' klaim</div></td>'
      ||'<td width="25%" style="padding:10px 12px;border:1px solid #e0e2e6;vertical-align:top;">'
        ||'<div style="font-size:10px;color:#5f6368;text-transform:uppercase;letter-spacing:.03em;">Clearing Rate</div>'
        ||'<div style="font-size:16px;font-weight:bold;color:#1a7f37;margin-top:4px;">'||rc_private.persen((v_kpi->>'cr')::numeric)||'</div></td>'
      ||'</tr></table>'
      ||'<h3 style="font-size:15px;margin:26px 0 8px;border-left:4px solid #4285F4;padding-left:8px;">Top 10 Depot dengan Clearing Rate Terendah</h3>'
      ||rc_private.email_tabel_performa(coalesce(v_top,'[]'::jsonb),'Depot')
      ||'<h3 style="font-size:15px;margin:26px 0 8px;border-left:4px solid #4285F4;padding-left:8px;">Distribusi Status Claim</h3>'
      ||'<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
        ||'<thead><tr>'
        ||'<th style="text-align:left;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Status</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Qty</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">%</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Value (Net CB)</th>'
        ||'</tr></thead><tbody>'||coalesce(v_status,'')||'</tbody></table>'
      ||'<p style="font-size:11px;color:#5f6368;margin:6px 0 0;">Pending Depot = menunggu Depot compile ke OSC '
        ||'(status mentah "Not Yet"). Pending OSC = menunggu penyelesaian OSC (Submitted &amp; Released). '
        ||'Pending Finance = menunggu penyelesaian Finance (Claimed). Lainnya = status belum terpetakan.</p>'
      ||'<h3 style="font-size:15px;margin:26px 0 8px;border-left:4px solid #4285F4;padding-left:8px;">Value Claim &amp; Outstanding by Region</h3>'
      ||case when coalesce(v_region,'') = '' then '<p style="color:#5f6368;">Tidak ada data Region.</p>'
        else '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
        ||'<thead><tr>'
        ||'<th style="text-align:left;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;">Region</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Net CB</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Claim Value (Done)</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Outstanding</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Outstanding Qty</th>'
        ||'<th style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;">Clearing Rate</th>'
        ||'</tr></thead><tbody>'||v_region||'</tbody></table>' end
      ||'<p style="line-height:1.6;">Thank you for your attention and cooperation.</p>'
      ||rc_private.email_ttd()
      ||'</td></tr></table></div>';

  elsif v_jenis = 'timetable' then
    select array_agg(depot_code) into v_depot from public.depots
     where coalesce(btrim(email_to),'') <> '' or coalesce(btrim(email_cc),'') <> '';
    v_penerima := rc_private.penerima_depot(coalesce(v_depot,'{}'));
    v_subjek := v_set.subjek || ' - ' || rc_private.tgl_panjang(now());
    v_html :=
      '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
      ||'<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:720px;"><tr><td>'
      ||'<p>Dear All,</p>'
      ||'<p style="line-height:1.6;">Berikut ringkasan <strong>Timetable Compile</strong> per '
        ||rc_private.tgl_panjang(now())||'.</p>'
      ||'<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:14px 0;">'
      ||'<tr><td style="font-size:13px;padding:6px 16px 6px 0;">Campaign aktif</td>'
        ||'<td style="font-size:13px;padding:6px 0;font-weight:bold;">'
        ||(select count(*) from public.campaigns
            where period_start is not null and period_start<=current_date
              and coalesce(period_end,current_date)>=current_date
              and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=campaigns.id))||'</td></tr>'
      ||'<tr><td style="font-size:13px;padding:6px 16px 6px 0;">Depot dipantau</td>'
        ||'<td style="font-size:13px;padding:6px 0;font-weight:bold;">'
        ||(select count(*) from public.depots)||'</td></tr>'
      ||'<tr><td style="font-size:13px;padding:6px 16px 6px 0;">Pasangan ditandai Not Achieved</td>'
        ||'<td style="font-size:13px;padding:6px 0;font-weight:bold;color:#EA4335;">'
        ||(select count(*) from public.timetable_not_achieved)||'</td></tr></table>'
      ||'<p style="line-height:1.6;">Buka modul Timetable pada aplikasi RC untuk matrix lengkapnya.</p>'
      ||'<p style="line-height:1.6;">Thank you for your attention and cooperation.</p>'
      ||rc_private.email_ttd()
      ||'</td></tr></table></div>';
  else
    raise exception 'Jenis email "%" tidak dikenali', p_jenis;
  end if;

  -- Pengujian mengabaikan pemetaan penerima sepenuhnya.
  if v_uji <> '' then
    v_penerima := jsonb_build_object('to', jsonb_build_array(v_uji), 'cc', '[]'::jsonb);
    v_subjek := '[UJI] ' || v_subjek;
  end if;

  if coalesce(jsonb_array_length(v_penerima->'to'),0) = 0 then
    insert into public.email_outbox(jenis,tujuan,subjek,isi_html,status,galat,konteks)
    values(v_jenis,'{}',v_subjek,v_html,'skipped',
      'Belum ada alamat TO pada master depot',jsonb_build_object('depot',to_jsonb(v_depot)))
    returning id into v_id;
    return jsonb_build_object('status','success','dikirim',false,'id',v_id,
      'subjek',v_subjek,'isiHtml',v_html,
      'message','Isi email tersusun, tetapi belum ada satu pun alamat TO di Key Master > Depot Master.');
  end if;

  insert into public.email_outbox(jenis,tujuan,cc,subjek,isi_html,status,konteks)
  values(v_jenis,
    array(select jsonb_array_elements_text(v_penerima->'to')),
    array(select jsonb_array_elements_text(v_penerima->'cc')),
    v_subjek, v_html,
    case when coalesce(p_kirim,false) then 'pending' else 'skipped' end,
    jsonb_build_object('depot',to_jsonb(v_depot),'preview',not coalesce(p_kirim,false),
                       'uji',v_uji <> ''))
  returning id into v_id;

  return jsonb_build_object('status','success','id',v_id,
    'dikirim',coalesce(p_kirim,false),
    'penerima',v_penerima,
    'subjek',v_subjek,
    'isiHtml',v_html,
    'message',case when coalesce(p_kirim,false)
      then case when v_uji <> '' then 'Email uji dimasukkan ke antrean untuk ' || v_uji || '.'
                else 'Email dimasukkan ke antrean pengiriman.' end
      else 'Pratinjau tersusun. Tidak ada yang dikirim.' end);
end $fn$;
revoke all on function public.rc_email_susun(text,boolean,text) from public,anon;
grant execute on function public.rc_email_susun(text,boolean,text) to authenticated;

create or replace function rc_private.marker_20261031() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261031() from public,anon;
grant execute on function rc_private.marker_20261031() to authenticated;

select 'Isi email disamakan dengan DailyEmail.gs dan WeeklyEmail.gs' as hasil,
 (select count(*) from public.depots where coalesce(btrim(email_to),'') <> '') as depot_punya_to;
