-- ==========================================================================================
-- Diagram pada email Daily dan Weekly
-- ==========================================================================================
-- Permintaan pemilik, 20 September 2026: "content email sudah ok tapi ada yang ketinggalan
-- yakni diagram nya".
--
-- Memang sengaja dilewati saat isi email disalin dari Apps Script. Catatannya masih ada pada
-- migration 20261031010000:
--
--   "SATU HAL YANG TIDAK DAPAT DISALIN: GAMBAR GRAFIK. Sistem lama menyisipkan grafik sebagai
--    gambar inline (cid:top5Chart dan seterusnya) yang digambar Apps Script lewat QuickChart.
--    Di sini email disusun di dalam PostgreSQL dan dikirim lewat pg_net; tidak ada yang dapat
--    menggambar PNG."
--
-- Kesimpulan itu terlalu cepat. Yang tidak bisa dilakukan PostgreSQL adalah MENGGAMBAR PNG,
-- bukan MERUJUKNYA. QuickChart menggambar dari URL: seluruh definisi grafik diletakkan pada
-- query string, dan layanannya mengembalikan PNG. Jadi email cukup memuat
--
--   <img src="https://quickchart.io/chart?c={...}">
--
-- dan gambarnya digambar di sisi QuickChart, persis sumber yang dipakai sistem lama. Bedanya
-- hanya cara menempelkannya - dulu lampiran inline (cid:), sekarang gambar jauh. Pembaca yang
-- mail client-nya memblokir gambar jauh tetap melihat seluruh tabel di bawahnya, sama seperti
-- dulu, karena tabelnya tidak diubah sama sekali.
--
-- ------------------------------------------------------------------------------------------
-- EMPAT DIAGRAM, MENGIKUTI EMPAT BAGIAN YANG SUDAH ADA
-- ------------------------------------------------------------------------------------------
--   Daily   Top 5 Depot dengan Clearing Rate Terendah   batang mendatar
--   Weekly  Top 10 Depot dengan Clearing Rate Terendah  batang mendatar
--   Weekly  Distribusi Status Claim                     donat
--   Weekly  Value Claim & Outstanding by Region         batang berpasangan
--
-- Warnanya TIDAK dipilih baru. Diagram depot memakai rc_private.warna_persen() - gradasi merah
-- #EA4335 ke hijau #34A853 yang sama dengan latar sel persentase di tabel, sehingga batang dan
-- selnya tidak mungkin bercerita berbeda. Diagram status memakai enam warna kelompok yang sudah
-- ditetapkan WEEKLY_STATUS_GROUPS, dan diagram region memakai biru #4285F4 untuk nilai klaim
-- serta merah #EA4335 untuk outstanding, mengikuti arti warna yang sudah berlaku di email.
--
-- ------------------------------------------------------------------------------------------
-- MENGAPA FUNGSI TERPISAH, BUKAN DITANAM DI rc_email_susun
-- ------------------------------------------------------------------------------------------
-- rc_email_susun panjang dan memuat dua email sekaligus. Menanam empat definisi grafik di
-- dalamnya berarti menambal belasan tempat pada fungsi yang sama. Dengan empat fungsi terpisah,
-- yang perlu disisipkan ke rc_email_susun hanyalah EMPAT baris - satu pemanggilan tepat di bawah
-- setiap judul.
--
-- Konsekuensinya diagram status dan region menghitung ulang agregatnya sendiri, tidak memakai
-- hasil hitungan yang sudah ada di dalam rc_email_susun. Itu disengaja: agregatnya kecil, email
-- hanya disusun sekali sehari, dan harganya jauh lebih murah daripada menambal satu fungsi
-- besar di banyak titik sekaligus.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Persen-encode untuk query string
-- ------------------------------------------------------------------------------------------
-- Definisi grafik adalah JSON dan memuat { } " , : yang harus dikodekan, atau URL-nya terpotong
-- di tengah. Dikerjakan per BYTE, bukan per karakter, supaya nama depot ber-UTF-8 tetap utuh.
create or replace function rc_private.url_encode(p text)
returns text language sql immutable set search_path='' as $fn$
  select coalesce(string_agg(
    case when b between 48 and 57      -- 0-9
           or b between 65 and 90      -- A-Z
           or b between 97 and 122     -- a-z
           or b in (45, 46, 95, 126)   -- - . _ ~
         then chr(b)
         else '%' || upper(lpad(to_hex(b), 2, '0')) end, '' order by i), '')
  from generate_series(0, octet_length(convert_to(coalesce(p,''),'UTF8')) - 1) as i,
       lateral (select get_byte(convert_to(coalesce(p,''),'UTF8'), i) as b) t;
