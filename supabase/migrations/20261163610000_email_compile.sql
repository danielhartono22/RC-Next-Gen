-- ==========================================================================================
-- Email otomatis Closing Campaign (Compile): rangkuman compile CB di Document Center, jam 14:00
-- ==========================================================================================
-- Pemilik, 4 November 2026:
--   "buat juga 1 email otomatis untuk compile dan dikirim tiap jam 2 sore, email compile ini
--    seperti bukan satu per satu depo tapi semuanya seperti top 5 depo intinya yang compile cb
--    di doc center akan masuk thread emailnya. dengan wordingan
--      Dear All,
--      Berikut closing campaign per hari ini (tanggal)
--      depot a 1. 2. 3.   depot b 1. 2. 3   dan seterusnya,
--    di kolom ditampilkan : kode campaign, nama campaign, periode campaign, jenis hadiah
--    (default), total cb net, process by: dan buatkan pdf juga, dan buatkan juga di email
--    otomatis. Untuk to sama seperti top 5 depo , dan cc bisa ditambahkan."
--
-- * Jenis email terjadwal baru 'compile' (Access Management > Email Otomatis), jam 14, tiap
--   hari, AKTIF (diminta dikirim tiap jam 2 sore). Hari tanpa compile: tidak ada email.
-- * Satu email untuk seluruh depot. Isi: setiap depot yang compile, bernomor 1, 2, 3 ... per
--   depot x campaign, kolom Kode Campaign, Nama Campaign, Periode Campaign, Jenis Hadiah,
--   Total CB Net, Process By. Lampiran PDF berisi tabel yang sama.
--     - Sumber: dokumen hasil Compile Cashback (claim_status_history.action = 'compile_import'),
--       yang belum diarsip. Total CB Net = jumlah cb_net dokumen itu.
--     - Jenis Hadiah = Jenis CB bawaan campaign di Key Master (campaigns.cashback_type), bukan
--       Jenis CB yang ditulis di file compile.
--     - Process By = user yang meng-compile (nama (ID)); lebih dari satu dipisah koma.
-- * Jendela (sama dengan Not Achieved): compile sebelum jam kirim masuk email hari itu, sesudahnya
--   masuk email besok. Terjadwal: sejak batas email sungguhan terakhir (atau jam kirim kemarin)
--   sampai jam kirim hari ini; hari yang terlewat ikut (maks 14 hari). Pratinjau / Test Email /
--   Kirim Manual: sejak batas itu sampai saat ini. Jam kirim mengikuti jam di panel.
-- * Penerima sama dengan Daily (Top 5 Depot): TO = Email TO, CC = Email CC (Depot Master) depot
--   yang ada di email, ditambah CC tambahan jadwal ini di panel. Test Email hanya ke alamat uji.
--   Di DEV surat ke penerima sungguhan tetap ditahan server.
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- 1. Jenis email ------------------------------------------------------------------------
alter table public.email_settings drop constraint if exists email_settings_jenis_check;
alter table public.email_settings add constraint email_settings_jenis_check
  check (jenis = any (array['daily','weekly','timetable','pengajuan','kesehatan','notachieved','compile']));

insert into public.email_settings(jenis, aktif, jam, subjek, catatan, hari_list, cc_tambahan, tujuan)
values ('compile', true, 14, 'Closing Campaign Report',
        'Rangkuman compile CB di Document Center per depot, sejak email terakhir sampai jam kirim. TO = Email TO, CC = Email CC (Depot Master) + CC tambahan.',
        null, '{}', '{}')
on conflict (jenis) do nothing;

-- ---- 2. Jendela waktu ----------------------------------------------------------------------
-- Batas = jam kirim (WIB) terakhir yang tidak melewati p_t.
create or replace function rc_private.email_cmp_batas(p_t timestamptz, p_jam integer) returns timestamptz
language sql immutable set search_path = '' as $f$
  select case when b <= p_t then b else b - interval '1 day' end
    from (select (date_trunc('day', p_t at time zone 'Asia/Jakarta') + make_interval(hours => coalesce(p_jam, 14))) at time zone 'Asia/Jakarta' b) x;
