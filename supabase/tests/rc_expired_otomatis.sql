-- ==========================================================================================
-- Uji 14 November 2026: dokumen di Open Expired otomatis 1 bulan sesudah batas proses (20261163970000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_expired_otomatis.sql
-- ==========================================================================================
create temp table if not exists _hasil_eo(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_eo;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; r jsonb; a record; b record; c record; v_n integer; v_txt text; v_html text; v_ant bigint;
  v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_log integer;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and suffix_num ~ '^[0-9]{3}$' order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  begin
    update public.profiles set must_change_password = false where id = v_sm;
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'approval_aktif';
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';
    update public.email_settings set aktif = true, mode_uji = false where jenis = 'pengajuan';
    delete from rc_private.email_expired_antrean;
    perform rc_private.zdage_nilai_baru();
    perform rc_private.zdage_expired_otomatis(); -- yang memang sudah waktunya tidak ikut dihitung di bawah

    -- A: batas proses lewat 1 bulan + 1 hari (kena). B: tepat 1 bulan (belum). C: pindahan Restricted (tanpa batas).
    select k.id, k.no_doc, k.depot_id, o.id oid into a from public.claims k join public.rc_clearing_offers o on o.claim_id = k.id
     where o.status in ('offered', 'overdue') and o.result = 'LUNAS' and o.deadline_at is not null and k.status = 'not_yet' and k.pending_approval is null and k.archived_at is null
     order by k.no_doc limit 1;
    select k.id, k.no_doc, o.id oid into b from public.claims k join public.rc_clearing_offers o on o.claim_id = k.id
     where o.status in ('offered', 'overdue') and o.result = 'LUNAS' and o.deadline_at is not null and k.status = 'not_yet' and k.pending_approval is null and k.archived_at is null
       and k.id <> a.id order by k.no_doc limit 1;
    if a.id is null or b.id is null then raise exception 'Fixture: dua dokumen toko lunas di Open tidak ada'; end if;
    select k.id, k.no_doc into c from public.claims k
     where k.status = 'not_yet' and k.pending_approval is null and k.archived_at is null and k.customer_id is not null
       and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = k.id and o.status in ('offered', 'overdue'))
       and not exists(select 1 from public.rc_bad_debt_remarks x where x.customer_id = k.customer_id and x.status = 'active')
       and exists(select 1 from public.rc_zdage_depot_data dd where dd.depot_id = k.depot_id)
     order by k.no_doc limit 1;
    if c.id is null then raise exception 'Fixture: dokumen Restricted tidak ada'; end if;
    r := public.rc_restricted_pindah(array[c.no_doc], 'Uji expired otomatis');
    update public.rc_clearing_offers set deadline_at = (((v_hari - interval '1 month')::date - 1)::timestamp + time '23:59:59') at time zone 'Asia/Jakarta', status = 'overdue' where id = a.oid;
    update public.rc_clearing_offers set deadline_at = ((v_hari - interval '1 month')::date::timestamp + time '23:59:59') at time zone 'Asia/Jakarta', status = 'overdue' where id = b.oid;
    select count(*) into v_log from public.activity_logs where event_type = 'zdage_expired_otomatis';

    -- 1. Tab Open menampilkan tanggal Expired otomatis = batas proses + 1 bulan + 1 hari.
    r := public.rc_open_claims_filtered(b.no_doc, '', 0, 20, '');
    v_txt := (select x->>'expiredOtomatis' from jsonb_array_elements(r->'rows') x where x->>'noDoc' = b.no_doc);
    hasil := hasil || jsonb_build_object('uji', 'Open: expiredOtomatis = batas proses + 1 bulan + 1 hari', 'lulus',
      v_txt = to_char(v_hari + 1, 'DD-Mon-YYYY'), 'rinci', coalesce(v_txt, 'tidak ada'));
    r := public.rc_open_claims_filtered(c.no_doc, '', 0, 20, '');
    v_txt := (select x->>'expiredOtomatis' from jsonb_array_elements(r->'rows') x where x->>'noDoc' = c.no_doc);
    hasil := hasil || jsonb_build_object('uji', 'Open: pindahan Restricted tidak punya tanggal Expired otomatis', 'lulus', v_txt = '', 'rinci', coalesce(v_txt, 'baris tidak ada'));

    -- 2. Job harian meng-Expired-kan A saja.
    r := rc_private.zdage_harian();
    select k.status || ' / ' || coalesce(k.batch_clearing, '-') || ' / ' || coalesce(k.batch_event_code, '-') into v_txt from public.claims k where k.id = a.id;
    hasil := hasil || jsonb_build_object('uji', 'Lewat 1 bulan + 1 hari: Expired, No Batch kepala 3 akhiran 000', 'lulus',
      (r->>'expiredOtomatis')::int = 1 and v_txt ~ ('^expired / 3[0-9]000' || to_char(v_hari, 'DDMMYY') || '[0-9]{4} / 3$'), 'rinci', v_txt || ' ' || r::text);
    hasil := hasil || jsonb_build_object('uji', 'Tepat 1 bulan dan pindahan Restricted: tetap Not Yet dengan tawaran aktif', 'lulus',
      (select count(*) from public.claims k join public.rc_clearing_offers o on o.claim_id = k.id and o.status in ('offered', 'overdue')
        where k.id in (b.id, c.id) and k.status = 'not_yet') = 2, 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Tawaran toko lunas dokumen yang Expired dibatalkan', 'lulus',
      (select status from public.rc_clearing_offers where id = a.oid) = 'cancelled', 'rinci', (select status from public.rc_clearing_offers where id = a.oid));
    select h.reason into v_txt from public.claim_status_history h where h.claim_id = a.id and h.action = 'expire_otomatis' and h.to_status = 'expired' and h.actor_id is null and h.batch ~ '^3';
    hasil := hasil || jsonb_build_object('uji', 'Riwayat expire_otomatis memuat batas prosesnya', 'lulus',
      v_txt ~ ('batas proses ' || to_char((v_hari - interval '1 month')::date - 1, 'DD-Mon-YYYY')), 'rinci', coalesce(v_txt, 'tidak ada'));
    select count(*) - v_log, max(batch_no) into v_n, v_txt from public.activity_logs where event_type = 'zdage_expired_otomatis';
    hasil := hasil || jsonb_build_object('uji', 'Log Activity satu baris dengan No Batch', 'lulus',
      v_n = 1 and v_txt = (select batch_clearing from public.claims where id = a.id), 'rinci', v_n || ' / ' || coalesce(v_txt, '-'));

    -- 3. Email: masuk antrean rekap Expired dengan alasan; pelaku = Sistem (otomatis).
    select q.id into v_ant from rc_private.email_expired_antrean q where q.batch = (select batch_clearing from public.claims where id = a.id) and q.aktor is null and a.id = any(q.claim_ids);
    v_html := case when v_ant is null then '' else rc_private.email_expired_html(array[v_ant], a.depot_id, now() + interval '1 hour') end;
    hasil := hasil || jsonb_build_object('uji', 'Email rekap Expired: alasan di badan email, Diproses oleh Sistem (otomatis)', 'lulus',
      v_ant is not null and v_html ~ 'Alasan Expired:' and v_html ~ 'tidak diproses sampai 1 bulan' and v_html ~ 'Sistem \(otomatis\)', 'rinci', coalesce(v_ant::text, 'tidak antre'));

    -- 4. Dijalankan lagi: tidak ada yang berubah.
    r := rc_private.zdage_expired_otomatis();
    hasil := hasil || jsonb_build_object('uji', 'Dijalankan ulang: 0 dokumen', 'lulus', (r->>'expired')::int = 0, 'rinci', r::text);

    -- 5. Dikembalikan lewat Change Status: Not Yet lagi, lalu ditawarkan ulang dengan batas proses baru.
    r := public.rc_change_status(jsonb_build_array(jsonb_build_object('noDoc', a.no_doc)), 'Uji: dikembalikan sesudah Expired otomatis');
    perform rc_private.zdage_nilai_baru();
    select k.status || ' / ' || coalesce((select to_char(o.deadline_at at time zone 'Asia/Jakarta', 'YYYY-MM-DD') from public.rc_clearing_offers o where o.claim_id = k.id and o.status = 'offered'), 'tanpa tawaran')
      into v_txt from public.claims k where k.id = a.id;
    hasil := hasil || jsonb_build_object('uji', 'Change Status mengembalikan dokumen; toko lunas ditawarkan lagi dengan batas 7 hari baru', 'lulus',
      v_txt = 'not_yet / ' || to_char(v_hari + 7, 'YYYY-MM-DD') and (rc_private.zdage_expired_otomatis()->>'expired')::int = 0, 'rinci', v_txt || ' ' || left(r::text, 120));

    -- 6. Saklar ZDAGE mati: tidak ada Expired otomatis.
    update public.rc_clearing_offers set deadline_at = now() - interval '3 months' where id = b.oid;
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'zdage_aktif';
    r := rc_private.zdage_harian();
    hasil := hasil || jsonb_build_object('uji', 'Saklar ZDAGE mati: tidak ada yang di-Expired', 'lulus',
      (select status from public.claims where id = b.id) = 'not_yet', 'rinci', r::text);
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';

    -- 7. Dokumen yang menunggu approval tidak disentuh.
    update public.claims set pending_approval = jsonb_build_object('kind', 'submit') where id = b.id;
    r := rc_private.zdage_expired_otomatis();
    hasil := hasil || jsonb_build_object('uji', 'Dokumen yang menunggu approval tidak di-Expired', 'lulus',
      (select status from public.claims where id = b.id) = 'not_yet', 'rinci', r::text);

    hasil := hasil || jsonb_build_object('uji', 'Fungsi Expired otomatis tidak dapat dipanggil pengguna', 'lulus',
      not has_function_privilege('authenticated', 'rc_private.zdage_expired_otomatis()', 'execute') and not has_function_privilege('anon', 'rc_private.zdage_expired_otomatis()', 'execute'), 'rinci', '-');
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_eo(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_eo order by urut;
