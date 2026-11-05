-- ==========================================================================================
-- Uji email terjadwal sekali sehari tanpa terhalang Pratinjau / Test Email (migrasi 20261163240000)
-- ==========================================================================================
-- Hanya memeriksa rc_private.email_terkirim_hari_ini dengan baris antrean buatan; rc_email_tick
-- TIDAK dipanggil (ia menjalankan antrean dan dapat benar-benar mengirim). Baris buatan berstatus
-- skipped / sent / failed (tidak pernah dikirim), dan pending hanya di dalam subtransaksi yang
-- dibatalkan (UJI_SELESAI), sehingga tidak terlihat pengirim tiap menit. Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_sekali_sehari.sql
-- ==========================================================================================
create temp table if not exists _hasil_s1(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_s1;

do $uji$
declare hasil jsonb := '[]'; v_besok timestamptz;
  -- Hari "besok" WIB pukul 09:00: belum ada baris sungguhan apa pun, jadi hanya baris buatan uji
  -- yang menentukan hasilnya.
begin
  v_besok := (date_trunc('day', now() at time zone 'Asia/Jakarta') + interval '1 day 9 hours') at time zone 'Asia/Jakarta';
  begin
    hasil := hasil || jsonb_build_object('uji', 'Belum ada apa pun hari itu: belum terkirim',
      'lulus', not rc_private.email_terkirim_hari_ini('kesehatan', v_besok), 'rinci', '');

    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, konteks, dibuat_pada)
    values ('kesehatan', array['sa_sd1@nipponpaint-indonesia.com'], 'pratinjau', '', 'skipped',
            '{"preview": true}', v_besok - interval '2 hours');
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau pagi itu TIDAK menghalangi email terjadwal',
      'lulus', not rc_private.email_terkirim_hari_ini('kesehatan', v_besok), 'rinci', '');

    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, konteks, dibuat_pada)
    values ('kesehatan', array['penguji@example.invalid'], '[TEST] uji', '', 'sent',
            '{"uji": true, "preview": false}', v_besok - interval '1 hour');
    hasil := hasil || jsonb_build_object('uji', 'Test Email pagi itu TIDAK menghalangi email terjadwal',
      'lulus', not rc_private.email_terkirim_hari_ini('kesehatan', v_besok), 'rinci', '');

    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, galat, konteks, dibuat_pada)
    values ('kesehatan', '{}', 'tanpa penerima', '', 'skipped', 'Belum ada penerima', '{"preview": false}', v_besok - interval '30 minutes');
    hasil := hasil || jsonb_build_object('uji', 'Baris tanpa penerima (skipped) tidak dihitung terkirim',
      'lulus', not rc_private.email_terkirim_hari_ini('kesehatan', v_besok), 'rinci', '');

    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, konteks, dibuat_pada)
    values ('daily', array['to.uji@example.invalid'], 'daily', '', 'sent', '{"preview": false, "uji": false}', v_besok - interval '1 hour');
    hasil := hasil || jsonb_build_object('uji', 'Email jenis lain yang terkirim tidak menghalangi jenis ini',
      'lulus', not rc_private.email_terkirim_hari_ini('kesehatan', v_besok) and rc_private.email_terkirim_hari_ini('daily', v_besok), 'rinci', '');

    insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, status, konteks, dibuat_pada)
    values ('kesehatan', array['sa_sd1@nipponpaint-indonesia.com'], array['cc.uji@example.invalid'], 'manual', '', 'sent',
            '{"preview": false, "uji": false}', v_besok - interval '15 minutes');
    hasil := hasil || jsonb_build_object('uji', 'Kirim Manual ke To + CC hari itu dihitung (tidak terkirim dua kali)',
      'lulus', rc_private.email_terkirim_hari_ini('kesehatan', v_besok), 'rinci', '');

    hasil := hasil || jsonb_build_object('uji', 'Hari berikutnya mulai dari nol lagi',
      'lulus', not rc_private.email_terkirim_hari_ini('kesehatan', v_besok + interval '1 day'), 'rinci', '');

    hasil := hasil || jsonb_build_object('uji', 'rc_email_tick memakai pemeriksaan baru',
      'lulus', pg_get_functiondef('public.rc_email_tick()'::regprocedure) ~ 'email_terkirim_hari_ini', 'rinci', '');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;

  insert into _hasil_s1(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_s1 order by urut;
