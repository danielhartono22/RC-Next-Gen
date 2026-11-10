-- ==========================================================================================
-- Backup harian ke Google Drive: data Document Center dan Log Activity yang berubah
-- ==========================================================================================
-- Pemilik, 9 November 2026: "buat back up data yang berubah setiap hari range jam 2 maks jam 4 untuk data
-- document center dan log activity di google drive".
-- * Cron 02:00 dan 03:00 WIB. Percobaan 03:00 hanya bekerja bila 02:00 gagal, jadi selesai sebelum 04:00.
-- * Yang dicadangkan: klaim yang berubah (created_at / updated_at) dan Log Activity baru sejak backup
--   terakhir yang berhasil (pertama kali: 24 jam terakhir). Tiap jenis satu berkas CSV UTF-8. Bila
--   tidak ada perubahan, berkasnya tidak dibuat.
-- * Tujuan: folder RC_Backup di Drive akun pengirim email (token Gmail yang sudah ada, izin drive.file).
-- * rc_private.sapu_drive menghapus SEMUA berkas aplikasi yang berumur lebih dari satu jam, jadi
--   berkas dan folder "RC_Backup" dikecualikan.
-- * Hasilnya tercatat di rc_private.backup_drive_log dan satu baris Log Activity per proses.
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

create table if not exists rc_private.backup_drive_setelan (
  id boolean primary key default true check (id),
  nama_folder text not null default 'RC_Backup',
  folder_id text
);
insert into rc_private.backup_drive_setelan(id) values (true) on conflict do nothing;

