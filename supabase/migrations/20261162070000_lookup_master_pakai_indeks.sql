-- ==========================================================================================
-- Pencarian master per kode memakai indeks
-- ==========================================================================================
-- rc_lookup_master (20261162010000) mengambil customer dan dokumen hanya untuk kode yang
-- sedang dipakai layar. Layar Workflow memintanya untuk setiap halaman antrean: 1000 kode
-- sekaligus. Di dev, 100 ribu klaim: 6,7 detik untuk 1000 dokumen, dan sering melewati batas
-- 8 detik. Kueri yang sama di luar fungsi: 62 ms.
--
-- SEBABNYA: legacy_documents dan legacy_customers adalah fungsi SQL, yang direncanakan dengan
-- parameter generik. Penyaring "(p_nodoc is null or upper(no_doc) = any(p_nodoc))" tidak dapat
-- memakai indeks karena OR dengan parameter: seluruh tabel dipindai, dan setiap baris
-- dibandingkan dengan seluruh isi larik.
--
-- PERBAIKANNYA memisahkan "tanpa daftar kode" dan "dengan daftar kode" supaya masing-masing
-- punya rencana sendiri; cabang dengan daftar kode memakai indeks upper(...):
--
--   legacy_customers  dua cabang UNION ALL yang saling meniadakan ("p_kode is null" /
--                     "is not null", dievaluasi sekali). 300 kode: 3.080 ms -> 25 ms.
--   legacy_documents  cara yang sama justru memburuk (10 detik): karena "order by no_doc
--                     limit 20000", perencana menyusuri seluruh klaim menurut no_doc sambil
--                     mencocokkan ke hasil union. Maka fungsinya menjadi PL/pgSQL dengan dua
--                     cabang IF, masing-masing berisi kueri lama dengan penyaring yang sudah
--                     disederhanakan untuk cabangnya. 300 kode: 5.600 ms -> 8 - 12 ms (hangat),
--                     1000 kode 277 ms, tanpa daftar 810 ms.
--
-- Setiap baris tetap muncul tepat sekali, penyaring lain tidak berubah, urutan dan batas
-- 20000 tidak berubah.
--
-- Dibuktikan: keluaran lama dan baru dibandingkan untuk beberapa pengguna dan beberapa isi
-- larik (sampel 300 kode, kode dengan huruf kecil, kode yang tidak ada, larik kosong dan
-- null), sebelum definisi lama diganti.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create temp table _lookup_sebelum(kunci text primary key, hasil jsonb) on commit drop;

do $sebelum$
-- Keluaran LAMA diambil dengan menjalankan isi fungsi lama itu sendiri (prosrc), dengan
-- parameternya diganti nilai konstanta. Maknanya persis sama dengan memanggil fungsinya;
-- bedanya hanya pada rencana kueri - dengan konstanta, perencana dapat memakai indeks,
-- sehingga pembandingan tidak memakan waktu yang justru sedang diperbaiki migrasi ini.
declare u record; docs text[]; custs text[]; k text; uji record; src_doc text; src_cust text;
  hasil jsonb; q text;
