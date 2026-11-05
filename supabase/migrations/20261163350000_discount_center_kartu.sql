-- ==========================================================================================
-- Discount Center: kartu disc (draft, terbit, revisi, tarik, wilayah tampil), dashboard,
-- acknowledge, monitoring (spesifikasi bagian 7-9). Bergantung pada 20261163310000-340000.
-- ==========================================================================================
-- Satu kartu = satu produk (MG, MG + kemasan, atau material) x periode x UNTUK_TARGET. Grup target
-- yang anggotanya beda ATURAN_DISC (Toko Khusus open qty vs Gavindo tanpa bulk) dipecah per aturan.
--  * UNTUK_TARGET kosong: mode PER_SCALE seperti memo (satu baris per titik scale).
--  * Target / grup OPEN_QTY: satu tier "Open Qty", BP tidak ikut, OPEN_QTY_TANPA_BULK tanpa Bulk.
--  * Total memakai disc.gabung yang sama dengan Generate. FAKTUR hanya tampil, tidak dihitung.
--  * Tampil di: dari WILAYAH baris; bila NASIONAL dan kartu khusus target, DC target-targetnya.
--    PENGECUALIAN KHUSUS_WILAYAH menggantikannya. Bisa diubah per kartu / massal sebelum terbit.
--  * Terbit menaikkan versi bila isi berubah (acknowledge versi lama tidak berlaku lagi). Perubahan
--    wilayah tampil / condition type saja tidak menaikkan versi.
--  * Kartu yang hilang dari kebijakan: draft yang belum pernah terbit dihapus; kartu terbit ditandai
--    USANG (keputusan tarik tetap di Sales Distribution). Catatan acknowledge tidak pernah dihapus.
-- ==========================================================================================

-- Teks jenis disc untuk Remark kartu: "Disc volume + campaign + bulk".
create or replace function disc.jenis_teks(p text[]) returns text
language sql immutable set search_path = '' as $f$
  select upper(left(s, 1)) || substr(s, 2) from (
    select string_agg(case j when 'VOL' then 'disc volume' when 'CMP' then 'campaign' when 'BULK' then 'bulk'
                             when 'BP' then 'disc BP' when 'PROMO' then 'promo' else 'disc lain' end, ' + '
                      order by array_position(array['VOL','CMP','BULK','BP','PROMO','LAIN'], j)) s
      from (select distinct j from unnest(p) j) y) z;
$f$;

-- Satu tier hasil disc.gabung -> baris kartu {syarat, vol, cmp, bulk, lain[], total}.
create or replace function disc.tier_kartu(p jsonb, p_mode text) returns jsonb
language plpgsql immutable set search_path = '' as $f$
declare v_vol numeric; v_cmp numeric; v_bulk numeric; v_lain jsonb := '[]'; x jsonb;
begin
  for x in select value from jsonb_array_elements(coalesce(p->'komponen', '[]'))
            order by array_position(array['VOL','CMP','BULK','BP','PROMO','LAIN'], value->>'jenis'), (value->>'disc')::numeric desc loop
    if x->>'jenis' = 'VOL' and v_vol is null then v_vol := (x->>'disc')::numeric;
    elsif x->>'jenis' = 'CMP' and v_cmp is null then v_cmp := (x->>'disc')::numeric;
    elsif x->>'jenis' = 'BULK' and v_bulk is null then v_bulk := (x->>'disc')::numeric;
    else v_lain := v_lain || jsonb_build_array(jsonb_build_object('jenis', disc.label_jenis(x->>'jenis'), 'd', (x->>'disc')::numeric));
    end if;
  end loop;
  return jsonb_build_object(
    'syarat', case when p_mode = 'OPEN_QTY' then 'Open Qty'
                   when (p->>'scale') is not null then disc.pct((p->>'scale')::numeric) || coalesce(' ' || (p->>'uom'), '')
                   else 'Tanpa minimum' end,
    'scale', p->'scale', 'uom', p->'uom', 'vol', v_vol, 'cmp', v_cmp, 'bulk', v_bulk, 'lain', v_lain,
    'total', trim_scale((p->>'amount')::numeric), 'ubah', '[]'::jsonb);
end $f$;

-- Tandai komponen yang berbeda dari tier lama dengan syarat sama (angka merah di layar).
-- p_semua_baru = true: tier tanpa pasangan dianggap berubah seluruhnya.
create or replace function disc.tandai_ubah(p_baru jsonb, p_lama jsonb) returns jsonb
language sql immutable set search_path = '' as $f$
  select coalesce(jsonb_agg(n || jsonb_build_object('ubah', coalesce((
      select jsonb_agg(k) from unnest(array['vol','cmp','bulk','lain']) k
       where case when o is null then (k = 'lain' and jsonb_array_length(coalesce(n->'lain', '[]')) > 0) or (k <> 'lain' and n->>k is not null)
                  else (n->k) is distinct from (o->k) end), '[]'::jsonb)) order by i), '[]')
    from jsonb_array_elements(coalesce(p_baru, '[]')) with ordinality q(n, i)
    left join lateral (select x o from jsonb_array_elements(coalesce(p_lama, '[]')) x
                        where x->>'syarat' = n->>'syarat' and coalesce(x->>'dari', '') = coalesce(n->>'dari', '') limit 1) l on true;
$f$;

-- Bentuk konten kartu yang terbit (sama dengan bentuk draft).
create or replace function disc.kartu_publik(k disc.kartu) returns jsonb
language sql stable set search_path = '' as $f$
  select jsonb_build_object('nama_produk', k.nama_produk, 'segmen', k.segmen, 'jenis_produk', k.jenis_produk,
    'untuk_label', k.untuk_label, 'remark', k.remark, 'no_memo', k.no_memo, 'catatan', k.catatan,
    'berlaku_dari', k.berlaku_dari, 'berlaku_sampai', k.berlaku_sampai, 'isi', k.isi, 'tampil_di', to_jsonb(k.tampil_di),
    'tampil_default', coalesce(k.isi->'tampilDefault', to_jsonb(k.tampil_di)),
    'condition_type', k.condition_type, 'key_combination', k.key_combination);
