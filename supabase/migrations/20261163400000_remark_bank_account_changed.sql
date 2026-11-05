-- ==========================================================================================
-- Remark "Bank Account Changed". Pemilik, 22 Oktober 2026: "cukup tampilkan remark bank account
-- changed jika admin memasukan no rek baru, bukan diupload dari key master".
-- ==========================================================================================
-- * Saat pengajuan (Submit), bila admin mengisi Nomor Rekening yang berbeda dari Customer Master
--   (Key Master) saat itu, dokumen ditandai rc_private.claim_sensitive.rekening_diubah = true.
--   Rekening yang hanya datang dari Key Master (kolom unggahan kosong / sama) tidak ditandai, dan
--   unggah Customer Master di Key Master tidak menandai dokumen apa pun. Pengajuan ulang menghitung
--   ulang tandanya.
-- * Remark dokumen (Analytics, detail klaim) menambahkan "Bank Account Changed" bila bertanda,
--   bersama kejadian khusus lain (Doc Amendment, Document Reprocessed, CB Type Changed).
-- * Data lama: tanda diisi dari log "Customer Master diperbarui dari pengajuan" (ada sejak
--   13 Oktober 2026) untuk dokumen yang Nomor Rekeningnya berbeda dari Nomor Rekening dokumen
--   toko yang sama yang diajukan sebelumnya. Dokumen yang tidak punya pembanding tidak ditandai.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

alter table rc_private.claim_sensitive add column if not exists rekening_diubah boolean not null default false;

-- Remark dengan kejadian "Bank Account Changed" (tanda tangan baru; versi 5 argumen tetap ada).
create or replace function rc_private.claim_remark_dari(p_reprocessed_at timestamptz, p_ada_reprocess boolean, p_cb_berubah boolean,
  p_amended_at timestamptz, p_amend_dari text[], p_rek_diubah boolean)
returns text language sql stable set search_path = '' as $f$
  select nullif(concat_ws(', ', nullif(rc_private.claim_remark_dari(p_reprocessed_at, p_ada_reprocess, p_cb_berubah, p_amended_at, p_amend_dari), ''),
                          case when coalesce(p_rek_diubah, false) then 'Bank Account Changed' end), '');
$f$;
grant execute on function rc_private.claim_remark_dari(timestamptz, boolean, boolean, timestamptz, text[], boolean) to authenticated;

create or replace function rc_private.claim_remark(c public.claims)
returns text language sql stable set search_path = '' as $f$
  select rc_private.claim_remark_dari(c.reprocessed_at,
    exists(select 1 from public.claim_status_history h where h.claim_id = c.id and h.action like '%reprocess%'),
    c.cashback_type_changed, c.amended_at,
    array(select rc_private.legacy_status(h.from_status) from public.claim_status_history h
           where h.claim_id = c.id and h.action = 'amend' order by h.id) /* 20261163150000 */,
    coalesce((select s.rekening_diubah from rc_private.claim_sensitive s where s.claim_id = c.id), false) /* 20261163400000 */);
$f$;

