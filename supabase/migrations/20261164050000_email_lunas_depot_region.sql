-- ==========================================================================================
-- Warning - Toko Lunas Belum Diproses Depot: email depot + email ringkasan per region
-- ==========================================================================================
-- Pemilik, 18 November 2026:
--   "buat email terpisah agar tidak spam: email cukup ke kepala admin, npc dan kadep masing-masing
--    yakni email yang sekarang ini berlaku dimana ditampilkan detail toko + tambahin 1 kolom lewat
--    berapa hari. sementara email ke rsm, asm, osc dan cc cukup 1 per region. 1. cukup ada kolom
--    kode depot-nama depot, jumlah campaign, total qty toko, net value nya dan kolom lewat berapa
--    hari dari hari terlama, PIC (ini kepala admin) namanya."
--   Kalimat sorotan: "mohon team depot dan managemen dapat follow up ke Kepala Admin ...".
--   "tidak perlu ada jenjang per jenjang, jenjang cukup untuk menentukan kapan dikirim kembali
--    emailnya dengan waktu dan cc orang yang beda. dan tidak boleh ada double email ... misal
--    jenjang 1 dan jenjang 2 bersamaan maka cukup masuk jenjang 2"
--   "email yg ke rsm asm cc itu juga masukan kadep dan kepala adminnya juga ya"
--
-- * Toko yang dihitung tetap rc_private.debtor_jatuh_tempo(): tawaran yang BARU mencapai jenjang
--   (hari sejak lunas di RC >= hari jenjang), masing-masing hanya pada jenjang tertinggi yang
--   dicapai; jenjang di bawahnya ikut ditandai, sehingga satu toko tidak pernah diperingatkan dua
--   kali untuk jenjang yang sama.
-- Lanjutan 18-Nov: "yang ke depot setiap 2 hari dan ganti gantian 50% depot ... dalam 1 region
--   diusahakan sama. rsm asm management dan cc sesuai jenjang dan hari ditentukan dari access
--   management ... tidak boleh ada 2 report yg sama meski beda jenjang" -> lihat bagian 3 dan 4.
-- * Email depot: SATU per depot per pengiriman, setiap 2 hari (kelompok A / B), tanpa jenjang.
--     TO = Email Kepala Admin + Email NPC + Email Kepala Depot (Depot Profile); cadangan Email
--     Depot (TO) lama. CC = kolom CC jenis ini di Email Otomatis (bawaan <cc-osc>@<domain-perusahaan>).
--     Kolom: No, Nama Toko, Nama Campaign, Net CB, Tanggal Lunas, Lewat (hari), Deadline.
-- * Email region: SATU per region per pengiriman, ringkasan depot di region itu.
--     TO = Email RSM + Email ASM depot-depotnya.
--     CC = OSC aktif yang memegang depot-depot itu + Kepala Depot + Kepala Admin depot-depot itu
--          + CC jenjang tertinggi yang tercapai di region itu (panel Email Otomatis).
--     Kolom: Depot (kode - nama), Jumlah Campaign, Total Toko, Net Value, Lewat (hari) terlama,
--            PIC (nama Kepala Admin), lalu Total.
-- * Kedua email memuat kalimat sorotan pemilik.
-- * Toko ditandai saat dikirim sungguhan (terjadwal / Kirim Manual), juga bila alamat TO depot
--   kosong (email dicatat skipped), supaya email region tidak berulang esok harinya.
-- Menggantikan isi rc_private.email_debtor_susun dari 20261163670000. Aman dijalankan berulang.
-- ==========================================================================================

-- ---- 1. Email depot ---------------------------------------------------------------------------
create or replace function rc_private.debtor_sorotan() returns text
language sql immutable set search_path = '' as $f$
  select '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin-top:16px;">'
      || '<tr><td bgcolor="#FFF4CC" style="background-color:#FFF4CC;border-left:4px solid #C8102E;padding:12px 14px;font-family:Arial,Helvetica,sans-serif;font-size:13px;line-height:1.6;color:#202124;">'
      || '<strong style="color:#C8102E;">Mohon team depot dan management dapat follow up ke Kepala Admin untuk segera memproses yang sudah lunas</strong>, '
      || 'karena sistem akan <strong>otomatis melakukan expiring jika dalam waktu H+30 hari toko lunas belum diproses / justifikasi</strong>, '
      || 'sehingga <strong style="color:#C8102E;">cashback tidak dapat di-claim kembali karena statusnya sudah Expired</strong>.'
      || '</td></tr></table>';
$f$;

create or replace function rc_private.debtor_email_depot_html(p_depot uuid, p_baris jsonb) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
  v_nama text; v_kode text; v_baris text; v_total numeric; v_n integer; v_lama integer;
