-- ==========================================================================================
-- Alasan Expired wajib + alasan di badan email; Restricted -> Open tanpa Tgl Lunas
-- ==========================================================================================
-- Pemilik, 13 November 2026:
--   "1. untuk reason pada expired wajib diisi per batch yang di expiredkan dan tampil di email,
--       tampilnya di body di atas kolom aja bukan di kolomnya.
--    2. untuk restricted juga sama
--    3. untuk restricted yang pindah ke open tidak perlu isi tanggal lunas lagi"
--
-- 1. Posting Exception > Expired (rc_posting_exception): alasan wajib (minimal 3 karakter), satu
--    alasan untuk satu proses = satu No Batch. Email rekap Expired (rc_private.email_expired_html):
--    kolom ALASAN dihapus dari tabel Detail; alasan tampil di badan email di atas tabel, satu baris
--    per batch. Expired lewat Claim Process (expire_claim_process) sudah mewajibkan alasan dan ikut
--    tampil dengan cara yang sama.
-- 2. Email klaim, bagian RESTRICTED CLAIM (rc_private.email_pengajuan_html): alasan yang diisi saat
--    Pindah ke Open (sudah wajib, satu alasan per proses pindah) tampil di badan email di atas tabel
--    Restricted Claim, bukan sebagai kolom. Kolom KETERANGAN (belum lunas / Overdue / Bad Debt) tetap.
-- 3. rc_private.legacy_documents menambah 'restrictedOpen' (Not Yet dengan tawaran aktif RESTRICTED)
--    supaya layar Claim Upload tidak mewajibkan Tgl Lunas untuk dokumen itu. Server memang tidak
--    pernah mewajibkan paid_on; yang berubah hanya penanda untuk layar.
-- Menambal fungsi yang ada (dev = prod pada 13 November 2026). Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $tambal$
declare src text;
begin
  -- ---- 1a. Posting Exception: alasan Expired wajib ------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_posting_exception(text,jsonb,text)'::regprocedure), E'\r', '');
  if src !~ '20261163930000' then
    src := pg_temp.ganti(src, $p$    raise exception 'Maksimal 500 baris sekali proses'; end if;$p$,
      $p$    raise exception 'Maksimal 500 baris sekali proses'; end if;
  -- 20261163930000: alasan Expired wajib, satu alasan untuk satu proses (satu No Batch).
  if v_action = 'expired' and length(btrim(coalesce(p_reason,''))) < 3 then
    raise exception 'Alasan Expired wajib diisi (minimal 3 karakter)'; end if;$p$, 1, 'posting_exception alasan');
    execute src;
  end if;

  -- ---- 1b. Email rekap Expired: alasan di badan email, bukan kolom ---------------------------------
  src := replace(pg_get_functiondef('rc_private.email_expired_html(bigint[],uuid,timestamp with time zone)'::regprocedure), E'\r', '');
  if src !~ '20261163930000' then
    src := pg_temp.ganti(src, $p$v_ids uuid[]; v_bd text := '';$p$,
      $p$v_ids uuid[]; v_bd text := ''; v_alasan text; -- 20261163930000$p$, 1, 'expired declare');
    src := pg_temp.ganti(src, $p$      || '<td style="' || v_td || '">' || rc_private.html_aman(coalesce(nullif(t.alasan, ''), '-')) || '</td>'
$p$, '', 1, 'expired sel alasan');
    src := pg_temp.ganti(src, $p$    || '<th align="left" style="' || v_th || '">ALASAN</th></tr></thead><tbody>'$p$,
      $p$    || '</tr></thead><tbody>'$p$, 1, 'expired kepala alasan');
    src := pg_temp.ganti(src, $p$    || '<td colspan="3" style="padding:10px;"></td></tr></tfoot></table>'$p$,
      $p$    || '<td colspan="2" style="padding:10px;"></td></tr></tfoot></table>'$p$, 1, 'expired kaki');
    src := pg_temp.ganti(src, $p$  -- Remark Bad Debt (bila fitur Upload Debtor sudah terpasang di lingkungan ini).$p$,
      $p$  -- 20261163930000: alasan per batch, tampil di badan email di atas tabel (bukan kolom).
  select string_agg('Batch <strong>' || rc_private.html_aman(coalesce(nullif(q.batch, ''), '-')) || '</strong>: '
           || rc_private.html_aman(coalesce(nullif(btrim(q.alasan), ''), '-')), '<br>' order by q.dibuat_pada, q.id)
    into v_alasan
    from (select a.id, a.dibuat_pada, a.batch, a.alasan from rc_private.email_expired_antrean a
           where a.id = any(p_ant)
             and exists(select 1 from unnest(a.claim_ids) x(id) join public.claims c on c.id = x.id where c.depot_id = p_depot)) q;

  -- Remark Bad Debt (bila fitur Upload Debtor sudah terpasang di lingkungan ini).$p$, 1, 'expired kueri alasan');
    src := pg_temp.ganti(src, $p$    -- Summary depot di bagian pertama.$p$,
      $p$    || case when v_alasan is null then '' else
         '<p style="line-height:1.6;background:#fff8e1;border-left:3px solid #f0ad4e;padding:8px 12px;margin:12px 0;font-size:12px;">'
         || '<strong>Alasan Expired:</strong><br>' || v_alasan || '</p>' end
    -- Summary depot di bagian pertama.$p$, 1, 'expired blok alasan');
    execute src;
  end if;

  -- ---- 2. Email klaim: alasan Pindah ke Open di atas tabel Restricted Claim ------------------------
  src := replace(pg_get_functiondef('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)'::regprocedure), E'\r', '');
  if src !~ '20261163930000' then
    src := pg_temp.ganti(src, $p$v_rdoc int := 0; v_ket text;$p$,
      $p$v_rdoc int := 0; v_ket text; v_ralasan text; -- 20261163930000$p$, 1, 'pengajuan declare');
    src := pg_temp.ganti(src, $p$    select count(distinct coalesce(c.customer_id::text, c.source_customer_code)) into v_rtoko from public.claims c where c.id = any(v_res);$p$,
      $p$    select count(distinct coalesce(c.customer_id::text, c.source_customer_code)) into v_rtoko from public.claims c where c.id = any(v_res);
    -- 20261163930000: alasan Pindah ke Open (satu alasan per proses pindah), di atas tabel.
    select string_agg(rc_private.html_aman(q.alasan) || ' <span style="color:#5f6368;">(' || q.n::text || ' dokumen'
             || case when coalesce(q.oleh, '') <> '' then ', dipindah oleh ' || rc_private.html_aman(q.oleh) else '' end || ')</span>',
             '<br>' order by q.awal, q.alasan)
      into v_ralasan
      from (select btrim(o.reason->>'alasanPindah') alasan, count(*) n, min(o.offered_at) awal,
                   string_agg(distinct coalesce(nullif(btrim(pr.full_name), ''), pr.user_code), ', ') oleh
              from unnest(v_res) x(id)
              join lateral (select o2.* from public.rc_clearing_offers o2 where o2.claim_id = x.id order by o2.created_at desc limit 1) o on true
              left join public.profiles pr on pr.id = o.offered_by
             where o.result = 'RESTRICTED' and coalesce(btrim(o.reason->>'alasanPindah'), '') <> ''
             group by 1) q;$p$, 1, 'pengajuan kueri alasan');
    src := pg_temp.ganti(src, $p$Bad Debt = ditandai Bad Debt atau ada tagihan yang tidak dibayar lebih dari 6 bulan.</p>'$p$,
      $p$Bad Debt = ditandai Bad Debt atau ada tagihan yang tidak dibayar lebih dari 6 bulan.</p>'
    || case when v_ralasan is null then '' else
         '<p style="line-height:1.6;background:#fff8e1;border-left:3px solid #f0ad4e;padding:8px 12px;margin:10px 0 0;font-size:12px;">'
         || '<strong>Alasan dipindah ke Open:</strong><br>' || v_ralasan || '</p>' end$p$, 1, 'pengajuan blok alasan');
    execute src;
  end if;

  -- ---- 3. Penanda dokumen Restricted yang sudah dipindah ke Open -----------------------------------
  src := replace(pg_get_functiondef('rc_private.legacy_documents(text[])'::regprocedure), E'\r', '');
  if src !~ 'restrictedOpen' then
    src := pg_temp.ganti(src, $p$ else true end /* 20261163170000 */) as x$p$,
      $p$ else true end /* 20261163170000 */,
       'restrictedOpen',c.status = 'not_yet' and exists(select 1 from public.rc_clearing_offers o where o.claim_id = c.id
           and o.status in ('offered', 'overdue') and o.result = 'RESTRICTED') /* 20261163930000: Tgl Lunas tidak wajib */) as x$p$, 2, 'legacy_documents');
    execute src;
  end if;
end $tambal$;

do $cek$
begin
  if pg_get_functiondef('public.rc_posting_exception(text,jsonb,text)'::regprocedure) !~ 'Alasan Expired wajib' then raise exception 'GAGAL: posting exception'; end if;
  if pg_get_functiondef('rc_private.email_expired_html(bigint[],uuid,timestamp with time zone)'::regprocedure) ~ '>ALASAN<' then raise exception 'GAGAL: kolom ALASAN masih ada'; end if;
  if pg_get_functiondef('rc_private.email_expired_html(bigint[],uuid,timestamp with time zone)'::regprocedure) !~ 'Alasan Expired:' then raise exception 'GAGAL: blok alasan expired'; end if;
  if pg_get_functiondef('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)'::regprocedure) !~ 'Alasan dipindah ke Open' then raise exception 'GAGAL: alasan restricted'; end if;
  if pg_get_functiondef('rc_private.legacy_documents(text[])'::regprocedure) !~ 'restrictedOpen' then raise exception 'GAGAL: restrictedOpen'; end if;
end $cek$;
