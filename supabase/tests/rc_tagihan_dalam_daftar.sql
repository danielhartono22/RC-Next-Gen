-- ==========================================================================================
-- Uji 14 November 2026: Tagihan ikut di baris tab Open dan Document Center (20261163960000)
-- ==========================================================================================
-- Hanya membaca; seluruh perubahan setelan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_tagihan_dalam_daftar.sql
-- ==========================================================================================
create temp table if not exists _hasil_td(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_td;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_adm uuid; r jsonb; t jsonb; v_n integer; v_beda integer; v_ada integer; v_docs text[]; k record; v_layar integer;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and suffix_num ~ '^[0-9]{3}$' order by user_code limit 1;
  begin
    update public.profiles set must_change_password = false where id = v_sm;
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';

    -- 1 & 2. System Manager: setiap baris membawa 'tagihan' yang sama persis dengan rc_tagihan_dokumen.
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_open_claims_filtered('', '', 0, 200, '');
    select array_agg(upper(x->>'noDoc')) into v_docs from jsonb_array_elements(r->'rows') x;
    t := public.rc_tagihan_dokumen(v_docs)->'data';
    select count(*), count(*) filter (where x->'tagihan' is distinct from t->upper(x->>'noDoc')), count(*) filter (where x->'tagihan'->>'status' = 'ada')
      into v_n, v_beda, v_ada from jsonb_array_elements(r->'rows') x;
    hasil := hasil || jsonb_build_object('uji', 'Open (SM): tagihan di baris = rc_tagihan_dokumen', 'lulus', v_n > 0 and v_beda = 0,
      'rinci', v_n || ' baris, beda ' || v_beda || ', bertagihan ' || v_ada);

    r := public.rc_compilation_list(p_limit => 200);
    select array_agg(upper(x->>'noDoc')) into v_docs from jsonb_array_elements(r->'rows') x;
    t := public.rc_tagihan_dokumen(v_docs)->'data';
    select count(*), count(*) filter (where x->'tagihan' is distinct from t->upper(x->>'noDoc')), count(*) filter (where x->'tagihan'->>'status' = 'ada')
      into v_n, v_beda, v_ada from jsonb_array_elements(r->'rows') x;
    hasil := hasil || jsonb_build_object('uji', 'Document Center (SM): tagihan di baris = rc_tagihan_dokumen', 'lulus', v_n > 0 and v_beda = 0,
      'rinci', v_n || ' baris, beda ' || v_beda || ', bertagihan ' || v_ada);

    -- 3 & 4. Admin di bawah RLS (role authenticated): hasilnya tetap sama, dan fungsi boleh dijalankan.
    -- 3 & 4. Akun non System Manager di bawah RLS (role authenticated): hasilnya tetap sama.
    -- Hak tab berbeda per akun, jadi dicari akun pertama yang memang bisa membuka layarnya.
    for v_layar in 1..2 loop
      v_adm := null;
      for k in select p.id from public.profiles p where p.status = 'active' and p.role <> 'system manager' order by (p.role = 'admin') desc, p.user_code limit 60 loop
        begin
          update public.profiles set must_change_password = false where id = k.id;
          perform set_config('request.jwt.claims', json_build_object('sub', k.id::text, 'role', 'authenticated')::text, true);
          perform set_config('role', 'authenticated', true); -- jangkauan depot berasal dari RLS: harus dicoba sebagai pengguna
          if v_layar = 1 then r := public.rc_open_claims_filtered('', '', 0, 5, ''); else r := public.rc_compilation_list(p_limit => 5); end if;
          perform set_config('role', 'postgres', true);
          if jsonb_array_length(r->'rows') > 0 then v_adm := k.id; exit; end if;
        exception when others then perform set_config('role', 'postgres', true);
        end;
      end loop;
      if v_adm is null then raise exception 'Fixture: akun non System Manager untuk layar % tidak ada', v_layar; end if;
      perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
      perform set_config('role', 'authenticated', true);
      if v_layar = 1 then r := public.rc_open_claims_filtered('', '', 0, 200, ''); else r := public.rc_compilation_list(p_limit => 200); end if;
      select array_agg(upper(x->>'noDoc')) into v_docs from jsonb_array_elements(r->'rows') x;
      t := public.rc_tagihan_dokumen(v_docs)->'data';
      select count(*), count(*) filter (where x->'tagihan' is distinct from t->upper(x->>'noDoc')) into v_n, v_beda from jsonb_array_elements(r->'rows') x;
      perform set_config('role', 'postgres', true);
      hasil := hasil || jsonb_build_object('uji', case v_layar when 1 then 'Open' else 'Document Center' end || ' (akun non-SM, RLS): tagihan di baris = rc_tagihan_dokumen',
        'lulus', v_n > 0 and v_beda = 0, 'rinci', v_n || ' baris, beda ' || v_beda || ', ' || (select role from public.profiles where id = v_adm));
    end loop;

    -- 5. Saklar ZDAGE mati: kunci 'tagihan' tidak dikirim.
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'zdage_aktif';
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_compilation_list(p_limit => 50);
    select count(*) filter (where x ? 'tagihan') into v_n from jsonb_array_elements(r->'rows') x;
    r := public.rc_open_claims_filtered('', '', 0, 50, '');
    select v_n + count(*) filter (where x ? 'tagihan') into v_n from jsonb_array_elements(r->'rows') x;
    hasil := hasil || jsonb_build_object('uji', 'Saklar ZDAGE mati: baris tanpa kunci tagihan', 'lulus', v_n = 0, 'rinci', v_n::text);

    -- 6. Hak.
    hasil := hasil || jsonb_build_object('uji', 'tagihan_toko: boleh untuk pengguna login, tertutup untuk anon', 'lulus',
      has_function_privilege('authenticated', 'rc_private.tagihan_toko(uuid,text)', 'execute') and not has_function_privilege('anon', 'rc_private.tagihan_toko(uuid,text)', 'execute'), 'rinci', '-');
    raise exception 'UJI_SELESAI';
  exception when others then
    perform set_config('role', 'postgres', true);
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_td(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_td order by urut;