begin
  select coalesce(nullif(depot_name, ''), depot_code), depot_code into v_nama, v_kode from public.depots where id = p_depot;
  select string_agg('<tr><td style="' || v_td || '" align="right">' || i::text || '.</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'toko') || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(x->>'campaign') || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;" align="right">' || rc_private.rupiah((x->>'cb')::numeric) || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || coalesce(to_char((x->>'lunas')::date, 'DD-Mon-YYYY'), '-') || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;font-weight:bold;" align="center">' || (x->>'umur') || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;color:#C8102E;font-weight:bold;">' || coalesce(to_char((x->>'deadline')::date, 'DD-Mon-YYYY'), '-') || '</td></tr>', '' order by i),
         sum((x->>'cb')::numeric), count(*), max((x->>'umur')::int)
    into v_baris, v_total, v_n, v_lama from jsonb_array_elements(p_baris) with ordinality q(x, i);

  return rc_private.email_kepala('Warning – Toko lunas belum diproses',
           'Depo ' || v_nama || '  |  ' || v_n::text || ' toko  |  terlama ' || v_lama::text || ' hari')
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
    || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
    || '<p style="line-height:1.6;margin-top:0;">Dear Team Depo,</p>'
    || '<p style="line-height:1.6;">Berikut toko di Depo <strong>' || rc_private.html_aman(v_kode || ' - ' || v_nama)
    || '</strong> yang sudah lunas menurut data debtor (ZDAGE), tetapi klaimnya belum diproses di Claim Upload. '
    || 'Kolom <strong>Lewat</strong> = jumlah hari sejak toko dinyatakan lunas di RC.</p>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin-top:12px;">'
    || '<thead><tr style="background:#f5f6f7;"><th align="right" style="' || v_th || '">NO</th>'
    || '<th align="left" style="' || v_th || '">NAMA TOKO</th><th align="left" style="' || v_th || '">NAMA CAMPAIGN</th>'
    || '<th align="right" style="' || v_th || '">NET CB</th><th align="left" style="' || v_th || '">TANGGAL LUNAS</th>'
    || '<th align="center" style="' || v_th || '">LEWAT (HARI)</th>'
    || '<th align="left" style="' || v_th || '">DEADLINE</th></tr></thead><tbody>' || coalesce(v_baris, '') || '</tbody>'
    || '<tfoot><tr style="background:#fdecef;"><td colspan="3" style="padding:10px;font-size:12px;font-weight:bold;color:#C8102E;">TOTAL ' || v_n::text || ' TOKO</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;white-space:nowrap;">' || rc_private.rupiah(v_total) || '</td>'
    || '<td colspan="3"></td></tr></tfoot></table>'
    || rc_private.debtor_sorotan()
    || rc_private.email_ttd()
    || '</td></tr></table>';
end $f$;

-- ---- 2. Email region --------------------------------------------------------------------------
-- p_baris: satu objek per depot {kode, nama, region, campaign, toko, net, umur, pic}.
-- p_region = 'SEMUA REGION': laporan nasional jenjang 3 (kolom Region ikut tampil).
create or replace function rc_private.debtor_email_region_html(p_region text, p_baris jsonb) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
  v_baris text; v_net numeric; v_toko integer; v_camp integer; v_depot integer; v_lama integer;
  v_nas boolean := p_region = 'SEMUA REGION'; v_h3 text := rc_private.debtor_jenjang()->2->>'hari';
begin
  select string_agg('<tr><td style="' || v_td || '" align="right">' || i::text || '.</td>'
      || case when v_nas then '<td style="' || v_td || 'white-space:nowrap;"><strong>' || rc_private.html_aman(coalesce(x->>'region', '-')) || '</strong></td>' else '' end
      || '<td style="' || v_td || '"><strong>' || rc_private.html_aman(x->>'kode') || '</strong> - ' || rc_private.html_aman(x->>'nama') || '</td>'
      || '<td style="' || v_td || '" align="center">' || (x->>'campaign') || '</td>'
      || '<td style="' || v_td || '" align="center">' || (x->>'toko') || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;" align="right">' || rc_private.rupiah((x->>'net')::numeric) || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;color:#C8102E;font-weight:bold;" align="center">' || (x->>'umur') || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(coalesce(nullif(x->>'pic', ''), '-')) || '</td></tr>', '' order by i),
         sum((x->>'net')::numeric), sum((x->>'toko')::int), sum((x->>'campaign')::int), count(*), max((x->>'umur')::int)
    into v_baris, v_net, v_toko, v_camp, v_depot, v_lama from jsonb_array_elements(p_baris) with ordinality q(x, i);

  return rc_private.email_kepala('Warning – Toko lunas belum diproses',
           case when v_nas then 'Semua Region' else 'Region ' || p_region end || '  |  ' || v_depot::text || ' depo  |  ' || v_toko::text || ' toko  |  terlama ' || v_lama::text || ' hari')
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
    || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
    || '<p style="line-height:1.6;margin-top:0;">Dear All,</p>'
    -- Kalimat pemilik, 18-Nov-2026.
    || '<p style="line-height:1.6;">Berikut summary toko yang sudah lunas berdasarkan data ZDAGE tetapi sampai saat ini belum diproses oleh team depo. '
    || 'Details per toko sudah dikirimkan ke team depo (Kepala Depo, Kepala Admin dan Admin), di bawah ini summary nya ('
    || case when v_nas then 'seluruh region, toko yang lewat <strong>' || v_h3 || ' hari atau lebih</strong>'
            else 'Region <strong>' || rc_private.html_aman(p_region) || '</strong>' end || '):</p>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin-top:12px;">'
    || '<thead><tr style="background:#f5f6f7;"><th align="right" style="' || v_th || '">NO</th>'
    || case when v_nas then '<th align="left" style="' || v_th || '">REGION</th>' else '' end
    || '<th align="left" style="' || v_th || '">DEPO</th><th align="center" style="' || v_th || '">JUMLAH CAMPAIGN</th>'
    || '<th align="center" style="' || v_th || '">TOTAL TOKO</th><th align="right" style="' || v_th || '">NET VALUE</th>'
    || '<th align="center" style="' || v_th || '">LEWAT (HARI)<br>TERLAMA</th><th align="left" style="' || v_th || '">PIC (KEPALA ADMIN)</th></tr></thead>'
    || '<tbody>' || coalesce(v_baris, '') || '</tbody>'
    || '<tfoot><tr style="background:#fdecef;"><td colspan="' || case when v_nas then '3' else '2' end || '" style="padding:10px;font-size:12px;font-weight:bold;color:#C8102E;">TOTAL ' || v_depot::text || ' DEPO</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;color:#C8102E;" align="center">' || v_camp::text || '</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;color:#C8102E;" align="center">' || v_toko::text || '</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;white-space:nowrap;">' || rc_private.rupiah(v_net) || '</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;color:#C8102E;" align="center">' || v_lama::text || '</td><td></td></tr></tfoot></table>'
    || rc_private.debtor_sorotan()
    || rc_private.email_ttd()
    || '</td></tr></table>';
end $f$;

-- ---- 3. Kelompok depot dan toko yang belum diproses ----------------------------------------------
-- Pemilik, 18 November 2026 (lanjutan): "yang ke depot setiap 2 hari dan ganti gantian 50% depot dulu
-- di hari pertama selanjutnya di hari kedua 50% depot lagi tetapi dalam 1 region diusahakan sama."
-- Region dibagi ke kelompok A / B (region terbesar lebih dulu, ke kelompok yang depotnya lebih
-- sedikit), sehingga satu region selalu satu kelompok dan jumlah depot kedua kelompok seimbang.
-- Kelompok hari ini: A pada hari genap sejak 18-Nov-2026, B pada hari ganjil (WIB).
create or replace function rc_private.debtor_kelompok() returns table(region text, kelompok smallint, n_depot integer)
language plpgsql stable security definer set search_path = '' as $f$
declare r record; a integer := 0; b integer := 0;
begin
  for r in select coalesce(nullif(upper(btrim(d.region)), ''), '-') rg, count(*)::integer n
             from public.depots d where d.archived_at is null and not coalesce(d.bukan_depot, false)
            group by 1 order by 2 desc, 1 loop
    region := r.rg; n_depot := r.n;
    if a <= b then kelompok := 0; a := a + r.n; else kelompok := 1; b := b + r.n; end if;
    return next;
  end loop;
end $f$;

create or replace function rc_private.debtor_kelompok_hari_ini() returns smallint
language sql stable set search_path = '' as $f$
  select (((now() at time zone 'Asia/Jakarta')::date - date '2026-11-18') % 2)::smallint;
$f$;

-- Seluruh toko lunas yang belum diproses (tawaran aktif, dokumen Not Yet), dengan umurnya.
create or replace function rc_private.debtor_belum_proses() returns table(
  offer_id uuid, depot_id uuid, umur integer, toko text, campaign text, cb_net numeric, tgl_lunas date, deadline date)
language sql stable security definer set search_path = '' as $f$
  select o.id, c.depot_id,
         ((now() at time zone 'Asia/Jakarta')::date - (o.offered_at at time zone 'Asia/Jakarta')::date),
         case when nullif(btrim(cu.customer_name), '') is null then coalesce(cu.customer_code, '-')
              else btrim(cu.customer_name) || coalesce(' (' || cu.customer_code || ')', '') end,
         coalesce(nullif(btrim(ca.campaign_name), ''), ca.campaign_code, '-'),
         c.cb_net, c.paid_on, (o.deadline_at at time zone 'Asia/Jakarta')::date
    from public.rc_clearing_offers o
    join public.claims c on c.id = o.claim_id
    join public.depots d on d.id = c.depot_id and d.archived_at is null
    left join public.customers cu on cu.id = c.customer_id
    left join public.campaigns ca on ca.id = c.campaign_id
   where o.status in ('offered', 'overdue') and o.offered_at is not null
     and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null;
$f$;

-- ---- 4. Susun -----------------------------------------------------------------------------------
-- * Email depot (pengingat, tanpa jenjang): depot kelompok hari ini yang punya toko lunas belum
--   diproses; isinya SELURUH toko itu. Tidak menandai apa pun - dua hari lagi dikirim ulang bila
--   tokonya belum diproses.
-- * Laporan region (management): pada hari yang dicentang di Access Management (kosong = tiap hari),
--   toko yang lewat >= hari jenjang 1 dan < hari jenjang 3, satu laporan per region (CC jenjang 1 / 2
--   menurut toko terlama region itu); toko yang lewat >= hari jenjang 3 digabung SATU laporan nasional
--   (semua region, kolom Region, CC jenjang 3). Tanpa penandaan (rc_private.debtor_peringatan tidak dipakai lagi).
create or replace function rc_private.email_debtor_susun(p_set public.email_settings, p_kirim boolean, p_uji text) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  -- 20261164050000: email depot tiap 2 hari bergantian kelompok; laporan region per jenjang.
  v_jj jsonb := rc_private.debtor_jenjang(); g record; rg record; v_to text[]; v_cc text[]; v_html text; v_subjek text; v_id uuid; v_pertama uuid;
  v_tumpuk text := ''; v_n integer := 0; v_toko integer := 0; v_dasar text; v_jjcc text[]; v_kirim boolean;
  v_kel smallint := rc_private.debtor_kelompok_hari_ini(); v_h1 integer; v_h3 integer; v_rows jsonb; v_hari_laporan boolean; rg_tk smallint;
  v_dep_nas uuid[];
  v_nama_hari text[] := array['Minggu', 'Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu']; v_nd integer := 0; v_nr integer := 0;
begin
  if not rc_private.zdage_aktif() then
    return jsonb_build_object('status', 'success', 'dikirim', false,
      'isiHtml', '<p style="font-family:Arial,sans-serif;">ZDAGE Integration mati (Access Management &gt; On/Off Sistem); peringatan toko lunas tidak disusun.</p>',
      'message', 'ZDAGE Integration mati; peringatan toko lunas tidak disusun.');
  end if;
  v_dasar := coalesce(nullif(btrim(p_set.subjek), ''), 'Warning - Toko Lunas Belum Diproses Depot');
  v_kirim := coalesce(p_kirim, false) and coalesce(p_uji, '') = '';
  v_h1 := (v_jj->0->>'hari')::int; v_h3 := (v_jj->2->>'hari')::int;

  -- ---- Email depot: kelompok hari ini ----
  for g in
    select b.depot_id, d.depot_code, coalesce(nullif(d.depot_name, ''), d.depot_code) depot_nama,
           jsonb_agg(jsonb_build_object('toko', b.toko, 'campaign', b.campaign, 'cb', b.cb_net, 'lunas', b.tgl_lunas, 'deadline', b.deadline, 'umur', b.umur)
                     order by b.umur desc, b.campaign, b.toko) baris, count(*) n
      from rc_private.debtor_belum_proses() b
      join public.depots d on d.id = b.depot_id
      join rc_private.debtor_kelompok() k on k.region = coalesce(nullif(upper(btrim(d.region)), ''), '-')
     where k.kelompok = v_kel
     group by b.depot_id, d.depot_code, d.depot_name order by d.depot_code
  loop
    select coalesce(array(select distinct lower(btrim(x)) from unnest(rc_private.pecah_email(
             concat_ws(',', p.email_kepala_admin, p.email_npc, p.email_kepala_depot))) x where btrim(x) like '%@%'), '{}')
      into v_to from public.depot_profiles p where p.depot_id = g.depot_id;
    if coalesce(array_length(v_to, 1), 0) = 0 then
      select coalesce(array(select distinct lower(btrim(x)) from unnest(rc_private.pecah_email(d.email_to)) x where btrim(x) like '%@%'), '{}')
        into v_to from public.depots d where d.id = g.depot_id;
    end if;
    -- "untuk cc email depot cukup masukan cc ke osc@..." -> CC panel Email Otomatis jenis ini.
    v_cc := coalesce(array(select distinct lower(btrim(x)) from unnest(coalesce(p_set.cc_tambahan, '{}')) x
                            where btrim(x) like '%@%' and not (lower(btrim(x)) = any(v_to))), '{}');
    v_html := rc_private.debtor_email_depot_html(g.depot_id, g.baris);
    v_subjek := v_dasar || ' - ' || g.depot_nama;
    v_n := v_n + 1; v_nd := v_nd + 1; v_toko := v_toko + g.n;
    v_tumpuk := v_tumpuk
      || '<div style="font-family:Arial,sans-serif;font-size:12px;background:#f1f3f4;border:1px solid #dadce0;padding:8px 12px;margin:16px 0 8px;">'
      || '<b>' || rc_private.html_aman(v_subjek) || '</b><br>TO: ' || rc_private.html_aman(coalesce(nullif(array_to_string(v_to, ', '), ''), 'BELUM ADA EMAIL KEPALA ADMIN / NPC / KEPALA DEPOT DI DEPOT PROFILE'))
      || ' &middot; CC: ' || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc, ', '), ''), '-')) || '</div>' || v_html;
    if v_kirim then
      insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, status, galat, konteks)
      values ('debtor', v_to, v_cc, v_subjek, rc_private.email_outlook(v_html),
        case when coalesce(array_length(v_to, 1), 0) = 0 then 'skipped' else 'pending' end,
        case when coalesce(array_length(v_to, 1), 0) = 0 then 'Belum ada Email Kepala Admin / NPC / Kepala Depot di Depot Profile' else '' end,
        jsonb_build_object('depot', g.depot_id, 'bagian', 'depot', 'kelompok', case when v_kel = 0 then 'A' else 'B' end, 'jumlah', g.n, 'preview', false, 'uji', false))
      returning id into v_id;
      v_pertama := coalesce(v_pertama, v_id);
    end if;
  end loop;

  -- ---- Laporan region: hanya hari yang dicentang (kosong = tiap hari) ----
  -- Pemilik, 18-Nov-2026: "dikirimkan sesuai hari yang saya tick ... misal jenjang 1 14 dan diseting
  -- tiap rabu dan jumat maka yang >=14 tiap rabu dan jumat akan masuk report sesuai jenjang."
  -- Isi = seluruh toko yang lewat >= hari jenjang 1; CC = CC jenjang tertinggi yang dicapai toko
  -- terlama di region itu. Satu laporan per region per hari; tidak ada penandaan.
  -- Pratinjau dan Test Email selalu menampilkannya, dengan keterangan bila hari ini bukan hari laporan.
  v_hari_laporan := p_set.hari_list is null or cardinality(p_set.hari_list) = 0
                    or extract(dow from now() at time zone 'Asia/Jakarta')::smallint = any(p_set.hari_list);
  if v_hari_laporan or not v_kirim then
  for rg in
    -- Pemilik, 18-Nov-2026: "untuk jenjang 3 saya mau jadi 1 email untuk semua region" -> laporan per
    -- region hanya toko jenjang 1-2 (lewat < hari jenjang 3); jenjang 3 dilaporkan nasional di bawah.
    select coalesce(nullif(upper(btrim(d.region)), ''), '-') region, array_agg(distinct b.depot_id) depots, max(b.umur) umur
      from rc_private.debtor_belum_proses() b join public.depots d on d.id = b.depot_id
     where b.umur >= v_h1 and b.umur < v_h3
     group by 1 order by 1
  loop
    rg_tk := case when rg.umur >= (v_jj->1->>'hari')::int then 2 else 1 end;
    select jsonb_agg(z.obj order by z.kode) into v_rows from (
      select d.depot_code kode, jsonb_build_object('kode', d.depot_code, 'nama', coalesce(nullif(d.depot_name, ''), d.depot_code),
               'campaign', count(distinct b.campaign), 'toko', count(*), 'net', sum(b.cb_net), 'umur', max(b.umur),
               'pic', coalesce((select nullif(btrim(p.kepala_admin), '') from public.depot_profiles p where p.depot_id = d.id), '')) obj
        from rc_private.debtor_belum_proses() b join public.depots d on d.id = b.depot_id
       where b.depot_id = any(rg.depots) and b.umur >= v_h1 and b.umur < v_h3
       group by d.id, d.depot_code, d.depot_name) z;
    v_to := coalesce(array(select distinct lower(btrim(x)) from public.depot_profiles p,
              unnest(rc_private.pecah_email(concat_ws(',', p.email_rsm, p.email_asm))) x
             where p.depot_id = any(rg.depots) and btrim(x) like '%@%'), '{}');
    v_jjcc := coalesce(array(select jsonb_array_elements_text(coalesce(v_jj->(rg_tk - 1)->'cc', '[]'))), '{}');
    v_cc := coalesce(array(select distinct a from (
              select lower(btrim(x)) a from public.depot_profiles p, unnest(rc_private.pecah_email(concat_ws(',', p.email_kepala_depot, p.email_kepala_admin))) x
               where p.depot_id = any(rg.depots)
              union all
              select lower(btrim(pr.business_email)) from public.profiles pr join public.user_depot_access u on u.user_id = pr.id
               where u.depot_id = any(rg.depots) and lower(coalesce(pr.role, '')) = 'osc' and coalesce(pr.status, '') = 'active' and pr.archived_at is null
              union all
              select lower(btrim(y)) from unnest(v_jjcc) y) s
            where a like '%@%' and not (a = any(v_to)) order by 1), '{}');
    v_html := rc_private.debtor_email_region_html(rg.region, v_rows);
    v_subjek := v_dasar || ' - Region ' || rg.region;
    v_n := v_n + 1; v_nr := v_nr + 1;
    v_tumpuk := v_tumpuk
      || '<div style="font-family:Arial,sans-serif;font-size:12px;background:#e8f0fe;border:1px solid #c6dafc;padding:8px 12px;margin:16px 0 8px;">'
      || '<b>' || rc_private.html_aman(v_subjek) || '</b> (terlama ' || rg.umur::text || ' hari = jenjang ' || rg_tk::text || ', CC jenjang ' || rg_tk::text || ')<br>TO: '
      || rc_private.html_aman(coalesce(nullif(array_to_string(v_to, ', '), ''), 'BELUM ADA EMAIL RSM / ASM DI DEPOT PROFILE'))
      || ' &middot; CC: ' || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc, ', '), ''), '-')) || '</div>' || v_html;
    if v_kirim then
      insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, status, galat, konteks)
      values ('debtor', v_to, v_cc, v_subjek, rc_private.email_outlook(v_html),
        case when coalesce(array_length(v_to, 1), 0) = 0 then 'skipped' else 'pending' end,
        case when coalesce(array_length(v_to, 1), 0) = 0 then 'Belum ada Email RSM / ASM di Depot Profile' else '' end,
        jsonb_build_object('region', rg.region, 'bagian', 'region', 'tingkat', rg_tk, 'depot', jsonb_array_length(v_rows), 'preview', false, 'uji', false))
      returning id into v_id;
      v_pertama := coalesce(v_pertama, v_id);
    end if;
  end loop;

  -- ---- Laporan nasional jenjang 3: satu email untuk semua region dan semua depot ----
  select jsonb_agg(z.obj order by z.region, z.kode), array_agg(z.did) into v_rows, v_dep_nas from (
    select d.id did, d.depot_code kode, coalesce(nullif(upper(btrim(d.region)), ''), '-') region,
           jsonb_build_object('kode', d.depot_code, 'nama', coalesce(nullif(d.depot_name, ''), d.depot_code),
             'region', coalesce(nullif(upper(btrim(d.region)), ''), '-'),
             'campaign', count(distinct b.campaign), 'toko', count(*), 'net', sum(b.cb_net), 'umur', max(b.umur),
             'pic', coalesce((select nullif(btrim(p.kepala_admin), '') from public.depot_profiles p where p.depot_id = d.id), '')) obj
      from rc_private.debtor_belum_proses() b join public.depots d on d.id = b.depot_id
     where b.umur >= v_h3
     group by d.id, d.depot_code, d.depot_name, d.region) z;
  if v_rows is not null then
    v_to := coalesce(array(select distinct lower(btrim(x)) from public.depot_profiles p,
              unnest(rc_private.pecah_email(concat_ws(',', p.email_rsm, p.email_asm))) x
             where p.depot_id = any(v_dep_nas) and btrim(x) like '%@%'), '{}');
    v_jjcc := coalesce(array(select jsonb_array_elements_text(coalesce(v_jj->2->'cc', '[]'))), '{}');
    v_cc := coalesce(array(select distinct a from (
              select lower(btrim(x)) a from public.depot_profiles p, unnest(rc_private.pecah_email(concat_ws(',', p.email_kepala_depot, p.email_kepala_admin))) x
               where p.depot_id = any(v_dep_nas)
              union all
              select lower(btrim(pr.business_email)) from public.profiles pr join public.user_depot_access u on u.user_id = pr.id
               where u.depot_id = any(v_dep_nas) and lower(coalesce(pr.role, '')) = 'osc' and coalesce(pr.status, '') = 'active' and pr.archived_at is null
              union all
              select lower(btrim(y)) from unnest(v_jjcc) y) s
            where a like '%@%' and not (a = any(v_to)) order by 1), '{}');
    v_html := rc_private.debtor_email_region_html('SEMUA REGION', v_rows);
    v_subjek := v_dasar || ' - Semua Region (lewat ' || v_h3::text || ' hari atau lebih)';
    v_n := v_n + 1; v_nr := v_nr + 1;
    v_tumpuk := v_tumpuk
      || '<div style="font-family:Arial,sans-serif;font-size:12px;background:#fce8e6;border:1px solid #f4b6ae;padding:8px 12px;margin:16px 0 8px;">'
      || '<b>' || rc_private.html_aman(v_subjek) || '</b> (jenjang 3, CC jenjang 3)<br>TO: '
      || rc_private.html_aman(coalesce(nullif(array_to_string(v_to, ', '), ''), 'BELUM ADA EMAIL RSM / ASM DI DEPOT PROFILE'))
      || ' &middot; CC: ' || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc, ', '), ''), '-')) || '</div>' || v_html;
    if v_kirim then
      insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, status, galat, konteks)
      values ('debtor', v_to, v_cc, v_subjek, rc_private.email_outlook(v_html),
        case when coalesce(array_length(v_to, 1), 0) = 0 then 'skipped' else 'pending' end,
        case when coalesce(array_length(v_to, 1), 0) = 0 then 'Belum ada Email RSM / ASM di Depot Profile' else '' end,
        jsonb_build_object('region', 'SEMUA', 'bagian', 'nasional', 'tingkat', 3, 'depot', jsonb_array_length(v_rows), 'preview', false, 'uji', false))
      returning id into v_id;
      v_pertama := coalesce(v_pertama, v_id);
    end if;
  end if;
  end if;

  if v_n = 0 then
    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, galat, konteks)
    values ('debtor', '{}', '(tidak dikirim)', '', 'skipped', 'Tidak ada toko lunas untuk depot kelompok hari ini dan tidak ada laporan region',
            jsonb_build_object('preview', not coalesce(p_kirim, false), 'uji', coalesce(p_uji, '') <> ''))
    returning id into v_id;
    return jsonb_build_object('status', 'success', 'dikirim', false, 'id', v_id,
      'isiHtml', '<p style="font-family:Arial,sans-serif;">Hari ini kelompok depot ' || case when v_kel = 0 then 'A' else 'B' end
                 || ': tidak ada toko lunas yang belum diproses, dan tidak ada toko yang lewat jenjang (hari ke-'
                 || (v_jj->0->>'hari') || ' / ' || (v_jj->1->>'hari') || ' / ' || (v_jj->2->>'hari') || ').</p>',
      'message', 'Tidak ada email peringatan toko lunas hari ini.');
  end if;

  v_tumpuk := '<div style="font-family:Arial,sans-serif;font-size:12px;background:#fff8e1;border:1px solid #f0d58c;padding:8px 12px;margin:0 0 8px;">'
    || 'Hari ini: <b>kelompok depot ' || case when v_kel = 0 then 'A' else 'B' end || '</b> (' || v_nd::text || ' email depot, setiap 2 hari bergantian A / B; region: '
    || coalesce((select string_agg(region, ', ' order by region) from rc_private.debtor_kelompok() where kelompok = v_kel), '-')
    || ') &middot; ' || v_nr::text || ' laporan region (toko lewat &gt;= ' || (v_jj->0->>'hari') || ' hari; jenjang ' || (v_jj->0->>'hari') || ' / ' || (v_jj->1->>'hari') || ' / ' || (v_jj->2->>'hari')
    || ' hari) &middot; hari laporan: ' || coalesce((select string_agg(v_nama_hari[h + 1], ', ' order by h) from unnest(p_set.hari_list) h), 'tiap hari')
    || case when not v_hari_laporan then ' &mdash; <b>hari ini bukan hari laporan</b>, laporan region di bawah hanya contoh dan tidak ikut terkirim' else '' end || '.</div>'
    || v_tumpuk;

  if coalesce(p_uji, '') <> '' then
    insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, status, konteks)
    values ('debtor', array[p_uji], '{}', '[UJI] ' || v_dasar || ' (' || v_n::text || ' email, ' || v_toko::text || ' toko)',
            rc_private.email_outlook('<div style="font-family:Arial,Helvetica,sans-serif;background:#1f2937;color:#ffffff;padding:12px 16px;border-radius:8px;margin-bottom:12px;max-width:640px;">'
              || '<div style="font-size:13px;font-weight:bold;">TEST EMAIL &mdash; ' || v_n::text || ' email peringatan berikut TIDAK dikirim ke depot / region dan tokonya tidak ditandai</div></div>' || v_tumpuk),
            case when coalesce(p_kirim, false) then 'pending' else 'skipped' end,
            jsonb_build_object('preview', false, 'uji', true, 'jumlah', v_n))
    returning id into v_pertama;
  elsif not coalesce(p_kirim, false) then
    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, konteks)
    values ('debtor', '{}', '(pratinjau)', '', 'skipped', jsonb_build_object('preview', true, 'jumlah', v_n))
    returning id into v_pertama;
  end if;

  return jsonb_build_object('status', 'success', 'id', v_pertama, 'dikirim', coalesce(p_kirim, false), 'jumlahEmail', v_n, 'jumlahToko', v_toko,
    'emailDepot', v_nd, 'emailRegion', v_nr, 'kelompok', case when v_kel = 0 then 'A' else 'B' end,
    'subjek', v_dasar || ' (' || v_n::text || ' email)',
    'isiHtml', v_tumpuk,
    'message', case when coalesce(p_uji, '') <> '' then 'Test Email peringatan (' || v_n || ' email) untuk ' || p_uji || '.'
                    when coalesce(p_kirim, false) then v_nd || ' email depot (kelompok ' || case when v_kel = 0 then 'A' else 'B' end || ') dan ' || v_nr || ' laporan region dimasukkan ke antrean.'
                    else 'Pratinjau ' || v_nd || ' email depot (kelompok ' || case when v_kel = 0 then 'A' else 'B' end || ') dan ' || v_nr || ' laporan region. Tidak ada yang dikirim.' end);
