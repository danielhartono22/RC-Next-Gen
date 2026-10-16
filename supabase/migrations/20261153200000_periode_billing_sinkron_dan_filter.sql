-- ==========================================================================================
-- Periode SO/Billing disinkronkan, dan Report memperoleh penyaring tahun serta periode Billing
-- ==========================================================================================
-- Kelanjutan 20261150. Permintaan pemilik:
--
--   "perbarui template upload juga dan sinkronisasikan dengan on hold process dan document
--    center. di modul report ditambahkan filter campaign year dan start dan end periode
--    patokan billing aja."
--
-- ------------------------------------------------------------------------------------------
-- SINKRONISASI: MASTER MENJADI ACUAN, DOKUMEN MENIMPANYA
-- ------------------------------------------------------------------------------------------
-- Layar Reprocessing (On Hold) menampilkan periode SO dan Billing dari kolom perpanjangan pada
-- dokumen - extend_so_start dan kawan-kawannya. Kolom itu hanya terisi bila seseorang memang
-- memperpanjangnya, sehingga sebagian besar baris tampil sebagai "-" padahal periodenya jelas:
-- yang berlaku adalah periode campaign-nya.
--
-- Sekarang keduanya berlapis - dokumen menimpa master, master menjadi dasar:
--
--   yang ditampilkan = coalesce(perpanjangan pada dokumen, periode pada Campaign Master)
--
-- Nilai yang tersimpan pada dokumen TIDAK disentuh. Yang berubah hanya apa yang dibaca layar
-- ketika dokumen itu tidak punya perpanjangan sendiri.
--
-- ------------------------------------------------------------------------------------------
-- PENYARING REPORT MEMAKAI BILLING, DAN HANYA BILLING
-- ------------------------------------------------------------------------------------------
-- Pemilik menegaskan "patokan billing aja". Jadi penyaring periode membandingkan periode BILLING
-- efektif tiap baris, bukan periode campaign dan bukan tanggal clearing. Sebuah baris ikut bila
-- periode billing-nya BERSINGGUNGAN dengan rentang yang diminta - bukan harus termuat seluruhnya
-- di dalamnya - karena periode yang melintasi batas rentang tetap relevan bagi yang mencarinya.
--
-- Tahun campaign mengikuti cara yang sudah dipakai layar sejak lama (getValidYear): tahun dari
-- Periode Start campaign. Ditulis ulang di SQL supaya penyaringnya bekerja atas seluruh data,
-- bukan hanya atas baris yang kebetulan sudah termuat di browser.
--
-- Baris yang periodenya kosong tidak ikut ketika penyaring dipakai, dan tetap ikut ketika tidak.
-- Menganggapnya "cocok" akan membuat penyaring terasa tidak bekerja.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 0. Pengurai tanggal dijadikan SECURITY DEFINER
-- ------------------------------------------------------------------------------------------
-- rc_private.urai_tanggal_rc memanggil rc_private.urai_tanggal, dan 'authenticated' tidak boleh
-- mengeksekusi yang terakhir. Selama ia INVOKER, setiap pemanggilan dari fungsi INVOKER - dan
-- penyaring Report di bawah adalah salah satunya - gagal dengan "permission denied".
--
-- Ia pengurai teks murni: tidak membaca satu tabel pun, tidak menerima apa pun selain sebuah
-- string, dan tidak mengembalikan apa pun selain tanggal. Menjalankannya sebagai pemilik tidak
-- membuka apa-apa.
create or replace function rc_private.urai_tanggal_rc(p text)
returns date language plpgsql immutable security definer set search_path='' as $fn$
declare s text; d date; hh int; bb int; tt int;
begin
  s := btrim(coalesce(p,''));
  if s = '' then return null; end if;

  d := rc_private.urai_tanggal(s);
  if d is not null then return d; end if;

  if s ~ '^[0-9]{1,2}[-./][0-9]{1,2}[-./][0-9]{2}([0-9]{2})?$' then
    hh := split_part(regexp_replace(s,'[./]','-','g'),'-',1)::int;
    bb := split_part(regexp_replace(s,'[./]','-','g'),'-',2)::int;
    tt := split_part(regexp_replace(s,'[./]','-','g'),'-',3)::int;
  elsif s ~ '^[0-9]{6}$' then
    hh := substr(s,1,2)::int; bb := substr(s,3,2)::int; tt := substr(s,5,2)::int;
  elsif s ~ '^[0-9]{8}$' then
    hh := substr(s,1,2)::int; bb := substr(s,3,2)::int; tt := substr(s,5,4)::int;
  else
    return null;
  end if;

  if tt < 100 then tt := 2000 + tt; end if;
  if hh < 1 or hh > 31 or bb < 1 or bb > 12 then return null; end if;
  begin
    return make_date(tt, bb, hh);
  exception when others then return null;
  end;
