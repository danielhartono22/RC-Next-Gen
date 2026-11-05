-- ==========================================================================================
-- Discount Center: kebijakan disc, generate template pantek, kartu terbit, acknowledge, monitoring
-- ==========================================================================================
-- Spesifikasi pemilik "Aplikasi Disc Generator - Prompt & Template Excel" (21 Oktober 2026),
-- bagian 2-5 dan 7-11; bagian 6 (Audit SAP) dikeluarkan. Rancangan layar: folder "Disc Center".
-- Keputusan pemilik 21 Oktober 2026:
--  * Sales Distribution IKUT TAB: siapa pun yang diberi tab Monitoring / Kebijakan / Generate /
--    Terbitkan diperlakukan Sales Distribution (seluruh depot, kolom CT & key combination,
--    acknowledge massal). Tanpa role baru (aturan RC "akses mengikuti tab").
--  * Template Sls Org / CG / Mat: Valid From-To di L-M (dirapikan, pola Cust / Mat).
--  * Satuan scale seperti sekarang: RA08/RA09 di kolom Uom, RA03 di kolom Unit setelah ScaleQty
--    (aturan_ct.kolom_satuan, dapat diubah tanpa kode).
--  * Dashboard TIDAK dikunci saat masih ada kartu belum di-acknowledge (pengaturan WAJIB_ACK_DULU).
--
-- Satu izin modul view_discount (Access Management mengelompokkan tab per izin): Dashboard dan
-- Acknowledge bawaan tercentang; Monitoring, Kebijakan, Generate, Terbitkan hanya bila dicentang.
-- Belum diberikan ke siapa pun - hanya System Manager yang melihat modul ini sampai lolos uji.
--
-- Seluruh tabel di schema disc tanpa hak langsung untuk pengguna (RLS aktif, tanpa kebijakan);
-- semua akses lewat RPC public.rc_disc_* yang memeriksa tab sendiri. Tidak ada tabel atau fungsi
-- klaim yang diubah, kecuali tambalan bertanda pada rc_private.tab_rights (tab opt-in) dan
-- public.rc_update_access (kunci izin modul baru, supaya tidak tercabut saat akun disimpan).
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

create schema if not exists disc;
revoke all on schema disc from public, anon, authenticated;

-- ---- 1. Tabel ------------------------------------------------------------------------------
create table if not exists disc.master_mg (
  mg text primary key check (btrim(mg) <> ''),
  nama_produk text not null,
  alias text,
  segmen text not null check (segmen in ('DEKORATIF','PAINTING TOOLS','CAT SEMPROT','LAIN-LAIN')),
  jenis_produk text not null check (jenis_produk in ('READY MIX','CCM')),
  uom_scale text check (uom_scale in ('KG','L','PC')),
  level_wajib text not null default 'MG' check (level_wajib in ('MG','KEMASAN')),
  aktif boolean not null default true,
  diubah_pada timestamptz not null default now(),
  diubah_oleh uuid references public.profiles(id)
);

create table if not exists disc.master_material (
  material text primary key check (btrim(material) <> ''),
  deskripsi text not null,
  mg text not null references disc.master_mg(mg),
  mg1 text, mg2 text, mg3 text,
  aktif boolean not null default true,
  diubah_pada timestamptz not null default now(),
  diubah_oleh uuid references public.profiles(id)
);
create index if not exists master_material_mg on disc.master_material(mg);

create table if not exists disc.target (
  target_id text primary key check (btrim(target_id) <> ''),
  tipe text not null check (tipe in ('CUSTOMER','SLS_OFFICE','SLS_ORG','COND_GROUP2')),
  kode text not null,
  cust_group text,
  nama text not null,
  dc text,
  grup text,
  aturan_disc text not null default 'NORMAL' check (aturan_disc in ('OPEN_QTY','OPEN_QTY_TANPA_BULK','NORMAL')),
  label_output text,
  aktif boolean not null default true,
  diubah_pada timestamptz not null default now(),
  diubah_oleh uuid references public.profiles(id)
);

