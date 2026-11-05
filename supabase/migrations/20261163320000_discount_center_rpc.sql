-- ==========================================================================================
-- Discount Center: fungsi (pembantu, mesin hitung, unggah, generate, kartu, dashboard,
-- acknowledge, monitoring). Bergantung pada 20261163310000.
-- ==========================================================================================
-- Rumus (spesifikasi bagian 4): Amount = (1 - prod(1 - d/100)) x 100, 3 desimal. Komponen digabung
-- bertingkat, bukan dijumlah. FAKTUR tidak pernah dihitung. Satu sumber untuk Generate dan
-- kartu dashboard, sehingga angka di dashboard selalu sama dengan yang dipantek.
-- Semua RPC public.rc_disc_* memeriksa tab sendiri; data wilayah disaring di server.
-- ==========================================================================================

-- ---- 1. Pembantu ---------------------------------------------------------------------------
create or replace function disc.stack(p numeric[]) returns numeric
language plpgsql immutable set search_path = '' as $f$
declare v numeric := 1; x numeric;
begin
  foreach x in array coalesce(p, '{}'::numeric[]) loop
    if x is not null and x > 0 then v := v * (1 - x / 100); end if;
  end loop;
  return round((1 - v) * 100, 3);
end $f$;

-- Tanggal teks dd.mm.yyyy (persis seperti template); selain itu null.
create or replace function disc.tgl(p text) returns date
language plpgsql immutable set search_path = '' as $f$
declare s text := btrim(coalesce(p, ''));
begin
  if s !~ '^\d{2}\.\d{2}\.\d{4}$' then return null; end if;
  begin
    return make_date(substr(s, 7, 4)::int, substr(s, 4, 2)::int, substr(s, 1, 2)::int);
  exception when others then return null;
  end;
end $f$;

create or replace function disc.tgl_teks(p date) returns text
language sql immutable set search_path = '' as $f$ select to_char(p, 'DD.MM.YYYY') $f$;

-- Angka dari teks Excel ("12", "12,5", "12.5"); selain itu null.
create or replace function disc.angka(p text) returns numeric
language plpgsql immutable set search_path = '' as $f$
declare s text := replace(btrim(coalesce(p, '')), ',', '.');
begin
  if s !~ '^-?\d+(\.\d+)?$' then return null; end if;
  return s::numeric;
end $f$;

create or replace function disc.kode(p text) returns text
language sql immutable set search_path = '' as $f$ select nullif(upper(btrim(coalesce(p, ''))), '') $f$;

