-- ==========================================================================================
-- Email Closing Campaign (compile): dikelompokkan per campaign, dikirim seminggu sekali
-- ==========================================================================================
-- Pemilik, 4 November 2026: "Untuk email compile grouping per campaign aja lalu di bawahnya ada
-- depo depot nya dan dibuat seminggu sekali". Hari kirim: Senin (pilihan pemilik), jam 14:00.
--
-- * Setiap campaign menjadi satu blok: judul Kode - Nama Campaign, Periode Campaign dan Jenis
--   Hadiah; di bawahnya tabel bernomor per depot: Kode Depot, Nama Depot, Total CB Net,
--   Process By, lalu total campaign. PDF mengikuti susunan yang sama.
-- * Jadwal bawaan Senin (hari_list {1}) - hanya bila jadwalnya belum pernah diubah di panel
--   (masih tiap hari). Hari dan jam tetap bisa diganti di Email Otomatis.
-- * Jendela: sejak batas email sungguhan terakhir sampai jam kirim. Bila belum pernah ada email
--   sungguhan, mulai 7 hari sebelum batas (dulu 1 hari). Maks 14 hari tetap.
-- Butuh 20261163610000. Aman dijalankan berulang.
-- ==========================================================================================

do $pra$ begin
  if to_regprocedure('rc_private.email_cmp_blok(jsonb,boolean)') is null then
    raise exception 'DITOLAK: jalankan 20261163610000 (email compile) lebih dulu.'; end if;
end $pra$;

update public.email_settings
   set hari_list = '{1}',
       catatan = 'Rangkuman mingguan compile CB di Document Center per campaign, sejak email terakhir sampai jam kirim. TO = Email TO, CC = Email CC (Depot Master) + CC tambahan.'
 where jenis = 'compile' and hari_list is null and diubah_oleh is null;

-- ---- Jendela: bawaan 7 hari ------------------------------------------------------------------
create or replace function rc_private.email_cmp_jendela(p_sekarang timestamptz, p_terjadwal boolean, p_jam integer) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_b timestamptz := rc_private.email_cmp_batas(p_sekarang, p_jam); v_akhir timestamptz; v_dari timestamptz; v_sampai timestamptz;
begin
  select max((o.konteks->>'sampai')::timestamptz) into v_akhir from public.email_outbox o
   where o.jenis = 'compile' and o.status in ('pending', 'sent', 'failed') and o.konteks ? 'sampai'
     and coalesce(o.konteks->>'preview', '') <> 'true' and coalesce(o.konteks->>'uji', '') <> 'true'
     and (o.konteks->>'sampai')::timestamptz <= p_sekarang;
  v_sampai := case when p_terjadwal then v_b else p_sekarang end;
  -- 20261163640000: email mingguan - tanpa email sungguhan sebelumnya, mulai seminggu sebelum batas.
  v_dari := coalesce(v_akhir, v_b - interval '7 days');
  v_dari := least(greatest(v_dari, v_sampai - interval '14 days'), v_sampai);
  return jsonb_build_object('dari', v_dari, 'sampai', v_sampai);
end $f$;

-- ---- Blok per campaign ----------------------------------------------------------------------
create or replace function rc_private.email_cmp_blok(p_isi jsonb, p_pdf boolean) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare
  v_th text := case when p_pdf then '' else 'padding:7px 9px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;' end;
  v_td text := case when p_pdf then '' else 'padding:7px 9px;border-bottom:1px solid #eceff1;font-size:12px;' end;
  v_tabel text := case when p_pdf then '<table border="1" cellspacing="0" cellpadding="4" style="border-collapse:collapse;font-size:10px;width:100%;">'
                       else '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin:4px 0 14px;">' end;
  v_hasil text := ''; k record; v_baris text;
begin
  -- 20261163640000: satu blok per campaign, depot-depotnya di bawah.
  for k in select x->>'kodeCampaign' kode, max(x->>'namaCampaign') nama, max(x->>'periode') periode,
                  max(x->>'jenisHadiah') jenis, sum((x->>'totalCbNet')::numeric) total, count(*) n_depot
             from jsonb_array_elements(p_isi->'rows') x group by 1 order by 1 loop
    select string_agg('<tr>'
        || '<td style="' || v_td || '" align="right">' || i::text || '.</td>'
        || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(x->>'kodeDepot') || '</td>'
        || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'namaDepot') || '</td>'
        || '<td style="' || v_td || 'white-space:nowrap;" align="right">' || rc_private.rupiah((x->>'totalCbNet')::numeric) || '</td>'
        || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'oleh') || '</td>'
        || '</tr>', '' order by i)
      into v_baris
      from (select x, row_number() over (order by x->>'kodeDepot') i
              from jsonb_array_elements(p_isi->'rows') x where x->>'kodeCampaign' = k.kode) q;
    v_hasil := v_hasil
      || case when p_pdf then '<h3 style="font-size:12px;margin:14px 0 2px;">'
              else '<p style="font-size:14px;font-weight:bold;margin:18px 0 2px;color:#202124;">' end
      || rc_private.html_aman(k.kode || ' - ' || k.nama)
      || case when p_pdf then '</h3>' else '</p>' end
      || '<p style="font-size:' || case when p_pdf then '10' else '12' end || 'px;color:#5f6368;margin:0 0 4px;">Periode Campaign: '
      || rc_private.html_aman(k.periode) || ' &middot; Jenis Hadiah: ' || rc_private.html_aman(k.jenis)
      || ' &middot; ' || k.n_depot::text || ' depot</p>'
      || v_tabel
      || '<tr' || case when p_pdf then '' else ' style="background:#f5f6f7;"' end || '>'
      || '<th align="right" style="' || v_th || '">NO</th><th align="left" style="' || v_th || '">KODE DEPOT</th>'
      || '<th align="left" style="' || v_th || '">NAMA DEPOT</th><th align="right" style="' || v_th || '">TOTAL CB NET</th>'
      || '<th align="left" style="' || v_th || '">PROCESS BY</th></tr>'
      || coalesce(v_baris, '')
      || '<tr><td colspan="3" style="' || v_td || 'font-weight:bold;">Total Campaign ' || rc_private.html_aman(k.kode) || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;font-weight:bold;" align="right">' || rc_private.rupiah(k.total) || '</td>'
      || '<td style="' || v_td || '"></td></tr></table>';
  end loop;
  return v_hasil;
end $f$;
revoke all on function rc_private.email_cmp_jendela(timestamptz, boolean, integer), rc_private.email_cmp_blok(jsonb, boolean)
  from public, anon, authenticated;

do $cek$ begin
  if rc_private.email_cmp_blok('{"rows":[{"kodeCampaign":"K1","namaCampaign":"N1","periode":"-","jenisHadiah":"CN","totalCbNet":5,"oleh":"x","kodeDepot":"1A","namaDepot":"D"}]}'::jsonb, false) !~ 'Total Campaign K1' then
    raise exception 'GAGAL: blok per campaign'; end if;
end $cek$;
