-- ==========================================================================================
-- Akun Suspended setelah salah PIN berulang, dan status PIN di daftar akun
-- ==========================================================================================
-- Diminta pemilik, 5 Oktober 2026 (Access Management):
--   "Request ganti pin masuk approval request, request terblokir maka status di list akun akan
--    berubah menjadi Suspended dan user yang berwenang bisa mengubahnya kembali menjadi aktif
--    dengan id dan pass yang sama."
--
-- SEBELUMNYA blokir "salah PIN lebih dari 3x" hanya ada di halaman browser: penghitungnya
-- hilang begitu halaman dimuat ulang, dan server tidak pernah tahu. Status akun hanya
-- pending/active/inactive/rejected/deleted.
--
-- SEKARANG
--   * status 'suspended': akun yang salah PIN 3 kali BERTURUT-TURUT. Ia tidak dapat masuk dan
--     seluruh aksesnya mati (semua pemeriksaan hak mensyaratkan status 'active').
--   * profiles.gagal_login: penghitung salah PIN berturut-turut. Kembali nol saat login
--     berhasil dan saat akun diaktifkan kembali.
--   * public.rc_login_gagal(kode, pin): dipanggil layar login setelah Supabase Auth menolak.
--     PIN dicocokkan lagi dengan hash yang tersimpan; yang ternyata BENAR tidak dihitung
--     (penolakannya karena hal lain, misalnya jaringan). Hanya akun aktif yang dihitung.
--     Jawabannya sama untuk kode yang tidak terdaftar, supaya layar login tidak dapat dipakai
--     memeriksa kode mana yang ada - kecuali ketika akun benar-benar baru saja di-suspend.
--   * public.rc_login_berhasil(): dipanggil setelah Auth menerima PIN. Menolak akun suspended
--     dan mengosongkan penghitung akun aktif.
--   * Daftar akun (rc_private.legacy_users) menampilkan "Suspended" dan menandai akun yang
--     punya permintaan ganti PIN tertunda ("Req PIN"; lencananya sudah ada di layar).
--   * Dialog ubah akses (rc_update_access) mengenal pilihan "Suspended". Memilih "Active"
--     mengaktifkan kembali akun dengan User ID dan PIN yang SAMA - PIN tidak disentuh - dan
--     mengosongkan penghitungnya. Menyimpan perubahan lain tanpa mengubah statusnya membiarkan
--     akun tetap suspended.
--
-- Antrean permintaan ganti PIN sendiri sudah lengkap di server (rc_pin_requests,
-- rc_review_pin dengan hak tab Approval Request); yang ditambahkan adalah tampilannya, di
-- tab Approval Request (frontend).
--
-- Penjaga pra-citra (MD5) memastikan definisi yang ditambal sama dengan yang diukur; MD5 ini
-- sama di dev dan prod pada 5 Oktober 2026.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $pra$
declare f record; md5_kini text;
begin
  for f in select * from (values
      ('rc_private.legacy_users()',                 'ee480b63c6c98b23619cb10c483e2ff2', 'Suspended'),
      ('public.rc_update_access(jsonb)',            '079978a175a29b834c9d401e18be8c86', 'suspended')) v(sig, harapan, penanda)
  loop
    md5_kini := md5(pg_get_functiondef(to_regprocedure(f.sig)));
    if md5_kini = f.harapan then continue; end if;
    if pg_get_functiondef(to_regprocedure(f.sig)) ~ f.penanda then
      raise notice '% sudah ditambal.', f.sig; continue; end if;
    raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5_kini;
  end loop;
end
$pra$;

-- ------------------------------------------------------------------------------------------
-- 1. Status dan penghitung
-- ------------------------------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_status_check;
alter table public.profiles add constraint profiles_status_check
  check (status = any (array['pending','active','inactive','rejected','deleted','suspended']));
alter table public.profiles add column if not exists gagal_login smallint not null default 0;

