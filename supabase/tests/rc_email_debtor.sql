-- ==========================================================================================
-- Uji email berjenjang toko lunas ZDAGE (20261163670000): jenjang 14 / 21 / 28 hari sejak toko
-- lunas di RC, CC per jenjang, sekali per toko per jenjang, saklar ZDAGE, Test Email, panel.
-- ==========================================================================================
-- Hanya untuk lingkungan yang sudah punya ZDAGE (20261163170000). Seluruh perubahan (tawaran,
-- alamat depot, jenjang, outbox, saklar) dibatalkan lewat UJI_SELESAI.
--
--   node scripts/apply-sql.mjs --env dev supabase/tests/rc_email_debtor.sql
-- ==========================================================================================
create temp table if not exists _hasil_deb(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_deb;

do $uji$
declare hasil jsonb := '[]'; r jsonb; v_sm uuid; v_dep uuid; v_o uuid[]; v_k uuid[]; v_galat text; n integer; v_rows jsonb;
  o1 public.email_outbox; o3 public.email_outbox;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  begin
    perform set_config('request.jwt.claims', '', true);
    hasil := hasil || jsonb_build_object('uji', 'Jadwal debtor: tiap hari jam 8, aktif, jenjang bawaan 14 / 21 / 28 hari',
      'lulus', (select aktif and jam = 8 and hari_list is null from public.email_settings where jenis = 'debtor')
           and (select string_agg(x->>'hari', '/' order by i) from jsonb_array_elements(rc_private.debtor_jenjang()) with ordinality q(x, i)) = '14/21/28',
      'rinci', rc_private.debtor_jenjang()::text);

    -- Data uji: tawaran aktif lain dibuat baru (tidak jatuh tempo); 4 tawaran di satu depot diberi umur.
    delete from rc_private.debtor_peringatan where true;
    update public.rc_clearing_offers set offered_at = now() where status in ('offered', 'overdue');
    select c.depot_id into v_dep from public.rc_clearing_offers o join public.claims c on c.id = o.claim_id
     where o.status in ('offered', 'overdue') and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
     group by 1 having count(*) >= 4 order by count(*) desc limit 1;
    select array_agg(o.id order by o.id), array_agg(o.claim_id order by o.id) into v_o, v_k from (
      select o.id, o.claim_id from public.rc_clearing_offers o join public.claims c on c.id = o.claim_id
       where o.status in ('offered', 'overdue') and c.depot_id = v_dep and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
       order by o.id limit 4) o;
    update public.rc_clearing_offers set offered_at = now() - interval '15 days' where id = v_o[1];
    update public.rc_clearing_offers set offered_at = now() - interval '22 days' where id = v_o[2];
    update public.rc_clearing_offers set offered_at = now() - interval '30 days' where id = v_o[3];
    update public.rc_clearing_offers set offered_at = now() - interval '10 days' where id = v_o[4];
    update public.depots set email_to = 'depo.uji@contoh.co.id', email_cc = 'depo.cc@contoh.co.id' where id = v_dep;
    -- 20261164060000: antrean debtor hari ini (dari jadwal) dikosongkan di dalam uji agar pencegah ganda tidak ikut menghitungnya.
    delete from public.email_outbox where jenis = 'debtor' and dibuat_pada >= date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta';
    -- 20261164050000: email depot ke Depot Profile (dikosongkan = cadangan Email Depot lama); region ke RSM.
    insert into public.depot_profiles(depot_id) select v_dep where not exists(select 1 from public.depot_profiles where depot_id = v_dep);
    update public.depot_profiles set email_kepala_admin = null, email_npc = null, email_kepala_depot = null,
           email_rsm = 'rsm.uji@contoh.co.id', email_asm = null where depot_id = v_dep;

    -- ---- Saklar ZDAGE ----------------------------------------------------------------------
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'zdage_aktif';
    select count(*) into n from public.email_outbox where jenis = 'debtor';
    r := public.rc_email_susun('debtor', true);
    hasil := hasil || jsonb_build_object('uji', 'ZDAGE Integration mati: peringatan tidak disusun',
      'lulus', r->>'message' ~ 'ZDAGE Integration mati' and (select count(*) from public.email_outbox where jenis = 'debtor') = n, 'rinci', r->>'message');
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';

    -- ---- Jatuh tempo -----------------------------------------------------------------------
    select jsonb_agg(jsonb_build_object('offer', offer_id, 'tingkat', tingkat) order by offer_id) into v_rows from rc_private.debtor_jatuh_tempo();
    hasil := hasil || jsonb_build_object('uji', 'Umur 15 / 22 / 30 hari = jenjang 1 / 2 / 3; umur 10 hari belum; hanya jenjang tertinggi',
      'lulus', (select tingkat from rc_private.debtor_jatuh_tempo() where offer_id = v_o[1]) = 1
           and (select tingkat from rc_private.debtor_jatuh_tempo() where offer_id = v_o[2]) = 2
           and (select tingkat from rc_private.debtor_jatuh_tempo() where offer_id = v_o[3]) = 3
           and not exists (select 1 from rc_private.debtor_jatuh_tempo() where offer_id = v_o[4])
           and (select count(*) from rc_private.debtor_jatuh_tempo()) = 3,
      'rinci', coalesce(v_rows::text, '-'));

    -- ---- Panel: jenjang dan CC ---------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    begin
      perform public.rc_email_settings_simpan('[{"jenis":"debtor","jenjang":[{"hari":14,"cc":""},{"hari":10,"cc":""},{"hari":28,"cc":""}]}]');
      v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Simpan jenjang: hari harus naik', 'lulus', v_galat ~ 'lebih besar', 'rinci', v_galat);
    perform public.rc_email_settings_simpan('[{"jenis":"debtor","jenjang":[{"hari":14,"cc":"cc.satu@contoh.co.id"},{"hari":21,"cc":"cc.dua@contoh.co.id, cc.dua.b@contoh.co.id"},{"hari":28,"cc":"cc.tiga@contoh.co.id"}]}]');
    r := public.rc_email_status();
    -- 20261164050000: CC jenis debtor = CC email depot.
    hasil := hasil || jsonb_build_object('uji', 'Panel: jenjang tersimpan (hari + CC); CC jenis debtor tampil sebagai CC email depot',
      'lulus', exists (select 1 from jsonb_array_elements(r->'pengaturan') x where x->>'jenis' = 'debtor' and jsonb_typeof(x->'cc') = 'array'
                        and (x->'jenjang'->1->>'hari')::int = 21 and (x->'jenjang'->1->'cc') ? 'cc.dua.b@contoh.co.id'),
      'rinci', (select (x->'jenjang')::text from jsonb_array_elements(r->'pengaturan') x where x->>'jenis' = 'debtor'));

    -- ---- Pratinjau ---------------------------------------------------------------------------
    r := public.rc_email_susun('debtor', false);
    -- 20261164050000: satu email depot (3 jenjang digabung) + satu email region; kolom Lewat (hari).
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau: 1 email depot + 1 email region (jenjang digabung), kolom Nama Toko / Nama Campaign / Net CB / Tanggal Lunas / Lewat / Auto-Expiring; tidak menandai',
      'lulus', (r->>'emailRegion')::int = 2
           and r->>'isiHtml' ~ 'NAMA TOKO</th><th[^>]*>NAMA CAMPAIGN</th><th[^>]*>NET CB</th><th[^>]*>TANGGAL LUNAS</th><th[^>]*>LEWAT \(HARI\)</th><th[^>]*>AUTO-EXPIRING</th>'
           and r->>'isiHtml' !~ 'Jenjang [0-9]'
           and not exists (select 1 from rc_private.debtor_peringatan),
      'rinci', coalesce(r->>'message', ''));

    -- ---- Test Email ----------------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    r := public.rc_email_susun('debtor', true, 'uji.rc@contoh.co.id');
    select * into o1 from public.email_outbox where id = (r->>'id')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Test Email: satu email ke alamat uji berisi semua peringatan; toko tidak ditandai',
      'lulus', o1.tujuan = array['uji.rc@contoh.co.id'] and (o1.konteks->>'uji')::boolean and o1.subjek ~ '^\[UJI\]'
           and not exists (select 1 from rc_private.debtor_peringatan), 'rinci', coalesce(o1.subjek, '-'));

    -- ---- Kirim sungguhan -----------------------------------------------------------------------
    r := public.rc_email_susun('debtor', true);
    select * into o1 from public.email_outbox where jenis = 'debtor' and (konteks->>'depot')::uuid = v_dep and konteks->>'bagian' = 'depot' and status = 'pending' order by dibuat_pada desc limit 1;
    select * into o3 from public.email_outbox where jenis = 'debtor' and konteks->>'bagian' = 'region' and status = 'pending' order by dibuat_pada desc limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Kirim: email depot (cadangan Email Depot lama, CC panel) + laporan region (toko 15 / 22 hari: CC jenjang 2) + laporan nasional (toko 30 hari: CC jenjang 3)',
      'lulus', (r->>'emailRegion')::int = 2 and o1.tujuan = array['depo.uji@contoh.co.id']
           and o1.cc is not distinct from (select coalesce(cc_tambahan, '{}') from public.email_settings where jenis = 'debtor')
           and o3.tujuan = array['rsm.uji@contoh.co.id'] and 'cc.dua@contoh.co.id' = any(o3.cc) and not (o3.cc && array['cc.satu@contoh.co.id', 'cc.tiga@contoh.co.id'])
           and exists (select 1 from public.email_outbox where jenis = 'debtor' and konteks->>'bagian' = 'nasional' and status = 'pending' and 'cc.tiga@contoh.co.id' = any(cc))
           and o1.subjek !~ 'Jenjang' and o3.subjek ~ 'Region',
      'rinci', coalesce(array_to_string(o1.tujuan, ','), '-') || ' | ' || coalesce(array_to_string(o3.cc, ','), '-'));
    -- 20261164050000: laporan region tidak lagi menandai toko.
    hasil := hasil || jsonb_build_object('uji', 'Tanpa penandaan toko; isi email depot memuat toko, Net CB, tanggal',
      'lulus', not exists (select 1 from rc_private.debtor_peringatan where offer_id = any(v_o))
           and o1.isi_html ~ (select to_char(((deadline_at at time zone 'Asia/Jakarta')::date + interval '1 month')::date + 1, 'DD-Mon-YYYY') from public.rc_clearing_offers where id = v_o[1])
           and o1.isi_html ~ replace(rc_private.rupiah((select cb_net from public.claims where id = v_k[1])), '.', '\.'),
      'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Tanpa lampiran PDF', 'lulus', not rc_private.email_perlu_pdf('debtor'), 'rinci', '-');

    select count(*) into n from public.email_outbox where jenis = 'debtor' and status = 'pending';
    r := public.rc_email_susun('debtor', true);
    -- 20261164060000: dijalankan lagi di hari yang sama = depot, region dan nasional yang sudah dikirimi dilewati (tanpa ganda).
    hasil := hasil || jsonb_build_object('uji', 'Dijalankan lagi di hari yang sama: tidak ada email ganda (depot, region, nasional dilewati)',
      'lulus', coalesce((r->>'jumlahEmail')::int, 0) = 0 and (select count(*) from public.email_outbox where jenis = 'debtor' and status = 'pending' and konteks->>'bagian' = 'region') = 1,
      'rinci', r->>'message');

    update public.rc_clearing_offers set offered_at = now() - interval '21 days' where id = v_o[1];
    hasil := hasil || jsonb_build_object('uji', 'Toko jenjang 1 yang mencapai 21 hari: jatuh tempo jenjang 2',
      'lulus', (select tingkat from rc_private.debtor_jatuh_tempo() where offer_id = v_o[1]) = 2, 'rinci', '-');
    update public.claims set status = 'submitted' where id = v_k[1];
    hasil := hasil || jsonb_build_object('uji', 'Toko yang sudah diproses (bukan Not Yet) tidak diperingatkan',
      'lulus', not exists (select 1 from rc_private.debtor_jatuh_tempo() where offer_id = v_o[1]), 'rinci', '-');

    -- Job harian ZDAGE tidak lagi mengirim email peringatan lama.
    select count(*) into n from public.email_outbox where konteks->>'aksi' = 'debtor_warning';
    perform rc_private.zdage_harian();
    hasil := hasil || jsonb_build_object('uji', 'Job harian ZDAGE: email peringatan lama tidak dikirim lagi',
      'lulus', (select count(*) from public.email_outbox where konteks->>'aksi' = 'debtor_warning') = n, 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_deb(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_deb order by urut;