$fn$;
revoke all on function rc_private.url_encode(text) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 2. URL gambar QuickChart
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.chart_url(p_konfig jsonb, p_lebar int, p_tinggi int)
returns text language sql immutable set search_path='' as $fn$
  select 'https://quickchart.io/chart?bkg=%23ffffff&w=' || p_lebar::text
      || '&h=' || p_tinggi::text || '&c=' || rc_private.url_encode(p_konfig::text);
$fn$;
revoke all on function rc_private.chart_url(jsonb,int,int) from public,anon;

-- Pembungkus <img> yang sama untuk keempat diagram: lebar dikunci 600px mengikuti lebar badan
-- email, max-width:100% supaya tidak meluber di ponsel, dan alt diisi judulnya supaya pembaca
-- yang gambarnya diblokir tetap tahu apa yang tidak tergambar.
create or replace function rc_private.email_gambar(p_konfig jsonb, p_judul text, p_tinggi int)
returns text language sql immutable set search_path='' as $fn$
  select '<div style="margin:10px 0 6px;"><img width="600" height="' || p_tinggi::text || '" '
      || 'style="display:block;width:100%;max-width:600px;height:auto;border:1px solid #e8eaed;'
      || 'border-radius:6px;" src="' || rc_private.html_aman(rc_private.chart_url(p_konfig,600,p_tinggi))
      || '" alt="' || rc_private.html_aman(p_judul) || '"></div>';
$fn$;
revoke all on function rc_private.email_gambar(jsonb,text,int) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 3. Diagram Top Depot - batang mendatar
-- ------------------------------------------------------------------------------------------
-- Menerima v_top yang SUDAH dihitung rc_email_susun, sehingga Daily (5 baris) dan Weekly
-- (10 baris) memakai fungsi yang sama dan angkanya dijamin sama dengan tabel di bawahnya.
create or replace function rc_private.email_chart_depot(p_top jsonb, p_judul text)
returns text language sql stable set search_path='' as $fn$
  select case when coalesce(jsonb_array_length(p_top),0) = 0 then ''
  else rc_private.email_gambar(
    jsonb_build_object(
      'type','horizontalBar',
      'data', jsonb_build_object(
        'labels', (select jsonb_agg(left(e->>'label',28) order by n)
                     from jsonb_array_elements(p_top) with ordinality t(e,n)),
        'datasets', jsonb_build_array(jsonb_build_object(
          'label','Clearing Rate (%)',
          'backgroundColor', (select jsonb_agg(rc_private.warna_persen((e->>'cr')::numeric) order by n)
                                from jsonb_array_elements(p_top) with ordinality t(e,n)),
          'data', (select jsonb_agg(round(((e->>'cr')::numeric) * 100, 1) order by n)
                     from jsonb_array_elements(p_top) with ordinality t(e,n))))),
      'options', jsonb_build_object(
        'legend', jsonb_build_object('display', false),
        'title', jsonb_build_object('display', true, 'text', p_judul, 'fontSize', 13),
        'scales', jsonb_build_object(
          'xAxes', jsonb_build_array(jsonb_build_object(
            'ticks', jsonb_build_object('beginAtZero', true, 'max', 100, 'fontSize', 10),
            'scaleLabel', jsonb_build_object('display', true, 'labelString','Clearing Rate (%)'))),
          'yAxes', jsonb_build_array(jsonb_build_object(
            'ticks', jsonb_build_object('fontSize', 10)))))),
    p_judul,
    greatest(180, 40 + coalesce(jsonb_array_length(p_top),0) * 26))
  end;
