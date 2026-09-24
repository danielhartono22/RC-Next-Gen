-- ==========================================================================================
-- Permintaan ganti PIN dan lupa PIN, dengan persetujuan
-- ==========================================================================================
-- KEADAAN SEBELUMNYA
-- Tombol "Request Ganti PIN" tidak pernah meminta persetujuan siapa pun. Adapter langsung
-- memanggil Supabase Auth updateUser dan PIN berganti saat itu juga. Untuk "lupa PIN" tidak
-- ada jalan sama sekali: seorang pengguna yang lupa PIN-nya tidak bisa masuk, dan karena
-- permintaan hanya bisa dikirim dari dalam aplikasi, ia juga tidak bisa meminta bantuan.
--
-- YANG DIMINTA PEMILIK
-- Pengguna mengajukan, lalu Supervisor wilayahnya atau System Manager menyetujui. Berlaku untuk
-- ganti PIN maupun lupa PIN.
--
-- DUA JALUR YANG BERBEDA, DAN ALASANNYA
--   ganti  Pengguna masih bisa masuk. Persetujuan hanya membuka kunci; PIN barunya ia tetapkan
--          sendiri pada layar ganti PIN. Pengelola tidak pernah tahu PIN siapa pun.
--   lupa   Pengguna tidak bisa masuk, jadi permintaannya boleh dikirim tanpa sesi, hanya dengan
--          menyebut kode pengguna. Permintaan itu tidak membocorkan apa pun: ia selalu dijawab
--          dengan pesan yang sama, ada atau tidak ada akunnya, supaya tidak bisa dipakai untuk
--          menebak kode pengguna yang valid. Karena yang bersangkutan tidak bisa masuk untuk
--          menetapkan PIN sendiri, penyetuju memberikan PIN sementara, dan pengguna wajib
--          menggantinya begitu berhasil masuk.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create table if not exists public.pin_requests(
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check(kind in('ganti','lupa')),
  reason text not null default '',
  status text not null default 'pending' check(status in('pending','approved','rejected')),
  reviewer_id uuid references public.profiles(id),
  review_note text not null default '',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index if not exists pin_requests_pending_idx
  on public.pin_requests(status, created_at desc);
-- Satu permintaan terbuka per orang. Tanpa ini, satu tombol yang diklik berkali-kali akan
-- memenuhi kotak masuk penyetuju dengan baris yang sama.
create unique index if not exists pin_requests_satu_terbuka
  on public.pin_requests(requester_id) where status='pending';

alter table public.pin_requests enable row level security;
revoke all on public.pin_requests from public,anon,authenticated;

-- ------------------------------------------------------------------------------------------
-- 1. Mengajukan
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_request_pin(p_user_code text, p_kind text, p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id uuid; v_kind text; v_sendiri uuid;
begin
  v_kind:=lower(btrim(coalesce(p_kind,'ganti')));
  if v_kind not in('ganti','lupa') then raise exception 'Jenis permintaan tidak dikenali'; end if;

  if v_kind='ganti' then
    -- Jalur ini menuntut sesi: hanya pemilik akun yang boleh meminta penggantian PIN-nya.
    v_sendiri:=(select auth.uid());
    if v_sendiri is null then
      raise exception 'Masuk lebih dulu untuk mengajukan ganti PIN' using errcode='42501'; end if;
    v_id:=v_sendiri;
  else
    select id into v_id from public.profiles
     where user_code=upper(btrim(coalesce(p_user_code,'')));
    -- Sengaja berhenti diam-diam bila akunnya tidak ada. Pesan di bawah selalu sama, sehingga
    -- layar tidak bisa dipakai untuk memeriksa kode pengguna mana yang benar-benar terdaftar.
    if v_id is null then
      return jsonb_build_object('status','success',
        'message','Bila kode pengguna itu terdaftar, permintaan Anda sudah diteruskan ke Supervisor atau System Manager.');
    end if;
  end if;

  insert into public.pin_requests(requester_id,kind,reason)
  values(v_id,v_kind,left(btrim(coalesce(p_reason,'')),300))
  on conflict(requester_id) where status='pending'
  do update set kind=excluded.kind, reason=excluded.reason, created_at=now();

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values(v_id,'pin_requested',v_id,jsonb_build_object('jenis',v_kind));

  return jsonb_build_object('status','success',
    'message',case when v_kind='ganti'
      then 'Permintaan ganti PIN dikirim. Tunggu persetujuan Supervisor atau System Manager.'
      else 'Bila kode pengguna itu terdaftar, permintaan Anda sudah diteruskan ke Supervisor atau System Manager.' end);
end $fn$;
revoke all on function public.rc_request_pin(text,text,text) from public;
-- anon sengaja diizinkan: seseorang yang lupa PIN memang tidak bisa masuk lebih dulu.
grant execute on function public.rc_request_pin(text,text,text) to anon,authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Kotak masuk penyetuju
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_pin_requests()
returns jsonb language sql stable security definer set search_path='' as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'userId',p.user_code,'namaLengkap',p.full_name,'peran',p.role,
    'jenis',r.kind,'alasan',r.reason,'status',r.status,
    'diajukan',to_char(r.created_at at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
    'kodeDepot',coalesce((select d.depot_code from public.user_depot_grants g
       join public.depots d on d.id=g.depot_id where g.user_id=p.id and g.kind='home' limit 1),''))
    order by r.created_at),'[]'::jsonb)
  from public.pin_requests r
  join public.profiles p on p.id=r.requester_id
  where r.status='pending' and rc_private.can_manage_user(p.id);
