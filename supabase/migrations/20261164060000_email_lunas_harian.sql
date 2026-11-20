-- ==========================================================================================
-- Warning - Toko Lunas: email depot setiap hari 02:00-04:00 (kecuali Minggu dan tanggal merah),
-- kolom Auto-Expiring menggantikan Deadline
-- ==========================================================================================
-- Pemilik, 19 November 2026:
--   "saya mau email ke depot nya dikirim tiap hari untuk yang ke admin dan kepala depot tapi supaya
--    ga berat dilakukan jam 2-4 pagi dan untuk kolom deadline hapus aja dan ganti jadi auto-expiring
--    tanggal berapa." lalu "tiap hari kecuali hari minggu dan tanggal merah"
--
-- * Email depot: setiap hari kecuali Minggu dan tanggal merah. Kelompok A (rc_private.debtor_kelompok)
--   disusun pukul 02:05 WIB, kelompok B pukul 03:05 WIB, supaya beban terbagi. Tidak lagi bergantian
--   per 2 hari.
-- * Tanggal merah: tabel rc_private.hari_libur, diisi libur nasional + cuti bersama 24-25 Des 2026
--   dan 2027 (SKB 3 Menteri 15-Sep-2026), dapat diubah di Email Otomatis > Peringatan Toko Lunas.
-- * Laporan region / nasional tetap pada jam panel dan hari yang dicentang.
-- * Kolom Deadline diganti Auto-Expiring = tanggal dokumen Open otomatis Expired
--   (rc_private.zdage_expired_otomatis: sehari setelah batas proses + 1 bulan).
-- * Kirim Manual: seluruh depot + laporan region bila hari laporan; depot / region / nasional yang
--   sudah dikirimi hari ini dilewati, sehingga tidak ada email ganda.
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $g$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $g$;

-- ---- 1. Tanggal merah -------------------------------------------------------------------------
create table if not exists rc_private.hari_libur (
  tanggal date primary key,
  nama text not null default '' check (length(nama) <= 120)
);
revoke all on rc_private.hari_libur from public, anon, authenticated;

insert into rc_private.hari_libur(tanggal, nama) values
  ('2026-12-24', 'Cuti bersama Natal'), ('2026-12-25', 'Natal'),
  ('2027-01-01', 'Tahun Baru 2027'), ('2027-01-05', 'Isra Mikraj'), ('2027-02-05', 'Cuti bersama Imlek'), ('2027-02-06', 'Imlek 2578'),
  ('2027-03-08', 'Nyepi'), ('2027-03-09', 'Cuti bersama Idulfitri'), ('2027-03-10', 'Idulfitri 1448 H'), ('2027-03-11', 'Idulfitri 1448 H'),
  ('2027-03-12', 'Cuti bersama Idulfitri'), ('2027-03-15', 'Cuti bersama Idulfitri'), ('2027-03-25', 'Cuti bersama Wafat Yesus Kristus'),
  ('2027-03-26', 'Wafat Yesus Kristus'), ('2027-03-28', 'Paskah'), ('2027-05-01', 'Hari Buruh'), ('2027-05-06', 'Kenaikan Yesus Kristus'),
  ('2027-05-17', 'Iduladha 1448 H'), ('2027-05-18', 'Cuti bersama Iduladha'), ('2027-05-19', 'Cuti bersama Waisak'), ('2027-05-20', 'Waisak'),
  ('2027-06-01', 'Hari Lahir Pancasila'), ('2027-06-06', 'Tahun Baru Islam 1449 H'), ('2027-08-15', 'Maulid Nabi'),
  ('2027-08-17', 'Proklamasi Kemerdekaan'), ('2027-12-24', 'Cuti bersama Natal'), ('2027-12-25', 'Natal'), ('2027-12-26', 'Isra Mikraj')
on conflict (tanggal) do nothing;

-- Minggu atau tanggal merah.
create or replace function rc_private.hari_libur_ini(p_tgl date) returns boolean
language sql stable security definer set search_path = '' as $f$
  select extract(dow from p_tgl) = 0 or exists(select 1 from rc_private.hari_libur where tanggal = p_tgl);
