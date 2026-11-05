-- ==========================================================================================
-- Discount Center: generate template pantek (spesifikasi bagian 4-5). Bergantung pada
-- 20261163310000, 20261163320000, 20261163330000.
-- ==========================================================================================
-- rc_disc_generate(periode, condition type, target[], komponen[], per grup, sumber, catat)
--  * target: '*' (semua target aktif bertipe TIPE_TARGET), 'GRUP:<grup>', TARGET_ID, atau
--    'KOSONG:<tipe>' = satu set baris tanpa kode target dan CustGrp yang diisi saat pantek (pola
--    RA08/RA09 "Semua Sales Office"). Boleh beberapa sekaligus.
--  * sumber SEMUA: baris UNTUK_TARGET kosong (berlaku untuk semua target) + baris khusus target /
--    grupnya. KHUSUS: hanya baris yang UNTUK_TARGET-nya target / grup itu.
--  * Condition type ber-UOM_SCALE (RA08 KG, RA09 L, RA03 PC) hanya mengambil MG yang satuan
--    master-nya (atau UOM_OVERRIDE) sama; MG lain milik condition type lain dan dilewati.
--    Komponen ber-scale dengan satuan lain = ERROR_UOM_CT.
--  * Satu MG untuk satu target hanya di satu level: bila MG wajib kemasan atau ada baris kemasan,
--    baris level MG ikut dipecah ke setiap kombinasi kemasan dari MASTER_MATERIAL.
--  * Komponen dengan masa berlaku berbeda dipecah per rentang tanggal, sehingga setiap record
--    hanya memuat komponen yang benar-benar berlaku di rentang itu.
--  * catat = true (tombol Download) menyimpan snapshot ke generate_run / generate_baris untuk
--    flag BERUBAH berikutnya dan kolom CT kartu, plus satu baris Log Activity.
-- ==========================================================================================

-- Hak tab modul discount untuk user mana pun (tab_rights hanya untuk user yang boleh dilihat
-- pemanggil). Logika sama dengan rc_private.tab_rights untuk tab berizin view_discount.
create or replace function disc.punya_tab(p_user uuid, p_code text) returns boolean
language sql stable security definer set search_path = '' as $f$
  select coalesce((
    select p.role = 'system manager'
        or ((p.role in ('depot head','management')
             or exists(select 1 from public.user_permissions up where up.user_id = p.id and up.permission_code = 'view_discount'))
            and coalesce(u.allowed, not (p_code in ('discount.monitor','discount.kebijakan','discount.generate','discount.terbit'))))
      from public.profiles p
      left join rc_private.user_tab_access u on u.user_id = p.id and u.tab_code = p_code
     where p.id = p_user and p.status = 'active' and p.archived_at is null), false);
$f$;

