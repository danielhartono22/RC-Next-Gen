-- ==========================================================================================
-- Knowledge Base: "Opened", pernyataan dengan sanksi, detail No Surat, email reminder acknowledge
-- ==========================================================================================
-- Pemilik, 19 November 2026:
--   1. "untuk kata 'dibuka, belum acknoledge' ganti jadi 'opened'"
--   3. "ketika user klik di no suratnya otomatis akan muncul pop up modal dialog yang menjelaskan
--      detailnya" (frontend; daftar Resources membawa peserta dan wilayah)
--   4. "jika user belum acknowledge tiap hari ada email ke user ybs untuk acknoledge ... 'Berikut di
--      bawah ini surat yang belum dibaca dan ditandai acknoledge;' , lalu ada kolom no surat, nama
--      surat, tanggal keluar surat, dan di bawahnya 'Mohon untuk user ... segera menandai acknowledge
--      surat tersebut sebagai bukti bahwa kepala admin dan semua team depot sudah memahami dengan baik
--      dan menjalankan semuanya sesuai isi surat'"
--   5. Kalimat acknowledge ditambah "Saya siap menerima peringatan dan sanksi dari perusahaan ..."
--
-- * Email jenis 'kb' ("Reminder Acknowledge KB", Access Management > Email Otomatis): satu email per
--   akun yang punya dokumen belum di-acknowledge (versi yang berlaku), TO = Business Email akun itu,
--   CC = kolom CC jenis ini. Bawaan aktif pukul 08:00 WIB, Senin-Sabtu, dan tidak pada tanggal merah
--   (rc_private.hari_libur, 20261164060000). Satu email per akun per hari.
-- * Status "Dibuka, belum acknowledge" di Details menjadi "Opened".
-- Butuh 20261164040000 dan 20261164060000. Aman dijalankan berulang.
-- ==========================================================================================

do $pra$ begin
  if to_regclass('rc_private.hari_libur') is null or to_regclass('public.rc_kb_jenis') is null then
    raise exception 'DITOLAK: jalankan 20261164040000 dan 20261164060000 lebih dulu.'; end if;
end $pra$;

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $g$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $g$;

-- ---- 1. Kalimat acknowledge -----------------------------------------------------------------------
create or replace function rc_private.kb_pernyataan(p_jenis text) returns text
language sql immutable set search_path = '' as $f$
  -- 20261164070000: ditambah kesiapan menerima peringatan dan sanksi.
  select 'Saya sudah membaca dan memahami isi dari ' || btrim(coalesce(p_jenis, 'dokumen')) || ' tersebut, dan saya akan '
      || 'mengimplementasikannya sesuai dengan yang tertulis serta menyebarkannya kepada team yang belum mendapatkan '
      || 'informasi ini. Saya siap menerima peringatan dan sanksi dari perusahaan sebagai konsekuensi apabila sewaktu-waktu '
      || 'saya dan team saya terbukti tidak melaksanakan isi sesuai dengan ketentuan yang berlaku.';
$f$;

-- ---- 2. Details: "Opened"; Resources: peserta dan wilayah untuk popup No Surat ----------------------
do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('public.rc_kb_detail(uuid)'::regprocedure), E'\r', '');
  if src !~ '20261164070000' then
    src := pg_temp.ganti(src, $p$when a.dibuka then 'Dibuka, belum acknowledge'$p$,
      $p$when a.dibuka then 'Opened' /* 20261164070000 */$p$, 1, 'detail opened');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_kb_list()'::regprocedure), E'\r', '');
  if src !~ '20261164070000' then
    src := pg_temp.ganti(src, $p$             'pernyataan', rc_private.kb_pernyataan(i.jenis)) j$p$,
      $p$             'pernyataan', rc_private.kb_pernyataan(i.jenis),
             /* 20261164070000: detail No Surat */
             'pesertaTeks', (select string_agg(rc_private.kb_peran_label(r), ', ' order by o)
                               from unnest(rc_private.kb_peran_semua()) with ordinality z(r, o) where r = any(i.peserta)),
             'wilayah', rc_private.kb_wilayah_teks(i.regions, i.depot_ids)) j$p$, 1, 'list detail');
    execute src;
  end if;
