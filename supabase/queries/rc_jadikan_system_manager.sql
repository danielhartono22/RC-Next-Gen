-- Menjadikan satu akun sebagai System Manager aktif.
--
-- Dipakai ketika pendaftar pertama bukan orang yang seharusnya, misalnya karena ada
-- percobaan sign up yang tertinggal, sehingga akun Anda berstatus "menunggu persetujuan"
-- dan tidak ada seorang pun yang bisa menyetujuinya.
--
-- Ini tindakan administratif sekali jalan lewat SQL Editor, bukan bagian dari alur normal.
-- Sesudah ada satu System Manager aktif, persetujuan berikutnya dilakukan lewat aplikasi di
-- menu Kelola Akses, bukan di sini.
--
-- CARA PAKAI
-- 1. Jalankan rc_lihat_akun.sql lebih dulu untuk melihat User ID yang ada.
-- 2. Ganti ISI_USER_ID_ANDA_DI_SINI di bawah dengan User ID Anda, huruf besar.
-- 3. Tempel seluruh file ini ke SQL Editor lalu Run.

do $rc_promote$
declare
  -- ====== GANTI BARIS INI ======
  target_code text := 'daniel';
  -- =============================
  target public.profiles%rowtype;
  new_suffix text;
begin
  if target_code = 'ISI_USER_ID_ANDA_DI_SINI' then
    raise exception 'Ganti dulu target_code dengan User ID Anda, lalu jalankan ulang.';
  end if;

  select * into target from public.profiles where user_code = upper(btrim(target_code));
  if not found then
    raise exception 'User ID "%" tidak ditemukan. Jalankan rc_lihat_akun.sql untuk melihat daftarnya.', target_code;
  end if;

  -- Suffix batch harus unik antar akun aktif, karena nomor batch dibentuk darinya.
  if target.suffix_num = '000' or exists(
       select 1 from public.profiles
       where suffix_num = target.suffix_num and status = 'active' and id <> target.id) then
    select lpad(n::text,3,'0') into new_suffix
    from generate_series(1,999) n
    where not exists(select 1 from public.profiles
                     where suffix_num = lpad(n::text,3,'0') and status = 'active')
      and not exists(select 1 from rc_private.batch_counters
                     where suffix = lpad(n::text,3,'0'))
    order by n limit 1;
    if new_suffix is null then raise exception 'Tidak ada suffix batch tersisa'; end if;
  else
    new_suffix := target.suffix_num;
  end if;

  update public.profiles
  set status = 'active',
      role = 'system manager',
      suffix_num = new_suffix,
      reviewed_at = now(),
      review_note = 'Dijadikan System Manager lewat SQL Editor oleh operator.'
  where id = target.id;

  -- System Manager memegang seluruh permission dan seluruh depot, sama seperti pendaftar
  -- pertama. Baris lama dibersihkan dulu supaya tidak ada sisa dari status sebelumnya.
  delete from public.user_permissions where user_id = target.id;
  insert into public.user_permissions(user_id, permission_code)
    select target.id, code from public.permissions;

  delete from public.user_depot_access where user_id = target.id;
  insert into public.user_depot_access(user_id, depot_id)
    select target.id, id from public.depots;

  insert into public.activity_logs(actor_id, event_type, entity_id, details)
  values (target.id, 'bootstrap_manager', target.id,
          jsonb_build_object('user_code', target.user_code,
                             'alasan', 'ditetapkan manual lewat SQL Editor',
                             'suffix_num', new_suffix));

  raise notice 'Selesai. % kini System Manager aktif dengan suffix %.', target.user_code, new_suffix;
end $rc_promote$;

-- Hasilnya. Akun Anda harus muncul sebagai system manager / active dengan permission dan
-- depot terisi. Sesudah ini, login ulang di portal.
select user_code as user_id, full_name as nama, role, status, suffix_num as suffix_batch,
  (select count(*) from public.user_permissions up where up.user_id = p.id) as jml_permission,
  (select count(*) from public.user_depot_access ud where ud.user_id = p.id) as jml_depot
from public.profiles p
order by (role = 'system manager') desc, user_code;
