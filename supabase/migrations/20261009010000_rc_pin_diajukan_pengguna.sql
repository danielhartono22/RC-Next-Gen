-- ==========================================================================================
-- Lupa PIN: pengguna mengajukan PIN-nya sendiri, penyetuju tinggal menyetujui
-- ==========================================================================================
-- ALUR SEBELUMNYA, DAN MENGAPA DIGANTI
-- Pada 20261004010000 penyetuju yang menetapkan PIN sementara, lalu pengguna wajib
-- menggantinya saat masuk. Alur itu aman, tetapi bukan yang diminta pemilik dan memang lebih
-- berbelit: PIN sementara harus disampaikan ke orangnya lewat jalur lain, dan ada satu langkah
-- ganti PIN tambahan sesudah berhasil masuk.
--
-- Alur yang diminta: pengguna memasukkan User ID, menuliskan PIN yang ia inginkan, lalu
-- permintaannya masuk ke antrean persetujuan. Begitu disetujui, PIN itulah yang berlaku.
--
-- BAGAIMANA PIN-NYA DISIMPAN SELAMA MENUNGGU
-- Tidak dalam bentuk aslinya. PIN yang diajukan langsung di-hash dengan bcrypt saat permintaan
-- dibuat, dan yang tersimpan hanyalah hash itu. Penyetuju tidak pernah melihatnya, dan seandainya
-- isi tabel ini terbaca orang lain pun, PIN-nya tidak terbaca. Saat disetujui, hash tersebut
-- dipindahkan apa adanya ke auth.users - tanpa pernah ada satu momen pun PIN-nya berbentuk teks
-- biasa di dalam basis data.
--
-- Karena PIN-nya ditetapkan sendiri oleh pemilik akun, must_change_password TIDAK dinyalakan:
-- tidak ada yang perlu diganti lagi, dan menyalakannya justru akan mengunci akun itu dari
-- seluruh layar (lihat 20261007010000).
--
-- Aman dijalankan berulang.
-- ==========================================================================================

alter table public.pin_requests add column if not exists requested_secret text;

-- ------------------------------------------------------------------------------------------
-- Mengajukan, dengan PIN yang diinginkan
-- ------------------------------------------------------------------------------------------
drop function if exists public.rc_request_pin(text,text,text);
create or replace function public.rc_request_pin(
  p_user_code text, p_kind text, p_reason text default '', p_new_pin text default null)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id uuid; v_kind text; v_sendiri uuid; v_hash text; v_pesan_netral text;
begin
  v_kind:=lower(btrim(coalesce(p_kind,'ganti')));
  if v_kind not in('ganti','lupa') then raise exception 'Jenis permintaan tidak dikenali'; end if;

  if coalesce(length(btrim(p_new_pin)),0) < 8 then
    raise exception 'PIN yang diajukan minimal 8 karakter'; end if;

  -- Pesan untuk jalur lupa selalu sama, ada atau tidak ada akunnya, supaya layar ini tidak
  -- bisa dipakai memeriksa kode pengguna mana yang benar-benar terdaftar.
  v_pesan_netral:='Bila kode pengguna itu terdaftar, permintaan Anda sudah diteruskan ke Supervisor atau System Manager.';

  if v_kind='ganti' then
    v_sendiri:=(select auth.uid());
    if v_sendiri is null then
      raise exception 'Masuk lebih dulu untuk mengajukan ganti PIN' using errcode='42501'; end if;
    v_id:=v_sendiri;
  else
    select id into v_id from public.profiles
     where user_code=upper(btrim(coalesce(p_user_code,'')));
    if v_id is null then
      return jsonb_build_object('status','success','message',v_pesan_netral);
    end if;
  end if;

  v_hash:=extensions.crypt(btrim(p_new_pin), extensions.gen_salt('bf'));

  insert into public.pin_requests(requester_id,kind,reason,requested_secret)
  values(v_id,v_kind,left(btrim(coalesce(p_reason,'')),300),v_hash)
  on conflict(requester_id) where status='pending'
  do update set kind=excluded.kind, reason=excluded.reason,
                requested_secret=excluded.requested_secret, created_at=now();

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(v_id,'pin_requested',v_id,jsonb_build_object('jenis',v_kind));

  return jsonb_build_object('status','success',
    'message',case when v_kind='ganti'
      then 'Permintaan ganti PIN dikirim. PIN baru berlaku setelah disetujui Supervisor atau System Manager.'
      else v_pesan_netral end);
end $fn$;
revoke all on function public.rc_request_pin(text,text,text,text) from public;
-- anon sengaja diizinkan: seseorang yang lupa PIN memang tidak bisa masuk lebih dulu.
grant execute on function public.rc_request_pin(text,text,text,text) to anon,authenticated;

-- ------------------------------------------------------------------------------------------
-- Menyetujui: PIN yang diajukan dipasang apa adanya
-- ------------------------------------------------------------------------------------------
drop function if exists public.rc_review_pin(uuid,boolean,text,text);
create or replace function public.rc_review_pin(
  p_id uuid, p_approve boolean, p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_req public.pin_requests; v_kode text;
begin
  if not rc_private.is_manager() then
    raise exception 'Hanya Supervisor atau System Manager yang dapat menyetujui'
      using errcode='42501'; end if;

  select * into v_req from public.pin_requests where id=p_id and status='pending' for update;
  if not found then raise exception 'Permintaan tidak ditemukan atau sudah diproses'; end if;
  if not rc_private.can_manage_user(v_req.requester_id) then
    raise exception 'Permintaan ini di luar wilayah Anda' using errcode='42501'; end if;

  select user_code into v_kode from public.profiles where id=v_req.requester_id;

  if not coalesce(p_approve,false) then
    update public.pin_requests
       set status='rejected', reviewer_id=(select auth.uid()), reviewed_at=now(),
           review_note=left(btrim(coalesce(p_note,'')),300),
           -- Hash yang diajukan tidak perlu disimpan lagi begitu permintaannya ditolak.
           requested_secret=null
     where id=p_id;
    return jsonb_build_object('status','success','message','Permintaan '||v_kode||' ditolak.');
  end if;

  if v_req.requested_secret is null then
    raise exception 'Permintaan ini tidak memuat PIN yang diajukan; minta pengguna mengajukan ulang';
  end if;

  update auth.users
     set encrypted_password = v_req.requested_secret, updated_at = now()
   where id = v_req.requester_id;

  -- PIN ini dipilih sendiri oleh pemilik akun, jadi tidak ada yang perlu diganti lagi.
  update public.profiles set must_change_password=false where id=v_req.requester_id;

  update public.pin_requests
     set status='approved', reviewer_id=(select auth.uid()), reviewed_at=now(),
         review_note=left(btrim(coalesce(p_note,'')),300), requested_secret=null
   where id=p_id;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'pin_approved',v_req.requester_id,
         jsonb_build_object('jenis',v_req.kind,'user',v_kode));

  return jsonb_build_object('status','success',
    'message','PIN baru untuk '||v_kode||' sudah berlaku. Ia dapat langsung masuk dengan PIN itu.');
end $fn$;
revoke all on function public.rc_review_pin(uuid,boolean,text) from public,anon;
grant execute on function public.rc_review_pin(uuid,boolean,text) to authenticated;

create or replace function rc_private.marker_20261009() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261009() from public,anon;
grant execute on function rc_private.marker_20261009() to authenticated;

select 'PIN diajukan pengguna, disetujui pengelola' as hasil,
 (select count(*) from public.pin_requests where status='pending') as menunggu,
 (select count(*) from public.pin_requests where status='pending' and requested_secret is null)
   as tanpa_pin_diajukan;
