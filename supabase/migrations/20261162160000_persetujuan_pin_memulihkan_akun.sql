-- ==========================================================================================
-- Persetujuan PIN benar-benar membuat pengguna bisa masuk lagi
-- ==========================================================================================
-- Laporan pemilik, 7 Oktober 2026: "ketika request ganti pin sudah di approve tapi tetep tidak
-- bisa masuk". Diperiksa pada data prod: belum pernah ada SATU PUN login berhasil sesudah PIN
-- disetujui. Hash PIN-nya sendiri benar - diuji di dev, Supabase Auth menerima PIN yang dipasang
-- persis seperti rc_review_pin. Yang menghalangi ada tiga, dua di server (berkas ini) dan satu di
-- layar login (frontend):
--
--   1. Menyetujui PIN tidak mengaktifkan kembali akun yang TER-SUSPEND. Kasus nyata AYI:
--      PIN disetujui 10:26, ter-suspend 10:34 (3x salah), lalu tiga persetujuan berikutnya
--      sia-sia karena login tetap ditolak "Akun di-suspend". Padahal permintaan Lupa PIN justru
--      datang dari orang yang baru saja salah PIN; persetujuan oleh yang berwenang adalah
--      verifikasi ulangnya. Kini persetujuan mengosongkan penghitung salah PIN dan mengubah
--      Suspended -> Active. Akun Inactive (dimatikan sengaja) TIDAK diaktifkan; pesannya
--      menyebut hal itu.
--
--   2. Kotak "Setujui PIN" di dialog Edit Akses hanya mewajibkan ganti PIN saat login berikut -
--      PIN yang diajukan pengguna tidak dipasang dan permintaannya tetap menggantung. Pengguna
--      yang lupa PIN lamanya tetap tidak bisa masuk. Kini kotak itu menjalankan persetujuan yang
--      sama dengan tab Approval Request: memasang PIN yang diajukan, menutup permintaannya, dan
--      memulihkan akun yang ter-suspend. Bila tidak ada permintaan berisi PIN, perilaku lama
--      (wajib ganti PIN saat login) dipertahankan.
--
-- Ditambal dengan penjaga MD5 pra-citra (akhir baris dinormalkan), sama di dev dan prod pada
-- 7 Oktober 2026. Aman dijalankan berulang.
-- ==========================================================================================

do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  ('public.rc_review_pin(uuid,boolean,text)', '8b41f5854ddb34af952cfb34a31cd56e',
   $p$declare v_req public.pin_requests; v_kode text;$p$,
   $p$declare v_req public.pin_requests; v_kode text; v_status_lama text; /* 20261162160000 */$p$, 1),
  ('public.rc_review_pin(uuid,boolean,text)', '8b41f5854ddb34af952cfb34a31cd56e',
   $p$  select user_code into v_kode from public.profiles where id=v_req.requester_id;$p$,
   $p$  select user_code, status into v_kode, v_status_lama from public.profiles where id=v_req.requester_id;$p$, 1),
  ('public.rc_review_pin(uuid,boolean,text)', '8b41f5854ddb34af952cfb34a31cd56e',
   $p$  update public.profiles set must_change_password=false where id=v_req.requester_id;$p$,
   $p$  -- Persetujuan oleh yang berwenang = verifikasi ulang: penghitung salah PIN dikosongkan dan
  -- akun yang ter-suspend karenanya aktif kembali. Akun Inactive tidak disentuh.
  update public.profiles set must_change_password=false, gagal_login=0,
         status=case when status='suspended' then 'active' else status end
   where id=v_req.requester_id;$p$, 1),
  ('public.rc_review_pin(uuid,boolean,text)', '8b41f5854ddb34af952cfb34a31cd56e',
   $p$jsonb_build_object('jenis',v_req.kind,'user',v_kode));$p$,
   $p$jsonb_build_object('jenis',v_req.kind,'user',v_kode,'statusSebelum',v_status_lama));$p$, 1),
  ('public.rc_review_pin(uuid,boolean,text)', '8b41f5854ddb34af952cfb34a31cd56e',
   $p$'message','PIN baru untuk '||v_kode||' sudah berlaku. Ia dapat langsung masuk dengan PIN itu.');$p$,
   $p$'message','PIN baru untuk '||v_kode||' sudah berlaku. '||case v_status_lama
      when 'active' then 'Ia dapat langsung masuk dengan PIN itu.'
      when 'suspended' then 'Akun yang ter-suspend diaktifkan kembali; ia dapat langsung masuk dengan PIN itu.'
      else 'Namun akun berstatus '||coalesce(v_status_lama,'-')||'; aktifkan lewat Edit Akses agar dapat masuk.' end);$p$, 1),

  ('public.rc_update_access(jsonb)', '7756722d4fa5547f1933c480bba250f7',
   $p$  v_diri boolean;$p$,
   $p$  v_diri boolean;
  v_pin public.pin_requests; /* 20261162160000 */$p$, 1),
  ('public.rc_update_access(jsonb)', '7756722d4fa5547f1933c480bba250f7',
   $p$    update public.profiles set must_change_password=true where id=v_target;$p$,
   $p$    -- Ada permintaan berisi PIN yang diajukan: persetujuannya sama persis dengan tab Approval
    -- Request - PIN itu dipasang, permintaannya ditutup, akun yang ter-suspend aktif kembali.
    select * into v_pin from public.pin_requests
     where requester_id=v_target and status='pending' and requested_secret is not null
     order by created_at desc limit 1 for update;
    if found then
      update auth.users set encrypted_password=v_pin.requested_secret, updated_at=now() where id=v_target;
      update public.profiles set must_change_password=false, gagal_login=0,
             status=case when status='suspended' then 'active' else status end
       where id=v_target;
      update public.pin_requests set status='approved', reviewer_id=(select auth.uid()), reviewed_at=now(),
             review_note='Disetujui lewat Edit Akses', requested_secret=null
       where id=v_pin.id;
      insert into public.activity_logs(actor_id,event_type,entity_id,details)
      values((select auth.uid()),'pin_approved',v_target,jsonb_build_object('jenis',v_pin.kind,'user',v_kode,'lewat','Edit Akses'));
    else
      -- Tidak ada PIN yang diajukan: pengguna wajib menetapkan PIN baru saat login berikutnya.
      update public.profiles set must_change_password=true where id=v_target;
    end if;$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261162160000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(src, E'\r', '')); end if;
    baru := src;
    for r in select * from _tambal where sig = f.sig order by urut loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> r.n then
        raise exception '%: pola "%" ditemukan % kali, diharapkan %.', f.sig, left(r.lama, 80), n, r.n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
    execute baru;
  end loop;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan di dalam subtransaksi yang dibatalkan: akun yang ter-suspend, mengajukan Lupa
