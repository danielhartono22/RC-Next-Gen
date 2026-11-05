-- ==========================================================================================
-- Discount Center: unggah dan validasi sheet input (spesifikasi bagian 2-3), daftar data, konfigurasi.
-- Bergantung pada 20261163310000 dan 20261163320000.
-- ==========================================================================================
-- Satu panggilan = satu sheet (layar mengirim berurutan: MASTER_MG, MASTER_MATERIAL, TARGET,
-- ATURAN_CT, PENGECUALIAN, KEBIJAKAN). p_simpan = false hanya memeriksa (Pratinjau), true menyimpan.
-- p_konteks memuat kode dari sheet lain di berkas yang sama ({"mg": {kode: {uom, level}},
-- "material": {kode: mg}, "target": [..], "grup": [..]}), supaya Pratinjau KEBIJAKAN mengenali master
-- baru yang belum tersimpan. Baris berstatus ERROR tidak diproses; baris CEK tetap disimpan.
--  * Master (MG, Material, Target, Aturan CT): disisipkan / diperbarui per kunci (tidak dihapus;
--    pakai AKTIF = N untuk menonaktifkan).
--  * PENGECUALIAN: sheet yang diunggah menggantikan seluruh daftar (yang lama diarsipkan).
--  * KEBIJAKAN: menggantikan kebijakan periode yang ada di berkas (yang lama diarsipkan, tidak
--    dihapus).
-- ==========================================================================================

