-- ==========================================================================================
-- Mengirim email lewat Gmail API
-- ==========================================================================================
-- MENGAPA GMAIL API, BUKAN SMTP GMAIL
-- pg_net hanya bisa HTTP. PostgreSQL tidak dapat bicara SMTP sama sekali, sehingga
-- smtp.gmail.com beserta App Password tidak dapat dipakai dari sini. Gmail API berbasis HTTPS,
-- jadi dapat dipanggil langsung. Konsekuensinya autentikasinya harus OAuth2 - App Password
-- memang tidak berlaku untuk Gmail API, hanya untuk SMTP.
--
-- MENGAPA REFRESH TOKEN, BUKAN SERVICE ACCOUNT
-- Service account dengan domain-wide delegation sebenarnya lebih rapi untuk Workspace, tetapi
-- ia menuntut JWT bertanda tangan RS256. pgcrypto tidak dapat menandatangani RS256, sehingga
-- jalur itu tertutup selama pengiriman dilakukan dari dalam database. Yang dipakai adalah alur
-- refresh token: sekali memberi izin di browser, sesudah itu database dapat memperbarui access
-- token sendiri selamanya.
--
-- YANG PERLU DISIAPKAN SEKALI - lihat docs/rc-email-gmail.md untuk langkah rincinya:
--   select vault.create_secret('<client_id>',     'rc_gmail_client_id');
--   select vault.create_secret('<client_secret>', 'rc_gmail_client_secret');
--   select vault.create_secret('<refresh_token>', 'rc_gmail_refresh_token');
--   select vault.create_secret('Nama <akun@domain.com>', 'rc_email_from');
--
-- BATAS YANG PERLU DIINGAT
-- Gmail membatasi jumlah penerima per hari: sekitar 2.000 untuk Google Workspace dan 500 untuk
-- akun Gmail biasa. Email Daily yang menyasar banyak depot dapat menyentuh batas itu, dan
-- ketika tersentuh Gmail menolak dengan galat yang tersimpan apa adanya di outbox - tidak
-- hilang diam-diam. Alamat pengirim juga harus akun yang memberi izin, atau alias "Send mail
-- as" yang sudah diverifikasi pada akun itu.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Access token disimpan sampai kedaluwarsa
-- ------------------------------------------------------------------------------------------
-- Access token Google hanya berlaku sekitar satu jam. Menukarnya setiap kali mengirim satu
-- email berarti dua permintaan jaringan untuk satu email, dan mempercepat tersentuhnya batas
-- laju. Karena itu token disimpan sampai hampir kedaluwarsa.
create table if not exists rc_private.oauth_cache(
  nama text primary key,
  token text not null,
  kedaluwarsa timestamptz not null
);
revoke all on rc_private.oauth_cache from public,anon,authenticated;

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
    return null;   -- belum dikonfigurasi; pemanggil yang memutuskan apa artinya
  end if;

  -- Endpoint token Google menerima form-encoded, bukan JSON.
  select net.http_post(
    url := 'https://oauth2.googleapis.com/token',
    headers := jsonb_build_object('Content-Type','application/x-www-form-urlencoded'),
    body := jsonb_build_object(
      'client_id', v_id, 'client_secret', v_secret,
      'refresh_token', v_refresh, 'grant_type','refresh_token'),
    timeout_milliseconds := 15000
  ) into v_req;

  -- Menunggu jawabannya. Penukaran token harus sinkron: tanpa token, tidak ada yang bisa
  -- dikirim, jadi tidak ada gunanya melanjutkan lebih dulu.
  perform net.http_collect_response(v_req, async := false);
  select to_jsonb(r) into v_res from net._http_response r where id = v_req;
  if v_res is null then return null; end if;
  if coalesce((v_res->>'status_code')::int,0) not between 200 and 299 then
    raise exception 'Gmail menolak penyegaran token: % %',
      v_res->>'status_code', left(coalesce(v_res->>'content',''),200); end if;

  v_body := (v_res->>'content')::jsonb;
  v_token := v_body->>'access_token';
  if coalesce(v_token,'')='' then return null; end if;

  insert into rc_private.oauth_cache(nama,token,kedaluwarsa)
  values('gmail', v_token,
         now() + make_interval(secs => greatest(coalesce((v_body->>'expires_in')::int,3600) - 120, 60)))
  on conflict(nama) do update set token=excluded.token, kedaluwarsa=excluded.kedaluwarsa;
  return v_token;
end $fn$;
revoke all on function rc_private.gmail_token() from public,anon,authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Menyusun pesan RFC 2822 lalu meng-encode base64url
-- ------------------------------------------------------------------------------------------
-- Gmail API menerima satu pesan mentah, bukan medan-medan terpisah. Badan HTML dikirim sebagai
-- base64 supaya baris panjang tidak melanggar batas panjang baris MIME, dan subjek di-encode
-- supaya huruf non-ASCII tidak rusak.
create or replace function rc_private.mime_base64url(
  p_from text, p_to text[], p_cc text[], p_subjek text, p_html text)