-- Sales Distribution ikut tab (keputusan pemilik): System Manager, atau pemegang salah satu tab
-- Monitoring / Kebijakan / Generate / Terbitkan.
create or replace function disc.sd_user(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $f$
  select coalesce((select p.role = 'system manager' from public.profiles p where p.id = p_user), false)
      or coalesce((select bool_or(coalesce((r.hak ->> t)::boolean, false))
                     from (select rc_private.tab_rights(p_user) hak) r,
                          unnest(array['discount.monitor','discount.kebijakan','discount.generate','discount.terbit']) t), false);
$f$;
create or replace function disc.sd_saya() returns boolean
language sql stable security definer set search_path = '' as $f$
  select coalesce((select p.role = 'system manager' from public.profiles p where p.id = auth.uid()), false)
      or rc_private.can_tab('discount.monitor') or rc_private.can_tab('discount.kebijakan')
      or rc_private.can_tab('discount.generate') or rc_private.can_tab('discount.terbit');
$f$;

-- Token wilayah seorang user: NASIONAL, kode depot jangkauannya (user_depot_access, termasuk
-- tagging Resource Partner), dan "REGION <kode>" depot-depot itu. Kantor (bukan_depot) tidak.
create or replace function disc.wilayah_user(p_user uuid) returns text[]
language sql stable security definer set search_path = '' as $f$
  select array(select distinct w from (
    select 'NASIONAL' w
    union all
    select upper(d.depot_code) from public.user_depot_access a join public.depots d on d.id = a.depot_id
     where a.user_id = p_user and d.archived_at is null and not d.bukan_depot
    union all
    select 'REGION ' || upper(btrim(d.region)) from public.user_depot_access a join public.depots d on d.id = a.depot_id
     where a.user_id = p_user and d.archived_at is null and not d.bukan_depot and btrim(coalesce(d.region, '')) <> ''
  ) x order by 1);
$f$;

-- Isian WILAYAH / Tampil di: NASIONAL, "REGION <kode region>", atau kode depot; dipisah koma.
-- Mengembalikan token baku; token tidak dikenal dikembalikan dengan awalan "?".
create or replace function disc.token_wilayah(p text) returns text[]
language sql stable security definer set search_path = '' as $f$
  select coalesce(array_agg(distinct case
      when t in ('', 'NASIONAL') then 'NASIONAL'
      when t like 'REGION %' and exists(select 1 from public.depots d where d.archived_at is null
                                          and upper(btrim(d.region)) = btrim(substr(t, 8))) then 'REGION ' || btrim(substr(t, 8))
      when exists(select 1 from public.depots d where d.archived_at is null and not d.bukan_depot and upper(d.depot_code) = t) then t
      else '?' || t end), array['NASIONAL'])
    from (select upper(btrim(x)) t from regexp_split_to_table(coalesce(p, ''), ',') x) y
   where t <> '' or coalesce(btrim(p), '') = '';
$f$;

-- Label kunci kombinasi untuk layar (key combination), dari kode level.
create or replace function disc.label_level(p_level text) returns text
language sql immutable set search_path = '' as $f$
  select case p_level
    when 'CUST_MG' then 'Cust / MG' when 'CUST_MAT' then 'Cust / Mat' when 'CUST_MG_MG2_MG1' then 'Cust / MG / MG2 / MG1'
    when 'SLSOFF_CG_MG' then 'Sls Off / CG / MG' when 'SLSOFF_CG_MAT' then 'Sls Off / CG / Mat'
    when 'SLSOFF_CG_MG_MG1' then 'Sls Off / CG / MG / MG1' when 'SLSOFF_CG_MG_MG2_MG1' then 'Sls Off / CG / MG / MG2 / MG1'
    when 'SLSORG_CG_MG' then 'Sls Org / CG / MG' when 'SLSORG_CG_MAT' then 'Sls Org / CG / Mat'
    when 'SLSORG_CG_MG_MG1' then 'Sls Org / CG / MG / MG1' when 'SLSORG_CG_MG_MG2_MG1' then 'Sls Org / CG / MG / MG2 / MG1'
    when 'CG2_CG_MG_MG3_MG2_MG1' then 'Cond Group 2 / CG / MG / MG2 / MG1 / MG3' else coalesce(p_level, '-') end;
$f$;

create or replace function disc.label_jenis(p text) returns text
language sql immutable set search_path = '' as $f$
  select case p when 'VOL' then 'Vol' when 'CMP' then 'CMP' when 'BULK' then 'Bulk' when 'BP' then 'BP'
                when 'PROMO' then 'Promo' when 'LAIN' then 'Lain' when 'FAKTUR' then 'Faktur' else p end;
$f$;

create or replace function disc.pct(p numeric) returns text
language sql immutable set search_path = '' as $f$ select rtrim(rtrim(to_char(p, 'FM9990.999'), '0'), '.') $f$;

-- ---- 2. Mesin hitung -------------------------------------------------------------------------
-- p_baris: larik {jenis, qty, uom, disc, dari, sampai}. Pemanggil sudah membuang komponen yang
-- tidak ikut (FAKTUR, BP pada OPEN_QTY, BULK pada OPEN_QTY_TANPA_BULK, TANPA_KOMPONEN).
-- Hasil: larik tier {scale, uom, komponen[], amount}.
--  OPEN_QTY : satu tier; per jenis tier tertinggi (scale terbesar) + baris tanpa scale.
--  PER_SCALE: titik scale = gabungan scale semua komponen ber-scale; di tiap titik per jenis
--             tier tertinggi <= titik + seluruh baris tanpa scale. Tanpa titik = satu tier.
--  FLAT     : satu tier per baris, disc apa adanya.
create or replace function disc.gabung(p_baris jsonb, p_mode text) returns jsonb
language plpgsql immutable set search_path = '' as $f$
declare
  v_out jsonb := '[]'; v_komp jsonb; v_titik numeric[]; t numeric; j text; r jsonb; v_uom text; v_x jsonb;
begin
  if coalesce(jsonb_array_length(p_baris), 0) = 0 then return '[]'; end if;
  if p_mode = 'FLAT' then
    for v_x in select value from jsonb_array_elements(p_baris) loop
      v_out := v_out || jsonb_build_array(jsonb_build_object('scale', v_x->'qty', 'uom', v_x->'uom', 'komponen', jsonb_build_array(v_x),
        'amount', disc.stack(array[(v_x->>'disc')::numeric])));
    end loop;
    return v_out;
  end if;

  if p_mode = 'PER_SCALE' then
    v_titik := array(select distinct (x->>'qty')::numeric from jsonb_array_elements(p_baris) x
                      where nullif(x->>'qty', '') is not null order by 1);
  end if;
  if p_mode = 'OPEN_QTY' or cardinality(coalesce(v_titik, '{}')) = 0 then
    v_titik := array[null::numeric];
  end if;

  foreach t in array v_titik loop
    v_komp := '[]';
    for j in select distinct x->>'jenis' from jsonb_array_elements(p_baris) x order by 1 loop
      r := null;
      if t is null then
        select x into r from jsonb_array_elements(p_baris) x
         where x->>'jenis' = j and nullif(x->>'qty', '') is not null
         order by (x->>'qty')::numeric desc, (x->>'disc')::numeric desc limit 1;
      else
        select x into r from jsonb_array_elements(p_baris) x
         where x->>'jenis' = j and nullif(x->>'qty', '') is not null and (x->>'qty')::numeric <= t
         order by (x->>'qty')::numeric desc, (x->>'disc')::numeric desc limit 1;
      end if;
      if r is not null then v_komp := v_komp || jsonb_build_array(r); end if;
      v_komp := v_komp || coalesce((select jsonb_agg(x) from jsonb_array_elements(p_baris) x
                                     where x->>'jenis' = j and nullif(x->>'qty', '') is null), '[]');
    end loop;
    if jsonb_array_length(v_komp) = 0 then continue; end if;
    v_uom := (select x->>'uom' from jsonb_array_elements(v_komp) x where nullif(x->>'qty', '') is not null
               order by (x->>'qty')::numeric desc limit 1);
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'scale', case when p_mode = 'PER_SCALE' then to_jsonb(t) else 'null'::jsonb end,
      'uom', case when p_mode = 'PER_SCALE' and t is not null then to_jsonb(v_uom) else 'null'::jsonb end,
      'komponen', v_komp,
      'amount', disc.stack(array(select (x->>'disc')::numeric from jsonb_array_elements(v_komp) x))));
  end loop;
  return v_out;
