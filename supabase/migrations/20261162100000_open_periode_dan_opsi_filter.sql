-- ==========================================================================================
-- Claim Upload > Open: periode SO dan billing, dan pilihan filter dari data yang ada
-- ==========================================================================================
-- Diminta pemilik, 5 Oktober 2026:
--   1. "tambahkan field start so dan end so, start billing date dan end billing date pada
--      'Pilih kolom' mengikuti dengan campaign master"
--   2. "Filter campaign menampilkan seluruh list campaign yang diikuti toko ... bukan full
--      campaign master sehingga jika tidak ada tidak perlu dimasukan (begitu juga yang lain)"
--
-- 1. Setiap baris membawa soStart, soEnd, billingStart, billingEnd (dd-Mmm-yyyy), mengikuti
--    Campaign Master dengan urutan yang sudah ditetapkan pemilik:
--      SO      = penimpaan dokumen (extend_so_*) > SO campaign > periode campaign
--      billing = penimpaan dokumen (extend_billing_*) > billing campaign > SO campaign
--                > periode campaign     ("billing mengikuti SO", 20261153400000)
--    Periode campaign menjadi dasar karena "by default dokumen itu memiliki periode sesuai
--    campaign start dan campaign end". Saat migrasi ini dibuat, kolom SO dan billing di
--    Campaign Master prod belum pernah diisi; begitu diisi, kolom di sini otomatis mengikuti.
--    Penimpaan extend_* hanya ada selama dokumen On Hold dan dikosongkan saat kembali ke
--    Not Yet, jadi untuk dokumen di tab ini praktis nilai campaign yang tampil.
--
-- 2. Halaman pertama (offset 0) membawa "opsi": daftar campaign dan Jenis CB yang BENAR-BENAR
--    ada di antara dokumen Not Yet dalam jangkauan pemanggil - bukan seluruh Campaign Master.
--    Pilihan dihitung tanpa memperhatikan penyaring yang sedang aktif, supaya dropdown tidak
--    menyusut ketika satu pilihan dipakai.
--
-- Selebihnya fungsi tidak berubah. Dibuktikan: keluaran lama sama persis dengan keluaran baru
-- setelah kunci tambahannya dibuang, untuk beberapa kombinasi penyaring.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $pra$
declare md5_kini text;
begin
  md5_kini := md5(pg_get_functiondef('public.rc_open_claims_filtered(text,text,integer,integer,text)'::regprocedure));
  if md5_kini = '9aa3591d9e1fc7950ac1b1624990da49' then return; end if;
  if pg_get_functiondef('public.rc_open_claims_filtered(text,text,integer,integer,text)'::regprocedure) ~ '''opsi''' then
    raise notice 'rc_open_claims_filtered sudah diperbarui.'; return; end if;
  raise exception 'DITOLAK: definisi rc_open_claims_filtered berbeda dari yang diukur (md5 %).', md5_kini;
end
$pra$;

create temp table _open_sebelum(kunci text primary key, hasil jsonb) on commit drop;

do $sebelum$
declare u uuid; c text; f record; h jsonb;
begin
  if pg_get_functiondef('public.rc_open_claims_filtered(text,text,integer,integer,text)'::regprocedure) ~ '''opsi''' then
    return; end if;
  select id into u from public.profiles where role = 'system manager' and status = 'active' order by user_code limit 1;
  if u is null then return; end if;
  select ca.campaign_code into c from public.claims cl join public.campaigns ca on ca.id = cl.campaign_id
   where cl.status = 'not_yet' and cl.pending_approval is null and cl.archived_at is null
   order by ca.campaign_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', u::text, 'role', 'authenticated')::text, true);
  for f in select * from (values ('semua', '', '', 0, ''), ('hal2', '', '', 200, ''), ('campaign', '', coalesce(c, ''), 0, ''),
                                 ('cari', 'a', '', 0, ''), ('jenis', '', '', 0, 'Transfer')) v(k, s, cp, o, j) loop
    set local role authenticated;
    h := public.rc_open_claims_filtered(f.s, f.cp, f.o, 200, f.j);
    reset role;
    insert into _open_sebelum values (f.k, h);
  end loop;
  perform set_config('request.jwt.claims', '', true);
exception when others then
  reset role; raise;
end
$sebelum$;

create or replace function public.rc_open_claims_filtered(
  p_search text default ''::text, p_campaign text default ''::text, p_offset integer default 0,
  p_limit integer default 200, p_cb_type text default ''::text)
