-- ==========================================================================================
-- Gross up dan periode dokumen dihitung sistem, dengan acuan Key Master dan Campaign Master
-- ==========================================================================================
-- Atas keputusan pemilik, 20 September 2026:
--
--   "untuk gross up saya mau yang belum ada saat ini dihitung oleh system dengan acuan
--    key master campaign master."
--
--   "periode dokumen? by default dokumen itu memiliki periode sesuai campaign start dan
--    campaign end. periode di atas overwrite ke so dan billing date start dan end."
--
-- Keduanya adalah aturan yang sama bentuknya: nilai turunan yang seharusnya berasal dari master,
-- tetapi tidak pernah ditulis. Migration ini memperbaiki JALUR TULIS lebih dulu supaya dokumen
-- baru benar, lalu MENGISI dokumen yang sudah ada.
--
-- ------------------------------------------------------------------------------------------
-- KEADAAN SEBELUM PERBAIKAN (diukur 20 September 2026)
-- ------------------------------------------------------------------------------------------
--   gross_up NULL              2.752 dari 2.754 klaim aktif
--   period_start NULL          1.427 dari 2.754
--   period_end   NULL            812 dari 2.754
--   tax_subject kosong         1.016 padahal Key Master punya nilainya
--
-- Hanya 2 klaim yang gross_up-nya terisi - persis dua dokumen yang pernah berhasil submit
-- sebelum cacat jenis_cashback memblokir seluruh upload. Keduanya sudah cocok dengan hitungan
-- master, jadi tidak ada satu pun nilai tersimpan yang perlu dikoreksi. Yang ada hanyalah
-- nilai yang belum pernah ada.
--
-- ------------------------------------------------------------------------------------------
-- TIGA SEBAB YANG DIPERBAIKI
-- ------------------------------------------------------------------------------------------
-- 1. JALUR TULIS MEMAKAI RUMUS YANG MENGABAIKAN CAMPAIGN MASTER
--
--    Ada dua mesin gross up di basis data, dan keduanya tidak sepakat:
--
--      public.rc_gross_up_legacy(net,subject)              - TIDAK melihat status pajak campaign
--      rc_private.gross_claimed(net,subyek,status_campaign) - melihat
--
--    gross_claimed mengembalikan 0 bila pajak ditanggung perusahaan ("PT Nipsea Paint and
--    Chemicals") atau campaign-nya Rebate Non Tax. rc_gross_up_legacy tetap menghitung
--    net/0.85. Jalur TULIS - compile_upload dan mutate_claims_unchecked - memakai yang pertama;
--    jalur BACA dan layar memakai yang kedua.
--
--    Selama upload terblokir, akibatnya belum tersimpan di mana pun. Sekarang upload sudah
--    berjalan kembali, jadi ini harus dibetulkan SEBELUM dokumen baru masuk membawa nilai yang
--    salah.
--
-- 2. LAPORAN MEMAKAI SUBYEK PAJAK DARI DOKUMEN, YANG KOSONG
--
--    View public.rc_report_rows menghitung:
--
--      rc_private.gross_claimed(c.cb_net, c.tax_subject, ca.tax_status)
--
--    memakai tax_subject DOKUMEN, bukan Key Master. Pada 1.016 klaim kolom itu kosong, dan
--    ketika kosong rumusnya jatuh ke tangga progresif Perorangan. Seratus enam puluh tujuh di
--    antaranya sebenarnya BADAN di Key Master, yang seharusnya flat 15%.
--
--    Dampak terukur pada angka Report: 78 baris berubah, Rp 79.735.356 pada seluruh klaim aktif,
--    Rp 34.417.503 pada status done yang masuk KPI.
--
--    Mengisi tax_subject dokumen dari Key Master memperbaiki view itu dengan sendirinya, tanpa
--    perlu mengubah view-nya - karena Key Master memang acuan yang pemilik maksudkan.
--
-- 3. PERIODE DOKUMEN TIDAK PERNAH DIISI
--
--    compile_upload membuat klaim tanpa period_start maupun period_end sama sekali, padahal
--    campaign-nya punya keduanya. Kolom itu dibaca oleh rc_periode_dokumen dan
--    rc_posting_exception - yaitu layar Posting Exception dan Reprocessing - sehingga periodenya
--    tampil kosong di sana.
--
--    Aturan penimpaannya sendiri SUDAH benar dan tidak diubah di sini: rc_posting_exception
--    menerima soStart/soEnd/billingStart/billingEnd dari layar On Hold, mensyaratkan sedikitnya
--    satu berbeda dari periode campaign, lalu menuliskannya ke extend_so_start/end dan
--    extend_billing_start/end. rc_reprocessing_upload mengosongkan kembali keempatnya saat
--    dokumen kembali ke Not Yet, karena perpanjangan hanya berlaku selama dokumen tertahan.
--    Yang kurang hanyalah periode dasar yang ditimpa itu.
--
-- ------------------------------------------------------------------------------------------
-- YANG SENGAJA TIDAK DILAKUKAN
-- ------------------------------------------------------------------------------------------
-- version_no TIDAK dinaikkan. Kolom itu penjaga tabrakan antar pengguna; menaikkannya pada 2.754
-- baris sekaligus akan membuat setiap layar yang sedang terbuka menolak dengan "Document changed;
-- refresh first". Pengisian ini tidak mengubah apa pun yang sedang disunting siapa pun.
--
-- Dokumen yang SUDAH DIARSIPKAN tidak disentuh. Arsip adalah catatan yang sengaja dibekukan.
-- Jumlah yang tersisa dilaporkan di akhir supaya pemilik dapat memutuskan terpisah.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- BAGIAN A - jalur tulis, supaya dokumen baru benar sejak awal
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text;
begin
  -- A1. rc_private.compile_upload ---------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'rc_private' and p.proname = 'compile_upload';
  if src is null then raise exception 'rc_private.compile_upload tidak ditemukan.'; end if;

  if position('gross_claimed' in src) > 0 then
    raise notice 'compile_upload sudah memakai gross_claimed; dilewati.';
  else
    baru := src;

    -- gross up dihitung untuk SEMUA dokumen, bukan hanya yang langsung done. Nilainya turunan
    -- murni dari cb_net dan kedua master, jadi tidak ada alasan menundanya sampai clearing.
    baru := replace(baru,
      'when v_status=''done'' and v_subject is not null',
      'when v_subject is not null');
    baru := replace(baru,
      'then public.rc_gross_up_legacy(v_cb,v_subject) else null end;',
      'then rc_private.gross_claimed(v_cb,v_subject,v_camp.tax_status) else null end;');

    -- periode dasar dari Campaign Master, dan subyek pajak dari Key Master untuk SEMUA status -
    -- bukan hanya done, karena view laporan membaca kolom itu pada status apa pun.
    baru := replace(baru,
      'net_value,volume,cb_net,gross_up,tax_subject,',
      'net_value,volume,cb_net,gross_up,tax_subject,period_start,period_end,');
    baru := replace(baru,
      'v_net,v_vol,v_cb,v_gross,case when v_status=''done'' then v_subject else null end,',
      'v_net,v_vol,v_cb,v_gross,v_subject,v_camp.period_start,v_camp.period_end,');

    if baru = src then
      raise exception 'Tidak satu pun pola ditemukan pada public.compile_upload. '
        'Sumbernya sudah berubah - periksa dan perbarui migration ini.';
    end if;
    if position('rc_gross_up_legacy' in baru) > 0 then
      raise exception 'compile_upload masih memanggil rc_gross_up_legacy sesudah penggantian.';
    end if;
    if position('period_start,period_end,' in baru) = 0 then
      raise exception 'compile_upload tidak jadi mengisi periode; pola kolom tidak cocok.';
    end if;
    execute baru;
    raise notice 'compile_upload: gross up mengikuti Campaign Master, periode diisi dari campaign.';
  end if;

  -- A2. mutate_claims_unchecked ------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'rc_private' and p.proname = 'mutate_claims_unchecked';
  if src is null then raise exception 'rc_private.mutate_claims_unchecked tidak ditemukan.'; end if;

  if position('gross_claimed' in src) > 0 then
    raise notice 'mutate_claims_unchecked sudah memakai gross_claimed; dilewati.';
  else
    baru := src;
    baru := replace(baru,
      'v_gross:=public.rc_gross_up_legacy(c.cb_net,subject);',
      'v_gross:=rc_private.gross_claimed(c.cb_net,subject,camp.tax_status);');

    -- Periode campaign menjadi cadangan terakhir: isian pengguna menang, lalu nilai lama,
    -- baru kemudian Campaign Master. Dokumen yang periodenya sudah benar tidak tersentuh.
    baru := replace(baru,
      'period_start=coalesce(nullif(item->>''period_start'','''')::date,period_start),',
      'period_start=coalesce(nullif(item->>''period_start'','''')::date,period_start,camp.period_start),');
    baru := replace(baru,
      'period_end=coalesce(nullif(item->>''period_end'','''')::date,period_end),paid_on=',
      'period_end=coalesce(nullif(item->>''period_end'','''')::date,period_end,camp.period_end),paid_on=');

    if baru = src then
      raise exception 'Tidak satu pun pola ditemukan pada rc_private.mutate_claims_unchecked. '
        'Sumbernya sudah berubah - periksa dan perbarui migration ini.';
    end if;
    if position('rc_gross_up_legacy' in baru) > 0 then
      raise exception 'mutate_claims_unchecked masih memanggil rc_gross_up_legacy.';
    end if;
    execute baru;
    raise notice 'mutate_claims_unchecked: gross up mengikuti Campaign Master, periode bercadangan campaign.';
  end if;
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- BAGIAN B - mengisi dokumen yang sudah ada
-- ------------------------------------------------------------------------------------------
-- Urutannya mengikat: tax_subject diisi LEBIH DULU, karena gross up dihitung darinya.
do $isi$
declare n_subyek int; n_periode int; n_gross int; n_sisa_gross int; n_arsip int;
        n_bentrok int := 0; r record;
begin
  -- B1. Subyek pajak dokumen dari Key Master ------------------------------------------------
  update public.claims cl
     set tax_subject = cu.tax_subject, updated_at = now()
    from public.customers cu
   where cu.id = cl.customer_id
     and cl.archived_at is null
     and coalesce(btrim(cl.tax_subject),'') = ''
     and coalesce(btrim(cu.tax_subject),'') <> '';
  get diagnostics n_subyek = row_count;

  -- B2. Periode dasar dari Campaign Master ---------------------------------------------------
  update public.claims cl
     set period_start = coalesce(cl.period_start, ca.period_start),
         period_end   = coalesce(cl.period_end,   ca.period_end),
         updated_at   = now()
    from public.campaigns ca
   where ca.id = cl.campaign_id
     and cl.archived_at is null
     and (cl.period_start is null or cl.period_end is null)
     and (ca.period_start is not null or ca.period_end is not null)
     -- Dokumen yang periodenya sendiri jatuh DI LUAR periode campaign akan terbalik bila sisi
     -- yang kosong diisi - dan batasan claim_period_order menolaknya. Yang seperti itu
     -- dilewati, lalu dilaporkan di bawah, bukan dipaksakan sampai datanya rusak.
     and (coalesce(cl.period_end, ca.period_end) is null
       or coalesce(cl.period_start, ca.period_start) is null
       or coalesce(cl.period_end, ca.period_end) >= coalesce(cl.period_start, ca.period_start));
  get diagnostics n_periode = row_count;

  -- B3. Gross up dari Key Master dan Campaign Master ------------------------------------------
  update public.claims cl
     set gross_up = rc_private.gross_claimed(cl.cb_net, cl.tax_subject, ca.tax_status),
         updated_at = now()
    from public.campaigns ca
   where ca.id = cl.campaign_id
     and cl.archived_at is null
     and cl.gross_up is null
     and coalesce(btrim(cl.tax_subject),'') <> '';
  get diagnostics n_gross = row_count;

  select count(*) into n_sisa_gross from public.claims
   where archived_at is null and gross_up is null;
  select count(*) into n_arsip from public.claims where archived_at is not null;

  -- Dokumen yang periodenya bertabrakan dengan periode campaign-nya, disebut satu per satu
  -- supaya dapat diperiksa tangan.
  for r in
    select cl.no_doc, cl.period_start, cl.period_end, ca.campaign_code,
           ca.period_start as camp_mulai, ca.period_end as camp_selesai
      from public.claims cl join public.campaigns ca on ca.id = cl.campaign_id
     where cl.archived_at is null
       and (cl.period_start is null or cl.period_end is null)
       and (ca.period_start is not null or ca.period_end is not null)
       and coalesce(cl.period_end, ca.period_end) is not null
       and coalesce(cl.period_start, ca.period_start) is not null
       and coalesce(cl.period_end, ca.period_end) < coalesce(cl.period_start, ca.period_start)
     order by cl.no_doc
  loop
    n_bentrok := n_bentrok + 1;
    raise notice 'PERIODE BENTROK: % (dokumen % .. %) vs campaign % (% .. %)',
      r.no_doc, coalesce(r.period_start::text,'-'), coalesce(r.period_end::text,'-'),
      r.campaign_code, coalesce(r.camp_mulai::text,'-'), coalesce(r.camp_selesai::text,'-');
  end loop;

  raise notice 'Subyek pajak diisi   : % baris', n_subyek;
  raise notice 'Periode diisi        : % baris', n_periode;
  raise notice 'Gross up dihitung    : % baris', n_gross;
  raise notice 'Gross up masih kosong: % baris (Key Master belum punya subyek pajaknya)', n_sisa_gross;
  raise notice 'Periode bentrok, dilewati : % baris', n_bentrok;
  raise notice 'Dokumen terarsip tidak disentuh: % baris', n_arsip;
end
$isi$;

-- ------------------------------------------------------------------------------------------
-- BAGIAN C - pemeriksaan, berhenti bila ada yang tidak sebagaimana mestinya
-- ------------------------------------------------------------------------------------------
do $periksa$
declare n int; src text;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where p.prokind = 'f' and ns.nspname in ('public','rc_private')
     and p.proname in ('compile_upload','mutate_claims_unchecked')
     and pg_get_functiondef(p.oid) like '%rc_gross_up_legacy%';
  if n > 0 then
    raise exception 'GAGAL: % fungsi jalur tulis masih memanggil rc_gross_up_legacy.', n;
  end if;

  -- Setiap klaim aktif yang Key Master-nya punya subyek pajak harus sudah punya gross up.
  select count(*) into n
    from public.claims cl join public.customers cu on cu.id = cl.customer_id
   where cl.archived_at is null and cl.gross_up is null
     and coalesce(btrim(cu.tax_subject),'') <> '';
  if n > 0 then
    raise exception 'GAGAL: % klaim masih tanpa gross up padahal Key Master punya subyeknya.', n;
  end if;

  -- Setiap klaim aktif yang campaign-nya punya periode harus sudah punya periode.
  select count(*) into n
    from public.claims cl join public.campaigns ca on ca.id = cl.campaign_id
   where cl.archived_at is null
     and ((cl.period_start is null and ca.period_start is not null)
       or (cl.period_end   is null and ca.period_end   is not null))
     -- kecuali yang memang dilewati karena periodenya bentrok
     and (coalesce(cl.period_end, ca.period_end) is null
       or coalesce(cl.period_start, ca.period_start) is null
       or coalesce(cl.period_end, ca.period_end) >= coalesce(cl.period_start, ca.period_start));
  if n > 0 then
    raise exception 'GAGAL: % klaim masih tanpa periode padahal campaign-nya punya.', n;
  end if;

  -- Gross up tersimpan harus sama dengan yang dihitung jalur baca. Bila keduanya berbeda,
  -- layar hasil upload akan kembali menampilkan angka yang lain daripada Report.
  select count(*) into n
    from public.claims cl join public.campaigns ca on ca.id = cl.campaign_id
   where cl.archived_at is null and cl.gross_up is not null
     and round(cl.gross_up,2) is distinct from
         round(rc_private.gross_claimed(cl.cb_net, cl.tax_subject, ca.tax_status),2);
  if n > 0 then
    raise exception 'GAGAL: % klaim nilai tersimpannya berbeda dari hitungan jalur baca.', n;
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
