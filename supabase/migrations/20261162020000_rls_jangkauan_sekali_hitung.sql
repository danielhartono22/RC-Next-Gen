-- ==========================================================================================
-- Kebijakan RLS menghitung jangkauan sekali per kueri, bukan sekali per baris
-- ==========================================================================================
-- Ditemukan di dev pada 100 ribu klaim: kueri yang sama memilih 1000 baris antrean dalam
-- 2,8 ms bila dijalankan pemilik database, tetapi 850 ms bila dijalankan pengguna yang login.
-- Menghitung 30 ribu baris antrean: 3,7 detik. Akibatnya Release, Claim Process, Management
-- of Approval dan History menembus batas 8 detik dan gagal.
--
-- SEBABNYA bukan kueri di fungsi mana pun, melainkan KEBIJAKAN RLS di bawahnya:
--
--   claims           (archived_at is null) and rc_private.can_view(depot_id)
--   depots           rc_private.can_view(id)
--   claim_sensitive  exists(claims c where ... and rc_private.can_access(c.depot_id))
--
-- can_view dan can_access dipanggil SEKALI PER BARIS, dan masing-masing menjalankan subkueri
-- ke profiles dan user_depot_access. Seluruh fungsi yang membaca tabel itu sebagai pemanggilnya
-- - hampir semua RPC laporan dan antrean - menanggung biaya itu untuk setiap baris.
--
-- PERBAIKANNYA menulis ulang ketiga kebijakan dengan bentuk yang SETARA, tetapi fungsi
-- jangkauannya dibungkus "(select ...)". PostgreSQL mengevaluasi subkueri tanpa korelasi seperti
-- itu SEKALI sebagai InitPlan, lalu memakai hasilnya untuk setiap baris - pola yang dianjurkan
-- Supabase untuk kebijakan RLS.
--
-- KESETARAANNYA diturunkan dari definisi, bukan diandaikan:
--
--   can_view(d)   = is_manager() or can_access(d)
--   can_access(d) = aktif and not wajib-ganti-PIN and (system manager or d in user_depot_access)
--   is_manager()  = aktif and not wajib-ganti-PIN and peran in (system manager, supervisor)
--
--   karena system manager sudah tercakup is_manager():
--   can_view(d)   = is_manager() or (aktif and not wajib-ganti-PIN and d in user_depot_access)
--
-- dan DIBUKTIKAN di bawah untuk setiap pengguna di database - termasuk yang nonaktif - sebelum
-- kebijakan lama diganti. Bila satu pengguna saja melihat baris yang berbeda, migrasi berhenti.
--
-- Satu pembedaan yang disengaja DIPERTAHANKAN: Supervisor melihat klaim SEMUA depot (can_view),
-- tetapi data sensitif - KTP, NPWP, rekening - hanya untuk depot binaannya (can_access).
--
-- Tidak ada fungsi yang naik menjadi SECURITY DEFINER. Semua pemanggil tetap dibatasi RLS
-- persis seperti sebelumnya; yang berubah hanya berapa kali batas itu dihitung.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Fungsi jangkauan yang dihitung sekali
-- ------------------------------------------------------------------------------------------
-- Depot yang tercatat di user_depot_access milik pemanggil - hanya bila akunnya aktif dan
-- tidak wajib mengganti PIN, persis syarat can_access. Selain itu larik kosong.
create or replace function rc_private.depot_akses_saya()
returns uuid[] language sql stable security definer set search_path to '' as $fn$
  select coalesce((
    select array_agg(a.depot_id)
      from public.user_depot_access a
      join public.profiles p on p.id = a.user_id
     where a.user_id = (select auth.uid())
       and p.status = 'active' and not p.must_change_password), '{}'::uuid[]);
$fn$;

-- System Manager yang aktif. Dipisah dari is_manager() karena data sensitif memakai can_access,
-- yang memberi keluasan hanya kepada System Manager - bukan kepada Supervisor.
create or replace function rc_private.saya_sm()
returns boolean language sql stable security definer set search_path to '' as $fn$
  select exists(select 1 from public.profiles p
                 where p.id = (select auth.uid()) and p.status = 'active'
                   and not p.must_change_password and p.role = 'system manager');
$fn$;