-- ------------------------------------------------------------------------------------------
-- 2. Pencatat login
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_login_gagal(p_user_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_id uuid; v_status text; v_hash text; v_gagal int;
  v_batas constant int := 3;
  v_netral constant jsonb := jsonb_build_object('status', 'success', 'suspended', false);
begin
  select p.id, p.status, u.encrypted_password into v_id, v_status, v_hash
    from public.profiles p join auth.users u on u.id = p.id
   where upper(p.user_code) = upper(btrim(coalesce(p_user_code, '')));
  if v_id is null or v_status <> 'active' then return v_netral; end if;

  -- PIN yang ternyata benar tidak dihitung: penolakannya bukan karena PIN.
  if v_hash is not null and v_hash = extensions.crypt(coalesce(p_pin, ''), v_hash) then
    return v_netral; end if;

  update public.profiles
     set gagal_login = gagal_login + 1,
         status = case when gagal_login + 1 >= v_batas then 'suspended' else status end
   where id = v_id
  returning gagal_login, status into v_gagal, v_status;

  if v_status = 'suspended' then
    insert into public.activity_logs(actor_id, event_type, entity_id, details)
    values (v_id, 'akun_suspended', v_id,
            jsonb_build_object('alasan', 'salah PIN ' || v_batas || ' kali berturut-turut'));
    return jsonb_build_object('status', 'success', 'suspended', true,
      'message', 'Akun di-suspend karena salah PIN ' || v_batas || ' kali berturut-turut. '
                 || 'Hubungi Supervisor atau System Manager untuk mengaktifkan kembali; User ID dan PIN Anda tetap sama.');
  end if;
  return v_netral;
end
$fn$;
revoke all on function public.rc_login_gagal(text, text) from public;
grant execute on function public.rc_login_gagal(text, text) to anon, authenticated;

create or replace function public.rc_login_berhasil()
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_status text;
begin
  select status into v_status from public.profiles where id = (select auth.uid());
  if v_status = 'active' then
    update public.profiles set gagal_login = 0 where id = (select auth.uid()) and gagal_login <> 0;
  end if;
  return jsonb_build_object('status', 'success', 'akun', coalesce(v_status, ''),
    'message', case when v_status = 'suspended'
      then 'Akun di-suspend karena salah PIN berulang. Hubungi Supervisor atau System Manager untuk mengaktifkan kembali; User ID dan PIN Anda tetap sama.'
      else '' end);
end
$fn$;
revoke all on function public.rc_login_berhasil() from public, anon;
grant execute on function public.rc_login_berhasil() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Daftar akun
-- ------------------------------------------------------------------------------------------
do $daftar$
declare src text; baru text; n int;
begin
  src := pg_get_functiondef('rc_private.legacy_users()'::regprocedure);
  if src ~ 'Suspended' then return; end if;

  n := (length(src) - length(replace(src, 'when ''rejected'' then ''Rejected'' else ''Nonactive'' end,', ''))) / length('when ''rejected'' then ''Rejected'' else ''Nonactive'' end,');
  if n <> 1 then raise exception 'legacy_users: label status ditemukan % kali, diharapkan 1.', n; end if;
  baru := replace(src, 'when ''rejected'' then ''Rejected'' else ''Nonactive'' end,',
    'when ''rejected'' then ''Rejected'' when ''suspended'' then ''Suspended'' else ''Nonactive'' end,
   -- Permintaan ganti PIN yang menunggu keputusan; layar menampilkannya sebagai lencana "Req PIN".
   ''pinStatus'',case when exists(select 1 from public.pin_requests pr where pr.requester_id=p.id and pr.status=''pending'') then ''pending'' else '''' end,');

  n := (length(baru) - length(replace(baru, 'jsonb_build_object(''i'',case p.status when ''active'' then ''Active'' else ''Inactive'' end)', ''))) / length('jsonb_build_object(''i'',case p.status when ''active'' then ''Active'' else ''Inactive'' end)');
  if n <> 1 then raise exception 'legacy_users: status aktivasi ditemukan % kali, diharapkan 1.', n; end if;
  baru := replace(baru, 'jsonb_build_object(''i'',case p.status when ''active'' then ''Active'' else ''Inactive'' end)',
    'jsonb_build_object(''i'',case p.status when ''active'' then ''Active'' when ''suspended'' then ''Suspended'' else ''Inactive'' end)');
  execute baru;
end
$daftar$;

-- ------------------------------------------------------------------------------------------
-- 4. Ubah akses: status Suspended dikenal, aktivasi ulang mengosongkan penghitung
-- ------------------------------------------------------------------------------------------
do $akses$
declare src text; baru text; pola text; n int;
begin
  src := pg_get_functiondef('public.rc_update_access(jsonb)'::regprocedure);
  if src ~ '''suspended''' then return; end if;

  pola := 'when lower\(coalesce\(p_payload->''auth''->>''i'',''''\)\) in\(''active'',''approved'',''ok''\) then ''active'' else ''inactive'' end;';
  select count(*) into n from regexp_matches(src, pola, 'g');
  if n <> 1 then raise exception 'rc_update_access: penentuan status ditemukan % kali, diharapkan 1.', n; end if;
  baru := regexp_replace(src, pola,
    'when lower(coalesce(p_payload->''auth''->>''i'','''')) in(''active'',''approved'',''ok'') then ''active''
    when lower(coalesce(p_payload->''auth''->>''i'','''')) = ''suspended'' then ''suspended'' else ''inactive'' end;');

  pola := 'update public\.profiles set status=v_status where id=v_target;';
  select count(*) into n from regexp_matches(baru, pola, 'g');
  if n <> 1 then raise exception 'rc_update_access: penyimpanan status ditemukan % kali, diharapkan 1.', n; end if;
  baru := regexp_replace(baru, pola,
    'update public.profiles set status=v_status,
         gagal_login=case when v_status=''active'' then 0 else gagal_login end where id=v_target;');
  execute baru;
end
$akses$;

-- ------------------------------------------------------------------------------------------
-- 5. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare u record; h jsonb; i int;
begin
  -- Akun aktif mana pun: PIN salah dua kali belum suspend, ketiga kali suspend; PIN benar
  -- tidak dihitung; aktivasi ulang lewat rc_update_access mengembalikannya. Semua di dalam
  -- transaksi migrasi ini dan dikembalikan ke keadaan semula.
  select p.id, p.user_code, p.status, p.gagal_login into u
    from public.profiles p where p.status = 'active' and p.role <> 'system manager'
   order by p.user_code limit 1;
  if u.id is null then raise notice 'Tidak ada akun aktif untuk diuji.'; return; end if;

  for i in 1..2 loop
    h := public.rc_login_gagal(lower(u.user_code), 'PIN-PASTI-SALAH-' || i);
    if (h->>'suspended')::boolean then raise exception 'GAGAL: suspend terlalu cepat (percobaan %).', i; end if;
  end loop;
  h := public.rc_login_gagal(u.user_code, 'PIN-PASTI-SALAH-3');
  if not (h->>'suspended')::boolean or (select status from public.profiles where id = u.id) <> 'suspended' then
    raise exception 'GAGAL: akun tidak di-suspend setelah 3 kali salah PIN.'; end if;
  h := public.rc_login_gagal('KODE-YANG-TIDAK-ADA-XYZ', 'apa saja');
  if (h->>'suspended')::boolean then raise exception 'GAGAL: kode tak terdaftar mendapat jawaban berbeda.'; end if;

  update public.profiles set status = u.status, gagal_login = u.gagal_login where id = u.id;
  delete from public.activity_logs where entity_id = u.id and event_type = 'akun_suspended'
    and created_at >= now() - interval '1 minute';
  raise notice 'Suspended teruji pada % lalu dipulihkan.', u.user_code;
end
$periksa$;