$f$;

-- Bagian yang menentukan versi (yang dibaca admin). Wilayah tampil dan CT tidak termasuk.
create or replace function disc.konten(d jsonb) returns jsonb
language sql immutable set search_path = '' as $f$
  select jsonb_build_object('nama_produk', d->'nama_produk', 'segmen', d->'segmen', 'jenis_produk', d->'jenis_produk',
    'untuk_label', d->'untuk_label', 'remark', d->'remark', 'no_memo', d->'no_memo', 'catatan', d->'catatan',
    'berlaku_dari', d->'berlaku_dari', 'berlaku_sampai', d->'berlaku_sampai',
    'isi', coalesce(d->'isi', '{}'::jsonb) - 'revisi' - 'revisiUbah' - 'tampilDefault');
$f$;

-- ---- Hitung semua kartu satu periode dari KEBIJAKAN -----------------------------------------
create or replace function disc.kartu_hitung(p_periode text) returns jsonb
language plpgsql stable security definer set search_path = '' as $f$
declare
  u record; m disc.master_mg; mm disc.master_material; c record; it jsonb; au jsonb;
  v_out jsonb := '[]'; v_aud jsonb := '[]'; v_rows jsonb; v_r jsonb; v_mgrows jsonb; v_items jsonb; v_x jsonb;
  v_mg text; v_b date[]; v_i integer; v_d1 date; v_d2 date; v_aktif jsonb; v_tiers jsonb; v_hit jsonb; v_fakt jsonb;
  v_nseg integer; v_jenis text[]; v_remark text; v_tok text[]; v_tampil text[]; v_khusus text[]; v_ct text; v_key text;
  v_kem_ada boolean; v_kunci text; v_kemasan text; v_cat text; v_exc text;
