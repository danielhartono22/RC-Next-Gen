-- ==========================================================================================
-- Penerima Email Pengajuan: TO Kepala Depot, CC RSM; email Done ke NPC + Kepala Admin
-- ==========================================================================================
-- Pemilik, 16 November 2026:
--   "untuk seluruh email pengajuan wajib to ke kadep dan cc ke rsm serta cc tambahan sesuai di tab
--    email pengajuan pada management access. Untuk done cukup ke npc dan kepala admin aja dan cc
--    yang ditunjuk."
--
-- 1. Depot Profile mendapat dua kolom: Email Kepala Depot dan Email NPC (maksimal 4 alamat,
--    dipisah koma). Isinya diisi dari pemetaan email depot (berkas data terpisah, bukan migrasi).
-- 2. rc_private.email_pengajuan_penerima(depot, kategori) - satu sumber untuk seluruh email
--    jalur Email Pengajuan (pengajuan, approval, On Hold / Expired, rekap Expired, Campaign Closed,
--    Done):
--      Done       TO = Email NPC + Email Kepala Admin; CC = CC tambahan + CC wajib jenis Done.
--      lainnya    TO = Email Kepala Depot; CC = Email RSM + CC tambahan + CC wajib jenis itu.
--    OSC / Supervisor depot tidak lagi otomatis masuk CC; yang perlu ditembuskan diisi di tab
--    Email Pengajuan. Email Depot (TO) dan Email CC di Depot Master tidak dipakai lagi untuk jalur ini.
--    Cadangan bila Kepala Depot kosong (mis. Jambi): Email ASM, lalu Email Depot (TO) lama.
--    Cadangan Done bila NPC dan Kepala Admin kosong: aturan lama (pengaju / user yang memproses).
-- Email terjadwal (Daily, Weekly, Not Achieved, debtor, compile, Timetable) tidak berubah.
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

alter table public.depot_profiles add column if not exists email_kepala_depot text;
alter table public.depot_profiles add column if not exists email_npc text;

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
    -- 20261164010000: Done ke NPC dan Kepala Admin; CC hanya yang ditunjuk di tab Email Pengajuan.
    v_to := rc_private.pecah_email(concat_ws(',', v_p.email_npc, v_p.email_kepala_admin));
    v_cc := rc_private.pecah_email(array_to_string(v_tam || v_jenis, ','));
  else
    -- 20261164010000: TO Kepala Depot (cadangan: ASM, lalu Email Depot lama); CC RSM + yang ditunjuk.
    v_to := rc_private.pecah_email(v_p.email_kepala_depot);
    if coalesce(array_length(v_to, 1), 0) = 0 then v_to := rc_private.pecah_email(v_p.email_asm); end if;
    if coalesce(array_length(v_to, 1), 0) = 0 then v_to := rc_private.pecah_email(v_dep.email_to); end if;
    v_cc := rc_private.pecah_email(concat_ws(',', v_p.email_rsm, array_to_string(v_tam || v_jenis, ',')));
  end if;

  -- Alamat yang sudah menjadi tujuan utama tidak perlu ikut sebagai tembusan.
  select coalesce(array_agg(c order by c), '{}') into v_cc from unnest(v_cc) c where not (c = any(coalesce(v_to, '{}')));

  return jsonb_build_object('to', to_jsonb(coalesce(v_to, '{}')), 'cc', to_jsonb(coalesce(v_cc, '{}')),
                            'depot', coalesce(v_dep.depot_name, v_dep.depot_code, ''));
end $f$;