returns jsonb language plpgsql stable set search_path to '' as $function$
declare v jsonb; jml bigint; v_opsi jsonb;
begin
 perform rc_private.require_tab('upload.open');
 if not rc_private.can_access(null,'upload_claim') then
  raise exception 'Access denied' using errcode='42501'; end if;

 select count(*) into jml from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  join public.customers cu on cu.id=c.customer_id
  where c.status='not_yet' and c.pending_approval is null and c.archived_at is null
    and (coalesce(btrim(p_cb_type),'')='' or rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type))=rc_private.jenis_efektif(p_cb_type)) and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%');

 select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
  select jsonb_build_object(
   'noDoc',c.no_doc,'kodeToko',cu.customer_code,'namaToko',cu.customer_name,
   'codeCampaign',ca.campaign_code,'campaignName',ca.campaign_name,
   'jenisCb',rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)),'statusPajakCamp',coalesce(ca.tax_status,''),
   'cbNet',c.cb_net,'dcCode',d.depot_code,'depotName',d.depot_name,
   'top',coalesce(cu.top_text,''),'ktp',coalesce(cu.ktp,''),'npwp',coalesce(cu.npwp,''),
   'noRek',coalesce(cu.account_number,''),'namaRek',coalesce(cu.account_name,''),
   'bank',coalesce(cu.bank,''),'subyekPajak',coalesce(cu.tax_subject,''),
   'contactPerson',coalesce(cu.contact_person,''),
   -- Dua kolom baru yang diminta pemilik.
   'createdOn',to_char(c.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY'),
   'createdBy',coalesce(p.user_code,''),
   'versionNo',c.version_no,
   -- Periode SO dan billing dari Campaign Master (20261162100000).
   'soStart',rc_private.legacy_date(coalesce(c.extend_so_start,ca.so_start,ca.period_start)),
   'soEnd',rc_private.legacy_date(coalesce(c.extend_so_end,ca.so_end,ca.period_end)),
   'billingStart',rc_private.legacy_date(coalesce(c.extend_billing_start,ca.billing_start,ca.so_start,ca.period_start)),
   'billingEnd',rc_private.legacy_date(coalesce(c.extend_billing_end,ca.billing_end,ca.so_end,ca.period_end))) as x
  from public.claims c
  join public.campaigns ca on ca.id=c.campaign_id
  join public.customers cu on cu.id=c.customer_id
  join public.depots d on d.id=c.depot_id
  left join public.profiles p on p.id=c.created_by
  where c.status='not_yet' and c.pending_approval is null and c.archived_at is null
    and (coalesce(btrim(p_cb_type),'')='' or rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type))=rc_private.jenis_efektif(p_cb_type)) and (coalesce(btrim(p_campaign),'')='' or ca.campaign_code=btrim(p_campaign))
    and (coalesce(btrim(p_search),'')='' or c.no_doc ilike '%'||btrim(p_search)||'%'
         or cu.customer_code ilike '%'||btrim(p_search)||'%'
         or cu.customer_name ilike '%'||btrim(p_search)||'%')
  order by ca.campaign_code,c.no_doc
  limit least(greatest(coalesce(p_limit,200),1),500) offset greatest(coalesce(p_offset,0),0)) t;

 -- Pilihan filter: hanya yang ada di antara dokumen Not Yet dalam jangkauan, tanpa
 -- memperhatikan penyaring yang sedang aktif. Hanya pada halaman pertama.
 if coalesce(p_offset,0) = 0 then
  select jsonb_build_object(
    'campaigns', coalesce((select jsonb_agg(jsonb_build_object('kode', k.campaign_code, 'nama', k.campaign_name)
                                            order by k.campaign_code)
                             from (select distinct ca.campaign_code, ca.campaign_name
                                     from public.claims c
                                     join public.campaigns ca on ca.id=c.campaign_id
                                     join public.customers cu on cu.id=c.customer_id
                                    where c.status='not_yet' and c.pending_approval is null and c.archived_at is null) k), '[]'::jsonb),
    'jenisCb', coalesce((select jsonb_agg(j.label order by j.label)
                           from (select distinct rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type)) as label
                                   from public.claims c
                                   join public.campaigns ca on ca.id=c.campaign_id
                                   join public.customers cu on cu.id=c.customer_id
                                  where c.status='not_yet' and c.pending_approval is null and c.archived_at is null) j
                          where coalesce(j.label,'') <> ''), '[]'::jsonb))
    into v_opsi;
 end if;

 return jsonb_build_object('status','success','rows',v,'total',jml)
        || case when v_opsi is null then '{}'::jsonb else jsonb_build_object('opsi', v_opsi) end;
end $function$;

-- Pembuktian: keluaran lama = keluaran baru tanpa kunci tambahan.
do $sesudah$
declare r record; u uuid; c text; f record; baru jsonb; dibuang jsonb; n int := 0;
begin
  select id into u from public.profiles where role = 'system manager' and status = 'active' order by user_code limit 1;
  select ca.campaign_code into c from public.claims cl join public.campaigns ca on ca.id = cl.campaign_id
   where cl.status = 'not_yet' and cl.pending_approval is null and cl.archived_at is null
   order by ca.campaign_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', u::text, 'role', 'authenticated')::text, true);
  for f in select * from (values ('semua', '', '', 0, ''), ('hal2', '', '', 200, ''), ('campaign', '', coalesce(c, ''), 0, ''),
                                 ('cari', 'a', '', 0, ''), ('jenis', '', '', 0, 'Transfer')) v(k, s, cp, o, j) loop
    select hasil into r from _open_sebelum where kunci = f.k;
    if not found then continue; end if;
    set local role authenticated;
    baru := public.rc_open_claims_filtered(f.s, f.cp, f.o, 200, f.j);
    reset role;
    dibuang := (baru - 'opsi') || jsonb_build_object('rows',
      coalesce((select jsonb_agg(e - 'soStart' - 'soEnd' - 'billingStart' - 'billingEnd' order by o)
                  from jsonb_array_elements(baru->'rows') with ordinality t(e, o)), '[]'::jsonb));
    if dibuang is distinct from r.hasil then
      raise exception 'GAGAL rc_open_claims_filtered (%): keluaran lama berubah.', f.k; end if;
    n := n + 1;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'rc_open_claims_filtered: % kombinasi identik.', n;
exception when others then
  reset role; raise;
end
$sesudah$;