revoke all on function rc_private.depot_akses_saya() from public, anon;
revoke all on function rc_private.saya_sm() from public, anon;
grant execute on function rc_private.depot_akses_saya() to authenticated;
grant execute on function rc_private.saya_sm() to authenticated;
grant execute on function rc_private.is_manager() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Pembuktian kesetaraan SEBELUM kebijakan diganti
-- ------------------------------------------------------------------------------------------
-- Kedua predikat - lama maupun baru - hanya bergantung pada dua masukan: SIAPA penggunanya
-- dan DEPOT MANA. Karena itu kesetaraan dibuktikan untuk setiap pasangan pengguna x depot.
--
-- Itu pembuktian yang MENYELURUH atas seluruh ruang masukannya, dan lebih kuat daripada
-- membandingkan jumlah baris: jumlah baris hanya menguji depot yang kebetulan punya klaim,
-- sedangkan ini menguji setiap depot yang ada. Sekaligus instan - menghitung ulang predikat
-- lama atas 100 ribu baris untuk setiap pengguna melewati batas gerbang Management API.
--
-- Dijalankan sebagai pemilik, jadi yang dibandingkan adalah predikatnya saja, lepas dari RLS.
do $setara$
declare
  u record; d record;
  n_pasangan int := 0; n_pengguna int := 0;
begin
  for u in select id, user_code, role, status from public.profiles order by user_code loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);

    for d in select id, depot_code from public.depots loop
      -- claims dan depots: can_view(d)
      if rc_private.can_view(d.id)
         is distinct from (rc_private.is_manager() or d.id = any(rc_private.depot_akses_saya())) then
        raise exception 'GAGAL can_view: % (% / %) depot % - lama %, baru %.',
          u.user_code, u.role, u.status, d.depot_code, rc_private.can_view(d.id),
          (rc_private.is_manager() or d.id = any(rc_private.depot_akses_saya())); end if;

      -- claim_sensitive: can_access(d)
      if rc_private.can_access(d.id)
         is distinct from (rc_private.saya_sm() or d.id = any(rc_private.depot_akses_saya())) then
        raise exception 'GAGAL can_access: % (% / %) depot % - lama %, baru %.',
          u.user_code, u.role, u.status, d.depot_code, rc_private.can_access(d.id),
          (rc_private.saya_sm() or d.id = any(rc_private.depot_akses_saya())); end if;

      n_pasangan := n_pasangan + 1;
    end loop;
    n_pengguna := n_pengguna + 1;
  end loop;

  perform set_config('request.jwt.claims', '', true);
  raise notice 'Kesetaraan terbukti menyeluruh: % pengguna, % pasangan pengguna x depot.',
    n_pengguna, n_pasangan;
end
$setara$;

-- ------------------------------------------------------------------------------------------
-- 2b. Potret jalur pengguna lewat kebijakan LAMA
-- ------------------------------------------------------------------------------------------
-- Ditambahkan 6 Oktober 2026 setelah pemeriksaan bagian 4 menolak berjalan di prod: prod punya
-- klaim terarsip, dev tidak. Kebijakan claim_sensitive membaca public.claims, dan RLS claims
-- ikut berlaku di DALAM kebijakan itu - jadi data sensitif klaim terarsip tidak terlihat, baik
-- oleh kebijakan lama maupun baru. Bagian 4 kini dibandingkan juga dengan potret ini, yaitu
-- apa yang benar-benar dilihat setiap pengguna SEBELUM kebijakannya diganti.
--
-- Kebijakan lama itulah yang lambat, jadi potretnya diambil sekali per PROFIL JANGKAUAN, bukan
-- per pengguna: kedua kebijakan hanya bergantung pada is_manager(), system manager atau bukan,
-- dan depot di user_depot_access - pengguna dengan ketiganya sama pasti melihat baris yang sama.
-- Di prod, 71 pengguna hanya membentuk 6 profil.
create temp table _rls_lama(profil text primary key, klaim bigint, sensitif bigint, depot bigint) on commit drop;
create or replace function pg_temp.profil_jangkauan(p_id uuid) returns text language sql stable as $f$
  select (p.status = 'active' and not p.must_change_password and p.role in ('system manager','supervisor'))::text || '|' ||
       (p.status = 'active' and not p.must_change_password and p.role = 'system manager')::text || '|' ||
       case when p.status = 'active' and not p.must_change_password
            then coalesce((select string_agg(a.depot_id::text, ',' order by a.depot_id)
                             from public.user_depot_access a where a.user_id = p.id), '') else '' end
    from public.profiles p where p.id = p_id;
$f$;
do $potret$
declare u record; k bigint; s bigint; d bigint;
begin
  for u in select distinct on (pg_temp.profil_jangkauan(id)) id, pg_temp.profil_jangkauan(id) profil
             from public.profiles order by pg_temp.profil_jangkauan(id), user_code loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select count(*) into k from public.claims;
    select count(*) into s from rc_private.claim_sensitive;
    select count(*) into d from public.depots;
    reset role;
    insert into _rls_lama values (u.profil, k, s, d);
  end loop;
  perform set_config('request.jwt.claims', '', true);
