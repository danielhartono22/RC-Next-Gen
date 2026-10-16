-- ==========================================================================================
-- Uji pascatransport 13 Oktober 2026 (migrasi 20261163010000 - 20261163060000)
-- ==========================================================================================
-- Memanggil fungsi yang sama dengan layar, sebagai System Manager (role authenticated bila
-- layarnya begitu). Setiap uji berjalan di subtransaksi yang DIBATALKAN (raise 'UJI_SELESAI'):
-- tidak ada data yang tertinggal, dan email pengajuan dimatikan di dalam uji yang menyentuh
-- status sehingga tidak ada surat yang diantrekan. Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_transport_20261013.sql
-- ==========================================================================================
create temp table if not exists _hasil_transport(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_transport;

do $uji$
declare
  v_sm uuid; m jsonb; k jsonb; p jsonb; r jsonb; o jsonb; s jsonb; harap record; d record; c public.claims%rowtype;
  kata text; lama bigint; v_kode text; mulai timestamptz; ms numeric; rows jsonb; v_html text; ids uuid[];
  d1 record; d2 record; v_depot_tanpa text;
  catat text := ''; hasil jsonb := '[]'::jsonb;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  -- ---- A. Timetable: Expired = selesai, tiga tempat sama ---------------------------------
  m := public.rc_timetable_matrix('{}'::jsonb)->'kpi';
  k := rc_private.timetable_ringkas(null);
  p := rc_private.people_metrics(array(select id from public.depots where archived_at is null), (now() at time zone 'Asia/Jakarta')::date)->'timetable';
  hasil := hasil || jsonb_build_array(jsonb_build_array('Timetable: modul = email ringkasan = People Performance',
    (m->>'total') = (k->>'total') and (m->>'completed') = (k->>'completed') and (m->>'compiled') = (k->>'compiled')
      and (m->>'notYet') = (k->>'notYet') and (p->>'total') = (m->>'total') and (p->>'completed') = (m->>'completed')
      and (p->>'compiled') = (m->>'compiled') and (p->>'not_yet') = (m->>'notYet'),
    format('modul %s/%s/%s/%s | email %s/%s/%s/%s | people %s/%s/%s/%s (total/completed/compiled/notYet)',
      m->>'total', m->>'completed', m->>'compiled', m->>'notYet', k->>'total', k->>'completed', k->>'compiled', k->>'notYet',
      p->>'total', p->>'completed', p->>'compiled', p->>'not_yet')));
  with t as (select rc_private.timetable_tahun_baku() tahun),
  kt as (select ca.id from public.campaigns ca, t where ca.archived_at is null and coalesce(ca.period_start,ca.period_end) is not null
          and extract(year from coalesce(ca.period_start,ca.period_end))::integer = t.tahun
          and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)),
  rk as (select cl.depot_id, cl.campaign_id, count(*) n, count(*) filter (where cl.status in ('done','expired')) sl,
                count(*) filter (where cl.status = 'expired') ne
           from public.claims cl join kt on kt.id = cl.campaign_id where cl.archived_at is null group by 1,2)
  select count(*) filter (where coalesce(rk.n,0) > 0 and rk.n = rk.sl) completed,
         count(*) filter (where coalesce(rk.ne,0) > 0 and rk.n = rk.sl) completed_berkat_expired
    into harap from public.depots dp cross join kt left join rk on rk.depot_id = dp.id and rk.campaign_id = kt.id where dp.archived_at is null;
  hasil := hasil || jsonb_build_array(jsonb_build_array('Timetable: Completed menghitung Done + Expired',
    (m->>'completed')::bigint = harap.completed,
    format('Completed %s (harap %s), %s di antaranya berkat dokumen Expired', m->>'completed', harap.completed, harap.completed_berkat_expired)));

  -- ---- B. Compile: Abbr dari Depot Master ----------------------------------------------------
  select dp.id depot_id, dp.depot_code, dp.abbr, cu.customer_code, ca.campaign_code into d
    from public.customers cu
    join public.customer_depots cd on cd.customer_id = cu.id
    join public.depots dp on dp.id = cd.depot_id and dp.archived_at is null and dp.abbr is not null
    cross join lateral (select ca.* from public.campaigns ca
                         where ca.status = 'active' and ca.archived_at is null
                           and not exists(select 1 from public.claims x where x.campaign_id = ca.id and x.customer_id = cu.id)
                           and not rc_private.np_pasangan(dp.id, ca.id)
                           and not exists(select 1 from public.timetable_not_achieved na where na.depot_id = dp.id and na.campaign_id = ca.id)
                         order by ca.campaign_code limit 1) ca
   where cu.archived_at is null order by cu.customer_code, ca.campaign_code limit 1;
  rows := jsonb_build_array(jsonb_build_object('kodeDepot', d.depot_code, 'abbr', 'SALAH', 'codeCampaign', d.campaign_code,
            'custCode', d.customer_code, 'netValue', '1000000', 'cbNet', '1000'));
  begin
    execute 'set local role authenticated';
    r := public.rc_compile_preview(rows);
    execute 'reset role';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Compile: kolom Abbr di file diabaikan, ikut Depot Master',
      (r->>'siap')::int = 1 and jsonb_array_length(r->'ditolak') = 0,
      format('depot %s (master %s), file "SALAH": siap %s, ditolak %s', d.depot_code, d.abbr, r->>'siap', r->'ditolak')));
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_array(jsonb_build_array('Compile: Abbr dari master', false, sqlerrm)); end if;
  end;
  begin
    select depot_code into v_depot_tanpa from public.depots where archived_at is null and coalesce(btrim(abbr),'') = '' order by depot_code limit 1;
    if v_depot_tanpa is null then
      update public.depots set abbr = null where id = d.depot_id; v_depot_tanpa := d.depot_code;
    end if;
    execute 'set local role authenticated';
    r := public.rc_compile_preview(jsonb_build_array(jsonb_build_object('kodeDepot', v_depot_tanpa, 'codeCampaign', d.campaign_code,
           'custCode', d.customer_code, 'cbNet', '1000')));
    execute 'reset role';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Compile: depot tanpa Abbr di master ditolak dengan petunjuk',
      exists(select 1 from jsonb_array_elements(r->'ditolak') x where x->>'alasan' ~ 'belum diisi di Key Master > Depot Master'),
      format('depot %s: %s', v_depot_tanpa, r->'ditolak')));
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_array(jsonb_build_array('Compile: depot tanpa Abbr', false, sqlerrm)); end if;
  end;

  -- ---- C. Document Center & tab Open ---------------------------------------------------------
  begin
    select dp.depot_code into v_kode from public.claims cl join public.depots dp on dp.id = cl.depot_id
     where cl.archived_at is null group by 1 order by count(*) desc limit 1;
    execute 'set local role authenticated';
    r := public.rc_compilation_list(p_depot => v_kode, p_limit => 500);
    select count(*) into lama from public.claims cl join public.depots dp on dp.id = cl.depot_id
      join public.campaigns ca on ca.id = cl.campaign_id where dp.depot_code = v_kode;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Document Center: filter Depot',
      (r->>'total')::bigint = lama and not exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'kodeDepot' <> v_kode),
      format('depot %s: total %s (harap %s)', v_kode, r->>'total', lama)));
    hasil := hasil || jsonb_build_array(jsonb_build_array('Document Center: kolom tambahan untuk unduhan',
      (r->'rows'->0) ?& array['region','netValue','volume','tglAktual','createdOn','createdBy','kodeDepot'],
      (select string_agg(x, ', ' order by x) from jsonb_object_keys(r->'rows'->0) x)));
    s := public.rc_compilation_depots();
    hasil := hasil || jsonb_build_array(jsonb_build_array('Document Center: daftar pilihan Depot',
      jsonb_array_length(s->'rows') = (select count(*) from public.depots where archived_at is null),
      jsonb_array_length(s->'rows') || ' depot'));
    foreach kata in array array[
        (select substr(no_doc, 5, 6) from public.claims order by no_doc limit 1),
        (select lower(split_part(customer_name, ' ', 1)) from public.customers where customer_name like '% %' order by customer_code limit 1),
        (select substr(customer_code, 2, 4) from public.customers order by customer_code limit 1), 'belum ada'] loop
      continue when kata is null;
      select count(*) into lama from public.claims cl join public.campaigns ca on ca.id = cl.campaign_id left join public.customers cu on cu.id = cl.customer_id
       where cl.no_doc ilike '%'||kata||'%' or coalesce(cu.customer_code,cl.source_customer_code) ilike '%'||kata||'%'
          or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||kata||'%';
      mulai := clock_timestamp();
      r := public.rc_compilation_list(p_search => kata, p_limit => 100);
      ms := round(extract(epoch from clock_timestamp() - mulai) * 1000);
      hasil := hasil || jsonb_build_array(jsonb_build_array('Document Center: cari "' || kata || '"', (r->>'total')::bigint = lama,
        format('total %s (harap %s), %s ms', r->>'total', lama, ms)));
      select count(*) into lama from public.claims cl join public.campaigns ca on ca.id = cl.campaign_id left join public.customers cu on cu.id = cl.customer_id
       where cl.status = 'not_yet' and cl.pending_approval is null and cl.archived_at is null
         and (cl.no_doc ilike '%'||kata||'%' or coalesce(cu.customer_code,cl.source_customer_code) ilike '%'||kata||'%'
          or coalesce(cu.customer_name,'Customer Master belum ada') ilike '%'||kata||'%');
      o := public.rc_open_claims_filtered(p_search => kata, p_limit => 200);
      hasil := hasil || jsonb_build_array(jsonb_build_array('Tab Open: cari "' || kata || '"', (o->>'total')::bigint = lama,
        format('total %s (harap %s)', o->>'total', lama)));
    end loop;
    execute 'reset role';
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_array(jsonb_build_array('Document Center / Open', false, sqlerrm)); end if;
  end;

  -- ---- D. On Hold / Expired tanpa approval ---------------------------------------------------
  catat := format('approval_aktif saat ini: %s', rc_private.approval_aktif());
  select cl.no_doc, cl.version_no, ca.period_start, ca.period_end into d1
    from public.claims cl join public.campaigns ca on ca.id = cl.campaign_id
   where cl.status = 'not_yet' and cl.pending_approval is null and cl.archived_at is null
     and ca.period_start is not null and ca.period_end is not null order by cl.no_doc limit 1;
  select cl.no_doc, cl.version_no into d2 from public.claims cl
   where cl.status = 'not_yet' and cl.pending_approval is null and cl.archived_at is null and cl.no_doc <> d1.no_doc
   order by cl.no_doc desc limit 1;
  begin
    update public.email_settings set aktif = false where jenis = 'pengajuan';
    insert into public.pengaturan_sistem(kunci, nilai) values ('approval_aktif', 'false'::jsonb)
    on conflict (kunci) do update set nilai = 'false'::jsonb;
    r := public.rc_posting_exception('expired', jsonb_build_array(jsonb_build_object('noDoc', d2.no_doc, 'versionNo', d2.version_no)), '');
    select * into c from public.claims where no_doc = d2.no_doc;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Approval mati: Expired langsung berlaku',
      (r->>'langsung')::boolean and c.status = 'expired' and c.pending_approval is null and coalesce(c.batch_clearing,'') <> '',
      format('%s -> %s, batch %s; %s | %s', d2.no_doc, c.status, c.batch_clearing, r->>'message', catat)));
    r := public.rc_posting_exception('hold', jsonb_build_array(jsonb_build_object('noDoc', d1.no_doc, 'versionNo', d1.version_no,
      'soStart', d1.period_start, 'soEnd', d1.period_end + 30, 'billingStart', d1.period_start, 'billingEnd', d1.period_end + 30)), 'uji transport');
    select * into c from public.claims where no_doc = d1.no_doc;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Approval mati: On Hold langsung berlaku',
      (r->>'langsung')::boolean and c.status = 'on_hold' and c.pending_approval is null and c.previous_status = 'not_yet'
        and c.extend_so_end = d1.period_end + 30,
      format('%s -> %s (sebelumnya %s), SO End %s; %s', d1.no_doc, c.status, c.previous_status, c.extend_so_end, r->>'message')));
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_array(jsonb_build_array('On Hold / Expired tanpa approval', false, sqlerrm)); end if;
  end;

  -- ---- E. Email --------------------------------------------------------------------------------
  hasil := hasil || jsonb_build_array(jsonb_build_array('Email: penanda lingkungan',
    true, format('hanya email uji = %s (dev harus true, prod harus false); surat depot ditahan = %s',
      rc_private.hanya_email_uji(), rc_private.email_ditahan_lingkungan('{"aksi":"submit"}'::jsonb))));
  r := public.rc_email_status(); s := public.rc_email_pengajuan_baca();
  hasil := hasil || jsonb_build_array(jsonb_build_array('Email: layar menerima hanyaUji',
    (r->'hanyaUji') is not null and (s->'hanyaUji') is not null and (r->>'hanyaUji')::boolean = rc_private.hanya_email_uji(),
    format('Email Otomatis %s, Email Pengajuan %s', r->>'hanyaUji', s->>'hanyaUji')));
  select array_agg(id) into ids from (select id from public.claims where archived_at is null and status = 'approved' order by updated_at desc limit 3) x;
  if ids is not null then
    v_html := rc_private.email_pengajuan_html('submit_langsung', 'UJI-01', ids, v_sm, '');
    hasil := hasil || jsonb_build_array(jsonb_build_array('Email pengajuan tanpa approval: format Outlook, tanpa catatan bypass',
      v_html ~ '<!--rc-outlook-->' and v_html !~* 'melewati approval' and v_html !~* 'tanpa approval',
      format('%s karakter, penanda Outlook %s', length(v_html), v_html ~ '<!--rc-outlook-->')));
  end if;

  perform set_config('request.jwt.claims', '', true);
  -- Dicatat di akhir: catatan yang dibuat di dalam subtransaksi yang dibatalkan akan ikut hilang.
  insert into _hasil_transport(uji, lulus, rinci)
  select x->>0, (x->>1)::boolean, x->>2 from jsonb_array_elements(hasil) x;
end
$uji$;

select urut, uji, lulus, rinci from _hasil_transport order by urut;
