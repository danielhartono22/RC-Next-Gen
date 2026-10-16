-- ==========================================================================================
-- Arsip Key Master: Customer, Campaign dan Depot dapat dipensiunkan tanpa dihapus
-- ==========================================================================================
-- Permintaan pemilik, 20 September 2026: "key master juga bisa di archive ya", untuk ketiga
-- tabnya.
--
-- MENGAPA ARSIP, BUKAN HAPUS
-- Sampai sekarang Key Master hanya punya satu cara memensiunkan baris, yaitu rc_campaign_delete
-- - dan itu pun menolak campaign yang sudah punya dokumen, karena menghapusnya akan memutus
-- rujukan riwayat. Akibatnya campaign lama yang sudah tidak dipakai tetap menumpuk di daftar,
-- sementara Customer dan Depot tidak punya cara apa pun untuk dipensiunkan.
--
-- Arsip menyelesaikan keduanya: baris yang diarsipkan hilang dari seluruh daftar dan tidak dapat
-- dipakai untuk dokumen baru, tetapi barisnya tetap ada sehingga dokumen lama yang merujuknya
-- tetap terbaca utuh. Dan karena hanya ditandai, ia dapat dikembalikan.
--
-- SATU SYARAT SEBELUM MENGARSIPKAN
-- Baris yang masih memegang dokumen BELUM SELESAI - not_yet, submitted, released, claimed atau
-- on_hold - ditolak, dengan menyebut jumlahnya. Alasannya sederhana: mengarsipkan customer yang
-- dokumennya masih menunggu clearing berarti menyembunyikan master dari orang yang sedang
-- mengerjakannya. Dokumen yang sudah done atau expired tidak menghalangi, karena tidak ada lagi
-- yang perlu dikerjakan atasnya.
--
-- YANG IKUT DISARING
-- Menandai baris saja tidak cukup - setiap tempat yang membaca master harus ikut melewatinya,
-- atau baris terarsip akan tetap muncul di layar upload dan tetap lolos compile. Karena itu
-- migration ini juga menambal tujuh fungsi pembaca:
--
--   rc_customer_list, rc_campaign_list, rc_depot_list   - daftar di layar Key Master
--   rc_private.legacy_customers, legacy_all_depots      - umpan untuk layar Upload
--   rc_public_depots                                    - daftar depot di halaman pendaftaran
--   rc_private.compile_upload                           - penolakan saat compile
--
-- Seperti migration sebelumnya, penambalan dilakukan dengan MEMBACA definisi yang sedang
-- terpasang lalu mengganti satu pola di dalamnya - bukan menyalin badan fungsi ke berkas ini,
-- yang akan membeku dan menyimpang diam-diam. Bila polanya tidak ditemukan, migration BERHENTI
-- dengan galat alih-alih diam-diam tidak menyaring apa pun.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Kolom penanda
-- ------------------------------------------------------------------------------------------
alter table public.customers add column if not exists archived_at     timestamptz;
alter table public.customers add column if not exists archived_by     uuid;
alter table public.customers add column if not exists archive_reason  text;

alter table public.campaigns add column if not exists archived_at     timestamptz;
alter table public.campaigns add column if not exists archived_by     uuid;
alter table public.campaigns add column if not exists archive_reason  text;

alter table public.depots    add column if not exists archived_at     timestamptz;
alter table public.depots    add column if not exists archived_by     uuid;
alter table public.depots    add column if not exists archive_reason  text;

-- Daftar aktif selalu menyaring archived_at is null, jadi indeks parsial ini yang dipakai.
create index if not exists customers_aktif_idx on public.customers (customer_code) where archived_at is null;
create index if not exists campaigns_aktif_idx on public.campaigns (campaign_code) where archived_at is null;
create index if not exists depots_aktif_idx    on public.depots    (depot_code)    where archived_at is null;

