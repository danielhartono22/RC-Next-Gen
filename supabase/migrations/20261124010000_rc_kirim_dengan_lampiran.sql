-- ==========================================================================================
-- Pengiriman email melampirkan PDF
-- ==========================================================================================
-- Melengkapi 20261123010000, yang menyiapkan pembuatan PDF tetapi belum menyambungkannya ke
-- jalur kirim. Di sini rc_private.kirim_satu_email membuat PDF lebih dulu, lalu menyusun MIME
-- multipart alih-alih HTML tunggal.
--
-- ------------------------------------------------------------------------------------------
-- KEGAGALAN PDF TIDAK BOLEH MENAHAN EMAILNYA
-- ------------------------------------------------------------------------------------------
-- Ini pilihan yang sama dengan Apps Script dulu, dan catatannya masih ada di WeeklyEmail.gs:
--
--   if (!pack.pdf) notes.push('PDF gagal dibuat (email tetap dikirim tanpa lampiran)');
--
-- Alasannya masuk akal: laporan yang sampai tanpa lampiran masih berguna, sedangkan laporan yang
-- tidak sampai sama sekali tidak berguna sama sekali. Jadi kegagalan pembuatan PDF ditangkap,
-- dicatat pada kolom galat baris antreannya, dan emailnya tetap berangkat sebagai HTML biasa.
--
-- ------------------------------------------------------------------------------------------
-- HANYA DI JALUR ANTREAN
-- ------------------------------------------------------------------------------------------
-- Pembuatan PDF memakai pgsql-http yang bekerja SINKRON - unggah, ekspor, hapus - sekitar empat
-- sampai enam detik. Peran authenticated hanya diberi delapan detik, jadi menjalankannya dari
-- tombol di layar terlalu rapat.
--
-- Karena itu tombol Test Email dan Kirim Manual tetap MENGANTRE seperti sebelumnya, dan prosedur
-- rc_email_proses - yang dijalankan pg_cron tiap menit tanpa batas itu - yang mengirimkannya
-- lengkap dengan lampiran. Jeda terburuknya satu menit.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.kirim_satu_email(p_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v public.email_outbox; v_key text; v_from text; v_req bigint; v_token text; v_raw text;
  v_pdf bytea; v_nama_pdf text; v_catatan text := '';
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
    -- Dibuat di dalam blok tersendiri: kegagalannya dicatat, tetapi emailnya tetap dikirim.
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

    select net.http_post(
      url := 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'Authorization','Bearer '||v_token),
      body := jsonb_build_object('raw', v_raw),
      timeout_milliseconds := 30000
    ) into v_req;

    update public.email_outbox
       set status='sent', dikirim_pada=now(), percobaan=percobaan+1,
           -- Kolom galat tidak boleh NULL; tanpa catatan ia dikosongkan, bukan di-NULL-kan.
           galat = coalesce(v_catatan,''),
           konteks = konteks || jsonb_build_object(
             'net_request_id', v_req, 'penyedia','gmail',
             'lampiran', case when v_pdf is null then null else v_nama_pdf end,
             'lampiranByte', case when v_pdf is null then null else octet_length(v_pdf) end)
     where id = p_id;

    return jsonb_build_object('status','success','penyedia','gmail','requestId',v_req,
      'lampiran', v_pdf is not null, 'catatan', nullif(v_catatan,''));
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

  if src not like '%mime_lampiran_base64url%' then
    raise exception 'GAGAL: kirim_satu_email belum memakai MIME berlampiran.'; end if;
  if src not like '%buat_pdf%' then
    raise exception 'GAGAL: kirim_satu_email belum membuat PDF.'; end if;
  -- Cadangan tanpa lampiran harus tetap ada.
  if src not like '%mime_base64url(v_from%' then
    raise exception 'GAGAL: jalur tanpa lampiran hilang; kegagalan PDF akan menahan emailnya.'; end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
