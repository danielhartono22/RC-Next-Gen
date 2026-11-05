-- ==========================================================================================
-- Email otomatis berjenjang: toko lunas (ZDAGE) yang belum diproses depot
-- ==========================================================================================
-- Pemilik, 4 November 2026: "email otomatis ke depot disertai toko toko nya di body email dengan
-- detail kolom, nama toko, nama campaign, net cb, tanggal lunas, deadline. dan email berjenjang,
-- yg pertama waktunya 14 hari (kalo bisa fleksibel kita tentukan juga). yg cc kedua maks 21 hari
-- (ini juga bisa ditentukan juga) yang ketiga 28 hari (sama bisa ditentukan juga). Jadi di email
-- otomatis buat 3 cc aja sementara to nya tetep sama dan samping cc untuk harinya."
--
-- * Jenis email terjadwal baru 'debtor' ("Peringatan Toko Lunas", Access Management > Email
--   Otomatis), tiap hari jam 08:00, aktif. Panel memuat 3 jenjang: hari ke-N (bawaan 14 / 21 /
--   28) dan CC masing-masing. TO tetap Email TO depot (Depot Master); CC = Email CC depot + CC
--   jenjang itu.
-- * Hari dihitung sejak toko dinyatakan lunas di RC (rc_clearing_offers.offered_at, WIB) -
--   pilihan pemilik. Yang dihitung: tawaran aktif (offered / overdue) dengan dokumen masih Not Yet,
--   tanpa pengajuan yang menunggu, tidak diarsip.
-- * Setiap toko (tawaran) diperingatkan SEKALI per jenjang. Bila saat diperiksa toko sudah melewati
--   beberapa jenjang sekaligus, hanya jenjang tertinggi yang dikirim (jenjang di bawahnya ikut
--   ditandai). Satu email per depot per jenjang, berisi toko yang baru mencapai jenjang itu.
--   Kolom: No, Nama Toko, Nama Campaign, Net CB, Tanggal Lunas (claims.paid_on), Deadline
--   (batas proses tawaran), lalu Total.
-- * Hanya saat saklar ZDAGE Integration HIDUP (20261163620000).
-- * Menggantikan email peringatan harian lama (zdage_email_peringatan dari job ZDAGE, di bawah
--   saklar Email Pengajuan): job harian tetap menandai overdue, tetapi tidak lagi mengirim email.
-- * Pratinjau: seluruh email yang akan berangkat, ditumpuk. Test Email: satu email ke alamat uji
--   berisi seluruh tumpukan itu; tidak menandai toko. Kirim Manual / terjadwal: menandai toko.
-- Butuh 20261163170000 (ZDAGE), 20261163610000, 20261163620000. Aman dijalankan berulang.
-- ==========================================================================================

do $pra$ begin
  if to_regclass('public.rc_clearing_offers') is null or to_regprocedure('rc_private.zdage_aktif()') is null
     or not exists (select 1 from public.email_settings where jenis = 'compile') then
    raise exception 'DITOLAK: jalankan 20261163170000, 20261163610000 dan 20261163620000 lebih dulu.'; end if;
end $pra$;

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- 1. Jenis email dan jenjang ----------------------------------------------------------------
alter table public.email_settings drop constraint if exists email_settings_jenis_check;
alter table public.email_settings add constraint email_settings_jenis_check
  check (jenis = any (array['daily','weekly','timetable','pengajuan','kesehatan','notachieved','compile','debtor']));
alter table public.email_settings add column if not exists jenjang jsonb;

insert into public.email_settings(jenis, aktif, jam, subjek, catatan, hari_list, cc_tambahan, tujuan, jenjang)
values ('debtor', true, 8, 'Warning - Toko Lunas Belum Diproses',
        'Peringatan berjenjang toko lunas (ZDAGE) yang belum diproses depot, dihitung sejak toko lunas di RC. TO = Email TO depot; CC = Email CC depot + CC jenjang.',
        null, '{}', '{}',
        '[{"hari":14,"cc":[]},{"hari":21,"cc":[]},{"hari":28,"cc":[]}]'::jsonb)
