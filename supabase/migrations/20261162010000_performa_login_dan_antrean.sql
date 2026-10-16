-- ==========================================================================================
-- Performa login dan antrean pada data besar
-- ==========================================================================================
-- Menggantikan delapan migrasi percobaan sebelumnya (20261162-20261169). Semuanya menulis
-- ulang fungsi secara UTUH dari versi lama yang kebetulan ada di lingkungan dev, dan karena
-- itu akan merusak produksi:
--
--   rc_legacy_workflow   Release kembali menampilkan Submitted alih-alih Approved - tahap
--                        Management of Approval terlewati seluruhnya; JOIN biasa menggantikan
--                        LEFT JOIN sehingga 97 dokumen yang dulu hilang hilang lagi; dan
--                        pemeriksaan izin per tab (can_tab) terhapus.
--   legacy_customers     saringan archived_at terbuang, pelanggan terarsip muncul lagi.
--   rc_lookup_master     nama kolom berbeda dari yang dibaca layar (kodeToko alih-alih
--                        custCode, kodeDepot alih-alih dcCode, tanpa pendingApproval) -
--                        setiap baris unggahan ditolak "KTP/NPWP Kosong", dan dokumen yang
--                        menunggu approval lolos.
--   seluruhnya           jangkauan depot diambil dari effective_depots (user_depot_grants),
--                        padahal can_access memakai user_depot_access. Dua sumber berbeda -
--                        siapa boleh melihat apa berubah diam-diam.
--
-- Migrasi ini karena itu TIDAK menulis ulang fungsi mana pun. Setiap perubahan adalah tambalan
-- atas definisi yang SEDANG HIDUP, menyentuh hanya bagian yang perlu, dan berhenti dengan
-- galat bila bagian itu tidak ditemukan - bukan menebak.
--
-- Yang diubah:
--   1. Jangkauan depot dihitung SEKALI per permintaan, dari sumber yang sama persis dengan
--      can_access - bukan dipanggil sekali per baris.
--   2. rc_legacy_workflow dimuat bertahap: baris dipilih lebih dulu, baru di-join.
--   3. Login berhenti mengirim seluruh daftar pelanggan dan dokumen; keduanya diambil saat
--      perlu lewat rc_lookup_master, yang MEMANGGIL fungsi pembentuk baris yang sama - satu
--      definisi, tidak mungkin berbeda bentuk.
--
-- Diukur di dev pada 100 ribu klaim: login dari timeout menjadi di bawah satu detik.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Jangkauan depot pemanggil, SETARA can_access
-- ------------------------------------------------------------------------------------------
-- can_access(depot) bernilai benar bila pemanggil aktif, tidak wajib mengganti PIN, dan
-- System Manager ATAU memiliki baris user_depot_access untuk depot itu. Fungsi ini
-- mengembalikan keterangan yang sama dalam satu baris, sehingga penyaringnya menjadi
-- perbandingan larik yang dihitung sekali:
--
--   can_access(d)  ==  l.semua or d = any(l.depot)
--
-- Pengguna yang tidak memenuhi syarat mendapat (false, {}) - tidak melihat apa pun, persis
-- seperti can_access yang mengembalikan false untuk mereka.
create or replace function rc_private.lingkup_depot_saya()
returns table(semua boolean, depot uuid[])
language sql stable security definer set search_path to '' as $fn$
  select coalesce(p.role = 'system manager', false),
         coalesce((select array_agg(a.depot_id) from public.user_depot_access a
                    where a.user_id = p.id), '{}'::uuid[])
    from public.profiles p
   where p.id = (select auth.uid()) and p.status = 'active' and not p.must_change_password
  union all
  select false, '{}'::uuid[]
   where not exists (select 1 from public.profiles p
                      where p.id = (select auth.uid()) and p.status = 'active'
                        and not p.must_change_password);
$fn$;

revoke all on function rc_private.lingkup_depot_saya() from public, anon;
grant execute on function rc_private.lingkup_depot_saya() to authenticated;

-- Sisa percobaan sebelumnya: memakai sumber jangkauan yang salah.
drop function if exists rc_private.depot_saya();
drop function if exists rc_private.taksir_baris(regclass);