$f$;

create or replace function rc_private.email_cmp_jendela(p_sekarang timestamptz, p_terjadwal boolean, p_jam integer) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_b timestamptz := rc_private.email_cmp_batas(p_sekarang, p_jam); v_akhir timestamptz; v_dari timestamptz; v_sampai timestamptz;
begin
  select max((o.konteks->>'sampai')::timestamptz) into v_akhir from public.email_outbox o
   where o.jenis = 'compile' and o.status in ('pending', 'sent', 'failed') and o.konteks ? 'sampai'
     and coalesce(o.konteks->>'preview', '') <> 'true' and coalesce(o.konteks->>'uji', '') <> 'true'
     and (o.konteks->>'sampai')::timestamptz <= p_sekarang;
  v_sampai := case when p_terjadwal then v_b else p_sekarang end;
  v_dari := coalesce(v_akhir, case when p_terjadwal then v_b - interval '1 day' else v_b end);
  v_dari := least(greatest(v_dari, v_sampai - interval '14 days'), v_sampai);
  return jsonb_build_object('dari', v_dari, 'sampai', v_sampai);
end $f$;

-- ---- 3. Isi --------------------------------------------------------------------------------
-- {rows (urut depot, campaign), depot[] (kode), jumlahDepot, jumlahCampaign, total}.
create or replace function rc_private.email_cmp_isi(p_dari timestamptz, p_sampai timestamptz) returns jsonb
language sql stable security definer set search_path = '' as $f$
  with k as (
    select distinct on (c.id) c.id, c.depot_id, c.campaign_id, c.cb_net, h.actor_id
      from public.claim_status_history h
      join public.claims c on c.id = h.claim_id
     where h.action = 'compile_import' and h.created_at >= p_dari and h.created_at < p_sampai
       and c.archived_at is null
     order by c.id, h.created_at
  ), g as (
    select d.depot_code, coalesce(d.depot_name, '') depot_name, ca.campaign_code, coalesce(ca.campaign_name, '') campaign_name,
           coalesce(nullif(concat_ws(' s/d ',
             coalesce(to_char(ca.period_start, 'DD-Mon-YYYY'), nullif(btrim(ca.period_start_text), '')),
             coalesce(to_char(ca.period_end, 'DD-Mon-YYYY'), nullif(btrim(ca.period_end_text), ''))), ''), '-') periode,
           coalesce(nullif(rc_private.cb_label(ca.cashback_type), ''), '-') jenis_hadiah,
           trunc(coalesce(sum(k.cb_net), 0)) total, count(*) qty,
           (select string_agg(distinct coalesce(nullif(btrim(pr.full_name), ''), pr.user_code, '-')
                     || case when pr.user_code is not null and nullif(btrim(pr.full_name), '') is not null then ' (' || pr.user_code || ')' else '' end, ', ')
              from public.profiles pr where pr.id = any(array_agg(k.actor_id))) oleh
      from k join public.depots d on d.id = k.depot_id join public.campaigns ca on ca.id = k.campaign_id
     group by d.depot_code, d.depot_name, ca.campaign_code, ca.campaign_name, ca.period_start, ca.period_start_text,
              ca.period_end, ca.period_end_text, ca.cashback_type
  )
  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(jsonb_build_object(
              'kodeDepot', g.depot_code, 'namaDepot', g.depot_name, 'kodeCampaign', g.campaign_code,
              'namaCampaign', g.campaign_name, 'periode', g.periode, 'jenisHadiah', g.jenis_hadiah,
              'totalCbNet', g.total, 'qty', g.qty, 'oleh', coalesce(g.oleh, '-'))
            order by g.depot_code, g.campaign_code), '[]'),
    'depot', coalesce(jsonb_agg(distinct g.depot_code), '[]'),
    'jumlahDepot', count(distinct g.depot_code),
    'jumlahCampaign', count(distinct g.campaign_code),
    'total', coalesce(sum(g.total), 0))
  from g;
