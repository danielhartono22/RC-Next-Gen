-- ==========================================================================================
-- Campaign Master: periode SO date dan periode Billing date
-- ==========================================================================================
-- Permintaan pemilik: "untuk campaign master ada periode start dan end so date, periode start
-- dan end billing date".
--
-- Sampai kini Campaign Master hanya memegang SATU periode - period_start dan period_end - dan
-- periode itulah yang dipakai sebagai patokan segala hal. Padahal dokumen membedakan keduanya
-- sejak lama: claims.extend_so_start/end dan claims.extend_billing_start/end sudah ada, dan
-- layar Reprocessing sudah menampilkannya sebagai dua baris terpisah. Yang belum ada adalah
-- ACUANNYA di master, sehingga setiap dokumen harus mengisinya sendiri dan tidak ada yang dapat
-- dibandingkan ketika isian itu kosong.
--
-- ------------------------------------------------------------------------------------------
-- TEKS DAN TANGGAL DISIMPAN BERDAMPINGAN
-- ------------------------------------------------------------------------------------------
-- Mengikuti pola yang sudah ada pada period_start_text/period_start: yang DIKETIK disimpan apa
-- adanya, dan hasil uraiannya disimpan sebagai date di sebelahnya. Teksnya berguna ketika
-- uraian gagal - "1-Oktober-26" dan "01-May-24" sama-sama ada di data ini - sehingga yang tidak
-- terurai tetap terlihat dan dapat diperbaiki, bukan hilang menjadi NULL tanpa jejak.
--
-- Berbeda dari period_start yang dulu diisi lewat migration satu kali, keempat pasangan baru ini
-- diurai DI DALAM upsert-nya. Jadi campaign yang dibuat atau disunting sesudah ini langsung
-- punya tanggalnya, tanpa menunggu perbaikan berikutnya.
--
-- ------------------------------------------------------------------------------------------
-- YANG TIDAK DISENTUH
-- ------------------------------------------------------------------------------------------
-- period_start dan period_end dibiarkan apa adanya, beserta seluruh pemakainya - Timetable,
-- aging, gross up, dan penurunan periode dokumen. Pemilik meminta penambahan, bukan penggantian.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

alter table public.campaigns
  add column if not exists so_start_text      text,
  add column if not exists so_end_text        text,
  add column if not exists billing_start_text text,
  add column if not exists billing_end_text   text,
  add column if not exists so_start           date,
  add column if not exists so_end             date,
  add column if not exists billing_start      date,
  add column if not exists billing_end        date;

comment on column public.campaigns.so_start is
  'Awal periode SO date campaign. Menjadi acuan dokumen yang tidak mengisi extend_so_start.';
comment on column public.campaigns.billing_start is
  'Awal periode Billing date campaign. Dipakai penyaring periode pada modul Report.';

create index if not exists campaigns_billing_idx on public.campaigns(billing_start, billing_end);

