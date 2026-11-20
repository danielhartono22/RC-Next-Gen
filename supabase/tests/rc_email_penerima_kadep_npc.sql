-- ==========================================================================================
-- Uji 16 November 2026: penerima Email Pengajuan dan Done (20261164010000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_penerima_kadep_npc.sql
-- ==========================================================================================
create temp table if not exists _hasil_ep(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_ep;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_dep uuid; v_kode text; r jsonb; v_tam text[];
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and suffix_num ~ '^[0-9]{3}$' order by user_code limit 1;
  select d.id, d.depot_code into v_dep, v_kode from public.depots d where d.archived_at is null and not coalesce(d.bukan_depot, false) order by d.depot_code limit 1;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    update public.profiles set must_change_password = false where id = v_sm;
    insert into public.depot_profiles(depot_id) select v_dep where not exists(select 1 from public.depot_profiles where depot_id = v_dep);
    update public.depot_profiles set email_kepala_depot = 'Kadep.Uji@contoh.co', email_rsm = 'rsm.uji@contoh.co', email_asm = 'asm.uji@contoh.co',
           email_npc = 'npc.uji@contoh.co, npc2.uji@contoh.co', email_kepala_admin = 'ka.uji@contoh.co' where depot_id = v_dep;
    update public.depots set email_to = 'lama.uji@contoh.co', email_cc = 'cclama.uji@contoh.co' where id = v_dep;
    update public.email_settings set cc_tambahan = array['tambah.uji@contoh.co'], cc_per_jenis = jsonb_build_object('done', jsonb_build_array('done.uji@contoh.co'), 'pengajuan', jsonb_build_array('jenis.uji@contoh.co')) where jenis = 'pengajuan';

    -- 20261164030000: TO seluruh tim depot; CC OSC / Supervisor berjurisdiksi + yang ditunjuk; Done TO Kepala Admin, Kepala Depot, NPC.
    v_tam := array(select lower(btrim(p.business_email)) from public.profiles p join public.user_depot_access u on u.user_id = p.id
                    where u.depot_id = v_dep and lower(p.role) in ('osc', 'supervisor') and p.status = 'active' and coalesce(btrim(p.business_email), '') like '%@%');
    r := rc_private.email_pengajuan_penerima(v_dep, 'pengajuan');
    hasil := hasil || jsonb_build_object('uji', 'Pengajuan: TO Kepala Depot + Kepala Admin + NPC + RSM + ASM; CC OSC/Supervisor + tab; tanpa CC Depot Master', 'lulus',
      r->'to' = '["asm.uji@contoh.co", "ka.uji@contoh.co", "kadep.uji@contoh.co", "npc.uji@contoh.co", "npc2.uji@contoh.co", "rsm.uji@contoh.co"]'::jsonb
      and r->'cc' @> '["jenis.uji@contoh.co", "tambah.uji@contoh.co"]'::jsonb and r->'cc' @> to_jsonb(v_tam) and not (r->'cc' ? 'cclama.uji@contoh.co'), 'rinci', r::text);
    r := rc_private.email_pengajuan_penerima(v_dep, 'hold_expired');
    hasil := hasil || jsonb_build_object('uji', 'On Hold / Expired: TO tim depot, CC OSC/Supervisor + CC tambahan', 'lulus',
      jsonb_array_length(r->'to') = 6 and r->'cc' @> '["tambah.uji@contoh.co"]'::jsonb and r->'cc' @> to_jsonb(v_tam), 'rinci', r::text);
    r := rc_private.email_pengajuan_penerima(v_dep, 'done');
    hasil := hasil || jsonb_build_object('uji', 'Done: TO Kepala Admin + Kepala Depot + NPC; CC hanya tab (tanpa OSC, RSM, ASM)', 'lulus',
      r->'to' = '["ka.uji@contoh.co", "kadep.uji@contoh.co", "npc.uji@contoh.co", "npc2.uji@contoh.co"]'::jsonb and r->'cc' = '["done.uji@contoh.co", "tambah.uji@contoh.co"]'::jsonb, 'rinci', r::text);

    update public.depot_profiles set email_kepala_depot = null, email_kepala_admin = null, email_npc = null, email_rsm = null where depot_id = v_dep;
    r := rc_private.email_pengajuan_penerima(v_dep, 'pengajuan');
    hasil := hasil || jsonb_build_object('uji', 'Hanya ASM terisi: TO ASM', 'lulus', r->'to' = '["asm.uji@contoh.co"]'::jsonb, 'rinci', r::text);
    update public.depot_profiles set email_asm = null where depot_id = v_dep;
    r := rc_private.email_pengajuan_penerima(v_dep, 'pengajuan');
    hasil := hasil || jsonb_build_object('uji', 'Tim depot kosong semua: TO Email Depot lama', 'lulus', r->'to' = '["lama.uji@contoh.co"]'::jsonb, 'rinci', r::text);

    -- Depot Master: dua kolom baru tersimpan dan tampil.
    r := public.rc_depot_save(v_kode, jsonb_build_object('emailKepalaDepot', 'kadep2.uji@contoh.co', 'emailNpc', 'npc3.uji@contoh.co'));
    hasil := hasil || jsonb_build_object('uji', 'Depot Master menyimpan Email Kepala Depot dan Email NPC', 'lulus',
      (select email_kepala_depot = 'kadep2.uji@contoh.co' and email_npc = 'npc3.uji@contoh.co' from public.depot_profiles where depot_id = v_dep)
      and exists(select 1 from jsonb_array_elements(public.rc_depot_list(v_kode, 0, 5)->'rows') x where x->>'emailKepalaDepot' = 'kadep2.uji@contoh.co' and x->>'emailNpc' = 'npc3.uji@contoh.co'),
      'rinci', left(r::text, 200));
    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_ep(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_ep order by urut;