$f$;

-- Teks panel: satu baris per tanggal "dd-mm-yyyy Nama", hanya hari ini ke depan.
create or replace function rc_private.hari_libur_teks() returns text
language sql stable security definer set search_path = '' as $f$
  select coalesce(string_agg(to_char(tanggal, 'DD-MM-YYYY') || coalesce(' ' || nullif(nama, ''), ''), E'\n' order by tanggal), '')
    from rc_private.hari_libur where tanggal >= (now() at time zone 'Asia/Jakarta')::date;
$f$;

-- Simpan dari panel: menggantikan seluruh tanggal hari ini ke depan. Format tanggal dd-mm-yyyy atau dd.mm.yyyy.
create or replace function rc_private.hari_libur_simpan(p_teks text) returns integer
language plpgsql security definer set search_path = '' as $f$
declare b text; m text[]; d date; n integer := 0; v_hari date := (now() at time zone 'Asia/Jakarta')::date;
begin
  create temp table if not exists _libur(tanggal date primary key, nama text) on commit drop;
  truncate _libur;
  foreach b in array regexp_split_to_array(coalesce(p_teks, ''), E'\\r?\\n') loop
    b := btrim(b);
    continue when b = '';
    m := regexp_match(b, '^(\d{1,2})[.-](\d{1,2})[.-](\d{4})\s*(.*)$');
    if m is null then raise exception 'Tanggal merah tidak terbaca: "%". Pakai dd-mm-yyyy lalu nama, mis. 25-12-2026 Natal', b; end if;
    begin d := make_date(m[3]::int, m[2]::int, m[1]::int);
    exception when others then raise exception 'Tanggal merah tidak ada di kalender: %', b; end;
    insert into _libur values (d, left(btrim(m[4]), 120)) on conflict (tanggal) do update set nama = excluded.nama;
  end loop;
  delete from rc_private.hari_libur where tanggal >= v_hari;
  insert into rc_private.hari_libur(tanggal, nama) select tanggal, nama from _libur where tanggal >= v_hari
  on conflict (tanggal) do update set nama = excluded.nama;
  get diagnostics n = row_count;
  return n;
end $f$;
revoke all on function rc_private.hari_libur_ini(date), rc_private.hari_libur_teks(), rc_private.hari_libur_simpan(text) from public, anon, authenticated;