begin
  -- Audiens kartu: semua customer, target tunggal, grup (dipecah per ATURAN_DISC bila campur).
  if exists(select 1 from disc.kebijakan k where k.periode = p_periode and k.diganti_pada is null and k.untuk_target is null) then
    v_aud := jsonb_build_array(jsonb_build_object('untuk', null, 'kunci', '*', 'mode', 'PER_SCALE', 'tanpaBulk', false,
      'label', 'semua customer', 'untukLabel', 'Semua customer', 'kecuali', null, 'dcs', '[]'::jsonb, 'ids', '[]'::jsonb));
  end if;
  for u in select distinct k.untuk_target v from disc.kebijakan k
            where k.periode = p_periode and k.diganti_pada is null and k.untuk_target is not null order by 1 loop
    if exists(select 1 from disc.target tg where tg.target_id = u.v) then
      v_aud := v_aud || (select jsonb_build_array(jsonb_build_object('untuk', u.v, 'kunci', u.v,
          'mode', case when tg.aturan_disc = 'NORMAL' then 'PER_SCALE' else 'OPEN_QTY' end,
          'tanpaBulk', tg.aturan_disc = 'OPEN_QTY_TANPA_BULK', 'label', tg.nama, 'untukLabel', tg.kode || ' ' || tg.nama,
          'kecuali', null, 'dcs', case when tg.dc is null then '[]'::jsonb else jsonb_build_array(upper(tg.dc)) end,
          'ids', jsonb_build_array(tg.target_id)))
        from disc.target tg where tg.target_id = u.v);
    elsif not exists(select 1 from disc.target tg where tg.grup = u.v and tg.aktif) then
      v_aud := v_aud || jsonb_build_array(jsonb_build_object('untuk', u.v, 'kunci', u.v, 'mode', 'PER_SCALE', 'tanpaBulk', false,
        'label', u.v, 'untukLabel', u.v, 'kecuali', null, 'dcs', '[]'::jsonb, 'ids', '[]'::jsonb));
    else
      v_aud := v_aud || (select jsonb_agg(jsonb_build_object('untuk', u.v,
          'kunci', case when z.nvar = 1 then u.v else u.v || ':' || z.atur end,
          'mode', case when z.atur = 'NORMAL' then 'PER_SCALE' else 'OPEN_QTY' end,
          'tanpaBulk', z.atur = 'OPEN_QTY_TANPA_BULK',
          'label', case when z.nvar > 1 and z.n = 1 then z.nama1 else coalesce(z.lbl, u.v) end,
          'untukLabel', case when z.nvar > 1 and z.n = 1 then z.kode1 || ' ' || z.nama1
                             else coalesce(z.lbl, u.v) || ' (' || z.n || ' toko)' end
                        || case when z.nvar > 1 and z.n > 1 then coalesce(', kecuali ' || z.kecuali, '') else '' end,
          'kecuali', case when z.nvar > 1 and z.n > 1 then z.kecuali end,
          'dcs', coalesce(z.dcs, '[]'::jsonb), 'ids', z.ids))
        from (select tg.aturan_disc atur, count(*) n, jsonb_agg(tg.target_id order by tg.target_id) ids,
                     jsonb_agg(distinct upper(tg.dc)) filter (where tg.dc is not null) dcs,
                     min(tg.nama) nama1, min(tg.kode) kode1,
                     (select max(t2.label_output) from disc.target t2 where t2.grup = u.v and t2.aktif) lbl,
                     count(*) over () nvar,
                     (select string_agg(t3.nama, ', ' order by t3.nama) from disc.target t3
                       where t3.grup = u.v and t3.aktif and t3.aturan_disc <> tg.aturan_disc) kecuali
                from disc.target tg where tg.grup = u.v and tg.aktif group by tg.aturan_disc) z);
    end if;
  end loop;

  for au in select value from jsonb_array_elements(v_aud) loop
    v_rows := (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'jenis', k.jenis, 'mg', k.mg, 'material', k.material,
                 'mg1', k.mg1, 'mg2', k.mg2, 'mg3', k.mg3, 'qty', k.scale_qty, 'uom', k.scale_uom, 'disc', k.disc,
                 'dari', k.valid_from, 'sampai', k.valid_to, 'memo', k.no_memo, 'catatan', k.catatan,
                 'wilayah', coalesce(nullif(k.wilayah, ''), 'NASIONAL')) order by k.id), '[]')
       from disc.kebijakan k
      where k.periode = p_periode and k.diganti_pada is null
        and case when au->>'untuk' is null then k.untuk_target is null else k.untuk_target = au->>'untuk' end
        and not (au->>'mode' = 'OPEN_QTY' and k.jenis = 'BP')
        and not ((au->>'tanpaBulk')::boolean and k.jenis = 'BULK')
        and not exists(select 1 from disc.pengecualian e where e.diganti_pada is null and e.jenis = 'TANPA_KOMPONEN'
                         and upper(e.nilai) = k.jenis and e.condition_type is null
                         and (e.periode is null or e.periode = p_periode)
                         and (e.target is null or e.target = au->>'untuk' or au->'ids' ? e.target)
                         and ((e.material is not null and e.material = k.material) or (e.material is null and e.mg = k.mg))));

    for v_mg in select distinct x->>'mg' from jsonb_array_elements(v_rows) x order by 1 loop
      select * into m from disc.master_mg where mg = v_mg;
      if not found then continue; end if;
      v_r := (select jsonb_agg(x) from jsonb_array_elements(v_rows) x where x->>'mg' = v_mg);
      v_mgrows := coalesce((select jsonb_agg(x) from jsonb_array_elements(v_r) x
                             where x->>'material' is null and x->>'mg1' is null and x->>'mg2' is null and x->>'mg3' is null), '[]');
      v_kem_ada := exists(select 1 from jsonb_array_elements(v_r) x where x->>'material' is null
                            and coalesce(x->>'mg1', x->>'mg2', x->>'mg3') is not null);
      v_items := '[]';
      if jsonb_array_length(v_mgrows) > 0 then
        v_items := jsonb_build_array(jsonb_build_object('kunci', 'MG:' || v_mg, 'desk', m.nama_produk,
          'kemasan', case when v_kem_ada then 'Kemasan lain' else 'Semua kemasan' end, 'rows', v_mgrows));
      end if;
      for c in select distinct x->>'mg1' mg1, x->>'mg2' mg2, x->>'mg3' mg3 from jsonb_array_elements(v_r) x
                where x->>'material' is null and coalesce(x->>'mg1', x->>'mg2', x->>'mg3') is not null order by 2, 1, 3 loop
        v_x := v_mgrows || (select jsonb_agg(x) from jsonb_array_elements(v_r) x
                 where x->>'material' is null and x->>'mg1' is not distinct from c.mg1 and x->>'mg2' is not distinct from c.mg2
                   and x->>'mg3' is not distinct from c.mg3);
        v_items := v_items || jsonb_build_array(jsonb_build_object('kunci', concat_ws('|', 'KEM:' || v_mg, coalesce(c.mg2, ''),
            coalesce(c.mg1, ''), coalesce(c.mg3, '')), 'mg1', c.mg1, 'mg2', c.mg2, 'mg3', c.mg3, 'desk', m.nama_produk,
          'kemasan', concat_ws(' · ', c.mg2, c.mg1, c.mg3), 'rows', v_x));
      end loop;
      for mm in select mt.* from disc.master_material mt
                 where mt.material in (select x->>'material' from jsonb_array_elements(v_r) x where x->>'material' is not null)
                 order by mt.material loop
        v_x := v_mgrows
          || coalesce((select jsonb_agg(x) from jsonb_array_elements(v_r) x
               where x->>'material' is null and coalesce(x->>'mg1', x->>'mg2', x->>'mg3') is not null
                 and (x->>'mg1' is null or x->>'mg1' = mm.mg1) and (x->>'mg2' is null or x->>'mg2' = mm.mg2)
                 and (x->>'mg3' is null or x->>'mg3' = mm.mg3)), '[]')
          || (select jsonb_agg(x) from jsonb_array_elements(v_r) x where x->>'material' = mm.material);
        v_items := v_items || jsonb_build_array(jsonb_build_object('kunci', 'MAT:' || mm.material, 'material', mm.material,
          'desk', mm.deskripsi, 'kemasan', 'Level material', 'rows', v_x));
      end loop;

      for it in select value from jsonb_array_elements(v_items) loop
        v_hit := coalesce((select jsonb_agg(x) from jsonb_array_elements(it->'rows') x where x->>'jenis' <> 'FAKTUR'), '[]');
        v_fakt := coalesce((select jsonb_agg(jsonb_build_object('d', (x->>'disc')::numeric, 'dari', x->'dari', 'sampai', x->'sampai')
                                             order by (x->>'disc')::numeric desc)
                              from jsonb_array_elements(it->'rows') x where x->>'jenis' = 'FAKTUR'), '[]');
        v_tiers := '[]'; v_nseg := 0;
        if jsonb_array_length(v_hit) > 0 then
          v_b := array(select distinct d from (
                   select (x->>'dari')::date d from jsonb_array_elements(v_hit) x
                   union select (x->>'sampai')::date + 1 from jsonb_array_elements(v_hit) x) z order by 1);
          for v_i in 1 .. cardinality(v_b) - 1 loop
            v_d1 := v_b[v_i]; v_d2 := v_b[v_i + 1] - 1;
            v_aktif := (select jsonb_agg(x) from jsonb_array_elements(v_hit) x
                         where (x->>'dari')::date <= v_d1 and (x->>'sampai')::date >= v_d2);
            if v_aktif is null then continue; end if;
            v_nseg := v_nseg + 1;
            v_tiers := v_tiers || (select coalesce(jsonb_agg(disc.tier_kartu(g, au->>'mode')
                                                             || jsonb_build_object('dari', v_d1, 'sampai', v_d2)), '[]')
                                     from jsonb_array_elements(disc.gabung(v_aktif, au->>'mode')) g);
          end loop;
        end if;
        -- Satu rentang berlaku: tanggal cukup di kartu, tidak per tier.
        if v_nseg <= 1 then
          v_tiers := (select coalesce(jsonb_agg(x - 'dari' - 'sampai'), '[]') from jsonb_array_elements(v_tiers) x);
        end if;

        v_jenis := array(select distinct x->>'jenis' from jsonb_array_elements(v_hit) x);
        v_remark := case
          when au->>'kunci' = '*' then coalesce(disc.jenis_teks(v_jenis), 'Diskon faktur') || ', semua customer'
          when au->>'mode' = 'OPEN_QTY' then (au->>'label') || ' (open qty' || case when (au->>'tanpaBulk')::boolean then ' tanpa bulk' else '' end
                                             || ')' || coalesce(', kecuali ' || (au->>'kecuali'), '')
          else coalesce(disc.jenis_teks(v_jenis), 'Diskon faktur') || ' untuk ' || (au->>'label') end;

        v_tok := array(select distinct w from jsonb_array_elements(it->'rows') x, unnest(string_to_array(x->>'wilayah', ',')) w);
        if 'NASIONAL' = any(v_tok) then
          v_tampil := case when jsonb_array_length(au->'dcs') > 0 then array(select jsonb_array_elements_text(au->'dcs'))
                           else array['NASIONAL'] end;
        else
          v_tampil := v_tok;
        end if;
        v_khusus := array(select distinct w from disc.pengecualian e, unnest(disc.token_wilayah(e.nilai)) w
                           where e.diganti_pada is null and e.jenis = 'KHUSUS_WILAYAH' and e.condition_type is null
                             and (e.periode is null or e.periode = p_periode)
                             and (e.target is null or e.target = au->>'untuk' or au->'ids' ? e.target)
                             and ((e.material is not null and e.material = it->>'material') or (e.material is null and e.mg = v_mg))
                             and w not like '?%');
        if cardinality(v_khusus) > 0 then v_tampil := v_khusus; end if;
        v_tampil := array(select distinct x from unnest(v_tampil) x order by 1);

        select string_agg(distinct b.condition_type, ', ' order by b.condition_type),
               string_agg(distinct disc.label_level(b.level), ', ' order by disc.label_level(b.level))
          into v_ct, v_key
          from disc.generate_baris b join disc.generate_run r on r.id = b.run_id
         where r.periode = p_periode and b.mg = v_mg and b.material is not distinct from (it->>'material');

        v_cat := (select string_agg(distinct x->>'catatan', '; ') from jsonb_array_elements(it->'rows') x
                   where nullif(x->>'catatan', '') is not null);
        if not (it ? 'material') then
          v_exc := (select string_agg(distinct mt.material || ' ' || mt.deskripsi, ', ') from disc.pengecualian e
                      join disc.master_material mt on mt.material = e.material
                     where e.diganti_pada is null and e.jenis = 'KECUALIKAN_MATERIAL' and mt.mg = v_mg and e.condition_type is null
                       and (e.periode is null or e.periode = p_periode)
                       and (e.target is null or e.target = au->>'untuk' or au->'ids' ? e.target));
          if v_exc is not null then v_cat := concat_ws('; ', v_cat, 'Tidak termasuk ' || v_exc); end if;
        end if;

        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'kunci_item', it->>'kunci', 'kunci_target', au->>'kunci', 'mg', v_mg, 'material', it->>'material',
          'mg1', it->>'mg1', 'mg2', it->>'mg2', 'mg3', it->>'mg3',
          'nama_produk', it->>'desk', 'segmen', m.segmen, 'jenis_produk', m.jenis_produk,
          'untuk_label', au->>'untukLabel', 'remark', v_remark,
          'no_memo', (select string_agg(distinct x->>'memo', '; ') from jsonb_array_elements(it->'rows') x),
          'catatan', v_cat,
          'berlaku_dari', (select min((x->>'dari')::date) from jsonb_array_elements(it->'rows') x),
          'berlaku_sampai', (select max((x->>'sampai')::date) from jsonb_array_elements(it->'rows') x),
          'isi', jsonb_build_object('tiers', v_tiers, 'faktur', v_fakt, 'kemasan', it->>'kemasan', 'alias', m.alias,
                                    'mode', au->>'mode'),
          'tampil_default', to_jsonb(v_tampil),
          'condition_type', coalesce(v_ct, '-'), 'key_combination', coalesce(v_key, '-')));
      end loop;
    end loop;
  end loop;
  return v_out;
