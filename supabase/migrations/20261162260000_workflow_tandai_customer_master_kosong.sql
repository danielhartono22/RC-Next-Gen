-- ==========================================================================================
-- Antrean Workflow menandai dokumen tanpa Customer Master
-- ==========================================================================================
-- Pemilik, 12 Oktober 2026: "apakah fitur clearing dengan no doc tidak bisa? perbaiki."
--
-- TEMUAN (diuji di prod dalam transaksi yang dibatalkan, 12 Oktober 2026): dari 850 dokumen
-- Claimed, 828 dapat di-Clearing, 1 berjenis Rebate (hanya lewat Bulk Process), dan 21 ditolak
-- server karena Customer Master-nya belum ada (jaga_customer_master_klaim, 20261162200000).
-- Posting Done memproses seluruh dokumen terpilih sebagai satu kesatuan, sehingga SATU dokumen
-- tanpa master di dalam daftar No Document yang ditempel menggagalkan seluruh posting - dan
-- layar hanya menulis "Gagal" tanpa alasan.
--
-- Selain itu rc_legacy_workflow mengirim kodeToko dan namaToko NULL untuk dokumen seperti itu
-- (20261162200000 menambal fungsi pembaca lain, tetapi fungsi ini sudah memakai LEFT JOIN
-- sehingga pola tambalannya tidak cocok), dan layar menampilkannya sebagai "null".
--
-- SEKARANG baris Workflow membawa:
--   kodeToko      kode Customer Master, atau kode sumber dokumen bila master belum ada
--   namaToko      nama Customer Master, atau "Customer Master belum ada"
--   masterKosong  true bila dokumen belum tertaut ke Customer Master
-- Layar memakai masterKosong untuk mengunci centangnya dan menjelaskannya di Mass Process.
--
-- Ditambal dengan penjaga MD5 pra-citra (sama di dev dan prod, 12 Oktober 2026).
-- ==========================================================================================

do $tambal$
declare src text; baru text; n int;
  lama constant text := $p$'kodeToko',cu.customer_code,'namaToko',cu.customer_name,$p$;
begin
  src := pg_get_functiondef('public.rc_legacy_workflow(integer,timestamp with time zone,uuid)'::regprocedure);
  if src ~ '20261162260000' then raise notice 'rc_legacy_workflow sudah ditambal.'; return; end if;
  if md5(replace(src, E'\r', '')) <> 'e5c0aff88f7d18637c00264e3dd5efb8' then
    raise exception 'DITOLAK: definisi rc_legacy_workflow berbeda dari yang diukur (md5 %).', md5(replace(src, E'\r', '')); end if;
  n := (length(src) - length(replace(src, lama, ''))) / length(lama);
  if n <> 1 then raise exception 'Pola kodeToko/namaToko ditemukan % kali, diharapkan 1.', n; end if;
  baru := replace(src, lama,
    $p$'kodeToko',coalesce(cu.customer_code,c.source_customer_code),'namaToko',coalesce(cu.customer_name,'Customer Master belum ada'),
    'masterKosong',c.customer_id is null, /* 20261162260000 */$p$);
  execute baru;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan: setiap baris antrean punya kodeToko; dokumen tanpa master ditandai.
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; w jsonb; semua jsonb := '[]'; kursor jsonb := null; e text := ''; n_kosong int; n_tanda int; n_db int;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  if v_sm is null then raise notice 'Tidak ada System Manager aktif; uji dilewati.'; return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  for i in 1..100 loop
    w := public.rc_legacy_workflow(1000, (kursor->>'waktu')::timestamptz, (kursor->>'id')::uuid);
    semua := semua || coalesce(w->'releaseData', '[]') || coalesce(w->'claimFinData', '[]')
                   || coalesce(w->'clearingData', '[]') || coalesce(w->'bulkRebateData', '[]');
    exit when w->'berikutnya' is null or w->'berikutnya' = 'null'::jsonb;
    kursor := w->'berikutnya';
  end loop;
  perform set_config('request.jwt.claims', '', true);

  select count(*) filter (where coalesce(x->>'kodeToko', '') = '' or x->>'namaToko' is null),
         count(*) filter (where (x->>'masterKosong')::boolean)
    into n_kosong, n_tanda from jsonb_array_elements(semua) x;
  select count(*) into n_db from public.claims
   where customer_id is null and archived_at is null and status in ('approved', 'released', 'claimed');
  if n_kosong > 0 then e := e || format(' %s baris tanpa kodeToko/namaToko;', n_kosong); end if;
  if not (semua->0 ? 'masterKosong') and jsonb_array_length(semua) > 0 then e := e || ' kunci masterKosong tidak ada;'; end if;
  if n_tanda > n_db then e := e || format(' %s baris ditandai, lebih dari %s dokumen tanpa master di antrean;', n_tanda, n_db); end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
  raise notice 'Workflow: % baris, % ditandai tanpa Customer Master.', jsonb_array_length(semua), n_tanda;
end
$uji$;
