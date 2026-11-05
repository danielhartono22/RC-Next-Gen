-- ==========================================================================================
-- Document Generator: Form Verifikasi menjadi Tanda Terima, plus Sales Name di Customer Master
-- ==========================================================================================
-- Pemilik, 27 Oktober 2026 (kloter 2):
--   "Tanda tangan cukup toko aja di ujung kanan"
--   "tambahkan keterangan nama sales di samping ttd toko"
--   "di master data, customer master terakhir tambahkan sales name."
--   "Nama form bukan form verifikasi, sekarang jadi Tanda Terima."
--
--   CUSTOMER MASTER  kolom baru customers.sales_name (kolom terakhir). rc_private.customer_upsert
--                    menerima salesName (aturan sama dengan kolom lain: tidak dikirim = tetap,
--                    "" = dikosongkan); rc_customer_list mengirim salesName.
--   DOCUMENT GENERATOR (hanya bila 20261163190000 sudah ada)
--                    rc_docgen_generate mengirim toko.sales untuk dicetak di samping tanda tangan
--                    toko; nomor form berawalan TT- (Tanda Terima), bukan FV-. Deret nomor per
--                    depot per hari tetap satu (tabel rc_form_verifikasi tidak diganti nama).
--                    Judul tab docgen.verifikasi menjadi "Tanda Terima".
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

alter table public.customers add column if not exists sales_name text;
comment on column public.customers.sales_name is 'Nama sales toko (Customer Master, 20261163520000); dicetak di Tanda Terima Document Generator.';

do $tambal$
declare src text; f text;
begin
  -- ---- Customer Master --------------------------------------------------------------------
  f := 'rc_private.customer_upsert(jsonb)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ 'salesName' then
    src := pg_temp.ganti(src, $p$'namaRek','noRek','bank','contactPerson')$p$,
      $p$'namaRek','noRek','bank','contactPerson','salesName') -- 20261163520000$p$, 1, f || ' kolom');
    src := pg_temp.ganti(src, $p$    contact_person=case when r ? 'contactPerson' then nullif(btrim(r->>'contactPerson'),'') else contact_person end,
$p$, $p$    contact_person=case when r ? 'contactPerson' then nullif(btrim(r->>'contactPerson'),'') else contact_person end,
    sales_name=case when r ? 'salesName' then nullif(btrim(r->>'salesName'),'') else sales_name end,
$p$, 1, f || ' update');
    src := pg_temp.ganti(src, $p$     account_name,account_number,bank,contact_person,updated_by)$p$,
      $p$     account_name,account_number,bank,contact_person,sales_name,updated_by)$p$, 1, f || ' insert kolom');
    src := pg_temp.ganti(src, $p$     nullif(btrim(coalesce(r->>'bank','')),''),nullif(btrim(coalesce(r->>'contactPerson','')),''),
$p$, $p$     nullif(btrim(coalesce(r->>'bank','')),''),nullif(btrim(coalesce(r->>'contactPerson','')),''),
     nullif(btrim(coalesce(r->>'salesName','')),''),
$p$, 1, f || ' insert nilai');
    execute src;
  end if;

  f := 'public.rc_customer_list(text,integer,integer)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ 'salesName' then
    src := pg_temp.ganti(src, $p$'bank',coalesce(cu.bank,''),'contactPerson',coalesce(cu.contact_person,''),$p$,
      $p$'bank',coalesce(cu.bank,''),'contactPerson',coalesce(cu.contact_person,''),'salesName',coalesce(cu.sales_name,''), /* 20261163520000 */$p$, 1, f);
    execute src;
  end if;

  -- ---- Document Generator (dev sejak 20261163190000) --------------------------------------
  f := 'public.rc_docgen_generate(jsonb,text)';
  if to_regprocedure(f) is null then
    raise notice 'Document Generator belum ada; bagian Tanda Terima dilewati.';
  else
    src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
    if src !~ '20261163520000' then
      src := pg_temp.ganti(src, $p$coalesce(btrim(cu.account_name), '') atas_nama$p$,
        $p$coalesce(btrim(cu.account_name), '') atas_nama, coalesce(btrim(cu.sales_name), '') sales /* 20261163520000 */$p$, 1, f || ' sales');
      src := pg_temp.ganti(src, $p$'subyekPajak', rc_private.docgen_subyek_pajak(r.npwp))$p$,
        $p$'subyekPajak', rc_private.docgen_subyek_pajak(r.npwp), 'sales', r.sales)$p$, 1, f || ' toko.sales');
      src := pg_temp.ganti(src, $p$v_no := 'FV-' || r.abbr$p$, $p$v_no := 'TT-' || r.abbr$p$, 1, f || ' awalan TT');
      src := pg_temp.ganti(src, $p$|| ' form verifikasi ('$p$, $p$|| ' tanda terima ('$p$, 1, f || ' log');
      execute src;
    end if;
    update rc_private.tab_catalog set title = 'Tanda Terima' where code = 'docgen.verifikasi' and title is distinct from 'Tanda Terima';
  end if;
end $tambal$;