-- ------------------------------------------------------------------------------------------
-- 2. Mengarsipkan
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_master_archive(p_jenis text, p_kunci jsonb, p_alasan text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  aku uuid := (select auth.uid());
  kunci text; v_id uuid; v_nama text; n_terbuka bigint;
  n_ok integer := 0; gagal jsonb := '[]'::jsonb;
begin
  if not rc_private.can_access(null,'manage_key_master') then
    raise exception 'Tidak punya hak mengubah Key Master' using errcode='42501'; end if;
  if p_jenis not in ('customer','campaign','depot') then
    raise exception 'Jenis master tidak dikenali: %', coalesce(p_jenis,'(kosong)'); end if;
  if jsonb_typeof(p_kunci) <> 'array' or jsonb_array_length(p_kunci) = 0 then
    raise exception 'Tidak ada baris yang dipilih'; end if;
  if jsonb_array_length(p_kunci) > 200 then
    raise exception 'Maksimal 200 baris sekali arsip'; end if;

  for kunci in select upper(btrim(value)) from jsonb_array_elements_text(p_kunci) loop
    if kunci = '' then continue; end if;

    -- select ... into TIDAK mengosongkan peubah ketika tidak ada baris; dikosongkan sendiri
    -- supaya baris sebelumnya tidak terbawa dan salah diarsipkan.
    v_id := null; v_nama := null;
    if p_jenis = 'customer' then
      select id, customer_name into v_id, v_nama from public.customers
       where upper(customer_code) = kunci and archived_at is null for update;
    elsif p_jenis = 'campaign' then
      select id, campaign_name into v_id, v_nama from public.campaigns
       where upper(campaign_code) = kunci and archived_at is null for update;
    else
      select id, depot_name into v_id, v_nama from public.depots
       where upper(depot_code) = kunci and archived_at is null for update;
    end if;

    if v_id is null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('kode',kunci,
        'sebab','Tidak ditemukan, atau sudah diarsipkan'));
      continue;
    end if;

    select count(*) into n_terbuka from public.claims c
     where c.archived_at is null
       and c.status in ('not_yet','submitted','released','claimed','on_hold')
       and ((p_jenis = 'customer' and c.customer_id = v_id)
         or (p_jenis = 'campaign' and c.campaign_id = v_id)
         or (p_jenis = 'depot'    and c.depot_id    = v_id));
    if n_terbuka > 0 then
      gagal := gagal || jsonb_build_array(jsonb_build_object('kode',kunci,
        'sebab','Masih memegang '||n_terbuka||' dokumen yang belum selesai. '
                ||'Selesaikan atau hanguskan lebih dulu, baru diarsipkan.'));
      continue;
    end if;

    if p_jenis = 'customer' then
      update public.customers set archived_at = now(), archived_by = aku,
        archive_reason = nullif(left(btrim(coalesce(p_alasan,'')),300),'') where id = v_id;
    elsif p_jenis = 'campaign' then
      update public.campaigns set archived_at = now(), archived_by = aku,
        archive_reason = nullif(left(btrim(coalesce(p_alasan,'')),300),'') where id = v_id;
    else
      update public.depots set archived_at = now(), archived_by = aku,
        archive_reason = nullif(left(btrim(coalesce(p_alasan,'')),300),'') where id = v_id;
    end if;

    insert into public.activity_logs(actor_id,event_type,entity_id,details)
    values(aku,'master_archive',v_id,jsonb_build_object(
      'jenis',p_jenis,'kode',kunci,'nama',coalesce(v_nama,''),'alasan',coalesce(p_alasan,'')));
    n_ok := n_ok + 1;
  end loop;

  return jsonb_build_object('status','success','berhasil',n_ok,
    'gagal',gagal,'jumlahGagal',jsonb_array_length(gagal),
    'message',n_ok||' baris diarsipkan'
      ||case when jsonb_array_length(gagal) > 0
             then ', '||jsonb_array_length(gagal)||' ditolak' else '' end);
