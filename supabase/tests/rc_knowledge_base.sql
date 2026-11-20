-- ==========================================================================================
-- Uji 11 November 2026: Knowledge Base (20261163920000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_knowledge_base.sql
-- ==========================================================================================
create temp table if not exists _hasil_kb(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_kb;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_adm uuid; v_dep uuid; v_reg text; v_lain uuid; r jsonb; v_a uuid; v_b uuid; v_c uuid; v_p uuid;
  v_err text; v_n integer; v_log integer; v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_ok boolean;

  -- Jalankan sebagai akun tertentu.
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password
     and archived_at is null order by user_code limit 1;
  select p.id, a.depot_id, upper(btrim(d.region)) into v_adm, v_dep, v_reg
    from public.profiles p join public.user_depot_access a on a.user_id = p.id join public.depots d on d.id = a.depot_id
   where p.role = 'admin' and p.status = 'active' and p.archived_at is null
     and btrim(coalesce(d.region, '')) <> '' and d.archived_at is null
     and (select count(*) from public.user_depot_access x where x.user_id = p.id) = 1
   order by p.user_code limit 1;
  -- Depot di luar jangkauan admin itu dan di region lain.
  select d.id into v_lain from public.depots d
   where d.archived_at is null and upper(btrim(coalesce(d.region, ''))) <> v_reg and btrim(coalesce(d.region, '')) <> ''
   order by d.depot_code limit 1;

  begin
    if v_sm is null or v_adm is null or v_lain is null then raise exception 'Fixture: SM / admin berdepot / depot lain tidak ada'; end if;
    -- Akun admin dev umumnya masih wajib ganti PIN; dilepas di dalam uji (dibatalkan di akhir).
    update public.profiles set must_change_password = false where id = v_adm;
    -- 20261164040000: setiap jenis wajib punya Kode 3 huruf untuk No Surat otomatis.
    if to_regclass('public.rc_kb_jenis') is not null then
      execute $s$insert into public.rc_kb_jenis(jenis, kode) values ('SOP', 'UJS'), ('Pricelist', 'UJP') on conflict do nothing$s$;
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

    -- 1. Hak tab: Resources terbuka untuk admin, Management hanya bila dicentang; SM keduanya.
    v_ok := (rc_private.tab_rights(v_sm)->>'kb.resources')::boolean and (rc_private.tab_rights(v_sm)->>'kb.manage')::boolean
        and (rc_private.tab_rights(v_adm)->>'kb.resources')::boolean and not (rc_private.tab_rights(v_adm)->>'kb.manage')::boolean;
    hasil := hasil || jsonb_build_object('uji', 'Tab: Knowledge Resources bawaan semua akun, Knowledge Management hanya dicentang (SM selalu)', 'lulus', v_ok, 'rinci', '-');

    -- 2. Validasi simpan.
    v_err := ''; v_n := 0;
    begin perform public.rc_kb_simpan('{"jenis":"SOP","judul":"Uji","url":"https://x.test/a.pdf","peserta":[]}'); exception when others then v_n := v_n + 1; v_err := v_err || sqlerrm || ' | '; end;
    begin perform public.rc_kb_simpan('{"jenis":"SOP","judul":"Uji","url":"javascript:alert(1)","peserta":["admin"]}'); exception when others then v_n := v_n + 1; v_err := v_err || sqlerrm || ' | '; end;
    begin perform public.rc_kb_simpan('{"jenis":"SOP","judul":"Uji","url":"https://x.test/a.pdf","peserta":["admin"],"pinned":true}'); exception when others then v_n := v_n + 1; v_err := v_err || sqlerrm || ' | '; end;
    begin perform public.rc_kb_simpan(jsonb_build_object('jenis','SOP','judul','Uji','url','https://x.test/a.pdf','peserta',jsonb_build_array('admin'),
      'pinned',true,'pinDari',to_char(v_hari + 3,'YYYY-MM-DD'),'pinSampai',to_char(v_hari + 1,'YYYY-MM-DD'))); exception when others then v_n := v_n + 1; v_err := v_err || sqlerrm || ' | '; end;
    begin perform public.rc_kb_simpan('{"jenis":"SOP","judul":"Uji","url":"https://x.test/a.pdf","peserta":["direktur"]}'); exception when others then v_n := v_n + 1; v_err := v_err || sqlerrm || ' | '; end;
    begin perform public.rc_kb_simpan('{"jenis":"","judul":"Uji","url":"https://x.test/a.pdf","peserta":["admin"]}'); exception when others then v_n := v_n + 1; v_err := v_err || sqlerrm || ' | '; end;
    hasil := hasil || jsonb_build_object('uji', 'Validasi: tanpa peserta, link non-http, pin tanpa tanggal, Sampai < Dari, peran asing, jenis kosong ditolak', 'lulus', v_n = 6, 'rinci', v_err);

    -- 3. Tiga dokumen: A untuk Admin semua wilayah (pin hari ini s/d +7), B untuk OSC region admin, C untuk Admin depot lain.
    r := public.rc_kb_simpan(jsonb_build_object('jenis','SOP','judul','UJIKB SOP Klaim','deskripsi','Uji','url','https://x.test/sop.pdf',
           'peserta',jsonb_build_array('admin','depot head'),'pinned',true,'pinDari',to_char(v_hari,'YYYY-MM-DD'),'pinSampai',to_char(v_hari + 7,'YYYY-MM-DD')));
    v_a := (r->>'id')::uuid;
    r := public.rc_kb_simpan(jsonb_build_object('jenis','Pricelist','judul','UJIKB Pricelist','url','https://x.test/pl.pdf',
           'peserta',jsonb_build_array('osc'),'regions',jsonb_build_array(v_reg)));
    v_b := (r->>'id')::uuid;
    r := public.rc_kb_simpan(jsonb_build_object('jenis','sop','judul','UJIKB SOP lain','url','https://x.test/sop2.pdf',
           'peserta',jsonb_build_array('admin'),'depotIds',jsonb_build_array(v_lain)));
    v_c := (r->>'id')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Jenis "sop" memakai penulisan yang sudah ada ("SOP")',
      'lulus', (select jenis from public.rc_kb_items where id = v_c) = 'SOP', 'rinci', (select jenis from public.rc_kb_items where id = v_c));

    -- 4. Sebagai admin: hanya A yang terlihat, pin di atas, badge menghitung A.
    perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
    r := public.rc_kb_list();
    hasil := hasil || jsonb_build_object('uji', 'Admin hanya melihat dokumen untuk perannya dan wilayahnya; pin aktif di atas',
      'lulus', exists(select 1 from jsonb_array_elements(r->'rows') e where (e->>'id')::uuid = v_a and (e->>'pin')::boolean)
           and not exists(select 1 from jsonb_array_elements(r->'rows') e where (e->>'id')::uuid in (v_b, v_c))
           and (r->'rows'->0->>'pin')::boolean,
      'rinci', (select string_agg(e->>'judul', ', ') from jsonb_array_elements(r->'rows') e));
    v_n := (public.rc_kb_belum()->>'belum')::integer;
    hasil := hasil || jsonb_build_object('uji', 'Badge belum dibaca = jumlah dokumen belum acknowledge di daftar',
      'lulus', v_n = (r->>'belum')::integer and v_n >= 1, 'rinci', v_n::text);

    -- 5. Acknowledge sebelum membuka ditolak; dokumen bukan untuknya ditolak.
    v_n := 0;
    begin perform public.rc_kb_ack(v_a, 1); exception when others then if sqlerrm ~ 'Buka dan baca dokumennya' then v_n := v_n + 1; end if; end;
    begin perform public.rc_kb_buka(v_b); exception when others then if sqlerrm ~ 'tidak ditujukan' then v_n := v_n + 1; end if; end;
    begin perform public.rc_kb_ack(v_c, 1); exception when others then if sqlerrm ~ 'tidak ditujukan' then v_n := v_n + 1; end if; end;
    hasil := hasil || jsonb_build_object('uji', 'Acknowledge sebelum dibuka ditolak; dokumen peran / wilayah lain ditolak', 'lulus', v_n = 3, 'rinci', v_n::text);

    -- 6. Buka lalu acknowledge: tercatat, badge turun, satu baris Log Activity.
    v_n := (public.rc_kb_belum()->>'belum')::integer;
    perform public.rc_kb_buka(v_a);
    perform public.rc_kb_buka(v_a);
    v_log := (select count(*) from public.activity_logs where event_type = 'kb_acknowledge' and actor_id = v_adm);
    r := public.rc_kb_ack(v_a, 1);
    hasil := hasil || jsonb_build_object('uji', 'Buka lalu Acknowledge: tercatat dengan pernyataan, badge berkurang satu, satu Log Activity',
      'lulus', (r->>'status') = 'success'
           and (select ack_versi = 1 and jumlah_buka = 2 and pernyataan ~ '^Saya sudah membaca dan memahami isi dari SOP tersebut, dan saya akan mengimplementasikannya'
                  from public.rc_kb_baca where item_id = v_a and user_id = v_adm)
           and (public.rc_kb_belum()->>'belum')::integer = v_n - 1
           and (select count(*) from public.activity_logs where event_type = 'kb_acknowledge' and actor_id = v_adm) = v_log + 1,
      'rinci', r->>'message');
    r := public.rc_kb_ack(v_a, 1);
    hasil := hasil || jsonb_build_object('uji', 'Acknowledge kedua kali tidak menggandakan', 'lulus', (r->>'sudah')::boolean
      and (select count(*) from public.activity_logs where event_type = 'kb_acknowledge' and actor_id = v_adm) = v_log + 1, 'rinci', '-');

    -- 7. Admin tidak memegang Knowledge Management.
    v_ok := false;
    begin perform public.rc_kb_kelola_list(false); exception when others then v_ok := sqlstate = '42501'; end;
    hasil := hasil || jsonb_build_object('uji', 'Admin tanpa centang tidak dapat membuka Knowledge Management', 'lulus', v_ok, 'rinci', '-');

    -- 8. Details sebagai SM: admin tercatat Acknowledged di depot dan regionnya.
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_kb_detail(v_a);
    hasil := hasil || jsonb_build_object('uji', 'Details: ringkasan, per region, per depot, dan daftar akun memuat admin sebagai Acknowledged',
      'lulus', (r->'ringkas'->>'sudah')::integer >= 1 and (r->'ringkas'->>'target')::integer >= (r->'ringkas'->>'sudah')::integer
           and (r->'ringkas'->>'target')::integer = (r->'ringkas'->>'sudah')::integer + (r->'ringkas'->>'dibukaBelum')::integer + (r->'ringkas'->>'belumDibuka')::integer
           and exists(select 1 from jsonb_array_elements(r->'region') e where e->>'region' = v_reg and (e->>'sudah')::integer >= 1)
           and exists(select 1 from jsonb_array_elements(r->'depot') e where e->>'kode' = (select depot_code from public.depots where id = v_dep) and (e->>'sudah')::integer >= 1)
           and exists(select 1 from jsonb_array_elements(r->'akun') e where e->>'userCode' = (select user_code from public.profiles where id = v_adm)
                        and e->>'status' = 'Acknowledged' and e->>'peran' = 'Admin'),
      'rinci', (r->'ringkas')::text);
    -- Hasil fungsi STABLE disimpan ke variabel dulu: di klausa WHERE perencana kueri dapat
    -- mengevaluasinya lebih awal dengan snapshot sebelum baris uji dibuat.
    r := public.rc_kb_kelola_list(false);
    v_n := (public.rc_kb_detail(v_a)->'ringkas'->>'sudah')::integer;
    v_log := (public.rc_kb_detail(null)->'ringkas'->>'dokumen')::integer;
    hasil := hasil || jsonb_build_object('uji', 'Knowledge Management: progres per dokumen sama dengan Details',
      'lulus', exists(select 1 from jsonb_array_elements(r->'rows') e where (e->>'id')::uuid = v_a
                        and (e->>'sudah')::integer = v_n
                        and e->>'pesertaTeks' = 'Admin, Kepala Depot' and e->>'wilayah' = 'Semua wilayah')
           and v_log >= 3,
      'rinci', '-');

    -- 9. Ubah dengan baca ulang: versi naik, admin wajib membuka dan acknowledge lagi.
    r := public.rc_kb_simpan(jsonb_build_object('id', v_a, 'jenis','SOP','judul','UJIKB SOP Klaim rev','url','https://x.test/sop-rev.pdf',
           'peserta',jsonb_build_array('admin','depot head'),'bacaUlang',true));
    perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
    r := public.rc_kb_list();
    v_n := 0;
    begin perform public.rc_kb_ack(v_a, 1); exception when others then if sqlerrm ~ 'direvisi' then v_n := 1; end if; end;
    hasil := hasil || jsonb_build_object('uji', 'Baca ulang: versi 2, status kembali belum acknowledge (revisi), acknowledge versi lama ditolak',
      'lulus', v_n = 1 and exists(select 1 from jsonb_array_elements(r->'rows') e where (e->>'id')::uuid = v_a
                        and not (e->>'ack')::boolean and not (e->>'dibuka')::boolean and (e->>'revisi')::boolean and (e->>'versi')::integer = 2
                        and not (e->>'pin')::boolean),
      'rinci', '-');

    -- 10. Arsip dengan alasan: hilang dari daftar peserta; pulihkan: kembali.
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    v_ok := false;
    begin perform public.rc_kb_arsip(array[v_a], true, ''); exception when others then v_ok := sqlerrm ~ 'Alasan'; end;
    perform public.rc_kb_arsip(array[v_a], true, 'Uji arsip');
    perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
    v_ok := v_ok and not exists(select 1 from jsonb_array_elements(public.rc_kb_list()->'rows') e where (e->>'id')::uuid = v_a);
    v_n := 0;
    begin perform public.rc_kb_buka(v_a); exception when others then if sqlerrm ~ 'diarsip' then v_n := 1; end if; end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    perform public.rc_kb_arsip(array[v_a], false, null);
    perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
    v_ok := v_ok and v_n = 1 and exists(select 1 from jsonb_array_elements(public.rc_kb_list()->'rows') e where (e->>'id')::uuid = v_a);
    hasil := hasil || jsonb_build_object('uji', 'Arsip wajib alasan, menyembunyikan dan mengunci dokumen; pulihkan menampilkannya kembali', 'lulus', v_ok, 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_kb(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_kb order by urut;
