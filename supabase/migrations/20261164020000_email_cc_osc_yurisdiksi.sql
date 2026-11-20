-- ==========================================================================================
-- Email Pengajuan: OSC / Supervisor berjurisdiksi tetap ditembuskan
-- ==========================================================================================
-- Pemilik, 16 November 2026 (sesudah 20261164010000): "osc yang memiliki yuridiksi tetep di cc kan?"
-- Seperti sebelum 20261164010000: OSC dan Supervisor aktif yang memegang depot itu ikut CC di semua
-- email jalur Email Pengajuan, kecuali email Done (Done tetap: CC hanya yang ditunjuk di tab).
-- Aman dijalankan berulang.
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
  src := replace(pg_get_functiondef('rc_private.email_pengajuan_penerima(uuid,text)'::regprocedure), E'\r', '');
  if src !~ '20261164020000' then
    src := pg_temp.ganti(src, $p$    v_cc := rc_private.pecah_email(concat_ws(',', v_p.email_rsm, array_to_string(v_tam || v_jenis, ',')));$p$,
      $p$    v_cc := rc_private.pecah_email(concat_ws(',', v_p.email_rsm, array_to_string(v_tam || v_jenis, ',')));
    -- 20261164020000: OSC / Supervisor aktif yang memegang depot ini tetap ditembuskan.
    v_cc := v_cc || rc_private.pecah_email((select string_agg(p.business_email, ',')
              from public.profiles p join public.user_depot_access uda on uda.user_id = p.id
             where uda.depot_id = p_depot and lower(coalesce(p.role, '')) in ('osc', 'supervisor') and coalesce(p.status, '') = 'active'));
    select coalesce(array_agg(distinct c), '{}') into v_cc from unnest(v_cc) c;$p$, 1, 'cc osc');
    execute src;
  end if;
end $tambal$;

do $cek$
begin
  if pg_get_functiondef('rc_private.email_pengajuan_penerima(uuid,text)'::regprocedure) !~ '20261164020000' then raise exception 'GAGAL'; end if;
end $cek$;