$f$;

-- Satu blok per depot: judul depot lalu tabel bernomor. p_pdf: gaya sederhana untuk PDF.
create or replace function rc_private.email_cmp_blok(p_isi jsonb, p_pdf boolean) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare
  v_th text := case when p_pdf then '' else 'padding:7px 9px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;' end;
  v_td text := case when p_pdf then '' else 'padding:7px 9px;border-bottom:1px solid #eceff1;font-size:12px;' end;
  v_tabel text := case when p_pdf then '<table border="1" cellspacing="0" cellpadding="4" style="border-collapse:collapse;font-size:10px;width:100%;">'
                       else '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin:4px 0 14px;">' end;
  v_hasil text := ''; d record; v_baris text;
begin
  for d in select x->>'kodeDepot' kode, max(x->>'namaDepot') nama, sum((x->>'totalCbNet')::numeric) total
             from jsonb_array_elements(p_isi->'rows') x group by 1 order by 1 loop
    select string_agg('<tr>'
        || '<td style="' || v_td || '" align="right">' || i::text || '.</td>'
        || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(x->>'kodeCampaign') || '</td>'
        || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'namaCampaign') || '</td>'
        || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(x->>'periode') || '</td>'
        || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'jenisHadiah') || '</td>'
        || '<td style="' || v_td || 'white-space:nowrap;" align="right">' || rc_private.rupiah((x->>'totalCbNet')::numeric) || '</td>'
        || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'oleh') || '</td>'
        || '</tr>', '' order by i)
      into v_baris
      from (select x, row_number() over (order by x->>'kodeCampaign') i
              from jsonb_array_elements(p_isi->'rows') x where x->>'kodeDepot' = d.kode) q;
    v_hasil := v_hasil
      || case when p_pdf then '<h3 style="font-size:12px;margin:14px 0 4px;">'
              else '<p style="font-size:14px;font-weight:bold;margin:18px 0 4px;color:#202124;">' end
      || 'Depot ' || rc_private.html_aman(d.kode || ' - ' || d.nama)
      || case when p_pdf then '</h3>' else '</p>' end
      || v_tabel
      || '<tr' || case when p_pdf then '' else ' style="background:#f5f6f7;"' end || '>'
      || '<th align="right" style="' || v_th || '">NO</th><th align="left" style="' || v_th || '">KODE CAMPAIGN</th>'
      || '<th align="left" style="' || v_th || '">NAMA CAMPAIGN</th><th align="left" style="' || v_th || '">PERIODE CAMPAIGN</th>'
      || '<th align="left" style="' || v_th || '">JENIS HADIAH</th><th align="right" style="' || v_th || '">TOTAL CB NET</th>'
      || '<th align="left" style="' || v_th || '">PROCESS BY</th></tr>'
      || coalesce(v_baris, '')
      || '<tr><td colspan="5" style="' || v_td || 'font-weight:bold;">Total Depot ' || rc_private.html_aman(d.kode) || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;font-weight:bold;" align="right">' || rc_private.rupiah(d.total) || '</td>'
      || '<td style="' || v_td || '"></td></tr></table>';
  end loop;
  return v_hasil;
end $f$;

