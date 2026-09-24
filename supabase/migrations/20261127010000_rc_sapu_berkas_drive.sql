-- ==========================================================================================
-- Penyapu berkas sementara di Drive
-- ==========================================================================================
-- rc_private.buat_pdf menghapus berkas sementaranya sendiri, baik ketika berhasil maupun ketika
-- ekspornya gagal. Tetapi ada satu celah yang terbukti nyata: bila panggilan penghapusan ITU
-- SENDIRI kehabisan waktu, atau prosesnya terputus di antara unggah dan hapus, berkasnya
-- tertinggal tanpa ada yang tahu.
--
-- Terbukti pada 20 September 2026. Sesudah beberapa percobaan, Drive akun pengirim menyimpan
-- empat berkas yatim:
--
--   RC_Daily_Report_2026-09-20, RC uji biner, RC uji lampiran, RC uji izin
--
-- Tiga di antaranya sisa pengujian, satu sisa percobaan yang kehabisan waktu lima detik sebelum
-- sempat menghapus. Seluruhnya sudah dibersihkan.
--
-- Supaya tidak menumpuk diam-diam, prosedur antrean kini menyapu berkas milik aplikasi ini yang
-- berumur lebih dari satu jam. Satu jam jauh lebih panjang daripada umur wajar sebuah berkas
-- sementara - yang hidup beberapa detik - sehingga penyapu ini tidak mungkin menghapus berkas
-- yang sedang dipakai.
--
-- Izin drive.file membuat penyapuan ini aman: aplikasi hanya melihat berkas yang ia buat sendiri.
-- Berkas lain milik pemilik akun tidak terlihat, apalagi terhapus.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.sapu_drive()
returns integer language plpgsql security definer set search_path='' as $fn$
declare r extensions.http_response; v jsonb; f jsonb; n integer := 0; v_tok text;
begin
  v_tok := rc_private.gmail_token();
  if v_tok is null then return 0; end if;
  perform rc_private.http_siapkan();

  -- Hanya berkas yang dibuat aplikasi ini DAN berumur lebih dari satu jam.
  select * into r from extensions.http((
    'GET',
    'https://www.googleapis.com/drive/v3/files'
      || '?q=' || extensions.urlencode('createdTime < ''' || to_char(now() - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '''')
      || '&fields=files(id,name)&pageSize=100',
    array[extensions.http_header('Authorization','Bearer '||v_tok)],
    null, null)::extensions.http_request);
  if coalesce(r.status,0) <> 200 then return 0; end if;

  v := r.content::jsonb;
  for f in select value from jsonb_array_elements(coalesce(v->'files','[]'::jsonb)) loop
    begin
      perform extensions.http((
        'DELETE','https://www.googleapis.com/drive/v3/files/'||(f->>'id'),
        array[extensions.http_header('Authorization','Bearer '||v_tok)],
        null, null)::extensions.http_request);
      n := n + 1;
    exception when others then
      -- Satu berkas yang gagal dihapus tidak boleh menghentikan penyapuan berkas lainnya,
      -- dan sama sekali tidak boleh menggagalkan pengiriman email yang menyusul.
      null;
    end;
  end loop;
  return n;
end $fn$;
revoke all on function rc_private.sapu_drive() from public,anon;

-- ------------------------------------------------------------------------------------------
-- Disisipkan ke prosedur antrean
-- ------------------------------------------------------------------------------------------
drop procedure if exists public.rc_email_proses(integer);

create procedure public.rc_email_proses(p_maks integer default 20)
language plpgsql as $pr$
declare v_req bigint; v_token text;
begin
  -- Tahap 1: minta token bila cache-nya sudah tidak berlaku.
  v_req := rc_private.gmail_token_minta();
  if v_req is not null then
    commit;                                   -- permintaan menjadi terlihat oleh worker pg_net
    perform pg_catalog.pg_sleep(3);           -- beri worker waktu menyelesaikan panggilannya
    v_token := rc_private.gmail_token_ambil(v_req);
    commit;
  end if;

  -- Tahap 2: jalankan antrean, termasuk membuat dan melampirkan PDF.
  perform public.rc_email_jalankan_antrean(coalesce(p_maks,20));
  commit;

  -- Tahap 3: sapu berkas sementara yang tertinggal. Dijalankan PALING AKHIR dan di dalam blok
  -- tersendiri, supaya kegagalannya tidak pernah menahan pengiriman.
  begin
    perform rc_private.sapu_drive();
  exception when others then
    null;
  end;
  commit;
end $pr$;

revoke all on procedure public.rc_email_proses(integer) from public;
revoke all on procedure public.rc_email_proses(integer) from anon;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_config text[];
begin
  select p.proconfig into v_config from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='rc_email_proses' and p.prokind='p';
  if v_config is not null then
    raise exception 'GAGAL: rc_email_proses punya klausa SET; COMMIT-nya akan ditolak.'; end if;

  if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                 where n.nspname='public' and p.proname='rc_email_proses' and p.prokind='p'
                   and pg_get_functiondef(p.oid) like '%sapu_drive%') then
    raise exception 'GAGAL: penyapu Drive belum tersambung ke prosedur antrean.'; end if;

  if not exists(select 1 from cron.job where jobname='rc_email_antrean' and active) then
    raise exception 'GAGAL: penjadwalan antrean tidak aktif.'; end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