on conflict (jenis) do nothing;

create table if not exists rc_private.debtor_peringatan(
  offer_id uuid not null references public.rc_clearing_offers(id) on delete cascade,
  tingkat smallint not null check (tingkat between 1 and 3),
  dikirim_pada timestamptz not null default now(),
  outbox_id uuid,
  primary key (offer_id, tingkat)
);
revoke all on rc_private.debtor_peringatan from public, anon, authenticated;

-- Jenjang tersimpan, selalu 3 baris {hari, cc[]} berurutan.
create or replace function rc_private.debtor_jenjang() returns jsonb
language sql stable security definer set search_path = '' as $f$
  select coalesce((select jenjang from public.email_settings where jenis = 'debtor'),
                  '[{"hari":14,"cc":[]},{"hari":21,"cc":[]},{"hari":28,"cc":[]}]'::jsonb);
$f$;

-- ---- 2. Siapa yang jatuh tempo ------------------------------------------------------------------
-- Satu baris per tawaran yang baru mencapai jenjang (tingkat = jenjang tertinggi yang dicapai).
create or replace function rc_private.debtor_jatuh_tempo() returns table(
  offer_id uuid, depot_id uuid, tingkat smallint, umur integer, toko text, campaign text, cb_net numeric, tgl_lunas date, deadline date)
language sql stable security definer set search_path = '' as $f$
  with j as (select rc_private.debtor_jenjang() v),
  h as (select (v->0->>'hari')::int h1, (v->1->>'hari')::int h2, (v->2->>'hari')::int h3 from j),
  o as (
    select o.id, c.depot_id, c.cb_net, c.paid_on, (o.deadline_at at time zone 'Asia/Jakarta')::date deadline,
           ((now() at time zone 'Asia/Jakarta')::date - (o.offered_at at time zone 'Asia/Jakarta')::date) umur,
           case when nullif(btrim(cu.customer_name), '') is null then coalesce(cu.customer_code, '-')
                else btrim(cu.customer_name) || coalesce(' (' || cu.customer_code || ')', '') end toko,
           coalesce(nullif(btrim(ca.campaign_name), ''), ca.campaign_code, '-') campaign,
           (select max(p.tingkat) from rc_private.debtor_peringatan p where p.offer_id = o.id) sudah
      from public.rc_clearing_offers o
      join public.claims c on c.id = o.claim_id
      join public.depots d on d.id = c.depot_id and d.archived_at is null
      left join public.customers cu on cu.id = c.customer_id
      left join public.campaigns ca on ca.id = c.campaign_id
     where o.status in ('offered', 'overdue') and o.offered_at is not null
       and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null),
  t as (select o.*, (case when o.umur >= h.h3 then 3 when o.umur >= h.h2 then 2 when o.umur >= h.h1 then 1 else 0 end)::smallint tk from o, h)
  select t.id, t.depot_id, t.tk, t.umur, t.toko, t.campaign, t.cb_net, t.paid_on, t.deadline
    from t where t.tk > 0 and t.tk > coalesce(t.sudah, 0);
$f$;

-- ---- 3. Satu email (depot x jenjang) --------------------------------------------------------------
create or replace function rc_private.debtor_email_html(p_depot uuid, p_tingkat smallint, p_hari integer, p_baris jsonb) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
  v_nama text; v_kode text; v_baris text; v_total numeric; v_n integer;