end $f$;

-- ---- RPC Terbitkan -------------------------------------------------------------------------
create or replace function public.rc_disc_draft_buat(p_periode text)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare
  v_kartu jsonb; c jsonb; k disc.kartu; v_lama jsonb; v_draft jsonb; v_tampil jsonb; v_kunci text[] := '{}';
  n_baru integer := 0; n_ubah integer := 0; n_sama integer := 0; n_usang integer := 0; n_hapus integer := 0;
begin
  perform rc_private.require_tab('discount.terbit');
  if p_periode is null or p_periode !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Periode harus YYYY-MM'; end if;
  v_kartu := disc.kartu_hitung(p_periode);

  for c in select value from jsonb_array_elements(v_kartu) loop
    v_kunci := v_kunci || ((c->>'kunci_item') || '#' || (c->>'kunci_target'));
    -- Tanda merah: beda dari kartu periode sebelumnya dengan kunci sama.
    v_lama := (select x.isi->'tiers' from disc.kartu x where x.kunci_item = c->>'kunci_item' and x.kunci_target = c->>'kunci_target'
                and x.periode < p_periode and x.versi > 0 order by x.periode desc limit 1);
    if v_lama is not null then
      c := jsonb_set(c, '{isi,tiers}', disc.tandai_ubah(c->'isi'->'tiers', v_lama));
    end if;

    select * into k from disc.kartu x where x.periode = p_periode and x.kunci_item = c->>'kunci_item'
                                      and x.kunci_target = c->>'kunci_target' for update;
    if not found then
      insert into disc.kartu(periode, kunci_item, kunci_target, mg, material, mg1, mg2, mg3, draft, versi, status)
      values (p_periode, c->>'kunci_item', c->>'kunci_target', c->>'mg', c->>'material', c->>'mg1', c->>'mg2', c->>'mg3',
              c || jsonb_build_object('tampil_di', c->'tampil_default'), 0, 'DRAFT');
      n_baru := n_baru + 1;
      continue;
    end if;
    -- Wilayah tampil: pilihan manual di draft dipertahankan; wilayah kartu terbit dipertahankan
    -- selama bawaan dari kebijakan tidak berubah.
    v_tampil := case
      when k.draft ? 'tampil_manual' then k.draft->'tampil_di'
      when k.versi > 0 and coalesce(k.isi->'tampilDefault', to_jsonb(k.tampil_di)) = c->'tampil_default' then to_jsonb(k.tampil_di)
      else c->'tampil_default' end;
    v_draft := c || jsonb_build_object('tampil_di', v_tampil)
                 || case when k.draft ? 'tampil_manual' then jsonb_build_object('tampil_manual', true) else '{}'::jsonb end;
    if k.status = 'TERBIT' and disc.konten(v_draft) = disc.konten(disc.kartu_publik(k))
       and v_tampil = to_jsonb(k.tampil_di)
       and (v_draft->>'condition_type') is not distinct from k.condition_type
       and (v_draft->>'key_combination') is not distinct from k.key_combination then
      update disc.kartu set draft = null, diubah_pada = now() where id = k.id;
      n_sama := n_sama + 1;
    else
      update disc.kartu set draft = v_draft, diubah_pada = now() where id = k.id;
      n_ubah := n_ubah + 1;
    end if;
  end loop;

  -- Kartu yang tidak dihasilkan lagi oleh kebijakan.
  with h as (delete from disc.kartu x where x.periode = p_periode and x.versi = 0
               and not ((x.kunci_item || '#' || x.kunci_target) = any(v_kunci)) returning 1)
  select count(*) into n_hapus from h;
  update disc.kartu x set draft = jsonb_build_object('usang', true), diubah_pada = now()
   where x.periode = p_periode and x.versi > 0 and x.status = 'TERBIT'
     and not ((x.kunci_item || '#' || x.kunci_target) = any(v_kunci));
  get diagnostics n_usang = row_count;

  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), 'discount_draft', jsonb_build_object('detail', 'Discount Center: susun draft kartu periode ' || p_periode
            || ' - ' || n_baru || ' baru, ' || n_ubah || ' berubah, ' || n_sama || ' sama, ' || n_usang || ' usang',
            'periode', p_periode, 'baru', n_baru, 'berubah', n_ubah, 'sama', n_sama, 'usang', n_usang, 'dihapus', n_hapus),
          'Discount Center', 'Terbitkan', 'Draft');
  return jsonb_build_object('status', 'success', 'periode', p_periode, 'baru', n_baru, 'berubah', n_ubah, 'sama', n_sama,
                            'usang', n_usang, 'dihapus', n_hapus);