$fn$;
revoke all on function rc_private.email_chart_depot(jsonb,text) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 4. Diagram Distribusi Status Claim - donat
-- ------------------------------------------------------------------------------------------
-- Enam kelompok dan warnanya disalin persis dari blok WEEKLY_STATUS_GROUPS di rc_email_susun,
-- termasuk cara kelompok "Lainnya" menampung status yang tidak masuk lima kelompok pertama.
create or replace function rc_private.email_chart_status()
returns text language sql stable set search_path='' as $fn$
  with g as (
    select x.urut, x.label, x.warna, count(c.id) as qty
      from (values
        (1,'Done','#34A853',array['done']),
        (2,'Expired','#7B1E1E',array['expired']),
        (3,'Pending Depot','#EA4335',array['not_yet']),
        (4,'Pending OSC','#FF9900',array['submitted','released']),
        (5,'Pending Finance','#4285F4',array['claimed']),
        (6,'Lainnya','#9AA0A6',array[]::text[])
      ) as x(urut,label,warna,status_list)
      left join public.rc_report_rows c on
        case when x.urut = 6
             then c.status <> all(array['done','expired','not_yet','submitted','released','claimed'])
             else c.status = any(x.status_list) end
     group by x.urut, x.label, x.warna)
  select case when coalesce((select sum(qty) from g),0) = 0 then ''
  else rc_private.email_gambar(
    jsonb_build_object(
      'type','doughnut',
      'data', jsonb_build_object(
        'labels', (select jsonb_agg(label order by urut) from g where qty > 0),
        'datasets', jsonb_build_array(jsonb_build_object(
          'data', (select jsonb_agg(qty order by urut) from g where qty > 0),
          'backgroundColor', (select jsonb_agg(warna order by urut) from g where qty > 0),
          'borderColor', '#ffffff', 'borderWidth', 2))),
      'options', jsonb_build_object(
        'title', jsonb_build_object('display', true, 'text','Distribusi Status Claim', 'fontSize', 13),
        'legend', jsonb_build_object('position','right',
          'labels', jsonb_build_object('fontSize', 11, 'boxWidth', 12)))),
    'Distribusi Status Claim', 260)
  end;
$fn$;
revoke all on function rc_private.email_chart_status() from public,anon;

-- ------------------------------------------------------------------------------------------
-- 5. Diagram Value Claim & Outstanding by Region - batang berpasangan
-- ------------------------------------------------------------------------------------------
-- Nilainya dalam JUTA rupiah. Rupiah penuh membuat sumbu memuat angka belasan digit yang tidak
-- terbaca pada lebar 600px, dan tabel di bawahnya sudah memuat angka penuhnya.
create or replace function rc_private.email_chart_region()
returns text language sql stable set search_path='' as $fn$
  with q as (
    select coalesce(nullif(btrim(region),''),'(tanpa region)') as region,
           coalesce(sum(cb_net),0) as net_cb,
           coalesce(sum(cb_net) filter (where outstanding),0) as os_val
      from public.rc_report_rows
     group by 1
    having coalesce(sum(cb_net),0) > 0
     order by os_val desc
     limit 12)
  select case when not exists(select 1 from q) then ''
  else rc_private.email_gambar(
    jsonb_build_object(
      'type','bar',
      'data', jsonb_build_object(
        'labels', (select jsonb_agg(region order by os_val desc) from q),
        'datasets', jsonb_build_array(
          jsonb_build_object('label','Value Claim (Juta)','backgroundColor','#4285F4',
            'data', (select jsonb_agg(round(net_cb/1000000.0, 1) order by os_val desc) from q)),
          jsonb_build_object('label','Outstanding (Juta)','backgroundColor','#EA4335',
            'data', (select jsonb_agg(round(os_val/1000000.0, 1) order by os_val desc) from q)))),
      'options', jsonb_build_object(
        'title', jsonb_build_object('display', true,
          'text','Value Claim & Outstanding by Region (Juta Rupiah)', 'fontSize', 13),
        'legend', jsonb_build_object('position','bottom',
          'labels', jsonb_build_object('fontSize', 11, 'boxWidth', 12)),
        'scales', jsonb_build_object(
          'xAxes', jsonb_build_array(jsonb_build_object(
            'ticks', jsonb_build_object('fontSize', 10))),
          'yAxes', jsonb_build_array(jsonb_build_object(
            'ticks', jsonb_build_object('beginAtZero', true, 'fontSize', 10)))))),
    'Value Claim dan Outstanding by Region', 300)
  end;
