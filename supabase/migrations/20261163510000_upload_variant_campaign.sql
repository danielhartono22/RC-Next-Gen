-- ==========================================================================================
-- Upload Variant di Key Master > Campaign Master
-- ==========================================================================================
-- Pemilik, 27 Oktober 2026: "saya mau upload ... untuk variant nya buatkan yaa, cukup kode campaign,
-- nama varian 1, description 1 sampe 3". Jawaban pemilik: tambah kolom T-Code; tombolnya di
-- Key Master > Campaign Master.
--
-- Template: Kode Campaign | T-Code | Nama Variant 1 | Description 1 | ... | Nama Variant 3 |
-- Description 3. Satu baris = satu campaign + satu T-Code (ZSQ04 / ZSOD / MCSI), sampai 3 variant.
--   * Baris yang mengisi variant MENGGANTI seluruh variant T-Code itu; T-Code lain tidak berubah.
--   * Baris tanpa Nama Variant = tidak diubah. "-" pada Nama Variant 1 = kosongkan T-Code itu
--     (aturan yang sama dengan upload Customer Master).
-- Disimpan ke kolom variant_<tcode> / _desc dengan pemisah titik koma (20261163470000), sehingga
-- Details Campaign dan Campaign Master langsung membacanya. Pratinjau dulu (p_simpan = false);
-- penyimpanan menolak seluruh berkas bila ada satu baris bermasalah. Satu baris Log Activity.
-- ==========================================================================================

create or replace function public.rc_campaign_variant_unggah(p_rows jsonb, p_simpan boolean default false)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare r jsonb; v_kode text; v_tcode text; v_kolom text; ca public.campaigns%rowtype; i int;
  v_nama text[]; v_desk text[]; v_n text; v_d text; v_galat text; v_hapus boolean;
  v_nama_baru text; v_desk_baru text; v_nama_lama text; v_desk_lama text; v_status text;
  v_hasil jsonb := '[]'::jsonb; v_lihat text[] := '{}'; n_galat int := 0; n_ubah int := 0; v_ringkas jsonb := '[]'::jsonb;