end $f$;

create or replace function public.rc_disc_terbit_list(p_periode text)
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  perform rc_private.require_tab('discount.terbit');
  return jsonb_build_object('status', 'success', 'periode', p_periode,
    'periodes', coalesce((select jsonb_agg(p order by p desc) from (select distinct periode p from disc.kebijakan where diganti_pada is null
                                                                    union select distinct periode from disc.kartu) z), '[]'),
    'kartu', coalesce((select jsonb_agg(jsonb_build_object(
        'id', k.id, 'status', k.status, 'versi', k.versi,
        'perubahan', case when k.draft ? 'usang' then 'USANG' when k.draft is null then null when k.versi = 0 then 'BARU'
                          when k.status = 'DITARIK' then 'TERBIT_ULANG'
                          when disc.konten(k.draft) <> disc.konten(disc.kartu_publik(k)) then 'REVISI'
                          when (k.draft->'tampil_di') <> to_jsonb(k.tampil_di) then 'WILAYAH' else 'CT' end,
        'produk', coalesce(d.d->>'nama_produk', k.nama_produk), 'kode', coalesce(k.material, k.mg),
        'segmen', coalesce(d.d->>'segmen', k.segmen),
        'kemasan', coalesce(d.d->'isi'->>'kemasan', k.isi->>'kemasan'), 'remark', coalesce(d.d->>'remark', k.remark),
        'untuk', coalesce(d.d->>'untuk_label', k.untuk_label), 'wilayah', coalesce(d.d->'tampil_di', to_jsonb(k.tampil_di)),
        'wilayahTerbit', to_jsonb(k.tampil_di), 'tiers', coalesce(d.d->'isi'->'tiers', k.isi->'tiers'),
        'faktur', coalesce(d.d->'isi'->'faktur', k.isi->'faktur'),
        'ct', coalesce(d.d->>'condition_type', k.condition_type), 'key', coalesce(d.d->>'key_combination', k.key_combination),
        'dari', coalesce(d.d->>'berlaku_dari', k.berlaku_dari::text), 'sampai', coalesce(d.d->>'berlaku_sampai', k.berlaku_sampai::text),
        'memo', coalesce(d.d->>'no_memo', k.no_memo), 'catatan', coalesce(d.d->>'catatan', k.catatan),
        'terbit', k.waktu_terbit, 'ditarik', k.ditarik_pada, 'alasanTarik', k.alasan_tarik)
        order by case k.status when 'DRAFT' then 0 when 'TERBIT' then 1 else 2 end, coalesce(d.d->>'segmen', k.segmen),
                 coalesce(d.d->>'nama_produk', k.nama_produk), k.kunci_target)
      from disc.kartu k cross join lateral (select case when k.draft ? 'usang' then null else k.draft end d) d
     where k.periode = p_periode), '[]'));