end $f$;

-- Rincian komponen untuk Remark 1 / layar: "Vol 10% + CMP 5% + Bulk 5%".
create or replace function disc.rincian(p_komponen jsonb) returns text
language sql immutable set search_path = '' as $f$
  select string_agg(disc.label_jenis(x->>'jenis') || ' ' || disc.pct((x->>'disc')::numeric) || '%', ' + '
                    order by array_position(array['VOL','CMP','BULK','BP','PROMO','LAIN'], x->>'jenis'), (x->>'disc')::numeric desc)
    from jsonb_array_elements(coalesce(p_komponen, '[]')) x;
$f$;

create or replace function disc.disc_type(p_komponen jsonb) returns text
language sql immutable set search_path = '' as $f$
  select string_agg(l, ' + ' order by u) from (
    select distinct on (x->>'jenis') array_position(array['VOL','CMP','BULK','BP','PROMO','LAIN'], x->>'jenis') u,
           case x->>'jenis' when 'VOL' then 'Disc Vol' when 'CMP' then 'Disc CMP' when 'BULK' then 'Disc Bulk'
                            when 'BP' then 'Disc BP' when 'PROMO' then 'Promo' else 'Disc Lain' end l
      from jsonb_array_elements(coalesce(p_komponen, '[]')) x order by x->>'jenis') y;
$f$;

revoke all on all functions in schema disc from public, anon, authenticated;
