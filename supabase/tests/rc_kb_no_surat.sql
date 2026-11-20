-- ==========================================================================================
-- Uji 17 November 2026: Knowledge Base No Surat otomatis, Upload Excel, PDF (20261164040000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_kb_no_surat.sql
-- ==========================================================================================
create temp table if not exists _hasil_kbn(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_kbn;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_adm uuid; r jsonb; r2 jsonb; v_n integer; v_im integer; v_err text; v_id uuid; v_log integer;
  v_ok boolean; v_x text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password
     and archived_at is null order by user_code limit 1;
  select id into v_adm from public.profiles where role = 'admin' and status = 'active' and archived_at is null order by user_code limit 1;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    select nomor_terakhir into v_n from public.rc_kb_jenis where kode = 'SOP';
    select nomor_terakhir into v_im from public.rc_kb_jenis where kode = 'IMO';

    -- 1. Nomor otomatis format baru, bulan romawi dan tahun dari Tanggal Terbit.
    r := public.rc_kb_simpan(jsonb_build_object('jenis', 'sop memo nasional', 'kode', '901', 'judul', 'UJIKBN SOP baru', 'url', 'https://x.test/1.pdf',
           'peserta', jsonb_build_array('admin'), 'tglTerbit', '2026-04-15'));
    hasil := hasil || jsonb_build_object('uji', 'SOP baru: No Surat {urut}/SAN/SOP/IV/2026, jenis memakai penulisan Kode Jenis', 'lulus',
      r->>'noSurat' = (v_n + 1) || '/SAN/SOP/IV/2026'
      and (select jenis from public.rc_kb_items where id = (r->>'id')::uuid) = 'SOP Memo Nasional', 'rinci', r::text);
    r := public.rc_kb_simpan(jsonb_build_object('jenis', 'SOP Memo Nasional', 'kode', '902', 'judul', 'UJIKBN SOP baru 2', 'url', 'https://x.test/2.pdf',
           'peserta', jsonb_build_array('admin'), 'tglTerbit', '2027-01-03'));
    hasil := hasil || jsonb_build_object('uji', 'Nomor berikutnya lanjut lintas tahun (tidak kembali ke 1)', 'lulus',
      r->>'noSurat' = (v_n + 2) || '/SAN/SOP/I/2027' and (select nomor_terakhir from public.rc_kb_jenis where kode = 'SOP') = v_n + 2, 'rinci', r::text);

    -- 2. Nomor lama diketik dipakai apa adanya; nomor sama (beda spasi / huruf) ditolak.
    r := public.rc_kb_simpan(jsonb_build_object('jenis', 'SOP Memo Nasional', 'kode', '903', 'judul', 'UJIKBN SOP lama', 'url', 'https://x.test/3.pdf',
           'peserta', jsonb_build_array('admin'), 'tglTerbit', '2023-07-12', 'noSurat', '921 / SAN / VII / 2023'));
    v_err := '';
    begin perform public.rc_kb_simpan(jsonb_build_object('jenis', 'SOP Memo Nasional', 'kode', '904', 'judul', 'UJIKBN ganda', 'url', 'https://x.test/4.pdf',
           'peserta', jsonb_build_array('admin'), 'noSurat', '921/san/VII/2023'));
    exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'No Surat lama dipakai apa adanya; nomor yang sama (beda spasi / huruf) ditolak; nomor urut tidak bergeser', 'lulus',
      r->>'noSurat' = '921 / SAN / VII / 2023' and v_err ~ 'sudah dipakai' and (select nomor_terakhir from public.rc_kb_jenis where kode = 'SOP') = v_n + 2,
      'rinci', v_err);

    -- 3. Lampiran tanpa nomor sendiri, menampilkan nomor induknya.
    r := public.rc_kb_simpan(jsonb_build_object('jenis', 'SOP Memo Nasional', 'kode', '903a', 'judul', 'UJIKBN Formulir lampiran', 'url', 'https://x.test/3a.pdf',
           'peserta', jsonb_build_array('admin'), 'tglTerbit', '2023-07-12'));
    hasil := hasil || jsonb_build_object('uji', 'Lampiran 903a: tanpa nomor sendiri, tampil dengan No Surat induk 903', 'lulus',
      r->>'noSurat' = '921 / SAN / VII / 2023' and (select no_surat is null from public.rc_kb_items where id = (r->>'id')::uuid)
      and (select nomor_terakhir from public.rc_kb_jenis where kode = 'SOP') = v_n + 2, 'rinci', r::text);

    -- 4. Internal Memo 3 digit; Kode Dokumen ganda dalam jenis ditolak.
    r := public.rc_kb_simpan(jsonb_build_object('jenis', 'Internal Memo', 'kode', '901', 'judul', 'UJIKBN memo', 'url', 'https://x.test/m.pdf',
           'peserta', jsonb_build_array('admin'), 'tglTerbit', '2026-11-17'));
    v_err := '';
    begin perform public.rc_kb_simpan(jsonb_build_object('jenis', 'Internal Memo', 'kode', '901', 'judul', 'UJIKBN memo ganda', 'url', 'https://x.test/m2.pdf',
           'peserta', jsonb_build_array('admin'))); exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Internal Memo: {3 digit}/SAN/IMO/XI/2026; Kode Dokumen ganda ditolak', 'lulus',
      r->>'noSurat' = lpad((v_im + 1)::text, 3, '0') || '/SAN/IMO/XI/2026' and v_err ~ 'sudah dipakai', 'rinci', (r->>'noSurat') || ' | ' || v_err);

    -- 5. Jenis baru tanpa kode ditolak; dengan kode 3 huruf dibuat dan bernomor 1.
    v_err := '';
    begin perform public.rc_kb_simpan(jsonb_build_object('jenis', 'UJIKBN Jenis', 'judul', 'x', 'url', 'https://x.test/j.pdf', 'peserta', jsonb_build_array('admin')));
    exception when others then v_err := sqlerrm; end;
    r := public.rc_kb_simpan(jsonb_build_object('jenis', 'UJIKBN Jenis', 'kodeJenis', 'qzx', 'judul', 'x', 'url', 'https://x.test/j.pdf',
           'peserta', jsonb_build_array('admin'), 'tglTerbit', '2026-02-01'));
    hasil := hasil || jsonb_build_object('uji', 'Jenis baru tanpa Kode Jenis ditolak; dengan kode QZX bernomor 1/SAN/QZX/II/2026', 'lulus',
      v_err ~ 'Kode 3 huruf' and r->>'noSurat' = '1/SAN/QZX/II/2026', 'rinci', v_err || ' | ' || (r->>'noSurat'));

    -- 6. Ubah tanpa mengetik nomor: nomor tetap.
    v_id := (r->>'id')::uuid;
    r := public.rc_kb_simpan(jsonb_build_object('id', v_id, 'jenis', 'UJIKBN Jenis', 'judul', 'x diubah', 'url', 'https://x.test/j.pdf',
           'peserta', jsonb_build_array('admin'), 'tglTerbit', '2026-05-01'));
    hasil := hasil || jsonb_build_object('uji', 'Ubah dokumen: No Surat tetap walau Tanggal Terbit berubah', 'lulus',
      (select no_surat from public.rc_kb_items where id = v_id) = '1/SAN/QZX/II/2026', 'rinci', r::text);

    -- 7. Upload: pratinjau tidak menyimpan dan tidak memakai nomor; urut nomor mengikuti Tanggal Terbit.
    select count(*) into v_log from public.activity_logs where event_type = 'kb_unggah' and created_at >= now();
    r := public.rc_kb_unggah(jsonb_build_array(
      jsonb_build_object('baris', 2, 'jenis', 'SOP MEMO NASIONAL', 'kode', '950', 'judul', 'UJIKBN U baru (terbit belakangan)', 'tglTerbit', '2026-06-01',
                         'url', 'https://x.test/u1', 'pesertaTeks', 'Semua', 'regionTeks', '', 'depotTeks', '', 'keyword', E'a b'),
      jsonb_build_object('baris', 3, 'jenis', 'SOP Memo Nasional', 'kode', '951', 'judul', 'UJIKBN U baru (terbit lebih dulu)', 'tglTerbit', '2026-05-01',
                         'url', 'https://x.test/u2', 'pesertaTeks', 'Admin, Kepala Depot'),
      jsonb_build_object('baris', 4, 'jenis', 'SOP Memo Nasional', 'kode', '952', 'judul', 'UJIKBN lama', 'tglTerbit', '2022-01-04',
                         'url', 'https://x.test/u3', 'pesertaTeks', 'Admin', 'noSurat', '3/SAN/I/2099'),
      jsonb_build_object('baris', 5, 'jenis', 'SOP Memo Nasional', 'kode', '953', 'judul', 'UJIKBN peserta salah', 'tglTerbit', '2026-01-01',
                         'url', 'https://x.test/u4', 'pesertaTeks', 'Direktur'),
      jsonb_build_object('baris', 6, 'jenis', 'SOP Memo Nasional', 'kode', '', 'judul', 'UJIKBN tanpa kode', 'tglTerbit', '2026-01-01',
                         'url', 'https://x.test/u5', 'pesertaTeks', 'Admin'),
      jsonb_build_object('baris', 7, 'jenis', 'SOP Memo Nasional', 'kode', '954', 'judul', 'UJIKBN depot salah', 'tglTerbit', '2026-01-01',
                         'url', 'https://x.test/u6', 'pesertaTeks', 'Admin', 'depotTeks', 'ZZ9'),
      jsonb_build_object('baris', 8, 'jenis', 'SOP Memo Nasional', 'kode', '955', 'judul', 'UJIKBN tgl salah', 'galat', 'Tanggal Terbit tidak terbaca: 31.02.2026')
    ), false, 'uji.xlsx');
    v_ok := not (r->>'simpan')::boolean and (r->>'baru')::integer = 3 and (r->>'galat')::integer = 4
        and not exists(select 1 from public.rc_kb_items where judul like 'UJIKBN U %')
        and (select nomor_terakhir from public.rc_kb_jenis where kode = 'SOP') = v_n + 2
        and (select x->>'noSurat' from jsonb_array_elements(r->'baris') x where x->>'baris' = '3') = (v_n + 3) || '/SAN/SOP/V/2026'
        and (select x->>'noSurat' from jsonb_array_elements(r->'baris') x where x->>'baris' = '2') = (v_n + 4) || '/SAN/SOP/VI/2026';
    hasil := hasil || jsonb_build_object('uji', 'Upload pratinjau: 3 baru, 4 galat, tidak tersimpan, nomor urut tidak terpakai; nomor mengikuti Tanggal Terbit', 'lulus', v_ok,
      'rinci', left(r::text, 1500));

    r := public.rc_kb_unggah(r->'baris', false, 'x');  -- baris hasil bukan baris unggah: semua galat, aman
    r := public.rc_kb_unggah(jsonb_build_array(
      jsonb_build_object('baris', 2, 'jenis', 'SOP MEMO NASIONAL', 'kode', '950', 'judul', 'UJIKBN U baru (terbit belakangan)', 'tglTerbit', '2026-06-01',
                         'url', 'https://x.test/u1', 'pesertaTeks', 'Semua', 'keyword', E'a b'),
      jsonb_build_object('baris', 3, 'jenis', 'SOP Memo Nasional', 'kode', '951', 'judul', 'UJIKBN U baru (terbit lebih dulu)', 'tglTerbit', '2026-05-01',
                         'url', 'https://x.test/u2', 'pesertaTeks', 'Admin, Kepala Depot'),
      jsonb_build_object('baris', 5, 'jenis', 'SOP Memo Nasional', 'kode', '953', 'judul', 'UJIKBN peserta salah', 'tglTerbit', '2026-01-01',
                         'url', 'https://x.test/u4', 'pesertaTeks', 'Direktur')), true, 'uji.xlsx');
    v_ok := (r->>'baru')::integer = 2 and (r->>'galat')::integer = 1
        and (select no_surat from public.rc_kb_items where kode_dok = '951' and archived_at is null and jenis = 'SOP Memo Nasional') = (v_n + 3) || '/SAN/SOP/V/2026'
        and (select keyword from public.rc_kb_items where kode_dok = '950' and archived_at is null and jenis = 'SOP Memo Nasional') = 'a b'
        and (select cardinality(peserta) from public.rc_kb_items where kode_dok = '950' and archived_at is null and jenis = 'SOP Memo Nasional') = 8
        and (select count(*) from public.activity_logs where event_type = 'kb_unggah' and created_at >= now()) = v_log + 1;
    hasil := hasil || jsonb_build_object('uji', 'Upload simpan: 2 baru dengan nomor urut, keyword dibersihkan, Semua = 8 peran, satu Log Activity', 'lulus', v_ok, 'rinci', left(r::text, 800));

    -- 8. Upload ulang Kode Dokumen yang sama: diperbarui, nomor tetap, versi naik bila ada Tanggal Update baru.
    r := public.rc_kb_unggah(jsonb_build_array(
      jsonb_build_object('baris', 2, 'jenis', 'SOP Memo Nasional', 'kode', '951', 'judul', 'UJIKBN U baru revisi', 'tglTerbit', '2026-05-01',
                         'tglUpdate', jsonb_build_array('2026-11-10'), 'url', 'https://x.test/u2', 'pesertaTeks', 'Admin')), true, 'uji2.xlsx');
    v_ok := (r->>'diperbarui')::integer = 1 and (r->'baris'->0->>'bacaUlang')::boolean
        and (select versi = 2 and no_surat = (v_n + 3) || '/SAN/SOP/V/2026' and judul = 'UJIKBN U baru revisi'
               from public.rc_kb_items where kode_dok = '951' and archived_at is null and jenis = 'SOP Memo Nasional');
    hasil := hasil || jsonb_build_object('uji', 'Upload ulang: diperbarui, No Surat tetap, Tanggal Update baru menaikkan versi', 'lulus', v_ok, 'rinci', left(r::text, 600));

    -- 9. Kode Jenis: kode dipakai jenis lain ditolak; nomor terakhir tidak boleh di bawah nomor terpakai.
    v_err := '';
    begin perform public.rc_kb_jenis_simpan('{"jenis":"SOP Module SD","kode":"SOP"}'); exception when others then v_err := v_err || sqlerrm || ' | '; end;
    begin perform public.rc_kb_jenis_simpan(jsonb_build_object('jenis', 'SOP Memo Nasional', 'kode', 'SOP', 'nomorTerakhir', v_n)); exception when others then v_err := v_err || sqlerrm || ' | '; end;
    r := public.rc_kb_jenis_simpan('{"jenis":"Pricelist UJIKBN","kode":"QZY","digit":2,"nomorTerakhir":5}');
    r2 := public.rc_kb_jenis_list();
    hasil := hasil || jsonb_build_object('uji', 'Kode Jenis: kode ganda dan nomor turun ditolak; jenis baru tersimpan dengan contoh nomor', 'lulus',
      v_err ~ 'sudah dipakai jenis' and v_err ~ 'lebih kecil'
      and exists(select 1 from jsonb_array_elements(r2->'rows') x where x->>'kode' = 'QZY' and x->>'contoh' ~ '^06/SAN/QZY/'), 'rinci', v_err);

    -- 10. PDF: jalur yang belum terunggah ditolak; peserta tidak dapat membaca berkas yang bukan miliknya.
    v_err := '';
    begin perform public.rc_kb_simpan(jsonb_build_object('jenis', 'SOP Memo Nasional', 'kode', '960', 'judul', 'UJIKBN pdf', 'filePath', gen_random_uuid()::text || '/a.pdf',
           'peserta', jsonb_build_array('admin'))); exception when others then v_err := sqlerrm; end;
    v_ok := v_err ~ 'belum terunggah' and public.rc_kb_pdf_boleh(gen_random_uuid()::text || '/a.pdf', true)
        and not public.rc_kb_pdf_boleh('../etc/a.pdf', true);
    if v_adm is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
      v_ok := v_ok and not public.rc_kb_pdf_boleh(gen_random_uuid()::text || '/a.pdf', true) and not public.rc_kb_pdf_boleh(gen_random_uuid()::text || '/a.pdf', false);
      perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    end if;
    hasil := hasil || jsonb_build_object('uji', 'PDF: belum terunggah ditolak; hanya pengelola boleh unggah; admin tidak bisa membaca berkas asing', 'lulus', v_ok, 'rinci', v_err);

    -- 10b. Link dan / atau PDF: keduanya boleh; tanpa keduanya ditolak; upload ulang tidak melepas PDF.
    v_x := gen_random_uuid()::text || '/uji.pdf';
    insert into storage.objects(bucket_id, name) values ('kb-pdf', v_x);
    v_err := '';
    begin perform public.rc_kb_simpan(jsonb_build_object('jenis', 'SOP Memo Nasional', 'kode', '961', 'judul', 'UJIKBN kosong', 'peserta', jsonb_build_array('admin')));
    exception when others then v_err := sqlerrm; end;
    r := public.rc_kb_simpan(jsonb_build_object('jenis', 'SOP Memo Nasional', 'kode', '962', 'judul', 'UJIKBN keduanya', 'url', 'https://x.test/k.pdf',
           'filePath', v_x, 'fileNama', 'uji.pdf', 'peserta', jsonb_build_array('admin'), 'tglTerbit', '2026-11-17'));
    v_id := (r->>'id')::uuid;
    r2 := public.rc_kb_unggah(jsonb_build_array(jsonb_build_object('baris', 2, 'jenis', 'SOP Memo Nasional', 'kode', '962', 'judul', 'UJIKBN keduanya',
           'tglTerbit', '2026-11-17', 'url', '', 'pesertaTeks', 'Admin')), true, 'uji3.xlsx');
    v_ok := v_err ~ 'minimal salah satu'
        and (r2->>'diperbarui')::integer = 1
        and (select url = 'https://x.test/k.pdf' and file_path = v_x and file_nama = 'uji.pdf' and versi = 1 from public.rc_kb_items where id = v_id);
    r2 := public.rc_kb_unggah(jsonb_build_array(jsonb_build_object('baris', 2, 'jenis', 'SOP Memo Nasional', 'kode', '963', 'judul', 'UJIKBN baru tanpa link',
           'tglTerbit', '2026-11-17', 'url', '', 'pesertaTeks', 'Admin')), false, 'uji4.xlsx');
    v_ok := v_ok and r2->'baris'->0->>'pesan' ~ 'minimal salah satu'
        and exists(select 1 from jsonb_array_elements(public.rc_kb_kelola_list(false)->'rows') x
                    where x->>'id' = v_id::text and x->>'file' = v_x and x->>'url' = 'https://x.test/k.pdf');
    hasil := hasil || jsonb_build_object('uji', 'Link + PDF boleh keduanya; tanpa keduanya ditolak; upload dengan Link kosong mempertahankan Link dan PDF; dokumen baru tanpa Link / PDF ditolak', 'lulus', v_ok,
      'rinci', v_err || ' | ' || coalesce(r2->'baris'->0->>'pesan', ''));

    -- 11. Daftar menampilkan kolom baru.
    r := public.rc_kb_kelola_list(false);
    hasil := hasil || jsonb_build_object('uji', 'Knowledge Management memuat noTampil, kode, keyword, Tanggal Terbit, kodeJenis', 'lulus',
      exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'kode' = '903a' and x->>'noTampil' = '921 / SAN / VII / 2023' and x->>'noSurat' = '')
      and r->'kodeJenis'->>'internal memo' = 'IMO', 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_kbn(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_kbn order by urut;