create table if not exists rc_private.backup_drive_log (
  id bigserial primary key,
  mulai timestamptz not null default now(),
  selesai timestamptz,
  status text not null default 'berjalan' check (status in ('berjalan', 'berhasil', 'gagal')),
  dari timestamptz,
  sampai timestamptz,
  n_klaim integer,
  n_log integer,
  berkas jsonb,
  pesan text
);
revoke all on rc_private.backup_drive_setelan, rc_private.backup_drive_log from public, anon, authenticated;

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.sapu_drive()'::regprocedure), E'\r', '');
  if src !~ 'RC_Backup' then
    src := pg_temp.ganti(src, $p$|| '''')$p$, $p$|| ''' and not name contains ''RC_Backup''')$p$, 1, 'sapu');
    execute src;
  end if;
end $tambal$;

create or replace function rc_private.csv_sel(p anyelement) returns text
language sql immutable set search_path to '' as $f$
  select '"' || replace(coalesce(p::text, ''), '"', '""') || '"';
$f$;

-- Kolom sama dengan unduhan Document Center (kecuali Tagihan), ditambah Arsip dan Diubah.
create or replace function rc_private.backup_csv_klaim(p_dari timestamptz, p_sampai timestamptz, out isi text, out n integer)
language plpgsql stable security definer set search_path to '' as $f$
begin
  select coalesce(string_agg(z.b, E'\r\n' order by z.b), ''), count(*) into isi, n from (
    select concat_ws(',', rc_private.csv_sel(c.no_doc), rc_private.csv_sel(rc_private.legacy_status(c.status)), rc_private.csv_sel(d.depot_code), rc_private.csv_sel(d.depot_name),
      rc_private.csv_sel(coalesce(cu.customer_code, c.source_customer_code)), rc_private.csv_sel(cu.customer_name), rc_private.csv_sel(ca.campaign_code), rc_private.csv_sel(ca.campaign_name),
      rc_private.csv_sel(rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type))), rc_private.csv_sel(coalesce(c.tax_subject, cu.tax_subject)),
      rc_private.csv_sel(trunc(c.cb_net)), rc_private.csv_sel(trunc(c.gross_up)), rc_private.csv_sel(rk.j->>'bank'), rc_private.csv_sel(rk.j->>'noRek'), rc_private.csv_sel(rk.j->>'namaRek'),
      rc_private.csv_sel(c.batch_upload), rc_private.csv_sel(c.batch_release), rc_private.csv_sel(c.batch_claim), rc_private.csv_sel(c.batch_clearing),
      rc_private.csv_sel(d.region), rc_private.csv_sel(cu.contact_person), rc_private.csv_sel(ca.tax_status), rc_private.csv_sel(trunc(c.net_value)), rc_private.csv_sel(c.volume), rc_private.csv_sel(trunc(c.total_billing)),
      rc_private.csv_sel(rc_private.legacy_ts(c.uploaded_at)), rc_private.csv_sel(rc_private.legacy_ts(c.cleared_at)), rc_private.csv_sel(rc_private.legacy_date(c.cleared_actual_on)),
      rc_private.csv_sel(to_char(c.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI')), rc_private.csv_sel(p.user_code),
      rc_private.csv_sel(rc_private.claim_remark(c)), rc_private.csv_sel(c.version_no), rc_private.csv_sel(c.archived_at is not null),
      rc_private.csv_sel(to_char(greatest(c.created_at, c.updated_at) at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI:SS'))) b
    from public.claims c
    join public.depots d on d.id = c.depot_id
    join public.campaigns ca on ca.id = c.campaign_id
    left join public.customers cu on cu.id = c.customer_id
    left join public.profiles p on p.id = c.created_by
    left join rc_private.claim_sensitive s on s.claim_id = c.id
    cross join lateral (select rc_private.rekening_tampil(s.account_number, s.account_name, s.bank, cu.account_number, cu.account_name, cu.bank) j) rk
   where greatest(c.created_at, c.updated_at) >= p_dari and greatest(c.created_at, c.updated_at) < p_sampai) z;
  if n > 0 then
    isi := '"No Doc","Status","Kode Depot","Nama Depot","Kode Toko","Nama Toko","Kode Campaign","Nama Campaign","Jenis CB","Subyek Pajak","Cashback","Gross Up","Bank","No Rekening","Nama Rekening",'
      || '"Batch Upload","Batch Release","Batch Claim","Batch Clearing","Region","Contact Person","Status Pajak","Net Value","Volume","Total Tagihan","Tgl Upload","Tgl Done","Tgl Transfer / Proses Aktual","Created On","Created By",'
      || '"Remark","Version","Diarsip","Diubah"' || E'\r\n' || isi;
  end if;
end $f$;

create or replace function rc_private.backup_csv_log(p_dari timestamptz, p_sampai timestamptz, out isi text, out n integer)
language plpgsql stable security definer set search_path to '' as $f$
begin
  select coalesce(string_agg(z.b, E'\r\n' order by z.t), ''), count(*) into isi, n from (
    select l.created_at t, concat_ws(',', rc_private.csv_sel(to_char(l.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI:SS')), rc_private.csv_sel(p.user_code), rc_private.csv_sel(l.event_type),
      rc_private.csv_sel(l.module), rc_private.csv_sel(l.tab), rc_private.csv_sel(l.process_stage), rc_private.csv_sel(l.batch_no), rc_private.csv_sel(d.depot_code), rc_private.csv_sel(l.details::text)) b
    from public.activity_logs l left join public.profiles p on p.id = l.actor_id left join public.depots d on d.id = l.depot_id
   where l.created_at >= p_dari and l.created_at < p_sampai) z;
  if n > 0 then isi := '"Waktu","User","Event","Module","Tab","Stage","Batch","Depot","Details"' || E'\r\n' || isi; end if;
end $f$;

create or replace function rc_private.backup_unggah(p_nama text, p_isi text, p_folder text, p_tok text) returns text
language plpgsql security definer set search_path to '' as $f$
declare r extensions.http_response; B constant text := 'RCBAK' || replace(gen_random_uuid()::text, '-', '');
begin
  select * into r from extensions.http(('POST', 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart',
    array[extensions.http_header('Authorization', 'Bearer ' || p_tok)], 'multipart/related; boundary=' || B,
    '--' || B || E'\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'
      || jsonb_build_object('name', p_nama, 'parents', jsonb_build_array(p_folder), 'mimeType', 'text/csv')::text || E'\r\n--' || B
      || E'\r\nContent-Type: text/csv; charset=UTF-8\r\n\r\n' || chr(65279) || p_isi || E'\r\n--' || B || '--')::extensions.http_request);
  if r.status <> 200 then raise exception 'Unggah % gagal: % %', p_nama, r.status, left(r.content, 200); end if;
  return (r.content::jsonb)->>'id';
end $f$;

-- Satu kali backup. Token harus sudah tersedia (rc_backup_harian yang memintanya).
create or replace function rc_private.backup_jalankan() returns jsonb
language plpgsql security definer set search_path to '' as $f$
declare v_tok text := rc_private.gmail_token(); r extensions.http_response; st rc_private.backup_drive_setelan; v_folder text;
  v_dari timestamptz; v_sampai timestamptz := now(); k record; l record; v_berkas jsonb := '[]'; v_tgl text := to_char(now() at time zone 'Asia/Jakarta', 'YYYYMMDD_HH24MI');
  v_id bigint; v_q text;
begin
  if v_tok is null then raise exception 'Access token Google belum tersedia'; end if;
  perform rc_private.http_siapkan();
  select coalesce(max(sampai), now() - interval '24 hours') into v_dari from rc_private.backup_drive_log where status = 'berhasil';
  insert into rc_private.backup_drive_log(dari, sampai) values (v_dari, v_sampai) returning id into v_id;

  select * into st from rc_private.backup_drive_setelan;
  v_folder := st.folder_id;
  if v_folder is null then
    v_q := 'name = ''' || st.nama_folder || ''' and mimeType = ''application/vnd.google-apps.folder'' and trashed = false';
    select * into r from extensions.http(('GET', 'https://www.googleapis.com/drive/v3/files?q=' || extensions.urlencode(v_q) || '&fields=files(id)&pageSize=1',
      array[extensions.http_header('Authorization', 'Bearer ' || v_tok)], null, null)::extensions.http_request);
    if r.status = 200 then v_folder := (r.content::jsonb)->'files'->0->>'id'; end if;
    if v_folder is null then
      select * into r from extensions.http(('POST', 'https://www.googleapis.com/drive/v3/files',
        array[extensions.http_header('Authorization', 'Bearer ' || v_tok)], 'application/json',
        jsonb_build_object('name', st.nama_folder, 'mimeType', 'application/vnd.google-apps.folder')::text)::extensions.http_request);
      if r.status <> 200 then raise exception 'Folder Drive gagal dibuat: % %', r.status, left(r.content, 200); end if;
      v_folder := (r.content::jsonb)->>'id';
    end if;
    update rc_private.backup_drive_setelan set folder_id = v_folder;
  end if;

  select * into k from rc_private.backup_csv_klaim(v_dari, v_sampai);
  select * into l from rc_private.backup_csv_log(v_dari, v_sampai);
  if k.n > 0 then v_berkas := v_berkas || jsonb_build_object('nama', 'RC_Backup_DocumentCenter_' || v_tgl || '.csv', 'id', rc_private.backup_unggah('RC_Backup_DocumentCenter_' || v_tgl || '.csv', k.isi, v_folder, v_tok)); end if;
  if l.n > 0 then v_berkas := v_berkas || jsonb_build_object('nama', 'RC_Backup_LogActivity_' || v_tgl || '.csv', 'id', rc_private.backup_unggah('RC_Backup_LogActivity_' || v_tgl || '.csv', l.isi, v_folder, v_tok)); end if;

  update rc_private.backup_drive_log set selesai = now(), status = 'berhasil', n_klaim = k.n, n_log = l.n, berkas = v_berkas where id = v_id;
  insert into public.activity_logs(event_type, details, module, tab)
  values ('backup_drive', jsonb_build_object('detail', 'Backup harian ke Google Drive: ' || k.n || ' dokumen, ' || l.n || ' log', 'dari', v_dari, 'sampai', v_sampai, 'berkas', v_berkas), 'access', 'backup');
  return jsonb_build_object('status', 'success', 'klaim', k.n, 'log', l.n, 'berkas', v_berkas, 'folder', v_folder);
end $f$;
revoke all on function rc_private.backup_jalankan(), rc_private.backup_unggah(text, text, text, text), rc_private.backup_csv_klaim(timestamptz, timestamptz), rc_private.backup_csv_log(timestamptz, timestamptz) from public, anon, authenticated;

-- Dipanggil cron. Prosedur karena permintaan token harus di-commit dulu supaya terlihat pg_net.
create or replace procedure public.rc_backup_harian(p_paksa boolean default false)
language plpgsql as $pr$
declare v_req bigint;
begin
  if not p_paksa and exists(select 1 from rc_private.backup_drive_log where status = 'berhasil' and mulai > now() - interval '12 hours') then return; end if;
  v_req := rc_private.gmail_token_minta();
  if v_req is not null then
    commit;
    perform pg_catalog.pg_sleep(3);
    perform rc_private.gmail_token_ambil(v_req);
    commit;
  end if;
  begin
    perform rc_private.backup_jalankan();
  exception when others then
    insert into rc_private.backup_drive_log(selesai, status, pesan) values (now(), 'gagal', left(sqlerrm, 500));
    insert into public.activity_logs(event_type, details, module, tab)
    values ('backup_drive_gagal', jsonb_build_object('detail', 'Backup harian ke Google Drive gagal: ' || left(sqlerrm, 300)), 'access', 'backup');
  end;
  commit;
end $pr$;
revoke all on procedure public.rc_backup_harian(boolean) from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'rc_backup_drive';
select cron.schedule('rc_backup_drive', '0 19,20 * * *', 'call public.rc_backup_harian()');
