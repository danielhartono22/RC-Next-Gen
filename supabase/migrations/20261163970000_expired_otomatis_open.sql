-- ==========================================================================================
-- Dokumen di Open yang tidak diproses menjadi Expired otomatis
-- ==========================================================================================
-- Pemilik, 14 November 2026:
--   "buat jika H+1 bulan tidak diproses semua dokumen akan menjadi expired."
--   H = batas proses 7 hari (pilihan "Sejak batas 7 hari lewat"); hanya dokumen di tab Open.
--
-- Aturan: dokumen Not Yet yang sedang ditawarkan di Open sebagai toko lunas (tawaran berstatus
-- offered / overdue dan punya batas proses) menjadi Expired pada hari SESUDAH batas proses +
-- 1 bulan. Contoh: batas proses 13-Nov-2026 -> Expired pada 14-Des-2026. Dijalankan job harian
-- 07:00 WIB (rc_private.zdage_harian), hanya saat saklar ZDAGE Integration menyala.
--   - Tidak kena: dokumen yang dipindah Editor dari Restricted (tanpa batas proses), dokumen
--     Restricted, toko Bad Debt, dan dokumen yang sedang menunggu approval.
--   - Satu proses = satu No Batch (tahap 04, akhiran 000 = sistem, kepala 3 = Expired), satu
--     baris Log Activity, satu riwayat per dokumen (expire_otomatis) beserta batas prosesnya.
--   - Email: masuk rekap Expired per depot (kloter 12:00 / 16:00) lewat saklar Email Pengajuan,
--     dengan alasan di badan email; "Diproses oleh" = Sistem (otomatis).
--   - Tawaran toko lunasnya dibatalkan oleh pemicu yang sudah ada (zdage_tawaran_ikut_klaim).
--   - Dokumen dapat dikembalikan lewat Amend Doc > Change Status; bila tokonya masih lunas, ia
--     ditawarkan lagi dengan batas proses baru (penilaian otomatis 20261163950000).
-- Tab Open mengirim tanggal 'expiredOtomatis' di setiap baris yang punya batas proses.
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

create or replace function rc_private.zdage_expired_otomatis()
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_ids uuid[]; v_jadi uuid[];
  n integer := 0; v_tot numeric := 0; n_dep integer := 0; k integer; b text; v text[]; v_batch text;
  v_alasan constant text := 'Otomatis: tidak diproses sampai 1 bulan setelah batas proses toko lunas';
begin
  if not rc_private.zdage_aktif() then return jsonb_build_object('expired', 0, 'lewati', 'ZDAGE Integration mati'); end if;

  select array_agg(c.id) into v_ids
    from public.rc_clearing_offers o join public.claims c on c.id = o.claim_id
   where o.status in ('offered', 'overdue') and o.deadline_at is not null
     and v_hari > ((o.deadline_at at time zone 'Asia/Jakarta')::date + interval '1 month')::date
     and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null;
  if v_ids is null then return jsonb_build_object('expired', 0); end if;

  -- No Batch milik sistem: tahap 04 (seperti Expired lain), akhiran 000. Aturan uniknya sama
  -- dengan rc_private.next_batch, yang hanya dapat dipakai pengguna yang sedang login.
  loop
    insert into rc_private.batch_counters values ('04', '000', v_hari, 1)
    on conflict (stage, suffix, business_date) do update set counter = rc_private.batch_counters.counter + 1 returning counter into k;
    b := '04' || '000' || to_char(v_hari, 'DDMMYY') || lpad(k::text, 4, '0');
    v := array[b, '1' || substr(b, 2), '2' || substr(b, 2), '3' || substr(b, 2), '4' || substr(b, 2), '6' || substr(b, 2), '7' || substr(b, 2)];
    exit when not exists(select 1 from public.claims where batch_upload = any(v) or batch_release = any(v) or batch_claim = any(v) or batch_clearing = any(v))
      and not exists(select 1 from staging.rc_latest_rows where sheet_name = 'BatchLog' and data->>'Batch Number' = any(v));
  end loop;
  v_batch := rc_private.batch_kejadian(b, '3');

  with x as (
    update public.claims c set status = 'expired', pending_approval = null, previous_status = null, hold_approved_at = now(),
           batch_clearing = v_batch, batch_event_code = '3', batch_event_at = now(), version_no = c.version_no + 1, updated_at = now()
     where c.id = any(v_ids) and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
    returning c.id, c.depot_id, c.cb_net),
  h as (
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, batch, reason)
    select x.id, null, 'not_yet', 'expired', 'expire_otomatis', v_batch,
           left('Expired otomatis: tidak diproses sampai 1 bulan setelah batas proses '
             || coalesce((select to_char(max(o.deadline_at) at time zone 'Asia/Jakarta', 'DD-Mon-YYYY') from public.rc_clearing_offers o
                           where o.claim_id = x.id and o.status in ('offered', 'overdue')), '-'), 300)
      from x returning claim_id)
  select coalesce(array_agg(x.id), '{}'), count(*), coalesce(trunc(sum(x.cb_net)), 0), count(distinct x.depot_id)
    into v_jadi, n, v_tot, n_dep from x;

  if n > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage, batch_no)
    values (null, 'zdage_expired_otomatis', jsonb_build_object(
      'detail', n || ' dokumen di Open menjadi Expired otomatis di ' || n_dep || ' depot (tidak diproses sampai 1 bulan setelah batas proses), Rp ' || rc_private.angka(v_tot),
      'jumlah', n, 'totalCb', v_tot, 'depot', n_dep, 'batch', v_batch), 'upload', 'open', 'expired', v_batch);
    -- Rekap Expired per depot (kloter 12:00 / 16:00). Kegagalannya tidak membatalkan perubahan status.
    begin
      perform rc_private.email_pengajuan_antre('expire', v_batch, v_jadi, null, v_alasan);
    exception when others then
      insert into public.activity_logs(actor_id, event_type, details)
      values (null, 'email_pengajuan_gagal', jsonb_build_object('aksi', 'expire_otomatis', 'batch', v_batch, 'sebab', left(sqlerrm, 300)));
    end;
  end if;
  return jsonb_build_object('expired', n, 'totalCb', v_tot, 'depot', n_dep, 'batch', v_batch);
