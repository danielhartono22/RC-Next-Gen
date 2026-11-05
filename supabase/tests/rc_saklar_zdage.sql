-- ==========================================================================================
-- Uji saklar ZDAGE Integration (20261163620000): bawaan mati, Open / Restricted mengikuti saklar,
-- job harian berhenti saat mati, setelan / ubah / status, hak akses, Log Activity.
-- ==========================================================================================
-- Seluruh perubahan (saklar, tawaran, log) dibatalkan lewat UJI_SELESAI.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_saklar_zdage.sql
-- ==========================================================================================
create temp table if not exists _hasil_szd(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_szd;

do $uji$
declare hasil jsonb := '[]'; r jsonb; v_sm uuid; v_tanpa uuid; v_klaim uuid; v_cust uuid; v_nodoc text; v_galat text;
  v_nt integer; v_tawar uuid; n integer; u record;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  for u in select p.id from public.profiles p where p.status = 'active' order by p.user_code limit 200 loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    if not rc_private.can_tab('access.approval') then v_tanpa := u.id; exit; end if;
  end loop;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    hasil := hasil || jsonb_build_object('uji', 'Saklar tersimpan di pengaturan_sistem; tab bernama On/Off Sistem',
      'lulus', exists (select 1 from public.pengaturan_sistem where kunci = 'zdage_aktif')
           and (select title from rc_private.tab_catalog where code = 'access.approval') = 'On/Off Sistem',
      'rinci', (select nilai::text from public.pengaturan_sistem where kunci = 'zdage_aktif'));

    -- Dokumen Not Yet tanpa tawaran aktif dan bukan toko Bad Debt.
    select c.id, c.customer_id, c.no_doc into v_klaim, v_cust, v_nodoc from public.claims c
     where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
       and not exists (select 1 from public.rc_clearing_offers o where o.claim_id = c.id and o.status in ('offered', 'overdue'))
       and not exists (select 1 from public.rc_bad_debt_remarks b where b.customer_id = c.customer_id and b.status = 'active')
     order by c.id limit 1;

    -- ---- MATI ---------------------------------------------------------------------------
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'zdage_aktif';
    hasil := hasil || jsonb_build_object('uji', 'MATI (cara lama): dokumen tanpa tawaran ZDAGE boleh ada di Open',
      'lulus', rc_private.boleh_open(v_klaim, v_cust), 'rinci', v_nodoc);
    r := public.rc_open_claims_filtered(v_nodoc, '', 0, 50, '');
    hasil := hasil || jsonb_build_object('uji', 'MATI: dokumen itu tampil di Claim Upload > Open dan bolehAjukan',
      'lulus', exists (select 1 from jsonb_array_elements(r->'rows') x where x::text ~ v_nodoc)
           and coalesce(((select x->>'bolehAjukan' from jsonb_array_elements(rc_private.legacy_documents(array[v_nodoc])) x limit 1))::boolean, true),
      'rinci', coalesce(r->>'total', '-'));
    -- 20261163680000: saat mati tab Restricted tertutup (tampilan prod); sebelum itu cukup kosong.
    begin r := public.rc_restricted_claims('', '', 0, 50, ''); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'MATI: tab Restricted tertutup (atau kosong)',
      'lulus', v_galat ~ 'upload\.restricted' or (v_galat = 'lolos' and (r->>'total')::int = 0), 'rinci', v_galat);

    -- Job harian: tawaran lewat batas tidak diubah, email tidak disusun.
    select o.id into v_tawar from public.rc_clearing_offers o join public.claims c on c.id = o.claim_id
     where o.status = 'offered' and o.result in ('LUNAS', 'REOFFER') and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null limit 1;
    if v_tawar is not null then update public.rc_clearing_offers set deadline_at = now() - interval '1 day' where id = v_tawar; end if;
    r := rc_private.zdage_harian();
    hasil := hasil || jsonb_build_object('uji', 'MATI: job harian ZDAGE dilewati (tidak ada overdue, tidak ada email)',
      'lulus', r->>'lewati' = 'ZDAGE Integration mati'
           and (v_tawar is null or (select status from public.rc_clearing_offers where id = v_tawar) = 'offered'),
      'rinci', r::text);

    -- ---- HIDUP -------------------------------------------------------------------------
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';
    hasil := hasil || jsonb_build_object('uji', 'HIDUP (cara baru): dokumen tanpa tawaran tidak boleh Open',
      'lulus', not rc_private.boleh_open(v_klaim, v_cust), 'rinci', v_nodoc);
    r := public.rc_restricted_claims(v_nodoc, '', 0, 50, '');
    hasil := hasil || jsonb_build_object('uji', 'HIDUP: dokumen itu pindah ke Restricted, hilang dari Open',
      'lulus', exists (select 1 from jsonb_array_elements(r->'rows') x where x::text ~ v_nodoc)
           and not exists (select 1 from jsonb_array_elements(public.rc_open_claims_filtered(v_nodoc, '', 0, 50, '')->'rows') x where x::text ~ v_nodoc),
      'rinci', r->>'total');
    r := rc_private.zdage_harian();
    hasil := hasil || jsonb_build_object('uji', 'HIDUP: job harian berjalan (tawaran lewat batas jadi overdue)',
      'lulus', not (r ? 'lewati') and (v_tawar is null or (select status from public.rc_clearing_offers where id = v_tawar) = 'overdue'),
      'rinci', r::text);

    -- ---- Setelan dan ubah ------------------------------------------------------------------
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'zdage_aktif';
    r := public.rc_zdage_setelan();
    select count(*) into v_nt from public.claims where status = 'not_yet' and pending_approval is null and archived_at is null;
    hasil := hasil || jsonb_build_object('uji', 'Setelan: keadaan, jumlah Not Yet, dampak bila dihidupkan',
      'lulus', r->>'status' = 'success' and (r->>'aktif')::boolean = false and (r->>'notYet')::int = v_nt
           and (r->>'openBilaHidup')::int between 0 and v_nt and r ? 'uploadTerakhir',
      'rinci', (r->>'openBilaHidup') || ' dari ' || (r->>'notYet') || ' | ' || (r->>'uploadTerakhir'));
    begin perform public.rc_zdage_setel(true, ''); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Ubah tanpa alasan ditolak', 'lulus', v_galat ~ 'Alasan wajib', 'rinci', v_galat);
    select count(*) into n from public.activity_logs where event_type = 'zdage_dihidupkan';
    r := public.rc_zdage_setel(true, 'Uji saklar');
    hasil := hasil || jsonb_build_object('uji', 'Dihidupkan: tersimpan, pesan dampak, satu baris Log Activity',
      'lulus', rc_private.zdage_aktif() and r->>'message' ~ 'cara baru'
           and (select count(*) from public.activity_logs where event_type = 'zdage_dihidupkan') = n + 1
           and (select diubah_oleh from public.pengaturan_sistem where kunci = 'zdage_aktif') = v_sm,
      'rinci', r->>'message');
    hasil := hasil || jsonb_build_object('uji', 'Riwayat perubahan tampil di setelan',
      'lulus', (public.rc_zdage_setelan()->'riwayat'->0->>'aksi') = 'Dihidupkan', 'rinci', '-');
    r := public.rc_zdage_setel(false, 'Uji kembali');
    hasil := hasil || jsonb_build_object('uji', 'Dimatikan: kembali cara lama',
      'lulus', not rc_private.zdage_aktif() and r->>'message' ~ 'cara lama', 'rinci', r->>'message');

    -- ---- Akses -------------------------------------------------------------------------------
    if v_tanpa is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_tanpa::text, 'role', 'authenticated')::text, true);
      begin perform public.rc_zdage_setel(true, 'Coba'); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
      hasil := hasil || jsonb_build_object('uji', 'User tanpa tab On/Off Sistem tidak bisa mengubah; status tetap terbaca',
        'lulus', v_galat ~ 'tidak diizinkan' and (public.rc_zdage_status()->>'aktif')::boolean = false, 'rinci', v_galat);
    end if;
    hasil := hasil || jsonb_build_object('uji', 'anon tidak bisa memanggil fungsi saklar',
      'lulus', not has_function_privilege('anon', 'public.rc_zdage_setel(boolean,text)', 'execute')
           and not has_function_privilege('anon', 'public.rc_zdage_status()', 'execute'), 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_szd(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_szd order by urut;