end $tambal$;

-- ---- 3. Email reminder acknowledge -------------------------------------------------------------
alter table public.email_settings drop constraint if exists email_settings_jenis_check;
alter table public.email_settings add constraint email_settings_jenis_check
  check (jenis = any (array['daily','weekly','timetable','pengajuan','kesehatan','notachieved','compile','debtor','kb']));

insert into public.email_settings(jenis, aktif, jam, subjek, catatan, hari_list, cc_tambahan, tujuan)
values ('kb', true, 8, 'Reminder - Acknowledge Knowledge Base',
        'Reminder harian ke setiap akun yang punya dokumen Knowledge Base belum di-acknowledge (TO = Business Email akun; CC = kolom CC). Tidak dikirim pada tanggal merah (daftar di Peringatan Toko Lunas).',
        array[1, 2, 3, 4, 5, 6]::smallint[], '{}', '{}')
on conflict (jenis) do nothing;

create or replace function rc_private.email_kb_html(p_nama text, p_baris jsonb) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
  v_baris text; v_n integer;
begin
  select string_agg('<tr><td style="' || v_td || '" align="right">' || i::text || '.</td>'
      || '<td style="' || v_td || 'white-space:nowrap;font-weight:bold;">' || rc_private.html_aman(coalesce(nullif(x->>'no', ''), '-')) || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'judul')
      || '<div style="font-size:11px;color:#5f6368;">' || rc_private.html_aman(x->>'jenis') || '</div></td>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || coalesce(to_char((x->>'terbit')::date, 'DD-Mon-YYYY'), '-') || '</td></tr>', '' order by i),
         count(*)
    into v_baris, v_n from jsonb_array_elements(p_baris) with ordinality q(x, i);
  return rc_private.email_kepala('Reminder Acknowledge Knowledge Base', p_nama || '  |  ' || v_n::text || ' surat belum di-acknowledge')
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
    || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
    || '<p style="line-height:1.6;margin-top:0;">Dear ' || rc_private.html_aman(p_nama) || ',</p>'
    -- Kalimat pemilik, 19-Nov-2026.
    || '<p style="line-height:1.6;">Berikut di bawah ini surat yang belum dibaca dan ditandai acknowledge;</p>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin-top:12px;">'
    || '<thead><tr style="background:#f5f6f7;"><th align="right" style="' || v_th || '">NO</th>'
    || '<th align="left" style="' || v_th || '">NO SURAT</th><th align="left" style="' || v_th || '">NAMA SURAT</th>'
    || '<th align="left" style="' || v_th || '">TANGGAL KELUAR SURAT</th></tr></thead><tbody>' || coalesce(v_baris, '') || '</tbody></table>'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin-top:16px;">'
    || '<tr><td bgcolor="#FFF4CC" style="background-color:#FFF4CC;border-left:4px solid #C8102E;padding:12px 14px;font-size:13px;line-height:1.6;color:#202124;">'
    || 'Mohon untuk user <strong>' || rc_private.html_aman(p_nama) || '</strong> segera menandai acknowledge surat tersebut sebagai bukti bahwa '
    || 'kepala admin dan semua team depot sudah memahami dengan baik dan menjalankan semuanya sesuai isi surat.'
    || '</td></tr></table>'
    || '<p style="line-height:1.6;margin-top:14px;font-size:12px;color:#5f6368;">Buka RC &gt; Knowledge Base &gt; Knowledge Resources, klik <b>Buka Dokumen</b>, lalu tekan <b>Acknowledge</b>.</p>'
    || rc_private.email_ttd()
    || '</td></tr></table>';
end $f$;