end $f$;
revoke all on function rc_private.zdage_expired_otomatis() from public, anon, authenticated;

do $tambal$
declare src text;
begin
  -- ---- Job harian: sesudah menandai overdue, jalankan Expired otomatis -----------------------
  src := replace(pg_get_functiondef('rc_private.zdage_harian()'::regprocedure), E'\r', '');
  if src !~ '20261163970000' then
    src := pg_temp.ganti(src, $p$declare n integer; v_email integer := 0;$p$,
      $p$declare n integer; v_email integer := 0; v_exp jsonb := '{}'; -- 20261163970000$p$, 1, 'harian declare');
    src := pg_temp.ganti(src, $p$  return jsonb_build_object('overdue', n, 'email', v_email);$p$,
      $p$  -- 20261163970000: dokumen di Open yang lewat 1 bulan dari batas prosesnya menjadi Expired.
  begin
    v_exp := rc_private.zdage_expired_otomatis();
  exception when others then
    insert into public.activity_logs(actor_id, event_type, details)
    values (null, 'zdage_expired_gagal', jsonb_build_object('sebab', left(sqlerrm, 300)));
  end;
  return jsonb_build_object('overdue', n, 'email', v_email, 'expiredOtomatis', coalesce((v_exp->>'expired')::integer, 0));$p$, 1, 'harian expired');
    execute src;
  end if;

  -- ---- Email rekap Expired: pelaku kosong = Sistem ---------------------------------------------
  src := replace(pg_get_functiondef('rc_private.email_expired_html(bigint[],uuid,timestamp with time zone)'::regprocedure), E'\r', '');
  if src !~ '20261163970000' then
    src := pg_temp.ganti(src, $p$pr.user_code, '-') oleh,$p$,
      $p$pr.user_code, case when a.aktor is null then 'Sistem (otomatis)' else '-' end /* 20261163970000 */) oleh,$p$, 1, 'email oleh sistem');
    src := pg_temp.ganti(src, $p$group by a.id, a.dibuat_pada, a.batch, a.alasan, 5, pr.full_name, pr.user_code$p$,
      $p$group by a.id, a.dibuat_pada, a.batch, a.alasan, a.aktor, 5, pr.full_name, pr.user_code$p$, 1, 'email group');
    execute src;
  end if;

  -- ---- Tab Open: tanggal Expired otomatis di setiap baris berbatas proses ----------------------
  src := replace(pg_get_functiondef('public.rc_open_claims_filtered(text,text,integer,integer,text)'::regprocedure), E'\r', '');
  if src !~ '20261163970000' then
    src := pg_temp.ganti(src, $p$'deadline',case when di.deadline_at is null then '' else to_char(di.deadline_at at time zone 'Asia/Jakarta','DD-Mon-YYYY') end,$p$,
      $p$'deadline',case when di.deadline_at is null then '' else to_char(di.deadline_at at time zone 'Asia/Jakarta','DD-Mon-YYYY') end,
   'expiredOtomatis',case when di.deadline_at is null then '' /* 20261163970000 */
     else to_char(((di.deadline_at at time zone 'Asia/Jakarta')::date + interval '1 month')::date + 1,'DD-Mon-YYYY') end,$p$, 1, 'open expired otomatis');
    execute src;
  end if;
end $tambal$;

do $cek$
begin
  if pg_get_functiondef('rc_private.zdage_harian()'::regprocedure) !~ 'zdage_expired_otomatis' then raise exception 'GAGAL: job harian'; end if;
  if pg_get_functiondef('rc_private.email_expired_html(bigint[],uuid,timestamp with time zone)'::regprocedure) !~ 'Sistem \(otomatis\)' then raise exception 'GAGAL: email'; end if;
  if pg_get_functiondef('public.rc_open_claims_filtered(text,text,integer,integer,text)'::regprocedure) !~ 'expiredOtomatis' then raise exception 'GAGAL: open'; end if;
  if has_function_privilege('authenticated', 'rc_private.zdage_expired_otomatis()', 'execute') then raise exception 'GAGAL: hak terbuka'; end if;
end $cek$;