begin
  if pg_get_functiondef('rc_private.legacy_documents(text[])'::regprocedure) ~ 'if p_nodoc is null then' then
    raise notice 'legacy_documents sudah ditambal; pembandingan dilewati.'; return; end if;

  select prosrc into src_doc from pg_proc where oid = 'rc_private.legacy_documents(text[])'::regprocedure;
  select prosrc into src_cust from pg_proc where oid = 'rc_private.legacy_customers(boolean,text[])'::regprocedure;

  select array_agg(upper(no_doc)) into docs
    from (select no_doc from public.claims order by no_doc limit 300) t;
  select array_agg(upper(customer_code)) into custs
    from (select customer_code from public.customers order by customer_code limit 300) t;

  for u in (select id, user_code from public.profiles where status = 'active' and role = 'system manager' order by user_code limit 1)
           union all
           (select id, user_code from public.profiles where status = 'active' and role <> 'system manager' order by user_code limit 1) loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    for uji in select * from (values
        ('sampel',  docs, custs),
        ('campur',  array[lower(docs[1]), docs[2], 'TIDAK-ADA-XYZ', null], array[lower(custs[1]), custs[2], 'TIDAK-ADA-XYZ', null]),
        ('kosong',  '{}'::text[], '{}'::text[]),
        ('null',    null::text[], null::text[])) v(nama, d, c) loop
      k := u.user_code || '|' || uji.nama;

      q := regexp_replace(src_doc, '\mp_nodoc\M', coalesce(quote_literal(uji.d::text), 'NULL') || '::text[]', 'g');
      execute q into hasil;
      insert into _lookup_sebelum values (k || '|doc', hasil);

      -- legacy_customers(..., null) tidak lagi dipanggil siapa pun (bootstrap mengirim larik
      -- kosong sejak 20261162010000) dan mengembalikan seluruh customer - pada 100 ribu
      -- customer belasan detik. Cabang null-nya adalah kueri lama tanpa penyaring kode, persis.
      if uji.nama <> 'null' then
        q := regexp_replace(src_cust, '\mp_kode\M', coalesce(quote_literal(uji.c::text), 'NULL') || '::text[]', 'g');
        execute regexp_replace(q, '\mp_with_contacts\M', 'true', 'g') into hasil;
        insert into _lookup_sebelum values (k || '|cust', hasil);
        execute regexp_replace(q, '\mp_with_contacts\M', 'false', 'g') into hasil;
        insert into _lookup_sebelum values (k || '|cust0', hasil);
      end if;
    end loop;
  end loop;
  perform set_config('request.jwt.claims', '', true);
end
$sebelum$;

-- legacy_documents: penjaga pra-citra, lalu definisi dua cabang. Definisi lama yang hidup
-- harus persis yang diukur di dev; bila berbeda (misalnya di prod ada perubahan lain),
-- migrasi berhenti alih-alih menimpanya.
do $pra_docs$
declare md5_kini text;
begin
  md5_kini := md5(pg_get_functiondef('rc_private.legacy_documents(text[])'::regprocedure));
  if md5_kini = '0557a96e594bfd3cdd5fed57a77cb6f6' then return; end if;
  if pg_get_functiondef('rc_private.legacy_documents(text[])'::regprocedure) ~ 'if p_nodoc is null then' then
    raise notice 'legacy_documents sudah dua cabang.'; return; end if;
  raise exception 'DITOLAK: definisi legacy_documents berbeda dari yang diukur (md5 %).', md5_kini;
end
$pra_docs$;

create or replace function rc_private.legacy_documents(p_nodoc text[] default null::text[])
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
begin
  -- Tanpa daftar kode: seluruh dokumen dalam jangkauan (paling banyak 20000), seperti dulu.
  if p_nodoc is null then
    return (select coalesce(jsonb_agg(x order by x->>'noDoc'),'[]'::jsonb) from (
      select jsonb_build_object(
       'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
       'dcCode',d.depot_code,'depotName',d.depot_name,
       'custCode',cu.customer_code,'custName',cu.customer_name,
       'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
       'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'cbNet',c.cb_net,'netValue',c.net_value,'volume',c.volume,
       'pendingApproval',c.pending_approval is not null,'versionNo',c.version_no) as x
      from public.claims c
      join public.depots d on d.id=c.depot_id
      join public.customers cu on cu.id=c.customer_id
      join public.campaigns ca on ca.id=c.campaign_id
      cross join rc_private.lingkup_depot_saya() l
      where (l.semua or c.depot_id = any(l.depot))
      order by c.no_doc limit 20000) t);
  end if;

  -- Dengan daftar kode: hanya kode itu, dicari lewat indeks upper(no_doc). Penyaringnya
  -- adalah "(p_nodoc is null or upper(no_doc) = any(p_nodoc))" yang lama, untuk p_nodoc
  -- yang tidak null.
  return (select coalesce(jsonb_agg(x order by x->>'noDoc'),'[]'::jsonb) from (
    select jsonb_build_object(
     'noDoc',c.no_doc,'status',rc_private.legacy_status(c.status),
     'dcCode',d.depot_code,'depotName',d.depot_name,
     'custCode',cu.customer_code,'custName',cu.customer_name,
     'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
     'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'cbNet',c.cb_net,'netValue',c.net_value,'volume',c.volume,
     'pendingApproval',c.pending_approval is not null,'versionNo',c.version_no) as x
    from public.claims c
    join public.depots d on d.id=c.depot_id
    join public.customers cu on cu.id=c.customer_id
    join public.campaigns ca on ca.id=c.campaign_id
    cross join rc_private.lingkup_depot_saya() l
    where upper(c.no_doc) = any(p_nodoc)
      and (l.semua or c.depot_id = any(l.depot))
    order by c.no_doc limit 20000) t);
