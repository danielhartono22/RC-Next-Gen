-- ==========================================================================================
-- Email Not Achieved: Summary per Campaign ditampilkan lebih dulu, baru Detail. Pemilik,
-- 22 Oktober 2026: "untuk email not achievement buat summary per campaign dulu bisa?"
-- Berlaku untuk badan email dan lampiran PDF. Isi, kolom, dan kalimat tidak berubah; hanya
-- urutannya (Summary per Campaign -> Detail), dan tabel detail diberi judul "Detail".
-- Bergantung pada 20261163370000.
-- ==========================================================================================

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
    -- 20261163410000: Summary per Campaign lebih dulu.
    || '<h2 style="font-size:14px;">Summary per Campaign</h2>'
    || '<table border="1" cellspacing="0" cellpadding="4" style="border-collapse:collapse;font-size:10px;">'
    || '<tr><th align="left">Kode Campaign</th><th align="left">Nama Campaign</th><th align="right">Jumlah Depot Tidak Mencapai</th></tr>'
    || coalesce(v_sum, '')
    || '<tr><td colspan="2"><b>Total ' || jsonb_array_length(v_ringkas)::text || ' campaign</b></td><td align="right"><b>' || v_n::text || '</b></td></tr>'
    || '</table>'
    || '<h2 style="font-size:14px;">Detail</h2>'
    || '<table border="1" cellspacing="0" cellpadding="4" style="border-collapse:collapse;font-size:9px;">'
    || '<tr><th align="left">Region</th><th align="left">Nama Depot</th><th align="left">Kode Campaign</th><th align="left">Nama Campaign</th>'
    || '<th align="left">Periode Start</th><th align="left">Periode End</th><th align="left">Process By</th><th align="left">Timestamp</th></tr>'
    || coalesce(v_detail, '') || '</table>'
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
    || '<p style="line-height:1.6;">Berikut daftar campaign yang sudah dikonfirmasi gagal mencapai target sesuai memo campaign '
    || 'yang ditetapkan, sehingga tidak ada toko yang mencapai cashback atas campaign tersebut.</p>'
    || '<p style="line-height:1.6;background:#fdecef;border-left:4px solid #C8102E;padding:10px 12px;margin:12px 0;font-size:13px;color:#8a0d20;">'
    || '<strong>PERHATIAN:</strong> ' || v_n::text || ' campaign di ' || v_dep::text || ' depot (' || v_reg::text || ' region) ditandai Not Achieved. '
    || 'Mohon OSC konfirmasi ke admin terkait mengenai tindakan ini, karena tindakan ini akan membuat campaign tersebut '
    || '<strong>tidak bisa diajukan kembali oleh tim depo</strong>.</p>'
    -- 20261163410000: Summary per Campaign lebih dulu, baru Detail.
    || '<p style="line-height:1.6;margin:18px 0 6px;font-weight:bold;">Summary per Campaign</p>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
    || '<thead><tr style="background:#f5f6f7;">'
    || '<th align="left" style="' || v_th || '">KODE CAMPAIGN</th><th align="left" style="' || v_th || '">NAMA CAMPAIGN</th>'
    || '<th align="right" style="' || v_th || '">JUMLAH DEPOT TIDAK MENCAPAI</th>'
    || '</tr></thead><tbody>' || coalesce(v_sum, '') || '</tbody>'
    || '<tfoot><tr style="background:#fdecef;"><td colspan="2" style="padding:8px 10px;font-size:12px;font-weight:bold;color:#C8102E;">TOTAL '
    || jsonb_array_length(v_ringkas)::text || ' CAMPAIGN</td>'
    || '<td style="padding:8px 10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;">' || v_n::text || '</td></tr></tfoot></table>'
    || '<p style="line-height:1.6;margin:22px 0 6px;font-weight:bold;">Detail</p>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
    || '<thead><tr style="background:#f5f6f7;">'
    || '<th align="left" style="' || v_th || '">REGION</th>'
    || '<th align="left" style="' || v_th || '">NAMA DEPOT</th><th align="left" style="' || v_th || '">NAMA CAMPAIGN</th>'
    || '<th align="left" style="' || v_th || '">PERIODE START</th><th align="left" style="' || v_th || '">PERIODE END</th>'
    || '<th align="left" style="' || v_th || '">PROCESS BY</th><th align="left" style="' || v_th || '">TIMESTAMP</th>'
    || '</tr></thead><tbody>' || coalesce(v_baris, '') || '</tbody></table>'
    || '<p style="line-height:1.6;margin-top:10px;font-size:12px;color:#5f6368;">Summary dan detail di atas juga terlampir dalam PDF.</p>'
    || '<p style="line-height:1.6;margin-top:16px;font-weight:bold;">Mohon perhatian kepada All RSM dan Depot Head agar menjadi bahan evaluasi ke depannya.</p>'
    || rc_private.email_ttd()
    || '</td></tr></table>';
end $f$;

revoke all on function rc_private.email_na_html(jsonb, timestamptz, timestamptz), rc_private.email_na_pdf_html(jsonb, timestamptz, timestamptz)
  from public, anon, authenticated;