begin
  select coalesce(nullif(depot_name, ''), depot_code), depot_code into v_nama, v_kode from public.depots where id = p_depot;
  select string_agg('<tr><td style="' || v_td || '" align="right">' || i::text || '.</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'toko') || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'campaign') || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;" align="right">' || rc_private.rupiah((x->>'cb')::numeric) || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || coalesce(to_char((x->>'lunas')::date, 'DD-Mon-YYYY'), '-') || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;color:#C8102E;font-weight:bold;">' || coalesce(to_char((x->>'deadline')::date, 'DD-Mon-YYYY'), '-') || '</td></tr>', '' order by i),
         sum((x->>'cb')::numeric), count(*)
    into v_baris, v_total, v_n from jsonb_array_elements(p_baris) with ordinality q(x, i);

  return rc_private.email_kepala('Warning Jenjang ' || p_tingkat::text || ' – Toko lunas belum diproses',
           'Depo ' || v_nama || '  |  ' || v_n::text || ' toko  |  lunas ' || p_hari::text || ' hari atau lebih')
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
    || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
    || '<p style="line-height:1.6;margin-top:0;">Dear All,</p>'
    || '<p style="line-height:1.6;">Berikut toko di Depo <strong>' || rc_private.html_aman(v_kode || ' - ' || v_nama)
    || '</strong> yang sudah lunas menurut data debtor (ZDAGE) sejak <strong>' || p_hari::text || ' hari atau lebih</strong>, '
    || 'tetapi klaimnya belum diproses di Claim Upload (peringatan jenjang ' || p_tingkat::text || ' dari 3).</p>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin-top:12px;">'
    || '<thead><tr style="background:#f5f6f7;"><th align="right" style="' || v_th || '">NO</th>'
    || '<th align="left" style="' || v_th || '">NAMA TOKO</th><th align="left" style="' || v_th || '">NAMA CAMPAIGN</th>'
    || '<th align="right" style="' || v_th || '">NET CB</th><th align="left" style="' || v_th || '">TANGGAL LUNAS</th>'
    || '<th align="left" style="' || v_th || '">DEADLINE</th></tr></thead><tbody>' || coalesce(v_baris, '') || '</tbody>'
    || '<tfoot><tr style="background:#fdecef;"><td colspan="3" style="padding:10px;font-size:12px;font-weight:bold;color:#C8102E;">TOTAL ' || v_n::text || ' TOKO</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;white-space:nowrap;">' || rc_private.rupiah(v_total) || '</td>'
    || '<td colspan="2"></td></tr></tfoot></table>'
    || '<p style="line-height:1.6;margin-top:16px;">Mohon management segera mendorong tim depo untuk memproses semua toko-toko yang sudah lunas di atas segera agar tidak ada complaint dari toko dan meningkatkan performance sales toko yang bersangkutan.</p>'
    || rc_private.email_ttd()
    || '</td></tr></table>';
end $f$;

-- ---- 4. Susun --------------------------------------------------------------------------------
create or replace function rc_private.email_debtor_susun(p_set public.email_settings, p_kirim boolean, p_uji text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  v_jj jsonb := rc_private.debtor_jenjang(); g record; v_to text[]; v_cc text[]; v_html text; v_subjek text; v_id uuid; v_pertama uuid;
  v_tumpuk text := ''; v_n integer := 0; v_toko integer := 0; v_hari integer; v_jjcc text[];
begin
  if not rc_private.zdage_aktif() then
    return jsonb_build_object('status', 'success', 'dikirim', false,
      'isiHtml', '<p style="font-family:Arial,sans-serif;">ZDAGE Integration mati (Access Management &gt; On/Off Sistem); peringatan toko lunas tidak disusun.</p>',
      'message', 'ZDAGE Integration mati; peringatan toko lunas tidak disusun.');
  end if;

  for g in
    select j.depot_id, j.tingkat, jsonb_agg(jsonb_build_object('offer', j.offer_id, 'toko', j.toko, 'campaign', j.campaign, 'cb', j.cb_net,
             'lunas', j.tgl_lunas, 'deadline', j.deadline) order by j.campaign, j.toko) baris, count(*) n
      from rc_private.debtor_jatuh_tempo() j join public.depots d on d.id = j.depot_id
     group by j.depot_id, j.tingkat, d.depot_code order by d.depot_code, j.tingkat
  loop
    v_hari := (v_jj->(g.tingkat - 1)->>'hari')::int;
    v_jjcc := coalesce(array(select jsonb_array_elements_text(coalesce(v_jj->(g.tingkat - 1)->'cc', '[]'))), '{}');
    select array(select distinct lower(btrim(x)) from unnest(rc_private.pecah_email(d.email_to)) x where btrim(x) like '%@%')
      into v_to from public.depots d where d.id = g.depot_id;
    select array(select distinct a from (
              select lower(btrim(x)) a from public.depots d, unnest(rc_private.pecah_email(d.email_cc)) x where d.id = g.depot_id
              union all select lower(btrim(y)) from unnest(v_jjcc) y) s
            where a like '%@%' and not (a = any(v_to))) into v_cc;
    v_html := rc_private.debtor_email_html(g.depot_id, g.tingkat, v_hari, g.baris);
    v_subjek := coalesce(nullif(btrim(p_set.subjek), ''), 'Warning - Toko Lunas Belum Diproses') || ' - Jenjang ' || g.tingkat::text
             || ' (' || v_hari::text || ' hari) - ' || (select coalesce(nullif(depot_name, ''), depot_code) from public.depots where id = g.depot_id);
    v_n := v_n + 1; v_toko := v_toko + g.n;
    v_tumpuk := v_tumpuk
      || '<div style="font-family:Arial,sans-serif;font-size:12px;background:#f1f3f4;border:1px solid #dadce0;padding:8px 12px;margin:16px 0 8px;">'
      || '<b>' || rc_private.html_aman(v_subjek) || '</b><br>TO: ' || rc_private.html_aman(coalesce(nullif(array_to_string(v_to, ', '), ''), 'BELUM ADA ALAMAT TO DI DEPOT MASTER'))
      || ' &middot; CC: ' || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc, ', '), ''), '-')) || '</div>' || v_html;

    -- Kirim sungguhan (terjadwal / Kirim Manual): satu email per depot x jenjang; tokonya ditandai.
    if coalesce(p_kirim, false) and coalesce(p_uji, '') = '' then
      insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, status, galat, konteks)
      values ('debtor', v_to, v_cc, v_subjek, rc_private.email_outlook(v_html),
        case when coalesce(array_length(v_to, 1), 0) = 0 then 'skipped' else 'pending' end,
        case when coalesce(array_length(v_to, 1), 0) = 0 then 'Belum ada alamat TO pada master depot' else '' end,
        jsonb_build_object('depot', g.depot_id, 'tingkat', g.tingkat, 'hari', v_hari, 'jumlah', g.n, 'preview', false, 'uji', false))
      returning id into v_id;
      if coalesce(array_length(v_to, 1), 0) > 0 then
        v_pertama := coalesce(v_pertama, v_id);
        insert into rc_private.debtor_peringatan(offer_id, tingkat, outbox_id)
        select (x->>'offer')::uuid, t.t::smallint, v_id from jsonb_array_elements(g.baris) x, generate_series(1, g.tingkat) t(t)
        on conflict do nothing;
      end if;
    end if;
  end loop;

  if v_n = 0 then
    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, galat, konteks)
    values ('debtor', '{}', '(tidak dikirim)', '', 'skipped', 'Tidak ada toko lunas yang mencapai jenjang peringatan',
            jsonb_build_object('preview', not coalesce(p_kirim, false), 'uji', coalesce(p_uji, '') <> ''))
    returning id into v_id;
    return jsonb_build_object('status', 'success', 'dikirim', false, 'id', v_id,
      'isiHtml', '<p style="font-family:Arial,sans-serif;">Tidak ada toko lunas yang baru mencapai jenjang peringatan (hari ke-'
                 || (v_jj->0->>'hari') || ' / ' || (v_jj->1->>'hari') || ' / ' || (v_jj->2->>'hari') || ').</p>',
      'message', 'Tidak ada toko lunas yang baru mencapai jenjang peringatan; email tidak disusun.');
  end if;

  if coalesce(p_uji, '') <> '' then
    insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, status, konteks)
    values ('debtor', array[p_uji], '{}', '[UJI] ' || coalesce(nullif(btrim(p_set.subjek), ''), 'Warning - Toko Lunas Belum Diproses')
              || ' (' || v_n::text || ' email, ' || v_toko::text || ' toko)',
            rc_private.email_outlook('<div style="font-family:Arial,Helvetica,sans-serif;background:#1f2937;color:#ffffff;padding:12px 16px;border-radius:8px;margin-bottom:12px;max-width:640px;">'
              || '<div style="font-size:13px;font-weight:bold;">TEST EMAIL &mdash; ' || v_n::text || ' email peringatan berikut TIDAK dikirim ke depot dan tokonya tidak ditandai</div></div>' || v_tumpuk),
            case when coalesce(p_kirim, false) then 'pending' else 'skipped' end,
            jsonb_build_object('preview', false, 'uji', true, 'jumlah', v_n))
    returning id into v_pertama;
  elsif not coalesce(p_kirim, false) then
    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, konteks)
    values ('debtor', '{}', '(pratinjau)', '', 'skipped', jsonb_build_object('preview', true, 'jumlah', v_n))
    returning id into v_pertama;
  end if;

  return jsonb_build_object('status', 'success', 'id', v_pertama, 'dikirim', coalesce(p_kirim, false), 'jumlahEmail', v_n, 'jumlahToko', v_toko,
    'subjek', coalesce(nullif(btrim(p_set.subjek), ''), 'Warning - Toko Lunas Belum Diproses') || ' (' || v_n::text || ' email)',
    'isiHtml', v_tumpuk,
    'message', case when coalesce(p_uji, '') <> '' then 'Test Email peringatan (' || v_n || ' email, ' || v_toko || ' toko) untuk ' || p_uji || '.'
                    when coalesce(p_kirim, false) then v_n || ' email peringatan (' || v_toko || ' toko) dimasukkan ke antrean.'
                    else 'Pratinjau ' || v_n || ' email peringatan (' || v_toko || ' toko). Tidak ada yang dikirim.' end);
