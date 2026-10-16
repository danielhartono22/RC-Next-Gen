-- ==========================================================================================
-- customer_depots tanpa probe per depot, Approval History dan People Performance
-- ==========================================================================================
-- Tiga penghambat yang tersisa di dev (100 ribu klaim, 100 ribu customer):
--
-- 1. KEBIJAKAN customer_depots (20261162040000) berbentuk "depot_id = any(<daftar depot>)".
--    Di dalam RLS customers (exists customer_depots ...) perencana kueri memakai bentuk itu
--    sebagai syarat indeks (depot_id, customer_id): SATU PROBE INDEKS PER DEPOT per customer.
--    System Manager dengan 51 depot = 51 probe untuk setiap customer yang disentuh. Menghitung
--    100 ribu klaim beserta customernya: 5,1 - 8,6 detik.
--    Bentuk "<daftar depot> @> array[depot_id]" tidak dapat dipakai sebagai syarat indeks,
--    sehingga baris dicari lewat kunci primer (customer_id, ...) lalu disaring: satu probe.
--    Hitungan yang sama: 0,44 - 0,75 detik. Diukur di dalam transaksi yang di-rollback.
--
--    Kesetaraan: untuk x yang tidak null, "arr @> array[x]" benar tepat ketika "x = any(arr)"
--    benar - keduanya memakai kesamaan bawaan uuid. depot_id dijamin NOT NULL (diperiksa).
--
-- 2. rc_approval_history memanggil can_access(depot, 'approve_claim') untuk SETIAP baris
--    riwayat approval (55 ribu di dev), dua kali (hitung total dan halaman). Selalu melewati
--    8 detik. Diganti padanannya yang dihitung sekali:
--
--      can_access(d, izin) = saya_sm() or (d = any(depot_akses_saya()) and can_access(null, izin))
--
--    Diturunkan dari definisi can_access: System Manager lolos tanpa syarat; selain itu harus
--    aktif, tidak wajib ganti PIN, memegang depot d, dan memenuhi syarat izin - dan syarat izin
--    itu sendiri tidak bergantung pada depot. DIBUKTIKAN untuk setiap pengguna x setiap depot.
--    claims.depot_id dijamin NOT NULL, jadi cabang "depot kosong" tidak pernah terjadi.
--    Ditambah indeks riwayat approval menurut waktu, untuk halaman terbaru.
--
-- 3. rc_private.people_metrics menyaring klaim dengan "depot_id = any(p_depots) and
--    can_access(depot_id)" - can_access per klaim. Diganti "depot_id = any(<p_depots yang
--    lolos can_access>)", dihitung sekali. Itu identitas himpunan, bukan pendekatan.
--    Riwayat status per klaim hanya dibutuhkan untuk tanggal di masa lalu; untuk hari ini
--    nilainya tidak dipakai (cabang CASE memakai status sekarang), tetapi tetap dibaca untuk
--    setiap klaim. Kini tidak dibaca bila tidak dipakai. Hasil sebelum dan sesudah
--    dibandingkan untuk beberapa pengguna, himpunan depot dan tanggal.
--
-- Setiap tambalan diterapkan pada definisi yang hidup, dengan penjaga: bila pola yang dicari
-- tidak ditemukan tepat sebanyak yang diharapkan, migrasi berhenti.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. customer_depots
-- ------------------------------------------------------------------------------------------
do $cd_syarat$
begin
  if not (select attnotnull from pg_attribute
           where attrelid = 'public.customer_depots'::regclass and attname = 'depot_id') then
    raise exception 'customer_depots.depot_id boleh NULL; kesetaraan @> dan = any tidak berlaku.';
  end if;
end
$cd_syarat$;

drop policy if exists customer_depots_scoped on public.customer_depots;
create policy customer_depots_scoped on public.customer_depots
  for select to authenticated
  using ((select rc_private.depot_cd_saya())::uuid[] @> array[depot_id]);

