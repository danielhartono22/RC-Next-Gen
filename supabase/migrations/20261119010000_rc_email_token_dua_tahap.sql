-- ==========================================================================================
-- Penyegaran token Gmail dipecah dua tahap - sebab email tidak pernah benar-benar terkirim
-- ==========================================================================================
-- Ditemukan 20 September 2026, tepat setelah keempat kredensial Gmail akhirnya berisi nilai
-- sungguhan. Sampai saat itu, cacat di bawah ini tidak pernah terlihat: rc_private.gmail_token()
-- selalu berhenti lebih dulu pada pemeriksaan panjang client secret, jauh sebelum menyentuh
-- jaringan.
--
-- ------------------------------------------------------------------------------------------
-- CACATNYA
-- ------------------------------------------------------------------------------------------
-- gmail_token() mengirim permintaan dan MENUNGGUNYA di dalam transaksi yang sama:
--
--   select net.http_post(...) into v_req;
--   perform net.http_collect_response(v_req, async := false);
--
-- pg_net bekerja lewat background worker, dan worker itu adalah proses terpisah yang hanya
-- melihat baris yang sudah TER-COMMIT. Selama transaksi pemanggil belum selesai, baris
-- permintaannya tidak terlihat olehnya - sehingga permintaan itu tidak pernah berangkat,
-- sementara pemanggilnya menunggu jawaban yang tidak akan pernah ada.
--
-- Penantian itu berakhir hanya ketika statement timeout memukulnya. Gejalanya berbeda-beda
-- menurut siapa yang memanggil, dan tak satu pun menyebut sebab sesungguhnya:
--
--   peran authenticated (tombol di layar)  batas  8 detik
--   pekerjaan pg_cron                      ikut terpotong, tercatat "canceling statement"
--   Management API                         batas  2 menit
--
-- ------------------------------------------------------------------------------------------
-- BUKTINYA
-- ------------------------------------------------------------------------------------------
-- Permintaan yang sama dipecah menjadi dua transaksi - kirim dulu, ambil jawabannya kemudian -
-- selesai dalam empat detik:
--
--   status=200  punya access_token=YA
--   {"access_token": "ya29.a0AdMD6Eg...", "expires_in": 3599, ...}
--
-- Jadi kredensialnya benar. Yang salah semata cara menunggunya.
--
-- ------------------------------------------------------------------------------------------
-- PERBAIKANNYA
-- ------------------------------------------------------------------------------------------
-- Penyegaran token dipecah menjadi dua fungsi yang dipanggil dari dua transaksi berbeda:
--
--   rc_private.gmail_token_minta()      mengirim permintaan, mengembalikan request_id
--   rc_private.gmail_token_ambil(req)   memungut jawabannya dan menyimpannya ke cache
--
-- Yang menjahitnya adalah PROSEDUR public.rc_email_proses() - prosedur, bukan fungsi, karena
-- hanya prosedur yang boleh melakukan COMMIT di tengah jalan. COMMIT itulah yang membuat
-- permintaannya terlihat oleh worker pg_net.
--
-- gmail_token() sendiri kini HANYA membaca cache dan tidak pernah menyentuh jaringan. Dengan
-- begitu ia tidak mungkin lagi menggantung di jalur mana pun yang berbatas waktu pendek -
-- termasuk tombol di layar, yang hanya punya delapan detik.
--
-- Pengiriman emailnya sendiri tidak perlu diubah: ia menembak lewat net.http_post dan TIDAK
-- menunggu jawaban, jadi ia tidak pernah terkena persoalan ini.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Tahap satu: mengirim permintaan penyegaran
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.gmail_token_minta()
returns bigint language plpgsql security definer set search_path='' as $fn$
declare v_id text; v_secret text; v_refresh text; v_req bigint; v_ada text;
begin
  -- Token yang masih berlaku tidak perlu disegarkan.
  select token into v_ada from rc_private.oauth_cache
   where nama='gmail' and kedaluwarsa > now() + interval '2 minutes';
  if v_ada is not null then return null; end if;

  v_id      := rc_private.rahasia('rc_gmail_client_id');
  v_secret  := rc_private.rahasia('rc_gmail_client_secret');
  v_refresh := rc_private.rahasia('rc_gmail_refresh_token');
  if coalesce(v_id,'')='' or coalesce(v_secret,'')='' or coalesce(v_refresh,'')='' then
    return null; end if;

  -- Penjagaan yang sama seperti sebelumnya: contoh penempelan yang disalin apa adanya ditolak
  -- di sini, dengan pesan yang menyebut sebabnya.
  if v_secret !~ '^GOCSPX-' and length(v_secret) < 20 then
    raise exception 'Client secret tampak bukan nilai sungguhan (% karakter). Client secret Google diawali GOCSPX- dan panjangnya sekitar 35 karakter.',
      length(v_secret); end if;
  if left(v_refresh,3) <> '1//' and length(v_refresh) < 40 then
    raise exception 'Refresh token tampak bukan nilai sungguhan (% karakter). Refresh token Google diawali 1// dan panjangnya lebih dari seratus karakter.',
      length(v_refresh); end if;

  select net.http_post(
    url := 'https://oauth2.googleapis.com/token',
    body := '{}'::jsonb,
    params := jsonb_build_object(
      'client_id', v_id, 'client_secret', v_secret,
      'refresh_token', v_refresh, 'grant_type','refresh_token'),
    headers := jsonb_build_object('Content-Type','application/json'),
    timeout_milliseconds := 15000
  ) into v_req;
  return v_req;