create or replace function disc.unggah_proses(p_sheet text, p_rows jsonb, p_konteks jsonb, p_simpan boolean)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare
  r jsonb; v_baris integer; v_pesan jsonb := '[]'; n_ok integer := 0; n_cek integer := 0; n_err integer := 0;
  v_err text[]; v_cek text[]; v_seen text[] := '{}'; v_aktor uuid := auth.uid(); v_kunci text;
  v_mg text; v_mat text; v_nama text; v_segmen text; v_jp text; v_uom text; v_lvl text; v_aktif text;
  v_tipe text; v_kode text; v_cg text; v_dc text; v_grup text; v_atur text; v_label text;
  v_ct text; v_tt text[]; v_lb text[]; v_mode text; v_komp text[]; v_kolsat text; v_batas numeric;
  v_jenis text; v_nilai text; v_periode text; v_qty numeric; v_suom text; v_disc numeric; v_dari date; v_sampai date;
  v_wil text[]; v_untuk text; v_master_uom text; v_mat_mg text; v_valid jsonb := '[]'; v_periodes text[] := '{}';
  v_level_dikenal text[] := array(select distinct level from disc.template_kolom);
  -- Konteks hanya untuk Pratinjau; saat simpan, master dari sheet lain sudah tersimpan lebih dulu.
  v_k jsonb := case when p_simpan then '{}'::jsonb else coalesce(p_konteks, '{}') end;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'Data sheet harus berupa daftar baris'; end if;
  if jsonb_array_length(p_rows) > 5000 then raise exception 'Satu kiriman maksimal 5000 baris; pecah unggahannya.'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_baris := coalesce((r->>'__BARIS')::integer, 0); v_err := '{}'; v_cek := '{}';

    if p_sheet = 'MASTER_MG' then
      v_mg := disc.kode(r->>'MG'); v_nama := nullif(btrim(r->>'NAMA_PRODUK'), ''); v_segmen := disc.kode(r->>'SEGMEN');
      v_jp := disc.kode(r->>'JENIS_PRODUK'); v_uom := disc.kode(r->>'UOM_SCALE'); v_lvl := coalesce(disc.kode(r->>'LEVEL_WAJIB'), 'MG');
      v_aktif := coalesce(disc.kode(r->>'AKTIF'), 'Y');
      if v_mg is null then v_err := v_err || text 'MG wajib diisi'; end if;
      if v_mg = any(v_seen) then v_err := v_err || ('MG ' || v_mg || ' dobel di berkas'); end if;
      if v_nama is null then v_err := v_err || text 'NAMA_PRODUK wajib diisi'; end if;
      if v_segmen is null or v_segmen not in ('DEKORATIF','PAINTING TOOLS','CAT SEMPROT','LAIN-LAIN') then
        v_err := v_err || text 'SEGMEN harus DEKORATIF, PAINTING TOOLS, CAT SEMPROT, atau LAIN-LAIN'; end if;
      if v_jp is not null and v_jp not in ('READY MIX','CCM') then v_err := v_err || text 'JENIS_PRODUK harus READY MIX atau CCM'; end if;
      if v_jp is null then v_jp := case when v_mg ~ '^ZCCM' then 'CCM' else 'READY MIX' end;
        v_cek := v_cek || ('JENIS_PRODUK kosong, diisi ' || v_jp); end if;
      if v_uom is null or v_uom not in ('KG','L','PC') then v_err := v_err || text 'UOM_SCALE harus KG, L, atau PC'; end if;
      if v_lvl not in ('MG','KEMASAN') then v_err := v_err || text 'LEVEL_WAJIB harus MG atau KEMASAN'; end if;
      if v_aktif not in ('Y','N') then v_err := v_err || text 'AKTIF harus Y atau N'; end if;
      v_seen := v_seen || coalesce(v_mg, '');
      if cardinality(v_err) = 0 and p_simpan then
        insert into disc.master_mg(mg, nama_produk, alias, segmen, jenis_produk, uom_scale, level_wajib, aktif, diubah_pada, diubah_oleh)
        values (v_mg, v_nama, nullif(btrim(r->>'ALIAS'), ''), v_segmen, v_jp, v_uom, v_lvl, v_aktif = 'Y', now(), v_aktor)
        on conflict (mg) do update set nama_produk = excluded.nama_produk, alias = excluded.alias, segmen = excluded.segmen,
          jenis_produk = excluded.jenis_produk, uom_scale = excluded.uom_scale, level_wajib = excluded.level_wajib,
          aktif = excluded.aktif, diubah_pada = now(), diubah_oleh = v_aktor;
      end if;

    elsif p_sheet = 'MASTER_MATERIAL' then
      v_mat := disc.kode(r->>'MATERIAL'); v_nama := nullif(btrim(r->>'DESKRIPSI'), ''); v_mg := disc.kode(r->>'MG');
      v_aktif := coalesce(disc.kode(r->>'AKTIF'), 'Y');
      if v_mat is null then v_err := v_err || text 'MATERIAL wajib diisi'; end if;
      if v_mat = any(v_seen) then v_err := v_err || ('MATERIAL ' || v_mat || ' dobel di berkas'); end if;
      if v_nama is null then v_err := v_err || text 'DESKRIPSI wajib diisi'; end if;
      if v_mg is null then v_err := v_err || text 'MG wajib diisi';
      elsif not exists(select 1 from disc.master_mg m where m.mg = v_mg) and not coalesce(v_k->'mg', '{}') ? v_mg then
        v_err := v_err || ('ERROR_MG: MG ' || v_mg || ' tidak ada di MASTER_MG'); end if;
      if v_aktif not in ('Y','N') then v_err := v_err || text 'AKTIF harus Y atau N'; end if;
      v_seen := v_seen || coalesce(v_mat, '');
      if cardinality(v_err) = 0 and p_simpan then
        insert into disc.master_material(material, deskripsi, mg, mg1, mg2, mg3, aktif, diubah_pada, diubah_oleh)
        values (v_mat, v_nama, v_mg, disc.kode(r->>'MG1'), disc.kode(r->>'MG2'), disc.kode(r->>'MG3'), v_aktif = 'Y', now(), v_aktor)
        on conflict (material) do update set deskripsi = excluded.deskripsi, mg = excluded.mg, mg1 = excluded.mg1,
          mg2 = excluded.mg2, mg3 = excluded.mg3, aktif = excluded.aktif, diubah_pada = now(), diubah_oleh = v_aktor;
      end if;

    elsif p_sheet = 'TARGET' then
      v_kunci := disc.kode(r->>'TARGET_ID'); v_tipe := disc.kode(r->>'TIPE'); v_kode := nullif(btrim(r->>'KODE'), '');
      v_cg := nullif(btrim(r->>'CUST_GROUP'), ''); v_nama := nullif(btrim(r->>'NAMA'), ''); v_dc := disc.kode(r->>'DC');
      v_grup := disc.kode(r->>'GRUP'); v_atur := coalesce(disc.kode(r->>'ATURAN_DISC'), 'NORMAL');
      v_label := nullif(btrim(r->>'LABEL_OUTPUT'), ''); v_aktif := coalesce(disc.kode(r->>'AKTIF'), 'Y');
      if v_kunci is null then v_err := v_err || text 'TARGET_ID wajib diisi'; end if;
      if v_kunci = any(v_seen) then v_err := v_err || ('TARGET_ID ' || v_kunci || ' dobel di berkas'); end if;
      if v_tipe is null or v_tipe not in ('CUSTOMER','SLS_OFFICE','SLS_ORG','COND_GROUP2') then
        v_err := v_err || text 'TIPE harus CUSTOMER, SLS_OFFICE, SLS_ORG, atau COND_GROUP2'; end if;
      if v_kode is null then v_err := v_err || text 'KODE wajib diisi'; end if;
      if v_cg is not null and v_cg ~ '^\d$' then v_cek := v_cek || ('CUST_GROUP ' || v_cg || ' ditulis 0' || v_cg); v_cg := '0' || v_cg; end if;
      if v_cg is null and v_tipe is distinct from 'CUSTOMER' then v_err := v_err || text 'CUST_GROUP wajib untuk tipe selain CUSTOMER'; end if;
      if v_nama is null then v_err := v_err || text 'NAMA wajib diisi'; end if;
      if v_dc is not null and not exists(select 1 from public.depots d where upper(d.depot_code) = v_dc and d.archived_at is null) then
        v_err := v_err || ('DC ' || v_dc || ' tidak ada di Depot Master'); end if;
      if v_atur not in ('OPEN_QTY','OPEN_QTY_TANPA_BULK','NORMAL') then v_err := v_err || text 'ATURAN_DISC harus OPEN_QTY, OPEN_QTY_TANPA_BULK, atau NORMAL'; end if;
      if v_aktif not in ('Y','N') then v_err := v_err || text 'AKTIF harus Y atau N'; end if;
      v_seen := v_seen || coalesce(v_kunci, '');
      if cardinality(v_err) = 0 and p_simpan then
        insert into disc.target(target_id, tipe, kode, cust_group, nama, dc, grup, aturan_disc, label_output, aktif, diubah_pada, diubah_oleh)
        values (v_kunci, v_tipe, v_kode, v_cg, v_nama, v_dc, v_grup, v_atur, v_label, v_aktif = 'Y', now(), v_aktor)
        on conflict (target_id) do update set tipe = excluded.tipe, kode = excluded.kode, cust_group = excluded.cust_group,
          nama = excluded.nama, dc = excluded.dc, grup = excluded.grup, aturan_disc = excluded.aturan_disc,
          label_output = excluded.label_output, aktif = excluded.aktif, diubah_pada = now(), diubah_oleh = v_aktor;
      end if;

    elsif p_sheet = 'ATURAN_CT' then
      -- Kode condition type dibaca sebagai teks persis (hanya spasi tepi dibuang): RA01 bukan ra01.
      v_ct := nullif(btrim(r->>'CONDITION_TYPE'), '');
      v_tt := array(select disc.kode(x) from regexp_split_to_table(coalesce(r->>'TIPE_TARGET', ''), ',') x where btrim(x) <> '');
      v_lb := array(select disc.kode(x) from regexp_split_to_table(coalesce(r->>'LEVEL_BOLEH', ''), ',') x where btrim(x) <> '');
      v_mode := disc.kode(r->>'MODE_HITUNG');
      v_komp := array(select disc.kode(x) from regexp_split_to_table(coalesce(r->>'KOMPONEN', ''), ',') x where btrim(x) <> '');
      v_uom := disc.kode(r->>'UOM_SCALE'); v_kolsat := coalesce(disc.kode(r->>'KOLOM_SATUAN'), 'UOM');
      v_batas := disc.angka(r->>'BATAS_AMOUNT'); v_aktif := coalesce(disc.kode(r->>'AKTIF'), 'Y');
      if v_ct is null then v_err := v_err || text 'CONDITION_TYPE wajib diisi'; end if;
      if v_ct = any(v_seen) then v_err := v_err || ('CONDITION_TYPE ' || v_ct || ' dobel di berkas'); end if;
      if exists(select 1 from unnest(v_tt) x where x not in ('CUSTOMER','SLS_OFFICE','SLS_ORG','COND_GROUP2')) then
        v_err := v_err || text 'TIPE_TARGET berisi nilai di luar CUSTOMER, SLS_OFFICE, SLS_ORG, COND_GROUP2'; end if;
      if exists(select 1 from unnest(v_lb) x where not (x = any(v_level_dikenal))) then
        v_err := v_err || ('LEVEL_BOLEH tidak dikenal: ' || (select string_agg(x, ', ') from unnest(v_lb) x where not (x = any(v_level_dikenal)))); end if;
      if v_mode is not null and v_mode not in ('OPEN_QTY','PER_SCALE','FLAT') then v_err := v_err || text 'MODE_HITUNG harus OPEN_QTY, PER_SCALE, atau FLAT'; end if;
      if v_mode is null then v_cek := v_cek || text 'MODE_HITUNG kosong: condition type ini belum dapat di-generate'; end if;
      if exists(select 1 from unnest(v_komp) x where x not in ('VOL','CMP','BULK','BP','PROMO','LAIN')) then
        v_err := v_err || text 'KOMPONEN berisi nilai di luar VOL, CMP, BULK, BP, PROMO, LAIN'; end if;
      if v_uom is not null and v_uom not in ('KG','L','PC','-') then v_err := v_err || text 'UOM_SCALE harus KG, L, PC, atau -'; end if;
      if v_kolsat not in ('UOM','UNIT') then v_err := v_err || text 'KOLOM_SATUAN harus UOM atau UNIT'; end if;
      if nullif(btrim(r->>'BATAS_AMOUNT'), '') is not null and v_batas is null then v_err := v_err || text 'BATAS_AMOUNT harus angka'; end if;
      if v_aktif not in ('Y','N') then v_err := v_err || text 'AKTIF harus Y atau N'; end if;
      v_seen := v_seen || coalesce(v_ct, '');
      if cardinality(v_err) = 0 and p_simpan then
        insert into disc.aturan_ct(condition_type, kegunaan, tipe_target, level_boleh, mode_hitung, komponen, uom_scale, kolom_satuan,
                                   disc_type_label, batas_amount, aktif, diubah_pada, diubah_oleh)
        values (v_ct, nullif(btrim(r->>'KEGUNAAN'), ''), v_tt, v_lb, v_mode, v_komp, nullif(v_uom, '-'), v_kolsat,
                nullif(btrim(r->>'DISC_TYPE_LABEL'), ''), v_batas, v_aktif = 'Y', now(), v_aktor)
        on conflict (condition_type) do update set kegunaan = excluded.kegunaan, tipe_target = excluded.tipe_target,
          level_boleh = excluded.level_boleh, mode_hitung = excluded.mode_hitung, komponen = excluded.komponen,
          uom_scale = excluded.uom_scale, kolom_satuan = excluded.kolom_satuan, disc_type_label = excluded.disc_type_label,
          batas_amount = excluded.batas_amount, aktif = excluded.aktif, diubah_pada = now(), diubah_oleh = v_aktor;
      end if;

    elsif p_sheet = 'PENGECUALIAN' then
      v_jenis := disc.kode(r->>'JENIS'); v_mg := disc.kode(r->>'MG'); v_mat := disc.kode(r->>'MATERIAL');
      v_nilai := nullif(btrim(r->>'NILAI'), ''); v_periode := nullif(btrim(r->>'PERIODE'), '');
      if v_jenis is null or v_jenis not in ('UOM_OVERRIDE','KECUALIKAN_MATERIAL','KHUSUS_WILAYAH','TANPA_KOMPONEN') then
        v_err := v_err || text 'JENIS harus UOM_OVERRIDE, KECUALIKAN_MATERIAL, KHUSUS_WILAYAH, atau TANPA_KOMPONEN'; end if;
      if v_mg is null and v_mat is null then v_err := v_err || text 'MG atau MATERIAL wajib diisi'; end if;
      if v_mg is not null and not exists(select 1 from disc.master_mg m where m.mg = v_mg) and not coalesce(v_k->'mg', '{}') ? v_mg then
        v_err := v_err || ('ERROR_MG: MG ' || v_mg || ' tidak ada di MASTER_MG'); end if;
      if v_mat is not null and not exists(select 1 from disc.master_material m where m.material = v_mat) and not coalesce(v_k->'material', '{}') ? v_mat then
        v_err := v_err || ('ERROR_MG: MATERIAL ' || v_mat || ' tidak ada di MASTER_MATERIAL'); end if;
      if v_jenis = 'KECUALIKAN_MATERIAL' and v_mat is null then v_err := v_err || text 'KECUALIKAN_MATERIAL butuh MATERIAL'; end if;
      if v_nilai is null then v_err := v_err || text 'NILAI wajib diisi'; end if;
      if v_jenis = 'UOM_OVERRIDE' and upper(coalesce(v_nilai, '')) not in ('KG','L','PC') then v_err := v_err || text 'NILAI UOM_OVERRIDE harus KG, L, atau PC'; end if;
      if v_jenis = 'TANPA_KOMPONEN' and upper(coalesce(v_nilai, '')) not in ('VOL','CMP','BULK','BP','PROMO','LAIN') then
        v_err := v_err || text 'NILAI TANPA_KOMPONEN harus VOL, CMP, BULK, BP, PROMO, atau LAIN'; end if;
      if v_jenis = 'KHUSUS_WILAYAH' and exists(select 1 from unnest(disc.token_wilayah(v_nilai)) x where x like '?%') then
        v_err := v_err || ('NILAI wilayah tidak dikenal: ' || v_nilai); end if;
      if v_periode is not null and v_periode !~ '^\d{4}-(0[1-9]|1[0-2])$' then v_err := v_err || text 'PERIODE harus YYYY-MM'; end if;
      if nullif(btrim(r->>'CATATAN'), '') is null then v_err := v_err || text 'CATATAN wajib diisi'; end if;
      if cardinality(v_err) = 0 then
        v_valid := v_valid || jsonb_build_array(jsonb_build_object('jenis', v_jenis, 'mg', v_mg, 'material', v_mat,
          'ct', nullif(btrim(r->>'CONDITION_TYPE'), ''), 'target', disc.kode(r->>'TARGET'),
          'nilai', case when v_jenis in ('UOM_OVERRIDE','TANPA_KOMPONEN') then upper(v_nilai) else v_nilai end,
          'periode', v_periode, 'catatan', btrim(r->>'CATATAN')));
      end if;

    elsif p_sheet = 'KEBIJAKAN' then
      v_periode := nullif(btrim(r->>'PERIODE'), ''); v_jenis := disc.kode(r->>'JENIS');
      v_mg := disc.kode(r->>'MG'); v_mat := disc.kode(r->>'MATERIAL');
      v_qty := disc.angka(r->>'SCALE_QTY'); v_suom := disc.kode(r->>'SCALE_UOM'); v_disc := disc.angka(r->>'DISC');
      v_dari := disc.tgl(r->>'VALID_FROM'); v_sampai := disc.tgl(r->>'VALID_TO');
      v_untuk := disc.kode(r->>'UNTUK_TARGET');
      if v_periode is null or v_periode !~ '^\d{4}-(0[1-9]|1[0-2])$' then v_err := v_err || text 'PERIODE harus YYYY-MM'; end if;
      if v_jenis is null or v_jenis not in ('VOL','CMP','BULK','BP','PROMO','LAIN','FAKTUR') then
        v_err := v_err || text 'JENIS harus VOL, CMP, BULK, BP, PROMO, LAIN, atau FAKTUR'; end if;
      if nullif(btrim(r->>'NO_MEMO'), '') is null then v_err := v_err || text 'NO_MEMO wajib diisi'; end if;
      if v_mg is null and v_mat is null then v_err := v_err || text 'MG wajib diisi (atau MATERIAL)'; end if;
      v_mat_mg := null;
      if v_mat is not null then
        v_mat_mg := coalesce((select m.mg from disc.master_material m where m.material = v_mat), v_k->'material'->>v_mat);
        if v_mat_mg is null then v_err := v_err || ('ERROR_MG: MATERIAL ' || v_mat || ' tidak ada di MASTER_MATERIAL');
        elsif v_mg is not null and v_mg <> v_mat_mg then v_err := v_err || ('ERROR_MG: MATERIAL ' || v_mat || ' milik MG ' || v_mat_mg || ', bukan ' || v_mg); end if;
      end if;
      if coalesce(v_mg, v_mat_mg) is not null and not exists(select 1 from disc.master_mg m where m.mg = coalesce(v_mg, v_mat_mg))
         and not coalesce(v_k->'mg', '{}') ? coalesce(v_mg, v_mat_mg) then
        v_err := v_err || ('ERROR_MG: MG ' || coalesce(v_mg, v_mat_mg) || ' tidak ada di MASTER_MG'); end if;
      if nullif(btrim(r->>'SCALE_QTY'), '') is not null and (v_qty is null or v_qty <= 0) then v_err := v_err || text 'SCALE_QTY harus angka > 0'; end if;
      if v_qty is not null and (v_suom is null or v_suom not in ('KG','L','PC')) then v_err := v_err || text 'SCALE_UOM wajib KG, L, atau PC bila ada scale'; end if;
      if v_qty is null and v_suom is not null then v_err := v_err || text 'SCALE_UOM diisi tanpa SCALE_QTY'; end if;
      if v_disc is null or v_disc <= 0 or v_disc >= 100 then v_err := v_err || text 'DISC harus angka persen (15 = 15%)'; end if;
      if v_dari is null or v_sampai is null then v_err := v_err || text 'ERROR_TANGGAL: VALID_FROM / VALID_TO harus dd.mm.yyyy';
      elsif v_dari > v_sampai then v_err := v_err || text 'ERROR_TANGGAL: VALID_FROM setelah VALID_TO'; end if;
      v_wil := disc.token_wilayah(r->>'WILAYAH');
      if exists(select 1 from unnest(v_wil) x where x like '?%') then
        v_err := v_err || ('WILAYAH tidak dikenal: ' || (select string_agg(substr(x, 2), ', ') from unnest(v_wil) x where x like '?%')
                           || ' (tulis NASIONAL, REGION <kode>, atau kode depot)'); end if;
      if v_untuk is not null and not exists(select 1 from disc.target t where t.target_id = v_untuk or t.grup = v_untuk)
         and not (coalesce(v_k->'target', '[]') ? v_untuk or coalesce(v_k->'grup', '[]') ? v_untuk) then
        v_err := v_err || ('UNTUK_TARGET ' || v_untuk || ' bukan TARGET_ID maupun GRUP di TARGET'); end if;
      -- Satuan scale berbeda dari master = CEK_UOM, kecuali ada UOM_OVERRIDE untuk MG itu.
      v_master_uom := coalesce((select m.uom_scale from disc.master_mg m where m.mg = coalesce(v_mg, v_mat_mg)),
                               v_k->'mg'->coalesce(v_mg, v_mat_mg, '')->>'uom');
      if v_suom is not null and v_master_uom is not null and v_suom <> v_master_uom
         and not exists(select 1 from disc.pengecualian e where e.diganti_pada is null and e.jenis = 'UOM_OVERRIDE'
                         and (e.mg = coalesce(v_mg, v_mat_mg) or e.material = v_mat) and upper(e.nilai) = v_suom) then
        v_cek := v_cek || ('CEK_UOM: satuan ' || v_suom || ', master ' || coalesce(v_mg, v_mat_mg) || ' ' || v_master_uom); end if;
      if cardinality(v_err) = 0 then
        v_periodes := array(select distinct x from unnest(v_periodes || v_periode) x);
        v_valid := v_valid || jsonb_build_array(jsonb_build_object('periode', v_periode, 'jenis', v_jenis, 'no_memo', btrim(r->>'NO_MEMO'),
          'mg', coalesce(v_mg, v_mat_mg), 'material', v_mat, 'mg1', disc.kode(r->>'MG1'), 'mg2', disc.kode(r->>'MG2'), 'mg3', disc.kode(r->>'MG3'),
          'qty', v_qty, 'uom', v_suom, 'disc', v_disc, 'dari', v_dari, 'sampai', v_sampai,
          'wilayah', array_to_string(v_wil, ','), 'untuk', v_untuk, 'catatan', nullif(btrim(r->>'CATATAN'), ''), 'baris', v_baris));
      end if;
    else
      raise exception 'Sheet % tidak dikenal', p_sheet;
    end if;

    if cardinality(v_err) > 0 then
      n_err := n_err + 1;
      if jsonb_array_length(v_pesan) < 1000 then
        v_pesan := v_pesan || jsonb_build_array(jsonb_build_object('baris', v_baris, 'status', 'ERROR', 'pesan', array_to_string(v_err, '; ')));
      end if;
    elsif cardinality(v_cek) > 0 then
      n_cek := n_cek + 1;
      if jsonb_array_length(v_pesan) < 1000 then
        v_pesan := v_pesan || jsonb_build_array(jsonb_build_object('baris', v_baris, 'status', 'CEK', 'pesan', array_to_string(v_cek, '; ')));
      end if;
    else
      n_ok := n_ok + 1;
    end if;
  end loop;

  if p_simpan and p_sheet = 'PENGECUALIAN' then
    update disc.pengecualian set diganti_pada = now() where diganti_pada is null;
    insert into disc.pengecualian(jenis, mg, material, condition_type, target, nilai, periode, catatan, dibuat_oleh)
    select x->>'jenis', x->>'mg', x->>'material', x->>'ct', x->>'target', x->>'nilai', x->>'periode', x->>'catatan', v_aktor
      from jsonb_array_elements(v_valid) x;
  elsif p_simpan and p_sheet = 'KEBIJAKAN' and cardinality(v_periodes) > 0 then
    update disc.kebijakan set diganti_pada = now() where diganti_pada is null and periode = any(v_periodes);
    insert into disc.kebijakan(periode, jenis, no_memo, mg, material, mg1, mg2, mg3, scale_qty, scale_uom, disc, valid_from, valid_to,
                               wilayah, untuk_target, catatan, baris_excel, dibuat_oleh)
    select x->>'periode', x->>'jenis', x->>'no_memo', x->>'mg', x->>'material', x->>'mg1', x->>'mg2', x->>'mg3',
           (x->>'qty')::numeric, x->>'uom', (x->>'disc')::numeric, (x->>'dari')::date, (x->>'sampai')::date,
           x->>'wilayah', x->>'untuk', x->>'catatan', (x->>'baris')::integer, v_aktor
      from jsonb_array_elements(v_valid) x;
  end if;

  if p_simpan then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (v_aktor, 'discount_unggah', jsonb_build_object('detail', 'Discount Center: unggah ' || p_sheet || ' - ' || n_ok + n_cek || ' baris disimpan, '
              || n_err || ' error', 'sheet', p_sheet, 'ok', n_ok, 'cek', n_cek, 'error', n_err, 'periode', to_jsonb(v_periodes)),
            'Discount Center', 'Kebijakan', 'Kebijakan');
  end if;

  return jsonb_build_object('status', 'success', 'sheet', p_sheet, 'total', jsonb_array_length(p_rows), 'ok', n_ok, 'cek', n_cek,
    'error', n_err, 'pesan', v_pesan, 'periode', to_jsonb(v_periodes), 'disimpan', p_simpan);