end $f$;

create or replace function public.rc_disc_atur_wilayah(p_ids uuid[], p_wilayah text)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare v_tok text[] := disc.token_wilayah(p_wilayah); n integer;
begin
  perform rc_private.require_tab('discount.terbit');
  if exists(select 1 from unnest(v_tok) x where x like '?%') then
    raise exception 'Wilayah tidak dikenal: % (tulis NASIONAL, REGION <kode>, atau kode depot)',
      (select string_agg(substr(x, 2), ', ') from unnest(v_tok) x where x like '?%');
  end if;
  update disc.kartu k
     set draft = case when k.draft is null or k.draft ? 'usang' then disc.kartu_publik(k) else k.draft end
                 || jsonb_build_object('tampil_di', to_jsonb(v_tok), 'tampil_manual', true),
         diubah_pada = now()
   where k.id = any(p_ids) and (k.status <> 'DITARIK' or (k.draft is not null and not k.draft ? 'usang'));
  get diagnostics n = row_count;
  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), 'discount_wilayah', jsonb_build_object('detail', 'Discount Center: wilayah tampil ' || n || ' kartu menjadi '
            || array_to_string(v_tok, ', '), 'kartu', to_jsonb(p_ids), 'wilayah', to_jsonb(v_tok)),
          'Discount Center', 'Terbitkan', 'Wilayah');
  return jsonb_build_object('status', 'success', 'diubah', n, 'wilayah', to_jsonb(v_tok));
end $f$;

create or replace function public.rc_disc_terbit(p_ids uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare
  k disc.kartu; d jsonb; v_lama jsonb; v_ubah jsonb; v_teks text[]; v_isi jsonb;
  n_baru integer := 0; n_revisi integer := 0; n_meta integer := 0; n_lewat integer := 0;
begin
  perform rc_private.require_tab('discount.terbit');
  for k in select * from disc.kartu where id = any(p_ids) order by id for update loop
    d := k.draft;
    if d is null or d ? 'usang' then n_lewat := n_lewat + 1; continue; end if;
    if k.status = 'TERBIT' and disc.konten(d) = disc.konten(disc.kartu_publik(k)) then
      update disc.kartu set tampil_di = array(select jsonb_array_elements_text(d->'tampil_di')),
             condition_type = d->>'condition_type', key_combination = d->>'key_combination',
             isi = isi || jsonb_build_object('tampilDefault', d->'tampil_default'), draft = null, diubah_pada = now()
       where id = k.id;
      n_meta := n_meta + 1;
      continue;
    end if;
    v_isi := (d->'isi') || jsonb_build_object('tampilDefault', d->'tampil_default');
    if k.versi > 0 then
      -- Revisi: catat apa yang berubah dibanding versi terbit, tandai merah di layar.
      v_lama := k.isi->'tiers';
      v_ubah := (select coalesce(jsonb_agg(jsonb_build_object('syarat', x->>'syarat', 'dari', x->>'dari', 'ubah', x->'ubah'))
                                 filter (where jsonb_array_length(x->'ubah') > 0), '[]')
                   from jsonb_array_elements(disc.tandai_ubah(d->'isi'->'tiers', v_lama)) x);
      v_teks := array(select distinct case k2 when 'vol' then 'Disc Vol' when 'cmp' then 'Disc CMP' when 'bulk' then 'Disc Bulk'
                                              else 'disc lain' end
                        from jsonb_array_elements(v_ubah) x, jsonb_array_elements_text(x->'ubah') k2);
      if jsonb_array_length(d->'isi'->'tiers') <> jsonb_array_length(coalesce(v_lama, '[]'))
         or exists(select 1 from jsonb_array_elements(v_lama) o where not exists(
                     select 1 from jsonb_array_elements(d->'isi'->'tiers') n where n->>'syarat' = o->>'syarat')) then
        v_teks := v_teks || 'tier'::text;
      end if;
      if (d->>'berlaku_dari')::date is distinct from k.berlaku_dari or (d->>'berlaku_sampai')::date is distinct from k.berlaku_sampai then
        v_teks := v_teks || 'masa berlaku'::text;
      end if;
      if cardinality(v_teks) = 0 then v_teks := array['keterangan']; end if;
      v_isi := v_isi || jsonb_build_object('revisiUbah', v_ubah,
        'revisi', upper(left(array_to_string(v_teks, ', '), 1)) || substr(array_to_string(v_teks, ', '), 2)
                  || ' diperbarui pada versi ' || (k.versi + 1) || '.');
      n_revisi := n_revisi + 1;
    else
      n_baru := n_baru + 1;
    end if;
    update disc.kartu set nama_produk = d->>'nama_produk', segmen = d->>'segmen', jenis_produk = d->>'jenis_produk',
           untuk_label = d->>'untuk_label', remark = d->>'remark', condition_type = d->>'condition_type',
           key_combination = d->>'key_combination', no_memo = d->>'no_memo', catatan = d->>'catatan',
           berlaku_dari = (d->>'berlaku_dari')::date, berlaku_sampai = (d->>'berlaku_sampai')::date, isi = v_isi,
           tampil_di = array(select jsonb_array_elements_text(d->'tampil_di')), draft = null, versi = k.versi + 1,
           status = 'TERBIT', diterbitkan_oleh = auth.uid(), waktu_terbit = now(),
           ditarik_oleh = null, ditarik_pada = null, alasan_tarik = null, diubah_pada = now()
     where id = k.id;
  end loop;
  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), 'discount_terbit', jsonb_build_object('detail', 'Discount Center: terbit ' || n_baru || ' kartu baru, '
            || n_revisi || ' revisi, ' || n_meta || ' wilayah/CT', 'kartu', to_jsonb(p_ids), 'baru', n_baru, 'revisi', n_revisi,
            'wilayah', n_meta, 'dilewati', n_lewat),
          'Discount Center', 'Terbitkan', 'Terbit');
  return jsonb_build_object('status', 'success', 'baru', n_baru, 'revisi', n_revisi, 'wilayah', n_meta, 'dilewati', n_lewat);