do $cd_jalur$
declare u record; dp uuid[]; r_cd bigint; r_cust bigint; h_cd bigint; h_cust bigint;
begin
  for u in select id, user_code from public.profiles order by user_code loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    dp := rc_private.depot_cd_saya();
    select count(*) into h_cd from public.customer_depots where depot_id = any(dp);
    select count(*) into h_cust from public.customers cu
     where exists(select 1 from public.customer_depots x where x.customer_id = cu.id and x.depot_id = any(dp));

    set local role authenticated;
    select count(*) into r_cd from public.customer_depots;
    select count(*) into r_cust from public.customers;
    reset role;

    if (r_cd, r_cust) is distinct from (h_cd, h_cust) then
      raise exception 'GAGAL: % melihat customer_depot/customer %/% lewat RLS, seharusnya %/%.',
        u.user_code, r_cd, r_cust, h_cd, h_cust; end if;
  end loop;
  perform set_config('request.jwt.claims', '', true);
exception when others then
  reset role; raise;
end
$cd_jalur$;

-- ------------------------------------------------------------------------------------------
-- 2. rc_approval_history
-- ------------------------------------------------------------------------------------------
do $syarat_depot$
begin
  if not (select attnotnull from pg_attribute
           where attrelid = 'public.claims'::regclass and attname = 'depot_id') then
    raise exception 'claims.depot_id boleh NULL; padanan can_access tidak berlaku.';
  end if;
end
$syarat_depot$;

-- Pembuktian padanan untuk izin approve_claim, setiap pengguna x setiap depot.
do $setara_izin$
declare u record; d record; n int := 0;
begin
  for u in select id, user_code, role, status from public.profiles order by user_code loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    for d in select id, depot_code from public.depots loop
      if rc_private.can_access(d.id, 'approve_claim')
         is distinct from (rc_private.saya_sm()
                           or (d.id = any(rc_private.depot_akses_saya())
                               and rc_private.can_access(null, 'approve_claim'))) then
        raise exception 'GAGAL padanan approve_claim: % (% / %) depot %.',
          u.user_code, u.role, u.status, d.depot_code; end if;
      n := n + 1;
    end loop;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'Padanan can_access(depot, approve_claim) terbukti untuk % pasangan.', n;
end
$setara_izin$;