do $tambal$
declare src text;
begin
  -- Pengajuan: tandai bila admin mengisi Nomor Rekening yang berbeda dari Key Master.
  src := replace(pg_get_functiondef('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)'::regprocedure), E'\r', '');
  if src !~ '20261163400000' then
    src := pg_temp.ganti(src, $p$master_top numeric; input_top numeric; master_changed boolean;$p$,
      $p$master_top numeric; input_top numeric; master_changed boolean; v_rek_baru boolean; /* 20261163400000 */$p$, 1, 'mutate deklarasi');
    src := pg_temp.ganti(src, $p$  master_changed:=false;$p$,
      $p$  master_changed:=false; v_rek_baru:=false; /* 20261163400000 */$p$, 1, 'mutate awal');
    src := pg_temp.ganti(src,
      $p$  elsif v_norek is distinct from nullif(btrim(coalesce(cust.account_number,'')),'') then master_changed:=true; end if;$p$,
      $p$  elsif v_norek is distinct from nullif(btrim(coalesce(cust.account_number,'')),'') then master_changed:=true;
    v_rek_baru:=true; /* 20261163400000: admin mengisi Nomor Rekening baru (bukan dari Key Master) */
  end if;$p$, 1, 'mutate tanda');
    src := pg_temp.ganti(src, $p$account_number=v_norek,account_name=v_namarek,top_text=v_top where claim_id=c.id$p$,
      $p$account_number=v_norek,account_name=v_namarek,top_text=v_top,rekening_diubah=coalesce(v_rek_baru,false) /* 20261163400000 */ where claim_id=c.id$p$,
      1, 'mutate simpan');
    execute src;
  end if;

  -- Analytics (Cashback List / Details).
  src := replace(pg_get_functiondef('public.rc_legacy_dashboard(integer,timestamptz,uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163400000' then
    src := pg_temp.ganti(src,
      $p$'remark',rc_private.claim_remark_dari(c.reprocessed_at, pel.ada_reprocess, c.cashback_type_changed, c.amended_at /* 20261163140000 */, pel.amend_dari /* 20261163150000 */)$p$,
      $p$'remark',rc_private.claim_remark_dari(c.reprocessed_at, pel.ada_reprocess, c.cashback_type_changed, c.amended_at /* 20261163140000 */, pel.amend_dari /* 20261163150000 */, coalesce(rk.rekening_diubah, false) /* 20261163400000 */)$p$,
      1, 'rc_legacy_dashboard remark');
    execute src;
  end if;

  -- Workflow (Claim Process dan layar lain yang membaca rc_legacy_workflow).
  src := replace(pg_get_functiondef('public.rc_legacy_workflow(integer,timestamptz,uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163400000' then
    src := pg_temp.ganti(src,
      $p$'remark',rc_private.claim_remark_dari(c.reprocessed_at, pel.ada_reprocess, c.cashback_type_changed, c.amended_at /* 20261163140000 */, pel.amend_dari /* 20261163150000 */)$p$,
      $p$'remark',rc_private.claim_remark_dari(c.reprocessed_at, pel.ada_reprocess, c.cashback_type_changed, c.amended_at /* 20261163140000 */, pel.amend_dari /* 20261163150000 */, coalesce(s.rekening_diubah, false) /* 20261163400000 */)$p$,
      1, 'rc_legacy_workflow remark');
    execute src;
  end if;
end $tambal$;

-- ---- Data lama: dari log pengajuan yang memperbarui Customer Master (sejak 13 Oktober 2026) ----
with dok as (
  select distinct coalesce(x->>'noDoc', l.details->>'noDoc') no_doc
    from public.activity_logs l
    left join lateral jsonb_array_elements(case when jsonb_typeof(l.details->'dokumen') = 'array' then l.details->'dokumen' else '[]'::jsonb end) x on true
   where l.event_type = 'customer_master_updated_from_upload'
), calon as (
  select c.id, c.customer_id, c.uploaded_at, nullif(btrim(s.account_number), '') norek
    from dok join public.claims c on c.no_doc = dok.no_doc
    join rc_private.claim_sensitive s on s.claim_id = c.id
   where c.uploaded_at is not null and nullif(btrim(s.account_number), '') is not null and not s.rekening_diubah
), banding as (
  select k.id,
         (select nullif(btrim(s2.account_number), '') from public.claims c2 join rc_private.claim_sensitive s2 on s2.claim_id = c2.id
           where c2.customer_id = k.customer_id and c2.id <> k.id and c2.uploaded_at < k.uploaded_at
             and nullif(btrim(s2.account_number), '') is not null
           order by c2.uploaded_at desc limit 1) norek_sebelum, k.norek
    from calon k
)
update rc_private.claim_sensitive s set rekening_diubah = true
  from banding b
 where s.claim_id = b.id and b.norek_sebelum is not null and b.norek_sebelum <> b.norek;