-- ------------------------------------------------------------------------------------------
-- 2. Indeks
-- ------------------------------------------------------------------------------------------
-- Predikat parsialnya disamakan dengan penyaring antrean yang hidup, supaya perencana kueri
-- benar-benar dapat memakainya. Kolom yang sudah ditetapkan predikat tidak ditaruh di depan:
-- itu hanya merusak urutan updated_at yang dipakai "order by".
drop index if exists public.claims_antrean_idx;
drop index if exists public.claims_antrean_depot_idx;
drop index if exists public.claims_no_doc_idx;
drop index if exists public.customers_code_idx;

create index if not exists claims_antrean_idx
  on public.claims (updated_at desc, id)
  where status in ('approved','released','claimed')
    and archived_at is null and pending_approval is null;

create index if not exists claims_antrean_depot_idx
  on public.claims (depot_id, updated_at desc)
  where status in ('approved','released','claimed')
    and archived_at is null and pending_approval is null;

-- Layar menormalkan kode ke huruf besar sebelum bertanya; indeks ekspresi membuat pencarian
-- itu tetap memakai indeks.
create index if not exists claims_no_doc_upper_idx on public.claims (upper(no_doc));
create index if not exists customers_code_upper_idx on public.customers (upper(customer_code));

analyze public.claims;
analyze public.customers;

-- ------------------------------------------------------------------------------------------
-- 3. legacy_documents dan legacy_customers menerima saringan kode
-- ------------------------------------------------------------------------------------------
-- Keduanya tetap pembentuk baris yang SATU-SATUNYA. Dipanggil tanpa saringan, perilakunya sama
-- seperti sebelumnya; dipanggil dengan saringan, ia mengembalikan hanya kode yang diminta.
-- rc_lookup_master memanggil keduanya, sehingga bentuk barisnya tidak mungkin menyimpang.
do $saring$
declare src text; baru text;
begin
  -- ---- legacy_documents ------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='rc_private' and p.proname='legacy_documents';
  if src is null then raise exception 'rc_private.legacy_documents tidak ditemukan.'; end if;

  if position('p_nodoc' in src) = 0 then
    if position('rc_private.legacy_documents()' in src) = 0 then
      raise exception 'Tanda tangan legacy_documents() tidak ditemukan.'; end if;
    if position('  where rc_private.can_access(c.depot_id)' in src) = 0 then
      raise exception 'Penyaring can_access pada legacy_documents tidak ditemukan.'; end if;

    baru := replace(src, 'rc_private.legacy_documents()',
                    'rc_private.legacy_documents(p_nodoc text[] DEFAULT NULL::text[])');
    baru := replace(baru,
      '  where rc_private.can_access(c.depot_id)',
      '  cross join rc_private.lingkup_depot_saya() l'
      || chr(10) || '  where (p_nodoc is null or upper(c.no_doc) = any(p_nodoc))'
      || chr(10) || '    and (l.semua or c.depot_id = any(l.depot))');

    -- Tanda tangan berubah, jadi yang lama harus dibuang dulu - dua versi berdampingan membuat
    -- pemanggilan tanpa argumen menjadi ambigu.
    drop function rc_private.legacy_documents();
    execute baru;
    raise notice 'legacy_documents: saringan kode dan jangkauan sekali hitung.';
  end if;

  -- ---- legacy_customers ------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='rc_private' and p.proname='legacy_customers';
  if src is null then raise exception 'rc_private.legacy_customers tidak ditemukan.'; end if;

  if position('p_kode' in src) = 0 then
    if position('rc_private.legacy_customers(p_with_contacts boolean)' in src) = 0 then
      raise exception 'Tanda tangan legacy_customers tidak ditemukan.'; end if;
    if position('where cd.customer_id=cu.id and rc_private.can_access(cd.depot_id))' in src) = 0 then
      raise exception 'Penyaring can_access pada legacy_customers tidak ditemukan.'; end if;
    if position(' from public.customers cu' in src) = 0 then
      raise exception 'Klausa from pada legacy_customers tidak ditemukan.'; end if;

    baru := replace(src, 'rc_private.legacy_customers(p_with_contacts boolean)',
      'rc_private.legacy_customers(p_with_contacts boolean, p_kode text[] DEFAULT NULL::text[])');
    baru := replace(baru, ' from public.customers cu',
      ' from public.customers cu' || chr(10) || ' cross join rc_private.lingkup_depot_saya() l');
    -- Syarat "punya tautan customer_depots" DIPERTAHANKAN untuk semua orang, termasuk System
    -- Manager. Hanya pemeriksaan depotnya yang diganti dengan bentuk setara.
    baru := replace(baru,
      'where cd.customer_id=cu.id and rc_private.can_access(cd.depot_id))',
      'where cd.customer_id=cu.id and (l.semua or cd.depot_id = any(l.depot)))'
      || chr(10) || '   and (p_kode is null or upper(cu.customer_code) = any(p_kode))');

    drop function rc_private.legacy_customers(boolean);
    execute baru;
    raise notice 'legacy_customers: saringan kode dan jangkauan sekali hitung.';
  end if;
