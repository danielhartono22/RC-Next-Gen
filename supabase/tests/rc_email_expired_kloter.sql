-- ==========================================================================================
-- Uji email Expired per kloter 12:00 / 16:00 - migrasi 20261163380000
-- ==========================================================================================
-- Dibatalkan seluruhnya (UJI_SELESAI). Tidak ada email dikirim: hanya baris antrean dan
-- email_outbox yang disusun (antrean pengiriman tidak dijalankan), lalu ikut dibatalkan.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_expired_kloter.sql
-- ==========================================================================================
create temp table if not exists _hasil_exp(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_exp;

do $uji$
declare
  hasil jsonb := '[]'; r jsonb; d1 uuid; d2 uuid; ids1 uuid[]; ids2 uuid[]; ids3 uuid[]; v_akt uuid; n integer;
  v_b timestamptz := rc_private.email_expired_batas(now()); v_row public.email_outbox; v_out0 integer;
begin
  select id into v_akt from public.profiles where role = 'osc' and status = 'active' order by user_code limit 1;
  select c.depot_id into d1 from public.claims c join public.depots d on d.id = c.depot_id
   where c.archived_at is null and btrim(coalesce(d.email_to, '')) <> '' group by c.depot_id having count(*) >= 3 order by count(*) desc limit 1;
  select c.depot_id into d2 from public.claims c join public.depots d on d.id = c.depot_id
   where c.archived_at is null and btrim(coalesce(d.email_to, '')) <> '' and c.depot_id <> d1 group by c.depot_id order by count(*) desc limit 1;
  ids1 := array(select id from public.claims where depot_id = d1 and archived_at is null order by id limit 2);
  ids2 := array(select id from public.claims where depot_id = d1 and archived_at is null order by id offset 2 limit 1)
          || array(select id from public.claims where depot_id = d2 and archived_at is null order by id limit 1);
  ids3 := array(select id from public.claims where depot_id = d2 and archived_at is null order by id offset 1 limit 1);

  begin
    -- ---- Batas kloter --------------------------------------------------------------------
    hasil := hasil || jsonb_build_object('uji', 'Kloter: 11:59 -> 16:00 kemarin; 12:00 dan 15:59 -> 12:00; 16:00 dan 23:00 -> 16:00',
      'lulus', rc_private.email_expired_batas('2026-10-22 11:59+07') = '2026-10-21 16:00+07'
           and rc_private.email_expired_batas('2026-10-22 12:00+07') = '2026-10-22 12:00+07'
           and rc_private.email_expired_batas('2026-10-22 15:59+07') = '2026-10-22 12:00+07'
           and rc_private.email_expired_batas('2026-10-22 16:00+07') = '2026-10-22 16:00+07'
           and rc_private.email_expired_batas('2026-10-22 23:00+07') = '2026-10-22 16:00+07', 'rinci', '-');

    -- ---- Expired dicatat, bukan langsung dikirim -------------------------------------------
    update public.email_settings set aktif = true, mode_uji = false where jenis = 'pengajuan';
    delete from rc_private.email_expired_antrean;
    select count(*) into v_out0 from public.email_outbox;
    perform rc_private.email_pengajuan_antre('expire', 'BUJI-1', ids1, v_akt, 'alasan satu');
    perform rc_private.email_pengajuan_antre('expire_claim_process', 'BUJI-2', ids2, v_akt, '');
    perform rc_private.email_pengajuan_antre('expire', 'BUJI-3', ids3, v_akt, 'sesudah batas');
    hasil := hasil || jsonb_build_object('uji', 'Expired tidak langsung membuat email; 3 proses masuk antrean kloter',
      'lulus', (select count(*) from public.email_outbox) = v_out0 and (select count(*) from rc_private.email_expired_antrean where kloter is null) = 3,
      'rinci', (select count(*) from rc_private.email_expired_antrean)::text);
    perform rc_private.email_pengajuan_antre('hold', 'BUJI-H', ids3, v_akt, 'tahan');
    hasil := hasil || jsonb_build_object('uji', 'On Hold tetap langsung (satu email)',
      'lulus', (select count(*) from public.email_outbox) = v_out0 + 1 and exists(select 1 from public.email_outbox where konteks->>'batch' = 'BUJI-H'), 'rinci', '-');

    -- Dua proses pertama sebelum batas kloter terakhir; proses ketiga sesudahnya (kloter berikutnya).
    update rc_private.email_expired_antrean set dibuat_pada = v_b - interval '2 hours' where batch = 'BUJI-1';
    update rc_private.email_expired_antrean set dibuat_pada = v_b - interval '1 hour' where batch = 'BUJI-2';
    update rc_private.email_expired_antrean set dibuat_pada = v_b + interval '1 minute' where batch = 'BUJI-3';

    r := rc_private.email_expired_kloter(now());
    hasil := hasil || jsonb_build_object('uji', 'Kloter: satu email per depot untuk proses sebelum batas; proses sesudah batas menunggu kloter berikutnya',
      'lulus', (r->>'email')::int = 2 and (r->>'proses')::int = 2
           and (select count(*) from public.email_outbox where konteks->>'aksi' = 'expire' and (konteks->>'kloter')::timestamptz = v_b) = 2
           and (select kloter is null from rc_private.email_expired_antrean where batch = 'BUJI-3')
           and (select bool_and(kloter = v_b and cardinality(outbox_ids) = 2) from rc_private.email_expired_antrean where batch in ('BUJI-1', 'BUJI-2')),
      'rinci', r::text);

    select * into v_row from public.email_outbox where konteks->>'aksi' = 'expire' and konteks ? 'kloter' and (konteks->>'depot')::uuid = d1
     order by dibuat_pada desc limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Email depot 1: Summary dulu, lalu detail kedua batch; subjek Expired + Rekap; penerima Depot Master',
      'lulus', v_row.isi_html like '%Summary%JUMLAH BATCH%JUMLAH DOKUMEN%TOTAL CB HANGUS%Detail%NO BATCH%'
           and v_row.isi_html like '%BUJI-1%' and v_row.isi_html like '%BUJI-2%' and v_row.isi_html not like '%BUJI-3%'
           and v_row.isi_html like '%alasan satu%'
           and v_row.subjek like 'Expired - Pengajuan Claim Cashback % - Rekap %'
           and v_row.tujuan @> rc_private.pecah_email((select email_to from public.depots where id = d1))
           and (v_row.konteks->>'qty')::int = 3,
      'rinci', v_row.subjek);
    r := rc_private.email_expired_kloter(now());
    hasil := hasil || jsonb_build_object('uji', 'Kloter yang sama tidak dikirim dua kali', 'lulus', (r->>'email')::int = 0, 'rinci', r::text);

    -- Kloter berikutnya: proses ketiga ikut.
    -- Kloter sesudah 12:00 adalah 16:00; sesudah 16:00 adalah 12:00 besok.
    r := rc_private.email_expired_kloter(v_b + case when extract(hour from v_b at time zone 'Asia/Jakarta') = 12 then interval '4 hours' else interval '20 hours' end + interval '30 minutes');
    hasil := hasil || jsonb_build_object('uji', 'Kloter berikutnya membawa proses sesudah batas sebelumnya',
      'lulus', (r->>'email')::int = 1 and (select kloter is not null from rc_private.email_expired_antrean where batch = 'BUJI-3'), 'rinci', r::text);

    -- Mode Uji: dibelokkan ke alamat uji.
    update public.email_settings set mode_uji = true, email_uji = 'uji.exp@contoh.co.id' where jenis = 'pengajuan';
    perform rc_private.email_pengajuan_antre('expire', 'BUJI-4', ids1, v_akt, '');
    update rc_private.email_expired_antrean set dibuat_pada = v_b - interval '5 minutes' where batch = 'BUJI-4';
    r := rc_private.email_expired_kloter(now());
    select * into v_row from public.email_outbox where konteks->'batch' ? 'BUJI-4';
    hasil := hasil || jsonb_build_object('uji', 'Mode Uji Email Pengajuan berlaku: TO alamat uji, subjek [UJI], spanduk',
      'lulus', v_row.tujuan = '{uji.exp@contoh.co.id}' and v_row.subjek like '[UJI] %' and v_row.isi_html like '%MODE UJI%', 'rinci', v_row.subjek);

    -- Email Pengajuan nonaktif: proses tidak dicatat (sama dengan email lain).
    update public.email_settings set aktif = false where jenis = 'pengajuan';
    select count(*) into n from rc_private.email_expired_antrean;
    perform rc_private.email_pengajuan_antre('expire', 'BUJI-5', ids1, v_akt, '');
    hasil := hasil || jsonb_build_object('uji', 'Email Pengajuan nonaktif: Expired tidak dicatat', 'lulus', (select count(*) from rc_private.email_expired_antrean) = n, 'rinci', '-');

    hasil := hasil || jsonb_build_object('uji', 'Penjadwal email menjalankan rekap kloter',
      'lulus', position('rc_private.email_expired_kloter(sekarang)' in pg_get_functiondef('public.rc_email_tick()'::regprocedure)) > 0, 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Antrean tertutup bagi authenticated', 'lulus', not has_table_privilege('authenticated', 'rc_private.email_expired_antrean', 'select'), 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  insert into _hasil_exp(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_exp order by urut;
