-- ==========================================================================================
-- rc_email_proses: melepas klausa SET supaya COMMIT-nya sah
-- ==========================================================================================
-- Migration sebelumnya (20261119010000) memasang prosedur rc_email_proses yang melakukan COMMIT
-- di tengah jalan - COMMIT itulah yang membuat permintaan pg_net terlihat oleh workernya.
-- Tetapi prosedurnya ditulis dengan klausa "set search_path=''", dan pg_cron menolaknya:
--
--   21:24:00  failed  ERROR: invalid transaction termination
--   21:25:00  failed  ERROR: invalid transaction termination
--
-- PostgreSQL melarang pengendalian transaksi di dalam rutin yang memiliki klausa SET. Sebabnya
-- masuk akal: klausa itu menyimpan nilai lama untuk dipulihkan saat rutinnya selesai, dan COMMIT
-- di tengah jalan membuat titik pemulihan itu tidak lagi berarti.
--
-- Karena itu klausa SET-nya dilepas. Sebagai gantinya SELURUH nama di dalam badan prosedur
-- ditulis lengkap dengan skemanya - termasuk pg_catalog.pg_sleep - sehingga tidak ada satu pun
-- yang bergantung pada search_path yang berlaku saat dipanggil.
--
-- SECURITY DEFINER juga dilepas. Prosedur ini hanya dipanggil oleh pg_cron, yang berjalan
-- sebagai postgres dan sudah berwenang penuh; hak tambahan tidak diperlukan. Haknya dicabut
-- dari public dan anon supaya tidak ada jalan memanggilnya dari aplikasi.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

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

  -- Tahap 2: jalankan antrean. kirim_satu_email kini memperoleh token dari cache tanpa
  -- menyentuh jaringan, dan pengirimannya sendiri memang tidak menunggu jawaban.
  perform public.rc_email_jalankan_antrean(coalesce(p_maks,20));
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
   where n.nspname = 'public' and p.proname = 'rc_email_proses' and p.prokind = 'p';

  if v_config is not null then
    raise exception 'GAGAL: rc_email_proses masih punya klausa SET (%); COMMIT-nya akan ditolak.',
      array_to_string(v_config, ', ');
  end if;

  if not exists(select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname='public' and p.proname='rc_email_proses' and p.prokind='p') then
    raise exception 'GAGAL: prosedur rc_email_proses tidak ada.';
  end if;

  if not exists(select 1 from cron.job where jobname='rc_email_antrean' and active) then
    raise exception 'GAGAL: penjadwalan antrean tidak aktif.';
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
