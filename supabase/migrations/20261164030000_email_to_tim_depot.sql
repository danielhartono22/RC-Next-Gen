-- ==========================================================================================
-- Email Pengajuan: TO seluruh tim depot; Done: TO Kepala Admin, Kepala Depot, NPC
-- ==========================================================================================
-- Pemilik, 17 November 2026:
--   "email to semua team depot kadep kepala admin npc dan rsm asm, cc default yakni osc sesuai
--    yuridiksi, spv dan tambahan di tab email pengajuan kecuali untuk done process cukup kepala
--    admin, kadep dan npc aja."
--
-- rc_private.email_pengajuan_penerima(depot, kategori):
--   bukan Done  TO = Kepala Depot + Kepala Admin + NPC + RSM + ASM (Depot Profile)
--               CC = OSC / Supervisor aktif yang memegang depot + CC tambahan + CC wajib jenis itu
--   Done        TO = Kepala Admin + Kepala Depot + NPC
--               CC = CC tambahan + CC wajib Done (tab Email Pengajuan); OSC tidak otomatis
--   Cadangan bila TO kosong: Email Depot lama di Depot Master (bukan Done); untuk Done tetap
--   aturan lama di email_pengajuan_antre (pengaju / pemroses).
-- Alamat yang sudah di TO tidak diulang di CC. Menggantikan isi 20261164010000 dan 20261164020000.
-- ==========================================================================================

create or replace function rc_private.email_pengajuan_penerima(p_depot uuid, p_kategori text)
returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare v_dep public.depots%rowtype; v_p public.depot_profiles%rowtype; v_to text[]; v_cc text[]; v_tam text[]; v_jenis text[];
begin
  select * into v_dep from public.depots where id = p_depot;
  select * into v_p from public.depot_profiles where depot_id = p_depot;

  select coalesce(cc_tambahan, '{}'),
         coalesce(array(select jsonb_array_elements_text(case when p_kategori is null then '[]'::jsonb
                                                              else coalesce(cc_per_jenis->p_kategori, '[]'::jsonb) end)), '{}')
    into v_tam, v_jenis
    from public.email_settings where jenis = 'pengajuan';

  if p_kategori = 'done' then
    -- 20261164030000: Done ke Kepala Admin, Kepala Depot dan NPC; CC hanya yang ditunjuk di tab.
    v_to := rc_private.pecah_email(concat_ws(',', v_p.email_kepala_admin, v_p.email_kepala_depot, v_p.email_npc));
    v_cc := rc_private.pecah_email(array_to_string(v_tam || v_jenis, ','));
  else
    -- 20261164030000: seluruh tim depot di TO.
    v_to := rc_private.pecah_email(concat_ws(',', v_p.email_kepala_depot, v_p.email_kepala_admin, v_p.email_npc, v_p.email_rsm, v_p.email_asm));
    if coalesce(array_length(v_to, 1), 0) = 0 then v_to := rc_private.pecah_email(v_dep.email_to); end if;
    -- CC: OSC / Supervisor aktif yang memegang depot ini + yang ditunjuk di tab.
    v_cc := rc_private.pecah_email(concat_ws(',', array_to_string(v_tam || v_jenis, ','),
              (select string_agg(p.business_email, ',')
                 from public.profiles p join public.user_depot_access uda on uda.user_id = p.id
                where uda.depot_id = p_depot and lower(coalesce(p.role, '')) in ('osc', 'supervisor') and coalesce(p.status, '') = 'active')));
  end if;

  select coalesce(array_agg(distinct c), '{}') into v_cc from unnest(v_cc) c where not (c = any(coalesce(v_to, '{}')));
  select coalesce(array_agg(t order by t), '{}') into v_to from (select distinct t from unnest(v_to) t) z;

  return jsonb_build_object('to', to_jsonb(coalesce(v_to, '{}')), 'cc', to_jsonb(coalesce(v_cc, '{}')),
                            'depot', coalesce(v_dep.depot_name, v_dep.depot_code, ''));
end $f$;

do $cek$
begin
  if pg_get_functiondef('rc_private.email_pengajuan_penerima(uuid,text)'::regprocedure) !~ '20261164030000' then raise exception 'GAGAL'; end if;
end $cek$;
