-- ==========================================================================================
-- Sekali jalan: Subyek Pajak dan Gross Up seluruh dokumen diselaraskan ke Customer Master terbaru
-- ==========================================================================================
-- Pemilik, 21 Oktober 2026: "ubah ikuti yang diperbarui saat ini", lalu "untuk saat ini semua
-- data, next ikutin aturan sesuai kondisi data saat itu".
--
--  * SEKARANG (migrasi ini): setiap dokumen aktif yang punya Customer Master, apa pun statusnya
--    termasuk Done, memakai subyek pajak master saat ini, dan Gross Up dihitung ulang dengan
--    rc_private.gross_up_klaim (aturan 12 Oktober 2026). Hanya dokumen yang berbeda yang diubah;
--    tiap dokumen dicatat di riwayatnya (sinkron_pajak_master, nilai lama -> baru) dan prosesnya
--    satu baris Log Activity.
--  * SELANJUTNYA tidak berubah: dokumen memakai data master pada saat ia diproses (compile,
--    submit, Reprocessing, tautan Customer Master), tanpa ikut berubah ketika master diubah
--    kemudian.
--
-- Prod 21 Oktober 2026 (hanya baca): 15 dokumen berbeda dari 32.809 - Not Yet 5, Done 6,
-- Claimed 3, Expired 1; Gross Up total +Rp 45.999.154. Penyebab utamanya: dokumen tertaut ke
-- master yang saat itu belum ber-KTP / NPWP, dan master yang NPWP-nya ditambahkan belakangan.
-- Aman dijalankan ulang: sesudahnya tidak ada lagi yang berbeda.
-- ==========================================================================================

do $sinkron$
declare n integer; v_dok jsonb;
begin
  with target as (
    select c.id, c.no_doc, c.status, c.tax_subject lama_s, cu.tax_subject baru_s, c.gross_up lama_g,
           rc_private.gross_up_klaim(c.cb_net, cu.tax_subject, ca.tax_status,
                                     coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) baru_g
      from public.claims c
      join public.customers cu on cu.id = c.customer_id
      join public.campaigns ca on ca.id = c.campaign_id
     where c.archived_at is null
  ), beda as (
    select * from target where lama_s is distinct from baru_s or lama_g is distinct from baru_g
  ), ubah as (
    update public.claims c
       set tax_subject = b.baru_s, gross_up = b.baru_g, version_no = c.version_no + 1, updated_at = now()
      from beda b
     where c.id = b.id
    returning c.id, c.status, b.no_doc, b.lama_s, b.baru_s, b.lama_g, b.baru_g
  ), riwayat as (
    insert into public.claim_status_history(claim_id, from_status, to_status, action, reason)
    select u.id, u.status, u.status, 'sinkron_pajak_master',
           format('Subyek Pajak %s -> %s; Gross Up %s -> %s (Customer Master terbaru)',
                  coalesce(u.lama_s, '-'), coalesce(u.baru_s, '-'), coalesce(u.lama_g::text, '-'), coalesce(u.baru_g::text, '-'))
      from ubah u
    returning claim_id
  )
  select count(*),
         jsonb_agg(jsonb_build_object('noDoc', no_doc, 'status', status,
                                      'subyek', coalesce(lama_s, '-') || ' -> ' || coalesce(baru_s, '-'),
                                      'grossUp', coalesce(lama_g::text, '-') || ' -> ' || coalesce(baru_g::text, '-'))
                   order by no_doc)
    into n, v_dok
    from ubah;

  if n > 0 then
    insert into public.activity_logs(event_type, details)
    values ('sinkron_pajak_master', jsonb_build_object(
      'detail', 'Subyek Pajak dan Gross Up diselaraskan ke Customer Master terbaru (sekali jalan, 20261163290000)',
      'jumlah', n, 'dokumen', v_dok));
  end if;
  raise notice 'Dokumen diselaraskan: %', n;
end $sinkron$;

do $cek$
begin
  if exists(select 1 from public.claims c
              join public.customers cu on cu.id = c.customer_id
              join public.campaigns ca on ca.id = c.campaign_id
             where c.archived_at is null
               and (c.tax_subject is distinct from cu.tax_subject
                 or c.gross_up is distinct from rc_private.gross_up_klaim(c.cb_net, cu.tax_subject, ca.tax_status,
                                                  coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)))) then
    raise exception 'GAGAL: masih ada dokumen yang berbeda dari Customer Master';
  end if;
end $cek$;
