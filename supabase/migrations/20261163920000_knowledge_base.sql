-- ==========================================================================================
-- Knowledge Base: SOP, surat, pricelist, pengumuman, dll. sebagai link + acknowledge
-- ==========================================================================================
-- Pemilik, 11 November 2026:
--  1. "untuk melihat SOP, Pemberitahuan dan Pengumuman apapun dan atau lainnya, nanti akan ada
--     link yang langsung mengarah ke pdf nya."
--  2. "system acknoledgemennt yakni ketika user klik link nya tercatat dan lalu user harus tekan
--     acknoledge dan akan muncul 'Saya sudah membaca dan memahami isi dari (SOP / Surat /
--     Pricelist / .. tergantung jenisnya) tersebut, dan saya akan mengimplementasikannya sesuai
--     dengan yang tertulis serta menyebarkannya kepada team yang belum mendapatkan informasi ini'"
--  3. "ada tanda notifikasi di modul jika ada yang belum terbaca"
--  4. Isian: Judul, description, pin atau tidak (bila pin: dari tanggal - sampai tanggal),
--     participan (admin, kepala depot, osc, atau lainnya), wilayah region / depot.
--  "File hanya diterima dalam bentuk link dan akan terbentuk dalam tab per tab" - konten di tab
--  "Knowledge Resources", pengelolaan di "Knowledge Management" beserta detail yang belum
--  acknowledge dan analytics (diagram belum acknowledge, depot mana, region mana) pada Details.
--
-- KEPUTUSAN
--  * Modul kb tanpa izin modul (permission null), seperti Portal Link. Knowledge Resources
--    (kb.resources) bawaannya terbuka untuk semua akun; Knowledge Management (kb.manage) hanya
--    bila dicentang di Access Management. System Manager selalu memegang keduanya.
--  * Jenis (SOP, Surat, Pricelist, Pengumuman, ...) diketik bebas oleh pengelola dan menjadi tab
--    di Knowledge Resources; penulisan yang sudah ada dipakai ulang tanpa membedakan huruf besar.
--    Kalimat acknowledge memakai nama jenis itu.
--  * Peserta = peran akun (Admin, Kepala Depot, OSC, Supervisor, Finance, Management, Lainnya,
--    System Manager), minimal satu. Wilayah sama dengan Portal Link: kosong = semua wilayah;
--    bila diisi, akun peserta yang jangkauan depotnya mencakup salah satu Region ATAU Depot
--    terpilih. System Manager (bila termasuk peserta) selalu masuk wilayah.
--  * Dokumen hanya terlihat oleh pesertanya. Membuka link tercatat (pertama, terakhir, jumlah);
--    tombol Acknowledge baru dapat ditekan setelah link dibuka untuk versi yang berlaku.
--  * Pin: per dokumen, wajib tanggal Dari dan Sampai; di luar rentang itu dokumen tetap tampil
--    tetapi tidak lagi di atas.
--  * Saat mengubah dokumen, pengelola dapat meminta baca ulang: versi naik, seluruh peserta
--    harus membuka dan acknowledge lagi. Riwayat acknowledge lama tetap di Log Activity.
--  * Hitungan analytics hanya untuk akun aktif yang tab Knowledge Resources-nya tidak dimatikan.
--    Per depot / region, akun dihitung di setiap depot jangkauannya yang masuk wilayah dokumen
--    (sama dengan monitoring Discount Center); akun tanpa depot dan System Manager (jangkauannya
--    seluruh depot) masuk "Tanpa depot".
--  * Tidak ada hapus permanen: diarsip dengan alasan dan dapat dipulihkan.
--  * Log Activity satu baris per proses (simpan, arsip / pulihkan, acknowledge).
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ------------------------------------------------------------------------------------------
-- 1. Tabel
-- ------------------------------------------------------------------------------------------
create table if not exists public.rc_kb_items (
  id uuid primary key default gen_random_uuid(),
  jenis text not null check (btrim(jenis) <> '' and length(jenis) <= 40),
  judul text not null check (btrim(judul) <> '' and length(judul) <= 150),
  deskripsi text check (deskripsi is null or length(deskripsi) <= 2000),
  url text not null check (url ~* '^https?://[^[:space:]<>"]+$' and length(url) <= 1000),
  pinned boolean not null default false,
  pin_dari date,
  pin_sampai date,
  peserta text[] not null check (cardinality(peserta) > 0),
  -- Wilayah; keduanya kosong = semua wilayah.
  regions text[] not null default '{}',
  depot_ids uuid[] not null default '{}',
  -- Naik bila pengelola meminta baca ulang; acknowledge versi lama tidak lagi berlaku.
  versi integer not null default 1,
  versi_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id),
  archived_at timestamptz,
  archived_by uuid references public.profiles(id),
  archive_reason text,
  constraint rc_kb_items_pin check ((not pinned and pin_dari is null and pin_sampai is null)
                                    or (pinned and pin_dari is not null and pin_sampai is not null and pin_sampai >= pin_dari))
);
create index if not exists rc_kb_items_aktif on public.rc_kb_items(created_at desc) where archived_at is null;