$fn$;
revoke all on function public.rc_pin_requests() from public,anon;
grant execute on function public.rc_pin_requests() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Menyetujui atau menolak
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_review_pin(
  p_id uuid, p_approve boolean, p_temp_pin text default null, p_note text default '')
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
           review_note=left(btrim(coalesce(p_note,'')),300)
     where id=p_id;
    return jsonb_build_object('status','success','message','Permintaan '||v_kode||' ditolak.');
  end if;

  if v_req.kind='lupa' then
    -- Yang bersangkutan tidak bisa masuk, jadi ia butuh PIN sementara. Panjangnya disamakan
    -- dengan aturan pendaftaran supaya tidak ada pintu belakang yang lebih longgar.
    if coalesce(length(btrim(p_temp_pin)),0) < 8 then
      raise exception 'PIN sementara minimal 8 karakter'; end if;
    update auth.users
       set encrypted_password = extensions.crypt(btrim(p_temp_pin), extensions.gen_salt('bf')),
           updated_at = now()
     where id = v_req.requester_id;
  end if;

  -- Keduanya berakhir sama: pengguna wajib menetapkan PIN sendiri begitu masuk, sehingga tidak
  -- ada PIN yang diketahui dua orang.
  update public.profiles set must_change_password=true where id=v_req.requester_id;

  update public.pin_requests
     set status='approved', reviewer_id=(select auth.uid()), reviewed_at=now(),
         review_note=left(btrim(coalesce(p_note,'')),300)
   where id=p_id;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'pin_approved',v_req.requester_id,
         jsonb_build_object('jenis',v_req.kind,'user',v_kode));

  return jsonb_build_object('status','success',
    'message',case when v_req.kind='lupa'
      then 'PIN sementara untuk '||v_kode||' sudah dipasang. Ia wajib menggantinya saat masuk.'
      else 'Permintaan '||v_kode||' disetujui. Ia dapat menetapkan PIN barunya saat masuk.' end);
end $fn$;
revoke all on function public.rc_review_pin(uuid,boolean,text,text) from public,anon;
grant execute on function public.rc_review_pin(uuid,boolean,text,text) to authenticated;

create or replace function rc_private.marker_20261004() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261004() from public,anon;
grant execute on function rc_private.marker_20261004() to authenticated;

select 'Alur permintaan PIN terpasang' as hasil,
 (select count(*) from public.pin_requests) as permintaan,
 (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname in('rc_request_pin','rc_pin_requests','rc_review_pin')) as fungsi_baru;