create or replace function rc_private.email_kb_susun(p_set public.email_settings, p_kirim boolean, p_uji text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare u record; v_to text[]; v_cc text[]; v_html text; v_subjek text; v_id uuid; v_pertama uuid; v_tumpuk text := '';
  v_n integer := 0; v_surat integer := 0; v_dasar text := coalesce(nullif(btrim(p_set.subjek), ''), 'Reminder - Acknowledge Knowledge Base');
  v_kirim boolean := coalesce(p_kirim, false) and coalesce(p_uji, '') = '';
  v_awal timestamptz := date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta';
begin
  for u in
    select p.id, coalesce(nullif(btrim(p.full_name), ''), p.user_code) nama, lower(btrim(p.business_email)) email,
           jsonb_agg(jsonb_build_object('no', rc_private.kb_no_tampil(i.jenis, i.kode_dok, i.no_surat), 'judul', i.judul, 'jenis', i.jenis,
                     'terbit', coalesce(i.tgl_terbit, (i.created_at at time zone 'Asia/Jakarta')::date))
                     order by coalesce(i.tgl_terbit, (i.created_at at time zone 'Asia/Jakarta')::date) desc, i.judul) baris, count(*) n
      from rc_private.kb_pasangan(array(select id from public.rc_kb_items where archived_at is null)) q
      join public.profiles p on p.id = q.user_id
      join public.rc_kb_items i on i.id = q.item_id
     where not q.sudah and coalesce(btrim(p.business_email), '') like '%@%'
       and not (v_kirim and exists(select 1 from public.email_outbox e where e.jenis = 'kb' and e.dibuat_pada >= v_awal
                                     and e.konteks->>'user' = p.id::text and coalesce(e.konteks->>'uji', '') <> 'true'
                                     and coalesce(e.konteks->>'preview', '') <> 'true'))
     group by p.id, p.full_name, p.user_code, p.business_email order by p.user_code
  loop
    v_to := array[u.email];
    v_cc := coalesce(array(select distinct lower(btrim(x)) from unnest(coalesce(p_set.cc_tambahan, '{}')) x
                            where btrim(x) like '%@%' and lower(btrim(x)) <> u.email), '{}');
    v_html := rc_private.email_kb_html(u.nama, u.baris);
    v_subjek := v_dasar || ' - ' || u.nama || ' (' || u.n::text || ' surat)';
    v_n := v_n + 1; v_surat := v_surat + u.n;
    v_tumpuk := v_tumpuk
      || '<div style="font-family:Arial,sans-serif;font-size:12px;background:#f1f3f4;border:1px solid #dadce0;padding:8px 12px;margin:16px 0 8px;">'
      || '<b>' || rc_private.html_aman(v_subjek) || '</b><br>TO: ' || rc_private.html_aman(u.email)
      || ' &middot; CC: ' || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc, ', '), ''), '-')) || '</div>' || v_html;
    if v_kirim then
      insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, status, konteks)
      values ('kb', v_to, v_cc, v_subjek, rc_private.email_outlook(v_html), 'pending',
              jsonb_build_object('user', u.id, 'bagian', 'kb', 'jumlah', u.n, 'preview', false, 'uji', false))
      returning id into v_id;
      v_pertama := coalesce(v_pertama, v_id);
    end if;
  end loop;

  if v_n = 0 then
    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, galat, konteks)
    values ('kb', '{}', '(tidak dikirim)', '', 'skipped', 'Tidak ada akun dengan dokumen belum di-acknowledge (atau sudah dikirimi hari ini)',
            jsonb_build_object('preview', not coalesce(p_kirim, false), 'uji', coalesce(p_uji, '') <> ''))
    returning id into v_id;
    return jsonb_build_object('status', 'success', 'dikirim', false, 'id', v_id, 'jumlahEmail', 0,
      'isiHtml', '<p style="font-family:Arial,sans-serif;">Semua akun sudah acknowledge seluruh dokumen Knowledge Base (atau sudah dikirimi reminder hari ini).</p>',
      'message', 'Tidak ada reminder acknowledge yang perlu dikirim.');
  end if;

  if coalesce(p_uji, '') <> '' then
    insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, status, konteks)
    values ('kb', array[p_uji], '{}', '[UJI] ' || v_dasar || ' (' || v_n::text || ' email, ' || v_surat::text || ' surat)',
            rc_private.email_outlook('<div style="font-family:Arial,Helvetica,sans-serif;background:#1f2937;color:#ffffff;padding:12px 16px;border-radius:8px;margin-bottom:12px;max-width:640px;">'
              || '<div style="font-size:13px;font-weight:bold;">TEST EMAIL &mdash; ' || v_n::text || ' email reminder berikut TIDAK dikirim ke akunnya</div></div>' || v_tumpuk),
            case when coalesce(p_kirim, false) then 'pending' else 'skipped' end,
            jsonb_build_object('preview', false, 'uji', true, 'jumlah', v_n))
    returning id into v_pertama;
  elsif not coalesce(p_kirim, false) then
    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, konteks)
    values ('kb', '{}', '(pratinjau)', '', 'skipped', jsonb_build_object('preview', true, 'jumlah', v_n))
    returning id into v_pertama;
  end if;

  return jsonb_build_object('status', 'success', 'id', v_pertama, 'dikirim', coalesce(p_kirim, false), 'jumlahEmail', v_n, 'jumlahSurat', v_surat,
    'subjek', v_dasar || ' (' || v_n::text || ' email)', 'isiHtml', v_tumpuk,
    'message', case when coalesce(p_uji, '') <> '' then 'Test Email reminder (' || v_n || ' email) untuk ' || p_uji || '.'
                    when coalesce(p_kirim, false) then v_n || ' email reminder acknowledge dimasukkan ke antrean.'
                    else 'Pratinjau ' || v_n || ' email reminder acknowledge (' || v_surat || ' surat). Tidak ada yang dikirim.' end);
