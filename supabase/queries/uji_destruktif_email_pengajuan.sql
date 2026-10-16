-- ==========================================================================================
-- UJI DESTRUKTIF (MENYIMPAN): kelima skema email pengajuan, 2 dokumen per skema
-- ==========================================================================================
-- Dijalankan atas izin eksplisit pemilik. BERBEDA dari berkas uji lain di folder ini: yang ini
-- BENAR-BENAR mengubah status dokumen dan ter-commit, karena hanya perpindahan status yang
-- sungguhan yang dapat membuktikan jalur "action -> email" bekerja. Uji yang digulung balik
-- tidak pernah sampai ke cron pengirim, jadi tidak pernah membuktikan apa pun tentang email.
--
-- Pengamannya:
--   1. Mode Uji WAJIB menyala. Tanpa itu berkas ini menolak jalan, karena surat akan sampai ke
--      depot sungguhan.
--   2. Seluruh baris yang disentuh disalin lebih dulu ke rc_private.uji_email_cadangan, beserta
--      claim_sensitive-nya, sehingga dapat dikembalikan persis.
--   3. Dokumen dipilih dari SATU depot dan hanya yang berstatus Not Yet.
--
-- Pengembaliannya: supabase/queries/pulihkan_uji_destruktif.sql
--
-- Jalankan: node scripts/apply-sql.mjs supabase/queries/uji_destruktif_email_pengajuan.sql
-- ==========================================================================================

create table if not exists rc_private.uji_email_cadangan(
  no_doc text primary key,
  klaim jsonb not null,
  sensitif jsonb,
  dibuat timestamptz not null default now()
);

do $uji$
declare
  v_sm uuid; v_dep uuid; v_kode text;
  a text[]; b text[]; c text[]; semua text[];
  v_r jsonb; nd text;
