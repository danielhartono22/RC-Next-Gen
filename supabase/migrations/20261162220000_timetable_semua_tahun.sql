-- ==========================================================================================
-- Timetable: pilihan Semua Tahun Campaign
-- ==========================================================================================
-- Tahun individual tetap memakai tahun Periode Start Campaign Master (Periode End sebagai
-- fallback). Nilai khusus ALL menggabungkan seluruh campaign yang memiliki tahun. Filter yang
-- sama berlaku ke KPI, grafik, Top 10, tabel, matriks, dan export di browser.
--
-- Bila tahunCampaign tidak dikirim, perilaku lama tetap dipertahankan: tahun Jakarta saat ini
-- bila tersedia, atau tahun terbaru. Dengan begitu pemanggil lama tidak mendadak mengambil
-- seluruh tahun; hanya pilihan ALL yang eksplisit yang melakukannya.
-- ==========================================================================================

do $mig$
declare
  src text;
  baru text;
  n integer;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and p.proname='rc_timetable_matrix'
     and pg_get_function_identity_arguments(p.oid)='p_filter jsonb';
  if src is null then raise exception 'public.rc_timetable_matrix(jsonb) tidak ditemukan.'; end if;
  if position('20261162220000: Semua Tahun' in src)>0 then
    raise notice 'Timetable Semua Tahun sudah terpasang; dilewati.';
    return;
  end if;

  baru := src;

  n := (length(baru)-length(replace(baru,$p$  v_tahun integer;$p$,''))) / length($p$  v_tahun integer;$p$);
  if n<>1 then raise exception 'Deklarasi v_tahun ditemukan % kali, diharapkan 1.',n; end if;
  baru := replace(baru,$p$  v_tahun integer;$p$,
    $p$  v_tahun integer;
  v_semua_tahun boolean := false; -- 20261162220000: Semua Tahun$p$);

  n := (length(baru)-length(replace(baru,
    $p$  if v_tahun_teks is not null and v_tahun_teks !~ '^[0-9]{4}$' then
    raise exception 'Tahun Campaign harus empat digit.';
  end if;
  v_tahun := v_tahun_teks::integer;$p$,''))) /
    length($p$  if v_tahun_teks is not null and v_tahun_teks !~ '^[0-9]{4}$' then
    raise exception 'Tahun Campaign harus empat digit.';
  end if;
  v_tahun := v_tahun_teks::integer;$p$);
  if n<>1 then raise exception 'Blok validasi tahun ditemukan % kali, diharapkan 1.',n; end if;
  baru := replace(baru,
    $p$  if v_tahun_teks is not null and v_tahun_teks !~ '^[0-9]{4}$' then
    raise exception 'Tahun Campaign harus empat digit.';
  end if;
  v_tahun := v_tahun_teks::integer;$p$,
    $p$  if upper(coalesce(v_tahun_teks,''))='ALL' then
    v_semua_tahun := true;
    v_tahun := null;
  elsif v_tahun_teks is not null and v_tahun_teks !~ '^[0-9]{4}$' then
    raise exception 'Tahun Campaign harus empat digit atau ALL.';
  else
    v_tahun := v_tahun_teks::integer;
  end if;$p$);

  n := (length(baru)-length(replace(baru,$p$  if v_tahun is null then$p$,''))) / length($p$  if v_tahun is null then$p$);
  if n<>1 then raise exception 'Blok default tahun ditemukan % kali, diharapkan 1.',n; end if;
  baru := replace(baru,$p$  if v_tahun is null then$p$,
                      $p$  if v_tahun is null and not v_semua_tahun then$p$);

  n := (length(baru)-length(replace(baru,$p$  elsif not exists($p$,''))) / length($p$  elsif not exists($p$);
  if n<>1 then raise exception 'Blok tahun tidak tersedia ditemukan % kali, diharapkan 1.',n; end if;
  baru := replace(baru,$p$  elsif not exists($p$,
                      $p$  elsif not v_semua_tahun and not exists($p$);

  n := (length(baru)-length(replace(baru,
    $p$extract(year from coalesce(ca.period_start,ca.period_end))::integer=v_tahun$p$,''))) /
    length($p$extract(year from coalesce(ca.period_start,ca.period_end))::integer=v_tahun$p$);
  if n<>3 then raise exception 'Penyaring tahun ditemukan % kali, diharapkan 3.',n; end if;
  baru := replace(baru,
    $p$extract(year from coalesce(ca.period_start,ca.period_end))::integer=v_tahun$p$,
    $p$(coalesce(ca.period_start,ca.period_end) is not null and
         (v_semua_tahun or extract(year from coalesce(ca.period_start,ca.period_end))::integer=v_tahun))$p$);

  n := (length(baru)-length(replace(baru,$p$      'tahunCampaign',v_tahun,$p$,''))) /
       length($p$      'tahunCampaign',v_tahun,$p$);
  if n<>1 then raise exception 'Respons tahunCampaign ditemukan % kali, diharapkan 1.',n; end if;
  baru := replace(baru,$p$      'tahunCampaign',v_tahun,$p$,
    $p$      'tahunCampaign',case when v_semua_tahun then 'ALL' else v_tahun::text end,
      'semuaTahun',v_semua_tahun,$p$);

  execute baru;
  raise notice 'Timetable menerima pilihan Semua Tahun.';
end
$mig$;

-- Pemeriksaan kontrak dan hitungan. Tidak mengubah data bisnis.
do $uji$
declare
  v_sm uuid;
  h jsonb;
  n integer;
  total integer;
begin
  select id into v_sm from public.profiles
   where role='system manager' and status='active' and not must_change_password
   order by user_code limit 1;
  if v_sm is null then
    raise notice 'Pemeriksaan Semua Tahun dilewati: System Manager aktif tidak ditemukan.';
    return;
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',json_build_object(
    'sub',v_sm::text,'role','authenticated')::text,true);
  h := public.rc_timetable_matrix('{"tahunCampaign":"ALL"}'::jsonb);
  reset role;

  if h->>'status'<>'success' or h->>'tahunCampaign'<>'ALL'
     or coalesce((h->>'semuaTahun')::boolean,false) is not true then
    raise exception 'GAGAL: respons Semua Tahun tidak sesuai kontrak: %',h;
  end if;

  select count(*) into n from public.campaigns ca
   where ca.archived_at is null
     and coalesce(ca.period_start,ca.period_end) is not null
     and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id);
  if (h->>'campaignJumlah')::integer<>n then
    raise exception 'GAGAL: Semua Tahun memuat % campaign, seharusnya %.',h->>'campaignJumlah',n;
  end if;

  total := (h->'kpi'->>'campaign')::integer*(h->'kpi'->>'depot')::integer;
  if (h->'kpi'->>'total')::integer<>total then
    raise exception 'GAGAL: total Semua Tahun bukan Campaign x Depot.';
  end if;

  raise notice 'Semua Tahun: % campaign x % depot = % kombinasi; pemeriksaan lolos.',
    h->>'campaignJumlah',h->'kpi'->>'depot',h->'kpi'->>'total';
exception when others then
  reset role;
  raise;
end
$uji$;

notify pgrst,'reload schema';