end $f$;

create or replace function public.rc_disc_tarik(p_ids uuid[], p_alasan text)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare n integer;
begin
  perform rc_private.require_tab('discount.terbit');
  if nullif(btrim(coalesce(p_alasan, '')), '') is null then raise exception 'Alasan tarik wajib diisi'; end if;
  update disc.kartu set status = 'DITARIK', ditarik_oleh = auth.uid(), ditarik_pada = now(), alasan_tarik = btrim(p_alasan),
         draft = case when draft ? 'usang' then null else draft end, diubah_pada = now()
   where id = any(p_ids) and status = 'TERBIT';
  get diagnostics n = row_count;
  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
  values (auth.uid(), 'discount_tarik', jsonb_build_object('detail', 'Discount Center: tarik ' || n || ' kartu - ' || btrim(p_alasan),
            'kartu', to_jsonb(p_ids), 'alasan', btrim(p_alasan)),
          'Discount Center', 'Terbitkan', 'Tarik');
  return jsonb_build_object('status', 'success', 'ditarik', n);
end $f$;

-- ---- Dashboard dan acknowledge ---------------------------------------------------------------
-- Kartu TERBIT yang boleh dilihat: Sales Distribution semua; selain itu TAMPIL_DI bertemu
-- wilayah user (NASIONAL, depot user_depot_access, region depot itu). Untuk selain Sales
-- Distribution, wilayah, condition type, dan key combination tidak dikirim.
create or replace function public.rc_disc_dashboard()
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare
  v_uid uuid := auth.uid(); v_sd boolean; v_wil text[]; v_depot jsonb; v_kartu jsonb;
  v_hari date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if not (rc_private.can_tab('discount.dashboard') or rc_private.can_tab('discount.ack')) then
    perform rc_private.require_tab('discount.dashboard');
  end if;
  v_sd := disc.sd_saya();
  v_wil := disc.wilayah_user(v_uid);
  v_depot := (select coalesce(jsonb_agg(jsonb_build_object('kode', upper(d.depot_code), 'nama', d.depot_name, 'region', d.region)
                                        order by d.depot_code), '[]')
                from public.user_depot_access a join public.depots d on d.id = a.depot_id
               where a.user_id = v_uid and d.archived_at is null and not d.bukan_depot);
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', k.id, 'periode', k.periode, 'segmen', k.segmen, 'jenisProduk', k.jenis_produk, 'produk', k.nama_produk,
      'alias', k.isi->>'alias', 'mg', k.mg, 'material', k.material, 'kode', coalesce(k.material, k.mg),
      'kemasan', k.isi->>'kemasan', 'remark', k.remark, 'untuk', k.untuk_label, 'tiers', k.isi->'tiers',
      'faktur', k.isi->'faktur', 'revisiUbah', k.isi->'revisiUbah', 'revisi', k.isi->>'revisi',
      'dari', k.berlaku_dari, 'sampai', k.berlaku_sampai, 'memo', k.no_memo, 'catatan', k.catatan, 'versi', k.versi,
      'terbit', k.waktu_terbit, 'ack', ak.waktu, 'wajibAck', k.berlaku_sampai >= v_hari,
      'wilayah', case when v_sd then to_jsonb(k.tampil_di) end,
      'ct', case when v_sd then k.condition_type end, 'key', case when v_sd then k.key_combination end,
      'depotTercakup', case when not v_sd then (select coalesce(jsonb_agg(dd->>'kode'), '[]') from jsonb_array_elements(v_depot) dd
                         where k.tampil_di && array['NASIONAL', dd->>'kode', 'REGION ' || upper(btrim(coalesce(dd->>'region', '')))]) end)
      order by k.periode desc, k.segmen, k.nama_produk, k.untuk_label), '[]')
    into v_kartu
    from disc.kartu k
    left join disc.ack ak on ak.kartu_id = k.id and ak.versi = k.versi and ak.user_id = v_uid
   where k.status = 'TERBIT' and (v_sd or k.tampil_di && v_wil)
     and (k.berlaku_sampai >= v_hari - 92 or k.periode >= to_char(v_hari - interval '3 months', 'YYYY-MM'));
  return jsonb_build_object('status', 'success', 'sd', v_sd, 'bolehAck', rc_private.can_tab('discount.ack'),
    'kartu', v_kartu, 'depot', v_depot, 'hariIni', v_hari,
    'wajibAckDulu', coalesce((select nilai = 'Y' from disc.pengaturan where kunci = 'WAJIB_ACK_DULU'), false));
end $f$;

