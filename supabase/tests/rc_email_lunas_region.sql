-- ==========================================================================================
-- Uji 18 November 2026: Warning toko lunas - email depot tiap 2 hari (kelompok A / B) + laporan
-- region berjenjang tanpa ganda (20261164050000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_lunas_region.sql
-- ==========================================================================================
create temp table if not exists _hasil_lr(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_lr;

do $uji$
declare hasil jsonb := '[]'; v_set public.email_settings; r jsonb; v_ids uuid[]; v_dep uuid[]; v_mulai timestamptz := now();
  v_ok boolean; v_d record; v_x text; v_kel smallint := rc_private.debtor_kelompok_hari_ini(); v_reg text; v_cari text; v_a integer; v_b integer;
  v_n_dep integer; v_n_reg integer; v_maks integer;
begin
  begin
    if not rc_private.zdage_aktif() then raise exception 'Fixture: ZDAGE Integration mati'; end if;

    -- 1. Kelompok: setiap region satu kelompok, jumlah depot kedua kelompok seimbang.
    select sum(n_depot) filter (where kelompok = 0), sum(n_depot) filter (where kelompok = 1), max(n_depot) into v_a, v_b, v_maks from rc_private.debtor_kelompok();
    hasil := hasil || jsonb_build_object('uji', 'Kelompok A / B: region utuh dalam satu kelompok, selisih depot <= region terbesar; hari ini bergantian', 'lulus',
      (select count(*) = count(distinct region) from rc_private.debtor_kelompok()) and abs(v_a - v_b) <= v_maks
      and rc_private.debtor_kelompok_hari_ini() in (0, 1), 'rinci', 'A ' || v_a || ' depot, B ' || v_b || ' depot, hari ini ' || case when v_kel = 0 then 'A' else 'B' end);

    -- Fixture: seluruh tawaran aktif diberi umur 20 / 8 / 4 ... hari; depot-depotnya dipindah ke satu region
    -- milik kelompok hari ini.
    v_ids := array(select o.id from public.rc_clearing_offers o join public.claims c on c.id = o.claim_id
                    join public.depots d on d.id = c.depot_id and d.archived_at is null
                   where o.status in ('offered', 'overdue') and o.offered_at is not null and c.status = 'not_yet'
                     and c.pending_approval is null and c.archived_at is null order by c.depot_id, o.id limit 12);
    if coalesce(cardinality(v_ids), 0) < 3 then raise exception 'Fixture: kurang dari 3 tawaran aktif'; end if;
    update public.rc_clearing_offers o set offered_at = now() - interval '1 day' where o.status in ('offered', 'overdue') and not (o.id = any(v_ids));
    delete from rc_private.debtor_peringatan where offer_id = any(v_ids);
    update public.rc_clearing_offers o set offered_at = now() - make_interval(days => case x.i when 1 then 20 when 2 then 8 else 4 end)
      from unnest(v_ids) with ordinality x(id, i) where o.id = x.id;
    v_dep := array(select distinct c.depot_id from public.rc_clearing_offers o join public.claims c on c.id = o.claim_id where o.id = any(v_ids));
    for v_cari in select region from rc_private.debtor_kelompok() where kelompok = v_kel order by n_depot desc loop
      update public.depots set region = v_cari where id = any(v_dep);
      if (select kelompok from rc_private.debtor_kelompok() where region = upper(v_cari)) = v_kel then v_reg := upper(v_cari); exit; end if;
    end loop;
    if v_reg is null then raise exception 'Fixture: tidak menemukan region kelompok hari ini'; end if;
    update public.email_settings set jenjang = '[{"hari":3,"cc":["cc1.uji@contoh.co"]},{"hari":7,"cc":["cc2.uji@contoh.co"]},{"hari":14,"cc":["cc3.uji@contoh.co"]}]',
           cc_tambahan = array['ccdepot.uji@contoh.co'],
           hari_list = array[extract(dow from now() at time zone 'Asia/Jakarta')::smallint],  -- hari ini = hari laporan
           jam = 8, aktif = true
     where jenis = 'debtor';
    insert into public.depot_profiles(depot_id) select x from unnest(v_dep) x where not exists(select 1 from public.depot_profiles p where p.depot_id = x);
    update public.depot_profiles p set email_kepala_admin = 'ka.' || d.depot_code || '@contoh.co', email_npc = 'npc.' || d.depot_code || '@contoh.co',
           email_kepala_depot = 'kadep.' || d.depot_code || '@contoh.co', email_rsm = 'rsm.uji@contoh.co', email_asm = 'asm.' || d.depot_code || '@contoh.co',
           kepala_admin = 'PIC UJI ' || d.depot_code
      from public.depots d where d.id = p.depot_id and p.depot_id = any(v_dep);
    -- Antrean debtor hari ini (mis. dari jadwal) dikosongkan di dalam uji, supaya pencegah ganda tidak ikut menghitungnya.
    delete from public.email_outbox where jenis = 'debtor' and dibuat_pada >= date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta';
    select * into v_set from public.email_settings where jenis = 'debtor';
    -- 20261164060000: email depot setiap hari untuk semua depot yang punya toko belum diproses.
    select count(distinct b.depot_id) into v_n_dep from rc_private.debtor_belum_proses() b;

    -- 2. Pratinjau.
    r := rc_private.email_debtor_susun(v_set, false, null);
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau: email depot = semua depot yang punya toko lunas; 1 laporan region (jenjang 1-2) + 1 laporan nasional (jenjang 3)', 'lulus',
      (r->>'emailDepot')::int = v_n_dep and v_n_dep >= cardinality(v_dep) and (r->>'emailRegion')::int = 2
      and not exists(select 1 from rc_private.debtor_peringatan where offer_id = any(v_ids)),
      'rinci', r->>'message');

    -- 3. Kirim: email depot berisi SELURUH toko depot itu; email region TO RSM/ASM, CC jenjang tertinggi.
    r := rc_private.email_debtor_susun(v_set, true, null);
    v_ok := (select count(*) from public.email_outbox where jenis = 'debtor' and dibuat_pada >= v_mulai and konteks->>'bagian' = 'depot') = v_n_dep;
    for v_d in select e.*, d.depot_code, d.id did from public.email_outbox e join public.depots d on d.id = (e.konteks->>'depot')::uuid
                where e.jenis = 'debtor' and e.dibuat_pada >= v_mulai and e.konteks->>'bagian' = 'depot' and d.id = any(v_dep) loop
      v_ok := v_ok and v_d.tujuan @> array['ka.' || lower(v_d.depot_code) || '@contoh.co', 'npc.' || lower(v_d.depot_code) || '@contoh.co', 'kadep.' || lower(v_d.depot_code) || '@contoh.co']
              and v_d.cc = array['ccdepot.uji@contoh.co'] and v_d.subjek !~* 'jenjang' and v_d.isi_html ~ 'LEWAT \(HARI\)' and v_d.isi_html ~ 'H\+30' and v_d.isi_html ~ 'AUTO-EXPIRING' and v_d.isi_html !~ '>DEADLINE<'
              and v_d.isi_html ~ ('TOTAL ' || (select count(*) from rc_private.debtor_belum_proses() b where b.depot_id = v_d.did) || ' TOKO');
    end loop;
    v_ok := v_ok and exists(select 1 from public.email_outbox e where e.jenis = 'debtor' and e.dibuat_pada >= v_mulai and e.konteks->>'bagian' = 'depot'
              and e.isi_html ~ (select to_char(((o.deadline_at at time zone 'Asia/Jakarta')::date + interval '1 month')::date + 1, 'DD-Mon-YYYY')
                                  from public.rc_clearing_offers o where o.id = v_ids[1]));
    hasil := hasil || jsonb_build_object('uji', 'Email depot: TO KA + NPC + Kadep, CC panel, seluruh toko depot, kolom Lewat, Auto-Expiring = batas proses + 1 bulan + 1 hari (tanpa Deadline), kalimat sorotan', 'lulus', v_ok, 'rinci', r->>'message');

    select * into v_d from public.email_outbox e where e.jenis = 'debtor' and e.dibuat_pada >= v_mulai and e.konteks->>'bagian' = 'region';
    hasil := hasil || jsonb_build_object('uji', 'Laporan region: toko lewat 3-13 hari saja; TO RSM + ASM; CC Kadep + KA + CC jenjang 2 (toko terlama 8 hari) saja', 'lulus',
      'rsm.uji@contoh.co' = any(v_d.tujuan) and v_d.cc @> array['cc2.uji@contoh.co'] and not (v_d.cc && array['cc1.uji@contoh.co', 'cc3.uji@contoh.co'])
      and exists(select 1 from unnest(v_d.cc) c where c like 'kadep.%') and exists(select 1 from unnest(v_d.cc) c where c like 'ka.%')
      and v_d.isi_html ~ ('TOTAL ' || (select count(distinct b.depot_id) from rc_private.debtor_belum_proses() b where b.umur between 3 and 13) || ' DEPO')
      and v_d.isi_html ~ 'PIC UJI' and v_d.subjek ~ ('Region ' || v_reg) and v_d.isi_html !~ '>REGION</th>',
      'rinci', coalesce(v_d.subjek, '-') || ' CC ' || coalesce(array_to_string(v_d.cc, ','), '-'));
    select * into v_d from public.email_outbox e where e.jenis = 'debtor' and e.dibuat_pada >= v_mulai and e.konteks->>'bagian' = 'nasional';
    hasil := hasil || jsonb_build_object('uji', 'Laporan nasional jenjang 3: satu email semua region, kolom Region, toko lewat >= 14 hari, CC jenjang 3', 'lulus',
      v_d.id is not null and v_d.subjek ~ 'Semua Region' and v_d.cc @> array['cc3.uji@contoh.co'] and not (v_d.cc && array['cc1.uji@contoh.co', 'cc2.uji@contoh.co'])
      and v_d.isi_html ~ '>REGION</th>' and v_d.isi_html ~ 'TOTAL 1 DEPO' and 'rsm.uji@contoh.co' = any(v_d.tujuan)
      and (select count(*) from public.email_outbox e where e.jenis = 'debtor' and e.dibuat_pada >= v_mulai and e.konteks->>'bagian' = 'nasional') = 1,
      'rinci', coalesce(v_d.subjek, '-') || ' CC ' || coalesce(array_to_string(v_d.cc, ','), '-'));

    -- 4. Laporan region tiap hari laporan (tanpa penandaan): susun ulang = laporan yang sama lagi.
    r := rc_private.email_debtor_susun(v_set, false, null);
    hasil := hasil || jsonb_build_object('uji', 'Laporan region tidak ditandai: hari laporan berikutnya toko >= jenjang 1 masuk lagi; email depot tetap', 'lulus',
      (r->>'emailRegion')::int = 2 and (r->>'emailDepot')::int = v_n_dep
      and not exists(select 1 from rc_private.debtor_peringatan where offer_id = any(v_ids)), 'rinci', r->>'message');

    -- 5. Bukan hari laporan: kirim = hanya email depot; pratinjau tetap menampilkan region dengan keterangan.
    update public.email_settings set hari_list = array[((extract(dow from now() at time zone 'Asia/Jakarta')::int + 1) % 7)::smallint] where jenis = 'debtor';
    select * into v_set from public.email_settings where jenis = 'debtor';
    r := rc_private.email_debtor_susun(v_set, true, null);
    hasil := hasil || jsonb_build_object('uji', 'Kirim lagi di hari yang sama (bukan hari laporan): tidak ada laporan region, depot yang sudah dikirimi dilewati (tanpa email ganda)', 'lulus',
      (r->>'emailRegion')::int = 0 and (r->>'emailDepot')::int = 0, 'rinci', r->>'message');
    r := rc_private.email_debtor_susun(v_set, false, null);
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau di luar hari laporan: region tetap tampil dengan keterangan bukan hari laporan', 'lulus',
      (r->>'emailRegion')::int = 2 and r->>'isiHtml' ~ 'bukan hari laporan', 'rinci', r->>'message');

    -- 6. Jadwal 20261164060000: Senin 02:05 kelompok A, 03:05 kelompok B; Minggu dan tanggal merah tidak ada email depot.
    delete from public.email_outbox where jenis = 'debtor' and dibuat_pada >= v_mulai and konteks->>'bagian' = 'depot';
    select count(distinct b.depot_id) filter (where k.kelompok = 0), count(distinct b.depot_id) filter (where k.kelompok = 1) into v_a, v_b
      from rc_private.debtor_belum_proses() b join public.depots d on d.id = b.depot_id
      join rc_private.debtor_kelompok() k on k.region = coalesce(nullif(upper(btrim(d.region)), ''), '-');
    perform rc_private.debtor_jadwal('2026-11-22 02:10+07');   -- Minggu
    perform rc_private.debtor_jadwal('2026-12-25 02:10+07');   -- Natal
    v_ok := (select count(*) from public.email_outbox where jenis = 'debtor' and dibuat_pada >= v_mulai and konteks->>'bagian' = 'depot') = 0;
    perform rc_private.debtor_jadwal('2026-11-23 02:10+07');   -- Senin 02:00
    v_ok := v_ok and (select count(*) from public.email_outbox where jenis = 'debtor' and dibuat_pada >= v_mulai and konteks->>'bagian' = 'depot') = v_a;
    perform rc_private.debtor_jadwal('2026-11-23 03:10+07');   -- Senin 03:00
    perform rc_private.debtor_jadwal('2026-11-23 03:10+07');   -- terpanggil lagi: tidak ganda
    v_ok := v_ok and (select count(*) from public.email_outbox where jenis = 'debtor' and dibuat_pada >= v_mulai and konteks->>'bagian' = 'depot') = v_a + v_b
        and (select count(*) from public.email_outbox where jenis = 'debtor' and dibuat_pada >= v_mulai and konteks->>'bagian' = 'depot' and konteks->>'kelompok' = 'A') = v_a
        and pg_get_functiondef('public.rc_email_tick()'::regprocedure) ~ 'debtor_jadwal';
    hasil := hasil || jsonb_build_object('uji', 'Jadwal: Minggu / tanggal merah tanpa email depot; 02:00 kelompok A, 03:00 kelompok B, dipanggil ulang tidak ganda', 'lulus', v_ok,
      'rinci', 'A ' || v_a || ', B ' || v_b);

    -- 6b. Tanggal merah dari panel.
    perform rc_private.hari_libur_simpan(E'25-12-2026 Natal
31.12.2026 Uji libur');
    v_ok := rc_private.hari_libur_ini('2026-12-31') and not rc_private.hari_libur_ini('2026-12-24') and rc_private.hari_libur_teks() ~ '31-12-2026 Uji libur';
    begin perform rc_private.hari_libur_simpan('2026/12/30 salah'); v_ok := false; exception when others then v_ok := v_ok and sqlerrm ~ 'tidak terbaca'; end;
    hasil := hasil || jsonb_build_object('uji', 'Tanggal merah: disimpan dari teks panel (dd-mm-yyyy nama), format salah ditolak', 'lulus', v_ok, 'rinci', left(rc_private.hari_libur_teks(), 120));

    -- 7. Bahasa email.
    r := rc_private.email_debtor_susun(v_set, false, null);
    hasil := hasil || jsonb_build_object('uji', 'Bahasa: depot "Dear Team Depo", region kalimat summary pemilik', 'lulus',
      r->>'isiHtml' ~ 'Dear Team Depo,' and r->>'isiHtml' ~ 'Berikut summary toko yang sudah lunas berdasarkan data ZDAGE tetapi sampai saat ini belum diproses oleh team depo',
      'rinci', '-');

    -- 8. Test Email tidak menandai.
    r := rc_private.email_debtor_susun(v_set, true, 'sa.uji@contoh.co');
    hasil := hasil || jsonb_build_object('uji', 'Test Email: satu email ke alamat uji', 'lulus',
      (select count(*) from public.email_outbox where jenis = 'debtor' and dibuat_pada >= now() and tujuan = array['sa.uji@contoh.co']) = 1, 'rinci', r->>'message');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  insert into _hasil_lr(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_lr order by urut;
