-- ==========================================================================================
-- Jawaban pg_net dibaca langsung dari tabelnya, bukan lewat http_collect_response
-- ==========================================================================================
-- Pekerjaan antrean masih gagal sesudah 20261120010000, kali ini dengan galat yang datang dari
-- dalam pg_net sendiri:
--
--   ERROR: query has no destination for result data
--   HINT:  If you want to discard the results of a SELECT, use PERFORM instead.
--   CONTEXT: PL/pgSQL function net.http_collect_response(bigint,boolean) line 4
--
-- Jadi yang cacat adalah net.http_collect_response bawaan pg_net 0.20.4 pada cabang async,
-- bukan kode kita. Fungsi itu memang sudah lama tidak dianjurkan dipakai.
--
-- Tidak ada yang hilang dengan melepasnya. Worker pg_net menulis sendiri jawabannya ke
-- net._http_response begitu panggilan HTTP selesai; membacanya cukup dengan SELECT biasa.
-- Itu pula yang dilakukan pada uji manual yang membuktikan kredensial Gmail benar:
--
--   select ... from net._http_response where id = 5;
--   status=200  punya access_token=YA
--
-- Satu hal yang ikut berubah: baris jawaban dihapus sesudah dibaca. http_collect_response dulu
-- melakukannya; tanpa itu, jawaban lama akan menumpuk - dan jawaban penyegaran token memuat
-- access_token, yang tidak pantas tertinggal di tabel lebih lama daripada perlunya.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.gmail_token_ambil(p_req bigint)
returns text language plpgsql security definer set search_path='' as $fn$
declare v_res jsonb; v_body jsonb; v_token text;
begin
  if p_req is null then return null; end if;

  -- Dibaca langsung. net.http_collect_response TIDAK dipakai: pada pg_net 0.20.4 cabang
  -- async-nya melempar "query has no destination for result data" dari dalam fungsinya sendiri.
  select to_jsonb(r) into v_res from net._http_response r where r.id = p_req;
  if v_res is null then
    -- Worker belum selesai. Bukan kegagalan: pemanggil akan mencobanya lagi pada giliran
    -- berikutnya, dan permintaan yang sama tidak dikirim ulang karena request_id-nya tetap.
    return null;
  end if;

  -- Baris jawaban dilepas sesudah dibaca, apa pun hasilnya - ia memuat access_token.
  delete from net._http_response where id = p_req;

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
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='gmail_token_ambil';
  -- Dicari bentuk PEMANGGILANNYA - nama diikuti kurung buka - bukan sekadar namanya, karena
  -- namanya memang disebut pada komentar di dalam badan fungsi ini untuk menerangkan mengapa
  -- ia tidak dipakai. Mencocokkan namanya saja membuat pemeriksaan ini menuduh dirinya sendiri.
  if src like '%http_collect_response(%' then
    raise exception 'GAGAL: masih memanggil http_collect_response yang cacat.';
  end if;
  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
