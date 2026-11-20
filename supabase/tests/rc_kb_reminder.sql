-- ==========================================================================================
-- Uji 19 November 2026: Knowledge Base "Opened", pernyataan sanksi, email reminder acknowledge (20261164070000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_kb_reminder.sql
-- ==========================================================================================
create temp table if not exists _hasil_kbr(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_kbr;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_adm uuid; v_id uuid; r jsonb; v_set public.email_settings; v_ok boolean; v_html text; v_n integer;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password and archived_at is null order by user_code limit 1;
  select p.id into v_adm from public.profiles p where p.role = 'admin' and p.status = 'active' and p.archived_at is null
     and exists(select 1 from public.user_depot_access a where a.user_id = p.id) order by p.user_code limit 1;
  begin
    if v_sm is null or v_adm is null then raise exception 'Fixture: SM / admin berdepot tidak ada'; end if;
    update public.profiles set must_change_password = false, business_email = 'admin.kbuji@contoh.co', full_name = 'Admin KB Uji' where id = v_adm;
    -- Hanya dokumen uji yang menunggu acknowledge: dokumen lain ditandai sudah untuk akun ini.
    delete from public.email_outbox where jenis = 'kb' and dibuat_pada >= date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta';
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    insert into public.rc_kb_jenis(jenis, kode) values ('UJIKBR Jenis', 'QZR') on conflict do nothing;
    r := public.rc_kb_simpan(jsonb_build_object('jenis', 'UJIKBR Jenis', 'kode', '901', 'judul', 'UJIKBR Surat Edaran', 'url', 'https://x.test/r.pdf',
           'peserta', jsonb_build_array('admin'), 'tglTerbit', '2026-11-10'));
    v_id := (r->>'id')::uuid;
    insert into public.rc_kb_baca(item_id, user_id, buka_versi, ack_versi, ack_at)
    select q.item_id, q.user_id, i.versi, i.versi, now() from rc_private.kb_pasangan(array(select id from public.rc_kb_items where id <> v_id)) q
      join public.rc_kb_items i on i.id = q.item_id where q.user_id = v_adm
    on conflict (item_id, user_id) do update set ack_versi = excluded.ack_versi, buka_versi = excluded.buka_versi;
    perform set_config('request.jwt.claims', '', true);
    select * into v_set from public.email_settings where jenis = 'kb';

    -- 1. Jadwal bawaan dan pernyataan.
    hasil := hasil || jsonb_build_object('uji', 'Jenis kb: Email Otomatis, bawaan aktif 08:00 Senin-Sabtu; pernyataan memuat kesiapan menerima sanksi', 'lulus',
      v_set.jenis = 'kb' and v_set.jam = 8 and v_set.hari_list = array[1, 2, 3, 4, 5, 6]::smallint[]
      and rc_private.kb_pernyataan('SOP Memo Nasional') ~ 'SOP Memo Nasional tersebut, dan saya akan mengimplementasikannya'
      and rc_private.kb_pernyataan('SOP Memo Nasional') ~ 'Saya siap menerima peringatan dan sanksi dari perusahaan sebagai konsekuensi apabila sewaktu-waktu saya dan team saya terbukti tidak melaksanakan isi sesuai dengan ketentuan yang berlaku\.$',
      'rinci', rc_private.kb_pernyataan('SOP'));

    -- 2. Pratinjau: email untuk admin berisi kalimat dan kolom pemilik.
    r := rc_private.email_kb_susun(v_set, false, null);
    v_html := r->>'isiHtml';
    v_ok := v_html ~ 'admin\.kbuji@contoh\.co' and v_html ~ 'Berikut di bawah ini surat yang belum dibaca dan ditandai acknowledge;'
        and v_html ~ 'NO SURAT</th><th[^>]*>NAMA SURAT</th><th[^>]*>TANGGAL KELUAR SURAT' and v_html ~ '1/SAN/QZR/XI/2026'
        and v_html ~ 'UJIKBR Surat Edaran' and v_html ~ '10-Nov-2026'
        and v_html ~ 'Mohon untuk user <strong>Admin KB Uji</strong> segera menandai acknowledge surat tersebut sebagai bukti bahwa kepala admin dan semua team depot sudah memahami dengan baik dan menjalankan semuanya sesuai isi surat';
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau: email ke akun ybs, kolom No Surat / Nama Surat / Tanggal Keluar Surat, kalimat pemilik', 'lulus', v_ok, 'rinci', r->>'message');

    -- 3. Kirim: satu email ke Business Email akun; dikirim lagi hari yang sama = tidak ganda.
    r := rc_private.email_kb_susun(v_set, true, null);
    select count(*) into v_n from public.email_outbox where jenis = 'kb' and dibuat_pada >= now() and konteks->>'user' = v_adm::text and tujuan = array['admin.kbuji@contoh.co'];
    r := rc_private.email_kb_susun(v_set, true, null);
    hasil := hasil || jsonb_build_object('uji', 'Kirim: satu email ke Business Email akun; dikirim lagi hari yang sama tidak ganda', 'lulus',
      v_n = 1 and (select count(*) from public.email_outbox where jenis = 'kb' and dibuat_pada >= now() and konteks->>'user' = v_adm::text) = 1,
      'rinci', v_n::text);

    -- 4. Sesudah buka + acknowledge: akun tidak lagi masuk reminder.
    perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
    perform public.rc_kb_buka(v_id);
    r := public.rc_kb_ack(v_id, null);
    perform set_config('request.jwt.claims', '', true);
    r := rc_private.email_kb_susun(v_set, false, null);
    hasil := hasil || jsonb_build_object('uji', 'Sesudah acknowledge (pernyataan baru tersimpan): akun tidak lagi mendapat reminder', 'lulus',
      coalesce(r->>'isiHtml', '') !~ 'admin\.kbuji@contoh\.co'
      and (select pernyataan ~ 'sanksi dari perusahaan' from public.rc_kb_baca where item_id = v_id and user_id = v_adm), 'rinci', r->>'message');

    -- 5. Details: status "Opened"; Resources membawa peserta dan wilayah.
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    update public.rc_kb_baca set ack_versi = null, ack_at = null where item_id = v_id and user_id = v_adm;
    r := public.rc_kb_detail(v_id);
    v_ok := exists(select 1 from jsonb_array_elements(r->'akun') a where a->>'status' = 'Opened')
        and not exists(select 1 from jsonb_array_elements(r->'akun') a where a->>'status' ~ 'Dibuka');
    perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
    r := public.rc_kb_list();
    v_ok := v_ok and exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'id' = v_id::text and x->>'pesertaTeks' = 'Admin' and x->>'wilayah' = 'Semua wilayah');
    perform set_config('request.jwt.claims', '', true);
    hasil := hasil || jsonb_build_object('uji', 'Details: status Opened (bukan "Dibuka, belum acknowledge"); daftar Resources membawa peserta dan wilayah', 'lulus', v_ok, 'rinci', '-');

    -- 6. Jadwal: tidak pada tanggal merah; tanpa PDF.
    hasil := hasil || jsonb_build_object('uji', 'Tick melewati jenis kb pada tanggal merah; email tanpa lampiran PDF', 'lulus',
      pg_get_functiondef('public.rc_email_tick()'::regprocedure) ~ 's.jenis = ''kb'' and rc_private.hari_libur_ini' and not rc_private.email_perlu_pdf('kb'), 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_kbr(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_kbr order by urut;