create or replace function public.rc_disc_ack(p_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare v_uid uuid := auth.uid(); v_sd boolean; v_wil text[]; n integer;
begin
  perform rc_private.require_tab('discount.ack');
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Tidak ada kartu yang di-acknowledge';
  end if;
  if jsonb_array_length(p_items) > 2000 then raise exception 'Maksimal 2000 kartu sekali acknowledge'; end if;
  v_sd := disc.sd_saya(); v_wil := disc.wilayah_user(v_uid);
  insert into disc.ack(kartu_id, versi, user_id)
  select k.id, k.versi, v_uid
    from (select distinct (x->>'id')::uuid id, (x->>'versi')::integer versi from jsonb_array_elements(p_items) x) i
    join disc.kartu k on k.id = i.id and k.versi = i.versi and k.status = 'TERBIT'
   where v_sd or k.tampil_di && v_wil
  on conflict do nothing;
  get diagnostics n = row_count;
  if n > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (v_uid, 'discount_ack', jsonb_build_object('detail', 'Discount Center: acknowledge ' || n || ' kartu', 'jumlah', n,
              'kartu', (select jsonb_agg(x->'id') from jsonb_array_elements(p_items) x)),
            'Discount Center', 'Acknowledge', 'Acknowledge');
  end if;
  return jsonb_build_object('status', 'success', 'dicatat', n, 'dikirim', jsonb_array_length(p_items));
end $f$;

-- ---- Monitoring ------------------------------------------------------------------------------
-- User wajib acknowledge: akun aktif yang punya tab Acknowledge dan bukan Sales Distribution
-- (Sales Distribution acknowledge massal, tidak wajib). Per depot = user dengan akses depot itu
-- x kartu yang tampil di depot itu.
create or replace function public.rc_disc_monitor(p_periode text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare v_per text; v_res jsonb;
begin
  perform rc_private.require_tab('discount.monitor');
  v_per := coalesce(nullif(btrim(coalesce(p_periode, '')), ''), (select max(periode) from disc.kartu where status = 'TERBIT'));
  with u as (
    select p.id, p.user_code, p.full_name, p.role, disc.wilayah_user(p.id) wil
      from public.profiles p
     where p.status = 'active' and p.archived_at is null and disc.punya_tab(p.id, 'discount.ack') and not disc.sd_user(p.id)
  ), c as (
    select k.id, k.nama_produk, coalesce(k.material, k.mg) kode, k.isi->>'kemasan' kemasan, k.versi, k.tampil_di,
           k.waktu_terbit, k.remark, k.segmen
      from disc.kartu k where k.status = 'TERBIT' and k.periode = v_per
  ), pr as (
    select u.id uid, c.id cid, exists(select 1 from disc.ack a where a.kartu_id = c.id and a.versi = c.versi and a.user_id = u.id) sudah
      from u join c on c.tampil_di && u.wil
  ), ud as (
    select a.user_id, upper(d.depot_code) kode, d.depot_name nama, d.region
      from public.user_depot_access a join public.depots d on d.id = a.depot_id
     where d.archived_at is null and not d.bukan_depot and a.user_id in (select id from u)
  ), dc as (
    select distinct ud.kode, c.id cid from (select distinct kode, region from ud) ud
      join c on c.tampil_di && array['NASIONAL', ud.kode, 'REGION ' || upper(btrim(coalesce(ud.region, '')))]
  ), dep as (
    select d.kode, max(d.nama) nama, max(d.region) region, count(distinct d.user_id) users,
           (select count(*) from dc where dc.kode = d.kode) kartu,
           (select count(*) from ud x join dc on dc.kode = x.kode join pr on pr.uid = x.user_id and pr.cid = dc.cid where x.kode = d.kode) wajib,
           (select count(*) from ud x join dc on dc.kode = x.kode join pr on pr.uid = x.user_id and pr.cid = dc.cid
             where x.kode = d.kode and pr.sudah) sudah
      from ud d group by d.kode
  )
  select jsonb_build_object('status', 'success', 'periode', v_per,
    'periodes', coalesce((select jsonb_agg(p order by p desc) from (select distinct periode p from disc.kartu where status = 'TERBIT') z), '[]'),
    'ringkas', jsonb_build_object('kartu', (select count(*) from c), 'user', (select count(*) from u),
               'wajib', (select count(*) from pr), 'sudah', (select count(*) from pr where sudah)),
    'depot', coalesce((select jsonb_agg(jsonb_build_object('kode', kode, 'nama', nama, 'region', region, 'user', users, 'kartu', kartu,
               'wajib', wajib, 'sudah', sudah) order by region, kode) from dep), '[]'),
    'kartu', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'produk', c.nama_produk, 'kode', c.kode, 'kemasan', c.kemasan,
               'remark', c.remark, 'versi', c.versi, 'wilayah', to_jsonb(c.tampil_di), 'segmen', c.segmen,
               'wajib', (select count(*) from pr where pr.cid = c.id), 'sudah', (select count(*) from pr where pr.cid = c.id and pr.sudah))
               order by c.segmen, c.nama_produk) from c), '[]'),
    'belum', coalesce((select jsonb_agg(jsonb_build_object('kartuId', c.id, 'userCode', u.user_code, 'nama', u.full_name, 'role', u.role,
               'depot', (select string_agg(x.kode, ', ' order by x.kode) from ud x where x.user_id = u.id),
               'produk', c.nama_produk, 'kode', c.kode, 'kemasan', c.kemasan, 'remark', c.remark, 'versi', c.versi,
               'terbit', c.waktu_terbit) order by u.user_code, c.nama_produk)
               from (select * from pr where not sudah limit 5000) pr join u on u.id = pr.uid join c on c.id = pr.cid), '[]'))
    into v_res;
  return v_res;
end $f$;

revoke all on all functions in schema disc from public, anon, authenticated;
do $hak$
declare f text;
begin
  foreach f in array array['public.rc_disc_draft_buat(text)', 'public.rc_disc_terbit_list(text)',
    'public.rc_disc_atur_wilayah(uuid[], text)', 'public.rc_disc_terbit(uuid[])', 'public.rc_disc_tarik(uuid[], text)',
    'public.rc_disc_dashboard()', 'public.rc_disc_ack(jsonb)', 'public.rc_disc_monitor(text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $hak$;
