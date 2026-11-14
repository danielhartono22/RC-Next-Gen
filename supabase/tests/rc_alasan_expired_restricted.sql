-- ==========================================================================================
-- Uji 13 November 2026: alasan Expired wajib + alasan di badan email; Restricted -> Open (930000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_alasan_expired_restricted.sql
-- ==========================================================================================
create temp table if not exists _hasil_ae(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_ae;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_dep uuid; k uuid[]; d text[]; r jsonb; v_err text; v_html text; v_ant bigint[];
  v_b1 text; v_b2 text; v_dok jsonb; v_n int;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and suffix_num ~ '^[0-9]{3}$' order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  begin
    update public.profiles set must_change_password = false where id = v_sm;
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'approval_aktif';
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';
    update public.email_settings set aktif = true, mode_uji = false where jenis = 'pengajuan';
    delete from rc_private.email_expired_antrean;

    -- Enam dokumen Not Yet satu depot, toko berbeda, tanpa tawaran aktif dan bukan Bad Debt.
    select c.depot_id into v_dep from public.claims c
     where c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null and c.customer_id is not null
       and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = c.id and o.status in ('offered', 'overdue'))
       and not exists(select 1 from public.rc_bad_debt_remarks b where b.customer_id = c.customer_id and b.status = 'active')
     group by 1 having count(distinct c.customer_id) >= 6 order by count(*) desc limit 1;
    if v_dep is null then raise exception 'Fixture: depot dengan 6 toko Not Yet tidak ada'; end if;
    select array_agg(id order by no_doc), array_agg(no_doc order by no_doc) into k, d from (
      select distinct on (c.customer_id) c.id, c.no_doc from public.claims c
       where c.depot_id = v_dep and c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null and c.customer_id is not null
         and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = c.id and o.status in ('offered', 'overdue'))
         and not exists(select 1 from public.rc_bad_debt_remarks b where b.customer_id = c.customer_id and b.status = 'active')
       order by c.customer_id, c.no_doc limit 6) z;

    -- 1. Expired tanpa alasan / alasan terlalu pendek ditolak; dokumen tidak berubah.
    v_err := '';
    begin perform public.rc_posting_exception('expired', jsonb_build_array(jsonb_build_object('noDoc', d[1])), '');
    exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Expired tanpa alasan ditolak', 'lulus', v_err ~ 'Alasan Expired wajib'
      and (select status from public.claims where id = k[1]) = 'not_yet', 'rinci', v_err);
    v_err := '';
    begin perform public.rc_posting_exception('expired', jsonb_build_array(jsonb_build_object('noDoc', d[1])), '  ab ');
    exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Alasan kurang dari 3 karakter ditolak', 'lulus', v_err ~ 'Alasan Expired wajib', 'rinci', v_err);

    -- 2. Dua proses Expired = dua batch, masing-masing dengan alasannya.
    r := public.rc_posting_exception('expired', jsonb_build_array(jsonb_build_object('noDoc', d[1]), jsonb_build_object('noDoc', d[2])), 'Toko tutup permanen <uji>');
    select batch_clearing into v_b1 from public.claims where id = k[1];
    hasil := hasil || jsonb_build_object('uji', 'Expired dengan alasan: 2 dokumen Expired, satu batch, alasan di riwayat',
      'lulus', (r->>'berhasil')::int = 2 and (select count(*) from public.claims where id in (k[1], k[2]) and status = 'expired' and batch_clearing = v_b1) = 2
           and (select count(*) from public.claim_status_history h where h.claim_id in (k[1], k[2]) and h.action = 'request_expired' and h.reason = 'Toko tutup permanen <uji>') = 2,
      'rinci', r->>'message');
    r := public.rc_posting_exception('expired', jsonb_build_array(jsonb_build_object('noDoc', d[3])), 'Dokumen dobel compile');
    select batch_clearing into v_b2 from public.claims where id = k[3];
    select array_agg(id order by id) into v_ant from rc_private.email_expired_antrean;
    hasil := hasil || jsonb_build_object('uji', 'Antrean email Expired: satu baris per batch dengan alasannya',
      'lulus', cardinality(v_ant) = 2 and v_b1 <> v_b2
           and (select count(*) from rc_private.email_expired_antrean a where (a.batch = v_b1 and a.alasan = 'Toko tutup permanen <uji>') or (a.batch = v_b2 and a.alasan = 'Dokumen dobel compile')) = 2,
      'rinci', coalesce(v_b1, '-') || ' / ' || coalesce(v_b2, '-'));

    -- 3. Email rekap: alasan di badan email di atas tabel, per batch; kolom ALASAN tidak ada.
    v_html := rc_private.email_expired_html(v_ant, v_dep, now() + interval '1 hour');
    hasil := hasil || jsonb_build_object('uji', 'Email Expired: blok "Alasan Expired" per batch di atas tabel',
      'lulus', v_html like '%<strong>Alasan Expired:</strong>%'
           and v_html like '%Batch <strong>' || v_b1 || '</strong>: Toko tutup permanen &lt;uji&gt;%'
           and v_html like '%Batch <strong>' || v_b2 || '</strong>: Dokumen dobel compile%'
           and position('Alasan Expired:' in v_html) < position('>Summary<' in v_html)
           and position('Alasan Expired:' in v_html) < position('>NO BATCH<' in v_html),
      'rinci', position('Alasan Expired:' in v_html)::text || ' < ' || position('>NO BATCH<' in v_html)::text);
    hasil := hasil || jsonb_build_object('uji', 'Email Expired: kolom ALASAN hilang, tabel Detail 6 kolom, alasan tidak terulang di baris',
      'lulus', v_html !~ '>ALASAN<' and v_html ~ '>WAKTU</th></tr>' and v_html ~ '<td colspan="2"[^>]*></td></tr></tfoot>'
           and (length(v_html) - length(replace(v_html, 'Dokumen dobel compile', ''))) / length('Dokumen dobel compile') = 1,
      'rinci', (v_html !~ '>ALASAN<')::text || '/' || (v_html ~ '>WAKTU</th></tr>')::text || '/' || (v_html ~ '<td colspan="2"[^>]*></td></tr></tfoot>')::text
               || '/' || ((length(v_html) - length(replace(v_html, 'Dokumen dobel compile', ''))) / length('Dokumen dobel compile'))::text);

    -- 4. Restricted -> Open: dua proses pindah dengan alasan berbeda.
    r := public.rc_restricted_pindah(array[d[4], d[5]], 'Sudah bayar, bukti transfer terlampir');
    r := public.rc_restricted_pindah(array[d[6]], 'Persetujuan RSM & OSC');
    v_dok := rc_private.legacy_documents(array[upper(d[4]), upper(d[5]), upper(d[6]), upper(d[1])]);
    hasil := hasil || jsonb_build_object('uji', 'legacy_documents: restrictedOpen benar untuk dokumen pindahan, salah untuk yang lain',
      'lulus', (select count(*) from jsonb_array_elements(v_dok) x where (x->>'restrictedOpen')::boolean and (x->>'bolehAjukan')::boolean) = 3
           and (select not (x->>'restrictedOpen')::boolean from jsonb_array_elements(v_dok) x where upper(x->>'noDoc') = upper(d[1])),
      'rinci', (select string_agg(x->>'restrictedOpen', ',') from jsonb_array_elements(v_dok) x));
    -- Tawaran lunas biasa bukan restrictedOpen.
    update public.rc_clearing_offers set result = 'LUNAS', reason = '{}'::jsonb where claim_id = k[6] and status = 'offered';
    v_dok := rc_private.legacy_documents(array[upper(d[6])]);
    hasil := hasil || jsonb_build_object('uji', 'Tawaran toko lunas: boleh diajukan tetapi bukan restrictedOpen (Tgl Lunas tetap wajib)',
      'lulus', (v_dok->0->>'bolehAjukan')::boolean and not (v_dok->0->>'restrictedOpen')::boolean, 'rinci', v_dok->0->>'restrictedOpen');
    update public.rc_clearing_offers set result = 'RESTRICTED', reason = jsonb_build_object('alasanPindah', 'Persetujuan RSM & OSC') where claim_id = k[6] and status = 'offered';

    -- 5. Email klaim: alasan pindah di atas tabel Restricted Claim, bukan kolom.
    v_html := rc_private.email_pengajuan_html('submit_langsung', '010000000000001', array[k[4], k[5], k[6]], v_sm, '');
    hasil := hasil || jsonb_build_object('uji', 'Email klaim: "Alasan dipindah ke Open" per proses pindah, dengan jumlah dokumen',
      'lulus', v_html like '%<strong>Alasan dipindah ke Open:</strong>%'
           and v_html ~ 'Sudah bayar, bukti transfer terlampir <span[^>]*>\(2 dokumen'
           and v_html ~ 'Persetujuan RSM &amp; OSC <span[^>]*>\(1 dokumen'
           and v_html ~ 'dipindah oleh ', 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Email klaim: alasan di atas tabel Restricted (sesudah judul, sebelum kepala tabel), kolom tetap 5',
      'lulus', position('RESTRICTED CLAIM</p>' in v_html) < position('Alasan dipindah ke Open' in v_html)
           and position('Alasan dipindah ke Open' in v_html) < position('>NO DOC</th>' in v_html)
           and v_html ~ '>KETERANGAN</th>' and v_html !~ '>ALASAN</th>', 'rinci', '-');

    -- 6. Email tanpa dokumen Restricted, dan Restricted karena Bad Debt (tanpa alasan pindah), tidak berubah.
    select count(*) into v_n from public.claims c where c.depot_id = v_dep and c.status = 'not_yet' and c.id <> all(k);
    v_html := rc_private.email_pengajuan_html('submit_langsung', '010000000000001',
      array(select c.id from public.claims c where c.depot_id = v_dep and c.status = 'not_yet' and c.archived_at is null and c.id <> all(k)
              and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = c.id)
              and c.bad_debt_remark_id is null order by c.no_doc limit 2), v_sm, '');
    hasil := hasil || jsonb_build_object('uji', 'Email klaim tanpa Restricted: tidak ada blok alasan',
      'lulus', v_html !~ 'Alasan dipindah ke Open' and v_html !~ 'RESTRICTED CLAIM', 'rinci', v_n::text);
    update public.rc_clearing_offers set reason = '{}'::jsonb where claim_id in (k[4], k[5], k[6]);
    v_html := rc_private.email_pengajuan_html('submit_langsung', '010000000000001', array[k[4], k[5], k[6]], v_sm, '');
    hasil := hasil || jsonb_build_object('uji', 'Restricted tanpa alasan pindah tersimpan (data lama): bagian Restricted tetap ada, tanpa blok alasan',
      'lulus', v_html ~ 'RESTRICTED CLAIM' and v_html !~ 'Alasan dipindah ke Open', 'rinci', '-');

    -- 7. On Hold tidak terkena aturan alasan Expired (alasannya tetap diurus layar seperti sebelumnya).
    v_err := '';
    begin r := public.rc_posting_exception('hold', jsonb_build_array(jsonb_build_object('noDoc', d[1])), '');
    exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'On Hold tanpa alasan tidak ditolak oleh aturan baru', 'lulus', v_err !~ 'Alasan Expired wajib', 'rinci', coalesce(nullif(v_err, ''), r->>'message'));

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_ae(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_ae order by urut;