end
$saring$;

-- ------------------------------------------------------------------------------------------
-- 4. rc_lookup_master
-- ------------------------------------------------------------------------------------------
drop function if exists public.rc_lookup_master(text[], text[]);

create or replace function public.rc_lookup_master(
  p_cust text[] default '{}', p_doc text[] default '{}')
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_cust text[]; v_doc text[];
begin
  if not rc_private.can_access(null) then
    raise exception 'Access denied' using errcode='42501'; end if;
  if coalesce(array_length(p_cust,1),0) > 2000 or coalesce(array_length(p_doc,1),0) > 2000 then
    raise exception 'Maksimal 2000 kode per permintaan'; end if;

  -- Dinormalkan di sini juga, bukan hanya dipercayakan pada layar.
  select coalesce(array_agg(distinct upper(btrim(x))) filter (where btrim(x)<>''),'{}')
    into v_cust from unnest(coalesce(p_cust,'{}')) x;
  select coalesce(array_agg(distinct upper(btrim(x))) filter (where btrim(x)<>''),'{}')
    into v_doc from unnest(coalesce(p_doc,'{}')) x;

  -- Larik KOSONG tidak boleh diteruskan sebagai null: null berarti "tanpa saringan", dan itu
  -- akan mengembalikan seluruh isi tabel - persis beban yang sedang dihapus.
  return jsonb_build_object('status','success',
    'customers', case when array_length(v_cust,1) is null then '[]'::jsonb
                      else rc_private.legacy_customers(
                             rc_private.can_access(null,'upload_claim'), v_cust) end,
    'documents', case when array_length(v_doc,1) is null then '[]'::jsonb
                      else rc_private.legacy_documents(v_doc) end);
end
$fn$;