end $f$;

revoke all on function rc_private.debtor_jenjang(), rc_private.debtor_jatuh_tempo(),
  rc_private.debtor_email_html(uuid, smallint, integer, jsonb), rc_private.email_debtor_susun(public.email_settings, boolean, text)
  from public, anon, authenticated;

-- ---- 5. Tambalan bertanda ---------------------------------------------------------------------
do $tambal$
declare src text;
begin
  -- rc_email_susun: jenis debtor disusun tersendiri.
  src := replace(pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure), E'\r', '');
  if src !~ '20261163670000' then
    src := pg_temp.ganti(src,
      $p$  if v_jenis = 'notachieved' then
    return rc_private.email_na_susun(v_set, coalesce(p_kirim, false), v_uji);
  end if;$p$,
      $p$  if v_jenis = 'notachieved' then
    return rc_private.email_na_susun(v_set, coalesce(p_kirim, false), v_uji);
  end if;
  -- 20261163670000: peringatan berjenjang toko lunas (ZDAGE), satu email per depot x jenjang.
  if v_jenis = 'debtor' then
    return rc_private.email_debtor_susun(v_set, coalesce(p_kirim, false), v_uji);
  end if;$p$, 1, 'susun debtor');
    execute src;
  end if;

  -- Tanpa lampiran PDF: seluruh isinya ada di badan surat.
  src := replace(pg_get_functiondef('rc_private.email_perlu_pdf(text)'::regprocedure), E'\r', '');
  if src !~ '20261163670000' then
    src := pg_temp.ganti(src, $p$'notachieved' /* 20261163360000 */)$p$,
      $p$'notachieved' /* 20261163360000 */, 'debtor' /* 20261163670000 */)$p$, 1, 'perlu_pdf');
    execute src;
  end if;

  -- Job harian ZDAGE tidak lagi mengirim email peringatan lama.
  src := replace(pg_get_functiondef('rc_private.zdage_harian()'::regprocedure), E'\r', '');
  if src !~ '20261163670000' then
    src := pg_temp.ganti(src, $p$    v_email := rc_private.zdage_email_peringatan(false);$p$,
      $p$    v_email := 0; -- 20261163670000: diganti email berjenjang jenis 'debtor' (Email Otomatis)$p$, 1, 'zdage_harian');
    execute src;
  end if;

  -- Panel: jenjang tampil untuk 'debtor'; CC tambahan umum tidak dipakai jenis ini.
  src := replace(pg_get_functiondef('public.rc_email_status()'::regprocedure), E'\r', '');
  if src !~ '20261163670000' then
    src := pg_temp.ganti(src,
      $p$'cc',to_jsonb(coalesce(cc_tambahan,'{}'::text[])) /* 20261163370000: CC tambahan semua jadwal */,$p$,
      $p$'cc',case when jenis = 'debtor' then null else to_jsonb(coalesce(cc_tambahan,'{}'::text[])) end /* 20261163370000; 20261163670000 */,
        'jenjang',case when jenis = 'debtor' then rc_private.debtor_jenjang() end,$p$, 1, 'status');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_email_settings_simpan(jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261163670000' then
    src := pg_temp.ganti(src,
      $p$    -- 20261163370000: CC tambahan jadwal lain (daily, weekly, timetable, notachieved).$p$,
      $p$    -- 20261163670000: jenjang peringatan toko lunas - 3 baris {hari, cc}, hari naik, 1..365.
    if lower(btrim(r->>'jenis')) = 'debtor' and r ? 'jenjang' then
      perform rc_private.debtor_jenjang_simpan(r->'jenjang');
    end if;
    -- 20261163370000: CC tambahan jadwal lain (daily, weekly, timetable, notachieved).$p$, 1, 'simpan');
    execute src;
  end if;
end $tambal$;

-- Dipanggil rc_email_settings_simpan (dibuat sesudahnya karena plpgsql baru menyelesaikan nama saat jalan).
create or replace function rc_private.debtor_jenjang_simpan(p jsonb) returns void
language plpgsql security definer set search_path = '' as $f$
declare v jsonb := '[]'; i integer; h integer; h_lalu integer := 0;
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) <> 3 then
    raise exception 'Jenjang peringatan harus tepat 3 baris'; end if;
  for i in 0..2 loop
    begin h := (p->i->>'hari')::int; exception when others then h := null; end;
    if h is null or h < 1 or h > 365 then raise exception 'Hari jenjang % harus angka 1 sampai 365', i + 1; end if;
    if h <= h_lalu then raise exception 'Hari jenjang % harus lebih besar dari jenjang sebelumnya (%)', i + 1, h_lalu; end if;
    v := v || jsonb_build_array(jsonb_build_object('hari', h, 'cc', to_jsonb(rc_private.email_cc_tambahan(p->i->'cc'))));
    h_lalu := h;
  end loop;
  update public.email_settings set jenjang = v where jenis = 'debtor';
end $f$;
revoke all on function rc_private.debtor_jenjang_simpan(jsonb) from public, anon, authenticated;

do $cek$ begin
  if pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure) !~ 'email_debtor_susun' then raise exception 'GAGAL: susun'; end if;
  if pg_get_functiondef('rc_private.zdage_harian()'::regprocedure) ~ 'zdage_email_peringatan\(' then raise exception 'GAGAL: zdage_harian'; end if;
  if rc_private.email_perlu_pdf('debtor') then raise exception 'GAGAL: perlu_pdf'; end if;
  raise notice 'Email berjenjang toko lunas terpasang.';
end $cek$;