create table if not exists disc.aturan_ct (
  condition_type text primary key check (btrim(condition_type) <> ''),
  kegunaan text,
  tipe_target text[] not null default '{}',
  level_boleh text[] not null default '{}',
  mode_hitung text check (mode_hitung in ('OPEN_QTY','PER_SCALE','FLAT')),
  komponen text[] not null default '{}',
  uom_scale text,
  kolom_satuan text not null default 'UOM' check (kolom_satuan in ('UOM','UNIT')),
  disc_type_label text,
  batas_amount numeric,
  aktif boolean not null default true,
  diubah_pada timestamptz not null default now(),
  diubah_oleh uuid references public.profiles(id)
);

create table if not exists disc.pengecualian (
  id bigint generated always as identity primary key,
  jenis text not null check (jenis in ('UOM_OVERRIDE','KECUALIKAN_MATERIAL','KHUSUS_WILAYAH','TANPA_KOMPONEN')),
  mg text, material text, condition_type text, target text,
  nilai text not null,
  periode text,
  catatan text not null,
  dibuat_pada timestamptz not null default now(),
  dibuat_oleh uuid references public.profiles(id),
  diganti_pada timestamptz
);

create table if not exists disc.kebijakan (
  id bigint generated always as identity primary key,
  periode text not null check (periode ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  jenis text not null check (jenis in ('VOL','CMP','BULK','BP','PROMO','LAIN','FAKTUR')),
  no_memo text not null,
  mg text, material text, mg1 text, mg2 text, mg3 text,
  scale_qty numeric check (scale_qty is null or scale_qty > 0),
  scale_uom text check (scale_uom in ('KG','L','PC')),
  disc numeric not null check (disc > 0 and disc < 100),
  valid_from date not null,
  valid_to date not null,
  wilayah text,
  untuk_target text,
  catatan text,
  baris_excel integer,
  dibuat_pada timestamptz not null default now(),
  dibuat_oleh uuid references public.profiles(id),
  diganti_pada timestamptz,
  check (valid_from <= valid_to),
  check (mg is not null or material is not null)
);
create index if not exists kebijakan_periode on disc.kebijakan(periode) where diganti_pada is null;

create table if not exists disc.template_kolom (
  level text not null,
  sheet_tujuan text not null,
  baris_header integer not null,
  kolom text not null,
  header text not null default '',
  field text not null default 'KOSONG',
  primary key (level, kolom)
);

create table if not exists disc.pengaturan (
  kunci text primary key,
  nilai text not null,
  diubah_pada timestamptz not null default now()
);

create table if not exists disc.kartu (
  id uuid primary key default gen_random_uuid(),
  periode text not null,
  kunci_item text not null,
  kunci_target text not null,
  mg text, material text, mg1 text, mg2 text, mg3 text,
  -- Isi yang TERBIT (dibaca dashboard dan acknowledge).
  nama_produk text, segmen text, jenis_produk text, untuk_label text, remark text,
  condition_type text, key_combination text, no_memo text, catatan text,
  berlaku_dari date, berlaku_sampai date,
  isi jsonb, tampil_di text[] not null default '{}',
  -- Draft / revisi yang menunggu diterbitkan (bentuk sama, jsonb).
  draft jsonb,
  versi integer not null default 0,
  status text not null default 'DRAFT' check (status in ('DRAFT','TERBIT','DITARIK')),
  diterbitkan_oleh uuid references public.profiles(id),
  waktu_terbit timestamptz,
  ditarik_oleh uuid references public.profiles(id),
  ditarik_pada timestamptz,
  alasan_tarik text,
  dibuat_pada timestamptz not null default now(),
  diubah_pada timestamptz not null default now(),
  unique (periode, kunci_item, kunci_target)
);

-- Catatan acknowledge: hanya ditambah, tidak pernah diubah atau dihapus.
create table if not exists disc.ack (
  kartu_id uuid not null references disc.kartu(id),
  versi integer not null,
  user_id uuid not null references public.profiles(id),
  waktu timestamptz not null default now(),
  primary key (kartu_id, versi, user_id)
);

create table if not exists disc.generate_run (
  id uuid primary key default gen_random_uuid(),
  periode text not null,
  condition_type text not null,
  target text not null,
  komponen text[] not null,
  per_grup boolean not null,
  baris integer not null default 0,
  ringkas jsonb not null default '{}',
  dibuat_pada timestamptz not null default now(),
  dibuat_oleh uuid references public.profiles(id)
);

create table if not exists disc.generate_baris (
  run_id uuid not null references disc.generate_run(id) on delete cascade,
  kunci text not null,
  level text not null,
  condition_type text not null,
  target_kode text,
  mg text, material text,
  amount numeric not null,
  scale_qty numeric, scale_uom text,
  valid_from date not null,
  valid_to date not null
);
create index if not exists generate_baris_kunci on disc.generate_baris(kunci, valid_to);
create index if not exists generate_baris_mg on disc.generate_baris(mg, material);

do $rls$
declare t text;
begin
  foreach t in array array['master_mg','master_material','target','aturan_ct','pengecualian','kebijakan','template_kolom',
                           'pengaturan','kartu','ack','generate_run','generate_baris'] loop
    execute format('alter table disc.%I enable row level security', t);
    execute format('revoke all on disc.%I from public, anon, authenticated', t);
  end loop;
end $rls$;

-- ---- 2. Isi awal ---------------------------------------------------------------------------
insert into disc.pengaturan(kunci, nilai) values ('WAJIB_ACK_DULU', 'N') on conflict (kunci) do nothing;

insert into disc.aturan_ct(condition_type, kegunaan, tipe_target, level_boleh, mode_hitung, komponen, uom_scale, kolom_satuan, disc_type_label, aktif) values
  ('RA01', 'Open qty Toko Khusus, disc khusus customer', '{CUSTOMER,SLS_OFFICE}',
   '{CUST_MG,CUST_MAT,CUST_MG_MG2_MG1,SLSOFF_CG_MG}', 'OPEN_QTY', '{VOL,CMP,BULK}', null, 'UOM', 'Disc Open Qty (Vol, Bulk, CMP)', true),
  ('RA02', 'Perlu dikonfirmasi', '{CUSTOMER,SLS_OFFICE}', '{CUST_MAT,SLSOFF_CG_MAT}', null, '{}', null, 'UOM', null, false),
  ('RA03', 'Campaign, promo, painting tools, disc per kemasan', '{SLS_ORG,SLS_OFFICE,COND_GROUP2}',
   '{SLSORG_CG_MG,SLSORG_CG_MAT,SLSORG_CG_MG_MG1,SLSORG_CG_MG_MG2_MG1,SLSOFF_CG_MG_MG1,SLSOFF_CG_MG_MG2_MG1,CG2_CG_MG_MG3_MG2_MG1}',
   'PER_SCALE', '{CMP,PROMO,VOL}', 'PC', 'UNIT', 'Disc Campaign', true),
  ('RA08', 'Disc volume per tier, satuan KG', '{SLS_OFFICE}', '{SLSOFF_CG_MG}', 'PER_SCALE', '{VOL,CMP,BULK}', 'KG', 'UOM',
   'Disc Vol + Disc CMP + Disc Bulk', true),
  ('RA09', 'Disc volume per tier, satuan L', '{SLS_OFFICE}', '{SLSOFF_CG_MG}', 'PER_SCALE', '{VOL,CMP,BULK}', 'L', 'UOM',
   'Disc Vol + Disc CMP + Disc Bulk', true)
on conflict (condition_type) do nothing;

-- Posisi kolom template Disc (West) per level (spesifikasi bagian 4). Pola: kolom kunci,
-- Description, Amount, Unit, per, Uom, dua kolom kosong, Valid From/To, ScaleQty, Unit, Check,
-- Disc Type, Created On, Remark 1, Remark 2. Sls Org / CG / Mat memakai Valid L-M (keputusan
-- pemilik); header kolom A Sls Org / CG / MG / MG2 / MG1 ditulis "Condition Type".
do $tpl$
declare
  v_def jsonb := jsonb_build_object(
    'CUST_MG', jsonb_build_array('Cust / MG', 3, jsonb_build_array(
       'Condition Type:CONDITION_TYPE','Customer:TARGET','CustGrp:CUST_GROUP','MG:MG',':KOSONG','Description:DESCRIPTION',':KOSONG',
       'Amount:AMOUNT','Unit:UNIT_AMOUNT','per:PER','Uom:UOM',':KOSONG',':KOSONG','Valid From:VALID_FROM','Valid To:VALID_TO',
       'Check:CHECK','Disc Type:DISC_TYPE','Created On:CREATED_ON','Remark 1:REMARK1','Remark 2:REMARK2')),
    'CUST_MAT', jsonb_build_array('Cust / Mat', 3, jsonb_build_array(
       'Condition Type:CONDITION_TYPE','Customer:TARGET','CustGrp:CUST_GROUP','Material:MATERIAL','Description:DESCRIPTION',
       'Amount:AMOUNT','Unit:UNIT_AMOUNT','per:PER','Uom:UOM',':KOSONG',':KOSONG','Valid From:VALID_FROM','Valid To:VALID_TO',
       'ScaleQty:SCALE_QTY','Unit:SCALE_UNIT','Check:CHECK','Disc Type:DISC_TYPE','Created On:CREATED_ON','Remark 1:REMARK1','Remark 2:REMARK2')),
    'CUST_MG_MG2_MG1', jsonb_build_array('Cust / MG / MG2 / MG1', 1, jsonb_build_array(
       'Condition Type:CONDITION_TYPE','Customer:TARGET','MG:MG','MG2:MG2','MG1:MG1',':KOSONG','Description:DESCRIPTION',':KOSONG',
       'Amount:AMOUNT','Unit:UNIT_AMOUNT','per:PER','Uom:UOM',':KOSONG',':KOSONG','Valid From:VALID_FROM','Valid To:VALID_TO',
       'ScaleQty:SCALE_QTY','Unit:SCALE_UNIT','Check:CHECK','Disc Type:DISC_TYPE','Created On:CREATED_ON','Remark 1:REMARK1','Remark 2:REMARK2')),
    'SLSOFF_CG_MG', jsonb_build_array('Sls Off / CG / MG', 1, jsonb_build_array(
       'Condition Type:CONDITION_TYPE','Sls Office:TARGET','CustGrp:CUST_GROUP','MG:MG',':KOSONG','Description:DESCRIPTION',':KOSONG',
       'Amount:AMOUNT','Unit:UNIT_AMOUNT','per:PER','Uom:UOM',':KOSONG',':KOSONG','Valid From:VALID_FROM','Valid To:VALID_TO',
       'ScaleQty:SCALE_QTY','Unit:SCALE_UNIT','Check:CHECK','Disc Type:DISC_TYPE','Created On:CREATED_ON','Remark 1:REMARK1','Remark 2:REMARK2')),
    'SLSOFF_CG_MAT', jsonb_build_array('Sls Off / CG / Mat', 3, jsonb_build_array(
       'Condition Type:CONDITION_TYPE','Sls Office:TARGET','CustGrp:CUST_GROUP','Material:MATERIAL',':KOSONG','Description:DESCRIPTION',':KOSONG',
       'Amount:AMOUNT','Unit:UNIT_AMOUNT','per:PER','Uom:UOM',':KOSONG',':KOSONG','Valid From:VALID_FROM','Valid To:VALID_TO',
       'ScaleQty:SCALE_QTY','Unit:SCALE_UNIT','Check:CHECK','Disc Type:DISC_TYPE','Created On:CREATED_ON','Remark 1:REMARK1','Remark 2:REMARK2')),
    'SLSOFF_CG_MG_MG1', jsonb_build_array('Sls Off / CG / MG / MG1', 1, jsonb_build_array(
       'Condition Type:CONDITION_TYPE','Sls Office:TARGET','CustGrp:CUST_GROUP','MG:MG','MG1:MG1',':KOSONG','Description:DESCRIPTION',':KOSONG',
       'Amount:AMOUNT','Unit:UNIT_AMOUNT','per:PER','Uom:UOM',':KOSONG',':KOSONG','Valid From:VALID_FROM','Valid To:VALID_TO',
       'ScaleQty:SCALE_QTY','Unit:SCALE_UNIT','Check:CHECK','Disc Type:DISC_TYPE','Created On:CREATED_ON','Remark 1:REMARK1','Remark 2:REMARK2')),
    'SLSOFF_CG_MG_MG2_MG1', jsonb_build_array('Sls Off / CG / MG / MG2 / MG1', 1, jsonb_build_array(
       'Condition Type:CONDITION_TYPE','Sls Office:TARGET','CustGrp:CUST_GROUP','MG:MG','MG2:MG2','MG1:MG1',':KOSONG','Description:DESCRIPTION',':KOSONG',
       'Amount:AMOUNT','Unit:UNIT_AMOUNT','per:PER','Uom:UOM',':KOSONG',':KOSONG','Valid From:VALID_FROM','Valid To:VALID_TO',
       'ScaleQty:SCALE_QTY','Unit:SCALE_UNIT','Check:CHECK','Disc Type:DISC_TYPE','Created On:CREATED_ON','Remark 1:REMARK1','Remark 2:REMARK2')),
    'SLSORG_CG_MG', jsonb_build_array('Sls Org / CG / MG', 3, jsonb_build_array(
       'Condition Type:CONDITION_TYPE','Sls Org:TARGET','CustGrp:CUST_GROUP','MG:MG',':KOSONG','Description:DESCRIPTION',':KOSONG',
       'Amount:AMOUNT','Unit:UNIT_AMOUNT','per:PER','Uom:UOM',':KOSONG',':KOSONG','Valid From:VALID_FROM','Valid To:VALID_TO',
       'ScaleQty:SCALE_QTY','Unit:SCALE_UNIT','Check:CHECK','Disc Type:DISC_TYPE','Created On:CREATED_ON','Remark 1:REMARK1','Remark 2:REMARK2')),
    'SLSORG_CG_MAT', jsonb_build_array('Sls Org / CG / Mat', 1, jsonb_build_array(
       'Condition Type:CONDITION_TYPE','Sls Org:TARGET','CustGrp:CUST_GROUP','Material:MATERIAL','Description:DESCRIPTION',
       'Amount:AMOUNT','Unit:UNIT_AMOUNT','per:PER','Uom:UOM',':KOSONG',':KOSONG','Valid From:VALID_FROM','Valid To:VALID_TO',
       'ScaleQty:SCALE_QTY','Unit:SCALE_UNIT','Check:CHECK','Disc Type:DISC_TYPE','Created On:CREATED_ON','Remark 1:REMARK1','Remark 2:REMARK2')),
    'SLSORG_CG_MG_MG1', jsonb_build_array('Sls Org / CG / MG / MG1', 1, jsonb_build_array(
       'Condition Type:CONDITION_TYPE','Sls Org:TARGET','CustGrp:CUST_GROUP','MG:MG','MG1:MG1',':KOSONG','Description:DESCRIPTION',':KOSONG',
       'Amount:AMOUNT','Unit:UNIT_AMOUNT','per:PER','Uom:UOM',':KOSONG',':KOSONG','Valid From:VALID_FROM','Valid To:VALID_TO',
       'ScaleQty:SCALE_QTY','Unit:SCALE_UNIT','Check:CHECK','Disc Type:DISC_TYPE','Created On:CREATED_ON','Remark 1:REMARK1','Remark 2:REMARK2')),
    'SLSORG_CG_MG_MG2_MG1', jsonb_build_array('Sls Org / CG / MG / MG2 / MG1', 1, jsonb_build_array(
       'Condition Type:CONDITION_TYPE','Sls Org:TARGET','CustGrp:CUST_GROUP','MG:MG','MG2:MG2','MG1:MG1',':KOSONG','Description:DESCRIPTION',':KOSONG',
       'Amount:AMOUNT','Unit:UNIT_AMOUNT','per:PER','Uom:UOM',':KOSONG',':KOSONG','Valid From:VALID_FROM','Valid To:VALID_TO',
       'ScaleQty:SCALE_QTY','Unit:SCALE_UNIT','Check:CHECK','Disc Type:DISC_TYPE','Created On:CREATED_ON','Remark 1:REMARK1','Remark 2:REMARK2')),
    'CG2_CG_MG_MG3_MG2_MG1', jsonb_build_array('Cond Group 2 / CG / MG / MG2 / MG1 / MG3', 1, jsonb_build_array(
       'Condition Type:CONDITION_TYPE','Cond Group 2:TARGET','CustGrp:CUST_GROUP','MG:MG','MG3:MG3','MG2:MG2','MG1:MG1',':KOSONG','Description:DESCRIPTION',':KOSONG',
       'Amount:AMOUNT','Unit:UNIT_AMOUNT','per:PER','Uom:UOM',':KOSONG',':KOSONG','Valid From:VALID_FROM','Valid To:VALID_TO',
       'ScaleQty:SCALE_QTY','Unit:SCALE_UNIT','Check:CHECK','Disc Type:DISC_TYPE','Created On:CREATED_ON','Remark 1:REMARK1','Remark 2:REMARK2')));
  v_lv text; v_isi jsonb; v_i integer; v_sel text; v_kol text;
begin
  for v_lv, v_isi in select key, value from jsonb_each(v_def) loop
    for v_i in 0 .. jsonb_array_length(v_isi->2) - 1 loop
      v_sel := v_isi->2->>v_i;
      v_kol := case when v_i < 26 then chr(65 + v_i) else 'A' || chr(65 + v_i - 26) end;
      insert into disc.template_kolom(level, sheet_tujuan, baris_header, kolom, header, field)
      values (v_lv, v_isi->>0, (v_isi->>1)::integer, v_kol, split_part(v_sel, ':', 1), split_part(v_sel, ':', 2))
      on conflict (level, kolom) do nothing;
    end loop;
  end loop;
end $tpl$;

-- ---- 3. Izin dan tab -----------------------------------------------------------------------
insert into public.permissions(code, description)
values ('view_discount', 'Discount Center: kebijakan disc, acknowledge, monitoring, generate template pantek')
on conflict (code) do update set description = excluded.description;

insert into rc_private.tab_catalog(code, module, label, permission, key, tab, title) values
  ('discount.dashboard', 'discount', 'Discount Center', 'view_discount', 'discount', 'dashboard', 'Dashboard'),
  ('discount.ack',       'discount', 'Discount Center', 'view_discount', 'discount', 'ack',       'Acknowledge'),
  ('discount.monitor',   'discount', 'Discount Center', 'view_discount', 'discount', 'monitor',   'Monitoring'),
  ('discount.kebijakan', 'discount', 'Discount Center', 'view_discount', 'discount', 'kebijakan', 'Kebijakan'),
  ('discount.generate',  'discount', 'Discount Center', 'view_discount', 'discount', 'generate',  'Generate'),
  ('discount.terbit',    'discount', 'Discount Center', 'view_discount', 'discount', 'terbit',    'Terbitkan')
on conflict (code) do update set module = excluded.module, label = excluded.label, permission = excluded.permission,
  key = excluded.key, tab = excluded.tab, title = excluded.title;

do $tambal$
declare src text;
begin
  -- tab_rights: empat tab Sales Distribution hanya bila dicentang (pola opt-in).
  src := replace(pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163310000' then
    src := pg_temp.ganti(src, $p$not ((p.role='depot head' and t.code in ('approval.ovd','approval.hold'))$p$,
      $p$not ((p.role='depot head' and t.code in ('approval.ovd','approval.hold')) or t.code in ('discount.monitor','discount.kebijakan','discount.generate','discount.terbit') /* 20261163310000: Sales Distribution hanya bila dicentang */$p$,
      1, 'tab_rights opt-in discount');
    execute src;
  end if;
  -- rc_update_access: kunci izin modul baru. Tanpa ini view_discount tercabut setiap akun disimpan.
  src := replace(pg_get_functiondef('public.rc_update_access(jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261163310000' then
    src := pg_temp.ganti(src, $p$('report','view_report'),$p$,
      $p$('report','view_report'),('discount','view_discount') /* 20261163310000 */,$p$, 1, 'update_access discount');
    execute src;
  end if;
end $tambal$;