create or replace function disc.sd_user(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $f$
  select coalesce((select p.role = 'system manager' from public.profiles p
                    where p.id = p_user and p.status = 'active' and p.archived_at is null), false)
      or disc.punya_tab(p_user, 'discount.monitor') or disc.punya_tab(p_user, 'discount.kebijakan')
      or disc.punya_tab(p_user, 'discount.generate') or disc.punya_tab(p_user, 'discount.terbit');
$f$;

-- Angka tanpa nol di belakang (9.75, 18.775, 20); scale bisa ribuan.
create or replace function disc.pct(p numeric) returns text
language sql immutable set search_path = '' as $f$ select rtrim(rtrim(to_char(p, 'FM999999990.999'), '0'), '.') $f$;

create or replace function disc.awalan(p_tipe text) returns text
language sql immutable set search_path = '' as $f$
  select case p_tipe when 'CUSTOMER' then 'CUST_' when 'SLS_OFFICE' then 'SLSOFF_CG_' when 'SLS_ORG' then 'SLSORG_CG_'
                     when 'COND_GROUP2' then 'CG2_CG_' end;
$f$;

-- Level dari tipe target dan kunci item (urutan access sequence: Material > kemasan > MG).
create or replace function disc.level_item(p_tipe text, p_material text, p_mg1 text, p_mg2 text, p_mg3 text) returns text
language sql immutable set search_path = '' as $f$
  select disc.awalan(p_tipe) || case
    when p_material is not null then 'MAT'
    when p_tipe = 'COND_GROUP2' then 'MG_MG3_MG2_MG1'
    when p_mg3 is not null then 'MG_MG3_MG2_MG1'
    when p_mg2 is not null then 'MG_MG2_MG1'
    when p_mg1 is not null then 'MG_MG1'
    else 'MG' end;
$f$;

-- Token wilayah sebuah DC: NASIONAL, kode depot, REGION <kode>. DC kosong = null (tidak diketahui).
create or replace function disc.wilayah_dc(p_dc text) returns text[]
language sql stable security definer set search_path = '' as $f$
  select case when nullif(btrim(coalesce(p_dc, '')), '') is null then null else array(
    select 'NASIONAL' union select upper(btrim(p_dc))
    union select 'REGION ' || upper(btrim(d.region)) from public.depots d
     where upper(d.depot_code) = upper(btrim(p_dc)) and d.archived_at is null and btrim(coalesce(d.region, '')) <> '') end;
$f$;

-- Disc Type disusun dari komponen yang benar-benar ikut (spesifikasi bagian 4).
drop function if exists disc.disc_type(jsonb);
create or replace function disc.disc_type(p_komponen jsonb, p_mode text default null) returns text
language sql immutable set search_path = '' as $f$
  select case when p_mode = 'OPEN_QTY' then 'Disc Open Qty (' || string_agg(l1, ', ' order by u1) || ')'
              else string_agg(l2, ' + ' order by u2) end
    from (select distinct x->>'jenis' j,
                 array_position(array['VOL','BULK','CMP','PROMO','BP','LAIN'], x->>'jenis') u1,
                 array_position(array['VOL','CMP','BULK','BP','PROMO','LAIN'], x->>'jenis') u2,
                 case x->>'jenis' when 'VOL' then 'Vol' when 'CMP' then 'CMP' when 'BULK' then 'Bulk' when 'BP' then 'BP'
                                  when 'PROMO' then 'Promo' else 'Lain' end l1,
                 case x->>'jenis' when 'VOL' then 'Disc Vol' when 'CMP' then 'Disc CMP' when 'BULK' then 'Disc Bulk'
                                  when 'BP' then 'Disc BP' when 'PROMO' then 'Disc Promo' else 'Disc Lain' end l2
            from jsonb_array_elements(coalesce(p_komponen, '[]')) x) y;
$f$;

-- ---- Inti generate: baris per target (belum digabung per grup) -------------------------------
create or replace function disc.generate_inti(p_periode text, p_ct text, p_targets text[], p_komponen text[], p_sumber text)
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare
  a disc.aturan_ct; m disc.master_mg; mm disc.master_material;
  t record; c record; e record; it jsonb; tr jsonb;
  v_mode text; v_tw text[]; v_semua jsonb; v_r jsonb; v_mgrows jsonb; v_items jsonb; v_x jsonb;
  v_rows jsonb := '[]'; v_targets jsonb := '[]'; v_lewat text[] := '{}';
  v_mg text; v_uom_eff text; v_kem boolean; v_level text; v_sheet text; v_b date[]; v_i integer;
  v_aktif jsonb; v_tiers jsonb; v_komp jsonb; v_flags text[]; v_ket text[]; v_amount numeric; v_scale numeric;
  v_uom text; v_d1 date; v_d2 date; v_kunci text; v_lama numeric; v_status text; v_r1 text; v_cat text;
  v_r2awal text; v_r2akhir text; v_dt text; v_desk text;
  v_hari text := to_char((now() at time zone 'Asia/Jakarta')::date, 'DD.MM.YYYY');
begin
  select * into a from disc.aturan_ct where condition_type = p_ct;
  if not found then raise exception 'Condition type % tidak ada di ATURAN_CT', p_ct; end if;
  if not a.aktif or a.mode_hitung is null then
    raise exception 'Aturan % belum lengkap (MODE_HITUNG kosong atau tidak aktif), jadi generate belum bisa dijalankan.', p_ct;
  end if;
  v_mode := a.mode_hitung;

  for t in
    select x.* from (
      select tg.target_id, tg.tipe, tg.kode, coalesce(tg.cust_group, '') cg, tg.nama, tg.dc, tg.grup, tg.aturan_disc,
             tg.label_output, false kosong
        from disc.target tg
       where tg.aktif and tg.tipe = any(a.tipe_target)
         and ('*' = any(p_targets) or tg.target_id = any(p_targets) or ('GRUP:' || tg.grup) = any(p_targets))
      union all
      select 'KOSONG:' || tp, tp, '', '', '', null::text, null::text, 'NORMAL', null::text, true
        from unnest(a.tipe_target) tp where ('KOSONG:' || tp) = any(p_targets)
    ) x order by x.kosong desc, x.grup nulls last, x.target_id
  loop
    v_targets := v_targets || jsonb_build_array(jsonb_build_object('tid', t.target_id, 'grup', t.grup, 'nama', t.nama,
                                                                   'tipe', t.tipe, 'kosong', t.kosong));
    v_tw := disc.wilayah_dc(t.dc);

    -- Baris KEBIJAKAN yang berlaku untuk target ini, setelah aturan target dan PENGECUALIAN.
    select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'jenis', k.jenis, 'mg', k.mg, 'material', k.material,
             'mg1', k.mg1, 'mg2', k.mg2, 'mg3', k.mg3, 'qty', k.scale_qty, 'uom', k.scale_uom, 'disc', k.disc,
             'dari', k.valid_from, 'sampai', k.valid_to, 'memo', k.no_memo, 'catatan', k.catatan,
             'wilayah', array_to_string(w.tok, ','),
             'cekwil', v_tw is null and (not ('NASIONAL' = any(w.tok)) or exists(
                 select 1 from disc.pengecualian e2 where e2.diganti_pada is null and e2.jenis = 'KHUSUS_WILAYAH'
                    and (e2.periode is null or e2.periode = p_periode) and (e2.condition_type is null or e2.condition_type = p_ct)
                    and (e2.target is null or e2.target = t.target_id or e2.target = t.grup)
                    and ((e2.material is not null and e2.material = k.material) or (e2.material is null and e2.mg = k.mg)))))
           order by k.id), '[]')
      into v_semua
      from disc.kebijakan k
      cross join lateral (select string_to_array(coalesce(nullif(k.wilayah, ''), 'NASIONAL'), ',') tok) w
     where k.periode = p_periode and k.diganti_pada is null and k.jenis <> 'FAKTUR' and k.jenis = any(p_komponen)
       and case when k.untuk_target is null then p_sumber = 'SEMUA' else k.untuk_target in (t.target_id, t.grup) end
       and not (v_mode = 'OPEN_QTY' and k.jenis = 'BP')
       and not (t.aturan_disc = 'OPEN_QTY_TANPA_BULK' and k.jenis = 'BULK')
       and ('NASIONAL' = any(w.tok) or v_tw is null or w.tok && v_tw)
       and not exists(select 1 from disc.pengecualian e2 where e2.diganti_pada is null and e2.jenis = 'TANPA_KOMPONEN'
                        and upper(e2.nilai) = k.jenis
                        and (e2.periode is null or e2.periode = p_periode) and (e2.condition_type is null or e2.condition_type = p_ct)
                        and (e2.target is null or e2.target = t.target_id or e2.target = t.grup)
                        and ((e2.material is not null and e2.material = k.material) or (e2.material is null and e2.mg = k.mg)))
       and not exists(select 1 from disc.pengecualian e2 where v_tw is not null and e2.diganti_pada is null and e2.jenis = 'KHUSUS_WILAYAH'
                        and (e2.periode is null or e2.periode = p_periode) and (e2.condition_type is null or e2.condition_type = p_ct)
                        and (e2.target is null or e2.target = t.target_id or e2.target = t.grup)
                        and ((e2.material is not null and e2.material = k.material) or (e2.material is null and e2.mg = k.mg))
                        and not (disc.token_wilayah(e2.nilai) && v_tw));

    for v_mg in select distinct x->>'mg' from jsonb_array_elements(v_semua) x order by 1 loop
      v_r := (select jsonb_agg(x) from jsonb_array_elements(v_semua) x where x->>'mg' = v_mg);
      select * into m from disc.master_mg where mg = v_mg;
      if not found or not m.aktif then
        v_rows := v_rows || jsonb_build_array(jsonb_build_object('tid', t.target_id, 'grup', t.grup, 'nama', t.nama, 'tipe', t.tipe,
          'status', 'ERROR', 'flags', jsonb_build_array('ERROR_MG'), 'mg', v_mg,
          'ket', 'MG ' || v_mg || case when found then ' tidak aktif di MASTER_MG' else ' tidak ada di MASTER_MG' end,
          'f', jsonb_build_object('CONDITION_TYPE', p_ct, 'TARGET', t.kode, 'MG', v_mg, 'DESCRIPTION', '-')));
        continue;
      end if;

      v_uom_eff := coalesce((select upper(e2.nilai) from disc.pengecualian e2
                              where e2.diganti_pada is null and e2.jenis = 'UOM_OVERRIDE' and e2.mg = v_mg and e2.material is null
                                and (e2.periode is null or e2.periode = p_periode) and (e2.condition_type is null or e2.condition_type = p_ct)
                                and (e2.target is null or e2.target = t.target_id or e2.target = t.grup)
                              order by e2.condition_type nulls last, e2.target nulls last, e2.id desc limit 1), m.uom_scale);
      if a.uom_scale is not null and v_uom_eff is not null and v_uom_eff <> a.uom_scale then
        if not (v_mg = any(v_lewat)) then v_lewat := v_lewat || v_mg; end if;
        continue;
      end if;

      -- Item: level MG, level kemasan (baris MG ikut ke setiap kemasan), level material.
      v_mgrows := coalesce((select jsonb_agg(x) from jsonb_array_elements(v_r) x
                             where x->>'material' is null and x->>'mg1' is null and x->>'mg2' is null and x->>'mg3' is null), '[]');
      v_kem := m.level_wajib = 'KEMASAN' or exists(select 1 from jsonb_array_elements(v_r) x
                 where x->>'material' is null and coalesce(x->>'mg1', x->>'mg2', x->>'mg3') is not null);
      v_items := '[]';
      if v_kem then
        for c in
          select distinct z.mg1, z.mg2, z.mg3 from (
            select mt.mg1, mt.mg2, mt.mg3 from disc.master_material mt
             where mt.mg = v_mg and mt.aktif and coalesce(mt.mg1, mt.mg2, mt.mg3) is not null
            union
            select x->>'mg1', x->>'mg2', x->>'mg3' from jsonb_array_elements(v_r) x
             where x->>'material' is null and coalesce(x->>'mg1', x->>'mg2', x->>'mg3') is not null
               and not exists(select 1 from disc.master_material mt where mt.mg = v_mg and mt.aktif
                                and (x->>'mg1' is null or mt.mg1 = x->>'mg1') and (x->>'mg2' is null or mt.mg2 = x->>'mg2')
                                and (x->>'mg3' is null or mt.mg3 = x->>'mg3'))) z
           order by 2 nulls first, 1 nulls first, 3 nulls first
        loop
          v_x := v_mgrows || coalesce((select jsonb_agg(x) from jsonb_array_elements(v_r) x
                   where x->>'material' is null and coalesce(x->>'mg1', x->>'mg2', x->>'mg3') is not null
                     and (x->>'mg1' is null or x->>'mg1' = c.mg1) and (x->>'mg2' is null or x->>'mg2' = c.mg2)
                     and (x->>'mg3' is null or x->>'mg3' = c.mg3)), '[]');
          if jsonb_array_length(v_x) > 0 then
            v_items := v_items || jsonb_build_array(jsonb_build_object('mg1', c.mg1, 'mg2', c.mg2, 'mg3', c.mg3,
                                                                       'desk', m.nama_produk, 'rows', v_x));
          end if;
        end loop;
        if jsonb_array_length(v_items) = 0 and jsonb_array_length(v_mgrows) > 0 then
          v_rows := v_rows || jsonb_build_array(jsonb_build_object('tid', t.target_id, 'grup', t.grup, 'nama', t.nama, 'tipe', t.tipe,
            'status', 'ERROR', 'flags', jsonb_build_array('ERROR_LEVEL'), 'mg', v_mg,
            'ket', 'MG ' || v_mg || ' wajib level kemasan, tetapi kombinasi MG1/MG2 belum ada di MASTER_MATERIAL',
            'f', jsonb_build_object('CONDITION_TYPE', p_ct, 'TARGET', t.kode, 'MG', v_mg, 'DESCRIPTION', m.nama_produk)));
        end if;
      elsif jsonb_array_length(v_mgrows) > 0 then
        v_items := jsonb_build_array(jsonb_build_object('desk', m.nama_produk, 'rows', v_mgrows));
      end if;

      for v_x in select x from jsonb_array_elements(v_r) x
                  where x->>'material' is not null
                    and not exists(select 1 from disc.master_material mt where mt.material = x->>'material') loop
        v_rows := v_rows || jsonb_build_array(jsonb_build_object('tid', t.target_id, 'grup', t.grup, 'nama', t.nama, 'tipe', t.tipe,
          'status', 'ERROR', 'flags', jsonb_build_array('ERROR_MG'), 'mg', v_mg, 'material', v_x->>'material',
          'ket', 'MATERIAL ' || (v_x->>'material') || ' tidak ada di MASTER_MATERIAL',
          'f', jsonb_build_object('CONDITION_TYPE', p_ct, 'TARGET', t.kode, 'MATERIAL', v_x->>'material', 'DESCRIPTION', '-')));
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
        v_items := v_items || jsonb_build_array(jsonb_build_object('material', mm.material, 'desk', mm.deskripsi, 'rows', v_x));
      end loop;

      -- KECUALIKAN_MATERIAL: material yang memakai MG sama ditulis di level material dengan Amount = NILAI.
      if exists(select 1 from jsonb_array_elements(v_items) i where not (i ? 'material')) then
        for e in select e2.material, e2.nilai, e2.catatan, mt.deskripsi from disc.pengecualian e2
                   join disc.master_material mt on mt.material = e2.material
                  where e2.diganti_pada is null and e2.jenis = 'KECUALIKAN_MATERIAL' and mt.mg = v_mg
                    and (e2.periode is null or e2.periode = p_periode) and (e2.condition_type is null or e2.condition_type = p_ct)
                    and (e2.target is null or e2.target = t.target_id or e2.target = t.grup)
                    and not exists(select 1 from jsonb_array_elements(v_items) i where i->>'material' = e2.material)
                  order by e2.material loop
          v_items := v_items || jsonb_build_array(jsonb_build_object('material', e.material, 'desk', e.deskripsi,
            'tetap', coalesce(disc.angka(e.nilai), 0), 'catatan', e.catatan,
            'dari', (select min((x->>'dari')::date) from jsonb_array_elements(v_r) x),
            'sampai', (select max((x->>'sampai')::date) from jsonb_array_elements(v_r) x)));
        end loop;
      end if;

      for it in select value from jsonb_array_elements(v_items) loop
        v_level := disc.level_item(t.tipe, it->>'material', it->>'mg1', it->>'mg2', it->>'mg3');
        v_sheet := (select k.sheet_tujuan from disc.template_kolom k where k.level = v_level limit 1);
        v_desk := it->>'desk';
        if it ? 'tetap' then
          v_tiers := jsonb_build_array(jsonb_build_object('scale', null, 'uom', null, 'komponen', '[]'::jsonb,
                       'amount', it->'tetap', 'dari', it->'dari', 'sampai', it->'sampai'));
        else
          v_tiers := '[]';
          v_b := array(select distinct d from (
                   select (x->>'dari')::date d from jsonb_array_elements(it->'rows') x
                   union select (x->>'sampai')::date + 1 from jsonb_array_elements(it->'rows') x) z order by 1);
          for v_i in 1 .. cardinality(v_b) - 1 loop
            v_d1 := v_b[v_i]; v_d2 := v_b[v_i + 1] - 1;
            v_aktif := (select jsonb_agg(x) from jsonb_array_elements(it->'rows') x
                         where (x->>'dari')::date <= v_d1 and (x->>'sampai')::date >= v_d2);
            if v_aktif is null then continue; end if;
            v_tiers := v_tiers || (select coalesce(jsonb_agg(g || jsonb_build_object('dari', v_d1, 'sampai', v_d2)), '[]')
                                     from jsonb_array_elements(disc.gabung(v_aktif, v_mode)) g);
          end loop;
        end if;

        for tr in select value from jsonb_array_elements(v_tiers) loop
          v_komp := coalesce(tr->'komponen', '[]');
          v_amount := (tr->>'amount')::numeric;
          v_scale := (tr->>'scale')::numeric;
          v_uom := tr->>'uom';
          v_flags := '{}'; v_ket := '{}'; v_lama := null;

          if v_sheet is null or not (v_level = any(a.level_boleh)) then
            v_flags := v_flags || 'ERROR_LEVEL'::text;
            v_ket := v_ket || ('Level ' || v_level || ' tidak ada di LEVEL_BOLEH ' || p_ct);
          end if;
          if (select count(distinct x->>'uom') from jsonb_array_elements(v_komp) x where x->>'uom' is not null) > 1 then
            v_flags := v_flags || 'ERROR_UOM_CT'::text; v_ket := v_ket || 'Satuan scale komponen berbeda-beda'::text;
          elsif a.uom_scale is not null and exists(select 1 from jsonb_array_elements(v_komp) x
                                                    where x->>'uom' is not null and x->>'uom' <> a.uom_scale) then
            v_flags := v_flags || 'ERROR_UOM_CT'::text;
            v_ket := v_ket || ('Satuan ' || (select x->>'uom' from jsonb_array_elements(v_komp) x where x->>'uom' <> a.uom_scale limit 1)
                               || ' tidak cocok dengan ' || p_ct || ' (' || a.uom_scale || ')');
          end if;
          if v_uom_eff is not null and exists(select 1 from jsonb_array_elements(v_komp) x
                                               where x->>'uom' is not null and x->>'uom' <> v_uom_eff) then
            v_flags := v_flags || 'CEK_UOM'::text;
            v_ket := v_ket || ('Satuan scale beda dengan master ' || v_mg || ' (' || v_uom_eff || ')');
          end if;
          if exists(select 1 from jsonb_array_elements(v_komp) x where (x->>'cekwil')::boolean) then
            v_flags := v_flags || 'CEK_WILAYAH'::text;
            v_ket := v_ket || ('Kebijakan hanya untuk ' || (select string_agg(distinct x->>'wilayah', ', ') from jsonb_array_elements(v_komp) x
                                                            where (x->>'cekwil')::boolean) || '; pastikan target pantek sesuai');
          end if;
          if a.batas_amount is not null and v_amount > a.batas_amount then
            v_flags := v_flags || 'CEK_PERSEN'::text;
            v_ket := v_ket || ('Amount ' || disc.pct(v_amount) || ' di atas batas ' || disc.pct(a.batas_amount));
          end if;
          if it ? 'tetap' then
            v_flags := v_flags || 'CEK_PENGECUALIAN'::text;
            v_ket := v_ket || ('Material dikecualikan dari disc MG ' || v_mg);
          end if;

          v_kunci := concat_ws('|', v_level, p_ct, t.kode, t.cg, v_mg, coalesce(it->>'mg1', ''), coalesce(it->>'mg2', ''),
                               coalesce(it->>'mg3', ''), coalesce(it->>'material', ''), coalesce(disc.pct(v_scale), ''), coalesce(v_uom, ''));
          select b.amount into v_lama from disc.generate_baris b join disc.generate_run r on r.id = b.run_id
           where b.kunci = v_kunci and b.valid_to = (tr->>'dari')::date - 1 order by r.dibuat_pada desc limit 1;
          if v_lama is not null and v_lama <> v_amount then
            v_flags := v_flags || 'BERUBAH'::text; v_ket := v_ket || ('Amount sebelumnya ' || disc.pct(v_lama));
          else
            v_lama := null;
          end if;

          v_r1 := disc.rincian(v_komp);
          if v_mode = 'PER_SCALE' and v_scale is not null then
            v_r1 := 'scale ' || disc.pct(v_scale) || coalesce(' ' || v_uom, '') || ' (' || v_r1 || ')';
          end if;
          v_cat := (select string_agg(distinct x->>'catatan', '; ') from jsonb_array_elements(v_komp) x where nullif(x->>'catatan', '') is not null);
          if it ? 'tetap' then v_r1 := 'Dikecualikan dari disc MG ' || v_mg; v_cat := it->>'catatan'; end if;
          v_r1 := concat_ws('; ', nullif(v_r1, ''), v_cat);
          v_dt := case when it ? 'tetap' then 'Pengecualian Material' else disc.disc_type(v_komp, v_mode) end;
          v_r2awal := case when v_mode = 'OPEN_QTY' then 'Open Qty' end;
          v_r2akhir := nullif(concat_ws(', ',
            case when t.aturan_disc = 'OPEN_QTY_TANPA_BULK' then 'tanpa Bulk' end,
            (select string_agg(distinct 'tanpa ' || disc.label_jenis(upper(e2.nilai)), ', ') from disc.pengecualian e2
              where e2.diganti_pada is null and e2.jenis = 'TANPA_KOMPONEN'
                and (e2.periode is null or e2.periode = p_periode) and (e2.condition_type is null or e2.condition_type = p_ct)
                and (e2.target is null or e2.target = t.target_id or e2.target = t.grup)
                and ((e2.material is not null and e2.material = it->>'material') or (e2.material is null and e2.mg = v_mg))),
            (select 'Memo ' || string_agg(distinct x->>'memo', ', ') from jsonb_array_elements(v_komp) x)), '');
          v_status := case when exists(select 1 from unnest(v_flags) f where f like 'ERROR%') then 'ERROR'
                           when cardinality(v_flags) > 0 then 'CEK' else 'OK' end;

          v_rows := v_rows || jsonb_build_array(jsonb_build_object(
            'tid', t.target_id, 'grup', t.grup, 'nama', t.nama, 'tipe', t.tipe, 'kosong', t.kosong,
            'level', v_level, 'sheet', v_sheet, 'kunci', v_kunci, 'status', v_status, 'flags', to_jsonb(v_flags),
            'ket', array_to_string(v_ket, '; '), 'mg', v_mg, 'material', it->>'material',
            'mg1', it->>'mg1', 'mg2', it->>'mg2', 'mg3', it->>'mg3',
            'amount', v_amount, 'amountLama', v_lama, 'scale', v_scale, 'uom', v_uom,
            'dari', tr->>'dari', 'sampai', tr->>'sampai', 'r2awal', v_r2awal, 'r2akhir', v_r2akhir,
            'gk', concat_ws('|', v_level, t.cg, v_mg, coalesce(it->>'mg1', ''), coalesce(it->>'mg2', ''), coalesce(it->>'mg3', ''),
                            coalesce(it->>'material', ''), coalesce(disc.pct(v_scale), ''), coalesce(v_uom, ''), tr->>'dari', tr->>'sampai',
                            disc.pct(v_amount), coalesce(v_r1, ''), coalesce(v_dt, ''), coalesce(v_r2akhir, '')),
            'f', jsonb_build_object('CONDITION_TYPE', p_ct, 'TARGET', t.kode, 'CUST_GROUP', t.cg, 'MG', v_mg,
                   'MG1', coalesce(it->>'mg1', ''), 'MG2', coalesce(it->>'mg2', ''), 'MG3', coalesce(it->>'mg3', ''),
                   'MATERIAL', coalesce(it->>'material', ''), 'DESCRIPTION', v_desk, 'AMOUNT', disc.pct(v_amount),
                   'UNIT_AMOUNT', '', 'PER', '', 'KOSONG', '', 'CHECK', '',
                   'UOM', case when v_scale is not null and a.kolom_satuan = 'UOM' then coalesce(v_uom, '') else '' end,
                   'VALID_FROM', disc.tgl_teks((tr->>'dari')::date), 'VALID_TO', disc.tgl_teks((tr->>'sampai')::date),
                   'SCALE_QTY', coalesce(disc.pct(v_scale), ''),
                   'SCALE_UNIT', case when v_scale is not null and a.kolom_satuan = 'UNIT' then coalesce(v_uom, '') else '' end,
                   'DISC_TYPE', coalesce(v_dt, ''), 'CREATED_ON', v_hari, 'REMARK1', coalesce(v_r1, ''),
                   'REMARK2', concat_ws(', ', v_r2awal, case when not t.kosong then t.nama end, v_r2akhir))));
        end loop;
      end loop;
    end loop;
  end loop;

  return jsonb_build_object('rows', v_rows, 'targets', v_targets, 'lewat', to_jsonb(v_lewat));