exception when others then
  reset role; raise;
end
$potret$;

-- ------------------------------------------------------------------------------------------
-- 3. Penggantian kebijakan
-- ------------------------------------------------------------------------------------------
-- Nama, perintah dan peran dipertahankan persis; hanya predikatnya yang berganti bentuk.
drop policy if exists claims_scope on public.claims;
create policy claims_scope on public.claims
  for select to authenticated
  using (archived_at is null
         and ((select rc_private.is_manager())
              or depot_id = any((select rc_private.depot_akses_saya())::uuid[])));

drop policy if exists depots_scoped on public.depots;
create policy depots_scoped on public.depots
  for select to authenticated
  using ((select rc_private.is_manager())
         or id = any((select rc_private.depot_akses_saya())::uuid[]));

drop policy if exists claim_sensitive_scoped on rc_private.claim_sensitive;
create policy claim_sensitive_scoped on rc_private.claim_sensitive
  for select to authenticated
  using (exists(select 1 from public.claims c
                 where c.id = claim_sensitive.claim_id
                   and ((select rc_private.saya_sm())
                        or c.depot_id = any((select rc_private.depot_akses_saya())::uuid[]))));

-- ------------------------------------------------------------------------------------------
-- 4. Pemeriksaan lewat jalur pengguna sungguhan
-- ------------------------------------------------------------------------------------------
-- Sekarang dijalankan SEBAGAI authenticated, sehingga RLS yang baru benar-benar berlaku.
-- Yang dibandingkan: jumlah baris yang terlihat lewat kebijakan baru harus sama dengan jumlah
-- yang dihitung dari predikat lama untuk pengguna yang sama. Ini membuktikan kebijakannya
-- terpasang dan dipakai - bukan hanya bahwa predikatnya setara di atas kertas.
do $jalur$
declare u record; lewat_rls bigint; harapan bigint; sens_rls bigint; sens_harapan bigint; depot_rls bigint; lama record;
begin
  for u in select id, user_code, role, status from public.profiles order by user_code loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);

    -- Predikat BARU yang eksplisit. Kesetaraannya dengan predikat lama sudah dibuktikan
    -- menyeluruh di bagian 2; di sini yang dibuktikan adalah bahwa kebijakan yang terpasang
    -- memang menerapkan predikat itu.
    select count(*) into harapan from public.claims
     where archived_at is null
       and (rc_private.is_manager() or depot_id = any(rc_private.depot_akses_saya()));
    -- RLS claims ikut berlaku di dalam kebijakan claim_sensitive (lihat bagian 2b), maka
    -- klaimnya harus juga terlihat lewat claims_scope: tidak terarsip dan dalam jangkauan.
    select count(*) into sens_harapan from rc_private.claim_sensitive s
     where exists(select 1 from public.claims c
                   where c.id = s.claim_id
                     and c.archived_at is null
                     and (rc_private.is_manager() or c.depot_id = any(rc_private.depot_akses_saya()))
                     and (rc_private.saya_sm() or c.depot_id = any(rc_private.depot_akses_saya())));

    set local role authenticated;
    select count(*) into lewat_rls from public.claims;
    select count(*) into sens_rls from rc_private.claim_sensitive;
    select count(*) into depot_rls from public.depots;
    reset role;
    select * into lama from _rls_lama where profil = pg_temp.profil_jangkauan(u.id);

    if lewat_rls <> harapan then
      raise exception 'GAGAL: % melihat % klaim lewat RLS, seharusnya %.',
        u.user_code, lewat_rls, harapan; end if;
    if sens_rls <> sens_harapan then
      raise exception 'GAGAL: % melihat % data sensitif lewat RLS, seharusnya %.',
        u.user_code, sens_rls, sens_harapan; end if;
    -- Dan yang terpenting: persis sama dengan yang ia lihat lewat kebijakan LAMA.
    if (lewat_rls, sens_rls, depot_rls) is distinct from (lama.klaim, lama.sensitif, lama.depot) then
      raise exception 'GAGAL: % melihat klaim/sensitif/depot %/%/% lewat kebijakan baru, %/%/% lewat yang lama.',
        u.user_code, lewat_rls, sens_rls, depot_rls, lama.klaim, lama.sensitif, lama.depot; end if;
    raise notice 'RLS benar: % melihat % klaim dan % data sensitif', u.user_code, lewat_rls, sens_rls;
  end loop;
  perform set_config('request.jwt.claims', '', true);
exception when others then
  reset role; raise;
end
$jalur$;
