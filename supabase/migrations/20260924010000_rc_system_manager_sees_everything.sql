-- PENDING: belum diterapkan. Aman dijalankan berulang.
--
-- System Manager melihat seluruh depot dan seluruh modul berdasarkan PERANNYA, bukan
-- berdasarkan baris pemberian akses.
--
-- Kelemahan rancangan sebelumnya, ditunjukkan pemilik: rc_private.can_access sama sekali
-- tidak mengenal peran. Ia hanya memeriksa apakah ada baris di user_depot_access dan
-- user_permissions. Seorang System Manager "melihat semua" hanya karena kebetulan diberi
-- satu baris untuk setiap depot.
--
-- Akibatnya rapuh dan senyap. Begitu satu depot baru ditambahkan, atau baris pemberian itu
-- hilang, terhapus, atau tidak pernah dibuat, System Manager mendadak tidak melihat apa pun
-- sementara aturan bisnisnya tetap berbunyi "System Manager melihat semua". Layar kosong,
-- tanpa error, dan penyebabnya jauh dari gejalanya. Itulah kelas bug yang sedang diselidiki.
--
-- Perbaikannya membuat aturan bisnis itu menjadi aturan yang sesungguhnya: peran diperiksa
-- langsung. Syarat lain tetap berlaku penuh, yaitu akun harus aktif dan sudah mengganti PIN
-- awal, sehingga ini bukan pintu belakang melainkan pemindahan kebenaran ke satu tempat.

create or replace function rc_private.can_access(p_depot uuid, p_permission text default null)
returns boolean language sql stable security definer set search_path='' as $$
select exists(
  select 1 from public.profiles p
  where p.id=(select auth.uid())
    and p.status='active'
    and not p.must_change_password
    and (
      -- System Manager tidak dibatasi depot maupun modul. Ini aturan bisnis yang sudah
      -- berlaku sejak sistem lama, kini ditegakkan di satu tempat, bukan disimulasikan
      -- dengan menyalin baris akses yang bisa tertinggal.
      p.role='system manager'
      or (
        (p_depot is null
         or exists(select 1 from public.user_depot_access a
                   where a.user_id=p.id and a.depot_id=p_depot))
        and (p_permission is null
         or exists(select 1 from public.user_permissions x
                   where x.user_id=p.id and x.permission_code=p_permission))
      )
    )
);
$$;

-- Baris pemberian akses tetap diisi supaya konsol Otorisasi menampilkan keadaan yang jujur
-- kepada System Manager lain, dan supaya laporan akses tidak terlihat kosong. Sekarang ia
-- menjadi cerminan, bukan sumber kebenaran.
insert into public.user_permissions(user_id,permission_code)
select p.id,c.code from public.profiles p cross join public.permissions c
where p.role='system manager' and p.status='active'
on conflict do nothing;

insert into public.user_depot_access(user_id,depot_id)
select p.id,d.id from public.profiles p cross join public.depots d
where p.role='system manager' and p.status='active'
on conflict do nothing;

create or replace function rc_private.marker_20260924() returns boolean
language sql immutable set search_path='' as $$select true$$;
revoke all on function rc_private.marker_20260924() from public,anon;
grant execute on function rc_private.marker_20260924() to authenticated;