end $f$;

-- ---- RPC Generate ---------------------------------------------------------------------------
create or replace function public.rc_disc_generate(p_periode text, p_ct text, p_targets text[], p_komponen text[] default null,
  p_per_grup boolean default false, p_sumber text default 'SEMUA', p_catat boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare
  a disc.aturan_ct; v_komp text[]; v_inti jsonb; v_rows jsonb; v_hasil jsonb; v_g text; v_gk text; v_list jsonb;
  v_first jsonb; v_label text; v_n integer; v_exc text; v_tids text[]; v_flags jsonb; v_run uuid; v_ring jsonb;
  v_sumber text := upper(coalesce(nullif(btrim(p_sumber), ''), 'SEMUA'));
begin
  perform rc_private.require_tab('discount.generate');
  if p_periode is null or p_periode !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Periode harus YYYY-MM'; end if;
  select * into a from disc.aturan_ct where condition_type = btrim(coalesce(p_ct, ''));
  if not found then raise exception 'Condition type % tidak ada di ATURAN_CT', p_ct; end if;
  if coalesce(cardinality(p_targets), 0) = 0 then raise exception 'Pilih target dulu'; end if;
  if v_sumber not in ('SEMUA', 'KHUSUS') then raise exception 'Sumber baris harus SEMUA atau KHUSUS'; end if;
  v_komp := array(select distinct upper(btrim(x)) from unnest(coalesce(p_komponen, a.komponen)) x
                   where upper(btrim(x)) in ('VOL','CMP','BULK','BP','PROMO','LAIN'));
  if cardinality(v_komp) = 0 then raise exception 'Pilih minimal satu komponen disc'; end if;

  v_inti := disc.generate_inti(p_periode, a.condition_type, p_targets, v_komp, v_sumber);
  v_rows := v_inti->'rows';

  -- Per grup: target satu grup dengan baris identik digabung, kolom target = LABEL_OUTPUT.
  if coalesce(p_per_grup, false) then
    v_hasil := coalesce((select jsonb_agg(x) from jsonb_array_elements(v_rows) x
                          where x->>'grup' is null or x->>'status' = 'ERROR'), '[]');
    for v_g, v_gk, v_list in
      select x->>'grup', x->>'gk', jsonb_agg(x order by x->>'tid') from jsonb_array_elements(v_rows) x
       where x->>'grup' is not null and x->>'status' <> 'ERROR' group by 1, 2
    loop
      if jsonb_array_length(v_list) = 1 then v_hasil := v_hasil || v_list; continue; end if;
      v_first := v_list->0;
      v_tids := array(select x->>'tid' from jsonb_array_elements(v_list) x);
      v_label := coalesce((select tg.label_output from disc.target tg where tg.grup = v_g and tg.label_output is not null
                            order by tg.target_id limit 1), v_g);
      v_n := (select count(*) from jsonb_array_elements(v_inti->'targets') tt where tt->>'grup' = v_g);
      v_exc := (select string_agg(tt->>'nama', ', ' order by tt->>'nama') from jsonb_array_elements(v_inti->'targets') tt
                 where tt->>'grup' = v_g and not (tt->>'tid' = any(v_tids)));
      v_flags := (select coalesce(jsonb_agg(distinct f), '[]') from jsonb_array_elements(v_list) x, jsonb_array_elements_text(x->'flags') f);
      v_hasil := v_hasil || jsonb_build_array(v_first || jsonb_build_object('tid', null, 'tids', to_jsonb(v_tids), 'nama', v_label,
        'flags', v_flags, 'status', case when jsonb_array_length(v_flags) > 0 then 'CEK' else 'OK' end,
        'amountLama', (select max((x->>'amountLama')::numeric) from jsonb_array_elements(v_list) x),
        'f', (v_first->'f') || jsonb_build_object('TARGET', v_label, 'CUST_GROUP', v_first->'f'->>'CUST_GROUP',
               'REMARK2', concat_ws(', ', v_first->>'r2awal',
                 'List ' || v_label || ' (' || v_n || case when v_first->>'tipe' = 'CUSTOMER' then ' toko' else ' target' end || ')'
                   || coalesce(', exc ' || v_exc, ''),
                 v_first->>'r2akhir'))));
    end loop;
    v_rows := v_hasil;
  end if;

  -- DOBEL: kunci sama (target, CustGrp, item, scale) dengan masa berlaku bertumpuk.
  v_rows := (with r as (select x, i, concat_ws('|', x->>'level', x->'f'->>'TARGET', x->'f'->>'CUST_GROUP', x->>'mg',
                                               coalesce(x->>'mg1', ''), coalesce(x->>'mg2', ''), coalesce(x->>'mg3', ''),
                                               coalesce(x->>'material', ''), coalesce(x->>'scale', ''), coalesce(x->>'uom', '')) k
                           from jsonb_array_elements(v_rows) with ordinality q(x, i))
             select coalesce(jsonb_agg(case when r.x->>'status' <> 'ERROR' and exists(
                        select 1 from r r2 where r2.i <> r.i and r2.k = r.k and r2.x->>'status' <> 'ERROR'
                           and (r2.x->>'dari')::date <= (r.x->>'sampai')::date and (r2.x->>'sampai')::date >= (r.x->>'dari')::date)
                      then r.x || jsonb_build_object('flags', (r.x->'flags') || '["DOBEL"]'::jsonb, 'status', 'CEK',
                                                     'ket', concat_ws('; ', nullif(r.x->>'ket', ''), 'Kunci sama muncul lebih dari sekali'))
                      else r.x end), '[]') from r);

  v_rows := (select coalesce(jsonb_agg(x order by x->>'status' = 'ERROR', coalesce(x->>'sheet', '~'), x->'f'->>'TARGET',
                                       x->>'mg', coalesce(x->>'mg2', ''), coalesce(x->>'mg1', ''), coalesce(x->>'material', ''),
                                       x->>'dari', (x->>'scale')::numeric nulls first), '[]')
               from jsonb_array_elements(v_rows) x);

  v_ring := jsonb_build_object(
    'baris', (select count(*) from jsonb_array_elements(v_rows) x where x->>'status' <> 'ERROR'),
    'error', (select count(*) from jsonb_array_elements(v_rows) x where x->>'status' = 'ERROR'),
    'cek', (select count(*) from jsonb_array_elements(v_rows) x where x->>'status' = 'CEK'),
    'berubah', (select count(*) from jsonb_array_elements(v_rows) x where x->'flags' ? 'BERUBAH'),
    'dobel', (select count(*) from jsonb_array_elements(v_rows) x where x->'flags' ? 'DOBEL'),
    'perSheet', coalesce((select jsonb_object_agg(s, n) from (select x->>'sheet' s, count(*) n from jsonb_array_elements(v_rows) x
                                                              where x->>'status' <> 'ERROR' group by 1) z), '{}'),
    'target', jsonb_array_length(v_inti->'targets'), 'dilewati', v_inti->'lewat');

  if coalesce(p_catat, false) then
    insert into disc.generate_run(periode, condition_type, target, komponen, per_grup, baris, ringkas, dibuat_oleh)
    values (p_periode, a.condition_type, array_to_string(p_targets, ','), v_komp, coalesce(p_per_grup, false),
            (v_ring->>'baris')::integer, v_ring, auth.uid())
    returning id into v_run;
    insert into disc.generate_baris(run_id, kunci, level, condition_type, target_kode, mg, material, amount, scale_qty, scale_uom,
                                    valid_from, valid_to)
    select v_run, x->>'kunci', x->>'level', a.condition_type, x->'f'->>'TARGET', x->>'mg', x->>'material', (x->>'amount')::numeric,
           (x->>'scale')::numeric, x->>'uom', (x->>'dari')::date, (x->>'sampai')::date
      from jsonb_array_elements(v_inti->'rows') x where x->>'status' <> 'ERROR' and x->>'kunci' is not null;
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'discount_generate', jsonb_build_object(
              'detail', 'Discount Center: generate ' || a.condition_type || ' periode ' || p_periode || ' - ' || (v_ring->>'baris')
                        || ' baris, ' || (v_ring->>'error') || ' error',
              'run', v_run, 'target', to_jsonb(p_targets), 'komponen', to_jsonb(v_komp), 'per_grup', coalesce(p_per_grup, false),
              'sumber', v_sumber, 'ringkas', v_ring),
            'Discount Center', 'Generate', 'Generate');
  end if;

  return jsonb_build_object('status', 'success', 'periode', p_periode, 'ct', a.condition_type, 'mode', a.mode_hitung,
    'komponen', to_jsonb(v_komp), 'sumber', v_sumber, 'perGrup', coalesce(p_per_grup, false), 'rows', v_rows, 'ringkas', v_ring,
    'run', v_run);
end $f$;

revoke all on all functions in schema disc from public, anon, authenticated;
revoke all on function public.rc_disc_generate(text, text, text[], text[], boolean, text, boolean) from public, anon;
grant execute on function public.rc_disc_generate(text, text, text[], text[], boolean, text, boolean) to authenticated;