-- ------------------------------------------------------------------------------------------
-- 0. Pengurai tanggal yang menerima bentuk resmi RC maupun bentuk warisan
-- ------------------------------------------------------------------------------------------
-- rc_private.urai_tanggal hanya mengenali bentuk warisan "1-Jan-26" - itulah bentuk yang dipakai
-- kolom periode lama, dan ia TIDAK disentuh karena banyak yang bergantung padanya.
--
-- Tetapi periode baru ini juga masuk lewat unggahan Excel, dan di sana yang diketik orang adalah
-- enam bentuk resmi yang berlaku di seluruh sistem: dd-mm-yyyy, dd.mm.yyyy, dd-mm-yy, dd.mm.yy,
-- ddmmyyyy dan ddmmyy. Tanpa pengurai yang mengenali keduanya, satu kolom tanggal akan diam-diam
-- menjadi NULL hanya karena pemisahnya titik alih-alih strip.
--
-- Bentuk warisan dicoba lebih dulu supaya "1-Jan-26" tidak salah dibaca sebagai angka.
create or replace function rc_private.urai_tanggal_rc(p text)
-- SECURITY DEFINER: ia memanggil rc_private.urai_tanggal, yang tidak boleh dieksekusi
-- 'authenticated'. Tanpa ini setiap pemanggilan dari fungsi INVOKER - misalnya penyaring
-- Report - gagal dengan 'permission denied', persis pelajaran yang sudah pernah
-- menghentikan modul Report. Ia murni pengurai teks dan tidak menyentuh data apa pun.
returns date language plpgsql immutable security definer set search_path='' as $fn$
declare s text; d date; hh int; bb int; tt int;
begin
  s := btrim(coalesce(p,''));
  if s = '' then return null; end if;

  d := rc_private.urai_tanggal(s);
  if d is not null then return d; end if;

  -- dd-mm-yyyy, dd.mm.yyyy, dd/mm/yyyy dan bentuk dua digit tahunnya.
  if s ~ '^[0-9]{1,2}[-./][0-9]{1,2}[-./][0-9]{2}([0-9]{2})?$' then
    hh := split_part(regexp_replace(s,'[./]','-','g'),'-',1)::int;
    bb := split_part(regexp_replace(s,'[./]','-','g'),'-',2)::int;
    tt := split_part(regexp_replace(s,'[./]','-','g'),'-',3)::int;
  -- ddmmyyyy dan ddmmyy, tanpa pemisah.
  elsif s ~ '^[0-9]{6}$' then
    hh := substr(s,1,2)::int; bb := substr(s,3,2)::int; tt := substr(s,5,2)::int;
  elsif s ~ '^[0-9]{8}$' then
    hh := substr(s,1,2)::int; bb := substr(s,3,2)::int; tt := substr(s,5,4)::int;
  else
    return null;
  end if;

  if tt < 100 then tt := 2000 + tt; end if;
  if hh < 1 or hh > 31 or bb < 1 or bb > 12 then return null; end if;
  -- Tanggal yang tidak ada pada kalender - 31 April, 30 Februari - dikembalikan NULL, bukan
  -- digeser diam-diam ke tanggal terdekat.
  begin
    return make_date(tt, bb, hh);
  exception when others then return null;
  end;