create or replace function rc_private.email_cmp_html(p_isi jsonb, p_dari timestamptz, p_sampai timestamptz) returns text
language sql stable security definer set search_path = '' as $f$
  select rc_private.email_kepala('Closing Campaign Report',
           (p_isi->>'jumlahCampaign') || ' campaign  |  ' || (p_isi->>'jumlahDepot') || ' depot  |  ' || rc_private.tgl_panjang(now()))
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
    || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
    || '<p style="line-height:1.6;margin-top:0;">Dear All,</p>'
    || '<p style="line-height:1.6;">Berikut closing campaign per hari ini (<strong>' || rc_private.tgl_panjang(now()) || '</strong>).</p>'
    || '<p style="line-height:1.6;font-size:12px;color:#5f6368;">Compile CB di Document Center '
    || to_char(p_dari at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ' s/d '
    || to_char(p_sampai at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ' WIB: '
    || (p_isi->>'jumlahCampaign') || ' campaign di ' || (p_isi->>'jumlahDepot') || ' depot, total CB Net '
    || rc_private.rupiah((p_isi->>'total')::numeric) || '. Rincian juga terlampir (PDF).</p>'
    || rc_private.email_cmp_blok(p_isi, false)
    || '<p style="line-height:1.6;">Thank you for your attention and cooperation.</p>'
    || rc_private.email_ttd()
    || '</td></tr></table>';
$f$;

create or replace function rc_private.email_cmp_pdf_html(p_isi jsonb, p_dari timestamptz, p_sampai timestamptz) returns text
language sql stable security definer set search_path = '' as $f$
  select '<html><head><meta charset="UTF-8"></head><body style="font-family:Arial,sans-serif;">'
    || '<h1 style="font-size:18px;">Closing Campaign Report</h1>'
    || '<p style="font-size:11px;color:#555;">' || rc_private.tgl_panjang(now()) || ' &middot; compile CB di Document Center '
    || to_char(p_dari at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ' s/d '
    || to_char(p_sampai at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ' WIB &middot; '
    || (p_isi->>'jumlahCampaign') || ' campaign, ' || (p_isi->>'jumlahDepot') || ' depot, total CB Net '
    || rc_private.rupiah((p_isi->>'total')::numeric) || '</p>'
    || '<p style="font-size:11px;">Dear All,<br>Berikut closing campaign per hari ini (' || rc_private.tgl_panjang(now()) || ').</p>'
    || rc_private.email_cmp_blok(p_isi, true)
    || '<p style="font-size:9px;color:#777;">Dibuat otomatis oleh RC (Resource Collection).</p></body></html>';
$f$;

revoke all on function rc_private.email_cmp_batas(timestamptz, integer), rc_private.email_cmp_jendela(timestamptz, boolean, integer),
  rc_private.email_cmp_isi(timestamptz, timestamptz), rc_private.email_cmp_blok(jsonb, boolean),
  rc_private.email_cmp_html(jsonb, timestamptz, timestamptz), rc_private.email_cmp_pdf_html(jsonb, timestamptz, timestamptz)
  from public, anon, authenticated;

-- ---- 4. Tambalan bertanda ------------------------------------------------------------------
do $tambal$
declare src text;
begin
  -- rc_email_susun: cabang 'compile' memakai jalur penerima Daily (penerima_depot + CC tambahan + Test Email).
  src := replace(pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure), E'\r', '');
  if src !~ '20261163610000' then
    src := pg_temp.ganti(src,
      $p$  v_ukur text; v_judul_top text; -- 20261163570000$p$,
      $p$  v_ukur text; v_judul_top text; -- 20261163570000
  v_cmp jsonb; v_cmp_jend jsonb; v_cmp_konteks jsonb; -- 20261163610000$p$, 1, 'susun declare');
    src := pg_temp.ganti(src,
      $p$  elsif v_jenis = 'timetable' then$p$,
      $p$  elsif v_jenis = 'compile' then
    -- 20261163610000: Closing Campaign - compile CB di Document Center, seluruh depot dalam satu email.
    v_cmp_jend := rc_private.email_cmp_jendela(now(),
      auth.uid() is null and coalesce(p_kirim, false) and v_uji = '', v_set.jam);
    v_cmp := rc_private.email_cmp_isi((v_cmp_jend->>'dari')::timestamptz, (v_cmp_jend->>'sampai')::timestamptz);
    if jsonb_array_length(v_cmp->'rows') = 0 then
      insert into public.email_outbox(jenis,tujuan,subjek,isi_html,status,galat,konteks)
      values(v_jenis,'{}','(tidak dikirim)','','skipped','Tidak ada compile pada jendela ini',
        jsonb_build_object('preview',not coalesce(p_kirim,false),'uji',v_uji <> '',
                           'dari',v_cmp_jend->'dari','sampai',v_cmp_jend->'sampai'))
      returning id into v_id;
      return jsonb_build_object('status','success','dikirim',false,'id',v_id,
        'isiHtml','<p style="font-family:Arial,sans-serif;">Belum ada compile CB di Document Center sejak '
          ||to_char((v_cmp_jend->>'dari')::timestamptz at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI')||' sampai '
          ||to_char((v_cmp_jend->>'sampai')::timestamptz at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI')||' WIB.</p>',
        'message','Tidak ada compile sejak '
          ||to_char((v_cmp_jend->>'dari')::timestamptz at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI')||' WIB; email tidak disusun.');
    end if;
    v_depot := array(select jsonb_array_elements_text(v_cmp->'depot'));
    v_subjek := coalesce(nullif(btrim(v_set.subjek),''),'Closing Campaign Report') || ' - ' || rc_private.tgl_panjang(now());
    v_html := rc_private.email_cmp_html(v_cmp, (v_cmp_jend->>'dari')::timestamptz, (v_cmp_jend->>'sampai')::timestamptz);
    v_penerima := rc_private.penerima_depot(v_depot);
    v_cmp_konteks := jsonb_build_object('dari',v_cmp_jend->'dari','sampai',v_cmp_jend->'sampai',
      'jumlah',jsonb_array_length(v_cmp->'rows'),
      'pdfHtml',rc_private.email_cmp_pdf_html(v_cmp, (v_cmp_jend->>'dari')::timestamptz, (v_cmp_jend->>'sampai')::timestamptz));

  elsif v_jenis = 'timetable' then$p$, 1, 'susun cabang');
    src := pg_temp.ganti(src,
      $p$    jsonb_build_object('depot',to_jsonb(v_depot),'preview',not coalesce(p_kirim,false),
                       'uji',v_uji <> ''))
  returning id into v_id;$p$,
      $p$    jsonb_build_object('depot',to_jsonb(v_depot),'preview',not coalesce(p_kirim,false),
                       'uji',v_uji <> '') || coalesce(v_cmp_konteks, '{}'::jsonb) /* 20261163610000 */)
  returning id into v_id;$p$, 1, 'susun konteks');
    execute src;
  end if;

  -- kirim_satu_email: PDF Closing Campaign dari isi yang disusun bersama emailnya.
  src := replace(pg_get_functiondef('rc_private.kirim_satu_email(uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163610000' then
    src := pg_temp.ganti(src,
      $p$if v.jenis = 'notachieved' then$p$,
      $p$if v.jenis in ('notachieved', 'compile' /* 20261163610000 */) then$p$, 1, 'kirim jenis');
    src := pg_temp.ganti(src,
      $p$v_nama_pdf := 'Not_Achieved_Campaign_Report_' ||$p$,
      $p$v_nama_pdf := case when v.jenis = 'compile' then 'Closing_Campaign_Report_' else 'Not_Achieved_Campaign_Report_' end ||$p$,
      1, 'kirim nama pdf');
    execute src;
  end if;
end $tambal$;

do $cek$ begin
  if not exists (select 1 from public.email_settings where jenis = 'compile') then raise exception 'GAGAL: jadwal compile'; end if;
  if pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure) !~ 'email_cmp_isi' then raise exception 'GAGAL: rc_email_susun'; end if;
  if pg_get_functiondef('rc_private.kirim_satu_email(uuid)'::regprocedure) !~ 'Closing_Campaign_Report_' then raise exception 'GAGAL: kirim_satu_email'; end if;
  raise notice 'Email Closing Campaign (compile) terpasang.';
end $cek$;