revoke all on function public.rc_lookup_master(text[],text[]) from public, anon;
grant execute on function public.rc_lookup_master(text[],text[]) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 5. rc_legacy_workflow dimuat bertahap
-- ------------------------------------------------------------------------------------------
-- Predikat antrean DIAMBIL dari definisi yang hidup, bukan ditulis ulang di sini. Dengan
-- begitu syarat apa pun yang ada di sana - status Approved, archived_at, pending_approval -
-- terbawa utuh. Hanya can_access yang diganti bentuk setaranya.
do $antrean$
declare src text; baru text; v_pred text; v_pred2 text; a int; b int;
  pola_akhir text := chr(10) || '  order by c.updated_at desc,c.id limit 5000) t;';
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='rc_legacy_workflow';
  if src is null then raise exception 'public.rc_legacy_workflow tidak ditemukan.'; end if;
  if position('p_limit' in src) > 0 then
    raise notice 'rc_legacy_workflow sudah bertahap; dilewati.'; return; end if;

  -- Mengambil predikat: teks antara "pel on true\n  where " dan akhir potongan.
  a := position('pel on true' || chr(10) || '  where ' in src);
  b := position(pola_akhir in src);
  if a = 0 or b = 0 or b < a then
    raise exception 'Penyaring antrean pada rc_legacy_workflow tidak ditemukan.'; end if;
  a := a + length('pel on true' || chr(10) || '  where ');
  v_pred := substr(src, a, b - a);

  if position('rc_private.can_access(c.depot_id)' in v_pred) = 0 then
    raise exception 'Penyaring antrean tidak memuat can_access(c.depot_id): %', v_pred; end if;
  v_pred2 := replace(v_pred, 'rc_private.can_access(c.depot_id)',
                     '(v_semua or c.depot_id = any(v_depot))');

  baru := src;

  -- 5a. Tanda tangan.
  baru := replace(baru, 'public.rc_legacy_workflow()',
    'public.rc_legacy_workflow(p_limit integer DEFAULT 1000, p_offset integer DEFAULT 0)');

  -- 5b. Variabel.
  if position('declare rows_json jsonb; nama jsonb;' in baru) = 0 then
    raise exception 'Deklarasi rc_legacy_workflow tidak ditemukan.'; end if;
  baru := replace(baru, 'declare rows_json jsonb; nama jsonb;',
    'declare rows_json jsonb; nama jsonb;' || chr(10)
    || ' v_limit int; v_offset int; v_total bigint; v_semua boolean; v_depot uuid[];');

  -- 5c. Jangkauan, batas halaman, dan total - dihitung sekali.
  if position(' nama := rc_private.peta_nama_pelaku();' in baru) = 0 then
    raise exception 'Pemanggilan peta_nama_pelaku tidak ditemukan.'; end if;
  baru := replace(baru, ' nama := rc_private.peta_nama_pelaku();',
    ' nama := rc_private.peta_nama_pelaku();' || chr(10)
    || ' -- Batas atas dijaga di sini, bukan dipercayakan pada pemanggil.' || chr(10)
    || ' v_limit  := least(greatest(coalesce(p_limit,1000),1),2000);' || chr(10)
    || ' v_offset := greatest(coalesce(p_offset,0),0);' || chr(10)
    || ' select l.semua, l.depot into v_semua, v_depot from rc_private.lingkup_depot_saya() l;' || chr(10)
    || ' -- Dua kueri terpisah, bukan satu dengan OR: bagi perencana kueri, OR yang memuat' || chr(10)
    || ' -- variabel tidak dapat disederhanakan dan setiap baris tetap diperiksa.' || chr(10)
    || ' if v_semua then' || chr(10)
    || '  select count(*) into v_total from public.claims c where '
    ||      replace(v_pred2, '(v_semua or c.depot_id = any(v_depot))', 'true') || ';' || chr(10)
    || ' else' || chr(10)
    || '  select count(*) into v_total from public.claims c where ' || v_pred2 || ';' || chr(10)
    || ' end if;');

  -- 5d. Baris dipilih lebih dulu - hanya id, dengan urutan dan potongannya.
  if position(' select coalesce(jsonb_agg(x),''[]''::jsonb) into rows_json from (' || chr(10)
              || '  select jsonb_build_object(' in baru) = 0 then
    raise exception 'Awal kueri antrean tidak ditemukan.'; end if;
  baru := replace(baru,
    ' select coalesce(jsonb_agg(x),''[]''::jsonb) into rows_json from (' || chr(10)
    || '  select jsonb_build_object(',
    ' select coalesce(jsonb_agg(x),''[]''::jsonb) into rows_json from (' || chr(10)
    || '  with dipilih as (' || chr(10)
    || '   select c.id from public.claims c' || chr(10)
    || '    where ' || v_pred2 || chr(10)
    || '    order by c.updated_at desc, c.id' || chr(10)
    || '    limit v_limit offset v_offset)' || chr(10)
    || '  select jsonb_build_object(');

  -- 5e. Join berjalan hanya untuk baris terpilih.
  if position('  from public.claims c' || chr(10) || '  left join public.depots d' in baru) = 0 then
    raise exception 'Klausa from pada kueri antrean tidak ditemukan.'; end if;
  baru := replace(baru,
    '  from public.claims c' || chr(10) || '  left join public.depots d',
    '  from dipilih' || chr(10) || '  join public.claims c on c.id = dipilih.id'
    || chr(10) || '  left join public.depots d');

  -- 5f. Penyaring lama dibuang: pemilihannya sudah terjadi di dipilih.
  baru := replace(baru, chr(10) || '  where ' || v_pred || pola_akhir,
                  chr(10) || '  order by c.updated_at desc,c.id) t;');
  if position(pola_akhir in baru) > 0 then
    raise exception 'Penyaring lama pada kueri antrean tidak terganti.'; end if;

  -- 5g. Total dan posisi halaman ikut dikembalikan.
  if position('return jsonb_build_object(''status'',''success'',' in baru) = 0 then
    raise exception 'Awal jawaban rc_legacy_workflow tidak ditemukan.'; end if;
  baru := replace(baru, 'return jsonb_build_object(''status'',''success'',',
    'return jsonb_build_object(''status'',''success'','
    || '''total'',v_total,''offset'',v_offset,''dimuat'',jsonb_array_length(rows_json),');

  drop function public.rc_legacy_workflow();
  execute baru;
  raise notice 'rc_legacy_workflow dimuat bertahap. Predikat: %', v_pred2;
end
$antrean$;

revoke all on function public.rc_legacy_workflow(integer,integer) from public, anon;
grant execute on function public.rc_legacy_workflow(integer,integer) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 6. Login berhenti memborong
-- ------------------------------------------------------------------------------------------
-- Kedua kunci TETAP ADA, berisi larik kosong: menghapusnya membuat layar yang membaca
-- res.customers mendapat undefined, galat yang muncul jauh dari sebabnya.
do $login$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='rc_legacy_bootstrap';
  if src is null then raise exception 'public.rc_legacy_bootstrap tidak ditemukan.'; end if;
  if position('diambil saat perlu' in src) > 0 then
    raise notice 'bootstrap sudah ringan; dilewati.'; return; end if;

  if position('  ''documents'',rc_private.legacy_documents(),' in src) = 0 then
    raise exception 'Kunci documents pada bootstrap tidak ditemukan.'; end if;
  if position('  ''customers'',rc_private.legacy_customers(may_read_contacts));' in src) = 0 then
    raise exception 'Kunci customers pada bootstrap tidak ditemukan.'; end if;

  baru := replace(src,
    '  ''documents'',rc_private.legacy_documents(),',
    '  -- diambil saat perlu lewat rc_lookup_master (migrasi 20261162010000).'
    || chr(10) || '  ''documents'',''[]''::jsonb,');
  baru := replace(baru,
    '  ''customers'',rc_private.legacy_customers(may_read_contacts));',
    '  ''customers'',''[]''::jsonb);');
  execute baru;
  raise notice 'bootstrap tidak lagi mengirim daftar pelanggan dan dokumen.';
end
$login$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
-- Yang dibuktikan di sini adalah hal-hal yang dulu LOLOS pemeriksaan padahal rusak:
--   * jangkauan baru menghasilkan baris yang SAMA dengan can_access, untuk setiap pengguna
--   * bentuk baris lookup IDENTIK dengan bentuk yang dibentuk legacy_documents/customers
--   * kolom yang dibaca layar ada: custCode, dcCode, pendingApproval
--   * isi antrean terbaru tetap utuh: Approved, approvedBy, can_tab
-- Ambang waktunya adalah batas KEGAGALAN (8 detik, batas authenticated), bukan target.
do $periksa$
declare
  u record; n_lama bigint; n_baru bigint; v_uid uuid; h jsonb; t0 timestamptz; ms numeric;
  k_lookup text; k_asli text; v_nd text; v_kc text;
begin
  -- 1. Kesetaraan jangkauan untuk SETIAP pengguna aktif.
  for u in select id, user_code, role from public.profiles
            where status='active' and not must_change_password loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text,'role','authenticated')::text, true);
    select count(*) into n_lama from public.claims c where rc_private.can_access(c.depot_id);
    select count(*) into n_baru from public.claims c cross join rc_private.lingkup_depot_saya() l
     where l.semua or c.depot_id = any(l.depot);
    if n_lama <> n_baru then
      raise exception 'GAGAL: jangkauan % (%) berbeda - can_access % baris, lingkup % baris.',
        u.user_code, u.role, n_lama, n_baru; end if;
  end loop;
  raise notice 'OK  1. Jangkauan setara can_access untuk seluruh pengguna aktif.';

  select id into v_uid from public.profiles
   where lower(coalesce(role,''))='system manager' and status='active' order by user_code limit 1;
  if v_uid is null then raise notice 'Tidak ada System Manager; sisa pemeriksaan dilewati.'; return; end if;
  if not exists (select 1 from public.claims) then
    raise notice 'Belum ada klaim; pemeriksaan bentuk dan waktu dilewati.'; return; end if;

  select no_doc into v_nd from public.claims order by no_doc limit 1;
  select customer_code into v_kc from public.customers where archived_at is null
   and exists(select 1 from public.customer_depots cd where cd.customer_id=customers.id)
   order by customer_code limit 1;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);

  -- 2. Bentuk baris lookup identik dengan pembentuknya.
  h := public.rc_lookup_master(array[v_kc], array[v_nd]);
  select string_agg(k, ',' order by k) into k_lookup from jsonb_object_keys(h->'documents'->0) k;
  select string_agg(k, ',' order by k) into k_asli
    from jsonb_object_keys(rc_private.legacy_documents(array[upper(v_nd)])->0) k;
  if k_lookup is distinct from k_asli then
    reset role; raise exception 'GAGAL: bentuk dokumen lookup (%) berbeda dari asal (%).', k_lookup, k_asli; end if;
  if not ((h->'documents'->0) ? 'custCode' and (h->'documents'->0) ? 'dcCode'
          and (h->'documents'->0) ? 'pendingApproval') then
    reset role; raise exception 'GAGAL: kolom yang dibaca layar hilang: %', k_lookup; end if;
  if jsonb_array_length(h->'customers') <> 1 then
    reset role; raise exception 'GAGAL: lookup pelanggan % mengembalikan % baris.',
      v_kc, jsonb_array_length(h->'customers'); end if;
  raise notice 'OK  2. Lookup berbentuk sama dengan pembentuknya: %', k_lookup;

  -- 3. Larik kosong tidak berubah menjadi "semua".
  h := public.rc_lookup_master('{}', '{}');
  if jsonb_array_length(h->'customers') <> 0 or jsonb_array_length(h->'documents') <> 0 then
    reset role; raise exception 'GAGAL: permintaan kosong mengembalikan data.'; end if;
  raise notice 'OK  3. Permintaan kosong mengembalikan kosong, bukan seluruh tabel.';

  -- 4. Antrean: isi terbaru utuh, dan waktunya di bawah batas kegagalan.
  perform public.rc_legacy_workflow();
  t0 := clock_timestamp();
  h := public.rc_legacy_workflow();
  ms := extract(epoch from (clock_timestamp()-t0))*1000;
  if not (h ? 'total' and h ? 'dimuat') then
    reset role; raise exception 'GAGAL: antrean tanpa total/dimuat.'; end if;
  if jsonb_array_length(h->'releaseData') > 0
     and not ((h->'releaseData'->0) ? 'approvedBy' and (h->'releaseData'->0) ? 'tglApprove') then
    reset role; raise exception 'GAGAL: kolom Approved By hilang dari antrean.'; end if;
  if exists (select 1 from jsonb_array_elements(h->'releaseData') v where v->>'status' <> 'Approved') then
    reset role; raise exception 'GAGAL: antrean Release memuat status selain Approved.'; end if;
  raise notice 'OK  4. Antrean % ms, dimuat % dari %, isi terbaru utuh.', round(ms), h->>'dimuat', h->>'total';

  -- 5. Login ringan.
  t0 := clock_timestamp();
  h := public.rc_legacy_bootstrap();
  ms := extract(epoch from (clock_timestamp()-t0))*1000;
  reset role;
  if coalesce(h->>'status','') <> 'success' then raise exception 'GAGAL: bootstrap tidak success.'; end if;
  if jsonb_array_length(h->'documents') <> 0 or jsonb_array_length(h->'customers') <> 0 then
    raise exception 'GAGAL: bootstrap masih mengirim daftar.'; end if;
  if not ((h->'data') ? 'tabs') then
    raise exception 'GAGAL: izin per tab hilang dari bootstrap.'; end if;
  raise notice 'OK  5. Bootstrap % ms, % KB, izin per tab utuh.', round(ms), round(length(h::text)/1024.0);
  if ms > 8000 then raise exception 'GAGAL: bootstrap % ms melewati batas 8 detik.', round(ms); end if;
exception when others then
  reset role; raise;
end
$periksa$;

-- Pemeriksaan kesetaraan menyetel klaim JWT; dikosongkan supaya tidak terbawa.
select set_config('request.jwt.claims', '', true);

-- Pemeriksaan bahwa can_tab tetap ada pada antrean - pengaman izin per tab milik Codex.
do $tab$
begin
  if position('can_tab(' in (select pg_get_functiondef(p.oid) from pg_proc p
       join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='rc_legacy_workflow')) = 0 then
    raise exception 'GAGAL: pemeriksaan izin per tab (can_tab) hilang dari rc_legacy_workflow.';
  end if;
  raise notice 'OK  6. can_tab tetap menjaga setiap antrean.';
end
$tab$;
