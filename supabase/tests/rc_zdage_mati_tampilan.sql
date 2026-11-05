-- ==========================================================================================
-- Uji ZDAGE Integration mati = tampilan prod (20261163680000): tab ZDAGE tertutup (kecuali
-- Upload Debtor untuk System Manager dan Bad Debt approval yang masih menunggu), tawaran dan
-- Bad Debt tidak dibaca, bootstrap / Open membawa zdageAktif; saat hidup semuanya kembali.
-- ==========================================================================================
-- Seluruh perubahan (saklar, tanda Bad Debt, pengajuan) dibatalkan lewat UJI_SELESAI.
--
--   node scripts/apply-sql.mjs --env dev supabase/tests/rc_zdage_mati_tampilan.sql
-- ==========================================================================================
create temp table if not exists _hasil_zmt(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_zmt;

do $uji$
declare hasil jsonb := '[]'; r jsonb; v_sm uuid; v_adm uuid; v_klaim uuid; v_cust uuid; v_nodoc text; v_galat text; v_tabs jsonb; v_bd uuid;
  v_kode text[] := array['upload.restricted', 'upload.restrictedEdit', 'upload.baddebt', 'compilation.debtor', 'approval.baddebt'];
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select id into v_adm from public.profiles where role = 'admin' and status = 'active' and not must_change_password order by user_code limit 1;
  begin
    perform set_config('request.jwt.claims', '', true);
    -- Klaim Not Yet dengan tawaran aktif; tokonya diberi tanda Bad Debt.
    select o.claim_id, c.customer_id, c.no_doc into v_klaim, v_cust, v_nodoc from public.rc_clearing_offers o join public.claims c on c.id = o.claim_id
     where o.status in ('offered', 'overdue') and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null and c.customer_id is not null
     order by o.id limit 1;
    insert into public.rc_bad_debt_remarks(customer_id, reason, created_by) values (v_cust, 'Uji tampilan prod', v_sm) returning id into v_bd;
    update public.claims set pending_approval = null where archived_at is null and pending_approval->>'bad_debt' = 'true';

    -- ---- MATI ---------------------------------------------------------------------------
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'zdage_aktif';
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    v_tabs := rc_private.tab_rights(v_sm);
    hasil := hasil || jsonb_build_object('uji', 'MATI: System Manager tidak melihat Restricted / Bad Debt / Bad Debt approval; Upload Debtor tetap (persiapan data)',
      'lulus', not (v_tabs->>'upload.restricted')::boolean and not (v_tabs->>'upload.restrictedEdit')::boolean and not (v_tabs->>'upload.baddebt')::boolean
           and not (v_tabs->>'approval.baddebt')::boolean and (v_tabs->>'compilation.debtor')::boolean
           and (v_tabs->>'upload.open')::boolean is not false,
      'rinci', (select string_agg(k || '=' || coalesce(v_tabs->>k, '-'), ', ') from unnest(v_kode) k));
    if v_adm is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
      v_tabs := rc_private.tab_rights(v_adm);
      hasil := hasil || jsonb_build_object('uji', 'MATI: Admin Depot tidak melihat satu pun tab ZDAGE',
        'lulus', not exists (select 1 from unnest(v_kode) k where coalesce((v_tabs->>k)::boolean, false)),
        'rinci', (select string_agg(k || '=' || coalesce(v_tabs->>k, '-'), ', ') from unnest(v_kode) k));
      perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    end if;
    begin perform public.rc_restricted_claims(); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'MATI: server menolak daftar Restricted', 'lulus', v_galat ~ 'upload\.restricted', 'rinci', v_galat);
    begin perform public.rc_bad_debt_set(array[v_nodoc], 'coba'); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'MATI: server menolak Tandai Bad Debt', 'lulus', v_galat ~ 'upload\.baddebt', 'rinci', v_galat);

    select to_jsonb(d) into r from rc_private.debtor_info(v_klaim, v_cust) d;
    hasil := hasil || jsonb_build_object('uji', 'MATI: tawaran (Deadline) dan Bad Debt tidak dibaca untuk daftar Open',
      'lulus', r->>'offer_id' is null and r->>'deadline_at' is null and not (r->>'bad_debt')::boolean, 'rinci', r::text);
    hasil := hasil || jsonb_build_object('uji', 'MATI: label Bad Debt toko kosong (Customer Master, email, jalur approval)',
      'lulus', rc_private.toko_bad_debt(v_cust) is null
           and pg_get_functiondef('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)'::regprocedure) ~ 'status=''active'' and rc_private\.zdage_aktif\(\)',
      'rinci', '-');
    r := public.rc_open_claims_filtered(v_nodoc, '', 0, 50, '');
    hasil := hasil || jsonb_build_object('uji', 'MATI: Open memuat dokumen itu tanpa Deadline / Bad Debt; zdageAktif = false',
      'lulus', (r->>'zdageAktif')::boolean = false
           and exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'noDoc' = v_nodoc and coalesce(x->>'deadline', '') = '' and not coalesce((x->>'badDebt')::boolean, false)),
      'rinci', coalesce(r->>'total', '-'));
    r := public.rc_legacy_bootstrap();
    hasil := hasil || jsonb_build_object('uji', 'MATI: bootstrap login membawa zdageAktif = false',
      'lulus', (r #>> '{data,zdageAktif}')::boolean = false,
      'rinci', left(coalesce(r::text, '-'), 120));

    -- Pengajuan Bad Debt yang masih menunggu: tab Bad Debt approval tetap terbuka.
    update public.claims set pending_approval = '{"kind":"submit","bad_debt":true}'::jsonb where id = v_klaim;
    hasil := hasil || jsonb_build_object('uji', 'MATI: tab Bad Debt approval terbuka selama masih ada pengajuan Bad Debt yang menunggu',
      'lulus', (rc_private.tab_rights(v_sm)->>'approval.baddebt')::boolean, 'rinci', '-');
    update public.claims set pending_approval = null where id = v_klaim;

    -- ---- HIDUP --------------------------------------------------------------------------
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';
    v_tabs := rc_private.tab_rights(v_sm);
    hasil := hasil || jsonb_build_object('uji', 'HIDUP: System Manager melihat semua tab ZDAGE lagi',
      'lulus', not exists (select 1 from unnest(v_kode) k where not coalesce((v_tabs->>k)::boolean, false)),
      'rinci', (select string_agg(k || '=' || coalesce(v_tabs->>k, '-'), ', ') from unnest(v_kode) k));
    select to_jsonb(d) into r from rc_private.debtor_info(v_klaim, v_cust) d;
    hasil := hasil || jsonb_build_object('uji', 'HIDUP: tawaran dan Bad Debt terbaca lagi',
      'lulus', r->>'offer_id' is not null and (r->>'bad_debt')::boolean and rc_private.toko_bad_debt(v_cust) = 'Uji tampilan prod', 'rinci', r::text);
    hasil := hasil || jsonb_build_object('uji', 'HIDUP: Open membawa zdageAktif = true',
      'lulus', (public.rc_open_claims_filtered(v_nodoc, '', 0, 50, '')->>'zdageAktif')::boolean, 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_zmt(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_zmt order by urut;
