-- ==========================================================================================
-- Email rapi di Outlook; email pengajuan saat approval dimatikan tanpa catatan
-- ==========================================================================================
-- Pemilik, 13 Oktober 2026:
--   "body email tidak rapih karena bukan format gmail melainkan outlook, coba sesuaikan"
--   "pada email pengajuan waktu approval dimatikan, tidak perlu ditambahkan note 'ini melewati
--    approval' cukup pengajuan aja tanpa note itu."
--
-- OUTLOOK. Outlook desktop merender HTML dengan mesin Word, yang mengabaikan sebagian besar CSS
-- pada <div>: padding, border-radius, max-width, dan latar warna. Font juga tidak diwarisi dari
-- <div> pembungkus, sehingga teks jatuh ke Times New Roman. Email RC dibangun persis dari bahan
-- itu: kepala merah berupa <div> berlatar, kotak isi berupa <div> ber-padding, dan lebar dijaga
-- max-width - di Outlook kepalanya bisa hilang, isinya menempel ke tepi, dan melebar penuh.
--
-- SEKARANG
--   rc_private.email_outlook(html)   pembungkus + penormal, dipasang di setiap penulis outbox:
--     - tabel pembungkus lebar 720 px khusus Outlook (komentar bersyarat mso), max-width untuk
--       klien lain;
--     - font Arial ditulis langsung pada setiap elemen yang punya style, <td>/<th>/<li> polos
--       diberi font, dan setiap <p> diberi margin eksplisit;
--     - line-height tanpa satuan (1.6) diubah ke persen (160%), yang dipatuhi Outlook.
--     Aman dipanggil berulang: html yang sudah dibungkus dikembalikan apa adanya.
--   rc_private.email_kepala          kepala merah berupa tabel dengan bgcolor, bukan <div>.
--   email_pengajuan_html             kotak isi berupa tabel; hasil akhir lewat email_outlook.
--   email_pengajuan_antre, rc_email_susun   html dibungkus email_outlook sebelum masuk outbox.
--
-- APPROVAL DIMATIKAN. Kalimat penutup email submit_langsung ("Pengajuan ini tidak melalui
-- approval dan langsung diteruskan ...") dihapus; paragraf penutup tidak ditulis bila kosong.
-- Subjek tetap "Pengajuan Claim Depot ..." (20261162180000).
--
-- Ditambal dengan penjaga MD5 pra-citra (sama di dev dan prod, 13 Oktober 2026).
-- ==========================================================================================

create or replace function rc_private.email_outlook(p_html text)
 returns text
 language sql
 immutable
 set search_path to ''
as $function$
  -- 20261163020000: lihat kepala migrasi.
  select case
    when coalesce(p_html, '') = '' then coalesce(p_html, '')
    when left(p_html, 17) = '<!--rc-outlook-->' then p_html
    else
      '<!--rc-outlook-->'
      || '<!--[if mso]><table role="presentation" width="720" align="left" cellpadding="0" cellspacing="0" border="0">'
      || '<tr><td style="font-family:Arial,Helvetica,sans-serif;"><![endif]-->'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
      || 'style="font-family:Arial,Helvetica,sans-serif;width:100%;max-width:720px;border-collapse:collapse;mso-table-lspace:0pt;mso-table-rspace:0pt;">'
      || '<tr><td style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:150%;color:#202124;">'
      || regexp_replace(
           regexp_replace(
             replace(replace(replace(replace(
               replace(p_html, '<p style="', '<p style="margin:0 0 12px 0;'),
               '<p>', '<p style="margin:0 0 12px 0;">'),
               '<td>', '<td style="font-family:Arial,Helvetica,sans-serif;">'),
               '<th>', '<th style="font-family:Arial,Helvetica,sans-serif;">'),
               '<li>', '<li style="font-family:Arial,Helvetica,sans-serif;">'),
             'style="(?![^"]*font-family)', 'style="font-family:Arial,Helvetica,sans-serif;', 'g'),
           'line-height:([0-9])\.([0-9])([;"])', 'line-height:\1\20%\3', 'g')
      || '</td></tr></table>'
      || '<!--[if mso]></td></tr></table><![endif]-->'
  end;
$function$;
revoke all on function rc_private.email_outlook(text) from public, anon, authenticated;

create or replace function rc_private.email_kepala(p_judul text, p_anak_judul text default ''::text)
 returns text
 language sql
 immutable
 set search_path to ''
as $function$
  -- 20261163020000: tabel ber-bgcolor, bukan <div> berlatar - Outlook mengabaikan latar <div>.
  select
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
    || '<tr><td bgcolor="#C8102E" style="background-color:#C8102E;padding:16px 20px;">'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;"><tr>'
    || '<td width="40" valign="middle" style="width:40px;">'
    || '<img src="cid:logo" width="34" height="34" alt="Nippon Paint" style="display:block;border:0;background:#ffffff;">'
    || '</td>'
    || '<td valign="middle" style="padding-left:12px;font-family:Arial,Helvetica,sans-serif;color:#ffffff;'
    || 'font-size:17px;font-weight:bold;line-height:130%;">'
    || rc_private.html_aman(p_judul)
    || case when coalesce(btrim(p_anak_judul),'') = '' then ''
            else '<br><span style="font-family:Arial,Helvetica,sans-serif;color:#ffd9de;font-size:12px;'
                 || 'font-weight:normal;line-height:140%;">' || rc_private.html_aman(p_anak_judul) || '</span>' end
    || '</td>'
    -- Maskot RC di ujung kanan: penanda cepat bahwa surat ini datang dari Resource Collection,
    -- bukan dari salah satu sistem Nippon yang lain.
    || '<td width="44" valign="middle" align="right" style="width:44px;">'
    || '<img src="cid:blobby" width="38" height="38" alt="Resource Collection" style="display:block;border:0;">'
    || '</td>'
    || '</tr></table>'
    || '</td></tr></table>';
$function$;

-- Tombol "Buka Claim Dashboard": <a> berlatar dan ber-padding tampil sebagai tautan polos di
-- Outlook. Kini tombolnya sel tabel ber-bgcolor (teknik "bulletproof button"). Teks lain sama.
do $tombol$ begin
  if md5(replace(pg_get_functiondef('rc_private.email_tautan_dashboard()'::regprocedure), E'\r', '')) <> '8adca5ddd109a8c4a5c93ff8f35d38ba'
     and pg_get_functiondef('rc_private.email_tautan_dashboard()'::regprocedure) !~ '20261163020000' then
    raise exception 'DITOLAK: definisi rc_private.email_tautan_dashboard berbeda dari yang diukur.'; end if;
end $tombol$;
create or replace function rc_private.email_tautan_dashboard()
 returns text
 language sql
 stable
 set search_path to ''
as $function$
  -- 20261163020000: tombol berupa sel tabel ber-bgcolor supaya tampil sebagai tombol di Outlook.
  select '<p style="line-height:1.6;margin-top:18px;">Untuk melihat detail Claim secara lebih '
      || 'lengkap, silakan mengakses Claim Dashboard melalui link berikut:</p>'
      || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:10px 0 14px;"><tr>'
      || '<td bgcolor="#4285F4" style="background-color:#4285F4;padding:10px 18px;">'
      || '<a href="https://rc-next-gen.vercel.app/dashboard" '
      || 'style="color:#ffffff;text-decoration:none;font-weight:bold;font-size:13px;display:inline-block;">'
      || 'Buka Claim Dashboard</a></td></tr></table>'
      || '<p style="line-height:1.6;">Detail performa per Depot dan per Campaign tersedia pada '
      || 'halaman tersebut, dan dapat dibuka langsung tanpa perlu masuk ke aplikasi.</p>'
      || '<p style="line-height:1.6;">Thank you for your attention and cooperation.</p>';
$function$;

do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  ('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)', 'e075e5337fe997052641a90edfb56f4a',
   $p$    when 'submit_langsung' then 'Pengajuan ini tidak melalui approval dan langsung diteruskan ke tahap Release. Mohon tim OSC untuk segera memproses dokumen tersebut.'$p$,
   $p$    -- 20261163020000: approval dimatikan - cukup pengajuannya, tanpa catatan "melewati approval".
    when 'submit_langsung' then ''$p$, 1),
  ('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)', 'e075e5337fe997052641a90edfb56f4a',
   $p$    || '<div style="border:1px solid #e0e2e6;border-top:none;border-radius:0 0 8px 8px;padding:18px 20px;">'$p$,
   $p$    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
    || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;">'$p$, 1),
  ('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)', 'e075e5337fe997052641a90edfb56f4a',
   $p$    || '<p style="line-height:1.6;margin-top:16px;">' || v_aksi || '</p>'$p$,
   $p$    || case when coalesce(v_aksi,'') = '' then ''
            else '<p style="line-height:1.6;margin-top:16px;">' || v_aksi || '</p>' end$p$, 1),
  ('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)', 'e075e5337fe997052641a90edfb56f4a',
   $p$    || rc_private.email_ttd()
    || '</div>';$p$,
   $p$    || rc_private.email_ttd()
    || '</td></tr></table>';$p$, 1),
  ('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)', 'e075e5337fe997052641a90edfb56f4a',
   $p$  return '<div style="font-family:Arial,Helvetica,sans-serif;color:#202124;max-width:640px;">'
         || v_html || '</div>';$p$,
   $p$  return rc_private.email_outlook(v_html); -- 20261163020000$p$, 1),

  ('rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)', '68fbd5f7410d66c072dc8ede7eaf7f4d',
   $p$      v_html   := v_spanduk || v_html;$p$,
   $p$      v_html   := rc_private.email_outlook(v_spanduk || v_html); -- 20261163020000$p$, 1),

  ('public.rc_email_susun(text,boolean,text)', 'd42f37c710c0d2d42ae459cefbb86884',
   $p$  insert into public.email_outbox(jenis,tujuan,cc,subjek,isi_html,status,konteks)
  values(v_jenis,$p$,
   $p$  v_html := rc_private.email_outlook(v_html); -- 20261163020000: rapi di Outlook
  insert into public.email_outbox(jenis,tujuan,cc,subjek,isi_html,status,konteks)
  values(v_jenis,$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261163020000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(src, E'\r', '')); end if;
    baru := replace(src, E'\r', '');
    for r in select * from _tambal where sig = f.sig order by urut loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> r.n then
        raise exception '%: pola "%" ditemukan % kali, diharapkan %.', f.sig, left(r.lama, 80), n, r.n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
    execute baru;
  end loop;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (dibatalkan): email pengajuan dan ringkasan terbungkus untuk Outlook, setiap
-- style memuat font, tidak ada <div> berlatar/ber-padding sebagai tata letak, dan email
-- submit_langsung tanpa catatan approval.
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; v_ids uuid[]; h text; s jsonb; e text := ''; jenis text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select array_agg(id) into v_ids from (select id from public.claims where archived_at is null and customer_id is not null order by no_doc limit 3) x;
  if v_sm is null or v_ids is null then raise notice 'Tidak ada fixture; uji dilewati.'; return; end if;

  foreach jenis in array array['submit','submit_langsung','approve','clearing','hold','expire'] loop
    h := rc_private.email_pengajuan_html(jenis, 'BATCHUJI', v_ids, v_sm, case when jenis in ('hold','expire') then 'alasan uji' else '' end);
    if left(h, 17) <> '<!--rc-outlook-->' or h !~ '<!--\[if mso\]>' then e := e || format(' %s tidak terbungkus;', jenis); end if;
    if h ~ 'style="(?![^"]*font-family)' then e := e || format(' %s ada style tanpa font;', jenis); end if;
    if h ~ '<div style="[^"]*(background|padding|border-radius)' then e := e || format(' %s masih memakai div tata letak;', jenis); end if;
    if h ~ 'line-height:[0-9]\.[0-9]' then e := e || format(' %s line-height tanpa satuan;', jenis); end if;
    if h !~ 'bgcolor="#C8102E"' then e := e || format(' %s kepala tanpa bgcolor;', jenis); end if;
    if rc_private.email_outlook(h) <> h then e := e || format(' %s tidak idempoten;', jenis); end if;
  end loop;
  h := rc_private.email_pengajuan_html('submit_langsung', 'BATCHUJI', v_ids, v_sm, '');
  if h ~* 'tidak melalui approval|melewati approval' then e := e || ' catatan approval masih ada;'; end if;
  if h ~ 'margin-top:16px;">\s*</p>' then e := e || ' paragraf penutup kosong tertulis;'; end if;
  h := rc_private.email_pengajuan_html('submit', 'BATCHUJI', v_ids, v_sm, '');
  if h !~ 'Mohon tim Management untuk segera melakukan approval' then e := e || ' kalimat submit biasa hilang;'; end if;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    foreach jenis in array array['daily','weekly','timetable'] loop
      s := public.rc_email_susun(jenis, false, '');
      if coalesce(s->>'isiHtml', '') <> '' and (left(s->>'isiHtml', 17) <> '<!--rc-outlook-->' or (s->>'isiHtml') ~ 'style="(?![^"]*font-family)') then
        e := e || format(' ringkasan %s tidak rapi untuk Outlook;', jenis); end if;
    end loop;
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then e := e || ' galat ringkasan: ' || sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