end
$fn$;

do $tambal_cust$
declare src text; baru text; pola text; n int;
begin
  -- legacy_customers --------------------------------------------------------------------
  select pg_get_functiondef('rc_private.legacy_customers(boolean,text[])'::regprocedure) into src;
  if src !~ 'union all' then
    pola := 'from public\.customers cu(\s+)cross join rc_private\.lingkup_depot_saya\(\) l';
    select count(*) into n from regexp_matches(src, pola, 'g');
    if n <> 1 then raise exception 'legacy_customers: FROM ditemukan % kali, diharapkan 1.', n; end if;
    baru := regexp_replace(src, pola,
      'from (select cu.id from public.customers cu where p_kode is null\1'
      || 'union all\1'
      || 'select cu.id from public.customers cu where p_kode is not null and upper(cu.customer_code) = any(p_kode)) pilih\1'
      || 'join public.customers cu on cu.id=pilih.id\1'
      || 'cross join rc_private.lingkup_depot_saya() l');

    pola := '\s+and \(p_kode is null or upper\(cu\.customer_code\) = any\(p_kode\)\)';
    select count(*) into n from regexp_matches(baru, pola, 'g');
    if n <> 1 then raise exception 'legacy_customers: penyaring kode ditemukan % kali, diharapkan 1.', n; end if;
    baru := regexp_replace(baru, pola, '');
    execute baru;
    raise notice 'legacy_customers ditambal.';
  end if;
end
$tambal_cust$;

do $sesudah$
declare r record; u_id uuid; bagian text[]; docs text[]; custs text[]; d text[]; c text[]; hasil jsonb; n int := 0;
begin
  select array_agg(upper(no_doc)) into docs
    from (select no_doc from public.claims order by no_doc limit 300) t;
  select array_agg(upper(customer_code)) into custs
    from (select customer_code from public.customers order by customer_code limit 300) t;
  for r in select * from _lookup_sebelum order by kunci loop
    bagian := string_to_array(r.kunci, '|');
    select id into u_id from public.profiles where user_code = bagian[1];
    perform set_config('request.jwt.claims',
      json_build_object('sub', u_id::text, 'role', 'authenticated')::text, true);
    d := case bagian[2] when 'sampel' then docs
                        when 'campur' then array[lower(docs[1]), docs[2], 'TIDAK-ADA-XYZ', null]
                        when 'kosong' then '{}'::text[] else null end;
    c := case bagian[2] when 'sampel' then custs
                        when 'campur' then array[lower(custs[1]), custs[2], 'TIDAK-ADA-XYZ', null]
                        when 'kosong' then '{}'::text[] else null end;
    hasil := case bagian[3] when 'doc' then rc_private.legacy_documents(d)
                            when 'cust' then rc_private.legacy_customers(true, c)
                            else rc_private.legacy_customers(false, c) end;
    if hasil is distinct from r.hasil then
      raise exception 'GAGAL lookup %: keluaran berubah (% -> % baris).',
        r.kunci, jsonb_array_length(r.hasil), jsonb_array_length(hasil); end if;
    n := n + 1;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'Pencarian master identik pada % kombinasi.', n;
end
$sesudah$;
