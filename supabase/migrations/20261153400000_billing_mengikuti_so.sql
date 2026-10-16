-- ==========================================================================================
-- Periode Billing mengikuti Periode SO selama billing dibiarkan kosong
-- ==========================================================================================
-- Ketetapan pemilik: "periode billing date start dan end untuk saat ini samakan dengan so."
--
-- Diterapkan sebagai ATURAN, bukan sebagai penyalinan sekali jalan. Alasannya sederhana: saat
-- ketetapan ini dibuat, so_start pun masih kosong pada seluruh campaign, sehingga menyalin
-- sekarang hanya memindahkan kosong ke kosong. Sebagai aturan, begitu tanggal SO diunggah,
-- billing langsung ikut - tanggalnya cukup diketik sekali.
--
-- Kata "untuk saat ini" dijaga artinya: billing yang BENAR-BENAR diisi tetap menang. Jadi
-- ketika suatu hari billing memang berbeda dari SO, tidak ada yang perlu dibongkar lagi -
-- cukup isi kolomnya.
--
-- Urutan yang berlaku untuk tiap kolom billing:
--   1. nilai billing yang diisi pada baris unggahan
--   2. nilai SO pada baris unggahan yang sama   <- aturan baru
--   3. nilai yang sudah tersimpan sebelumnya
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='campaign_upsert';
  if src is null then raise exception 'rc_private.campaign_upsert tidak ditemukan.'; end if;

  if position('billing mengikuti SO' in src) > 0 then
    raise notice 'campaign_upsert sudah memuat aturan billing-mengikuti-SO; dilewati.';
    return;
  end if;

  -- ---- a. Dua penampung teks tambahan ----------------------------------------------------
  if position(' v_so_a date; v_so_b date; v_bi_a date; v_bi_b date;' in src) = 0 then
    raise exception 'Pola deklarasi tanggal tidak ditemukan pada campaign_upsert.';
  end if;
  baru := replace(src,
    ' v_so_a date; v_so_b date; v_bi_a date; v_bi_b date;',
    ' v_so_a date; v_so_b date; v_bi_a date; v_bi_b date;' || chr(10) ||
    ' v_bi_at text; v_bi_bt text;');

  -- ---- b. Aturannya sendiri, tepat setelah pemeriksaan periode terbalik -------------------
  if position('   raise exception ''Periode Billing terbalik pada %: % sampai %'',code,r->>''billingStart'',r->>''billingEnd''; end if;' in baru) = 0 then
    raise exception 'Pola pemeriksaan periode terbalik tidak ditemukan.';
  end if;
  baru := replace(baru,
    '   raise exception ''Periode Billing terbalik pada %: % sampai %'',code,r->>''billingStart'',r->>''billingEnd''; end if;',
    '   raise exception ''Periode Billing terbalik pada %: % sampai %'',code,r->>''billingStart'',r->>''billingEnd''; end if;' || chr(10) ||
    '  -- Aturan "billing mengikuti SO": selama billing dibiarkan kosong, ia memakai tanggal SO' || chr(10) ||
    '  -- pada baris yang sama. Yang diisi tetap menang, jadi pintu untuk billing yang berbeda' || chr(10) ||
    '  -- tidak ikut tertutup.' || chr(10) ||
    '  v_bi_at := nullif(btrim(coalesce(r->>''billingStart'','''')),'''');' || chr(10) ||
    '  v_bi_bt := nullif(btrim(coalesce(r->>''billingEnd'','''')),'''');' || chr(10) ||
    '  if v_bi_a is null then v_bi_a := v_so_a; v_bi_at := nullif(btrim(coalesce(r->>''soStart'','''')),''''); end if;' || chr(10) ||
    '  if v_bi_b is null then v_bi_b := v_so_b; v_bi_bt := nullif(btrim(coalesce(r->>''soEnd'','''')),''''); end if;');

  -- ---- c. Cabang UPDATE: ikut terpicu ketika hanya SO yang dikirim ------------------------
  if position('    billing_start_text=case when r ? ''billingStart'' then nullif(btrim(r->>''billingStart''),'''') else billing_start_text end,' in baru) = 0 then
    raise exception 'Pola UPDATE billing_start_text tidak ditemukan.';
  end if;
  baru := replace(baru,
    '    billing_start_text=case when r ? ''billingStart'' then nullif(btrim(r->>''billingStart''),'''') else billing_start_text end,' || chr(10) ||
    '    billing_end_text=case when r ? ''billingEnd'' then nullif(btrim(r->>''billingEnd''),'''') else billing_end_text end,',
    '    billing_start_text=case when (r ? ''billingStart'') or (r ? ''soStart'') then v_bi_at else billing_start_text end,' || chr(10) ||
    '    billing_end_text=case when (r ? ''billingEnd'') or (r ? ''soEnd'') then v_bi_bt else billing_end_text end,');

  if position('    billing_start=case when r ? ''billingStart'' then v_bi_a else billing_start end,' in baru) = 0 then
    raise exception 'Pola UPDATE billing_start tidak ditemukan.';
  end if;
  baru := replace(baru,
    '    billing_start=case when r ? ''billingStart'' then v_bi_a else billing_start end,' || chr(10) ||
    '    billing_end=case when r ? ''billingEnd'' then v_bi_b else billing_end end',
    '    billing_start=case when (r ? ''billingStart'') or (r ? ''soStart'') then v_bi_a else billing_start end,' || chr(10) ||
    '    billing_end=case when (r ? ''billingEnd'') or (r ? ''soEnd'') then v_bi_b else billing_end end');

  -- ---- d. Cabang INSERT: teks billing ikut jatuh ke teks SO -------------------------------
  if position('     nullif(btrim(coalesce(r->>''billingStart'','''')),''''),nullif(btrim(coalesce(r->>''billingEnd'','''')),''''),' in baru) = 0 then
    raise exception 'Pola INSERT teks billing tidak ditemukan.';
  end if;
  baru := replace(baru,
    '     nullif(btrim(coalesce(r->>''billingStart'','''')),''''),nullif(btrim(coalesce(r->>''billingEnd'','''')),''''),',
    '     v_bi_at,v_bi_bt,');

  execute baru;
  raise notice 'campaign_upsert: billing kini mengikuti SO selama dibiarkan kosong.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Menyusulkan aturan yang sama pada baris yang sudah ada
-- ------------------------------------------------------------------------------------------
-- Saat migrasi ini ditulis hasilnya nol baris karena SO pun masih kosong. Tetap dijalankan
-- supaya campaign yang SO-nya terisi lewat jalur lain tidak tertinggal.
do $susul$
declare n int;
begin
  update public.campaigns
     set billing_start      = so_start,
         billing_end        = so_end,
         billing_start_text = so_start_text,
         billing_end_text   = so_end_text
   where archived_at is null
     and so_start is not null
     and billing_start is null;
  get diagnostics n = row_count;
  raise notice 'Campaign yang billing-nya disusulkan dari SO: %', n;
end
$susul$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan: aturannya benar-benar berlaku, dan yang diisi tetap menang
-- ------------------------------------------------------------------------------------------
do $periksa$
declare
  v_uid uuid; kode text;
  a_so date; a_bi date; b_bi date; t_bi text;
begin
  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;
  select campaign_code into kode from public.campaigns where archived_at is null
   order by campaign_code limit 1;
  if kode is null then raise notice 'Tidak ada campaign untuk diperiksa; dilewati.'; return; end if;

  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text,'role','authenticated')::text, true);

    -- 1. Hanya SO yang dikirim -> billing mengikutinya.
    perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object(
      'codeCampaign', kode, 'soStart','07-03-2026','soEnd','21-05-2026')));
    select so_start, billing_start, billing_end, billing_start_text
      into a_so, a_bi, b_bi, t_bi
      from public.campaigns where campaign_code=kode;
    if a_bi is distinct from a_so or b_bi <> date '2026-05-21' then
      raise exception 'GAGAL: billing tidak mengikuti SO (so=%, billing=%).', a_so, a_bi; end if;
    if coalesce(t_bi,'') <> '07-03-2026' then
      raise exception 'GAGAL: teks billing tidak ikut SO -> %', coalesce(t_bi,'(kosong)'); end if;

    -- 2. Billing yang diisi sungguhan tetap menang.
    perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object(
      'codeCampaign', kode, 'soStart','07-03-2026','soEnd','21-05-2026',
      'billingStart','01-09-2026','billingEnd','30-09-2026')));
    select billing_start into a_bi from public.campaigns where campaign_code=kode;
    if a_bi <> date '2026-09-01' then
      raise exception 'GAGAL: billing yang diisi justru tertimpa SO -> %', a_bi; end if;

    reset role;
    raise exception 'ULANGI_SAJA';
  exception when others then
    reset role;
    if sqlerrm = 'ULANGI_SAJA' then
      raise notice 'Pemeriksaan lolos: billing mengikuti SO, dan billing yang diisi tetap menang.';
    else
      raise;
    end if;
  end;
end
$periksa$;