end $f$;

revoke all on function rc_private.debtor_kelompok(), rc_private.debtor_kelompok_hari_ini(), rc_private.debtor_belum_proses() from public, anon, authenticated;
revoke all on function rc_private.debtor_sorotan(), rc_private.debtor_email_depot_html(uuid, jsonb),
  rc_private.debtor_email_region_html(text, jsonb), rc_private.email_debtor_susun(public.email_settings, boolean, text)
  from public, anon, authenticated;

-- ---- 5. Jadwal: jenis debtor berjalan tiap hari (email depot tiap 2 hari); centang hari = hari laporan region.
create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $g$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $g$;

-- 20-Nov-2026: CC email depot bawaan diisi lewat panel Email Otomatis (alamatnya tidak ditulis di git).

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('public.rc_email_status()'::regprocedure), E'\r', '');
  if src !~ '20261164050000' then
    src := pg_temp.ganti(src, $p$'cc',case when jenis = 'debtor' then null else to_jsonb(coalesce(cc_tambahan,'{}'::text[])) end /* 20261163370000; 20261163670000 */,$p$,
      $p$'cc',to_jsonb(coalesce(cc_tambahan,'{}'::text[])) /* 20261163370000; 20261164050000: debtor = CC email depot */,$p$, 1, 'status cc');
    execute src;
  end if;
  src := replace(pg_get_functiondef('public.rc_email_tick()'::regprocedure), E'\r', '');
  if src !~ '20261164050000' then
    src := pg_temp.ganti(src, $p$    if s.hari_list is not null and not (hari_lokal = any(s.hari_list)) then continue; end if;$p$,
      $p$    if s.hari_list is not null and not (hari_lokal = any(s.hari_list))
       and s.jenis <> 'debtor' /* 20261164050000: centang hari debtor = hari laporan region; email depot tiap 2 hari */ then continue; end if;$p$, 1, 'tick hari');
    execute src;
  end if;