begin
  -- ---- 0. Pengaman ------------------------------------------------------------------------
  if not exists (select 1 from public.email_settings
                  where jenis='pengajuan' and aktif and mode_uji
                    and btrim(coalesce(email_uji,'')) <> '') then
    raise exception 'DITOLAK: Mode Uji harus menyala dengan alamat terisi sebelum uji ini dijalankan.';
  end if;
  if exists (select 1 from rc_private.uji_email_cadangan) then
    raise exception 'DITOLAK: masih ada cadangan uji sebelumnya. Jalankan pulihkan_uji_destruktif.sql lebih dulu.';
  end if;

  select id into v_sm from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  select d.id, d.depot_code into v_dep, v_kode
    from public.depots d where d.depot_code = '4A' and d.archived_at is null;
  if v_dep is null then raise exception 'Depot 4A tidak ditemukan.'; end if;

  -- ---- 1. Memilih 6 dokumen yang benar-benar lolos syarat submit --------------------------
  create temp table pilihan as
  select c.no_doc, row_number() over (order by c.no_doc) as urut
    from public.claims c
    join public.customers cu on cu.id = c.customer_id
    join public.campaigns ca on ca.id = c.campaign_id
   where c.depot_id = v_dep
     and c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null
     and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override,''), ca.cashback_type))
         not in ('rebate','rebate manual','')
     and ( (nullif(btrim(coalesce(cu.ktp,'')),'')  is not null and nullif(btrim(coalesce(cu.npwp,'')),'') is null)
        or (nullif(btrim(coalesce(cu.npwp,'')),'') is not null and nullif(btrim(coalesce(cu.ktp,'')),'')  is null) )
     and ( rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override,''), ca.cashback_type)) <> 'transfer'
        or ( nullif(btrim(coalesce(cu.account_number,'')),'') is not null
         and nullif(btrim(coalesce(cu.account_name,'')),'')   is not null
         and nullif(btrim(coalesce(cu.bank,'')),'')           is not null ) )
   order by c.no_doc limit 6;

  if (select count(*) from pilihan) < 6 then
    raise exception 'Hanya % dokumen layak; perlu 6.', (select count(*) from pilihan); end if;

  select array_agg(no_doc order by urut) filter (where urut <= 2),
         array_agg(no_doc order by urut) filter (where urut between 3 and 4),
         array_agg(no_doc order by urut) filter (where urut between 5 and 6),
         array_agg(no_doc order by urut)
    into a, b, c, semua from pilihan;

  raise notice 'Depot % | alur penuh: % | on hold: % | expired: %', v_kode, a, b, c;

  -- ---- 2. Cadangan ------------------------------------------------------------------------
  insert into rc_private.uji_email_cadangan(no_doc, klaim, sensitif)
  select cl.no_doc, to_jsonb(cl),
         (select to_jsonb(s) from rc_private.claim_sensitive s where s.claim_id = cl.id)
    from public.claims cl where cl.no_doc = any(semua);
  raise notice 'Cadangan tersimpan: % baris', (select count(*) from rc_private.uji_email_cadangan);

  -- ---- 3. Bertindak sebagai pengguna sungguhan --------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_sm::text,'role','authenticated')::text, true);

  -- Skema 1: SUBMIT (2 dokumen) -> email "Approval - ..."
  v_r := public.rc_process_claims('submit',
    (select jsonb_agg(jsonb_build_object('no_doc',no_doc,'version_no',version_no))
       from public.claims where no_doc = any(a)), gen_random_uuid(), '');
  raise notice 'submit   -> % dokumen, batch %', v_r->>'count', v_r->>'batch';

  -- Skema 2: APPROVE (2 dokumen yang sama) -> email "Approved - ..."
  v_r := public.rc_process_claims('approve',
    (select jsonb_agg(jsonb_build_object('no_doc',no_doc,'version_no',version_no))
       from public.claims where no_doc = any(a)), gen_random_uuid(), '');
  raise notice 'approve  -> % dokumen', v_r->>'count';

  -- Menuju Clearing. Release dan Claim TIDAK mengirim email; keduanya hanya jembatan.
  v_r := public.rc_process_claims('release',
    (select jsonb_agg(jsonb_build_object('no_doc',no_doc,'version_no',version_no))
       from public.claims where no_doc = any(a)), gen_random_uuid(), '');
  raise notice 'release  -> % dokumen (tanpa email, sesuai rancangan)', v_r->>'count';

  v_r := public.rc_process_claims('claim',
    (select jsonb_agg(jsonb_build_object('no_doc',no_doc,'version_no',version_no))
       from public.claims where no_doc = any(a)), gen_random_uuid(), '');
  raise notice 'claim    -> % dokumen (tanpa email, sesuai rancangan)', v_r->>'count';

  -- Skema 3: CLEARING (2 dokumen) -> email "Done - ..."
  v_r := public.rc_process_claims('clearing',
    (select jsonb_agg(jsonb_build_object('no_doc',no_doc,'version_no',version_no))
       from public.claims where no_doc = any(a)), gen_random_uuid(), '');
  raise notice 'clearing -> % dokumen, batch %', v_r->>'count', v_r->>'batch';

  -- Skema 4: HOLD (2 dokumen) -> email "On Hold - ..."
  v_r := public.rc_process_claims('hold',
    (select jsonb_agg(jsonb_build_object('no_doc',no_doc,'version_no',version_no))
       from public.claims where no_doc = any(b)), gen_random_uuid(),
    'Uji skema email - penahanan sementara');
  raise notice 'hold     -> % dokumen', v_r->>'count';

  -- Skema 5: EXPIRE (2 dokumen) -> email "Expired - ..."
  v_r := public.rc_process_claims('expire',
    (select jsonb_agg(jsonb_build_object('no_doc',no_doc,'version_no',version_no))
       from public.claims where no_doc = any(c)), gen_random_uuid(),
    'Uji skema email - penghangusan');
  raise notice 'expire   -> % dokumen', v_r->>'count';

  reset role;

  raise notice 'Selesai. Dokumen yang tersentuh: %', semua;
exception when others then
  reset role;
  raise;
end
$uji$;

-- Hasilnya ditampilkan sebagai tabel supaya terbaca tanpa bergantung pada notice.
select to_char(dibuat_pada at time zone 'Asia/Jakarta','HH24:MI:SS') as dibuat,
       status,
       konteks->>'aksi'      as aksi,
       konteks->>'qty'       as qty,
       konteks->>'modeUji'   as mode_uji,
       array_to_string(tujuan,', ') as tujuan,
       left(subjek,56)       as subjek
  from public.email_outbox
 where jenis='pengajuan' and konteks ? 'aksi'
 order by dibuat_pada desc, subjek;
