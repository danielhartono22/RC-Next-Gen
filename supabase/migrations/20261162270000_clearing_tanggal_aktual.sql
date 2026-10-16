-- ==========================================================================================
-- Clearing: tanggal transfer / proses AKTUAL, dan email Done tanpa baris Campaign
-- ==========================================================================================
-- Pemilik, 12 Oktober 2026, atas contoh email Done:
--   "untuk nama campaign cukup di table aja tidak perlu diulangi di body atasnya."
--   "sertakan juga tanggal transfer / proses actual nya, selain tanggal proses system nya
--    sesuai dengan tanggal yang dipilih oleh user."
--
-- SEBELUMNYA. Layar Clearing mewajibkan "Tgl Clearing (Aktual)", tetapi tanggal itu tidak
-- pernah sampai ke server: adapter tidak meneruskannya dan mutate_claims_unchecked mencatat
-- cleared_at = waktu sistem saat tombol ditekan. Tanggal yang dipilih pengguna hilang.
--
-- SEKARANG
--   public.claims.cleared_actual_on   tanggal transfer / proses aktual pilihan pengguna, terpisah
--                                     dari cleared_at (waktu proses di sistem)
--   mutate_claims_unchecked('clearing') membaca item->>'tgl_aktual' (yyyy-mm-dd) setiap dokumen.
--     Wajib, harus tanggal yang sah, dan tidak boleh sesudah hari ini (WIB) - "aktual" berarti
--     sudah terjadi. Tanpa tanggal, Clearing ditolak dengan pesan yang jelas, bukan diam-diam
--     memakai waktu sistem seperti dulu.
--   Email Done (email_pengajuan_html 'clearing'):
--     - baris "Campaign: ..." di pembuka dihapus; nama campaign tetap ada di tabel;
--     - ditambah "Tanggal transfer / proses aktual: <tanggal>";
--     - baris waktu sistem tetap ada, berbunyi "Diproses di sistem oleh ... pada ...".
--   Email jenis lain tidak berubah.
--
-- Ditambal dengan penjaga MD5 pra-citra (sama di dev dan prod, 12 Oktober 2026).
-- ==========================================================================================

alter table public.claims add column if not exists cleared_actual_on date;
comment on column public.claims.cleared_actual_on is
  'Tanggal transfer / proses aktual Clearing yang dipilih pengguna (20261162270000). cleared_at = waktu proses di sistem.';

do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  -- mutate_claims: daftar field item yang diizinkan
  ('rc_private.mutate_claims(text,jsonb,uuid,text)', 'a7be22ff43476522f08cfc15ee4ccb02',
   $p$'top','jenis_cashback')$p$,
   $p$'top','jenis_cashback','tgl_aktual' /* 20261162270000 */)$p$, 1),

  -- mutate_claims_unchecked
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', 'e1fb65f917e3f4ccb88d49dfff85786e',
   $p$ master_top numeric; input_top numeric; master_changed boolean;$p$,
   $p$ master_top numeric; input_top numeric; master_changed boolean;
 v_tgl_aktual date; -- 20261162270000$p$, 1),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', 'e1fb65f917e3f4ccb88d49dfff85786e',
   $p$ if not found then raise exception 'Document not found'; end if;$p$,
   $p$ if not found then raise exception 'Document not found'; end if;
 -- 20261162270000: Clearing mencatat tanggal transfer/proses AKTUAL yang dipilih pengguna.
 v_tgl_aktual:=null;
 if p_action='clearing' then
  begin
   v_tgl_aktual:=nullif(btrim(coalesce(item->>'tgl_aktual','')),'')::date;
  exception when others then
   raise exception 'Tanggal transfer/proses aktual "%" tidak valid',item->>'tgl_aktual';
  end;
  if v_tgl_aktual is null then
   raise exception 'Tanggal transfer/proses aktual wajib diisi untuk Clearing. Muat ulang halaman lalu ulangi.';
  end if;
  if v_tgl_aktual>(now() at time zone 'Asia/Jakarta')::date then
   raise exception 'Tanggal transfer/proses aktual % belum terjadi',to_char(v_tgl_aktual,'DD-MM-YYYY');
  end if;
 end if;$p$, 1),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', 'e1fb65f917e3f4ccb88d49dfff85786e',
   $p$ cleared_by=case when p_action in('clearing','bulk_rebate') or ((p_action='approve' or v_langsung) and target='done') then actor else cleared_by end,$p$,
   $p$ cleared_by=case when p_action in('clearing','bulk_rebate') or ((p_action='approve' or v_langsung) and target='done') then actor else cleared_by end,
 cleared_actual_on=case when p_action='clearing' then v_tgl_aktual else cleared_actual_on end,$p$, 1),

  -- email_pengajuan_html
  ('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)', '00ee6655d1b7d3aea85965ba0f731d8c',
   $p$v_pembuka text; v_aksi text; v_campaign text; v_html text; v_judul text;$p$,
   $p$v_pembuka text; v_aksi text; v_aktual text; v_html text; v_judul text; -- 20261162270000$p$, 1),
  ('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)', '00ee6655d1b7d3aea85965ba0f731d8c',
   $p$  select string_agg(distinct coalesce(ca.campaign_name, ca.campaign_code), ', ')
    into v_campaign
    from public.claims c left join public.campaigns ca on ca.id = c.campaign_id
   where c.id = any(p_ids);$p$,
   $p$  -- 20261162270000: nama campaign cukup di tabel; yang ditampilkan di atas tabel adalah
  -- tanggal transfer/proses aktual pilihan pengguna.
  select string_agg(distinct rc_private.tgl_panjang((c.cleared_actual_on + time '12:00') at time zone 'Asia/Jakarta'), ', ')
    into v_aktual
    from public.claims c
   where c.id = any(p_ids) and c.cleared_actual_on is not null;$p$, 1),
  ('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)', '00ee6655d1b7d3aea85965ba0f731d8c',
   $p$
      || '<br>Campaign: <strong>' || rc_private.html_aman(coalesce(v_campaign,'-')) || '</strong>'$p$,
   '', 1),
  ('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)', '00ee6655d1b7d3aea85965ba0f731d8c',
   $p$    || '<p style="line-height:1.6;color:#5f6368;font-size:12px;">'
    || 'Diproses oleh <strong>'$p$,
   $p$    || case when p_action = 'clearing' then
         '<p style="line-height:1.6;">Tanggal transfer / proses aktual: <strong>'
         || rc_private.html_aman(coalesce(v_aktual,'-')) || '</strong></p>' else '' end
    || '<p style="line-height:1.6;color:#5f6368;font-size:12px;">'
    || case when p_action = 'clearing' then 'Diproses di sistem oleh <strong>' else 'Diproses oleh <strong>' end$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261162270000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(src, E'\r', '')); end if;
    baru := replace(src, E'\r', '');
    for r in select * from _tambal where sig = f.sig order by urut loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> r.n then
        raise exception '%: pola "%" ditemukan % kali, diharapkan %.', f.sig, left(r.lama, 80), n, r.n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
    execute baru;
  end loop;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (dibatalkan seluruhnya): Clearing menyimpan tanggal aktual, menolak tanggal kosong