end $tambal$;

update public.email_settings
   set catatan = 'Peringatan toko lunas (ZDAGE) yang belum diproses depot. Email depot (TO Kepala Admin, NPC, Kepala Depot; CC kolom CC email depot; seluruh toko lunas belum diproses) setiap 2 hari, bergantian kelompok depot A / B (satu region satu kelompok). Pada hari yang dicentang: laporan per region untuk toko jenjang 1-2 (TO RSM + ASM; CC OSC, Kepala Depot, Kepala Admin + CC jenjang) dan satu laporan nasional semua region untuk toko jenjang 3 (CC jenjang 3).'
 where jenis = 'debtor';

do $cek$ begin
  if pg_get_functiondef('rc_private.email_debtor_susun(public.email_settings,boolean,text)'::regprocedure) !~ '20261164050000' then raise exception 'GAGAL: susun'; end if;
  if rc_private.debtor_sorotan() !~ 'H\+30' then raise exception 'GAGAL: sorotan'; end if;
  if pg_get_functiondef('public.rc_email_tick()'::regprocedure) !~ '20261164050000' then raise exception 'GAGAL: tick'; end if;
  if pg_get_functiondef('public.rc_email_status()'::regprocedure) !~ '20261164050000' then raise exception 'GAGAL: status'; end if;
end $cek$;
