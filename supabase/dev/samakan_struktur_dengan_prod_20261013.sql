-- ==========================================================================================
-- DEV SAJA: menyamakan struktur dev dengan prod (13 Oktober 2026)
-- ==========================================================================================
-- Pemilik: "Cek dan duplicate sistem yg prod ke dev karena saya ada beberapa yang tidak bisa di
-- dev" - cakupan yang dipilih: STRUKTUR SAJA (data dan akun dev tidak disentuh).
--
-- Selisih ditemukan dengan membandingkan kolom, tabel, constraint, index, trigger, policy, view,
-- fungsi (isi + izin), ekstensi, event trigger, storage dan cron kedua project. Yang disamakan:
--   1. depot_profile_requests: authenticated boleh SELECT dan policy baca menurut yurisdiksi
--      (tanpa ini pengajuan profil depot tidak terbaca di dev).
--   2. Index unik depots_abbr_idx (Abbr depot tidak boleh ganda).
--   3. Izin service_role pada rc_private.document_counters.
--   4. Izin fungsi compile: hanya authenticated, seperti prod (dev terbuka untuk PUBLIC/anon).
--   5. public.rls_auto_enable() + event trigger ensure_rls (RLS otomatis untuk tabel baru).
--   6. Tabel rc_private.bootstrap_managers dan rc_private.uji_email_cadangan (kosong; tidak
--      dipakai fungsi mana pun, ada di prod).
--   7. Fungsi rc_private.sinkron_rekening dihapus - hanya ada di dev dan tidak dipakai.
--
-- SENGAJA TIDAK disamakan: cron rc_email_antrean dan rc_email_tick (pengirim email). Dev tidak
-- boleh mengirim email sungguhan. public._migrasi_dev (pelacak scripts/siapkan-dev.mjs) tetap.
-- ==========================================================================================

do $dev$ begin
  if current_database() is null or (select count(*) from pg_proc where proname = 'rc_email_tick') = 0
     and exists(select 1 from cron.job where jobname in ('rc_email_antrean','rc_email_tick')) then
    raise exception 'DITOLAK: tampaknya bukan dev.'; end if;
  -- Penjaga utama: prod memiliki cron pengirim email; dev tidak.
  if exists(select 1 from cron.job where jobname in ('rc_email_antrean','rc_email_tick')) then
    raise exception 'DITOLAK: cron email terpasang - skrip ini hanya untuk dev.'; end if;
end $dev$;

-- 1. depot_profile_requests
grant select on public.depot_profile_requests to authenticated;
drop policy if exists depot_profile_requests_baca on public.depot_profile_requests;
create policy depot_profile_requests_baca on public.depot_profile_requests
  as permissive for select to authenticated using (rc_private.can_access(depot_id));

-- 2. Abbr depot unik
create unique index if not exists depots_abbr_idx on public.depots using btree (abbr) where (abbr is not null);

-- 3. document_counters
grant all on rc_private.document_counters to service_role;

-- 4. Izin compile seperti prod
revoke all on function public.rc_compile_preview(jsonb) from public, anon;
revoke all on function public.rc_compile_upload(jsonb, uuid) from public, anon;
grant execute on function public.rc_compile_preview(jsonb) to authenticated, service_role;
grant execute on function public.rc_compile_upload(jsonb, uuid) to authenticated, service_role;
revoke all on function rc_private.compile_upload(jsonb, uuid) from public;
grant execute on function rc_private.compile_upload(jsonb, uuid) to authenticated;

-- 5. RLS otomatis untuk tabel baru (definisi persis dari prod)
create or replace function public.rls_auto_enable()
 returns event_trigger
 language plpgsql
 security definer
 set search_path to 'pg_catalog'
as $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

do $evt$ begin
  if not exists(select 1 from pg_event_trigger where evtname = 'ensure_rls') then
    create event trigger ensure_rls on ddl_command_end execute function public.rls_auto_enable();
  end if;
exception when insufficient_privilege then
  raise notice 'Event trigger ensure_rls tidak dapat dibuat dengan peran ini (dibuat platform di prod).';
end $evt$;

-- 6. Tabel yang ada di prod
create table if not exists rc_private.bootstrap_managers(
  user_code text primary key, full_name text not null,
  suffix_num text not null check (suffix_num ~ '^[0-9]{3}$'), claimed_at timestamptz);
alter table rc_private.bootstrap_managers enable row level security;
revoke all on rc_private.bootstrap_managers from public, anon, authenticated;
grant all on rc_private.bootstrap_managers to service_role;

create table if not exists rc_private.uji_email_cadangan(
  no_doc text primary key, klaim jsonb not null, sensitif jsonb, dibuat timestamptz not null default now());

-- 7. Fungsi sisa yang hanya ada di dev
drop function if exists rc_private.sinkron_rekening(uuid, text, text, text);
