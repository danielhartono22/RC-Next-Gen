-- ==========================================================================================
-- CC email pengajuan TIDAK diambil dari Depot Master
-- ==========================================================================================
-- Koreksi atas penerapan sebelumnya. Ketetapan pemilik menyebut empat sumber saja:
--
--   TO : alamat depot pada Depot Master
--   CC : OSC sesuai yurisdiksi
--        Supervisor sesuai yurisdiksi
--        email tambahan yang dikelola di tab Email Pengajuan
--
-- Kolom depots.email_cc IKUT terbawa pada penerapan pertama padahal tidak diminta. Akibatnya
-- CC berisi 12-13 alamat yang nyaris sama di seluruh depot - didominasi isi kolom master -
-- sehingga yurisdiksi OSC dan Supervisor nyaris tidak kelihatan pengaruhnya, dan daftar
-- tambahan di tab Email Pengajuan kehilangan gunanya sebagai satu-satunya tempat mengatur CC.
--
-- Depot Master tetap menentukan TO. Yang dicabut hanya perannya atas CC.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.email_pengajuan_penerima(p_depot uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_to text[]; v_cc text[]; v_dep public.depots%rowtype; v_tam text[];
begin
  select * into v_dep from public.depots where id = p_depot;

  -- TO tetap dari Depot Master. Alamatnya ditulis dipisah koma.
  select coalesce(array_agg(distinct lower(btrim(x))) filter (where btrim(x) <> ''), '{}')
    into v_to
    from unnest(string_to_array(coalesce(v_dep.email_to,''), ',')) x;

  select coalesce(cc_tambahan,'{}') into v_tam
    from public.email_settings where jenis='pengajuan';

  -- CC hanya dari tiga sumber yang diminta. depots.email_cc SENGAJA tidak ikut: CC diatur di
  -- satu tempat saja, yaitu tab Email Pengajuan, supaya tidak ada dua daftar yang harus
  -- dirawat dan bisa berbeda diam-diam.
  select coalesce(array_agg(distinct a) filter (where a <> ''), '{}')
    into v_cc
    from (
      select lower(btrim(coalesce(p.business_email,''))) as a
        from public.profiles p
        join public.user_depot_access uda on uda.user_id = p.id
       where uda.depot_id = p_depot
         and lower(coalesce(p.role,'')) in ('osc','supervisor')
         and coalesce(p.status,'') = 'active'
      union all
      select lower(btrim(y)) from unnest(v_tam) y
    ) s
   where a is not null and a <> '' and a like '%@%';

  -- Alamat yang sudah menjadi tujuan utama tidak perlu ikut sebagai tembusan.
  select coalesce(array_agg(c),'{}') into v_cc
    from unnest(v_cc) c where not (c = any(coalesce(v_to,'{}')));

  return jsonb_build_object('to', to_jsonb(coalesce(v_to,'{}')),
                            'cc', to_jsonb(coalesce(v_cc,'{}')),
                            'depot', coalesce(v_dep.depot_name, v_dep.depot_code, ''));
end
$fn$;

revoke all on function rc_private.email_pengajuan_penerima(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare
  v_dep uuid; v_pen jsonb; v_cc_master text; v_bocor text; n_cc int; v_uji text := 'uji.cc.tambahan@contoh.com';
  v_semula text[];
begin
  -- Depot yang kolom email_cc-nya BERISI, supaya kebocoran benar-benar terdeteksi. Memeriksa
  -- pada depot yang email_cc-nya kosong hanya akan lolos tanpa membuktikan apa pun.
  select id, email_cc into v_dep, v_cc_master
    from public.depots
   where archived_at is null and coalesce(email_cc,'') <> '' and coalesce(email_to,'') <> ''
   order by depot_code limit 1;
  if v_dep is null then
    raise notice 'Tidak ada depot dengan email_cc terisi; pemeriksaan kebocoran dilewati.';
  else
    v_pen := rc_private.email_pengajuan_penerima(v_dep);

    select x into v_bocor
      from unnest(string_to_array(coalesce(v_cc_master,''), ',')) x
     where lower(btrim(x)) <> ''
       and lower(btrim(x)) in (select jsonb_array_elements_text(v_pen->'cc'))
       -- Alamat yang juga OSC/Supervisor depot ini memang berhak ikut lewat jalur yurisdiksi.
       and lower(btrim(x)) not in (
         select lower(btrim(coalesce(p.business_email,'')))
           from public.profiles p join public.user_depot_access u on u.user_id=p.id
          where u.depot_id = v_dep and lower(coalesce(p.role,'')) in ('osc','supervisor'))
     limit 1;
    if v_bocor is not null then
      raise exception 'GAGAL: alamat % masih terbawa dari kolom email_cc Depot Master.', v_bocor;
    end if;
    raise notice 'OK  1. Kolom email_cc Depot Master tidak lagi terbawa ke CC';
  end if;

  -- Daftar tambahan dari tab memang benar-benar dipakai.
  select cc_tambahan into v_semula from public.email_settings where jenis='pengajuan';
  begin
    update public.email_settings set cc_tambahan = array[v_uji] where jenis='pengajuan';
    select id into v_dep from public.depots
     where archived_at is null and coalesce(email_to,'') <> '' order by depot_code limit 1;
    v_pen := rc_private.email_pengajuan_penerima(v_dep);
    if not (v_uji in (select jsonb_array_elements_text(v_pen->'cc'))) then
      raise exception 'GAGAL: email tambahan dari tab tidak masuk CC.'; end if;
    n_cc := jsonb_array_length(v_pen->'cc');
    raise exception 'ULANGI_SAJA';
  exception when others then
    if sqlerrm <> 'ULANGI_SAJA' then raise; end if;
  end;
  raise notice 'OK  2. Email tambahan dari tab Email Pengajuan masuk CC (total % alamat)', n_cc;

  if (select coalesce(cc_tambahan,'{}') from public.email_settings where jenis='pengajuan')
     <> coalesce(v_semula,'{}') then
    raise exception 'GAGAL: daftar tambahan tidak kembali seperti semula.'; end if;
  raise notice 'OK  3. Pemeriksaan tidak meninggalkan jejak';
  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
