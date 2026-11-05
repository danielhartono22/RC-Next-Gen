-- ==========================================================================================
-- Email Otomatis: CC tambahan per jadwal, dan teks email Not Achieved. Pemilik, 22 Oktober 2026:
--   "saya mau semua di tab email otomatis ada cc nya tapi di email otomatisnya untuk tambahan cc
--    bukan di tab email pengajuan"
-- ==========================================================================================
-- * Setiap jadwal di Email Otomatis (daily, weekly, timetable, kesehatan, notachieved) punya CC
--   tambahan sendiri (email_settings.cc_tambahan), diisi di panel Email Otomatis. Kesehatan tetap
--   punya To sendiri; jadwal lain To-nya dari Depot Master.
-- * Daily / Weekly / Timetable: CC = Email CC Depot Master + CC tambahan jadwal itu.
-- * Not Achieved: CC = Email CC Depot Master + CC tambahan jadwal Not Achieved. Kotak CC di tab
--   Email Pengajuan dan "CC semua email" Email Pengajuan tidak lagi dipakai untuk email ini; isi
--   kotak lama (bila ada) dipindahkan ke CC tambahan jadwal Not Achieved.
-- * Teks Not Achieved: kalimat pembuka dan penutup diganti sesuai pemilik. Di bawah tabel detail
--   ada Summary per Campaign (Kode Campaign, Nama Campaign, Jumlah Depot yang tidak mencapai),
--   dan email dilampiri PDF berisi detail + summary yang sama ("dan buat pdf nya"). Isi PDF
--   disusun bersama emailnya (email_outbox.konteks.pdfHtml) lalu dijadikan PDF saat dikirim,
--   lewat jalur PDF yang sama dengan email Daily (Google Drive).
-- Alamat yang sudah di TO tidak diulang di CC. Maksimal 30 alamat CC tambahan per jadwal.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- 1. Pembaca daftar CC tambahan --------------------------------------------------------------
create or replace function rc_private.email_cc_tambahan(p jsonb) returns text[]
language plpgsql immutable set search_path = '' as $f$
declare v text[] := '{}'; x text;
begin
  if p is null or jsonb_typeof(p) = 'null' then return '{}'; end if;
  for x in
    select lower(btrim(t))
      from regexp_split_to_table(
             case jsonb_typeof(p) when 'array' then (select string_agg(value #>> '{}', ',') from jsonb_array_elements(p))
                                  else p #>> '{}' end, '[,;\s]+') t
     where btrim(t) <> ''
  loop
    if x !~ '^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$' then raise exception 'Alamat email CC tidak sah: %', x; end if;
    if not (x = any(v)) then v := v || x; end if;
  end loop;
  if cardinality(v) > 30 then raise exception 'CC tambahan maksimal 30 alamat (diterima %)', cardinality(v); end if;
  return v;
end $f$;
revoke all on function rc_private.email_cc_tambahan(jsonb) from public, anon, authenticated;

-- ---- 2. Data: CC Not Achieved lama dari tab Email Pengajuan ----------------------------------
update public.email_settings n
   set cc_tambahan = array(select distinct lower(btrim(x)) from unnest(coalesce(n.cc_tambahan, '{}') ||
                             array(select jsonb_array_elements_text(p.cc_per_jenis->'notachieved'))) x where btrim(x) like '%@%')
  from public.email_settings p
 where n.jenis = 'notachieved' and p.jenis = 'pengajuan' and p.cc_per_jenis ? 'notachieved';
update public.email_settings set cc_per_jenis = cc_per_jenis - 'notachieved'
 where jenis = 'pengajuan' and cc_per_jenis ? 'notachieved';

-- ---- 3. Penerima dan teks Not Achieved -----------------------------------------------------------
create or replace function rc_private.email_na_penerima(p_depot uuid[]) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_to text[]; v_cc text[];
begin
  select coalesce(array_agg(distinct x order by x), '{}') into v_to
    from public.depots d, unnest(rc_private.pecah_email(d.email_to)) x
   where d.id = any(p_depot);

  -- 20261163370000: CC = Email CC Depot Master + CC tambahan jadwal Not Achieved (Email Otomatis).
  select coalesce(array_agg(distinct a order by a) filter (where a ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
                                                             and not (a = any(v_to))), '{}') into v_cc from (
    select x a from public.depots d, unnest(rc_private.pecah_email(d.email_cc)) x where d.id = any(p_depot)
    union all
    select lower(btrim(y)) from public.email_settings s, unnest(coalesce(s.cc_tambahan, '{}')) y where s.jenis = 'notachieved'
  ) s;

  return jsonb_build_object('to', to_jsonb(v_to), 'cc', to_jsonb(v_cc));
end $f$;

-- Summary per Campaign: jumlah depot yang tidak mencapai, urut terbanyak.
create or replace function rc_private.email_na_ringkas(p_rows jsonb) returns jsonb
language sql immutable set search_path = '' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('kodeCampaign', k, 'namaCampaign', n, 'jumlahDepot', j) order by j desc, k), '[]')
    from (select x->>'kodeCampaign' k, max(x->>'namaCampaign') n, count(distinct x->>'kodeDepot') j
            from jsonb_array_elements(coalesce(p_rows, '[]')) x group by 1) y;
$f$;

-- Isi PDF lampiran: judul, detail, dan Summary per Campaign (tabel sederhana untuk Google Docs).
create or replace function rc_private.email_na_pdf_html(p_rows jsonb, p_dari timestamptz, p_sampai timestamptz) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare v_detail text; v_sum text; v_ringkas jsonb := rc_private.email_na_ringkas(p_rows);
  v_n integer := jsonb_array_length(coalesce(p_rows, '[]'));
begin
  select string_agg('<tr><td>' || rc_private.html_aman(x->>'region') || '</td><td>' || rc_private.html_aman((x->>'kodeDepot') || ' - ' || (x->>'namaDepot'))
      || '</td><td>' || rc_private.html_aman(x->>'kodeCampaign') || '</td><td>' || rc_private.html_aman(x->>'namaCampaign')
      || '</td><td>' || rc_private.html_aman(x->>'mulai') || '</td><td>' || rc_private.html_aman(x->>'akhir')
      || '</td><td>' || rc_private.html_aman(x->>'oleh') || '</td><td>' || rc_private.html_aman(x->>'waktu') || '</td></tr>', '' order by i)
    into v_detail from jsonb_array_elements(p_rows) with ordinality q(x, i);
  select string_agg('<tr><td>' || rc_private.html_aman(x->>'kodeCampaign') || '</td><td>' || rc_private.html_aman(x->>'namaCampaign')
      || '</td><td align="right">' || (x->>'jumlahDepot') || '</td></tr>', '' order by i)
    into v_sum from jsonb_array_elements(v_ringkas) with ordinality q(x, i);
  return '<html><head><meta charset="UTF-8"></head><body style="font-family:Arial,sans-serif;">'
    || '<h1 style="font-size:18px;">Not Achieved Campaign Report</h1>'
    || '<p style="font-size:11px;color:#555;">' || rc_private.tgl_panjang(now()) || ' &middot; tanda Not Achieved '
    || to_char(p_dari at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ' s/d '
    || to_char(p_sampai at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ' WIB &middot; ' || v_n::text || ' campaign-depot, '
    || jsonb_array_length(v_ringkas)::text || ' campaign</p>'
    || '<p style="font-size:11px;">Berikut daftar campaign yang sudah dikonfirmasi gagal mencapai target sesuai memo campaign yang ditetapkan, '
    || 'sehingga tidak ada toko yang mencapai cashback atas campaign tersebut.</p>'
    || '<h2 style="font-size:14px;">Detail</h2>'
    || '<table border="1" cellspacing="0" cellpadding="4" style="border-collapse:collapse;font-size:9px;">'
    || '<tr><th align="left">Region</th><th align="left">Nama Depot</th><th align="left">Kode Campaign</th><th align="left">Nama Campaign</th>'
    || '<th align="left">Periode Start</th><th align="left">Periode End</th><th align="left">Process By</th><th align="left">Timestamp</th></tr>'
    || coalesce(v_detail, '') || '</table>'
    || '<h2 style="font-size:14px;">Summary per Campaign</h2>'
    || '<table border="1" cellspacing="0" cellpadding="4" style="border-collapse:collapse;font-size:10px;">'
    || '<tr><th align="left">Kode Campaign</th><th align="left">Nama Campaign</th><th align="right">Jumlah Depot Tidak Mencapai</th></tr>'
    || coalesce(v_sum, '')
    || '<tr><td colspan="2"><b>Total ' || jsonb_array_length(v_ringkas)::text || ' campaign</b></td><td align="right"><b>' || v_n::text || '</b></td></tr>'
    || '</table>'
    || '<p style="font-size:11px;"><b>Mohon perhatian kepada All RSM dan Depot Head agar menjadi bahan evaluasi ke depannya.</b></p>'
    || '<p style="font-size:9px;color:#777;">Dibuat otomatis oleh RC (Resource Collection).</p></body></html>';
end $f$;

create or replace function rc_private.email_na_html(p_rows jsonb, p_dari timestamptz, p_sampai timestamptz) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
  v_n integer := jsonb_array_length(coalesce(p_rows, '[]')); v_dep integer; v_reg integer; v_baris text; v_ringkas jsonb; v_sum text;
begin
  select count(distinct x->>'kodeDepot'), count(distinct x->>'region') into v_dep, v_reg from jsonb_array_elements(p_rows) x;
  v_ringkas := rc_private.email_na_ringkas(p_rows);
  select string_agg('<tr>'
      || '<td style="' || v_td || 'white-space:nowrap;font-weight:bold;">' || rc_private.html_aman(x->>'region') || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman((x->>'kodeDepot') || ' - ' || (x->>'namaDepot')) || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'namaCampaign')
         || '<br><span style="font-size:11px;color:#5f6368;font-family:Consolas,monospace;">' || rc_private.html_aman(x->>'kodeCampaign') || '</span></td>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(x->>'mulai') || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(x->>'akhir') || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'oleh') || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(x->>'waktu') || '</td>'
      || '</tr>', '' order by i)
    into v_baris from jsonb_array_elements(p_rows) with ordinality q(x, i);
  select string_agg('<tr>'
      || '<td style="' || v_td || 'white-space:nowrap;font-family:Consolas,monospace;">' || rc_private.html_aman(x->>'kodeCampaign') || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'namaCampaign') || '</td>'
      || '<td style="' || v_td || 'text-align:right;font-weight:bold;">' || (x->>'jumlahDepot') || '</td>'
      || '</tr>', '' order by i)
    into v_sum from jsonb_array_elements(v_ringkas) with ordinality q(x, i);

  return rc_private.email_kepala('Not Achieved Campaign Report',
           v_n::text || ' campaign  |  ' || v_dep::text || ' depot  |  ' || v_reg::text || ' region  |  ' || rc_private.tgl_panjang(now()))
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
    || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;">'
    || '<p style="line-height:1.6;margin-top:0;">Dear All,</p>'
    -- 20261163370000: kalimat pembuka dari pemilik.
    || '<p style="line-height:1.6;">Berikut daftar campaign yang sudah dikonfirmasi gagal mencapai target sesuai memo campaign '
    || 'yang ditetapkan, sehingga tidak ada toko yang mencapai cashback atas campaign tersebut.</p>'
    || '<p style="line-height:1.6;background:#fdecef;border-left:4px solid #C8102E;padding:10px 12px;margin:12px 0;font-size:13px;color:#8a0d20;">'
    || '<strong>PERHATIAN:</strong> ' || v_n::text || ' campaign di ' || v_dep::text || ' depot (' || v_reg::text || ' region) ditandai Not Achieved. '
    || 'Mohon OSC konfirmasi ke admin terkait mengenai tindakan ini, karena tindakan ini akan membuat campaign tersebut '
    || '<strong>tidak bisa diajukan kembali oleh tim depo</strong>.</p>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin-top:12px;">'
    || '<thead><tr style="background:#f5f6f7;">'
    || '<th align="left" style="' || v_th || '">REGION</th>'
    || '<th align="left" style="' || v_th || '">NAMA DEPOT</th><th align="left" style="' || v_th || '">NAMA CAMPAIGN</th>'
    || '<th align="left" style="' || v_th || '">PERIODE START</th><th align="left" style="' || v_th || '">PERIODE END</th>'
    || '<th align="left" style="' || v_th || '">PROCESS BY</th><th align="left" style="' || v_th || '">TIMESTAMP</th>'
    || '</tr></thead><tbody>' || coalesce(v_baris, '') || '</tbody></table>'
    -- 20261163370000: Summary per Campaign.
    || '<p style="line-height:1.6;margin:22px 0 6px;font-weight:bold;">Summary per Campaign</p>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
    || '<thead><tr style="background:#f5f6f7;">'
    || '<th align="left" style="' || v_th || '">KODE CAMPAIGN</th><th align="left" style="' || v_th || '">NAMA CAMPAIGN</th>'
    || '<th align="right" style="' || v_th || '">JUMLAH DEPOT TIDAK MENCAPAI</th>'
    || '</tr></thead><tbody>' || coalesce(v_sum, '') || '</tbody>'
    || '<tfoot><tr style="background:#fdecef;"><td colspan="2" style="padding:8px 10px;font-size:12px;font-weight:bold;color:#C8102E;">TOTAL '
    || jsonb_array_length(v_ringkas)::text || ' CAMPAIGN</td>'
    || '<td style="padding:8px 10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;">' || v_n::text || '</td></tr></tfoot></table>'
    || '<p style="line-height:1.6;margin-top:10px;font-size:12px;color:#5f6368;">Detail dan summary di atas juga terlampir dalam PDF.</p>'
    -- 20261163370000: kalimat penutup dari pemilik.
    || '<p style="line-height:1.6;margin-top:16px;font-weight:bold;">Mohon perhatian kepada All RSM dan Depot Head agar menjadi bahan evaluasi ke depannya.</p>'
    || rc_private.email_ttd()
    || '</td></tr></table>';
end $f$;

revoke all on function rc_private.email_na_penerima(uuid[]), rc_private.email_na_html(jsonb, timestamptz, timestamptz),
  rc_private.email_na_ringkas(jsonb), rc_private.email_na_pdf_html(jsonb, timestamptz, timestamptz)
  from public, anon, authenticated;

-- ---- 4. Tambalan bertanda ---------------------------------------------------------------------
do $tambal$
declare src text;
begin
  -- rc_email_status: CC tambahan dikirim untuk semua jadwal; To sendiri hanya Kesehatan.
  src := replace(pg_get_functiondef('public.rc_email_status()'::regprocedure), E'\r', '');
  if src !~ '20261163370000' then
    src := pg_temp.ganti(src,
      $p$'cc',case when jenis = 'kesehatan' then to_jsonb(cc_tambahan) end /* 20261163230000 */$p$,
      $p$'cc',to_jsonb(coalesce(cc_tambahan,'{}'::text[])) /* 20261163370000: CC tambahan semua jadwal */,'toTetap',jenis = 'kesehatan'$p$,
      1, 'rc_email_status cc');
    execute src;
  end if;

  -- rc_email_settings_simpan: CC tambahan jadwal selain Kesehatan disimpan dari panel Email Otomatis.
  src := replace(pg_get_functiondef('public.rc_email_settings_simpan(jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261163370000' then
    src := pg_temp.ganti(src,
      $p$      where jenis = 'kesehatan';
    end if;
  end loop;$p$,
      $p$      where jenis = 'kesehatan';
    end if;
    -- 20261163370000: CC tambahan jadwal lain (daily, weekly, timetable, notachieved).
    if lower(btrim(r->>'jenis')) not in ('kesehatan', 'pengajuan') and r ? 'cc' then
      update public.email_settings set cc_tambahan = rc_private.email_cc_tambahan(r->'cc')
       where jenis = lower(btrim(r->>'jenis'));
    end if;
  end loop;$p$, 1, 'rc_email_settings_simpan cc');
    execute src;
  end if;

  -- rc_email_susun (daily, weekly, timetable): CC tambahan jadwal ikut di CC; TO tidak diulang.
  src := replace(pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure), E'\r', '');
  if src !~ '20261163370000' then
    src := pg_temp.ganti(src,
      $p$  -- Pengujian mengabaikan pemetaan penerima sepenuhnya.$p$,
      $p$  -- 20261163370000: CC tambahan jadwal ini (panel Email Otomatis) ikut di CC; alamat TO tidak diulang.
  if coalesce(array_length(v_set.cc_tambahan, 1), 0) > 0 then
    v_penerima := jsonb_set(coalesce(v_penerima, '{}'::jsonb), '{cc}', coalesce((
      select jsonb_agg(a order by a) from (
        select jsonb_array_elements_text(coalesce(v_penerima->'cc', '[]'::jsonb)) a
        union select lower(btrim(x)) from unnest(v_set.cc_tambahan) x where btrim(x) like '%@%') s
       where not (coalesce(v_penerima->'to', '[]'::jsonb) ? a)), '[]'::jsonb));
  end if;

  -- Pengujian mengabaikan pemetaan penerima sepenuhnya.$p$, 1, 'rc_email_susun cc');
    execute src;
  end if;

  -- email_na_susun: isi PDF ikut disimpan bersama emailnya; pratinjau menyebut lampirannya.
  src := replace(pg_get_functiondef('rc_private.email_na_susun(public.email_settings,boolean,text)'::regprocedure), E'\r', '');
  if src !~ '20261163370000' then
    src := pg_temp.ganti(src, $p$'jumlah', v_n, 'region', v_isi->'region', 'depot', v_isi->'depot'))$p$,
      $p$'jumlah', v_n, 'region', v_isi->'region', 'depot', v_isi->'depot',
                             'pdfHtml', rc_private.email_na_pdf_html(v_isi->'rows', v_dari, v_sampai) /* 20261163370000 */))$p$, 1, 'email_na_susun pdf');
    src := pg_temp.ganti(src, $p$|| ' &middot; CC: ' || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc, ', '), ''), '-')) || '</div>' || v_html,$p$,
      $p$|| ' &middot; CC: ' || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc, ', '), ''), '-'))
               || ' &middot; Lampiran: Not_Achieved_Campaign_Report (PDF)</div>' || v_html,$p$, 1, 'email_na_susun pratinjau');
    execute src;
  end if;

  -- kirim_satu_email: lampiran PDF Not Achieved dari isi yang disusun bersama emailnya.
  src := replace(pg_get_functiondef('rc_private.kirim_satu_email(uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163370000' then
    src := pg_temp.ganti(src, $p$      if not rc_private.email_perlu_pdf(v.jenis) then
        v_pdf := null;
      else$p$,
      $p$      if v.jenis = 'notachieved' then /* 20261163370000: PDF dari isi yang disusun bersama emailnya */
        v_pdf := null;
        if coalesce(v.konteks->>'pdfHtml', '') <> '' then
          v_nama_pdf := 'Not_Achieved_Campaign_Report_' || to_char(now() at time zone 'Asia/Jakarta','YYYY-MM-DD') || '.pdf';
          v_pdf := rc_private.buat_pdf(v.konteks->>'pdfHtml', replace(v_nama_pdf, '.pdf', ''));
        end if;
      elsif not rc_private.email_perlu_pdf(v.jenis) then
        v_pdf := null;
      else$p$, 1, 'kirim_satu_email pdf notachieved');
    execute src;
  end if;

  -- rc_email_pengajuan_simpan: kotak CC Not Achieved di tab Email Pengajuan dihapus.
  src := replace(pg_get_functiondef('public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text,jsonb)'::regprocedure), E'\r', '');
  if position($p$,'notachieved' /* 20261163360000 */$p$ in src) > 0 then
    src := pg_temp.ganti(src, $p$,'notachieved' /* 20261163360000 */$p$, '', 1, 'pengajuan_simpan tanpa notachieved');
    execute src;
  end if;
end $tambal$;
