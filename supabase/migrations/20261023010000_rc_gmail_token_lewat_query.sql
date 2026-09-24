-- ==========================================================================================
-- Penyegaran token Gmail: parameter dipindahkan ke query string
-- ==========================================================================================
-- GALAT YANG DIPERBAIKI
--   Content-Type header must be "application/json"
--
-- Pesan itu TIDAK datang dari Google, melainkan dari pg_net. net.http_post menerima body
-- sebagai jsonb, dan ia menolak mengirimkannya bila header Content-Type bukan application/json.
-- Endpoint token Google sendiri menuntut form-urlencoded, sehingga permintaan sebelumnya
-- terjepit di antara dua syarat yang saling bertentangan dan tidak pernah sampai ke Google.
--
-- Jalan keluarnya: parameter tidak lagi diletakkan di badan permintaan, melainkan pada query
-- string lewat argumen params milik pg_net. Endpoint token Google menerima bentuk itu, dan
-- pg_net tidak lagi mempermasalahkan Content-Type karena badannya kosong.
--
-- Client secret dan refresh token tetap tidak pernah tercetak di mana pun. Keduanya memang
-- ikut pada query string permintaan ke Google lewat HTTPS, yang terenkripsi seutuhnya termasuk
-- bagian itu.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.gmail_token()
returns text language plpgsql security definer set search_path='' as $fn$
declare
  v_token text; v_id text; v_secret text; v_refresh text;
  v_req bigint; v_res jsonb; v_body jsonb;
begin
  select token into v_token from rc_private.oauth_cache
   where nama='gmail' and kedaluwarsa > now() + interval '2 minutes';
  if v_token is not null then return v_token; end if;

  v_id      := rc_private.rahasia('rc_gmail_client_id');
  v_secret  := rc_private.rahasia('rc_gmail_client_secret');
  v_refresh := rc_private.rahasia('rc_gmail_refresh_token');
  if coalesce(v_id,'')='' or coalesce(v_secret,'')='' or coalesce(v_refresh,'')='' then
    return null; end if;

  -- Penjagaan terhadap kesalahan yang paling sering terjadi: contoh penempelan disalin apa
  -- adanya. Nilai sependek itu tidak mungkin kredensial sungguhan, dan menolaknya di sini
  -- memberi pesan yang menyebut sebabnya - jauh lebih berguna daripada "invalid_client" dari
  -- Google beberapa langkah kemudian.
  if v_secret !~ '^GOCSPX-' and length(v_secret) < 20 then
    raise exception 'Client secret tampak bukan nilai sungguhan (% karakter). Client secret Google diawali GOCSPX- dan panjangnya sekitar 35 karakter.',
      length(v_secret); end if;
  if left(v_refresh,3) <> '1//' and length(v_refresh) < 40 then
    raise exception 'Refresh token tampak bukan nilai sungguhan (% karakter). Refresh token Google diawali 1// dan panjangnya lebih dari seratus karakter.',
      length(v_refresh); end if;

  -- Parameter dikirim sebagai query string, bukan sebagai badan permintaan. Lihat penjelasan
  -- di kepala berkas: pg_net dan Google menuntut Content-Type yang berbeda untuk badan.
  select net.http_post(
    url := 'https://oauth2.googleapis.com/token',
    body := '{}'::jsonb,
    params := jsonb_build_object(
      'client_id', v_id, 'client_secret', v_secret,
      'refresh_token', v_refresh, 'grant_type','refresh_token'),
    headers := jsonb_build_object('Content-Type','application/json'),
    timeout_milliseconds := 15000
  ) into v_req;

  perform net.http_collect_response(v_req, async := false);
  select to_jsonb(r) into v_res from net._http_response r where id = v_req;
  if v_res is null then
    raise exception 'Tidak ada jawaban dari Google dalam batas waktu'; end if;
  if coalesce((v_res->>'status_code')::int,0) not between 200 and 299 then
    raise exception 'Google menolak penyegaran token: % %',
      v_res->>'status_code', left(coalesce(v_res->>'content',''),300); end if;

  v_body := (v_res->>'content')::jsonb;
  v_token := v_body->>'access_token';
  if coalesce(v_token,'')='' then
    raise exception 'Jawaban Google tidak memuat access_token'; end if;

  insert into rc_private.oauth_cache(nama,token,kedaluwarsa)
  values('gmail', v_token,
         now() + make_interval(secs => greatest(coalesce((v_body->>'expires_in')::int,3600) - 120, 60)))
  on conflict(nama) do update set token=excluded.token, kedaluwarsa=excluded.kedaluwarsa;
  return v_token;
end $fn$;
revoke all on function rc_private.gmail_token() from public,anon,authenticated;

create or replace function rc_private.marker_20261023() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261023() from public,anon;
grant execute on function rc_private.marker_20261023() to authenticated;

select 'Penyegaran token Gmail diperbaiki' as hasil,
 (select length(decrypted_secret) from vault.decrypted_secrets where name='rc_gmail_client_secret') as panjang_client_secret,
 (select length(decrypted_secret) from vault.decrypted_secrets where name='rc_gmail_refresh_token') as panjang_refresh_token,
 'Client secret asli ~35 karakter diawali GOCSPX-; refresh token 100+ karakter diawali 1//' as acuan;