end $f$;

revoke all on function rc_private.email_kb_html(text, jsonb), rc_private.email_kb_susun(public.email_settings, boolean, text)
  from public, anon, authenticated;

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure), E'\r', '');
  if src !~ '20261164070000' then
    src := pg_temp.ganti(src, $p$  if v_jenis = 'debtor' then
    return rc_private.email_debtor_susun(v_set, coalesce(p_kirim, false), v_uji);
  end if;$p$,
      $p$  if v_jenis = 'debtor' then
    return rc_private.email_debtor_susun(v_set, coalesce(p_kirim, false), v_uji);
  end if;
  -- 20261164070000: reminder acknowledge Knowledge Base, satu email per akun.
  if v_jenis = 'kb' then
    return rc_private.email_kb_susun(v_set, coalesce(p_kirim, false), v_uji);
  end if;$p$, 1, 'susun kb');
    execute src;
  end if;

  src := replace(pg_get_functiondef('rc_private.email_perlu_pdf(text)'::regprocedure), E'\r', '');
  if src !~ '20261164070000' then
    src := pg_temp.ganti(src, $p$'debtor' /* 20261163670000 */)$p$, $p$'debtor' /* 20261163670000 */, 'kb' /* 20261164070000 */)$p$, 1, 'perlu_pdf kb');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_email_tick()'::regprocedure), E'\r', '');
  if src !~ '20261164070000' then
    src := pg_temp.ganti(src, $p$    if s.jam <> jam_lokal then continue; end if;$p$,
      $p$    if s.jam <> jam_lokal then continue; end if;
    -- 20261164070000: reminder acknowledge KB tidak dikirim pada tanggal merah.
    if s.jenis = 'kb' and rc_private.hari_libur_ini((sekarang at time zone 'Asia/Jakarta')::date) then continue; end if;$p$, 1, 'tick kb');
    execute src;
  end if;
end $tambal$;

do $cek$ begin
  if rc_private.kb_pernyataan('SOP') !~ 'sanksi dari perusahaan' then raise exception 'GAGAL: pernyataan'; end if;
  if pg_get_functiondef('public.rc_kb_detail(uuid)'::regprocedure) !~ '''Opened''' then raise exception 'GAGAL: detail'; end if;
  if pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure) !~ 'email_kb_susun' then raise exception 'GAGAL: susun'; end if;
  if rc_private.email_perlu_pdf('kb') then raise exception 'GAGAL: pdf'; end if;
  if pg_get_functiondef('public.rc_email_tick()'::regprocedure) !~ 's.jenis = ''kb''' then raise exception 'GAGAL: tick'; end if;
end $cek$;