-- ---- 2. Kolom Auto-Expiring di email depot -----------------------------------------------------
do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.debtor_email_depot_html(uuid,jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261164060000' then
    src := pg_temp.ganti(src, $p$coalesce(to_char((x->>'deadline')::date, 'DD-Mon-YYYY'), '-')$p$,
      $p$coalesce(to_char((x->>'expire')::date, 'DD-Mon-YYYY'), '-') /* 20261164060000: Auto-Expiring */$p$, 1, 'sel expire');
    src := pg_temp.ganti(src, $p$'">DEADLINE</th>$p$, $p$'">AUTO-EXPIRING</th>$p$, 1, 'judul expire');
    execute src;
  end if;
end $tambal$;

-- ---- 3. Penyusun ---------------------------------------------------------------------------------
create or replace function rc_private.email_debtor_bagian(p_set public.email_settings, p_kirim boolean, p_uji text,
  p_depot boolean, p_kel smallint, p_region boolean) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  -- 20261164060000: p_depot = email depot (p_kel: kelompok 0 / 1, null = semua); p_region = laporan region + nasional.
  -- Kirim sungguhan melewati depot / region yang sudah dikirimi hari ini (tidak ada email ganda).
  v_jj jsonb := rc_private.debtor_jenjang(); g record; rg record; v_to text[]; v_cc text[]; v_html text; v_subjek text; v_id uuid; v_pertama uuid;
  v_tumpuk text := ''; v_n integer := 0; v_toko integer := 0; v_dasar text; v_jjcc text[]; v_kirim boolean;
  v_kel smallint := rc_private.debtor_kelompok_hari_ini(); v_h1 integer; v_h3 integer; v_rows jsonb; v_hari_laporan boolean; rg_tk smallint;
  v_dep_nas uuid[]; v_awal timestamptz := date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta';
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

  -- ---- Email depot: setiap hari kecuali Minggu dan tanggal merah (jadwal: rc_private.debtor_jadwal) ----
  if coalesce(p_depot, false) then
  for g in
    select b.depot_id, d.depot_code, coalesce(nullif(d.depot_name, ''), d.depot_code) depot_nama,
           jsonb_agg(jsonb_build_object('toko', b.toko, 'campaign', b.campaign, 'cb', b.cb_net, 'lunas', b.tgl_lunas, 'deadline', b.deadline,
                                      'expire', ((b.deadline + interval '1 month')::date + 1), 'umur', b.umur)
                     order by b.umur desc, b.campaign, b.toko) baris, count(*) n
      from rc_private.debtor_belum_proses() b
      join public.depots d on d.id = b.depot_id
      join rc_private.debtor_kelompok() k on k.region = coalesce(nullif(upper(btrim(d.region)), ''), '-')
     where (p_kel is null or k.kelompok = p_kel)
       and not (v_kirim and exists(select 1 from public.email_outbox e where e.jenis = 'debtor' and e.dibuat_pada >= v_awal
                                     and e.konteks->>'bagian' = 'depot' and e.konteks->>'depot' = b.depot_id::text
                                     and coalesce(e.konteks->>'uji', '') <> 'true' and coalesce(e.konteks->>'preview', '') <> 'true'))
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
        jsonb_build_object('depot', g.depot_id, 'bagian', 'depot', 'kelompok', case when p_kel = 0 then 'A' when p_kel = 1 then 'B' else 'semua' end, 'jumlah', g.n, 'preview', false, 'uji', false))
      returning id into v_id;
      v_pertama := coalesce(v_pertama, v_id);
    end if;
  end loop;
  end if;

  -- ---- Laporan region: hanya hari yang dicentang (kosong = tiap hari) ----
  -- Pemilik, 18-Nov-2026: "dikirimkan sesuai hari yang saya tick ... misal jenjang 1 14 dan diseting
  -- tiap rabu dan jumat maka yang >=14 tiap rabu dan jumat akan masuk report sesuai jenjang."
  -- Isi = seluruh toko yang lewat >= hari jenjang 1; CC = CC jenjang tertinggi yang dicapai toko
  -- terlama di region itu. Satu laporan per region per hari; tidak ada penandaan.
  -- Pratinjau dan Test Email selalu menampilkannya, dengan keterangan bila hari ini bukan hari laporan.
  v_hari_laporan := p_set.hari_list is null or cardinality(p_set.hari_list) = 0
                    or extract(dow from now() at time zone 'Asia/Jakarta')::smallint = any(p_set.hari_list);
  if coalesce(p_region, false) and (v_hari_laporan or not v_kirim) then
  for rg in
    -- Pemilik, 18-Nov-2026: "untuk jenjang 3 saya mau jadi 1 email untuk semua region" -> laporan per
    -- region hanya toko jenjang 1-2 (lewat < hari jenjang 3); jenjang 3 dilaporkan nasional di bawah.
    select coalesce(nullif(upper(btrim(d.region)), ''), '-') region, array_agg(distinct b.depot_id) depots, max(b.umur) umur
      from rc_private.debtor_belum_proses() b join public.depots d on d.id = b.depot_id
     where b.umur >= v_h1 and b.umur < v_h3
     group by 1 order by 1
  loop
    if v_kirim and exists(select 1 from public.email_outbox e where e.jenis = 'debtor' and e.dibuat_pada >= v_awal
                            and e.konteks->>'bagian' = 'region' and e.konteks->>'region' = rg.region
                            and coalesce(e.konteks->>'uji', '') <> 'true' and coalesce(e.konteks->>'preview', '') <> 'true') then continue; end if;
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
  if v_rows is not null and not (v_kirim and exists(select 1 from public.email_outbox e where e.jenis = 'debtor' and e.dibuat_pada >= v_awal
        and e.konteks->>'bagian' = 'nasional' and coalesce(e.konteks->>'uji', '') <> 'true' and coalesce(e.konteks->>'preview', '') <> 'true')) then
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
    values ('debtor', '{}', '(tidak dikirim)', '', 'skipped', 'Tidak ada email peringatan toko lunas yang perlu dikirim',
            jsonb_build_object('preview', not coalesce(p_kirim, false), 'uji', coalesce(p_uji, '') <> ''))
    returning id into v_id;
    return jsonb_build_object('status', 'success', 'dikirim', false, 'id', v_id, 'emailDepot', 0, 'emailRegion', 0, 'jumlahEmail', 0,
      'isiHtml', '<p style="font-family:Arial,sans-serif;">Tidak ada email yang perlu dikirim: toko lunas belum diproses sudah dikirimi hari ini atau tidak ada, '
                 || 'dan tidak ada laporan region yang jatuh pada hari ini (hari ke-'
                 || (v_jj->0->>'hari') || ' / ' || (v_jj->1->>'hari') || ' / ' || (v_jj->2->>'hari') || ').</p>',
      'message', 'Tidak ada email peringatan toko lunas hari ini.');
  end if;

  v_tumpuk := '<div style="font-family:Arial,sans-serif;font-size:12px;background:#fff8e1;border:1px solid #f0d58c;padding:8px 12px;margin:0 0 8px;">'
    || '<b>' || v_nd::text || ' email depot</b> (setiap hari kecuali Minggu &amp; tanggal merah; kelompok A 02:00, B 03:00 WIB'
    || case when rc_private.hari_libur_ini((now() at time zone 'Asia/Jakarta')::date) then ' &mdash; <b>hari ini tanggal merah / Minggu</b>, jadwal tidak mengirim email depot' else '' end
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
    'emailDepot', v_nd, 'emailRegion', v_nr,
    'subjek', v_dasar || ' (' || v_n::text || ' email)',
    'isiHtml', v_tumpuk,
    'message', case when coalesce(p_uji, '') <> '' then 'Test Email peringatan (' || v_n || ' email) untuk ' || p_uji || '.'
                    when coalesce(p_kirim, false) then v_nd || ' email depot dan ' || v_nr || ' laporan region dimasukkan ke antrean.'
                    else 'Pratinjau ' || v_nd || ' email depot dan ' || v_nr || ' laporan region. Tidak ada yang dikirim.' end);
