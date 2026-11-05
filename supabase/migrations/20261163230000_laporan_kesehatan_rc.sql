-- ==========================================================================================
-- Laporan Kesehatan RC (RC Health Report): email harian berbasis aturan - outlier, customer
-- tanpa master, bug, prediksi risiko bug
-- ==========================================================================================
-- Pemilik, 20 Oktober 2026: "report harian ke email sa_sd1@nipponpaint-indonesia.com mengenai
-- data outlier, customer yang tidak ada masternya, deretan bug dan prediksi bug apapun mengenai
-- rc tiap jam 8 pagi senin sampai jumat". Mesin analisa: "Aturan saja (tanpa AI)". Revisi hari
-- yang sama: penerima CC dapat diatur sendiri, pembuka "Hi Daniel, We would like to share ...",
-- isi beserta statistiknya dan subjek dalam bahasa Inggris.
--
-- Menumpang mesin email yang sudah ada:
--  * jenis email baru 'kesehatan' di email_settings (jam 8, Senin-Jumat) dengan kolom baru
--    `tujuan` (To tetap - laporan ini tidak mengikuti alamat depot); CC memakai cc_tambahan baris
--    'kesehatan'. Keduanya diubah dari panel Email Otomatis (rc_email_settings_simpan);
--  * rc_email_tick menyusunnya pada jamnya, pengirim tiap menit (rc_email_proses) mengirimnya;
--  * tanpa lampiran PDF.
--
-- Isi (periode pemantauan: 24 jam terakhir; Senin sejak Jumat, 72 jam):
--  0. Key Statistics: klaim aktif, dokumen baru, Done / Expired, Not Yet, user aktif, email.
--  1. Data Outliers: CB > Net Value, CB > 20x median campaign, Not Yet dengan CB 0, potensi
--     dobel - total dan yang baru / berubah dalam periode, beserta contoh teratas.
--  2. Customers Without Master: per depot dan per kode toko.
--  3. Bugs & Incidents dalam periode: jadwal pg_cron gagal, email gagal / tertahan / menumpuk,
--     akun tersuspend, status klaim tanpa tanggal prosesnya.
--  4. Bug Risk Prediction: fungsi aplikasi mendekati batas 8 detik (pg_stat_statements), master
--     dan pengaturan yang akan memicu penolakan / penahanan, akun berisiko, jadwal yang gagal.
-- Laporan yang gagal disusun tetap dikirim berisi sebab kegagalannya.
--
-- Penjaga MD5 pra-citra (sama di dev dan prod, 20 Oktober 2026): rc_email_susun 147e7040,
-- rc_email_status 1bd52777, email_perlu_pdf 332b577a, rc_email_settings_simpan 9751970b.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- 1. Pengaturan ----------------------------------------------------------------------
alter table public.email_settings drop constraint if exists email_settings_jenis_check;
alter table public.email_settings add constraint email_settings_jenis_check
  check (jenis = any (array['daily','weekly','timetable','pengajuan','kesehatan']));
alter table public.email_settings add column if not exists tujuan text[] not null default '{}';
comment on column public.email_settings.tujuan is
  'Penerima tetap (To) untuk jenis email yang tidak mengikuti alamat depot (20261163230000: kesehatan).';

insert into public.email_settings(jenis, aktif, jam, subjek, hari_list, tujuan, cc_tambahan)
values ('kesehatan', true, 8, 'RC Health Report - Outliers, Customers Without Master & Bugs',
        '{1,2,3,4,5}', array['sa_sd1@nipponpaint-indonesia.com'], '{}')
on conflict (jenis) do update set subjek = excluded.subjek
 where public.email_settings.subjek = 'RC Health Report - Outlier, Customer Tanpa Master & Bug';

-- ---- 2. Pembantu --------------------------------------------------------------------------
-- Angka dan rupiah gaya Inggris (koma ribuan), dipotong tanpa desimal.
create or replace function rc_private.kes_angka(n numeric)
returns text language sql immutable set search_path = '' as $f$
  select case when coalesce(n, 0) < 0 then '-' else '' end || to_char(trunc(abs(coalesce(n, 0))), 'FM999,999,999,999,990');
$f$;
create or replace function rc_private.kes_rp(n numeric)
returns text language sql immutable set search_path = '' as $f$
  select case when coalesce(n, 0) < 0 then '-' else '' end || 'Rp ' || rc_private.kes_angka(abs(coalesce(n, 0)));
$f$;
create or replace function rc_private.kes_tgl(t timestamptz)
returns text language sql stable set search_path = '' as $f$
  select to_char(t at time zone 'Asia/Jakarta', 'FMDD FMMonth YYYY');
$f$;

