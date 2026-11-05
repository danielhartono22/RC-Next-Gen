-- ==========================================================================================
-- Rekening (Bank, No Rekening, Nama Rekening) sesuai yang diproses, di Analytics dan Document
-- Center. Pemilik, 22 Oktober 2026: "saya mau ditampilkan rekening nama bank dan nama pemilik
-- sesuai dengan yang diproses di analytics dan document center, jadi bisa aja toko udah ganti
-- rek tapi saya mau ditampilkan sesuai kondisinya".
-- ==========================================================================================
-- Setiap pengajuan (Submit) sudah menyimpan rekening yang dipakai dokumen itu di
-- rc_private.claim_sensitive (isian unggahan, atau master saat itu). Rekening itulah yang
-- ditampilkan, bukan master sekarang - toko yang kemudian ganti rekening tidak mengubah dokumen
-- lamanya. Dokumen tanpa salinan (belum pernah diajukan, atau data impor lama) memakai master saat
-- ini dan ditandai sumberRek = 'master'; yang dari dokumen sumberRek = 'dokumen'. Ketiga isian
-- selalu diambil dari sumber yang sama (tidak dicampur per kolom).
-- Hanya menambah isian pada rc_legacy_dashboard (Analytics) dan rc_compilation_list (Document
-- Center); penyaring dan urutan tidak berubah.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

create or replace function rc_private.rekening_tampil(p_s_no text, p_s_nama text, p_s_bank text, p_m_no text, p_m_nama text, p_m_bank text)
returns jsonb language sql immutable set search_path = '' as $f$
  select case
    when coalesce(btrim(p_s_no), '') <> '' or coalesce(btrim(p_s_nama), '') <> '' or coalesce(btrim(p_s_bank), '') <> '' then
      jsonb_build_object('noRek', coalesce(btrim(p_s_no), ''), 'namaRek', coalesce(btrim(p_s_nama), ''), 'bank', coalesce(btrim(p_s_bank), ''),
                         'sumberRek', 'dokumen')
    when coalesce(btrim(p_m_no), '') <> '' or coalesce(btrim(p_m_nama), '') <> '' or coalesce(btrim(p_m_bank), '') <> '' then
      jsonb_build_object('noRek', coalesce(btrim(p_m_no), ''), 'namaRek', coalesce(btrim(p_m_nama), ''), 'bank', coalesce(btrim(p_m_bank), ''),
                         'sumberRek', 'master')
    else jsonb_build_object('noRek', '', 'namaRek', '', 'bank', '', 'sumberRek', '') end;
$f$;
-- Dipanggil di dalam rc_legacy_dashboard / rc_compilation_list yang berjalan sebagai pemanggil
-- (SECURITY INVOKER); fungsi murni tanpa akses data, baris rekening tetap disaring RLS claim_sensitive.
revoke all on function rc_private.rekening_tampil(text, text, text, text, text, text) from public, anon;
grant execute on function rc_private.rekening_tampil(text, text, text, text, text, text) to authenticated;

do $tambal$
declare src text;
begin
  -- Analytics (Cashback List, Details, detail per toko).
  src := replace(pg_get_functiondef('public.rc_legacy_dashboard(integer,timestamptz,uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163390000' then
    src := pg_temp.ganti(src,
      $p$    'batchUpload',coalesce(c.batch_upload,''),'batchClearing',coalesce(c.batch_clearing,''))
   -- Padanan rc_private.claim_details(c).$p$,
      $p$    'batchUpload',coalesce(c.batch_upload,''),'batchClearing',coalesce(c.batch_clearing,''))
   -- 20261163390000: rekening sesuai yang diproses (salinan dokumen; tanpa salinan: master).
   || rc_private.rekening_tampil(rk.account_number, rk.account_name, rk.bank, cu.account_number, cu.account_name, cu.bank)
   -- Padanan rc_private.claim_details(c).$p$, 1, 'rc_legacy_dashboard isian rekening');
    src := pg_temp.ganti(src,
      $p$  join public.campaigns ca on ca.id=c.campaign_id
  -- Riwayat dibaca sekali per klaim:$p$,
      $p$  join public.campaigns ca on ca.id=c.campaign_id
  left join rc_private.claim_sensitive rk on rk.claim_id=c.id /* 20261163390000 */
  -- Riwayat dibaca sekali per klaim:$p$, 1, 'rc_legacy_dashboard join rekening');
    execute src;
  end if;

  -- Document Center.
  src := replace(pg_get_functiondef('public.rc_compilation_list(text,text,text,text,integer,integer,text,date,date)'::regprocedure), E'\r', '');
  if src !~ '20261163390000' then
    src := pg_temp.ganti(src, $p$   'versionNo',c.version_no) as x$p$,
      $p$   'versionNo',c.version_no)
   || rc_private.rekening_tampil(rk.account_number, rk.account_name, rk.bank, cu.account_number, cu.account_name, cu.bank) /* 20261163390000 */ as x$p$,
      1, 'rc_compilation_list isian rekening');
    src := pg_temp.ganti(src, $p$  left join public.profiles p on p.id=c.created_by
  where$p$,
      $p$  left join public.profiles p on p.id=c.created_by
  left join rc_private.claim_sensitive rk on rk.claim_id=c.id /* 20261163390000 */
  where$p$, 1, 'rc_compilation_list join rekening');
    execute src;
  end if;
end $tambal$;