begin
  perform rc_private.require_tab('keyMaster.campaign');
  if not rc_private.can_access(null, 'manage_key_master') then
    raise exception 'Anda belum diberi akses Key Master' using errcode = '42501'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Tidak ada baris yang dikirim'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'Satu unggahan maksimal 2000 baris'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_galat := null; v_status := null; v_nama_lama := null; v_desk_lama := null; v_nama_baru := null; v_desk_baru := null;
    v_kode := upper(btrim(coalesce(r->>'kode', '')));
    v_tcode := upper(regexp_replace(coalesce(r->>'tcode', ''), '[[:space:]_.-]', '', 'g'));
    v_nama := array[btrim(coalesce(r->'nama'->>0, '')), btrim(coalesce(r->'nama'->>1, '')), btrim(coalesce(r->'nama'->>2, ''))];
    v_desk := array[btrim(coalesce(r->'deskripsi'->>0, '')), btrim(coalesce(r->'deskripsi'->>1, '')), btrim(coalesce(r->'deskripsi'->>2, ''))];
    v_hapus := v_nama[1] = '-';
    v_kolom := case v_tcode when 'ZSQ04' then 'variant_zsq04' when 'ZSOD' then 'variant_zsod' when 'MCSI' then 'variant_mcsi' end;

    if v_kode = '' then v_galat := 'Kode Campaign kosong';
    elsif v_kolom is null then v_galat := 'T-Code "' || coalesce(r->>'tcode', '') || '" harus ZSQ04, ZSOD, atau MCSI';
    else
      select * into ca from public.campaigns where campaign_code = v_kode and archived_at is null;
      if not found then v_galat := 'Campaign ' || v_kode || ' tidak ada di Campaign Master (atau diarsipkan)';
      elsif (v_kode || '|' || v_tcode) = any(v_lihat) then v_galat := 'Campaign dan T-Code ini muncul lebih dari sekali di berkas';
      end if;
    end if;
    if v_galat is null and not v_hapus then
      for i in 1..3 loop
        if v_nama[i] ~ '[;\n]' or v_desk[i] ~ '[;\n]' then v_galat := 'Variant ' || i || ' tidak boleh memuat titik koma atau baris baru'; exit; end if;
        if v_nama[i] = '' and v_desk[i] <> '' then v_galat := 'Description ' || i || ' diisi tanpa Nama Variant ' || i; exit; end if;
      end loop;
    end if;

    if v_galat is null then
      v_lihat := v_lihat || (v_kode || '|' || v_tcode);
      execute format('select %I, %I from public.campaigns where id = $1', v_kolom, v_kolom || '_desc') into v_nama_lama, v_desk_lama using ca.id;
      if v_hapus then
        v_nama_baru := null; v_desk_baru := null;
      elsif v_nama[1] = '' and v_nama[2] = '' and v_nama[3] = '' then
        v_status := 'dilewati';
      else
        select string_agg(x.n, '; ' order by x.k), case when bool_or(x.d <> '') then string_agg(x.d, '; ' order by x.k) end
          into v_nama_baru, v_desk_baru
          from (select g.k, v_nama[g.k] n, v_desk[g.k] d from generate_series(1, 3) as g(k) where v_nama[g.k] <> '') x;
        if length(v_nama_baru) > 2000 or length(coalesce(v_desk_baru, '')) > 2000 then v_galat := 'Variant terlalu panjang (maksimal 2.000 karakter per T-Code)'; end if;
      end if;
      if v_galat is null and v_status is null then
        v_status := case when v_nama_baru is not distinct from v_nama_lama and v_desk_baru is not distinct from v_desk_lama then 'sama'
                         when v_hapus then 'dikosongkan' else 'diganti' end;
      end if;
    end if;
    if v_galat is not null then v_status := 'galat'; n_galat := n_galat + 1; end if;

    if p_simpan and v_status in ('diganti', 'dikosongkan') then
      execute format('update public.campaigns set %I = $1, %I = $2 where id = $3', v_kolom, v_kolom || '_desc') using v_nama_baru, v_desk_baru, ca.id;
      n_ubah := n_ubah + 1;
      v_ringkas := v_ringkas || jsonb_build_object('kode', v_kode, 'tcode', v_tcode, 'lama', v_nama_lama, 'baru', v_nama_baru);
    end if;
    v_hasil := v_hasil || jsonb_build_object('baris', r->'baris', 'kode', v_kode, 'tcode', v_tcode, 'status', v_status, 'galat', v_galat,
      'namaLama', coalesce(v_nama_lama, ''), 'deskripsiLama', coalesce(v_desk_lama, ''), 'namaBaru', coalesce(v_nama_baru, ''), 'deskripsiBaru', coalesce(v_desk_baru, ''));
  end loop;

  if p_simpan and n_galat > 0 then
    raise exception 'Upload Variant dibatalkan: % baris bermasalah. Perbaiki lalu unggah ulang.', n_galat; end if;
  if p_simpan and n_ubah > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values ((select auth.uid()), 'campaign_variant_unggah', jsonb_build_object(
      'detail', 'Upload Variant Campaign Master: ' || n_ubah || ' campaign x T-Code diubah', 'jumlah', n_ubah, 'perubahan', v_ringkas),
      'keyMaster', 'campaign', 'upload');
  end if;
  return jsonb_build_object('status', 'success', 'disimpan', p_simpan, 'galat', n_galat, 'diubah', n_ubah, 'baris', v_hasil);
end $function$;
revoke all on function public.rc_campaign_variant_unggah(jsonb, boolean) from public, anon;
grant execute on function public.rc_campaign_variant_unggah(jsonb, boolean) to authenticated;
