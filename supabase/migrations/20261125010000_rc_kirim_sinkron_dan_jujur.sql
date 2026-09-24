-- ==========================================================================================
-- Pengiriman email menunggu jawaban Gmail, dan melaporkan hasil yang sebenarnya
-- ==========================================================================================
-- Dua cacat yang terungkap bersamaan begitu lampiran PDF mulai dikirim.
--
-- ------------------------------------------------------------------------------------------
-- CACAT 1 - "SENT" DITULIS TANPA PERNAH MELIHAT JAWABAN
-- ------------------------------------------------------------------------------------------
-- kirim_satu_email menembak lewat net.http_post lalu LANGSUNG menandai barisnya 'sent':
--
--   select net.http_post(...) into v_req;
--   update public.email_outbox set status='sent', dikirim_pada=now() ...
--
-- pg_net bekerja asinkron, jadi pada saat baris itu ditandai terkirim, permintaannya bahkan
-- belum berangkat. Apa pun jawaban Gmail sesudahnya - ditolak, kehabisan waktu, kuota habis -
-- tidak pernah sampai ke tabel antrean. Layar mengatakan terkirim, dan tidak ada yang tahu bila
-- ternyata tidak.
--
-- Terbukti pada percobaan pertama lampiran PDF:
--
--   baris antrean : status=sent, lampiran=RC_Daily_Report_2026-09-20.pdf
--   jawaban nyata : Timeout of 30000 ms reached
--
-- Barisnya mengaku terkirim; emailnya tidak pernah sampai.
--
-- ------------------------------------------------------------------------------------------
-- CACAT 2 - MUATAN BERLAMPIRAN TERLALU BESAR UNTUK pg_net
-- ------------------------------------------------------------------------------------------
-- PDF 111 KB menjadi sekitar 150 KB setelah base64, dan seluruhnya harus dikirim sebagai satu
-- badan JSON. pg_net kehabisan waktu tiga puluh detik pada muatan sebesar itu.
--
-- ------------------------------------------------------------------------------------------
-- KEDUANYA HILANG DENGAN SATU PERUBAHAN
-- ------------------------------------------------------------------------------------------
-- Pengiriman dipindahkan ke pgsql-http, yang bekerja SINKRON: ia menunggu jawaban Gmail dan
-- mengembalikan status sesungguhnya. Dengan begitu:
--
--   * 'sent' hanya ditulis ketika Gmail benar-benar menjawab 200
--   * penolakan dicatat apa adanya pada kolom galat, dan barisnya tetap pending untuk dicoba lagi
--   * muatan besar tidak lagi menjadi masalah - ekstensi yang sama sudah mengunggah HTML dan
--     mengunduh PDF tanpa keluhan
--
-- Ini aman justru karena pengiriman hanya berjalan di dalam prosedur rc_email_proses yang
-- dijalankan pg_cron. Di sana tidak ada batas delapan detik milik peran authenticated, sehingga
-- menunggu beberapa detik tidak menahan siapa pun.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.kirim_satu_email(p_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v public.email_outbox; v_key text; v_from text; v_token text; v_raw text;
  v_pdf bytea; v_nama_pdf text; v_catatan text := '';
  r extensions.http_response; v_req bigint;
begin
  select * into v from public.email_outbox where id = p_id and status = 'pending' for update;
  if not found then return jsonb_build_object('status','skipped','sebab','Bukan baris pending'); end if;

  v_from := rc_private.rahasia('rc_email_from');
  if coalesce(v_from,'')='' then
    return jsonb_build_object('status','tertunda',
      'sebab','Alamat pengirim belum diisi di Vault (rc_email_from)'); end if;

  v_token := rc_private.gmail_token();

  if v_token is not null then
    -- ---- Lampiran PDF ------------------------------------------------------------------
    -- Kegagalannya dicatat, tetapi emailnya tetap dikirim tanpa lampiran. Laporan yang sampai
    -- tanpa lampiran masih berguna; laporan yang tidak sampai tidak berguna sama sekali.
    begin
      v_nama_pdf := 'RC_' || initcap(v.jenis) || '_Report_'
                 || to_char(now() at time zone 'Asia/Jakarta','YYYY-MM-DD') || '.pdf';
      v_pdf := rc_private.buat_pdf(
        rc_private.pdf_detail_html('RC Reporting - ' || initcap(v.jenis) || ' Outstanding Claim Report'),
        replace(v_nama_pdf, '.pdf', ''));
    exception when others then
      v_pdf := null;
      v_catatan := 'PDF gagal dibuat, email dikirim tanpa lampiran: ' || left(sqlerrm, 200);
    end;

    if v_pdf is not null then
      v_raw := rc_private.mime_lampiran_base64url(v_from, v.tujuan, v.cc, v.subjek, v.isi_html,
                                                  v_pdf, v_nama_pdf);
    else
      v_raw := rc_private.mime_base64url(v_from, v.tujuan, v.cc, v.subjek, v.isi_html);
    end if;

    -- Pengiriman SINKRON: jawabannya ditunggu, bukan ditebak.
    select * into r from extensions.http((
      'POST',
      'https://gmail.googleapis.com/gmail/v1/users/me/messages/send',
      array[extensions.http_header('Authorization','Bearer '||v_token)],
      'application/json',
      jsonb_build_object('raw', v_raw)::text)::extensions.http_request);

    if coalesce(r.status,0) not between 200 and 299 then
      -- Tetap pending supaya dicoba lagi pada giliran berikutnya; percobaannya dinaikkan
      -- sehingga penolakan yang berulang tetap berakhir sebagai failed, bukan berputar selamanya.
      update public.email_outbox
         set percobaan = percobaan + 1,
             galat = left('Gmail menolak ('||coalesce(r.status::text,'tanpa status')||'): '
                          ||coalesce(r.content,''), 500),
             status = case when percobaan + 1 >= 5 then 'failed' else 'pending' end
       where id = p_id;
      return jsonb_build_object('status','gagal','penyedia','gmail',
        'sebab', coalesce(r.status::text,'-')||' '||left(coalesce(r.content,''),200));
    end if;

    update public.email_outbox
       set status='sent', dikirim_pada=now(), percobaan=percobaan+1,
           galat = coalesce(v_catatan,''),
           konteks = konteks || jsonb_build_object(
             'penyedia','gmail',
             'messageId', (r.content::jsonb)->>'id',
             'lampiran', case when v_pdf is null then null else v_nama_pdf end,
             'lampiranByte', case when v_pdf is null then null else octet_length(v_pdf) end)
     where id = p_id;

    return jsonb_build_object('status','success','penyedia','gmail',
      'messageId', (r.content::jsonb)->>'id',
      'lampiran', v_pdf is not null, 'catatan', nullif(v_catatan,''));
  end if;

  v_key := rc_private.rahasia('rc_email_api_key');
  if coalesce(v_key,'')='' then
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
revoke all on function rc_private.kirim_satu_email(uuid) from public,anon;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='rc_private' and p.proname='kirim_satu_email';

  -- Jalur Gmail tidak boleh lagi memakai pg_net yang asinkron.
  if src like '%gmail.googleapis.com%' and src like '%net.http_post(%url := ''https://gmail%' then
    raise exception 'GAGAL: pengiriman Gmail masih lewat pg_net.'; end if;
  if src not like '%extensions.http((%' then
    raise exception 'GAGAL: pengiriman Gmail belum sinkron.'; end if;
  if src not like '%Gmail menolak%' then
    raise exception 'GAGAL: penolakan Gmail tidak dicatat.'; end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