end $fn$;
revoke all on function rc_private.urai_tanggal_rc(text) from public, anon;
grant execute on function rc_private.urai_tanggal_rc(text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 1. Upsert menerima keempat pasangan, mengurai, dan memeriksa urutannya
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text; i int; n int := 0;
  ubah text[][] := array[
    -- kolom yang dikenali
    [$p$   if k not in('codeCampaign','campaignName','periodStart','periodEnd','jenisCb','statusPajak','status')$p$,
     $p$   if k not in('codeCampaign','campaignName','periodStart','periodEnd','jenisCb','statusPajak','status',$p$ || chr(10) ||
     $p$               'soStart','soEnd','billingStart','billingEnd')$p$],
    -- pemeriksaan urutan, tepat sebelum baris ditulis
    [$p$  select exists(select 1 from public.campaigns where campaign_code=code) into sudah;$p$,
     $p$  -- Periode yang terbalik hampir selalu salah ketik, dan diamkan sekali saja ia akan$p$ || chr(10) ||
     $p$  -- menyaring habis laporan tanpa ada yang tahu sebabnya. Ditolak di sini, bukan nanti.$p$ || chr(10) ||
     $p$  v_so_a := rc_private.urai_tanggal_rc(nullif(btrim(coalesce(r->>'soStart','')),''));$p$ || chr(10) ||
     $p$  v_so_b := rc_private.urai_tanggal_rc(nullif(btrim(coalesce(r->>'soEnd','')),''));$p$ || chr(10) ||
     $p$  v_bi_a := rc_private.urai_tanggal_rc(nullif(btrim(coalesce(r->>'billingStart','')),''));$p$ || chr(10) ||
     $p$  v_bi_b := rc_private.urai_tanggal_rc(nullif(btrim(coalesce(r->>'billingEnd','')),''));$p$ || chr(10) ||
     $p$  if v_so_a is not null and v_so_b is not null and v_so_b < v_so_a then$p$ || chr(10) ||
     $p$   raise exception 'Periode SO terbalik pada %: % sampai %',code,r->>'soStart',r->>'soEnd'; end if;$p$ || chr(10) ||
     $p$  if v_bi_a is not null and v_bi_b is not null and v_bi_b < v_bi_a then$p$ || chr(10) ||
     $p$   raise exception 'Periode Billing terbalik pada %: % sampai %',code,r->>'billingStart',r->>'billingEnd'; end if;$p$ || chr(10) ||
     $p$  select exists(select 1 from public.campaigns where campaign_code=code) into sudah;$p$],
    -- penyuntingan
    [$p$    status=case when st <> '' then st else status end$p$,
     $p$    status=case when st <> '' then st else status end,$p$ || chr(10) ||
     $p$    so_start_text=case when r ? 'soStart' then nullif(btrim(r->>'soStart'),'') else so_start_text end,$p$ || chr(10) ||
     $p$    so_end_text=case when r ? 'soEnd' then nullif(btrim(r->>'soEnd'),'') else so_end_text end,$p$ || chr(10) ||
     $p$    billing_start_text=case when r ? 'billingStart' then nullif(btrim(r->>'billingStart'),'') else billing_start_text end,$p$ || chr(10) ||
     $p$    billing_end_text=case when r ? 'billingEnd' then nullif(btrim(r->>'billingEnd'),'') else billing_end_text end,$p$ || chr(10) ||
     $p$    so_start=case when r ? 'soStart' then v_so_a else so_start end,$p$ || chr(10) ||
     $p$    so_end=case when r ? 'soEnd' then v_so_b else so_end end,$p$ || chr(10) ||
     $p$    billing_start=case when r ? 'billingStart' then v_bi_a else billing_start end,$p$ || chr(10) ||
     $p$    billing_end=case when r ? 'billingEnd' then v_bi_b else billing_end end$p$],
    -- pembuatan baris baru
    [$p$   insert into public.campaigns(campaign_code,campaign_name,period_start_text,period_end_text,$p$ || chr(10) ||
     $p$     cashback_type,tax_status,status,created_by)$p$,
     $p$   insert into public.campaigns(campaign_code,campaign_name,period_start_text,period_end_text,$p$ || chr(10) ||
     $p$     cashback_type,tax_status,status,created_by,$p$ || chr(10) ||
     $p$     so_start_text,so_end_text,billing_start_text,billing_end_text,$p$ || chr(10) ||
     $p$     so_start,so_end,billing_start,billing_end)$p$],
    [$p$     case when st <> '' then st else 'active' end, aku);$p$,
     $p$     case when st <> '' then st else 'active' end, aku,$p$ || chr(10) ||
     $p$     nullif(btrim(coalesce(r->>'soStart','')),''),nullif(btrim(coalesce(r->>'soEnd','')),''),$p$ || chr(10) ||
     $p$     nullif(btrim(coalesce(r->>'billingStart','')),''),nullif(btrim(coalesce(r->>'billingEnd','')),''),$p$ || chr(10) ||
     $p$     v_so_a,v_so_b,v_bi_a,v_bi_b);$p$],
    -- variabel bantu
    [$p$ st text; aku uuid:=(select auth.uid());$p$,
     $p$ st text; aku uuid:=(select auth.uid());$p$ || chr(10) ||
     $p$ v_so_a date; v_so_b date; v_bi_a date; v_bi_b date;$p$]
  ];
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='campaign_upsert';
  if src is null then raise exception 'rc_private.campaign_upsert tidak ditemukan.'; end if;

  if position('billingStart' in src) > 0 then
    raise notice 'campaign_upsert sudah menerima periode SO dan Billing; dilewati.'; return; end if;

  baru := src;
  for i in 1 .. array_length(ubah,1) loop
    if position(ubah[i][1] in baru) = 0 then
      raise exception 'Pola ke-% tidak ditemukan pada campaign_upsert: %', i, left(ubah[i][1], 90);
    end if;
    baru := replace(baru, ubah[i][1], ubah[i][2]);
    n := n + 1;
  end loop;

  execute baru;
  raise notice 'campaign_upsert menerima periode SO dan Billing (% pola).', n;
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 2. Daftar campaign membawanya ke layar
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='rc_campaign_list';
  if src is null then raise exception 'public.rc_campaign_list tidak ditemukan.'; end if;
  if position($q$'soStart'$q$ in src) > 0 then
    raise notice 'rc_campaign_list sudah membawa periode baru; dilewati.'; return; end if;

  if position($q$'jenisCb',rc_private.cb_label(ca.cashback_type)$q$ in src) = 0 then
    raise exception 'Pola baris campaign tidak ditemukan pada rc_campaign_list.'; end if;

  baru := replace(src, $q$'jenisCb',rc_private.cb_label(ca.cashback_type)$q$,
    $q$'soStart',rc_private.legacy_date(ca.so_start),'soEnd',rc_private.legacy_date(ca.so_end),$q$ || chr(10) ||
    $q$   'billingStart',rc_private.legacy_date(ca.billing_start),'billingEnd',rc_private.legacy_date(ca.billing_end),$q$ || chr(10) ||
    $q$   'jenisCb',rc_private.cb_label(ca.cashback_type)$q$);
  execute baru;
  raise notice 'rc_campaign_list membawa periode SO dan Billing.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare k text; v_uid uuid; h jsonb; baris jsonb; kode text;