$fn$;
revoke all on function rc_private.email_chart_region() from public,anon;

-- ------------------------------------------------------------------------------------------
-- 6. Menyisipkan keempatnya ke rc_email_susun
-- ------------------------------------------------------------------------------------------
-- Empat sisipan, masing-masing satu baris tepat di bawah judul bagiannya dan tepat di atas
-- tabelnya - urutan yang sama dengan sistem lama: judul, grafik, lalu tabel angkanya.
do $sisip$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rc_email_susun';
  if src is null then raise exception 'public.rc_email_susun tidak ditemukan.'; end if;

  if position('email_chart_depot' in src) > 0 then
    raise notice 'rc_email_susun sudah memuat diagram; dilewati.';
    return;
  end if;

  baru := src;

  -- Daily: Top 5
  baru := replace(baru,
    '||''<h3 style="font-size:15px;margin:22px 0 8px;">Top 5 Depot dengan Clearing Rate Terendah</h3>''' || chr(10)
      || '      ||rc_private.email_tabel_performa(v_top,''Depot'')',
    '||''<h3 style="font-size:15px;margin:22px 0 8px;">Top 5 Depot dengan Clearing Rate Terendah</h3>''' || chr(10)
      || '      ||rc_private.email_chart_depot(v_top,''Top 5 Depot dengan Clearing Rate Terendah'')' || chr(10)
      || '      ||rc_private.email_tabel_performa(v_top,''Depot'')');

  -- Weekly: Top 10
  baru := replace(baru,
    '||rc_private.email_tabel_performa(coalesce(v_top,''[]''::jsonb),''Depot'')',
    '||rc_private.email_chart_depot(coalesce(v_top,''[]''::jsonb),''Top 10 Depot dengan Clearing Rate Terendah'')' || chr(10)
      || '      ||rc_private.email_tabel_performa(coalesce(v_top,''[]''::jsonb),''Depot'')');

  -- Weekly: Distribusi Status Claim
  baru := replace(baru,
    'Distribusi Status Claim</h3>''',
    'Distribusi Status Claim</h3>''' || chr(10) || '      ||rc_private.email_chart_status()');

  -- Weekly: Value Claim & Outstanding by Region
  baru := replace(baru,
    'Value Claim &amp; Outstanding by Region</h3>''',
    'Value Claim &amp; Outstanding by Region</h3>''' || chr(10) || '      ||rc_private.email_chart_region()');

  if baru = src then
    raise exception 'Tidak satu pun pola ditemukan pada public.rc_email_susun. '
      'Susunannya sudah berubah - periksa dan perbarui migration ini.';
  end if;

  execute baru;
  raise notice 'rc_email_susun: empat diagram disisipkan.';
end
$sisip$;

-- ------------------------------------------------------------------------------------------
-- 7. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text; n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='rc_private' and p.prokind='f'
     and p.proname in ('url_encode','chart_url','email_gambar',
                       'email_chart_depot','email_chart_status','email_chart_region');
  if n <> 6 then raise exception 'GAGAL: hanya % dari 6 fungsi diagram yang terpasang.', n; end if;

  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.proname='rc_email_susun';

  if position('email_chart_depot' in src) = 0
     or position('email_chart_status' in src) = 0
     or position('email_chart_region' in src) = 0 then
    raise exception 'GAGAL: rc_email_susun belum memanggil seluruh diagram.';
  end if;

  -- Daily dan Weekly masing-masing memanggil diagram depot, jadi harus muncul dua kali.
  if (length(src) - length(replace(src,'email_chart_depot',''))) / length('email_chart_depot') <> 2 then
    raise exception 'GAGAL: diagram depot tidak muncul tepat dua kali (Daily dan Weekly).';
  end if;

  -- Persen-encode harus benar, atau URL grafiknya terpotong di kurung kurawal pertama.
  if rc_private.url_encode('{"a":1}') <> '%7B%22a%22%3A1%7D' then
    raise exception 'GAGAL: url_encode menghasilkan %', rc_private.url_encode('{"a":1}');
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