end $fn$;
revoke all on function rc_private.gmail_token_minta() from public,anon;

-- ------------------------------------------------------------------------------------------
-- 2. Tahap dua: memungut jawabannya
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.gmail_token_ambil(p_req bigint)
returns text language plpgsql security definer set search_path='' as $fn$
declare v_res jsonb; v_body jsonb; v_token text;
begin
  if p_req is null then return null; end if;

  -- async := true. Jawabannya sudah dipungut worker sebelum ini dipanggil; menunggunya lagi
  -- secara sinkron justru mengembalikan penantian yang baru saja dihapuskan.
  perform net.http_collect_response(p_req, async := true);
  select to_jsonb(r) into v_res from net._http_response r where id = p_req;
  if v_res is null then return null; end if;

  if coalesce((v_res->>'status_code')::int,0) not between 200 and 299 then
    raise exception 'Google menolak penyegaran token: % %',
      coalesce(v_res->>'status_code','-'), left(coalesce(v_res->>'content',''),300); end if;

  v_body  := (v_res->>'content')::jsonb;
  v_token := v_body->>'access_token';
  if coalesce(v_token,'')='' then
    raise exception 'Jawaban Google tidak memuat access_token'; end if;

  insert into rc_private.oauth_cache(nama,token,kedaluwarsa)
  values('gmail', v_token,
         now() + make_interval(secs => greatest(coalesce((v_body->>'expires_in')::int,3600) - 120, 60)))
  on conflict(nama) do update set token=excluded.token, kedaluwarsa=excluded.kedaluwarsa;

  return v_token;
end $fn$;
revoke all on function rc_private.gmail_token_ambil(bigint) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 3. gmail_token() kini hanya membaca cache
-- ------------------------------------------------------------------------------------------
-- Tidak pernah lagi menyentuh jaringan, sehingga tidak mungkin menggantung. Bila cache-nya
-- kosong ia mengembalikan NULL, dan pemanggilnya memperlakukan itu sebagai "tertunda" -
-- bukan kegagalan - persis seperti ketika kredensialnya belum diisi.
create or replace function rc_private.gmail_token()
returns text language sql stable security definer set search_path='' as $fn$
  select token from rc_private.oauth_cache
   where nama='gmail' and kedaluwarsa > now() + interval '2 minutes';
$fn$;
revoke all on function rc_private.gmail_token() from public,anon;

-- ------------------------------------------------------------------------------------------
-- 4. Prosedur yang menjahit keduanya
-- ------------------------------------------------------------------------------------------
-- PROSEDUR, bukan fungsi: hanya prosedur yang boleh COMMIT di tengah jalan, dan COMMIT itulah
-- yang membuat permintaan pg_net terlihat oleh workernya.
create or replace procedure public.rc_email_proses(p_maks integer default 20)
language plpgsql security definer set search_path='' as $pr$
declare v_req bigint; v_token text;
begin
  -- Tahap 1: minta token bila cache-nya sudah tidak berlaku.
  v_req := rc_private.gmail_token_minta();
  if v_req is not null then
    commit;                                   -- permintaan menjadi terlihat oleh worker pg_net
    perform pg_sleep(3);                      -- beri worker waktu menyelesaikan panggilannya
    v_token := rc_private.gmail_token_ambil(v_req);
    commit;
  end if;

  -- Tahap 2: jalankan antrean seperti biasa. kirim_satu_email kini memperoleh token dari cache
  -- tanpa menyentuh jaringan, dan pengirimannya sendiri memang tidak menunggu jawaban.
  perform public.rc_email_jalankan_antrean(coalesce(p_maks,20));
  commit;
end $pr$;
revoke all on procedure public.rc_email_proses(integer) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 5. Penjadwalan
-- ------------------------------------------------------------------------------------------
-- Antrean diproses tiap menit supaya tombol Kirim Manual dan Test Email terasa seketika:
-- tombolnya mengantre, prosedur ini yang mengirimkannya beberapa detik kemudian.
-- rc_email_tick tetap per jam untuk MENYUSUN email terjadwal.
do $jadwal$
begin
  perform cron.unschedule('rc_email_antrean');
exception when others then null;
end
$jadwal$;

select cron.schedule('rc_email_antrean', '* * * * *', $$ call public.rc_email_proses(20); $$);

-- ------------------------------------------------------------------------------------------
-- 6. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='rc_private' and p.proname='gmail_token';
  if src like '%http_post%' or src like '%collect_response%' then
    raise exception 'GAGAL: gmail_token masih menyentuh jaringan.';
  end if;

  if not exists(select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname='rc_private' and p.proname in ('gmail_token_minta','gmail_token_ambil')
                 having count(*) = 2) then
    raise exception 'GAGAL: fungsi dua tahap belum lengkap.';
  end if;

  if not exists(select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname='public' and p.proname='rc_email_proses' and p.prokind='p') then
    raise exception 'GAGAL: rc_email_proses bukan prosedur atau tidak ada.';
  end if;

  if not exists(select 1 from cron.job where jobname='rc_email_antrean' and active) then
    raise exception 'GAGAL: penjadwalan antrean tidak aktif.';
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