do $tambal_riwayat$
declare src text; baru text; lama_filter text; n int;
begin
  select pg_get_functiondef('public.rc_approval_history(integer,integer,text,text)'::regprocedure) into src;
  if src ~ 'v_izin' then
    raise notice 'rc_approval_history sudah ditambal; dilewati.'; return; end if;

  lama_filter := 'and rc_private.can_access(c.depot_id,''approve_claim'')';
  n := (length(src) - length(replace(src, lama_filter, ''))) / length(lama_filter);
  if n <> 2 then
    raise exception 'rc_approval_history: penyaring can_access ditemukan % kali, diharapkan 2.', n; end if;
  baru := replace(src, lama_filter, 'and (v_sm or (c.depot_id = any(v_akses) and v_izin))');

  if position('declare hasil jsonb; v_total bigint;' in baru) = 0 then
    raise exception 'rc_approval_history: deklarasi tidak dikenali.'; end if;
  baru := replace(baru, 'declare hasil jsonb; v_total bigint;',
    'declare hasil jsonb; v_total bigint; v_sm boolean; v_akses uuid[]; v_izin boolean;');

  if position('raise exception ''Tidak punya hak melihat riwayat approval'' using errcode=''42501''; end if;' in baru) = 0 then
    raise exception 'rc_approval_history: pemeriksaan hak tidak dikenali.'; end if;
  baru := replace(baru,
    'raise exception ''Tidak punya hak melihat riwayat approval'' using errcode=''42501''; end if;',
    'raise exception ''Tidak punya hak melihat riwayat approval'' using errcode=''42501''; end if;
  -- Padanan can_access(depot,''approve_claim''), dihitung sekali (lihat 20261162060000).
  v_sm    := rc_private.saya_sm();
  v_akses := rc_private.depot_akses_saya();
  v_izin  := rc_private.can_access(null,''approve_claim'');');

  execute baru;
  raise notice 'rc_approval_history ditambal.';
end
$tambal_riwayat$;

create index if not exists claim_status_history_approval_idx
  on public.claim_status_history (created_at desc)
  where action in ('approve','reject_approval');

-- ------------------------------------------------------------------------------------------
-- 3. rc_private.people_metrics
-- ------------------------------------------------------------------------------------------
create temp table _people_sebelum(kunci text primary key, hasil jsonb) on commit drop;

do $people_sebelum$
declare u record; semua uuid[]; satu uuid[]; tgl date; k text;
begin
  if pg_get_functiondef('rc_private.people_metrics(uuid[],date)'::regprocedure) ~ 'unnest\(p_depots\)' then
    raise notice 'people_metrics sudah ditambal; pembandingan dilewati.'; return; end if;
  select coalesce(array_agg(id order by depot_code), '{}') into semua from public.depots;
  satu := semua[1:1];
  -- Satu System Manager dan satu pengguna lain yang aktif: keduanya menempuh cabang can_access
  -- yang berbeda. Dibatasi dua supaya pembandingan tidak mendekati batas waktu gerbang.
  for u in (select id, user_code from public.profiles where status = 'active' and role = 'system manager' order by user_code limit 1)
           union all
           (select id, user_code from public.profiles where status = 'active' and role <> 'system manager' order by user_code limit 1) loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    foreach tgl in array array[(now() at time zone 'Asia/Jakarta')::date,
                               (now() at time zone 'Asia/Jakarta')::date - 45] loop
      k := u.user_code || '|semua|' || tgl;
      insert into _people_sebelum values (k, rc_private.people_metrics(semua, tgl));
      k := u.user_code || '|satu|' || tgl;
      insert into _people_sebelum values (k, rc_private.people_metrics(satu, tgl));
    end loop;
  end loop;
  perform set_config('request.jwt.claims', '', true);
end
$people_sebelum$;

do $tambal_people$
declare src text; baru text; lama text; n int;
begin
  select pg_get_functiondef('rc_private.people_metrics(uuid[],date)'::regprocedure) into src;
  if src ~ 'unnest\(p_depots\)' then
    raise notice 'people_metrics sudah ditambal; dilewati.'; return; end if;

  lama := 'c.depot_id=any(p_depots) and rc_private.can_access(c.depot_id)';
  n := (length(src) - length(replace(src, lama, ''))) / length(lama);
  if n <> 1 then raise exception 'people_metrics: penyaring klaim ditemukan % kali, diharapkan 1.', n; end if;
  baru := replace(src, lama,
    'c.depot_id=any(array(select x from unnest(p_depots) x where rc_private.can_access(x)))');

  -- Definisinya tersimpan dengan akhir baris CRLF; pola ditulis sebagai regex yang menerima
  -- spasi apa pun di antara kedua syarat.
  lama := '(where h\.claim_id=c\.id\s+and h\.created_at<\(p_asof\+1\)::timestamp at time zone ''Asia/Jakarta'')';
  select count(*) into n from regexp_matches(baru, lama, 'g');
  if n <> 1 then raise exception 'people_metrics: penyaring riwayat ditemukan % kali, diharapkan 1.', n; end if;
  baru := regexp_replace(baru, lama, '\1 and p_asof<(now() at time zone ''Asia/Jakarta'')::date');

  execute baru;
  raise notice 'people_metrics ditambal.';
end
$tambal_people$;

do $people_sesudah$
declare r record; u_id uuid; semua uuid[]; satu uuid[]; bagian text[]; hasil jsonb; n int := 0;
begin
  select coalesce(array_agg(id order by depot_code), '{}') into semua from public.depots;
  satu := semua[1:1];
  for r in select * from _people_sebelum loop
    bagian := string_to_array(r.kunci, '|');
    select id into u_id from public.profiles where user_code = bagian[1];
    perform set_config('request.jwt.claims',
      json_build_object('sub', u_id::text, 'role', 'authenticated')::text, true);
    hasil := rc_private.people_metrics(case when bagian[2] = 'semua' then semua else satu end, bagian[3]::date);
    if hasil is distinct from r.hasil then
      raise exception 'GAGAL people_metrics %: sebelum % | sesudah %', r.kunci, r.hasil, hasil; end if;
    n := n + 1;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'people_metrics identik pada % kombinasi.', n;
end
$people_sesudah$;