end $fn$;
revoke all on function public.rc_master_archive(text,jsonb,text) from public,anon;
grant execute on function public.rc_master_archive(text,jsonb,text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Mengembalikan dari arsip
-- ------------------------------------------------------------------------------------------
-- Kode master bersifat UNIQUE dan tetap dipegang baris terarsip, sehingga tidak mungkin ada
-- baris lain memakai kode yang sama selama ia diarsipkan. Karena itu pemulihan tidak perlu
-- memeriksa bentrokan - berbeda dari pemulihan akun, yang User ID-nya dapat direbut.
create or replace function public.rc_master_unarchive(p_jenis text, p_kunci jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  aku uuid := (select auth.uid());
  kunci text; v_id uuid; v_nama text;
  n_ok integer := 0; gagal jsonb := '[]'::jsonb;
begin
  if not rc_private.can_access(null,'manage_key_master') then
    raise exception 'Tidak punya hak mengubah Key Master' using errcode='42501'; end if;
  if p_jenis not in ('customer','campaign','depot') then
    raise exception 'Jenis master tidak dikenali: %', coalesce(p_jenis,'(kosong)'); end if;
  if jsonb_typeof(p_kunci) <> 'array' or jsonb_array_length(p_kunci) = 0 then
    raise exception 'Tidak ada baris yang dipilih'; end if;
  if jsonb_array_length(p_kunci) > 200 then
    raise exception 'Maksimal 200 baris sekali pulihkan'; end if;

  for kunci in select upper(btrim(value)) from jsonb_array_elements_text(p_kunci) loop
    if kunci = '' then continue; end if;
    v_id := null; v_nama := null;

    if p_jenis = 'customer' then
      select id, customer_name into v_id, v_nama from public.customers
       where upper(customer_code) = kunci and archived_at is not null for update;
      if v_id is not null then
        update public.customers set archived_at = null, archived_by = null,
          archive_reason = null where id = v_id; end if;
    elsif p_jenis = 'campaign' then
      select id, campaign_name into v_id, v_nama from public.campaigns
       where upper(campaign_code) = kunci and archived_at is not null for update;
      if v_id is not null then
        update public.campaigns set archived_at = null, archived_by = null,
          archive_reason = null where id = v_id; end if;
    else
      select id, depot_name into v_id, v_nama from public.depots
       where upper(depot_code) = kunci and archived_at is not null for update;
      if v_id is not null then
        update public.depots set archived_at = null, archived_by = null,
          archive_reason = null where id = v_id; end if;
    end if;

    if v_id is null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('kode',kunci,
        'sebab','Tidak ada di arsip'));
      continue;
    end if;

    insert into public.activity_logs(actor_id,event_type,entity_id,details)
    values(aku,'master_unarchive',v_id,jsonb_build_object(
      'jenis',p_jenis,'kode',kunci,'nama',coalesce(v_nama,'')));
    n_ok := n_ok + 1;
  end loop;

  return jsonb_build_object('status','success','berhasil',n_ok,
    'gagal',gagal,'jumlahGagal',jsonb_array_length(gagal),
    'message',n_ok||' baris dikembalikan dari arsip'
      ||case when jsonb_array_length(gagal) > 0
             then ', '||jsonb_array_length(gagal)||' ditolak' else '' end);
end $fn$;
revoke all on function public.rc_master_unarchive(text,jsonb) from public,anon;
grant execute on function public.rc_master_unarchive(text,jsonb) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Isi tab Arsip
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_master_archived(p_jenis text, p_search text default '')
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v jsonb; nama jsonb; cari text;
begin
  if not rc_private.can_access(null,'manage_key_master') then
    raise exception 'Tidak punya hak membuka Key Master' using errcode='42501'; end if;
  if p_jenis not in ('customer','campaign','depot') then
    raise exception 'Jenis master tidak dikenali: %', coalesce(p_jenis,'(kosong)'); end if;

  cari := nullif(btrim(coalesce(p_search,'')),'');
  nama := rc_private.peta_nama_pelaku();

  if p_jenis = 'customer' then
    select coalesce(jsonb_agg(x order by x->>'diarsipkanPada' desc),'[]'::jsonb) into v from (
      select jsonb_build_object('kode',cu.customer_code,'nama',cu.customer_name,
        'diarsipkanPada',to_char(cu.archived_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
        'diarsipkanOleh',coalesce(nama->>(cu.archived_by::text),''),
        'alasan',coalesce(cu.archive_reason,''),
        'dokumen',(select count(*) from public.claims c where c.customer_id = cu.id)) as x
        from public.customers cu where cu.archived_at is not null
         and (cari is null or cu.customer_code ilike '%'||cari||'%'
                           or cu.customer_name ilike '%'||cari||'%')) t;
  elsif p_jenis = 'campaign' then
    select coalesce(jsonb_agg(x order by x->>'diarsipkanPada' desc),'[]'::jsonb) into v from (
      select jsonb_build_object('kode',ca.campaign_code,'nama',ca.campaign_name,
        'diarsipkanPada',to_char(ca.archived_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
        'diarsipkanOleh',coalesce(nama->>(ca.archived_by::text),''),
        'alasan',coalesce(ca.archive_reason,''),
        'dokumen',(select count(*) from public.claims c where c.campaign_id = ca.id)) as x
        from public.campaigns ca where ca.archived_at is not null
         and (cari is null or ca.campaign_code ilike '%'||cari||'%'
                           or ca.campaign_name ilike '%'||cari||'%')) t;
  else
    select coalesce(jsonb_agg(x order by x->>'diarsipkanPada' desc),'[]'::jsonb) into v from (
      select jsonb_build_object('kode',d.depot_code,'nama',d.depot_name,
        'diarsipkanPada',to_char(d.archived_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
        'diarsipkanOleh',coalesce(nama->>(d.archived_by::text),''),
        'alasan',coalesce(d.archive_reason,''),
        'dokumen',(select count(*) from public.claims c where c.depot_id = d.id)) as x
        from public.depots d where d.archived_at is not null
         and (cari is null or d.depot_code ilike '%'||cari||'%'
                           or d.depot_name ilike '%'||cari||'%')) t;
  end if;

  return jsonb_build_object('status','success','jenis',p_jenis,'rows',v);
end $fn$;
revoke all on function public.rc_master_archived(text,text) from public,anon;
grant execute on function public.rc_master_archived(text,text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 5. Menyaring arsip dari setiap pembaca master
-- ------------------------------------------------------------------------------------------
do $saring$
declare src text; baru text; n int := 0;
begin
  -- 5a. rc_customer_list --------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'public' and p.proname = 'rc_customer_list';
  if src is null then raise exception 'public.rc_customer_list tidak ditemukan.'; end if;
  if position('cu.archived_at is null' in src) = 0 then
    baru := replace(src,
      'from public.customers cu' || chr(10) || '  where (coalesce(btrim(p_search),'''')=''''',
      'from public.customers cu' || chr(10) || '  where cu.archived_at is null and (coalesce(btrim(p_search),'''')=''''');
    baru := replace(baru,
      '''total'',(select count(*) from public.customers));',
      '''total'',(select count(*) from public.customers where archived_at is null));');
    if baru = src then raise exception 'Pola rc_customer_list tidak ditemukan.'; end if;
    execute baru; n := n + 1;
  end if;

  -- 5b. rc_campaign_list --------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'public' and p.proname = 'rc_campaign_list';
  if src is null then raise exception 'public.rc_campaign_list tidak ditemukan.'; end if;
  if position('ca.archived_at is null and (coalesce' in src) = 0 then
    baru := replace(src,
      'from public.campaigns ca' || chr(10) || '  where (coalesce(btrim(p_search),'''')=''''',
      'from public.campaigns ca' || chr(10) || '  where ca.archived_at is null and (coalesce(btrim(p_search),'''')=''''');
    baru := replace(baru,
      '''total'',(select count(*) from public.campaigns));',
      '''total'',(select count(*) from public.campaigns where archived_at is null));');
    if baru = src then raise exception 'Pola rc_campaign_list tidak ditemukan.'; end if;
    execute baru; n := n + 1;
  end if;

  -- 5c. rc_depot_list -----------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'public' and p.proname = 'rc_depot_list';
  if src is null then raise exception 'public.rc_depot_list tidak ditemukan.'; end if;
  if position('d.archived_at is null' in src) = 0 then
    baru := replace(src,
      'where v_search is null' || chr(10)
        || '          or d.depot_code ilike ''%''||v_search||''%''' || chr(10)
        || '          or d.depot_name ilike ''%''||v_search||''%''' || chr(10)
        || '          or coalesce(d.region,'''') ilike ''%''||v_search||''%''),',
      'where d.archived_at is null and (v_search is null' || chr(10)
        || '          or d.depot_code ilike ''%''||v_search||''%''' || chr(10)
        || '          or d.depot_name ilike ''%''||v_search||''%''' || chr(10)
        || '          or coalesce(d.region,'''') ilike ''%''||v_search||''%'')),');
    baru := replace(baru,
      'where v_search is null' || chr(10)
        || '                or d.depot_code ilike ''%''||v_search||''%''' || chr(10)
        || '                or d.depot_name ilike ''%''||v_search||''%''' || chr(10)
        || '                or coalesce(d.region,'''') ilike ''%''||v_search||''%''' || chr(10)
        || '             order by d.depot_code',
      'where d.archived_at is null and (v_search is null' || chr(10)
        || '                or d.depot_code ilike ''%''||v_search||''%''' || chr(10)
        || '                or d.depot_name ilike ''%''||v_search||''%''' || chr(10)
        || '                or coalesce(d.region,'''') ilike ''%''||v_search||''%'')' || chr(10)
        || '             order by d.depot_code');
    if baru = src then raise exception 'Pola rc_depot_list tidak ditemukan.'; end if;
    execute baru; n := n + 1;
  end if;

  -- 5d. rc_private.legacy_customers ---------------------------------------------------------
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'rc_private' and p.proname = 'legacy_customers';
  if src is null then raise exception 'rc_private.legacy_customers tidak ditemukan.'; end if;
  if position('cu.archived_at is null' in src) = 0 then
    baru := replace(src,
      'where exists(select 1 from public.customer_depots cd',
      'where cu.archived_at is null and exists(select 1 from public.customer_depots cd');
    if baru = src then raise exception 'Pola rc_private.legacy_customers tidak ditemukan.'; end if;
    execute baru; n := n + 1;
  end if;

  -- 5e. rc_private.legacy_all_depots --------------------------------------------------------
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'rc_private' and p.proname = 'legacy_all_depots';
  if src is null then raise exception 'rc_private.legacy_all_depots tidak ditemukan.'; end if;
  if position('archived_at is null' in src) = 0 then
    baru := replace(src, 'from public.depots;', 'from public.depots where archived_at is null;');
    if baru = src then raise exception 'Pola rc_private.legacy_all_depots tidak ditemukan.'; end if;
    execute baru; n := n + 1;
  end if;

  -- 5f. rc_public_depots --------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'public' and p.proname = 'rc_public_depots';
  if src is null then raise exception 'public.rc_public_depots tidak ditemukan.'; end if;
  if position('archived_at is null' in src) = 0 then
    baru := replace(src, 'from public.depots;', 'from public.depots where archived_at is null;');
    if baru = src then raise exception 'Pola rc_public_depots tidak ditemukan.'; end if;
    execute baru; n := n + 1;
  end if;

  -- 5g. rc_private.compile_upload -----------------------------------------------------------
  -- Pencariannya sendiri yang menyaring, sehingga baris terarsip jatuh ke cabang "not found"
  -- yang sudah ada. Pesannya disesuaikan supaya pengunggah tahu bedanya antara belum pernah ada
  -- dan sudah dipensiunkan.
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'rc_private' and p.proname = 'compile_upload';
  -- Pada database yang dibangun dari nol fungsi ini belum ada di titik ini (lihat catatan yang
  -- sama pada 20261108). Melewatinya menjaga bagian lain migrasi ini - termasuk kolom
  -- archived_at pada depots, campaigns dan customers - tetap terpasang. Tanpa itu, satu fungsi
  -- yang belum lahir meruntuhkan belasan migrasi sesudahnya.
  if src is null then
    raise notice 'rc_private.compile_upload belum ada; tambalan dilewati (versi akhirnya dari 20261152010000).';
  elsif position('sudah diarsipkan' in src) = 0 then
    baru := src;
    baru := replace(baru,
      'select * into v_depot from public.depots where depot_code=btrim(coalesce(r->>''kodeDepot'',''''));',
      'select * into v_depot from public.depots where depot_code=btrim(coalesce(r->>''kodeDepot'','''')) and archived_at is null;');
    baru := replace(baru,
      '''" tidak ada di master depot''',
      '''" tidak ada di master depot, atau sudah diarsipkan''');
    baru := replace(baru,
      'select * into v_camp from public.campaigns where campaign_code=v_code;',
      'select * into v_camp from public.campaigns where campaign_code=v_code and archived_at is null;');
    baru := replace(baru,
      '''" belum ada di Campaign Master''',
      '''" belum ada di Campaign Master, atau sudah diarsipkan''');
    baru := replace(baru,
      'select * into v_cust from public.customers where customer_code=v_custcode;',
      'select * into v_cust from public.customers where customer_code=v_custcode and archived_at is null;');
    baru := replace(baru,
      '''" belum ada di Customer Master''',
      '''" belum ada di Customer Master, atau sudah diarsipkan''');
    if baru = src then raise exception 'Pola rc_private.compile_upload tidak ditemukan.'; end if;
    execute baru; n := n + 1;
  end if;

  raise notice 'Fungsi pembaca yang ditambal: %', n;
end
$saring$;

-- ------------------------------------------------------------------------------------------
-- 6. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare n int;
begin
  select count(*) into n from information_schema.columns
   where table_schema='public' and column_name='archived_at'
     and table_name in ('customers','campaigns','depots');
  if n <> 3 then raise exception 'GAGAL: kolom archived_at baru ada pada % dari 3 tabel.', n; end if;

  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and p.prokind='f'
     and p.proname in ('rc_master_archive','rc_master_unarchive','rc_master_archived');
  if n <> 3 then raise exception 'GAGAL: hanya % dari 3 fungsi arsip yang terpasang.', n; end if;

  -- Setiap pembaca master harus benar-benar menyaring.
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where p.prokind='f'
     and ((ns.nspname='public' and p.proname in ('rc_customer_list','rc_campaign_list','rc_depot_list','rc_public_depots'))
       or (ns.nspname='rc_private' and p.proname in ('legacy_customers','legacy_all_depots','compile_upload')))
     and pg_get_functiondef(p.oid) not like '%archived_at is null%';
  if n > 0 then
    raise exception 'GAGAL: % fungsi pembaca master masih tidak menyaring arsip.', n;
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
