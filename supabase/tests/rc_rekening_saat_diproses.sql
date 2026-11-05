-- ==========================================================================================
-- Uji rekening sesuai yang diproses (Analytics, Document Center) - migrasi 20261163390000
-- ==========================================================================================
-- Dibatalkan seluruhnya (UJI_SELESAI): perubahan master / salinan rekening uji ikut dibatalkan.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_rekening_saat_diproses.sql
-- ==========================================================================================
create temp table if not exists _hasil_rek(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_rek;

do $uji$
declare hasil jsonb := '[]'; r jsonb; x jsonb; v_sm uuid; c1 record; c2 record;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- c1: dokumen dengan salinan rekening; c2: dokumen lain dengan customer bermaster.
  select c.id, c.no_doc, c.customer_id into c1 from public.claims c join rc_private.claim_sensitive s on s.claim_id = c.id
   where c.archived_at is null and c.customer_id is not null and coalesce(s.account_number, '') <> '' order by c.no_doc limit 1;
  select c.id, c.no_doc, c.customer_id into c2 from public.claims c
   where c.archived_at is null and c.customer_id is not null and c.customer_id <> c1.customer_id and c.id <> c1.id order by c.no_doc limit 1;

  begin
    hasil := hasil || jsonb_build_object('uji', 'rekening_tampil: salinan dokumen menang; tanpa salinan pakai master; tidak dicampur per kolom',
      'lulus', rc_private.rekening_tampil('111', 'A', 'BCA', '999', 'B', 'BRI') = '{"noRek":"111","namaRek":"A","bank":"BCA","sumberRek":"dokumen"}'::jsonb
           and rc_private.rekening_tampil('', null, ' ', '999', 'B', 'BRI') = '{"noRek":"999","namaRek":"B","bank":"BRI","sumberRek":"master"}'::jsonb
           and rc_private.rekening_tampil('111', '', '', '999', 'B', 'BRI')->>'namaRek' = ''
           and rc_private.rekening_tampil(null, null, null, null, null, null)->>'sumberRek' = '', 'rinci', '-');

    -- Toko ganti rekening sesudah dokumen diproses; dokumen c2 belum punya salinan.
    update rc_private.claim_sensitive set account_number = '0011223344', account_name = 'PEMILIK LAMA', bank = 'BANK LAMA' where claim_id = c1.id;
    update public.customers set account_number = '9988776655', account_name = 'PEMILIK BARU', bank = 'BANK BARU' where id = c1.customer_id;
    delete from rc_private.claim_sensitive where claim_id = c2.id;
    update public.customers set account_number = '5544332211', account_name = 'PEMILIK MASTER', bank = 'BANK MASTER' where id = c2.customer_id;

    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    -- Dijalankan sebagai peran authenticated (seperti dari layar), supaya hak fungsi dan RLS ikut teruji.
    execute 'set local role authenticated';
    r := public.rc_compilation_list('', '', '', c1.no_doc, 0, 50, '', null, null);
    x := (select y from jsonb_array_elements(r->'rows') y where y->>'noDoc' = c1.no_doc);
    hasil := hasil || jsonb_build_object('uji', 'Document Center: rekening saat diproses, bukan master sekarang',
      'lulus', x->>'noRek' = '0011223344' and x->>'namaRek' = 'PEMILIK LAMA' and x->>'bank' = 'BANK LAMA' and x->>'sumberRek' = 'dokumen',
      'rinci', coalesce(x::text, 'dokumen tidak ditemukan'));
    r := public.rc_compilation_list('', '', '', c2.no_doc, 0, 50, '', null, null);
    x := (select y from jsonb_array_elements(r->'rows') y where y->>'noDoc' = c2.no_doc);
    hasil := hasil || jsonb_build_object('uji', 'Document Center: dokumen tanpa salinan memakai master, ditandai master',
      'lulus', x->>'noRek' = '5544332211' and x->>'sumberRek' = 'master', 'rinci', coalesce(x->>'noRek', '-') || ' / ' || coalesce(x->>'sumberRek', '-'));

    execute 'reset role';
    -- Analytics: dokumen uji dinaikkan ke urutan teratas (updated_at terbaru) lalu dibaca halaman pertama.
    update public.claims set updated_at = now() + interval '1 minute' where id in (c1.id, c2.id);
    execute 'set local role authenticated';
    r := public.rc_legacy_dashboard(50, null, null);
    execute 'reset role';
    x := (select y from jsonb_array_elements(r->'history') y where y->>'noDoc' = c1.no_doc);
    hasil := hasil || jsonb_build_object('uji', 'Analytics: rekening saat diproses, bukan master sekarang',
      'lulus', x->>'noRek' = '0011223344' and x->>'namaRek' = 'PEMILIK LAMA' and x->>'bank' = 'BANK LAMA' and x->>'sumberRek' = 'dokumen',
      'rinci', coalesce((x - 'amendBy')::text, 'dokumen tidak ditemukan'));
    x := (select y from jsonb_array_elements(r->'history') y where y->>'noDoc' = c2.no_doc);
    hasil := hasil || jsonb_build_object('uji', 'Analytics: dokumen tanpa salinan memakai master, ditandai master',
      'lulus', x->>'noRek' = '5544332211' and x->>'sumberRek' = 'master', 'rinci', coalesce(x->>'noRek', '-') || ' / ' || coalesce(x->>'sumberRek', '-'));

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  insert into _hasil_rek(uji, lulus, rinci) select x2->>'uji', (x2->>'lulus')::boolean, x2->>'rinci' from jsonb_array_elements(hasil) x2;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_rek order by urut;