-- Daftar alamat dari larik JSON atau teks (dipisah koma / titik koma / spasi): dirapikan,
-- diperiksa, tanpa kembar, maksimal 10.
create or replace function rc_private.kes_alamat(p jsonb)
returns text[] language plpgsql immutable set search_path = '' as $f$
declare v text[] := '{}'; x text;
begin
  if p is null or jsonb_typeof(p) = 'null' then return '{}'; end if;
  for x in
    select lower(btrim(t))
      from regexp_split_to_table(
             case jsonb_typeof(p) when 'array' then (select string_agg(value #>> '{}', ',') from jsonb_array_elements(p))
                                  else p #>> '{}' end, '[,;\s]+') t
     where btrim(t) <> ''
  loop
    if x !~ '^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$' then raise exception 'Alamat email tidak sah: %', x; end if;
    if not (x = any(v)) then v := v || x; end if;
  end loop;
  if cardinality(v) > 10 then raise exception 'Maksimal 10 alamat email (diterima %)', cardinality(v); end if;
  return v;
end $f$;

-- p_baris: larik JSON berisi larik sel (teks). Seluruh sel di-escape.
create or replace function rc_private.kes_tabel(p_kepala text[], p_baris jsonb, p_kosong text default 'None.')
returns text language sql immutable set search_path = '' as $f$
  select case when coalesce(jsonb_array_length(p_baris), 0) = 0
    then '<p style="font-size:13px;color:#5f6368;margin:6px 0 16px;">' || rc_private.html_aman(p_kosong) || '</p>'
    else '<table cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;width:100%;margin:6px 0 16px;font-size:12px;">'
      || '<tr>' || (select string_agg('<th align="left" style="background:#f1f3f4;border:1px solid #dadce0;padding:6px 8px;white-space:nowrap;">'
                                      || rc_private.html_aman(k) || '</th>', '' order by i)
                      from unnest(p_kepala) with ordinality u(k, i)) || '</tr>'
      || (select string_agg('<tr>' || (select string_agg('<td style="border:1px solid #dadce0;padding:6px 8px;vertical-align:top;">'
                                                          || rc_private.html_aman(sel) || '</td>', '' order by j)
                                         from jsonb_array_elements_text(b) with ordinality v(sel, j)) || '</tr>', '' order by n)
            from jsonb_array_elements(p_baris) with ordinality w(b, n))
      || '</table>' end;
$f$;

create or replace function rc_private.kes_judul(p_teks text)
returns text language sql immutable set search_path = '' as $f$
  select '<h3 style="font-size:15px;color:#b3261e;margin:22px 0 4px;border-bottom:2px solid #b3261e;padding-bottom:4px;">'
         || rc_private.html_aman(p_teks) || '</h3>';
$f$;

create or replace function rc_private.kes_sub(p_teks text)
returns text language sql immutable set search_path = '' as $f$
  select '<p style="font-size:13px;font-weight:bold;margin:4px 0;">' || rc_private.html_aman(p_teks) || '</p>';
$f$;

revoke all on function rc_private.kes_angka(numeric), rc_private.kes_rp(numeric), rc_private.kes_tgl(timestamptz),
  rc_private.kes_alamat(jsonb), rc_private.kes_tabel(text[], jsonb, text), rc_private.kes_judul(text),
  rc_private.kes_sub(text) from public, anon, authenticated;

-- ---- 3. Isi laporan -----------------------------------------------------------------------
create or replace function rc_private.email_kesehatan_isi(p_dari timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare
  v_html text := ''; v_t jsonb; v_t2 jsonb; v_n jsonb;
  v_out_baru bigint; v_tm_total bigint; v_tm_baru bigint; v_gangguan bigint; v_risiko bigint;
  v_reset timestamptz;
begin
  -- ===== 0. Key statistics =====
  select jsonb_build_array(
    jsonb_build_array('Active claims', rc_private.kes_angka(count(*)), rc_private.kes_rp(sum(cb_net))),
    jsonb_build_array('New documents in this period', rc_private.kes_angka(count(*) filter (where created_at >= p_dari)),
                      rc_private.kes_rp(sum(cb_net) filter (where created_at >= p_dari))),
    jsonb_build_array('Outstanding Not Yet', rc_private.kes_angka(count(*) filter (where status = 'not_yet')),
                      rc_private.kes_rp(sum(cb_net) filter (where status = 'not_yet'))),
    jsonb_build_array('Moved to Done in this period', rc_private.kes_angka(x.done_n), rc_private.kes_rp(x.done_cb)),
    jsonb_build_array('Moved to Expired in this period', rc_private.kes_angka(x.exp_n), rc_private.kes_rp(x.exp_cb)),
    jsonb_build_array('Active users in this period', rc_private.kes_angka(x.user_n), '-'),
    jsonb_build_array('Emails sent in this period', rc_private.kes_angka(x.mail_n), '-'))
    into v_t
    from public.claims c,
         (select (select count(distinct h.claim_id) from public.claim_status_history h
                   where h.to_status = 'done' and h.from_status is distinct from 'done' and h.created_at >= p_dari) done_n,
                 (select sum(c2.cb_net) from public.claims c2 where c2.id in (
                    select h.claim_id from public.claim_status_history h
                     where h.to_status = 'done' and h.from_status is distinct from 'done' and h.created_at >= p_dari)) done_cb,
                 (select count(distinct h.claim_id) from public.claim_status_history h
                   where h.to_status = 'expired' and h.from_status is distinct from 'expired' and h.created_at >= p_dari) exp_n,
                 (select sum(c2.cb_net) from public.claims c2 where c2.id in (
                    select h.claim_id from public.claim_status_history h
                     where h.to_status = 'expired' and h.from_status is distinct from 'expired' and h.created_at >= p_dari)) exp_cb,
                 (select count(distinct l.actor_id) from public.activity_logs l where l.created_at >= p_dari and l.actor_id is not null) user_n,
                 (select count(*) from public.email_outbox o where o.status = 'sent' and o.dikirim_pada >= p_dari) mail_n) x
   where c.archived_at is null
   group by x.done_n, x.done_cb, x.exp_n, x.exp_cb, x.user_n, x.mail_n;

  v_html := v_html || rc_private.kes_judul('Key Statistics')
    || rc_private.kes_tabel(array['Metric', 'Documents', 'Total CB'], v_t);

  -- ===== 1. Data outliers =====
  with med as (
    select campaign_id, percentile_cont(0.5) within group (order by cb_net) m, count(*) n
      from public.claims where archived_at is null and cb_net > 0 group by 1
  ), k as (
    select (c.net_value > 0 and c.cb_net > c.net_value) r1,
           (m.n >= 10 and m.m > 0 and c.cb_net > 20 * m.m) r2,
           (c.status = 'not_yet' and coalesce(c.cb_net, 0) = 0) r3,
           greatest(c.created_at, c.updated_at) >= p_dari baru
      from public.claims c left join med m on m.campaign_id = c.campaign_id
     where c.archived_at is null
  ), dobel as (
    select greatest(c.created_at, c.updated_at) >= p_dari baru
      from public.claims c
     where c.archived_at is null and c.status = 'not_yet'
       and (c.campaign_id, coalesce(c.customer_id::text, c.source_customer_code)) in (
         select campaign_id, coalesce(customer_id::text, source_customer_code) from public.claims
          where archived_at is null and status = 'not_yet' group by 1, 2 having count(*) > 1)
  )
  select jsonb_build_array(
    jsonb_build_array('CB exceeds Net Value (possible net value input error)', rc_private.kes_angka(count(*) filter (where r1)), rc_private.kes_angka(count(*) filter (where r1 and baru))),
    jsonb_build_array('CB more than 20x its campaign median', rc_private.kes_angka(count(*) filter (where r2)), rc_private.kes_angka(count(*) filter (where r2 and baru))),
    jsonb_build_array('Not Yet with CB 0', rc_private.kes_angka(count(*) filter (where r3)), rc_private.kes_angka(count(*) filter (where r3 and baru))),
    jsonb_build_array('Possible duplicate: same store + campaign on more than one Not Yet document',
      rc_private.kes_angka((select count(*) from dobel)), rc_private.kes_angka((select count(*) from dobel where baru)))),
    count(*) filter (where (r1 or r2 or r3) and baru) + (select count(*) from dobel where baru)
    into v_t, v_out_baru from k;

  with med as (
    select campaign_id, percentile_cont(0.5) within group (order by cb_net) m, count(*) n
      from public.claims where archived_at is null and cb_net > 0 group by 1
  ), k as (
    select c.no_doc, d.depot_code, coalesce(cu.customer_code, c.source_customer_code) toko, ca.campaign_code,
           c.status, c.cb_net, c.net_value,
           case when c.net_value > 0 and c.cb_net > c.net_value then 'CB > Net Value' else 'CB > 20x median' end aturan,
           greatest(c.created_at, c.updated_at) >= p_dari baru
      from public.claims c
      join public.depots d on d.id = c.depot_id
      left join public.customers cu on cu.id = c.customer_id
      left join public.campaigns ca on ca.id = c.campaign_id
      left join med m on m.campaign_id = c.campaign_id
     where c.archived_at is null
       and ((c.net_value > 0 and c.cb_net > c.net_value) or (m.n >= 10 and m.m > 0 and c.cb_net > 20 * m.m))
     order by (greatest(c.created_at, c.updated_at) >= p_dari) desc, c.cb_net desc nulls last
     limit 10)
  select coalesce(jsonb_agg(jsonb_build_array(no_doc, depot_code, coalesce(toko, '-'), coalesce(campaign_code, '-'), rc_private.legacy_status(status),
           rc_private.kes_rp(cb_net), rc_private.kes_rp(net_value), aturan || case when baru then ' (new/changed)' else '' end)), '[]')
    into v_t2 from k;

  v_html := v_html || rc_private.kes_judul('1. Data Outliers')
    || '<p style="font-size:12px;color:#5f6368;margin:0 0 6px;">"New/changed" = documents created or modified during the monitoring period.</p>'
    || rc_private.kes_tabel(array['Rule', 'Total', 'New/changed'], v_t)
    || rc_private.kes_sub('Top examples (new/changed first, then largest CB)')
    || rc_private.kes_tabel(array['No Doc', 'Depot', 'Store Code', 'Campaign', 'Status', 'CB', 'Net Value', 'Rule'], v_t2,
                            'No CB outliers.');

  -- ===== 2. Customers without master =====
  select count(*), count(*) filter (where c.created_at >= p_dari) into v_tm_total, v_tm_baru
    from public.claims c where c.archived_at is null and c.customer_id is null;

  select coalesce(jsonb_agg(jsonb_build_array(x.depot, rc_private.kes_angka(x.dok), rc_private.kes_angka(x.toko), rc_private.kes_rp(x.cb), rc_private.kes_angka(x.baru))
                            order by x.dok desc), '[]')
    into v_t
    from (select d.depot_code || ' - ' || d.depot_name depot, count(*) dok, count(distinct c.source_customer_code) toko,
                 sum(c.cb_net) cb, count(*) filter (where c.created_at >= p_dari) baru
            from public.claims c join public.depots d on d.id = c.depot_id
           where c.archived_at is null and c.customer_id is null
           group by 1 order by 2 desc limit 10) x;

  select coalesce(jsonb_agg(jsonb_build_array(x.toko, x.depot, rc_private.kes_angka(x.dok), rc_private.kes_angka(x.notyet), rc_private.kes_rp(x.cb))
                            order by x.dok desc, x.cb desc), '[]')
    into v_t2
    from (select coalesce(c.source_customer_code, '(empty)') toko, string_agg(distinct d.depot_code, ', ') depot, count(*) dok,
                 count(*) filter (where c.status = 'not_yet') notyet, sum(c.cb_net) cb
            from public.claims c join public.depots d on d.id = c.depot_id
           where c.archived_at is null and c.customer_id is null
           group by 1 order by 3 desc, 5 desc limit 10) x;

  v_html := v_html || rc_private.kes_judul('2. Customers Without Master')
    || '<p style="font-size:13px;margin:0 0 6px;"><b>' || rc_private.kes_angka(v_tm_total) || '</b> documents are not yet linked to a Customer Master'
    || ' (<b>' || rc_private.kes_angka(v_tm_baru) || '</b> new in this period). Complete them in Key Master &gt; Customer Master;'
    || ' the claims are linked automatically when the master is saved.</p>'
    || rc_private.kes_sub('By depot (top 10)')
    || rc_private.kes_tabel(array['Depot', 'Documents', 'Store Codes', 'Total CB', 'New'], v_t, 'Every claim has a Customer Master.')
    || rc_private.kes_sub('By store code (top 10)')
    || rc_private.kes_tabel(array['Store Code', 'Depot', 'Documents', 'Not Yet', 'Total CB'], v_t2, 'None.');

  -- ===== 3. Bugs and incidents =====
  select coalesce(jsonb_agg(x.baris order by x.urut), '[]'), coalesce(sum(x.n), 0) into v_t, v_gangguan from (
    select 1 urut, count(*) n, jsonb_build_array('Failed schedule: ' || j.jobname, rc_private.kes_angka(count(*)),
             to_char(max(d.start_time) at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
             left(split_part(min(d.return_message), E'\n', 1), 160)) baris
      from cron.job_run_details d join cron.job j on j.jobid = d.jobid
     where d.status = 'failed' and d.start_time >= p_dari
     group by j.jobname
    union all
    select 2, count(*), jsonb_build_array('Email failed to send (' || o.jenis || ')', rc_private.kes_angka(count(*)),
             to_char(max(o.dibuat_pada) at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), left(max(o.galat), 160))
      from public.email_outbox o where o.status = 'failed' and o.dibuat_pada >= p_dari group by o.jenis
    union all
    select 3, count(*), jsonb_build_array('Email not sent (' || o.jenis || ')', rc_private.kes_angka(count(*)),
             to_char(max(o.dibuat_pada) at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), left(max(o.galat), 160))
      from public.email_outbox o
     where o.status = 'skipped' and o.dibuat_pada >= p_dari and coalesce(o.galat, '') <> ''
       and coalesce(o.konteks->>'preview', '') <> 'true' and o.galat not like 'Lingkungan DEV%'
     group by o.jenis
    union all
    select 4, count(*), jsonb_build_array('Emails queued for more than 15 minutes', rc_private.kes_angka(count(*)),
             to_char(min(o.dibuat_pada) at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), left(max(o.galat), 160))
      from public.email_outbox o where o.status = 'pending' and o.dibuat_pada < now() - interval '15 minutes'
     having count(*) > 0
    union all
    select 5, count(*), jsonb_build_array('Submission emails held (no recipient)', rc_private.kes_angka(count(*)),
             to_char(max(l.created_at) at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), left(max(l.details->>'sebab'), 160))
      from public.activity_logs l where l.event_type = 'email_pengajuan_tanpa_tujuan' and l.created_at >= p_dari
     having count(*) > 0
    union all
    select 6, count(*), jsonb_build_array('Accounts suspended (3 wrong PINs)', rc_private.kes_angka(count(*)),
             to_char(max(l.created_at) at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), '')
      from public.activity_logs l where l.event_type = 'akun_suspended' and l.created_at >= p_dari
     having count(*) > 0
    union all
    -- Status tanpa tanggal prosesnya: tanda proses yang tidak lengkap (bug), bukan salah input.
    select 7, s.n, jsonb_build_array('Status ' || s.st || ' without ' || s.kol, rc_private.kes_angka(s.n),
             rc_private.kes_angka(s.total) || ' total', 'Changed in this period, e.g. ' || coalesce(s.contoh, '-'))
      from (select x.st, x.kol, count(*) filter (where x.baru) n, count(*) total,
                   min(x.no_doc) filter (where x.baru) contoh
              from (select c.no_doc, c.updated_at >= p_dari baru,
                           case when c.status = 'done' then 'Done' when c.status = 'claimed' then 'Claimed'
                                when c.status = 'released' then 'Released' else 'Approved' end st,
                           case c.status when 'done' then 'Done Date' when 'claimed' then 'Claim Date'
                                when 'released' then 'Release Date' else 'Approval Date' end kol
                      from public.claims c
                     where c.archived_at is null
                       and ((c.status = 'done' and c.cleared_at is null) or (c.status = 'claimed' and c.claimed_at is null)
                         or (c.status = 'released' and c.released_at is null) or (c.status = 'approved' and c.approved_at is null))) x
             group by x.st, x.kol) s
     where s.n > 0
  ) x;

  v_html := v_html || rc_private.kes_judul('3. Bugs & Incidents')
    || rc_private.kes_tabel(array['Event', 'Count', 'Last / Total', 'Details'], v_t,
                            'No incidents recorded in this period.')
    || '<p style="font-size:11px;color:#5f6368;margin:0 0 6px;">API errors (HTTP 500 / statement timeouts) are logged by Supabase '
    || 'outside the database and are not included here; their risk is monitored in section 4.</p>';

  -- ===== 4. Bug risk prediction =====
  begin
    select stats_reset into v_reset from extensions.pg_stat_statements_info;
    select coalesce(jsonb_agg(jsonb_build_array(x.fungsi, rc_private.kes_angka(x.calls), rc_private.kes_angka(round(x.rata::numeric)) || ' ms',
                                                rc_private.kes_angka(round(x.maks::numeric)) || ' ms',
                                                -- Panggilan yang dibatalkan tidak tercatat, jadi maksimum
                                                -- di atas 7 detik berarti sangat mungkin sudah pernah timeout.
                                                case when x.maks >= 7000 then 'Very critical (likely timed out before)'
                                                     when x.maks >= 6000 then 'Critical' else 'Watch' end)
                              order by x.maks desc), '[]')
      into v_t
      from (select coalesce(substring(s.query from '"?(rc_[a-z0-9_]+)"?\('), left(regexp_replace(s.query, '\s+', ' ', 'g'), 60)) fungsi,
                   sum(s.calls) calls, sum(s.mean_exec_time * s.calls) / nullif(sum(s.calls), 0) rata, max(s.max_exec_time) maks
              from extensions.pg_stat_statements s join pg_catalog.pg_roles r on r.oid = s.userid
             where r.rolname in ('authenticated', 'anon')
             group by 1
            having max(s.max_exec_time) >= 4000 or sum(s.mean_exec_time * s.calls) / nullif(sum(s.calls), 0) >= 1500
             order by 4 desc limit 10) x;
  exception when others then
    v_t := jsonb_build_array(jsonb_build_array('(statistics unavailable)', '-', '-', '-', left(sqlerrm, 120)));
  end;

  select coalesce(jsonb_agg(x.baris order by x.urut), '[]'), count(*) into v_t2, v_risiko from (
    select 1 urut, jsonb_build_array('Active depots without Abbr', rc_private.kes_angka(count(*)), 'Compile for these depots is rejected',
             coalesce(string_agg(depot_code, ', ' order by depot_code), '')) baris
      from public.depots where archived_at is null and coalesce(btrim(abbr), '') = '' having count(*) > 0
    union all
    select 2, jsonb_build_array('Active depots without Email TO', rc_private.kes_angka(count(*)), 'Submission emails for these depots are held',
             coalesce(string_agg(depot_code, ', ' order by depot_code), ''))
      from public.depots where archived_at is null and coalesce(btrim(email_to), '') = '' having count(*) > 0
    union all
    select 3, jsonb_build_array('Campaigns without SO End', rc_private.kes_angka(count(*)), 'Period End in Details Campaign is empty',
             coalesce(string_agg(campaign_code, ', ' order by campaign_code), ''))
      from public.campaigns where archived_at is null and so_end is null having count(*) > 0
    union all
    select 4, jsonb_build_array('Campaigns without Billing End', rc_private.kes_angka(count(*)), 'Billing period is incomplete',
             coalesce(string_agg(campaign_code, ', ' order by campaign_code), ''))
      from public.campaigns where archived_at is null and billing_end is null having count(*) > 0
    union all
    select 5, jsonb_build_array('Not Yet claims without Customer Master', rc_private.kes_angka(count(*)),
             'Cannot be submitted until the master is completed', '')
      from public.claims where archived_at is null and status = 'not_yet' and customer_id is null having count(*) > 0
    union all
    select 6, jsonb_build_array('Stores with Not Yet claims but no KTP or NPWP', rc_private.kes_angka(count(distinct cu.id)),
             'Upload is rejected ("KTP/NPWP Kosong")', '')
      from public.claims c join public.customers cu on cu.id = c.customer_id
     where c.archived_at is null and c.status = 'not_yet' and coalesce(btrim(cu.ktp), '') = '' and coalesce(btrim(cu.npwp), '') = ''
    having count(*) > 0
    union all
    select 7, jsonb_build_array('Active accounts with 2 wrong PINs', rc_private.kes_angka(count(*)), 'One more wrong PIN suspends the account',
             coalesce(string_agg(user_code, ', ' order by user_code), ''))
      from public.profiles where status = 'active' and coalesce(gagal_login, 0) >= 2 having count(*) > 0
    union all
    select 8, jsonb_build_array('Accounts that must change PIN', rc_private.kes_angka(count(*)), 'Cannot use the application yet',
             coalesce(string_agg(user_code, ', ' order by user_code), ''))
      from public.profiles where status = 'active' and must_change_password having count(*) > 0
    union all
    select 9, jsonb_build_array('Schedule whose last run failed: ' || j.jobname, '1', 'The next scheduled run may fail again',
             left(split_part(t.return_message, E'\n', 1), 160))
      from cron.job j
      cross join lateral (select d.status, d.return_message from cron.job_run_details d
                           where d.jobid = j.jobid order by d.start_time desc limit 1) t
     where t.status = 'failed'
  ) x;

  v_html := v_html || rc_private.kes_judul('4. Bug Risk Prediction')
    || rc_private.kes_sub('Application functions approaching the 8-second limit')
    || '<p style="font-size:12px;color:#5f6368;margin:0 0 6px;">User calls that exceed 8 seconds are cancelled by the server (error 500). '
    || 'Statistics since ' || coalesce(to_char(v_reset at time zone 'Asia/Jakarta', 'DD-Mon-YYYY'), '-') || '.</p>'
    || rc_private.kes_tabel(array['Function', 'Calls', 'Average', 'Maximum', 'Status'], v_t, 'No function is approaching the limit.')
    || rc_private.kes_sub('Data and settings that will cause rejections or holds')
    || rc_private.kes_tabel(array['Risk', 'Count', 'Impact', 'Details'], v_t2, 'None.');

  v_n := jsonb_build_object('outlierBaru', v_out_baru, 'tanpaMaster', v_tm_total, 'tanpaMasterBaru', v_tm_baru,
                            'gangguan', v_gangguan, 'risiko', v_risiko + coalesce(jsonb_array_length(v_t), 0));
  return jsonb_build_object('html', v_html, 'ringkas', v_n);
end $f$;
revoke all on function rc_private.email_kesehatan_isi(timestamptz) from public, anon, authenticated;

-- ---- 4. Penyusun email ------------------------------------------------------------------
create or replace function rc_private.email_kesehatan_susun(p_set public.email_settings, p_kirim boolean, p_uji text)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare
  v_dari timestamptz; v_isi jsonb; v_html text; v_subjek text; v_to text[]; v_cc text[]; v_id uuid; v_r jsonb;
  v_kotak text;
begin
  -- Senin memantau sejak Jumat pagi; hari lain sejak 24 jam lalu.
  v_dari := now() - case when extract(isodow from now() at time zone 'Asia/Jakarta') = 1
                         then interval '3 days' else interval '1 day' end;
  begin
    v_isi := rc_private.email_kesehatan_isi(v_dari);
  exception when others then
    v_isi := jsonb_build_object('gagal', true,
      'html', '<p style="font-size:14px;color:#b3261e;"><b>The report could not be generated:</b> ' || rc_private.html_aman(sqlerrm)
              || '</p><p style="font-size:13px;">This failure is itself a bug that needs to be checked.</p>');
  end;
  v_r := coalesce(v_isi->'ringkas', '{}');

  v_kotak := case when v_isi ? 'gagal' then '' else
    '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:12px 0 4px;"><tr>'
    || (select string_agg('<td style="padding:10px 14px;border:1px solid #dadce0;text-align:center;">'
                          || '<div style="font-size:20px;font-weight:bold;color:' || w || ';">' || rc_private.kes_angka(nil) || '</div>'
                          || '<div style="font-size:11px;color:#5f6368;">' || lbl || '</div></td>', '' order by u)
          from (values (1, coalesce((v_r->>'outlierBaru')::numeric, 0), 'New/changed outliers', '#b3261e'),
                       (2, coalesce((v_r->>'tanpaMaster')::numeric, 0), 'Documents without master', '#e37400'),
                       (3, coalesce((v_r->>'gangguan')::numeric, 0), 'Incidents', '#b3261e'),
                       (4, coalesce((v_r->>'risiko')::numeric, 0), 'Risks monitored', '#1a73e8')) k(u, nil, lbl, w))
    || '</tr></table>' end;

  v_html := '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#202124;">'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:860px;"><tr><td>'
    || '<p style="line-height:1.6;margin:0 0 10px;">Hi Daniel,</p>'
    || '<p style="line-height:1.6;margin:0;">We would like to share the RC Health Report as of <b>' || rc_private.kes_tgl(now())
    || '</b>. Monitoring period: since <b>' || to_char(v_dari at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ' WIB</b>.</p>'
    || v_kotak
    || coalesce(v_isi->>'html', '')
    || '<p style="font-size:11px;color:#5f6368;line-height:1.5;margin-top:20px;">This report is generated automatically by RC using '
    || 'rule-based checks (no AI), Monday to Friday. Its schedule, time and recipients (To / CC) can be changed in '
    || 'Access Management &gt; Email Otomatis (type "kesehatan").</p>'
    || '<p style="margin-top:18px;line-height:1.6;">Best regards,<br><strong>SA &amp; SD Operations</strong></p>'
    || '<p style="color:#5f6368;font-size:11px;border-top:1px solid #e0e2e6;padding-top:8px;margin-top:20px;line-height:1.6;">'
    || 'For RC issues, please contact <a href="mailto:sa_sd1@nipponpaint-indonesia.com" style="color:#5f6368;">sa_sd1@nipponpaint-indonesia.com</a><br>'
    || 'Data retrieved on ' || rc_private.kes_tgl(now()) || ' ' || to_char(now() at time zone 'Asia/Jakarta', 'HH24:MI')
    || ' WIB. This email was sent automatically.</p>'
    || '</td></tr></table></div>';

  v_subjek := coalesce(nullif(btrim(p_set.subjek), ''), 'RC Health Report') || ' - ' || rc_private.kes_tgl(now());
  if coalesce(p_uji, '') <> '' then
    v_to := array[p_uji];
    v_cc := '{}';
    v_subjek := '[TEST] ' || v_subjek;
  else
    -- Urutan mengikuti isian di panel (sudah dirapikan dan tanpa kembar saat disimpan).
    v_to := array(select lower(btrim(x)) from unnest(coalesce(p_set.tujuan, '{}')) with ordinality u(x, i)
                   where btrim(x) like '%@%' order by i);
    v_cc := array(select lower(btrim(x)) from unnest(coalesce(p_set.cc_tambahan, '{}')) with ordinality u(x, i)
                   where btrim(x) like '%@%' and not (lower(btrim(x)) = any(v_to)) order by i);
  end if;

  if coalesce(array_length(v_to, 1), 0) = 0 then
    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, galat, konteks)
    values ('kesehatan', '{}', v_subjek, v_html, 'skipped', 'Belum ada penerima (To) Laporan Kesehatan',
            jsonb_build_object('preview', not coalesce(p_kirim, false), 'dari', v_dari))
    returning id into v_id;
    return jsonb_build_object('status', 'success', 'dikirim', false, 'id', v_id, 'subjek', v_subjek, 'isiHtml', v_html,
      'message', 'Isi laporan tersusun, tetapi belum ada penerima (To).');
  end if;

  insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, status, konteks)
  values ('kesehatan', v_to, v_cc, v_subjek, v_html,
          case when coalesce(p_kirim, false) then 'pending' else 'skipped' end,
          jsonb_build_object('preview', not coalesce(p_kirim, false), 'uji', coalesce(p_uji, '') <> '',
                             'dari', v_dari, 'ringkas', v_r))
  returning id into v_id;

  return jsonb_build_object('status', 'success', 'id', v_id, 'dikirim', coalesce(p_kirim, false),
    'penerima', jsonb_build_object('to', to_jsonb(v_to), 'cc', to_jsonb(v_cc)),
    'subjek', v_subjek, 'isiHtml', v_html,
    'message', case when coalesce(p_kirim, false)
      then case when coalesce(p_uji, '') <> '' then 'Email uji dimasukkan ke antrean untuk ' || p_uji || '.'
                else 'Email dimasukkan ke antrean pengiriman.' end
      else 'Pratinjau tersusun. Tidak ada yang dikirim.' end);
end $f$;
revoke all on function rc_private.email_kesehatan_susun(public.email_settings, boolean, text) from public, anon, authenticated;

-- ---- 5. Tambalan fungsi yang sudah ada ----------------------------------------------------
do $tambal$
declare src text; f record;
begin
  for f in select * from (values
    ('public.rc_email_susun(text,boolean,text)', '147e7040e2bdc079ffaebf72b37cf10a'),
    ('public.rc_email_status()', '1bd527771cbfb4dbd7f6e42262c5474c'),
    ('rc_private.email_perlu_pdf(text)', '332b577aef2d27fa4b4695f3a96924ea'),
    ('public.rc_email_settings_simpan(jsonb)', '9751970b84f6501fe522070ad7feb4df')) x(sig, harapan)
  loop
    src := replace(pg_get_functiondef(f.sig::regprocedure), E'\r', '');
    if src ~ '20261163230000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(src) <> f.harapan then raise exception 'DITOLAK: % berbeda dari yang diukur (md5 %).', f.sig, md5(src); end if;

    if f.sig like 'public.rc_email_susun%' then
      src := pg_temp.ganti(src, $p$  -- Ringkasan menyeluruh, dipakai kedua jenis email.$p$,
        $p$  -- 20261163230000: Laporan Kesehatan RC disusun tersendiri, penerimanya tetap (To / CC).
  if v_jenis = 'kesehatan' then
    return rc_private.email_kesehatan_susun(v_set, coalesce(p_kirim, false), v_uji);
  end if;

  -- Ringkasan menyeluruh, dipakai kedua jenis email.$p$, 1, 'susun cabang kesehatan');
    elsif f.sig like 'public.rc_email_status%' then
      src := pg_temp.ganti(src, $p$'subjek',subjek) order by jenis)$p$,
        $p$'subjek',subjek,'tujuan',to_jsonb(tujuan),
        'cc',case when jenis = 'kesehatan' then to_jsonb(cc_tambahan) end /* 20261163230000 */) order by jenis)$p$, 1, 'status penerima');
    elsif f.sig like 'rc_private.email_perlu_pdf%' then
      src := pg_temp.ganti(src, $p$not in ('weekly','pengajuan')$p$,
        $p$not in ('weekly','pengajuan','kesehatan') /* 20261163230000 */$p$, 1, 'perlu pdf');
    else
      src := pg_temp.ganti(src, $p$declare r jsonb; n integer := 0; v_hari smallint[]; v_angka smallint;$p$,
        $p$declare r jsonb; n integer := 0; v_hari smallint[]; v_angka smallint;
  v_to text[]; v_cc text[]; -- 20261163230000$p$, 1, 'simpan deklarasi');
      src := pg_temp.ganti(src, $p$    if found then n := n + 1; end if;$p$,
        $p$    if found then n := n + 1; end if;

    -- 20261163230000: penerima Laporan Kesehatan (To / CC) diatur dari panel Email Otomatis.
    -- Hanya baris 'kesehatan': CC jenis lain (mis. CC Semua Email pengajuan) tidak tersentuh.
    if lower(btrim(r->>'jenis')) = 'kesehatan' and (r ? 'tujuan' or r ? 'cc') then
      v_to := rc_private.kes_alamat(r->'tujuan');
      v_cc := rc_private.kes_alamat(r->'cc');
      if r ? 'tujuan' and coalesce(array_length(v_to, 1), 0) = 0 then
        raise exception 'Penerima (To) Laporan Kesehatan wajib diisi minimal satu alamat'; end if;
      update public.email_settings set
        tujuan = case when r ? 'tujuan' then v_to else tujuan end,
        cc_tambahan = case when r ? 'cc'
                           then array(select x from unnest(v_cc) x
                                       where not (x = any(case when r ? 'tujuan' then v_to else tujuan end)))
                           else cc_tambahan end
      where jenis = 'kesehatan';
    end if;$p$, 1, 'simpan penerima');
    end if;
    execute src;
  end loop;
end $tambal$;

do $cek$
declare e text := '';
begin
  if pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure) !~ 'email_kesehatan_susun' then e := e || ' susun;'; end if;
  if pg_get_functiondef('public.rc_email_status()'::regprocedure) !~ '''tujuan''' then e := e || ' status;'; end if;
  if pg_get_functiondef('public.rc_email_settings_simpan(jsonb)'::regprocedure) !~ 'kes_alamat' then e := e || ' simpan;'; end if;
  if rc_private.email_perlu_pdf('kesehatan') then e := e || ' pdf;'; end if;
  if not rc_private.email_perlu_pdf('daily') then e := e || ' pdf daily;'; end if;
  if not exists(select 1 from public.email_settings where jenis = 'kesehatan') then e := e || ' pengaturan;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