-- dan tanggal yang belum terjadi; email Done memuat tanggal aktual tanpa baris Campaign.
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; d record; e text := ''; h jsonb; v_html text; v_tgl date;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  if v_sm is null then raise notice 'Tidak ada System Manager aktif; uji dilewati.'; return; end if;

  -- Email: dua dokumen apa pun, tanggal aktual dipasang sementara.
  begin
    update public.claims set cleared_actual_on = date '2026-10-10'
     where id in (select id from public.claims where archived_at is null and customer_id is not null order by no_doc limit 2);
    v_html := rc_private.email_pengajuan_html('clearing', 'BATCHUJI',
      array(select id from public.claims where cleared_actual_on = date '2026-10-10' limit 2), v_sm, '');
    if v_html !~ 'Tanggal transfer / proses aktual: <strong>10 Oktober 2026</strong>' then e := e || ' email tanpa tanggal aktual;'; end if;
    if v_html ~ 'Campaign: <strong>' then e := e || ' email masih memuat baris Campaign;'; end if;
    if v_html !~ 'Diproses di sistem oleh' then e := e || ' email tanpa waktu sistem;'; end if;
    if v_html !~ 'NAMA CAMPAIGN' then e := e || ' tabel campaign hilang;'; end if;
    v_html := rc_private.email_pengajuan_html('approve', 'BATCHUJI',
      array(select id from public.claims where cleared_actual_on = date '2026-10-10' limit 2), v_sm, '');
    if v_html ~ 'Tanggal transfer' or v_html !~ 'Diproses oleh <strong>' then e := e || ' email approve ikut berubah;'; end if;
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then e := e || ' galat email: ' || sqlerrm; end if;
  end;

  -- Clearing sungguhan pada satu dokumen Claimed.
  select c.no_doc, c.version_no into d from public.claims c join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'claimed' and c.archived_at is null and c.customer_id is not null and ca.status = 'active'
     and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) <> 'rebate'
   order by c.no_doc limit 1;
  if d.no_doc is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    begin
      begin
        h := public.rc_process_claims('clearing', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', d.version_no)), gen_random_uuid(), '');
        e := e || ' clearing tanpa tanggal diterima;';
      exception when others then
        if sqlerrm !~ 'wajib diisi' then e := e || ' tanpa tanggal: ' || sqlerrm || ';'; end if;
      end;
      begin
        h := public.rc_process_claims('clearing', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', d.version_no,
               'tgl_aktual', to_char((now() at time zone 'Asia/Jakarta')::date + 3, 'YYYY-MM-DD'))), gen_random_uuid(), '');
        e := e || ' tanggal masa depan diterima;';
      exception when others then
        if sqlerrm !~ 'belum terjadi' then e := e || ' masa depan: ' || sqlerrm || ';'; end if;
      end;
      h := public.rc_process_claims('clearing', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', d.version_no,
             'tgl_aktual', to_char((now() at time zone 'Asia/Jakarta')::date - 2, 'YYYY-MM-DD'))), gen_random_uuid(), '');
      select cleared_actual_on into v_tgl from public.claims where no_doc = d.no_doc;
      if v_tgl is distinct from (now() at time zone 'Asia/Jakarta')::date - 2 then e := e || format(' tanggal aktual tersimpan %s;', v_tgl); end if;
      raise exception 'UJI_SELESAI';
    exception when others then
      if sqlerrm <> 'UJI_SELESAI' then e := e || ' galat clearing: ' || sqlerrm; end if;
    end;
    perform set_config('request.jwt.claims', '', true);
  else
    raise notice 'Tidak ada dokumen Claimed untuk diuji; uji clearing dilewati.';
  end if;

  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