end $fn$;
revoke all on function rc_private.urai_tanggal_rc(text) from public, anon;
grant execute on function rc_private.urai_tanggal_rc(text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 1. rc_report_rows membawa periode billing efektif dan tahun campaign
-- ------------------------------------------------------------------------------------------
do $mig$
declare def text;
begin
  def := pg_get_viewdef('public.rc_report_rows'::regclass, true);
  if position('billing_start' in def) > 0 then
    raise notice 'rc_report_rows sudah membawa periode billing; dilewati.'; return; end if;

  -- Definisi lama DIBUNGKUS sebagai subkueri, lalu kolom baru ditambahkan di sebelahnya.
  -- Menempelkan kolom ke ujung definisi aslinya tidak mungkin - definisi itu sudah punya FROM
  -- dan WHERE sendiri. Membungkusnya menjaga urutan dan nama kolom lama tetap persis, yang
  -- memang disyaratkan create or replace view, sekaligus membuat kolom baru muncul di belakang.
  execute 'create or replace view public.rc_report_rows as
    select v.*,
      coalesce(c2.extend_billing_start, ca2.billing_start) as billing_start,
      coalesce(c2.extend_billing_end,   ca2.billing_end)   as billing_end,
      coalesce(c2.extend_so_start,      ca2.so_start)      as so_start,
      coalesce(c2.extend_so_end,        ca2.so_end)        as so_end,
      extract(year from coalesce(ca2.period_start, ca2.period_end))::int as campaign_year
    from ( ' || rtrim(rtrim(def), ';') || ' ) v
    join public.claims c2 on c2.id = v.id
    join public.campaigns ca2 on ca2.id = c2.campaign_id';
  raise notice 'rc_report_rows membawa periode billing, SO, dan tahun campaign.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 2. Ketiga badan agregasi menerima penyaring baru
-- ------------------------------------------------------------------------------------------
-- Ditulis sekali sebagai potongan SQL, lalu disisipkan ke ketiganya - supaya penyaring yang
-- sama tidak mungkin berbeda tafsir antara Dashboard, Cost Center 1 dan Cost Center 2.
do $mig$
declare src text; baru text; nama text; n int := 0;
  v_dekl text := $p$  v_tahun_camp integer; v_bill_a date; v_bill_b date;$p$;
  v_baca text := $p$  v_tahun_camp := nullif(btrim(coalesce(p_filter->>'tahunCampaign','')),'')::integer;$p$ || chr(10) ||
                 $p$  v_bill_a := rc_private.urai_tanggal_rc(nullif(btrim(coalesce(p_filter->>'billingStart','')),''));$p$ || chr(10) ||
                 $p$  v_bill_b := rc_private.urai_tanggal_rc(nullif(btrim(coalesce(p_filter->>'billingEnd','')),''));$p$;
  -- Bersinggungan, bukan termuat: awal <= batas akhir DAN akhir >= batas awal.
  v_where text := $p$ and (v_tahun_camp is null or campaign_year = v_tahun_camp)$p$ || chr(10) ||
                  $p$       and (v_bill_a is null or (billing_end is not null and billing_end >= v_bill_a))$p$ || chr(10) ||
                  $p$       and (v_bill_b is null or (billing_start is not null and billing_start <= v_bill_b))$p$;
begin
  foreach nama in array array['report_dashboard','cost_center','cost_center_2'] loop
    select pg_get_functiondef(p.oid) into src from pg_proc p
      join pg_namespace n2 on n2.oid = p.pronamespace
     where n2.nspname='rc_private' and p.proname = nama;
    if src is null then raise exception 'rc_private.% tidak ditemukan.', nama; end if;
    if position('v_tahun_camp' in src) > 0 then
      raise notice '%: sudah menerima penyaring baru; dilewati.', nama;
      continue;
    end if;

    if position($q$declare v_region text;$q$ in src) = 0 then
      raise exception 'Pola deklarasi tidak ditemukan pada rc_private.%.', nama; end if;
    if position($q$  v_campaign := nullif(btrim(coalesce(p_filter->>'campaign','')),'');$q$ in src) = 0 then
      raise exception 'Pola pembacaan filter tidak ditemukan pada rc_private.%.', nama; end if;
    if position($q$       and (v_campaign is null or campaign_code = v_campaign)$q$ in src) = 0 then
      raise exception 'Pola penyaring campaign tidak ditemukan pada rc_private.%.', nama; end if;

    baru := src;
    baru := replace(baru, $q$declare v_region text;$q$,
                          $q$declare$q$ || chr(10) || v_dekl || chr(10) || $q$ v_region text;$q$);
    baru := replace(baru, $q$  v_campaign := nullif(btrim(coalesce(p_filter->>'campaign','')),'');$q$,
                          $q$  v_campaign := nullif(btrim(coalesce(p_filter->>'campaign','')),'');$q$ || chr(10) || v_baca);
    -- Seluruh kemunculan penyaring campaign ikut diberi penyaring baru: cost_center_2 memakainya
    -- lebih dari sekali, dan menambal yang pertama saja menghasilkan dua tab yang tidak sepakat.
    baru := replace(baru, $q$       and (v_campaign is null or campaign_code = v_campaign)$q$,
                          $q$       and (v_campaign is null or campaign_code = v_campaign)$q$ || chr(10) || v_where);

    execute baru;
    n := n + 1;
    raise notice '%: menerima tahunCampaign, billingStart, billingEnd.', nama;
  end loop;
  raise notice 'Badan agregasi diperbarui: %.', n;
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 3. Reprocessing (On Hold) memakai periode campaign bila dokumen tidak memperpanjang
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='rc_reprocessing_list';
  if src is null then raise exception 'public.rc_reprocessing_list tidak ditemukan.'; end if;
  if position('coalesce(c.extend_so_start' in src) > 0 then
    raise notice 'rc_reprocessing_list sudah berlapis; dilewati.'; return; end if;

  if position($q$      'soStart',c.extend_so_start,'soEnd',c.extend_so_end,$q$ in src) = 0 then
    raise exception 'Pola periode tidak ditemukan pada rc_reprocessing_list.'; end if;

  baru := replace(src,
    $q$      'soStart',c.extend_so_start,'soEnd',c.extend_so_end,$q$,
    $q$      'soStart',coalesce(c.extend_so_start,ca.so_start),'soEnd',coalesce(c.extend_so_end,ca.so_end),$q$);
  baru := replace(baru,
    $q$'billingStart',c.extend_billing_start,'billingEnd',c.extend_billing_end,$q$,
    $q$'billingStart',coalesce(c.extend_billing_start,ca.billing_start),$q$ || chr(10) ||
    $q$      'billingEnd',coalesce(c.extend_billing_end,ca.billing_end),$q$);
  if baru = src then raise exception 'Penggantian periode Reprocessing gagal.'; end if;

  execute baru;
  raise notice 'rc_reprocessing_list memakai periode Campaign Master sebagai dasar.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 4. Document Center membawa kedua periode
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='rc_compilation_list';
  if src is null then raise exception 'public.rc_compilation_list tidak ditemukan.'; end if;
  if position($q$'soStart'$q$ in src) > 0 then
    raise notice 'rc_compilation_list sudah membawa periode; dilewati.'; return; end if;

  if position($q$'statusPajak',coalesce(ca.tax_status,'')$q$ in src) = 0 then
    raise exception 'Pola baris tidak ditemukan pada rc_compilation_list.'; end if;

  baru := replace(src, $q$'statusPajak',coalesce(ca.tax_status,'')$q$,
    $q$'soStart',coalesce(c.extend_so_start,ca.so_start),'soEnd',coalesce(c.extend_so_end,ca.so_end),$q$ || chr(10) ||
    $q$   'billingStart',coalesce(c.extend_billing_start,ca.billing_start),$q$ || chr(10) ||
    $q$   'billingEnd',coalesce(c.extend_billing_end,ca.billing_end),$q$ || chr(10) ||
    $q$   'statusPajak',coalesce(ca.tax_status,'')$q$);
  execute baru;
  raise notice 'rc_compilation_list membawa periode SO dan Billing.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_uid uuid; k text; h jsonb; n_semua int; n_saring int; v_tahun int; src text;
begin
  -- View membawa kolom barunya.
  foreach k in array array['billing_start','billing_end','so_start','so_end','campaign_year'] loop
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='rc_report_rows' and column_name=k) then
      raise exception 'GAGAL: rc_report_rows tidak membawa %.', k; end if;
  end loop;

  -- Ketiga badan menerima penyaringnya.
  foreach k in array array['report_dashboard','cost_center','cost_center_2'] loop
    select pg_get_functiondef(p.oid) into src from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='rc_private' and p.proname=k;
    if position('tahunCampaign' in src) = 0 or position('billingStart' in src) = 0 then
      raise exception 'GAGAL: rc_private.% belum menerima penyaring baru.', k; end if;
  end loop;

  -- Reprocessing dan Document Center berlapis.
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='rc_reprocessing_list';
  if position('coalesce(c.extend_so_start,ca.so_start)' in src) = 0 then
    raise exception 'GAGAL: Reprocessing belum memakai periode master.'; end if;

  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='rc_compilation_list';
  if position($q$'soStart'$q$ in src) = 0 then
    raise exception 'GAGAL: Document Center belum membawa periode.'; end if;

  -- Penyaringnya benar-benar menyaring.
  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);

  h := public.rc_cost_center('{}'::jsonb);
  n_semua := jsonb_array_length(h->'rows');

  select campaign_year into v_tahun from public.rc_report_rows
   where campaign_year is not null group by campaign_year order by count(*) desc limit 1;

  if v_tahun is not null then
    h := public.rc_cost_center(jsonb_build_object('tahunCampaign', v_tahun::text));
    n_saring := jsonb_array_length(h->'rows');
    if n_saring = 0 then
      reset role; raise exception 'GAGAL: tahun % menghasilkan nol baris.', v_tahun; end if;
    if n_saring > n_semua then
      reset role; raise exception 'GAGAL: penyaring tahun justru memperluas hasil.'; end if;
  end if;

  -- Tahun karangan harus kosong, dan rentang billing mustahil juga kosong.
  if jsonb_array_length(public.rc_cost_center(
       jsonb_build_object('tahunCampaign','1900'))->'rows') <> 0 then
    reset role; raise exception 'GAGAL: tahun karangan tetap mengembalikan baris.'; end if;
  if jsonb_array_length(public.rc_cost_center(
       jsonb_build_object('billingStart','01-01-1900','billingEnd','31-12-1900'))->'rows') <> 0 then
    reset role; raise exception 'GAGAL: rentang billing mustahil tetap mengembalikan baris.'; end if;

  -- Tanpa penyaring, hasilnya harus tetap utuh seperti semula.
  if jsonb_array_length(public.rc_cost_center('{}'::jsonb)->'rows') <> n_semua then
    reset role; raise exception 'GAGAL: hasil tanpa penyaring berubah.'; end if;

  perform public.rc_report_dashboard('{}'::jsonb);
  perform public.rc_cost_center_2(jsonb_build_object('tahunCampaign', coalesce(v_tahun::text,'2026')));
  reset role;

  raise notice 'Tahun campaign %: % dari % baris.', v_tahun, n_saring, n_semua;
  raise notice 'Pemeriksaan lolos.';
exception when others then
  reset role; raise;
end
$periksa$;
