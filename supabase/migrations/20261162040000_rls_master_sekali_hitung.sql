-- ==========================================================================================
-- Kebijakan RLS customer dan campaign dihitung sekali per kueri, bukan sekali per baris
-- ==========================================================================================
-- Lanjutan 20261162020000 (claims, depots, claim_sensitive). Dua kebijakan lain ternyata
-- menanggung pola yang sama dan menjadi penghambat berikutnya pada 100 ribu klaim:
--
--   campaigns        rc_private.can_access(NULL::uuid)
--                    Tidak bergantung pada baris sama sekali, tetapi tetap dipanggil untuk
--                    setiap baris - dan ketika campaigns digabung ke klaim, untuk setiap klaim.
--
--   customer_depots  exists(select 1 from user_depot_access a
--                            where a.user_id = auth.uid() and a.depot_id = customer_depots.depot_id)
--                    Subkueri itu sendiri tunduk pada RLS user_depot_access, yang memeriksa
--                    profiles lagi. customers bergantung padanya (exists customer_depots), jadi
--                    setiap baris customer menjalankan tiga lapis subkueri.
--
-- Akibatnya Customer Master (menghitung 100 ribu customer) dan Document Center (menghitung
-- 100 ribu klaim yang digabung ke customer dan campaign) mendekati batas 8 detik.
--
-- KESETARAAN, diturunkan dari definisi:
--
--   customer_depots lama, bila dievaluasi sebagai pengguna u untuk depot d:
--     exists(user_depot_access a where a.user_id = u and a.depot_id = d
--            and [RLS access_self] a.user_id = u
--                and exists(profiles p where p.id = u and not p.must_change_password))
--   = d in {depot di user_depot_access milik u}, bila profil u tidak wajib ganti PIN
--   = d = any(rc_private.depot_cd_saya())
--
--   Perhatikan: syaratnya HANYA "tidak wajib ganti PIN" - tidak memeriksa status aktif.
--   Itu perilaku yang berlaku sekarang dan dipertahankan persis; fungsi baru meniru syarat
--   yang sama, bukan syarat can_access.
--
--   campaigns: (select can_access(NULL)) - ekspresi yang sama, dihitung sekali.
--
-- Kesetaraan customer_depots DIBUKTIKAN untuk setiap pengguna x setiap depot sebelum
-- kebijakan diganti, dengan predikat lama dijalankan SEBAGAI pengguna itu (sehingga RLS
-- berlapisnya ikut berlaku). customers tidak diubah: ia otomatis ikut cepat karena bergantung
-- pada customer_depots.
--
-- Tidak ada fungsi yang naik menjadi SECURITY DEFINER selain fungsi jangkauan baru, yang
-- hanya mengembalikan daftar depot milik pemanggil sendiri.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Fungsi jangkauan
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.depot_cd_saya()
returns uuid[] language sql stable security definer set search_path to '' as $fn$
  select coalesce((
    select array_agg(a.depot_id)
      from public.user_depot_access a
      join public.profiles p on p.id = a.user_id
     where a.user_id = (select auth.uid())
       and not p.must_change_password), '{}'::uuid[]);
$fn$;
revoke all on function rc_private.depot_cd_saya() from public, anon;
grant execute on function rc_private.depot_cd_saya() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Pembuktian kesetaraan SEBELUM kebijakan diganti
-- ------------------------------------------------------------------------------------------
-- Predikat lama dijalankan sebagai authenticated, sehingga RLS user_depot_access dan profiles
-- di dalamnya berlaku persis seperti ketika kebijakan lama dievaluasi.
do $setara$
declare u record; d record; lama boolean; baru boolean; n_pasangan int := 0; n_pengguna int := 0;
begin
  for u in select id, user_code, role, status, must_change_password from public.profiles order by user_code loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    for d in select id, depot_code from public.depots loop
      set local role authenticated;
      select exists(select 1 from public.user_depot_access a
                     where a.user_id = (select auth.uid()) and a.depot_id = d.id) into lama;
      select d.id = any(rc_private.depot_cd_saya()) into baru;
      reset role;
      if lama is distinct from baru then
        raise exception 'GAGAL customer_depots: % (% / % / ganti PIN %) depot % - lama %, baru %.',
          u.user_code, u.role, u.status, u.must_change_password, d.depot_code, lama, baru;
      end if;
      n_pasangan := n_pasangan + 1;
    end loop;
    n_pengguna := n_pengguna + 1;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'Kesetaraan customer_depots terbukti: % pengguna, % pasangan.', n_pengguna, n_pasangan;
exception when others then
  reset role; raise;
end
$setara$;

-- ------------------------------------------------------------------------------------------
-- 3. Penggantian kebijakan
-- ------------------------------------------------------------------------------------------
-- Nama, perintah dan peran dipertahankan persis; hanya predikatnya yang berganti bentuk.
drop policy if exists campaigns_scope on public.campaigns;
create policy campaigns_scope on public.campaigns
  for select to authenticated
  using ((select rc_private.can_access(NULL::uuid)));

drop policy if exists customer_depots_scoped on public.customer_depots;
create policy customer_depots_scoped on public.customer_depots
  for select to authenticated
  using (depot_id = any((select rc_private.depot_cd_saya())::uuid[]));

-- ------------------------------------------------------------------------------------------
-- 4. Pemeriksaan lewat jalur pengguna sungguhan
-- ------------------------------------------------------------------------------------------
-- Jumlah baris yang terlihat lewat kebijakan yang terpasang harus sama dengan jumlah yang
-- dihitung dari predikat baru secara eksplisit (sebagai pemilik), untuk setiap pengguna.
do $jalur$
declare u record; akses boolean; dp uuid[];
  r_camp bigint; r_cd bigint; r_cust bigint; h_camp bigint; h_cd bigint; h_cust bigint;
begin
  for u in select id, user_code from public.profiles order by user_code loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);

    akses := rc_private.can_access(null::uuid);
    dp := rc_private.depot_cd_saya();
    select count(*) into h_camp from public.campaigns where akses;
    select count(*) into h_cd from public.customer_depots where depot_id = any(dp);
    select count(*) into h_cust from public.customers cu
     where exists(select 1 from public.customer_depots x where x.customer_id = cu.id and x.depot_id = any(dp));

    set local role authenticated;
    select count(*) into r_camp from public.campaigns;
    select count(*) into r_cd from public.customer_depots;
    select count(*) into r_cust from public.customers;
    reset role;

    if (r_camp, r_cd, r_cust) is distinct from (h_camp, h_cd, h_cust) then
      raise exception 'GAGAL: % melihat campaign/customer_depot/customer %/%/% lewat RLS, seharusnya %/%/%.',
        u.user_code, r_camp, r_cd, r_cust, h_camp, h_cd, h_cust; end if;
    raise notice 'RLS benar: % melihat % campaign, % customer_depot, % customer',
      u.user_code, r_camp, r_cd, r_cust;
  end loop;
  perform set_config('request.jwt.claims', '', true);
exception when others then
  reset role; raise;
end
$jalur$;