end $f$;

-- Pratinjau, Test Email dan Kirim Manual: seluruh depot + laporan region / nasional.
create or replace function rc_private.email_debtor_susun(p_set public.email_settings, p_kirim boolean, p_uji text) returns jsonb
language sql security definer set search_path = '' as $f$
  select rc_private.email_debtor_bagian(p_set, p_kirim, p_uji, true, null, true); -- 20261164060000
$f$;

-- Jadwal jenis debtor (dipanggil rc_email_tick tiap jam, menit 05).
create or replace function rc_private.debtor_jadwal(p_now timestamptz) returns void
language plpgsql security definer set search_path = '' as $f$
declare s public.email_settings; v_jam integer := extract(hour from p_now at time zone 'Asia/Jakarta')::integer;
  v_dow smallint := extract(dow from p_now at time zone 'Asia/Jakarta')::smallint; v_tgl date := (p_now at time zone 'Asia/Jakarta')::date;
begin
  select * into s from public.email_settings where jenis = 'debtor';
  if not found or not s.aktif or not rc_private.zdage_aktif() then return; end if;
  -- Email depot: 02:05 kelompok A, 03:05 kelompok B; tidak pada Minggu / tanggal merah.
  if v_jam in (2, 3) and not rc_private.hari_libur_ini(v_tgl) then
    perform rc_private.email_debtor_bagian(s, true, null, true, (v_jam - 2)::smallint, false);
  end if;
  -- Laporan region / nasional: jam panel, hari yang dicentang (kosong = tiap hari).
  if v_jam = s.jam and (s.hari_list is null or cardinality(s.hari_list) = 0 or v_dow = any(s.hari_list)) then
    perform rc_private.email_debtor_bagian(s, true, null, false, null, true);
  end if;
end $f$;

