-- ==========================================================================================
-- Memo PDF campaign dapat dibuka dari halaman publik /details-campaign
-- ==========================================================================================
-- Pemilik, 27 Oktober 2026: "memo pdf link publik ya". Sebelumnya (20261163470000) halaman publik
-- hanya menandai memo "Ada".
--
-- Bucket campaign-memo tetap PRIVAT. Anon hanya boleh membuat signed URL (berlaku 5 menit) untuk
-- objek yang menjadi memo campaign yang tidak diarsip - bukan menelusuri isi bucket. Penentunya
-- public.rc_memo_publik(nama objek), SECURITY DEFINER karena anon tidak dapat membaca campaigns.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

create or replace function public.rc_memo_publik(p_nama text)
 returns boolean
 language sql
 stable security definer
 set search_path to ''
as $function$
  select exists(select 1 from public.campaigns c where c.memo_path = p_nama and c.archived_at is null);
$function$;
revoke all on function public.rc_memo_publik(text) from public;
grant execute on function public.rc_memo_publik(text) to anon, authenticated;

drop policy if exists campaign_memo_baca_publik on storage.objects;
create policy campaign_memo_baca_publik on storage.objects for select to anon
  using (bucket_id = 'campaign-memo' and public.rc_memo_publik(name));

-- Path memo ikut dikirim ke halaman publik supaya tombol PDF dapat membukanya.
do $tambal$
declare src text; f text := 'rc_private.timetable_campaigns_isi(boolean)';
begin
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163500000' then
    src := pg_temp.ganti(src, $p$'memoPath', case when p_publik then '' else coalesce(ca.memo_path, '') end,$p$,
      $p$'memoPath', coalesce(ca.memo_path, '') /* 20261163500000: memo publik */,$p$, 1, f);
    execute src;
  end if;
end $tambal$;