do $tambal$
declare src text;
begin
  -- ---- Email Done: TO dari penerima (NPC + Kepala Admin), bukan hanya Kepala Admin ---------------
  src := replace(pg_get_functiondef('rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)'::regprocedure), E'\r', '');
  if src !~ '20261164010000' then
    src := pg_temp.ganti(src, $p$        from public.depot_profiles dp, unnest(rc_private.pecah_email(dp.email_kepala_admin)) x
       where dp.depot_id = v_dep.depot_id and btrim(x) <> '';$p$,
      $p$        from jsonb_array_elements_text(v_pen->'to') x /* 20261164010000: NPC + Kepala Admin */
       where btrim(x) <> '';$p$, 1, 'antre done');
    execute src;
  end if;

  -- ---- Depot Master: simpan dan tampilkan dua kolom baru -----------------------------------------
  src := replace(pg_get_functiondef('rc_private.terapkan_depot(uuid,jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261164010000' then
    src := pg_temp.ganti(src, $p$    grade = case when c ? 'grade'$p$,
      $p$    -- 20261164010000
    email_kepala_depot = case when c ? 'emailKepalaDepot'
                              then rc_private.periksa_email_maks(c->>'emailKepalaDepot','Email Kepala Depot',4) else email_kepala_depot end,
    email_npc    = case when c ? 'emailNpc'   then rc_private.periksa_email_maks(c->>'emailNpc','Email NPC',4) else email_npc end,
    grade = case when c ? 'grade'$p$, 1, 'terapkan kolom');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_depot_save(text,jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261164010000' then
    src := pg_temp.ganti(src, $p$'emailTo','emailCc','emailKepalaAdmin']; -- 20261163100000$p$,
      $p$'emailTo','emailCc','emailKepalaAdmin','emailKepalaDepot','emailNpc']; -- 20261163100000, 20261164010000$p$, 1, 'save izin');
    src := pg_temp.ganti(src, $p$  perform rc_private.periksa_email_maks(v_bersih->>'emailKepalaAdmin','Email Kepala Admin',4);$p$,
      $p$  perform rc_private.periksa_email_maks(v_bersih->>'emailKepalaAdmin','Email Kepala Admin',4);
  perform rc_private.periksa_email_maks(v_bersih->>'emailKepalaDepot','Email Kepala Depot',4); -- 20261164010000
  perform rc_private.periksa_email_maks(v_bersih->>'emailNpc','Email NPC',4);$p$, 1, 'save periksa');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_depot_list(text,integer,integer)'::regprocedure), E'\r', '');
  if src !~ '20261164010000' then
    src := pg_temp.ganti(src, $p$        'emailKepalaAdmin',coalesce(t.email_kepala_admin,''), -- 20261163100000$p$,
      $p$        'emailKepalaAdmin',coalesce(t.email_kepala_admin,''), -- 20261163100000
        'emailKepalaDepot',coalesce(t.email_kepala_depot,''),'emailNpc',coalesce(t.email_npc,''), -- 20261164010000$p$, 1, 'list json');
    src := pg_temp.ganti(src, $p$p.kar_teknisi, p.kar_lain, p.email_rsm, p.email_asm, p.email_sm, p.email_kepala_admin$p$,
      $p$p.kar_teknisi, p.kar_lain, p.email_rsm, p.email_asm, p.email_sm, p.email_kepala_admin, p.email_kepala_depot, p.email_npc$p$, 1, 'list kolom');
    execute src;
  end if;

  -- ---- Tab Email Pengajuan: contoh dan jumlah depot tanpa Kepala Depot ---------------------------
  src := replace(pg_get_functiondef('public.rc_email_pengajuan_baca()'::regprocedure), E'\r', '');
  if src !~ '20261164010000' then
    src := pg_temp.ganti(src, $p$  select id into v_dep from public.depots
   where archived_at is null and coalesce(email_to,'') <> ''
   order by depot_code limit 1;$p$,
      $p$  select d.id into v_dep from public.depots d join public.depot_profiles p on p.depot_id = d.id
   where d.archived_at is null and coalesce(btrim(p.email_kepala_depot),'') <> '' /* 20261164010000 */
   order by d.depot_code limit 1;$p$, 1, 'baca contoh');
    src := pg_temp.ganti(src, $p$    'depotTanpaEmail', (select count(*) from public.depots
                         where archived_at is null and coalesce(email_to,'')=''),$p$,
      $p$    'depotTanpaEmail', (select count(*) from public.depots d left join public.depot_profiles p on p.depot_id = d.id
                         where d.archived_at is null and not coalesce(d.bukan_depot, false)
                           and coalesce(btrim(p.email_kepala_depot),'') = '' and coalesce(btrim(p.email_asm),'') = ''
                           and coalesce(btrim(d.email_to),'') = ''), /* 20261164010000 */$p$, 1, 'baca tanpa email');
    execute src;
  end if;
end $tambal$;

do $cek$
begin
  if pg_get_functiondef('rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)'::regprocedure) !~ '20261164010000' then raise exception 'GAGAL: antre'; end if;
  if pg_get_functiondef('rc_private.terapkan_depot(uuid,jsonb)'::regprocedure) !~ 'emailNpc' then raise exception 'GAGAL: terapkan'; end if;
  if pg_get_functiondef('public.rc_depot_list(text,integer,integer)'::regprocedure) !~ 'emailKepalaDepot' then raise exception 'GAGAL: list'; end if;
end $cek$;