returns text language sql immutable set search_path='' as $fn$
  select translate(
    encode(convert_to(
      'From: ' || p_from || E'\r\n' ||
      'To: ' || array_to_string(p_to, ', ') || E'\r\n' ||
      case when coalesce(array_length(p_cc,1),0) > 0
           then 'Cc: ' || array_to_string(p_cc, ', ') || E'\r\n' else '' end ||
      'Subject: =?UTF-8?B?' || translate(encode(convert_to(p_subjek,'UTF8'),'base64'), E'\n','') || '?=' || E'\r\n' ||
      'MIME-Version: 1.0' || E'\r\n' ||
      'Content-Type: text/html; charset="UTF-8"' || E'\r\n' ||
      'Content-Transfer-Encoding: base64' || E'\r\n\r\n' ||
      encode(convert_to(p_html,'UTF8'),'base64'),
      'UTF8'), 'base64'),
    E'+/=\n', '-_');
$fn$;
revoke all on function rc_private.mime_base64url(text,text[],text[],text,text) from public,anon;

-- ------------------------------------------------------------------------------------------
-- 3. Pengirim memilih penyedia sesuai rahasia yang tersedia
-- ------------------------------------------------------------------------------------------
-- Gmail didahulukan bila kredensialnya ada; bila tidak, jatuh ke penyedia HTTP biasa. Dengan
-- begitu berpindah penyedia cukup dengan mengisi atau menghapus rahasia, tanpa menyunting SQL.
create or replace function rc_private.kirim_satu_email(p_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v public.email_outbox; v_key text; v_from text; v_req bigint; v_token text; v_raw text;
begin
  select * into v from public.email_outbox where id = p_id and status = 'pending' for update;
  if not found then return jsonb_build_object('status','skipped','sebab','Bukan baris pending'); end if;

  v_from := rc_private.rahasia('rc_email_from');
  if coalesce(v_from,'')='' then
    return jsonb_build_object('status','tertunda',
      'sebab','Alamat pengirim belum diisi di Vault (rc_email_from)'); end if;

  v_token := rc_private.gmail_token();

  if v_token is not null then
    v_raw := rc_private.mime_base64url(v_from, v.tujuan, v.cc, v.subjek, v.isi_html);
    select net.http_post(
      url := 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'Authorization','Bearer '||v_token),
      body := jsonb_build_object('raw', v_raw),
      timeout_milliseconds := 20000
    ) into v_req;
    update public.email_outbox
       set status='sent', dikirim_pada=now(), percobaan=percobaan+1,
           konteks = konteks || jsonb_build_object('net_request_id', v_req, 'penyedia','gmail')
     where id = p_id;
    return jsonb_build_object('status','success','penyedia','gmail','requestId',v_req);
  end if;

  v_key := rc_private.rahasia('rc_email_api_key');
  if coalesce(v_key,'')='' then
    -- Sengaja TIDAK ditandai failed. Belum dikonfigurasi bukan kegagalan pengiriman, dan
    -- menandainya failed akan membuat email hilang begitu kredensialnya nanti diisi.
    return jsonb_build_object('status','tertunda',
      'sebab','Belum ada kredensial Gmail maupun kunci penyedia lain di Vault');
  end if;

  select net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body := jsonb_build_object('from',v_from,'to',to_jsonb(v.tujuan),'cc',to_jsonb(v.cc),
                               'subject',v.subjek,'html',v.isi_html),
    timeout_milliseconds := 20000
  ) into v_req;
  update public.email_outbox
     set status='sent', dikirim_pada=now(), percobaan=percobaan+1,
         konteks = konteks || jsonb_build_object('net_request_id', v_req, 'penyedia','resend')
   where id = p_id;
  return jsonb_build_object('status','success','penyedia','resend','requestId',v_req);
end $fn$;
revoke all on function rc_private.kirim_satu_email(uuid) from public,anon,authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Memeriksa kesiapan, supaya tidak perlu menebak
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_email_uji_koneksi()
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_token text; v_from text;
begin
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager' using errcode='42501'; end if;
  v_from := rc_private.rahasia('rc_email_from');
  begin
    v_token := rc_private.gmail_token();
  exception when others then
    return jsonb_build_object('status','error','penyedia','gmail','pesan',sqlerrm);
  end;
  return jsonb_build_object('status','success',
    'pengirim', coalesce(v_from,'(belum diisi)'),
    'gmailSiap', v_token is not null,
    'resendSiap', coalesce(rc_private.rahasia('rc_email_api_key'),'') <> '',
    'pesan', case
      when v_token is not null then 'Gmail siap. Access token berhasil diperoleh.'
      when coalesce(rc_private.rahasia('rc_email_api_key'),'') <> '' then 'Gmail belum dikonfigurasi; akan memakai penyedia cadangan.'
      else 'Belum ada kredensial email sama sekali. Email akan menumpuk di antrean.' end);
end $fn$;
revoke all on function public.rc_email_uji_koneksi() from public,anon;
grant execute on function public.rc_email_uji_koneksi() to authenticated;

create or replace function rc_private.marker_20261017() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261017() from public,anon;
grant execute on function rc_private.marker_20261017() to authenticated;

select 'Pengirim Gmail terpasang' as hasil,
 case when coalesce(rc_private.rahasia('rc_gmail_refresh_token'),'')='' then 'BELUM DIISI'
      else 'sudah diisi' end as kredensial_gmail,
 left(rc_private.mime_base64url('a@b.com','{c@d.com}','{}','Uji','<b>halo</b>'),40) as contoh_mime,
 'Ikuti docs/rc-email-gmail.md untuk memperoleh refresh token' as langkah_berikutnya;
