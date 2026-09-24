-- ==========================================================================================
-- Depot Master di Key Master, lengkap dengan alamat email tujuan
-- ==========================================================================================
-- Email otomatis harus tahu ke mana dikirim. Pada sistem lama alamat itu berada di sheet Email
-- dengan pemetaan kode depot di kolom B dan alamat di kolom L, M, N - terpisah dari master
-- depotnya sendiri, sehingga menambah depot dan menambah penerimanya adalah dua pekerjaan di
-- dua tempat yang mudah tidak sinkron.
--
-- Di RC keduanya disatukan: alamat TO dan CC menjadi kolom pada master depot, dan Key Master
-- memperoleh sub-modul Depot Master dengan tampilan, penyuntingan, dan unggah massal - sama
-- seperti Customer Master dan Campaign Master.
--
-- SATU SEL BOLEH MEMUAT BEBERAPA ALAMAT, dipisah koma atau titik koma, persis seperti perilaku
-- sistem lama. Pembersihannya dilakukan di server, bukan di layar: alamat kosong dibuang,
-- duplikat dihapus tanpa membedakan kapitalisasi, dan alamat yang sudah ada di TO tidak
-- diulang di CC. Dengan begitu aturan yang sama berlaku untuk unggahan massal maupun ketikan
-- manual.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

alter table public.depots add column if not exists email_to text;
alter table public.depots add column if not exists email_cc text;
alter table public.depots add column if not exists head_depot text;
alter table public.depots add column if not exists kepala_admin text;
alter table public.depots add column if not exists updated_at timestamptz;
alter table public.depots add column if not exists updated_by uuid references public.profiles(id);

comment on column public.depots.email_to is
  'Penerima utama email otomatis untuk depot ini. Boleh beberapa alamat dipisah koma atau titik koma.';