revoke all on function rc_private.email_debtor_bagian(public.email_settings, boolean, text, boolean, smallint, boolean),
  rc_private.email_debtor_susun(public.email_settings, boolean, text), rc_private.debtor_jadwal(timestamptz) from public, anon, authenticated;

-- ---- 4. Tick, panel ------------------------------------------------------------------------------
do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('public.rc_email_tick()'::regprocedure), E'\r', '');
  if src !~ '20261164060000' then
    src := pg_temp.ganti(src, $p$  for s in select * from public.email_settings where aktif and jenis <> 'pengajuan' loop$p$,
      $p$  -- 20261164060000: jenis debtor punya jadwal sendiri (rc_private.debtor_jadwal).
  for s in select * from public.email_settings where aktif and jenis not in ('pengajuan', 'debtor') loop$p$, 1, 'tick loop');
    src := pg_temp.ganti(src, $p$  -- 20261163380000: rekap email Expired per kloter 12:00 / 16:00.$p$,
      $p$  begin
    perform rc_private.debtor_jadwal(sekarang); -- 20261164060000
  exception when others then
    insert into public.activity_logs(event_type, details)
    values ('email_terjadwal_gagal', jsonb_build_object('jenis', 'debtor', 'sebab', left(sqlerrm, 500)));
  end;

  -- 20261163380000: rekap email Expired per kloter 12:00 / 16:00.$p$, 1, 'tick debtor');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_email_status()'::regprocedure), E'\r', '');
  if src !~ '20261164060000' then
    src := pg_temp.ganti(src, $p$        'jenjang',case when jenis = 'debtor' then rc_private.debtor_jenjang() end,$p$,
      $p$        'jenjang',case when jenis = 'debtor' then rc_private.debtor_jenjang() end,
        'hariLibur',case when jenis = 'debtor' then rc_private.hari_libur_teks() end, /* 20261164060000 */$p$, 1, 'status libur');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_email_settings_simpan(jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261164060000' then
    src := pg_temp.ganti(src, $p$    if lower(btrim(r->>'jenis')) = 'debtor' and r ? 'jenjang' then$p$,
      $p$    if lower(btrim(r->>'jenis')) = 'debtor' and r ? 'hariLibur' then
      perform rc_private.hari_libur_simpan(r->>'hariLibur'); -- 20261164060000
    end if;
    if lower(btrim(r->>'jenis')) = 'debtor' and r ? 'jenjang' then$p$, 1, 'simpan libur');
    execute src;
  end if;
end $tambal$;

update public.email_settings
   set catatan = 'Peringatan toko lunas (ZDAGE) yang belum diproses depot. Email depot (TO Kepala Admin, NPC, Kepala Depot; CC kolom CC email depot; seluruh toko lunas belum diproses, kolom Auto-Expiring) setiap hari kecuali Minggu dan tanggal merah, kelompok A 02:00 dan B 03:00 WIB. Pada jam dan hari yang dicentang: laporan per region untuk toko jenjang 1-2 (TO RSM + ASM; CC OSC, Kepala Depot, Kepala Admin + CC jenjang) dan satu laporan nasional semua region untuk toko jenjang 3 (CC jenjang 3).'
 where jenis = 'debtor';

do $cek$ begin
  if pg_get_functiondef('public.rc_email_tick()'::regprocedure) !~ 'debtor_jadwal' then raise exception 'GAGAL: tick'; end if;
  if pg_get_functiondef('rc_private.debtor_email_depot_html(uuid,jsonb)'::regprocedure) !~ 'AUTO-EXPIRING' then raise exception 'GAGAL: kolom'; end if;
  if pg_get_functiondef('public.rc_email_status()'::regprocedure) !~ 'hariLibur' then raise exception 'GAGAL: status'; end if;
  if pg_get_functiondef('public.rc_email_settings_simpan(jsonb)'::regprocedure) !~ 'hari_libur_simpan' then raise exception 'GAGAL: simpan'; end if;
  if not rc_private.hari_libur_ini('2026-12-25') or not rc_private.hari_libur_ini('2026-11-22') or rc_private.hari_libur_ini('2026-11-23') then
    raise exception 'GAGAL: hari libur'; end if;
end $cek$;
