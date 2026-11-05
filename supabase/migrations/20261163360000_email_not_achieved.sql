-- ==========================================================================================
-- Email otomatis Not Achieved: rangkuman harian jam 16:00 pasangan depot x campaign yang
-- ditandai Not Achieved (Timetable). Permintaan pemilik 22 Oktober 2026.
-- ==========================================================================================
-- * Jadwal: jenis email terjadwal baru 'notachieved' (Access Management > Email Otomatis),
--   bawaan jam 16, tiap hari, NONAKTIF sampai dinyalakan (sama dengan jadwal lain).
-- * Jendela: tanda yang dibuat sebelum jam 16:00 masuk email hari itu; sesudah 16:00 masuk
--   email besoknya. Email terjadwal memuat tanda sejak batas email sungguhan terakhir (atau
--   16:00 kemarin) sampai 16:00 hari ini, sehingga hari yang terlewat tidak hilang (maks 14 hari).
--   Pratinjau / Test Email / Kirim Manual memuat tanda sejak batas itu sampai saat ini.
-- * Satu email untuk seluruh region (pemilik, 22 Oktober 2026), subjek
--   "Not Achieved Campaign Report - <tanggal hari ini>". Kolom: Region, Nama Depot, Nama Campaign,
--   Periode Start (SO start), Periode End (SO end), Process By, Timestamp - satu baris per tanda.
-- * Penerima dari Depot Master (pemilik, 22 Oktober 2026: "pakai email di depo master yang cc
--   nya dan to nya"), gabungan seluruh depot yang ada di email:
--   TO = Email TO depot; CC = Email CC depot + CC semua email dan CC wajib jenis "Not Achieved"
--   di tab Email Pengajuan (dapat diubah). Alamat yang sudah di TO tidak diulang di CC.
-- * Mode Uji tab Email Pengajuan berlaku juga di sini: surat dibelokkan ke alamat uji dengan
--   spanduk penerima seharusnya. Di DEV surat ke penerima sungguhan tetap ditahan server.
-- Tanda Not Participating (Campaign NP) tidak termasuk; hanya timetable_not_achieved.
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
  check (jenis = any (array['daily','weekly','timetable','pengajuan','kesehatan','notachieved']));

insert into public.email_settings(jenis, aktif, jam, subjek, catatan, hari_list, cc_tambahan, tujuan)
values ('notachieved', false, 16, 'Not Achieved Campaign Report',
        'Rangkuman harian tanda Not Achieved seluruh region. TO = Email TO, CC = Email CC (Depot Master) + CC tab Email Pengajuan.',
        null, '{}', '{}')
on conflict (jenis) do nothing;
-- Subjek bawaan versi pertama (sebelum dibakukan pemilik) diganti; subjek yang sudah diubah di panel dibiarkan.
update public.email_settings set subjek = 'Not Achieved Campaign Report'
 where jenis = 'notachieved' and subjek = 'RC Not Achieved Campaign';

-- Versi pertama (satu email per region) memakai tanda tangan lain.
drop function if exists rc_private.email_na_penerima(uuid[], text);
drop function if exists rc_private.email_na_penerima(uuid[], text[]);
drop function if exists rc_private.email_na_html(text, jsonb, timestamptz, timestamptz);

-- ---- 2. Jendela waktu ------------------------------------------------------------------------
-- Batas 16:00 WIB terakhir yang sudah lewat (<= p_t).
create or replace function rc_private.email_na_batas(p_t timestamptz) returns timestamptz
language sql immutable set search_path = '' as $f$
  select case when b <= p_t then b else b - interval '1 day' end
    from (select (date_trunc('day', p_t at time zone 'Asia/Jakarta') + interval '16 hours') at time zone 'Asia/Jakarta' b) x;
$f$;

-- {dari, sampai}. Terjadwal: sampai = batas 16:00 terakhir. Lainnya: sampai = saat ini.
-- dari = batas email sungguhan terakhir (pratinjau dan uji tidak dihitung), atau bawaan.
create or replace function rc_private.email_na_jendela(p_sekarang timestamptz, p_terjadwal boolean) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_b timestamptz := rc_private.email_na_batas(p_sekarang); v_akhir timestamptz; v_dari timestamptz; v_sampai timestamptz;
begin
  select max((o.konteks->>'sampai')::timestamptz) into v_akhir from public.email_outbox o
   where o.jenis = 'notachieved' and o.status in ('pending', 'sent', 'failed') and o.konteks ? 'sampai'
     and coalesce(o.konteks->>'preview', '') <> 'true' and coalesce(o.konteks->>'uji', '') <> 'true'
     and (o.konteks->>'sampai')::timestamptz <= p_sekarang;
  v_sampai := case when p_terjadwal then v_b else p_sekarang end;
  v_dari := coalesce(v_akhir, case when p_terjadwal then v_b - interval '1 day' else v_b end);
  v_dari := least(greatest(v_dari, v_sampai - interval '14 days'), v_sampai);
  return jsonb_build_object('dari', v_dari, 'sampai', v_sampai);
end $f$;

-- ---- 3. Penerima ------------------------------------------------------------------------------
-- p_depot: depot yang ada di email. TO = Email TO, CC = Email CC (Depot Master) + CC tab Email Pengajuan.
create or replace function rc_private.email_na_penerima(p_depot uuid[]) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_to text[]; v_cc text[]; v_tam text[]; v_jenis text[];
begin
  select coalesce(array_agg(distinct x order by x), '{}') into v_to
    from public.depots d, unnest(rc_private.pecah_email(d.email_to)) x
   where d.id = any(p_depot);

  select coalesce(cc_tambahan, '{}'), coalesce(array(select jsonb_array_elements_text(coalesce(cc_per_jenis->'notachieved', '[]'::jsonb))), '{}')
    into v_tam, v_jenis from public.email_settings where jenis = 'pengajuan';

  select coalesce(array_agg(distinct a order by a) filter (where a ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
                                                             and not (a = any(v_to))), '{}') into v_cc from (
    select x a from public.depots d, unnest(rc_private.pecah_email(d.email_cc)) x where d.id = any(p_depot)
    union all select lower(btrim(y)) from unnest(coalesce(v_tam, '{}') || coalesce(v_jenis, '{}')) y
  ) s;

  return jsonb_build_object('to', to_jsonb(v_to), 'cc', to_jsonb(v_cc));
end $f$;

-- ---- 4. Isi --------------------------------------------------------------------------------
-- Tanda dalam jendela: {rows (urut region, depot, waktu), depot[], region[]}.
create or replace function rc_private.email_na_isi(p_dari timestamptz, p_sampai timestamptz) returns jsonb
language sql stable security definer set search_path = '' as $f$
  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(jsonb_build_object(
               'region', t.region, 'kodeDepot', t.depot_code, 'namaDepot', t.depot_name,
               'kodeCampaign', t.campaign_code, 'namaCampaign', t.campaign_name,
               'mulai', t.mulai, 'akhir', t.akhir, 'oleh', t.oleh, 'waktu', t.waktu)
             order by t.region, t.depot_code, t.marked_at, t.campaign_code), '[]'),
    'depot', coalesce(jsonb_agg(distinct t.depot_id), '[]'),
    'region', coalesce(jsonb_agg(distinct t.region), '[]'))
  from (
    select coalesce(nullif(upper(btrim(d.region)), ''), '-') region, d.id depot_id, d.depot_code, coalesce(d.depot_name, '') depot_name,
           c.campaign_code, coalesce(c.campaign_name, '') campaign_name, na.marked_at,
           coalesce(to_char(c.so_start, 'DD-Mon-YYYY'), nullif(btrim(c.so_start_text), ''), '-') mulai,
           coalesce(to_char(c.so_end, 'DD-Mon-YYYY'), nullif(btrim(c.so_end_text), ''), '-') akhir,
           coalesce(nullif(btrim(pr.full_name), ''), pr.user_code, '-')
             || case when pr.user_code is not null and nullif(btrim(pr.full_name), '') is not null then ' (' || pr.user_code || ')' else '' end oleh,
           to_char(na.marked_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') waktu
      from public.timetable_not_achieved na
      join public.depots d on d.id = na.depot_id
      join public.campaigns c on c.id = na.campaign_id
      left join public.profiles pr on pr.id = na.marked_by
     where na.marked_at >= p_dari and na.marked_at < p_sampai
       and d.archived_at is null and not d.bukan_depot) t;
$f$;

create or replace function rc_private.email_na_html(p_rows jsonb, p_dari timestamptz, p_sampai timestamptz) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
  v_n integer := jsonb_array_length(coalesce(p_rows, '[]')); v_dep integer; v_reg integer; v_baris text;
begin
  select count(distinct x->>'kodeDepot'), count(distinct x->>'region') into v_dep, v_reg from jsonb_array_elements(p_rows) x;
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

  return rc_private.email_kepala('Not Achieved Campaign Report',
           v_n::text || ' campaign  |  ' || v_dep::text || ' depot  |  ' || v_reg::text || ' region  |  ' || rc_private.tgl_panjang(now()))
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
    || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;">'
    || '<p style="line-height:1.6;margin-top:0;">Dear All,</p>'
    || '<p style="line-height:1.6;">Berikut campaign yang ditandai <strong>Not Achieved</strong> pada '
    || to_char(p_dari at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ' s/d '
    || to_char(p_sampai at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ' WIB.</p>'
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
    || '<p style="line-height:1.6;margin-top:16px;font-weight:bold;">Mohon perhatian kepada All RSM dan Depot Head terkait mengenai tindakan ini.</p>'
    || rc_private.email_ttd()
    || '</td></tr></table>';
end $f$;

-- ---- 5. Susun ------------------------------------------------------------------------------
create or replace function rc_private.email_na_susun(p_set public.email_settings, p_kirim boolean, p_uji text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  v_jend jsonb; v_dari timestamptz; v_sampai timestamptz; v_isi jsonb; v_pen jsonb; v_to text[]; v_cc text[];
  v_html text; v_subjek text; v_id uuid; v_modeuji boolean; v_alamat text; v_spanduk text := ''; v_n integer;
  v_terjadwal boolean := auth.uid() is null and coalesce(p_kirim, false) and coalesce(p_uji, '') = '';
begin
  v_jend := rc_private.email_na_jendela(now(), v_terjadwal);
  v_dari := (v_jend->>'dari')::timestamptz; v_sampai := (v_jend->>'sampai')::timestamptz;
  v_isi := rc_private.email_na_isi(v_dari, v_sampai);
  v_n := jsonb_array_length(v_isi->'rows');

  if v_n = 0 then
    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, galat, konteks)
    values ('notachieved', '{}', '(tidak dikirim)', '', 'skipped', 'Tidak ada tanda Not Achieved pada jendela ini',
            jsonb_build_object('preview', not coalesce(p_kirim, false), 'uji', coalesce(p_uji, '') <> '', 'dari', v_dari, 'sampai', v_sampai))
    returning id into v_id;
    return jsonb_build_object('status', 'success', 'dikirim', false, 'id', v_id, 'dari', v_dari, 'sampai', v_sampai,
      'isiHtml', '<p style="font-family:Arial,sans-serif;">Tidak ada campaign yang ditandai Not Achieved sejak '
                 || to_char(v_dari at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ' sampai '
                 || to_char(v_sampai at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ' WIB.</p>',
      'message', 'Tidak ada tanda Not Achieved sejak ' || to_char(v_dari at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI')
                 || ' WIB; email tidak disusun.');
  end if;

  v_pen := rc_private.email_na_penerima(array(select jsonb_array_elements_text(v_isi->'depot'))::uuid[]);
  v_to := array(select jsonb_array_elements_text(v_pen->'to'));
  v_cc := array(select jsonb_array_elements_text(v_pen->'cc'));
  v_subjek := coalesce(nullif(btrim(p_set.subjek), ''), 'Not Achieved Campaign Report') || ' - ' || rc_private.tgl_panjang(now());
  v_html := rc_private.email_na_html(v_isi->'rows', v_dari, v_sampai);

  select coalesce(mode_uji, false) and btrim(coalesce(email_uji, '')) <> '', btrim(coalesce(email_uji, ''))
    into v_modeuji, v_alamat from public.email_settings where jenis = 'pengajuan';
  v_modeuji := coalesce(v_modeuji, false) and coalesce(p_uji, '') = '';

  if coalesce(p_uji, '') <> '' or v_modeuji then
    v_spanduk := '<div style="font-family:Arial,Helvetica,sans-serif;background:#1f2937;color:#ffffff;padding:12px 16px;'
      || 'border-radius:8px;margin-bottom:12px;max-width:640px;"><div style="font-size:13px;font-weight:bold;margin-bottom:6px;">'
      || case when coalesce(p_uji, '') <> '' then 'TEST EMAIL' else 'MODE UJI' end || ' &mdash; surat ini TIDAK dikirim ke depot</div>'
      || '<div style="font-size:11px;line-height:1.7;color:#d1d5db;">Seharusnya dikirim ke<br>'
      || '<strong style="color:#ffffff;">TO</strong> (' || coalesce(array_length(v_to, 1), 0)::text || '): '
      || rc_private.html_aman(coalesce(nullif(array_to_string(v_to, ', '), ''), 'BELUM ADA ALAMAT')) || '<br>'
      || '<strong style="color:#ffffff;">CC</strong> (' || coalesce(array_length(v_cc, 1), 0)::text || '): '
      || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc, ', '), ''), 'tidak ada')) || '</div></div>';
    v_subjek := '[UJI] ' || v_subjek;
    v_to := array[case when coalesce(p_uji, '') <> '' then p_uji else v_alamat end];
    v_cc := '{}';
  end if;
  v_html := rc_private.email_outlook(v_spanduk || v_html);

  insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, status, galat, konteks)
  values ('notachieved', v_to, v_cc, v_subjek, v_html,
          case when not coalesce(p_kirim, false) then 'skipped'
               when coalesce(array_length(v_to, 1), 0) = 0 then 'skipped' else 'pending' end,
          case when coalesce(p_kirim, false) and coalesce(array_length(v_to, 1), 0) = 0 then 'Belum ada alamat TO' else '' end,
          jsonb_build_object('preview', not coalesce(p_kirim, false), 'uji', coalesce(p_uji, '') <> '', 'modeUji', v_modeuji,
                             'dari', v_dari, 'sampai', v_sampai, 'jumlah', v_n, 'region', v_isi->'region', 'depot', v_isi->'depot'))
  returning id into v_id;

  return jsonb_build_object('status', 'success', 'id', v_id, 'dikirim', coalesce(p_kirim, false),
    'dari', v_dari, 'sampai', v_sampai, 'jumlah', v_n, 'subjek', v_subjek,
    'penerima', jsonb_build_object('to', to_jsonb(v_to), 'cc', to_jsonb(v_cc)),
    'isiHtml', '<div style="font-family:Arial,sans-serif;font-size:12px;background:#f1f3f4;border:1px solid #dadce0;padding:8px 12px;margin:0 0 8px;">'
               || 'TO: ' || rc_private.html_aman(coalesce(nullif(array_to_string(v_to, ', '), ''), '-'))
               || ' &middot; CC: ' || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc, ', '), ''), '-')) || '</div>' || v_html,
    'message', case when coalesce(p_kirim, false)
      then 'Email Not Achieved (' || v_n || ' campaign) dimasukkan ke antrean'
           || case when coalesce(p_uji, '') <> '' then ' untuk ' || p_uji when v_modeuji then ' (MODE UJI ke ' || v_alamat || ')' else '' end || '.'
      else 'Pratinjau email Not Achieved (' || v_n || ' campaign). Tidak ada yang dikirim.' end);