-- Satu baris per dokumen per akun: kapan dibuka (untuk versi buka_versi) dan acknowledge.
create table if not exists public.rc_kb_baca (
  item_id uuid not null references public.rc_kb_items(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  buka_versi integer,
  buka_pertama timestamptz,
  buka_terakhir timestamptz,
  jumlah_buka integer not null default 0,
  ack_versi integer,
  ack_at timestamptz,
  pernyataan text,
  primary key (item_id, user_id)
);
create index if not exists rc_kb_baca_user on public.rc_kb_baca(user_id);

-- Hanya lewat RPC.
alter table public.rc_kb_items enable row level security;
alter table public.rc_kb_baca enable row level security;
revoke all on public.rc_kb_items, public.rc_kb_baca from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Pembantu
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.kb_peran_semua() returns text[]
language sql immutable set search_path = '' as $f$
  select array['admin', 'depot head', 'osc', 'supervisor', 'finance', 'management', 'others', 'system manager']::text[];
$f$;

create or replace function rc_private.kb_peran_label(p text) returns text
language sql immutable set search_path = '' as $f$
  select case lower(btrim(coalesce(p, '')))
    when 'admin' then 'Admin' when 'depot head' then 'Kepala Depot' when 'osc' then 'OSC'
    when 'supervisor' then 'Supervisor' when 'finance' then 'Finance' when 'management' then 'Management'
    when 'others' then 'Lainnya' when 'system manager' then 'System Manager' else initcap(coalesce(p, '-')) end;
$f$;

create or replace function rc_private.kb_pernyataan(p_jenis text) returns text
language sql immutable set search_path = '' as $f$
  select 'Saya sudah membaca dan memahami isi dari ' || btrim(coalesce(p_jenis, 'dokumen')) || ' tersebut, dan saya akan '
      || 'mengimplementasikannya sesuai dengan yang tertulis serta menyebarkannya kepada team yang belum mendapatkan '
      || 'informasi ini.';
$f$;

create or replace function rc_private.kb_wilayah_teks(p_regions text[], p_depots uuid[]) returns text
language sql stable security definer set search_path = '' as $f$
  select case when coalesce(cardinality(p_regions), 0) = 0 and coalesce(cardinality(p_depots), 0) = 0 then 'Semua wilayah'
              else rc_private.link_aturan_teks(p_regions, p_depots) end;
$f$;

-- Apakah akun (dengan perannya) termasuk peserta dokumen: perannya dipilih dan wilayahnya cocok.
create or replace function rc_private.kb_cocok(p_user uuid, p_role text, p_peserta text[], p_regions text[], p_depots uuid[])
returns boolean language sql stable security definer set search_path = '' as $f$
  select coalesce(p_role, '') = any(coalesce(p_peserta, '{}'))
     and (p_role = 'system manager'
          or (coalesce(cardinality(p_regions), 0) = 0 and coalesce(cardinality(p_depots), 0) = 0)
          or exists(select 1 from public.user_depot_access a join public.depots d on d.id = a.depot_id
                     where a.user_id = p_user
                       and (d.id = any(coalesce(p_depots, '{}'))
                            or upper(btrim(coalesce(d.region, ''))) = any(coalesce(p_regions, '{}')))));
$f$;

-- Pasangan dokumen x akun peserta (akun aktif yang tab Knowledge Resources-nya tidak dimatikan),
-- beserta status baca untuk versi yang berlaku.
create or replace function rc_private.kb_pasangan(p_items uuid[])
returns table(item_id uuid, user_id uuid, dibuka boolean, sudah boolean, buka_pada timestamptz, ack_pada timestamptz)
language sql stable security definer set search_path = '' as $f$
  select i.id, p.id, coalesce(b.buka_versi = i.versi, false), coalesce(b.ack_versi = i.versi, false),
         case when b.buka_versi = i.versi then b.buka_pertama end, case when b.ack_versi = i.versi then b.ack_at end
    from public.rc_kb_items i
    join public.profiles p on p.status = 'active' and p.archived_at is null
     and not exists(select 1 from rc_private.user_tab_access u where u.user_id = p.id and u.tab_code = 'kb.resources' and not u.allowed)
     and rc_private.kb_cocok(p.id, p.role, i.peserta, i.regions, i.depot_ids)
    left join public.rc_kb_baca b on b.item_id = i.id and b.user_id = p.id
   where i.id = any(coalesce(p_items, '{}'));
$f$;

revoke all on function rc_private.kb_peran_semua(), rc_private.kb_peran_label(text), rc_private.kb_pernyataan(text),
  rc_private.kb_wilayah_teks(text[], uuid[]), rc_private.kb_cocok(uuid, text, text[], text[], uuid[]),
  rc_private.kb_pasangan(uuid[]) from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. RPC Knowledge Resources (peserta)
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_kb_list() returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_role text; v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_rows jsonb;
begin
  perform rc_private.require_tab('kb.resources');
  select role into v_role from public.profiles where id = auth.uid();
  select coalesce(jsonb_agg(x.j order by x.pin desc, x.dibuat desc), '[]'::jsonb) into v_rows from (
    select (i.pinned and v_hari between i.pin_dari and i.pin_sampai) pin, i.created_at dibuat,
           jsonb_build_object('id', i.id, 'jenis', i.jenis, 'judul', i.judul, 'deskripsi', coalesce(i.deskripsi, ''), 'url', i.url,
             'pin', i.pinned and v_hari between i.pin_dari and i.pin_sampai,
             'pinSampai', coalesce(to_char(i.pin_sampai, 'DD-Mon-YYYY'), ''),
             'versi', i.versi,
             'dibuka', coalesce(b.buka_versi = i.versi, false),
             'dibukaPada', coalesce(case when b.buka_versi = i.versi then to_char(b.buka_pertama at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') end, ''),
             'ack', coalesce(b.ack_versi = i.versi, false),
             'ackPada', coalesce(case when b.ack_versi = i.versi then to_char(b.ack_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') end, ''),
             'revisi', b.ack_versi is not null and b.ack_versi <> i.versi,
             'terbit', to_char(i.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY'),
             'revisiPada', case when i.versi > 1 then to_char(i.versi_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY') else '' end,
             'pernyataan', rc_private.kb_pernyataan(i.jenis)) j
      from public.rc_kb_items i
      left join public.rc_kb_baca b on b.item_id = i.id and b.user_id = auth.uid()
     where i.archived_at is null and rc_private.kb_cocok(auth.uid(), v_role, i.peserta, i.regions, i.depot_ids)) x;
  return jsonb_build_object('status', 'success', 'rows', v_rows,
    'belum', (select count(*) from jsonb_array_elements(v_rows) e where not (e->>'ack')::boolean));
end $f$;

-- Jumlah dokumen yang belum di-acknowledge akun ini (badge beranda). Tanpa tab = 0, bukan galat.
create or replace function public.rc_kb_belum() returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_role text;
begin
  if not rc_private.can_tab('kb.resources') then return jsonb_build_object('status', 'success', 'belum', 0); end if;
  select role into v_role from public.profiles where id = auth.uid();
  return jsonb_build_object('status', 'success', 'belum',
    (select count(*) from public.rc_kb_items i
       left join public.rc_kb_baca b on b.item_id = i.id and b.user_id = auth.uid()
      where i.archived_at is null and b.ack_versi is distinct from i.versi
        and rc_private.kb_cocok(auth.uid(), v_role, i.peserta, i.regions, i.depot_ids)));
end $f$;

-- Dokumen yang dapat dibaca akun ini (aktif dan ditujukan kepadanya), dikunci untuk diubah.
create or replace function rc_private.kb_item_peserta(p_id uuid) returns public.rc_kb_items
language plpgsql security definer set search_path = '' as $f$
declare v public.rc_kb_items%rowtype; v_role text;
begin
  perform rc_private.require_tab('kb.resources');
  select * into v from public.rc_kb_items where id = p_id and archived_at is null;
  if not found then raise exception 'Dokumen tidak ditemukan atau sudah diarsip'; end if;
  select role into v_role from public.profiles where id = auth.uid();
  if not rc_private.kb_cocok(auth.uid(), v_role, v.peserta, v.regions, v.depot_ids) then
    raise exception 'Dokumen ini tidak ditujukan untuk akun Anda'; end if;
  return v;
end $f$;
revoke all on function rc_private.kb_item_peserta(uuid) from public, anon, authenticated;

-- Link dibuka: dicatat sebelum peramban berpindah ke dokumennya.
create or replace function public.rc_kb_buka(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v public.rc_kb_items%rowtype; v_b public.rc_kb_baca%rowtype;
begin
  v := rc_private.kb_item_peserta(p_id);
  insert into public.rc_kb_baca as b (item_id, user_id, buka_versi, buka_pertama, buka_terakhir, jumlah_buka)
  values (v.id, auth.uid(), v.versi, now(), now(), 1)
  on conflict (item_id, user_id) do update
     set buka_pertama = case when b.buka_versi is distinct from excluded.buka_versi then excluded.buka_pertama else b.buka_pertama end,
         buka_versi = excluded.buka_versi, buka_terakhir = excluded.buka_terakhir, jumlah_buka = b.jumlah_buka + 1
  returning * into v_b;
  return jsonb_build_object('status', 'success', 'versi', v.versi,
    'dibukaPada', to_char(v_b.buka_pertama at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'));
end $f$;

-- Acknowledge: hanya setelah link versi yang berlaku dibuka.
create or replace function public.rc_kb_ack(p_id uuid, p_versi integer default null) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v public.rc_kb_items%rowtype; v_b public.rc_kb_baca%rowtype; v_teks text;
begin
  v := rc_private.kb_item_peserta(p_id);
  if p_versi is not null and p_versi <> v.versi then
    raise exception 'Dokumen ini baru saja direvisi. Segarkan halaman, buka ulang dokumennya, lalu acknowledge.'; end if;
  select * into v_b from public.rc_kb_baca where item_id = v.id and user_id = auth.uid() for update;
  if v_b.buka_versi is distinct from v.versi then
    raise exception 'Buka dan baca dokumennya lebih dulu, lalu tekan Acknowledge.'; end if;
  if v_b.ack_versi = v.versi then
    return jsonb_build_object('status', 'success', 'sudah', true,
      'ackPada', to_char(v_b.ack_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
      'message', 'Dokumen ini sudah Anda acknowledge.');
  end if;
  v_teks := rc_private.kb_pernyataan(v.jenis);
  update public.rc_kb_baca set ack_versi = v.versi, ack_at = now(), pernyataan = v_teks
   where item_id = v.id and user_id = auth.uid()
  returning * into v_b;
  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), 'kb_acknowledge',
    jsonb_build_object('detail', 'Acknowledge ' || v.jenis || ': ' || v.judul || case when v.versi > 1 then ' (versi ' || v.versi || ')' else '' end,
                       'itemId', v.id, 'jenis', v.jenis, 'judul', v.judul, 'versi', v.versi, 'pernyataan', v_teks),
    'kb', 'resources', 'resources');
  return jsonb_build_object('status', 'success', 'sudah', false,
    'ackPada', to_char(v_b.ack_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
    'message', 'Terima kasih. Acknowledge ' || v.jenis || ' "' || v.judul || '" tercatat.');
end $f$;

-- ------------------------------------------------------------------------------------------
-- 4. RPC Knowledge Management (pengelola)
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_kb_kelola_list(p_arsip boolean default false) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_ids uuid[];
begin
  perform rc_private.require_tab('kb.manage');
  v_ids := array(select id from public.rc_kb_items where (archived_at is not null) = coalesce(p_arsip, false));
  return jsonb_build_object('status', 'success',
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'jenis', i.jenis, 'judul', i.judul,
              'deskripsi', coalesce(i.deskripsi, ''), 'url', i.url,
              'pinned', i.pinned, 'pinAktif', i.pinned and v_hari between i.pin_dari and i.pin_sampai,
              'pinDari', coalesce(to_char(i.pin_dari, 'YYYY-MM-DD'), ''), 'pinSampai', coalesce(to_char(i.pin_sampai, 'YYYY-MM-DD'), ''),
              'pinTeks', case when i.pinned then to_char(i.pin_dari, 'DD-Mon-YYYY') || ' s/d ' || to_char(i.pin_sampai, 'DD-Mon-YYYY') else '' end,
              'peserta', to_jsonb(i.peserta),
              'pesertaTeks', (select string_agg(rc_private.kb_peran_label(r), ', ' order by o)
                                from unnest(rc_private.kb_peran_semua()) with ordinality z(r, o) where r = any(i.peserta)),
              'regions', to_jsonb(i.regions), 'depotIds', to_jsonb(i.depot_ids),
              'wilayah', rc_private.kb_wilayah_teks(i.regions, i.depot_ids),
              'versi', i.versi,
              'target', coalesce(s.target, 0), 'sudah', coalesce(s.sudah, 0), 'dibuka', coalesce(s.dibuka, 0),
              'dibuat', to_char(i.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY'),
              'diubahOleh', coalesce(nullif(p.full_name, ''), p.user_code, '-'),
              'diubahPada', to_char(i.updated_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
              'arsip', i.archived_at is not null, 'alasanArsip', coalesce(i.archive_reason, ''),
              'diarsipPada', coalesce(to_char(i.archived_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), ''))
              order by (i.pinned and v_hari between i.pin_dari and i.pin_sampai) desc, i.created_at desc)
       from public.rc_kb_items i
       left join (select q.item_id, count(*) target, count(*) filter (where q.sudah) sudah, count(*) filter (where q.dibuka) dibuka
                    from rc_private.kb_pasangan(v_ids) q group by q.item_id) s on s.item_id = i.id
       left join public.profiles p on p.id = coalesce(i.updated_by, i.created_by)
      where i.id = any(v_ids)), '[]'::jsonb),
    'jumlahAktif', (select count(*) from public.rc_kb_items where archived_at is null),
    'jumlahArsip', (select count(*) from public.rc_kb_items where archived_at is not null),
    'peran', (select jsonb_agg(jsonb_build_object('kode', r, 'label', rc_private.kb_peran_label(r)) order by o)
                from unnest(rc_private.kb_peran_semua()) with ordinality z(r, o)),
    'jenisAda', (select jsonb_agg(j order by lower(j)) from (
                   select distinct on (lower(x)) x j from (
                     select jenis x from public.rc_kb_items
                     union all select unnest(array['SOP', 'Surat', 'Pricelist', 'Pengumuman', 'Pemberitahuan'])) y
                   order by lower(x), x) z),
    'regions', coalesce((select jsonb_agg(r order by r) from (select distinct upper(btrim(d.region)) r from public.depots d
                 where d.archived_at is null and btrim(coalesce(d.region, '')) <> '') x), '[]'::jsonb),
    'depots', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kode', d.depot_code,
                 'nama', coalesce(nullif(d.depot_name, ''), d.depot_code), 'region', coalesce(upper(btrim(d.region)), ''))
                 order by d.depot_code) from public.depots d where d.archived_at is null), '[]'::jsonb));
end $f$;

-- Tambah (id kosong) atau ubah satu dokumen.
create or replace function public.rc_kb_simpan(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  v_id uuid; v_jenis text := regexp_replace(btrim(coalesce(p->>'jenis', '')), '\s+', ' ', 'g');
  v_judul text := regexp_replace(btrim(coalesce(p->>'judul', '')), '\s+', ' ', 'g');
  v_desk text := nullif(btrim(coalesce(p->>'deskripsi', '')), ''); v_url text := btrim(coalesce(p->>'url', ''));
  v_pin boolean := coalesce(jsonb_typeof(p->'pinned') = 'boolean' and (p->>'pinned')::boolean, false);
  v_dari date; v_sampai date; v_hari date := (now() at time zone 'Asia/Jakarta')::date;
  v_peserta text[]; v_reg text[]; v_dep uuid[]; v_salah text[]; v_ada text; v_ulang boolean := false;
  v_lama public.rc_kb_items%rowtype;
begin
  perform rc_private.require_tab('kb.manage');
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Data dokumen tidak valid'; end if;
  begin v_id := nullif(btrim(coalesce(p->>'id', '')), '')::uuid;
  exception when invalid_text_representation then raise exception 'Dokumen tidak ditemukan'; end;
  if v_jenis = '' then raise exception 'Jenis wajib diisi (mis. SOP, Surat, Pricelist)'; end if;
  if length(v_jenis) > 40 then raise exception 'Jenis maksimal 40 karakter'; end if;
  if v_judul = '' then raise exception 'Judul wajib diisi'; end if;
  if length(v_judul) > 150 then raise exception 'Judul maksimal 150 karakter'; end if;
  if length(coalesce(v_desk, '')) > 2000 then raise exception 'Description maksimal 2000 karakter'; end if;
  if v_url !~* '^https?://[^[:space:]<>"]+$' then raise exception 'Link harus diawali http:// atau https:// dan tanpa spasi'; end if;
  if length(v_url) > 1000 then raise exception 'Link maksimal 1000 karakter'; end if;

  if v_pin then
    if coalesce(p->>'pinDari', '') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(p->>'pinSampai', '') !~ '^\d{4}-\d{2}-\d{2}$' then
      raise exception 'Isi tanggal pin Dari dan Sampai'; end if;
    begin v_dari := (p->>'pinDari')::date; v_sampai := (p->>'pinSampai')::date;
    exception when others then raise exception 'Tanggal pin tidak terbaca'; end;
    if v_sampai < v_dari then raise exception 'Tanggal pin Sampai tidak boleh sebelum tanggal Dari'; end if;
  end if;

  if jsonb_typeof(coalesce(p->'peserta', '[]')) <> 'array' then raise exception 'Peserta tidak valid'; end if;
  v_peserta := array(select distinct lower(btrim(x)) from jsonb_array_elements_text(coalesce(p->'peserta', '[]')) x where btrim(x) <> '');
  v_salah := array(select r from unnest(v_peserta) r where r <> all(rc_private.kb_peran_semua()));
  if cardinality(v_salah) > 0 then raise exception 'Peserta tidak dikenal: %', array_to_string(v_salah, ', '); end if;
  if cardinality(v_peserta) = 0 then raise exception 'Pilih minimal satu peserta (mis. Admin, Kepala Depot, OSC)'; end if;
  v_peserta := array(select r from unnest(rc_private.kb_peran_semua()) with ordinality z(r, o) where r = any(v_peserta) order by o);

  if jsonb_typeof(coalesce(p->'regions', '[]')) <> 'array' or jsonb_typeof(coalesce(p->'depotIds', '[]')) <> 'array' then
    raise exception 'Wilayah tidak valid'; end if;
  v_reg := array(select distinct upper(btrim(x)) from jsonb_array_elements_text(coalesce(p->'regions', '[]')) x
                  where btrim(x) <> '' order by 1);
  v_salah := array(select r from unnest(v_reg) r
                    where not exists(select 1 from public.depots d where d.archived_at is null and upper(btrim(coalesce(d.region, ''))) = r));
  if cardinality(v_salah) > 0 then raise exception 'Region tidak dikenal: %', array_to_string(v_salah, ', '); end if;
  begin
    v_dep := array(select distinct btrim(x)::uuid from jsonb_array_elements_text(coalesce(p->'depotIds', '[]')) x where btrim(x) <> '');
  exception when invalid_text_representation then raise exception 'Depot tidak valid'; end;
  if exists(select 1 from unnest(v_dep) i where not exists(select 1 from public.depots d where d.id = i and d.archived_at is null)) then
    raise exception 'Depot tidak dikenal atau sudah diarsip'; end if;

  if v_id is not null then
    select * into v_lama from public.rc_kb_items where id = v_id for update;
    if not found then raise exception 'Dokumen tidak ditemukan'; end if;
    if v_lama.archived_at is not null then raise exception 'Dokumen sudah diarsip; pulihkan lebih dulu'; end if;
    v_ulang := coalesce(jsonb_typeof(p->'bacaUlang') = 'boolean' and (p->>'bacaUlang')::boolean, false);
  end if;
  -- Rentang pin yang baru diisi atau diubah tidak boleh sudah berakhir.
  if v_pin and v_sampai < v_hari and (v_lama.id is null or v_lama.pin_sampai is distinct from v_sampai) then
    raise exception 'Tanggal pin Sampai (%) sudah lewat', to_char(v_sampai, 'DD-Mon-YYYY'); end if;

  -- Jenis yang sudah ada dipakai dengan penulisan yang sama, supaya tab tidak terbelah.
  select i.jenis into v_ada from public.rc_kb_items i
   where lower(i.jenis) = lower(v_jenis) and i.id is distinct from v_id order by i.archived_at nulls first, i.created_at limit 1;
  v_jenis := coalesce(v_ada, v_jenis);

  if v_id is null then
    insert into public.rc_kb_items(jenis, judul, deskripsi, url, pinned, pin_dari, pin_sampai, peserta, regions, depot_ids, created_by, updated_by)
    values (v_jenis, v_judul, v_desk, v_url, v_pin, v_dari, v_sampai, v_peserta, v_reg, v_dep, auth.uid(), auth.uid()) returning id into v_id;
  else
    update public.rc_kb_items set jenis = v_jenis, judul = v_judul, deskripsi = v_desk, url = v_url, pinned = v_pin,
           pin_dari = v_dari, pin_sampai = v_sampai, peserta = v_peserta, regions = v_reg, depot_ids = v_dep,
           versi = versi + case when v_ulang then 1 else 0 end, versi_at = case when v_ulang then now() else versi_at end,
           updated_at = now(), updated_by = auth.uid()
     where id = v_id;
  end if;

  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), case when v_lama.id is null then 'kb_tambah' else 'kb_ubah' end,
    jsonb_build_object('detail', case when v_lama.id is null then 'Tambah ' else 'Ubah ' end || v_jenis || ': ' || v_judul
                                   || ' (' || array_to_string(array(select rc_private.kb_peran_label(r) from unnest(v_peserta) r), ', ')
                                   || ' · ' || rc_private.kb_wilayah_teks(v_reg, v_dep) || ')'
                                   || case when v_ulang then ' - peserta diminta acknowledge ulang' else '' end,
                       'itemId', v_id, 'jenis', v_jenis, 'judul', v_judul, 'url', v_url, 'peserta', to_jsonb(v_peserta),
                       'regions', to_jsonb(v_reg), 'depotIds', to_jsonb(v_dep), 'pinned', v_pin,
                       'pinDari', v_dari, 'pinSampai', v_sampai, 'bacaUlang', v_ulang,
                       'sebelum', case when v_lama.id is null then null else jsonb_build_object('jenis', v_lama.jenis, 'judul', v_lama.judul,
                                    'url', v_lama.url, 'peserta', to_jsonb(v_lama.peserta), 'regions', to_jsonb(v_lama.regions),
                                    'depotIds', to_jsonb(v_lama.depot_ids), 'versi', v_lama.versi) end),
    'kb', 'manage', 'manage');
  return jsonb_build_object('status', 'success', 'id', v_id,
    'message', case when v_lama.id is null then 'Dokumen ditambahkan' else 'Dokumen diperbarui' end || ': ' || v_jenis || ' - ' || v_judul
               || case when v_ulang then '. Seluruh peserta diminta membuka dan acknowledge ulang.' else '.' end);
end $f$;

-- Arsip (dengan alasan) atau pulihkan beberapa dokumen sekaligus.
create or replace function public.rc_kb_arsip(p_ids uuid[], p_arsip boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare n integer; v_alasan text := left(btrim(coalesce(p_reason, '')), 300);
  v_ids uuid[] := array(select distinct x from unnest(coalesce(p_ids, '{}')) x where x is not null);
begin
  perform rc_private.require_tab('kb.manage');
  if p_arsip is null then raise exception 'Pilih arsip atau pulihkan'; end if;
  if cardinality(v_ids) = 0 then raise exception 'Pilih dokumen lebih dulu'; end if;
  if cardinality(v_ids) > 500 then raise exception 'Maksimal 500 dokumen sekali proses'; end if;
  if p_arsip and length(v_alasan) < 3 then raise exception 'Alasan arsip wajib diisi'; end if;
  if p_arsip then
    update public.rc_kb_items set archived_at = now(), archived_by = auth.uid(), archive_reason = v_alasan
     where id = any(v_ids) and archived_at is null;
  else
    update public.rc_kb_items set archived_at = null, archived_by = null, archive_reason = null, updated_at = now(), updated_by = auth.uid()
     where id = any(v_ids) and archived_at is not null;
  end if;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Tidak ada dokumen yang dapat %', case when p_arsip then 'diarsip' else 'dipulihkan' end; end if;
  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), case when p_arsip then 'kb_arsip' else 'kb_pulihkan' end,
    jsonb_build_object('detail', case when p_arsip then 'Arsip Knowledge Base: ' else 'Pulihkan Knowledge Base: ' end || n || ' dokumen'
                                   || case when p_arsip then ' (' || v_alasan || ')' else '' end,
                       'jumlah', n, 'alasan', nullif(v_alasan, ''), 'itemIds', to_jsonb(v_ids)), 'kb', 'manage', 'manage');
  return jsonb_build_object('status', 'success', 'jumlah', n,
    'message', n || ' dokumen ' || case when p_arsip then 'diarsip.' else 'dipulihkan.' end);
end $f$;

-- Details / analytics: satu dokumen (p_id) atau seluruh dokumen aktif (p_id kosong).
create or replace function public.rc_kb_detail(p_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare v_ids uuid[]; v_res jsonb;
begin
  perform rc_private.require_tab('kb.manage');
  if p_id is null then
    v_ids := array(select id from public.rc_kb_items where archived_at is null);
  else
    if not exists(select 1 from public.rc_kb_items where id = p_id) then raise exception 'Dokumen tidak ditemukan'; end if;
    v_ids := array[p_id];
  end if;

  with pr as (select * from rc_private.kb_pasangan(v_ids)),
  it as (select * from public.rc_kb_items where id = any(v_ids)),
  -- Depot tiap pasangan: depot jangkauan akun yang masuk wilayah dokumen (seluruh depotnya bila
  -- dokumen untuk semua wilayah). Akun tanpa depot yang cocok - dan System Manager, yang
  -- jangkauannya seluruh depot - satu baris "Tanpa depot", supaya angka depot tidak menggembung.
  pd as (
    select pr.item_id, pr.user_id, pr.sudah, pr.dibuka,
           coalesce(d.depot_code, '-') kode, coalesce(nullif(d.depot_name, ''), d.depot_code, 'Tanpa depot') nama,
           coalesce(nullif(upper(btrim(d.region)), ''), '-') region
      from pr join it on it.id = pr.item_id
      join public.profiles pp on pp.id = pr.user_id
      left join lateral (
        select dd.* from public.user_depot_access a join public.depots dd on dd.id = a.depot_id
         where a.user_id = pr.user_id and dd.archived_at is null and pp.role <> 'system manager'
           and ((coalesce(cardinality(it.regions), 0) = 0 and coalesce(cardinality(it.depot_ids), 0) = 0)
                or dd.id = any(it.depot_ids) or upper(btrim(coalesce(dd.region, ''))) = any(it.regions))) d on true
  ),
  ak as (
    select pr.*, p.user_code, coalesce(nullif(p.full_name, ''), p.user_code) nama, p.role,
           (select string_agg(distinct x.kode, ', ') from pd x where x.item_id = pr.item_id and x.user_id = pr.user_id and x.kode <> '-') depot,
           (select string_agg(distinct x.region, ', ') from pd x where x.item_id = pr.item_id and x.user_id = pr.user_id and x.region <> '-') region,
           it.jenis, it.judul
      from pr join public.profiles p on p.id = pr.user_id join it on it.id = pr.item_id
  )
  select jsonb_build_object('status', 'success',
    'item', (select jsonb_build_object('id', it.id, 'jenis', it.jenis, 'judul', it.judul, 'url', it.url, 'versi', it.versi,
               'pesertaTeks', (select string_agg(rc_private.kb_peran_label(r), ', ' order by o)
                                 from unnest(rc_private.kb_peran_semua()) with ordinality z(r, o) where r = any(it.peserta)),
               'wilayah', rc_private.kb_wilayah_teks(it.regions, it.depot_ids),
               'arsip', it.archived_at is not null, 'dibuat', to_char(it.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY'))
               from it where p_id is not null),
    'ringkas', jsonb_build_object('dokumen', cardinality(v_ids), 'target', (select count(*) from pr),
               'akun', (select count(distinct user_id) from pr),
               'sudah', (select count(*) from pr where sudah),
               'dibukaBelum', (select count(*) from pr where dibuka and not sudah),
               'belumDibuka', (select count(*) from pr where not dibuka)),
    'region', coalesce((select jsonb_agg(jsonb_build_object('region', z.region, 'target', z.t, 'sudah', z.s, 'dibukaBelum', z.b,
                 'belumDibuka', z.t - z.s - z.b) order by z.region = '-', z.region)
               from (select region, count(distinct (item_id, user_id)) t,
                            count(distinct (item_id, user_id)) filter (where sudah) s,
                            count(distinct (item_id, user_id)) filter (where dibuka and not sudah) b
                       from pd group by region) z), '[]'::jsonb),
    'depot', coalesce((select jsonb_agg(jsonb_build_object('kode', z.kode, 'nama', z.nama, 'region', z.region, 'target', z.t,
                 'sudah', z.s, 'dibukaBelum', z.b, 'belumDibuka', z.t - z.s - z.b, 'akun', z.a) order by z.kode = '-', z.region, z.kode)
               from (select kode, max(nama) nama, max(region) region, count(*) t, count(*) filter (where sudah) s,
                            count(*) filter (where dibuka and not sudah) b, count(distinct user_id) a
                       from pd group by kode) z), '[]'::jsonb),
    'perItem', case when p_id is null then coalesce((select jsonb_agg(jsonb_build_object('id', it.id, 'jenis', it.jenis, 'judul', it.judul,
                 'target', coalesce(s.t, 0), 'sudah', coalesce(s.s, 0), 'dibukaBelum', coalesce(s.b, 0)) order by it.created_at desc)
               from it left join (select item_id, count(*) t, count(*) filter (where sudah) s, count(*) filter (where dibuka and not sudah) b
                                    from pr group by item_id) s on s.item_id = it.id), '[]'::jsonb) end,
    'akun', coalesce((select jsonb_agg(jsonb_build_object('userCode', a.user_code, 'nama', a.nama, 'peran', rc_private.kb_peran_label(a.role),
                 'depot', coalesce(a.depot, '-'), 'region', coalesce(a.region, '-'), 'jenis', a.jenis, 'judul', a.judul,
                 'status', case when a.sudah then 'Acknowledged' when a.dibuka then 'Dibuka, belum acknowledge' else 'Belum dibuka' end,
                 'dibukaPada', coalesce(to_char(a.buka_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), ''),
                 'ackPada', coalesce(to_char(a.ack_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'), ''))
                 order by a.sudah, a.dibuka, a.region nulls last, a.depot nulls last, a.user_code, a.judul)
               from (select * from ak order by sudah, dibuka, user_code limit 20000) a), '[]'::jsonb),
    'akunTerpotong', (select count(*) from pr) > 20000)
  into v_res;
  return v_res;
end $f$;

revoke all on function public.rc_kb_list(), public.rc_kb_belum(), public.rc_kb_buka(uuid), public.rc_kb_ack(uuid, integer),
  public.rc_kb_kelola_list(boolean), public.rc_kb_simpan(jsonb), public.rc_kb_arsip(uuid[], boolean, text),
  public.rc_kb_detail(uuid) from public, anon;
grant execute on function public.rc_kb_list(), public.rc_kb_belum(), public.rc_kb_buka(uuid), public.rc_kb_ack(uuid, integer),
  public.rc_kb_kelola_list(boolean), public.rc_kb_simpan(jsonb), public.rc_kb_arsip(uuid[], boolean, text),
  public.rc_kb_detail(uuid) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 5. Katalog tab dan tambalan tab_rights
-- ------------------------------------------------------------------------------------------
insert into rc_private.tab_catalog(code, module, tab, permission, title, label, key)
select x.code, 'kb', x.tab, null, x.title, 'Knowledge Base', 'kb'
  from (values ('kb.resources', 'resources', 'Knowledge Resources'), ('kb.manage', 'manage', 'Knowledge Management')) x(code, tab, title)
 where not exists(select 1 from rc_private.tab_catalog c where c.code = x.code);

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.tab_rights(uuid,text)'::regprocedure), E'\r', '');
  if src ~ 'kb\.manage' then raise notice 'tab_rights sudah ditambal.';
  else
    -- Knowledge Management hanya bila dicentang; Knowledge Resources bawaannya terbuka.
    src := pg_temp.ganti(src, $p$or t.code='access.approval' /* 20261162180000: hanya bila dicentang */$p$,
      $p$or t.code='access.approval' /* 20261162180000: hanya bila dicentang */ or t.code='kb.manage' /* 20261163920000: Knowledge Management hanya bila dicentang */$p$,
      1, 'tab_rights kb.manage');
    execute src;
  end if;
end $tambal$;

-- ------------------------------------------------------------------------------------------
-- 6. Pemeriksaan diri
-- ------------------------------------------------------------------------------------------
do $cek$
declare e text := '';
begin
  if pg_get_functiondef('rc_private.tab_rights(uuid,text)'::regprocedure) !~ 'kb\.manage' then e := e || ' tab_rights;'; end if;
  if (select count(*) from rc_private.tab_catalog where code in ('kb.resources', 'kb.manage') and permission is null) <> 2 then
    e := e || ' katalog tab;'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.rc_kb_items'::regclass)
     or not (select relrowsecurity from pg_class where oid = 'public.rc_kb_baca'::regclass) then e := e || ' RLS;'; end if;
  if has_table_privilege('authenticated', 'public.rc_kb_items', 'select') or has_table_privilege('authenticated', 'public.rc_kb_baca', 'select') then
    e := e || ' hak tabel;'; end if;
  if rc_private.kb_pernyataan('SOP') !~ '^Saya sudah membaca dan memahami isi dari SOP tersebut' then e := e || ' pernyataan;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