begin
  foreach k in array array['so_start_text','so_end_text','billing_start_text','billing_end_text',
                           'so_start','so_end','billing_start','billing_end'] loop
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='campaigns' and column_name=k) then
      raise exception 'GAGAL: kolom campaigns.% tidak terbentuk.', k; end if;
  end loop;

  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;
  select campaign_code into kode from public.campaigns where archived_at is null order by campaign_code limit 1;
  -- Tanpa campaign, pengujian upsert tidak punya bahan, tetapi kolom dan fungsinya sudah
  -- terpasang di atas. Dilewati dengan jejak - menggagalkannya menggulung balik kolom
  -- billing_start, lalu tiga migrasi sesudahnya runtuh karena kolom itu tidak ada.
  if kode is null then
    raise notice 'Belum ada campaign; pengujian periode dilewati.'; return; end if;

  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text,'role','authenticated')::text, true);

    -- Menulis keempatnya, lalu membacanya kembali lewat daftar.
    perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object(
      'codeCampaign', kode,
      'soStart','01-01-2026','soEnd','31-03-2026',
      'billingStart','01-02-2026','billingEnd','30-04-2026')));

    h := public.rc_campaign_list(kode, 0, 5);
    reset role;

    select x into baris from jsonb_array_elements(h->'rows') x where x->>'codeCampaign' = kode;
    if baris is null then raise exception 'GAGAL: campaign % tidak ditemukan pada daftar.', kode; end if;
    foreach k in array array['soStart','soEnd','billingStart','billingEnd'] loop
      if coalesce(baris->>k,'') = '' then
        raise exception 'GAGAL: % kosong pada daftar campaign.', k; end if;
    end loop;

    -- Tanggalnya benar-benar terurai, bukan sekadar tersimpan sebagai teks.
    if not exists (select 1 from public.campaigns where campaign_code=kode
                    and so_start='2026-01-01' and so_end='2026-03-31'
                    and billing_start='2026-02-01' and billing_end='2026-04-30') then
      raise exception 'GAGAL: tanggal tidak terurai dengan benar.'; end if;

    -- Periode terbalik harus ditolak.
    begin
      set local role authenticated;
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text,'role','authenticated')::text, true);
      perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object(
        'codeCampaign', kode, 'billingStart','30-04-2026','billingEnd','01-02-2026')));
      reset role;
      raise exception 'GAGAL: periode Billing terbalik diterima.';
    exception when others then
      reset role;
      if sqlerrm like 'GAGAL:%' then raise; end if;
    end;

    raise notice 'Periode SO dan Billing tersimpan, terurai, dan urutannya dijaga.';
    raise exception 'BATALKAN_UJI';
  exception when others then
    reset role;
    if sqlerrm like 'GAGAL:%' then raise; end if;
    if sqlerrm <> 'BATALKAN_UJI' then
      raise exception 'GAGAL: uji periode campaign gagal -> %', sqlerrm; end if;
  end;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