-- PIN, lalu disetujui - lewat tab Approval Request dan lewat Edit Akses - menjadi Active dengan
-- PIN yang diajukannya. Tidak ada data yang tertinggal.
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; v_u record; v_req uuid; h jsonb; hasil jsonb := '{}'; e text := '';
begin
  select id into v_sm from public.profiles where role='system manager' and status='active' and not must_change_password order by user_code limit 1;
  select p.id, p.user_code, u.encrypted_password into v_u from public.profiles p join auth.users u on u.id=p.id
   where p.role <> 'system manager' and p.status='active'
     and not exists(select 1 from public.pin_requests r where r.requester_id=p.id and r.status='pending')
   order by p.user_code limit 1;
  if v_sm is null or v_u.id is null then raise notice 'Tidak ada akun untuk diuji; dilewati.'; return; end if;

  begin
    -- Jalur 1: tab Approval Request.
    update public.profiles set status='suspended', gagal_login=3 where id=v_u.id;
    perform set_config('request.jwt.claims', '', true);
    h := public.rc_request_pin(v_u.user_code, 'lupa', 'uji', 'PinUjiSatu123');
    select id into v_req from public.pin_requests where requester_id=v_u.id and status='pending';
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    h := public.rc_review_pin(v_req, true, 'uji');
    perform set_config('request.jwt.claims', '', true);
    hasil := hasil || jsonb_build_object('jalur1',
      (select jsonb_build_object('status', p.status, 'gagal', p.gagal_login,
         'pinCocok', u.encrypted_password = extensions.crypt('PinUjiSatu123', u.encrypted_password),
         'req', (select status from public.pin_requests where id=v_req), 'pesan', h->>'message')
         from public.profiles p join auth.users u on u.id=p.id where p.id=v_u.id));

    -- Jalur 2: kotak "Setujui PIN" di Edit Akses.
    update public.profiles set status='suspended', gagal_login=3 where id=v_u.id;
    h := public.rc_request_pin(v_u.user_code, 'lupa', 'uji', 'PinUjiDua4567');
    select id into v_req from public.pin_requests where requester_id=v_u.id and status='pending';
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    h := public.rc_update_access(jsonb_build_object('userId', v_u.user_code, 'approvePin', true));
    perform set_config('request.jwt.claims', '', true);
    hasil := hasil || jsonb_build_object('jalur2',
      (select jsonb_build_object('status', p.status, 'gagal', p.gagal_login, 'mcp', p.must_change_password,
         'pinCocok', u.encrypted_password = extensions.crypt('PinUjiDua4567', u.encrypted_password),
         'req', (select status from public.pin_requests where id=v_req))
         from public.profiles p join auth.users u on u.id=p.id where p.id=v_u.id));
    raise exception 'UJI_SELESAI';
  exception when raise_exception then if sqlerrm <> 'UJI_SELESAI' then raise; end if; end;
  perform set_config('request.jwt.claims', '', true);

  if hasil->'jalur1'->>'status' <> 'active' or (hasil->'jalur1'->>'gagal')::int <> 0 or not (hasil->'jalur1'->>'pinCocok')::boolean
     or hasil->'jalur1'->>'req' <> 'approved' or hasil->'jalur1'->>'pesan' !~ 'diaktifkan kembali' then e := e || ' jalur Approval Request;'; end if;
  if hasil->'jalur2'->>'status' <> 'active' or (hasil->'jalur2'->>'gagal')::int <> 0 or (hasil->'jalur2'->>'mcp')::boolean
     or not (hasil->'jalur2'->>'pinCocok')::boolean or hasil->'jalur2'->>'req' <> 'approved' then e := e || ' jalur Edit Akses;'; end if;
  if e <> '' then raise exception 'GAGAL:% Hasil: %', e, hasil; end if;
  if (select encrypted_password from auth.users where id=v_u.id) is distinct from v_u.encrypted_password
     or (select status from public.profiles where id=v_u.id) <> 'active' then
    raise exception 'GAGAL: uji meninggalkan perubahan pada akun %.', v_u.user_code; end if;
  raise notice 'Persetujuan PIN teruji pada %: %', v_u.user_code, hasil;
end
$uji$;