end $f$;

create or replace function public.rc_disc_unggah(p_sheet text, p_rows jsonb, p_konteks jsonb default '{}', p_simpan boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $f$
begin
  perform rc_private.require_tab('discount.kebijakan');
  return disc.unggah_proses(upper(btrim(coalesce(p_sheet, ''))), p_rows, p_konteks, coalesce(p_simpan, false));
end $f$;

-- Daftar isi sheet untuk tab Kebijakan (200 baris per halaman), beserta status validasinya saat ini.
create or replace function public.rc_disc_data(p_sheet text, p_periode text default null, p_cari text default '', p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare v_cari text := nullif(lower(btrim(coalesce(p_cari, ''))), ''); v_rows jsonb; v_total bigint; v_sheet text := upper(btrim(coalesce(p_sheet, '')));
  v_off integer := greatest(coalesce(p_offset, 0), 0);
begin
  perform rc_private.require_tab('discount.kebijakan');
  if v_sheet = 'KEBIJAKAN' then
    select count(*), coalesce(jsonb_agg(x order by urut) filter (where urut > v_off and urut <= v_off + 200), '[]') into v_total, v_rows
      from (select row_number() over (order by k.mg, k.material nulls first, k.jenis, k.scale_qty nulls first, k.id) urut,
                   jsonb_build_object('jenis', k.jenis, 'mg', k.mg, 'produk', coalesce(mm.deskripsi, m.nama_produk, '-'),
                     'kemasan', concat_ws(' / ', k.material, nullif(concat_ws(' / ', k.mg2, k.mg1, k.mg3), '')),
                     'scale', case when k.scale_qty is null then '-' else disc.pct(k.scale_qty) || ' ' || k.scale_uom end,
                     'disc', k.disc, 'berlaku', disc.tgl_teks(k.valid_from) || ' – ' || disc.tgl_teks(k.valid_to),
                     'wilayah', coalesce(k.wilayah, 'NASIONAL'), 'untuk', coalesce(k.untuk_target, '-'), 'memo', k.no_memo,
                     'catatan', coalesce(k.catatan, ''),
                     -- Isian asli, untuk tanggal tampilan dd-Mmm-yyyy dan Unduh berformat template.
                     'periode', k.periode, 'material', k.material, 'mg1', k.mg1, 'mg2', k.mg2, 'mg3', k.mg3, 'qty', k.scale_qty,
                     'uomScale', k.scale_uom, 'dari', k.valid_from, 'sampai', k.valid_to, 'untukRaw', k.untuk_target,
                     'cek', case when m.mg is null then 'ERROR_MG'
                                 when k.scale_uom is not null and m.uom_scale is not null and k.scale_uom <> m.uom_scale
                                  and not exists(select 1 from disc.pengecualian e where e.diganti_pada is null and e.jenis = 'UOM_OVERRIDE'
                                                  and (e.mg = k.mg or e.material = k.material) and upper(e.nilai) = k.scale_uom) then 'CEK_UOM'
                                 else 'OK' end,
                     'ket', case when m.mg is null then 'MG tidak ada di MASTER_MG'
                                 when k.scale_uom is not null and m.uom_scale is not null and k.scale_uom <> m.uom_scale
                                   then 'Satuan ' || k.scale_uom || ', master ' || m.uom_scale else '' end) x
              from disc.kebijakan k
              left join disc.master_mg m on m.mg = k.mg
              left join disc.master_material mm on mm.material = k.material
             where k.diganti_pada is null and (p_periode is null or k.periode = p_periode)
               and (v_cari is null or lower(concat_ws(' ', k.mg, k.material, m.nama_produk, m.alias, mm.deskripsi, k.no_memo, k.jenis)) like '%' || v_cari || '%')) y;
  elsif v_sheet = 'MASTER_MG' then
    select count(*), coalesce(jsonb_agg(x order by urut) filter (where urut > v_off and urut <= v_off + 200), '[]') into v_total, v_rows
      from (select row_number() over (order by m.mg) urut, jsonb_build_object('mg', m.mg, 'nama', m.nama_produk, 'alias', coalesce(m.alias, ''),
                   'segmen', m.segmen, 'jenis', m.jenis_produk, 'uom', m.uom_scale, 'level', m.level_wajib, 'aktif', m.aktif) x
              from disc.master_mg m where v_cari is null or lower(concat_ws(' ', m.mg, m.nama_produk, m.alias)) like '%' || v_cari || '%') y;
  elsif v_sheet = 'MASTER_MATERIAL' then
    select count(*), coalesce(jsonb_agg(x order by urut) filter (where urut > v_off and urut <= v_off + 200), '[]') into v_total, v_rows
      from (select row_number() over (order by m.mg, m.material) urut, jsonb_build_object('material', m.material, 'deskripsi', m.deskripsi,
                   'mg', m.mg, 'mg1', coalesce(m.mg1, ''), 'mg2', coalesce(m.mg2, ''), 'mg3', coalesce(m.mg3, ''), 'aktif', m.aktif) x
              from disc.master_material m where v_cari is null or lower(concat_ws(' ', m.material, m.deskripsi, m.mg)) like '%' || v_cari || '%') y;
  elsif v_sheet = 'TARGET' then
    select count(*), coalesce(jsonb_agg(x order by urut) filter (where urut > v_off and urut <= v_off + 200), '[]') into v_total, v_rows
      from (select row_number() over (order by t.grup nulls last, t.target_id) urut, jsonb_build_object('targetId', t.target_id, 'tipe', t.tipe,
                   'kode', t.kode, 'custGroup', coalesce(t.cust_group, ''), 'nama', t.nama, 'dc', coalesce(t.dc, ''), 'grup', coalesce(t.grup, ''),
                   'aturan', t.aturan_disc, 'label', coalesce(t.label_output, ''), 'aktif', t.aktif) x
              from disc.target t where v_cari is null or lower(concat_ws(' ', t.target_id, t.kode, t.nama, t.grup, t.dc)) like '%' || v_cari || '%') y;
  elsif v_sheet = 'ATURAN_CT' then
    select count(*), coalesce(jsonb_agg(x order by urut), '[]') into v_total, v_rows
      from (select row_number() over (order by a.condition_type) urut, jsonb_build_object('ct', a.condition_type, 'kegunaan', coalesce(a.kegunaan, ''),
                   'tipeTarget', array_to_string(a.tipe_target, ', '), 'levelBoleh', array_to_string(a.level_boleh, ', '),
                   'mode', coalesce(a.mode_hitung, '-'), 'komponen', array_to_string(a.komponen, ', '), 'uom', coalesce(a.uom_scale, '-'),
                   'kolomSatuan', a.kolom_satuan, 'label', coalesce(a.disc_type_label, ''), 'batas', a.batas_amount, 'aktif', a.aktif) x
              from disc.aturan_ct a) y;
  elsif v_sheet = 'PENGECUALIAN' then
    select count(*), coalesce(jsonb_agg(x order by urut), '[]') into v_total, v_rows
      from (select row_number() over (order by e.id) urut, jsonb_build_object('jenis', e.jenis, 'mg', coalesce(e.mg, ''), 'material', coalesce(e.material, ''),
                   'ct', coalesce(e.condition_type, ''), 'target', coalesce(e.target, ''), 'nilai', e.nilai, 'periode', coalesce(e.periode, ''),
                   'catatan', e.catatan) x
              from disc.pengecualian e where e.diganti_pada is null) y;
  else
    raise exception 'Sheet % tidak dikenal', p_sheet;
  end if;
  return jsonb_build_object('status', 'success', 'sheet', v_sheet, 'rows', v_rows, 'total', v_total, 'offset', v_off,
    'periodes', coalesce((select jsonb_agg(p order by p desc) from (select distinct periode p from disc.kebijakan where diganti_pada is null) z), '[]'));
end $f$;

-- Konfigurasi untuk tab Generate / Terbitkan / Kebijakan: aturan CT, target, periode, template
-- kolom, pilihan wilayah.
create or replace function public.rc_disc_konfigurasi()
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  if not (rc_private.can_tab('discount.generate') or rc_private.can_tab('discount.terbit') or rc_private.can_tab('discount.kebijakan')) then
    perform rc_private.require_tab('discount.generate');
  end if;
  return jsonb_build_object('status', 'success',
    'aturan', coalesce((select jsonb_agg(jsonb_build_object('ct', a.condition_type, 'kegunaan', coalesce(a.kegunaan, ''),
        'tipeTarget', to_jsonb(a.tipe_target), 'levelBoleh', to_jsonb(a.level_boleh), 'mode', a.mode_hitung, 'komponen', to_jsonb(a.komponen),
        'uom', a.uom_scale, 'kolomSatuan', a.kolom_satuan, 'label', a.disc_type_label, 'batas', a.batas_amount,
        'aktif', a.aktif and a.mode_hitung is not null) order by a.condition_type) from disc.aturan_ct a), '[]'),
    'target', coalesce((select jsonb_agg(jsonb_build_object('id', t.target_id, 'tipe', t.tipe, 'kode', t.kode, 'nama', t.nama,
        'grup', t.grup, 'aturan', t.aturan_disc, 'label', t.label_output) order by t.grup nulls last, t.target_id)
        from disc.target t where t.aktif), '[]'),
    'periodes', coalesce((select jsonb_agg(p order by p desc) from (select distinct periode p from disc.kebijakan where diganti_pada is null) z), '[]'),
    'template', coalesce((select jsonb_agg(jsonb_build_object('level', k.level, 'sheet', k.sheet_tujuan, 'baris', k.baris_header,
        'kolom', k.kolom, 'header', k.header, 'field', k.field) order by k.level, length(k.kolom), k.kolom) from disc.template_kolom k), '[]'),
    'wilayah', (select jsonb_build_array('NASIONAL')
        || coalesce((select jsonb_agg('REGION ' || r order by r) from (select distinct upper(btrim(region)) r from public.depots
                      where archived_at is null and not bukan_depot and btrim(coalesce(region, '')) <> '') x), '[]')
        || coalesce((select jsonb_agg(upper(depot_code) order by depot_code) from public.depots where archived_at is null and not bukan_depot), '[]')),
    'pengaturan', coalesce((select jsonb_object_agg(kunci, nilai) from disc.pengaturan), '{}'));
end $f$;

revoke all on all functions in schema disc from public, anon, authenticated;
revoke all on function public.rc_disc_unggah(text, jsonb, jsonb, boolean), public.rc_disc_data(text, text, text, integer),
  public.rc_disc_konfigurasi() from public, anon;
grant execute on function public.rc_disc_unggah(text, jsonb, jsonb, boolean), public.rc_disc_data(text, text, text, integer),
  public.rc_disc_konfigurasi() to authenticated;