end $f$;

-- ---- 6. Tambalan bertanda ---------------------------------------------------------------------
do $tambal$
declare src text;
begin
  -- rc_email_susun: jenis notachieved disusun tersendiri.
  src := replace(pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure), E'\r', '');
  if src !~ '20261163360000' then
    src := pg_temp.ganti(src,
      $p$  if v_jenis = 'kesehatan' then
    return rc_private.email_kesehatan_susun(v_set, coalesce(p_kirim, false), v_uji);
  end if;$p$,
      $p$  if v_jenis = 'kesehatan' then
    return rc_private.email_kesehatan_susun(v_set, coalesce(p_kirim, false), v_uji);
  end if;
  -- 20261163360000: rangkuman harian Not Achieved seluruh region.
  if v_jenis = 'notachieved' then
    return rc_private.email_na_susun(v_set, coalesce(p_kirim, false), v_uji);
  end if;$p$, 1, 'rc_email_susun notachieved');
    execute src;
  end if;

  -- email_perlu_pdf: pemberitahuan, tanpa lampiran PDF.
  src := replace(pg_get_functiondef('rc_private.email_perlu_pdf(text)'::regprocedure), E'\r', '');
  if src !~ '20261163360000' then
    src := pg_temp.ganti(src, $p$('weekly','pengajuan','kesehatan')$p$,
      $p$('weekly','pengajuan','kesehatan','notachieved' /* 20261163360000 */)$p$, 1, 'email_perlu_pdf notachieved');
    execute src;
  end if;

  -- rc_email_pengajuan_simpan: CC wajib jenis "notachieved" dapat disimpan dari tab Email Pengajuan.
  src := replace(pg_get_functiondef('public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text,jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261163360000' then
    if position($p$'debtor' /* 20261163170000 */];$p$ in src) > 0 then
      src := pg_temp.ganti(src, $p$'debtor' /* 20261163170000 */];$p$,
        $p$'debtor' /* 20261163170000 */,'notachieved' /* 20261163360000 */];$p$, 1, 'pengajuan_simpan notachieved');
    else
      src := pg_temp.ganti(src, $p$'amend','reprocess'];$p$,
        $p$'amend','reprocess','notachieved' /* 20261163360000 */];$p$, 1, 'pengajuan_simpan notachieved');
    end if;
    execute src;
  end if;
end $tambal$;

revoke all on function rc_private.email_na_batas(timestamptz), rc_private.email_na_jendela(timestamptz, boolean),
  rc_private.email_na_penerima(uuid[]), rc_private.email_na_isi(timestamptz, timestamptz),
  rc_private.email_na_html(jsonb, timestamptz, timestamptz), rc_private.email_na_susun(public.email_settings, boolean, text)
  from public, anon, authenticated;