-- ------------------------------------------------------------------------------------------
-- Membersihkan dan memecah daftar alamat
-- ------------------------------------------------------------------------------------------
-- Dipakai oleh penyusun email maupun pemeriksa masukan, supaya keduanya tidak bisa menyimpang.
create or replace function rc_private.pecah_email(p text)
returns text[] language sql immutable set search_path='' as $fn$
  select coalesce(array_agg(distinct lower(btrim(x))) filter (
           where btrim(x) <> '' and btrim(x) ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
         '{}'::text[])
    from unnest(string_to_array(regexp_replace(coalesce(p,''), '[;\n\r]', ',', 'g'), ',')) as x;
$fn$;
revoke all on function rc_private.pecah_email(text) from public,anon;
grant execute on function rc_private.pecah_email(text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Daftar depot untuk Key Master
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_depot_list(
  p_search text default null, p_offset integer default 0, p_limit integer default 50)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare v_search text; v_limit integer; v_offset integer;
begin
  if not rc_private.can_access(null,'manage_key_master') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak membuka Key Master' using errcode='42501'; end if;
  v_search := nullif(btrim(coalesce(p_search,'')),'');
  v_limit  := least(greatest(coalesce(p_limit,50),1),500);
  v_offset := greatest(coalesce(p_offset,0),0);

  return (select jsonb_build_object('status','success',
    'total',(select count(*) from public.depots d
       where v_search is null
          or d.depot_code ilike '%'||v_search||'%'
          or d.depot_name ilike '%'||v_search||'%'
          or coalesce(d.region,'') ilike '%'||v_search||'%'),
    'rows',coalesce((select jsonb_agg(jsonb_build_object(
        'kode',t.depot_code,'nama',t.depot_name,'abbr',coalesce(t.abbr,''),
        'region',coalesce(t.region,''),'alamat',coalesce(t.address,''),
        'headDepot',coalesce(t.head_depot,''),'kepalaAdmin',coalesce(t.kepala_admin,''),
        'emailTo',coalesce(t.email_to,''),'emailCc',coalesce(t.email_cc,''),
        -- Jumlah alamat yang benar-benar sah ditampilkan supaya salah ketik terlihat sebelum
        -- email pertama gagal terkirim, bukan sesudahnya.
        'jumlahTo',coalesce(array_length(rc_private.pecah_email(t.email_to),1),0),
        'jumlahCc',coalesce(array_length(rc_private.pecah_email(t.email_cc),1),0))
        order by t.depot_code)
      from (select * from public.depots d
             where v_search is null
                or d.depot_code ilike '%'||v_search||'%'
                or d.depot_name ilike '%'||v_search||'%'
                or coalesce(d.region,'') ilike '%'||v_search||'%'
             order by d.depot_code offset v_offset limit v_limit) t),'[]'::jsonb)));
end $fn$;
revoke all on function public.rc_depot_list(text,integer,integer) from public,anon;
grant execute on function public.rc_depot_list(text,integer,integer) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Menyimpan, satu baris maupun massal
-- ------------------------------------------------------------------------------------------
-- Kode depot adalah kuncinya dan tidak pernah diubah dari sini; baris dengan kode yang belum
-- ada akan dibuat. Kolom yang tidak dikirim dibiarkan seperti semula, sehingga mengunggah
-- berkas yang hanya memuat kolom email tidak menghapus region maupun alamat.
create or replace function public.rc_depot_upsert(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare r jsonb; v_kode text; n_baru integer := 0; n_ubah integer := 0; salah text[] := '{}';
  v_to text; v_cc text;
begin
  if not rc_private.can_access(null,'manage_key_master') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak mengubah Key Master' using errcode='42501'; end if;
  if jsonb_typeof(p_rows)<>'array' then raise exception 'Data harus berupa daftar baris'; end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'Maksimal 500 baris sekali unggah'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_kode := upper(btrim(coalesce(r->>'kode','')));
    if v_kode = '' then salah := salah || 'baris tanpa kode depot'; continue; end if;

    -- Alamat diperiksa di sini supaya kesalahan ketik tertangkap saat unggah, bukan saat
    -- email pertama gagal terkirim berhari-hari kemudian.
    v_to := btrim(coalesce(r->>'emailTo',''));
    v_cc := btrim(coalesce(r->>'emailCc',''));
    if v_to <> '' and coalesce(array_length(rc_private.pecah_email(v_to),1),0) = 0 then
      salah := salah || (v_kode||': alamat TO tidak sah'); continue; end if;
    if v_cc <> '' and coalesce(array_length(rc_private.pecah_email(v_cc),1),0) = 0 then
      salah := salah || (v_kode||': alamat CC tidak sah'); continue; end if;

    if exists(select 1 from public.depots where depot_code=v_kode) then
      update public.depots set
        depot_name   = coalesce(nullif(btrim(coalesce(r->>'nama','')),''), depot_name),
        abbr         = case when r ? 'abbr'   then nullif(upper(btrim(coalesce(r->>'abbr',''))),'') else abbr end,
        region       = case when r ? 'region' then nullif(btrim(coalesce(r->>'region','')),'') else region end,
        address      = case when r ? 'alamat' then nullif(btrim(coalesce(r->>'alamat','')),'') else address end,
        head_depot   = case when r ? 'headDepot'   then nullif(btrim(coalesce(r->>'headDepot','')),'') else head_depot end,
        kepala_admin = case when r ? 'kepalaAdmin' then nullif(btrim(coalesce(r->>'kepalaAdmin','')),'') else kepala_admin end,
        email_to     = case when r ? 'emailTo' then nullif(v_to,'') else email_to end,
        email_cc     = case when r ? 'emailCc' then nullif(v_cc,'') else email_cc end,
        updated_at   = now(), updated_by = (select auth.uid())
      where depot_code = v_kode;
      n_ubah := n_ubah + 1;
    else
      if coalesce(btrim(r->>'nama'),'') = '' then
        salah := salah || (v_kode||': depot baru wajib punya nama'); continue; end if;
      insert into public.depots(depot_code,depot_name,abbr,region,address,head_depot,
        kepala_admin,email_to,email_cc,updated_at,updated_by)
      values(v_kode, btrim(r->>'nama'), nullif(upper(btrim(coalesce(r->>'abbr',''))),''),
        nullif(btrim(coalesce(r->>'region','')),''), nullif(btrim(coalesce(r->>'alamat','')),''),
        nullif(btrim(coalesce(r->>'headDepot','')),''), nullif(btrim(coalesce(r->>'kepalaAdmin','')),''),
        nullif(v_to,''), nullif(v_cc,''), now(), (select auth.uid()));
      n_baru := n_baru + 1;
    end if;
  end loop;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'depot_master_updated',null,
    jsonb_build_object('baru',n_baru,'ubah',n_ubah,'ditolak',coalesce(array_length(salah,1),0)));

  return jsonb_build_object('status','success','baru',n_baru,'diperbarui',n_ubah,
    'ditolak',coalesce(array_length(salah,1),0),
    'pesanDitolak',to_jsonb(salah),
    'message',n_baru||' depot baru, '||n_ubah||' diperbarui'
      ||case when coalesce(array_length(salah,1),0)>0
             then ', '||array_length(salah,1)||' ditolak' else '' end);
end $fn$;
revoke all on function public.rc_depot_upsert(jsonb) from public,anon;
grant execute on function public.rc_depot_upsert(jsonb) to authenticated;

create or replace function rc_private.marker_20261014() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261014() from public,anon;
grant execute on function rc_private.marker_20261014() to authenticated;

select 'Depot Master dan email tujuan terpasang' as hasil,
 (select count(*) from public.depots) as depot,
 (select count(*) from public.depots where coalesce(btrim(email_to),'')<>'') as depot_ber_email,
 (select count(*) from public.depots where coalesce(btrim(region),'')<>'') as depot_ber_region,
 array_to_string(rc_private.pecah_email('a@b.com; A@B.COM , salah , c@d.co.id'),', ') as uji_pemecah;
