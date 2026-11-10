-- ==========================================================================================
-- Document Center > Arsip: pencarian cepat, dan arsip terkunci bila dokumennya sudah dicompile ulang
-- ==========================================================================================
-- Pemilik, 9 November 2026: "pada arsip dibuatkan filter pencarian cepat" dan "jika dokumen di arsip,
-- maka user bisa compile dengan kode cust dan kode campaign yang sama dengan konsekuensi dokumen arsip
-- tidak bisa dikembalikan."
-- * rc_private.compile_upload sudah mengabaikan dokumen arsip saat memeriksa duplikat, jadi compile ulang
--   tidak berubah. Yang baru: unarchive ditolak bila kombinasi toko + campaign itu sudah punya dokumen
--   aktif (kalau tidak, satu toko + campaign menjadi dobel).
-- * rc_archived_list: p_cari (No Doc, kode / nama toko, kode campaign, alasan, user), total, dan
--   bisaKembali + dokumen pengganti per baris. Signature lama dibuang. Aman dijalankan berulang.
-- ==========================================================================================

drop function if exists public.rc_archived_list(integer, integer);
create or replace function public.rc_archived_list(p_offset integer default 0, p_limit integer default 100, p_cari text default '')
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
-- 20261163120000: SECURITY DEFINER - sebagai SECURITY INVOKER daftar ini selalu kosong karena RLS
-- claims_scope hanya membuka baris yang belum diarsipkan. Hak dijaga di sini: tab
-- compilation.archive, boleh_arsip_compilation, dan depot dalam jangkauan pemanggil.
declare v jsonb; v_cari text := btrim(coalesce(p_cari, '')); n bigint;
begin
 perform rc_private.require_tab('compilation.archive');
 if not rc_private.boleh_arsip_compilation() /* 20261162130000 */ then raise exception 'Anda belum diberi akses Archive Compilation' using errcode='42501'; end if;
 with a as (
  select c.id, c.no_doc, c.customer_id, c.campaign_id, c.cb_net, c.archive_reason, c.archived_at, ca.campaign_code,
         coalesce(cu.customer_code, c.source_customer_code) kode_toko, coalesce(cu.customer_name, 'Customer Master belum ada') nama_toko,
         coalesce(p.user_code, '') oleh
    from public.claims c
    left join public.customers cu on cu.id = c.customer_id
    join public.campaigns ca on ca.id = c.campaign_id
    left join public.profiles p on p.id = c.archived_by
   where c.archived_at is not null and rc_private.can_access(c.depot_id)
     and (v_cari = '' or position(lower(v_cari) in lower(concat_ws(' ', c.no_doc, cu.customer_code, c.source_customer_code, cu.customer_name, ca.campaign_code, ca.campaign_name, c.archive_reason, p.user_code))) > 0))
 select (select count(*) from a), coalesce((select jsonb_agg(x) from (
  select jsonb_build_object('id', a.id, 'noDoc', a.no_doc, 'kodeToko', a.kode_toko, 'namaToko', a.nama_toko,
           'codeCampaign', a.campaign_code, 'cbNet', a.cb_net, 'alasan', coalesce(a.archive_reason, ''), 'olehUser', a.oleh,
           'waktu', rc_private.legacy_ts(a.archived_at),
           -- 20261163800000: sudah dicompile ulang = tidak dapat dikembalikan.
           'pengganti', (select z.no_doc from public.claims z where z.campaign_id = a.campaign_id and z.customer_id = a.customer_id and z.archived_at is null limit 1)) as x
    from a order by a.archived_at desc
   limit least(greatest(coalesce(p_limit, 100), 1), 500) offset greatest(coalesce(p_offset, 0), 0)) t), '[]'::jsonb) into n, v;
 return jsonb_build_object('status', 'success', 'rows', v, 'total', n);
end $function$;
revoke all on function public.rc_archived_list(integer, integer, text) from public, anon;
grant execute on function public.rc_archived_list(integer, integer, text) to authenticated, service_role;

create or replace function rc_private.unarchive_claims(p_ids uuid[])
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare jml integer; v_bentrok text;
begin
 if not rc_private.boleh_arsip_compilation() /* 20261162130000 */ then raise exception 'Anda belum diberi akses Archive Compilation' using errcode='42501'; end if;
 -- Sama dengan pengarsipan: depot di luar jangkauan tidak ikut dipulihkan walau id-nya ditebak.
 if exists(select 1 from public.claims where id=any(p_ids) and archived_at is not null and not rc_private.can_access(depot_id)) then
  raise exception 'Ada baris di luar akses depot Anda' using errcode='42501'; end if;
 if p_ids is null or array_length(p_ids,1) is null then raise exception 'Pilih baris terlebih dahulu'; end if;
 -- 20261163800000: toko + campaign yang sudah dicompile ulang tidak boleh menjadi dobel.
 select string_agg(a.no_doc || ' (sudah ada ' || z.no_doc || ')', ', ') into v_bentrok
   from public.claims a join public.claims z on z.campaign_id = a.campaign_id and z.customer_id = a.customer_id and z.archived_at is null and z.id <> a.id
  where a.id = any(p_ids) and a.archived_at is not null;
 if v_bentrok is not null then
  raise exception 'Dokumen arsip tidak dapat dikembalikan karena toko dan campaign yang sama sudah dicompile ulang: %', left(v_bentrok, 600); end if;
 update public.claims set archived_at=null,archived_by=null,archive_reason=null,
   updated_at=now(),version_no=version_no+1
 where id=any(p_ids) and archived_at is not null;
 get diagnostics jml=row_count;
 insert into public.activity_logs(actor_id,event_type,details)
 values((select auth.uid()),'compilation_unarchived',jsonb_build_object('jumlah',jml));
 return jsonb_build_object('status','success','jumlah',jml);
end $function$;
