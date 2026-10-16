-- ==========================================================================================
-- UJI (tidak menyimpan apa pun): Email Pengajuan, dari perpindahan status sampai antrean
-- ==========================================================================================
-- Yang dibuktikan di sini bukan "fungsinya ada", melainkan bahwa PERPINDAHAN STATUS YANG
-- SUNGGUHAN benar-benar menghasilkan surat di antrean - lewat jalur yang sama persis dengan
-- yang ditempuh layar.
--
-- Berkas ini SELALU berakhir dengan raise exception, jadi seluruh perubahannya dibatalkan:
-- sakelar kembali mati, antrean kembali seperti semula, dokumen kembali ke statusnya.
--
-- Jalankan: node scripts/apply-sql.mjs supabase/queries/uji_email_pengajuan.sql
-- ==========================================================================================
-- Dipanggil lewat public.rc_process_claims - pembungkus yang BENAR-BENAR dipakai layar.
-- Memanggil rc_private langsung akan lolos sebagai pemilik skema dan tidak membuktikan
-- bahwa pengguna sungguhan dapat menempuhnya.
do $uji$
declare
  v_sm uuid; v_doc text; v_ver bigint; v_depot uuid; v_lolos int := 0;
  n_awal int; n_kini int; v_res jsonb; v_surat public.email_outbox%rowtype;
  v_req uuid := gen_random_uuid();
begin
  select count(*) into n_awal from public.email_outbox;

  select id into v_sm from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  -- Dokumen yang benar-benar bisa di-submit: Not Yet, belum menunggu approval, dan depotnya
  -- punya alamat email. Tanpa syarat terakhir, uji ini akan "lolos" tanpa membuktikan apa pun.
  select c.no_doc, c.version_no, c.depot_id into v_doc, v_ver, v_depot
    from public.claims c
    join public.depots d on d.id = c.depot_id
   where c.status='not_yet' and c.archived_at is null and c.pending_approval is null
     and coalesce(d.email_to,'') <> ''
   order by c.no_doc limit 1;
  if v_doc is null then
    raise exception 'Tidak ada dokumen Not Yet pada depot yang punya alamat email.'; end if;
  raise notice 'Dokumen uji: % (versi %)', v_doc, v_ver;

  -- ---- 1. Sakelar MATI -> perpindahan status tidak mengirim apa pun ----------------------
  update public.email_settings set aktif=false where jenis='pengajuan';
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_sm::text,'role','authenticated')::text, true);
  v_res := public.rc_process_claims('submit',
    jsonb_build_array(jsonb_build_object('no_doc', v_doc, 'version_no', v_ver)), v_req, null);
  reset role;

  if coalesce(v_res->>'count','0') <> '1' then
    raise exception 'GAGAL: submit tidak memproses dokumennya (%).', v_res; end if;
  select count(*) into n_kini from public.email_outbox;
  if n_kini <> n_awal then
    raise exception 'GAGAL: sakelar mati tetapi antrean bertambah % baris.', n_kini-n_awal; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  1. Sakelar mati -> submit berhasil, tidak ada surat';

  -- ---- 2. Sakelar NYALA -> submit menghasilkan tepat satu surat ---------------------------
  update public.email_settings set aktif=true where jenis='pengajuan';
  select c.no_doc, c.version_no into v_doc, v_ver
    from public.claims c join public.depots d on d.id = c.depot_id
   where c.status='not_yet' and c.archived_at is null and c.pending_approval is null
     and coalesce(d.email_to,'') <> ''
   order by c.no_doc limit 1;
  if v_doc is null then
    raise exception 'GAGAL: kehabisan dokumen Not Yet untuk langkah kedua.'; end if;

  v_req := gen_random_uuid();
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_sm::text,'role','authenticated')::text, true);
  perform public.rc_process_claims('submit',
    jsonb_build_array(jsonb_build_object('no_doc', v_doc, 'version_no', v_ver)), v_req, null);
  reset role;

  select count(*) into n_kini from public.email_outbox;
  if n_kini <> n_awal + 1 then
    raise exception 'GAGAL: seharusnya bertambah tepat 1 surat, bertambah %.', n_kini-n_awal; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  2. Sakelar nyala -> submit menghasilkan 1 surat';

  -- ---- 3. Suratnya benar isinya ------------------------------------------------------------
  select * into v_surat from public.email_outbox
   where jenis='pengajuan' order by dibuat_pada desc limit 1;

  if v_surat.status <> 'pending' then
    raise exception 'GAGAL: surat tidak berstatus pending (%).', v_surat.status; end if;
  if coalesce(array_length(v_surat.tujuan,1),0) = 0 then
    raise exception 'GAGAL: surat tanpa alamat tujuan.'; end if;
  if v_surat.subjek !~ '^Approval - Pengajuan Claim Cashback' then
    raise exception 'GAGAL: subjek tidak sesuai -> %', v_surat.subjek; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  3. Subjek "%"; TO % alamat, CC % alamat',
    v_surat.subjek, coalesce(array_length(v_surat.tujuan,1),0),
    coalesce(array_length(v_surat.cc,1),0);

  -- ---- 4. Kolom yang diminta pemilik benar-benar ada -------------------------------------
  if position('NO BATCH' in v_surat.isi_html) = 0
     or position('NAMA CAMPAIGN' in v_surat.isi_html) = 0
     or position('JUMLAH TOKO' in v_surat.isi_html) = 0
     or position('TOTAL CB' in v_surat.isi_html) = 0
     or position('GRAND TOTAL' in v_surat.isi_html) = 0 then
    raise exception 'GAGAL: kolom yang diminta tidak lengkap di dalam surat.'; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  4. No Batch, Nama Campaign, Jumlah Toko, Total CB dan Grand Total ada';

  -- ---- 5. Kop merah, logo, dan tanda tangan ------------------------------------------------
  if position('#C8102E' in v_surat.isi_html) = 0 then
    raise exception 'GAGAL: kop merah tidak ada.'; end if;
  if position('cid:logo' in v_surat.isi_html) = 0 then
    raise exception 'GAGAL: logo Nippon tidak dirujuk inline.'; end if;
  if position('cid:blobby' in v_surat.isi_html) = 0 then
    raise exception 'GAGAL: maskot RC tidak dirujuk inline.'; end if;
  if position('SA &amp; SD Operations' in v_surat.isi_html) = 0 then
    raise exception 'GAGAL: tanda tangan tidak sesuai.'; end if;
  if position('sa_sd1@nipponpaint-indonesia.com' in v_surat.isi_html) = 0 then
    raise exception 'GAGAL: alamat pelaporan kendala tidak ada.'; end if;
  if position('Dear All,' in v_surat.isi_html) = 0
     or position('Mohon tim Management untuk segera melakukan approval' in v_surat.isi_html) = 0 then
    raise exception 'GAGAL: wording pengajuan tidak sesuai.'; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  5. Kop merah, kedua logo inline, wording, dan tanda tangan';

  -- ---- 6. Nominal memakai titik, tanpa desimal --------------------------------------------
  if v_surat.isi_html ~ 'Rp [0-9]+,[0-9]{3}' then
    raise exception 'GAGAL: nominal memakai koma sebagai pemisah ribuan.'; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  6. Nominal memakai pemisah titik tanpa desimal';

  -- ---- 7. Alamat TO tidak diulang di CC ---------------------------------------------------
  if exists (select 1 from unnest(v_surat.cc) c where c = any(v_surat.tujuan)) then
    raise exception 'GAGAL: ada alamat yang muncul di TO sekaligus CC.'; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  7. Tidak ada alamat yang menerima surat dua kali';

  -- ---- 8. Penolakan TIDAK mengirim surat ---------------------------------------------------
  select count(*) into n_awal from public.email_outbox;
  select c.no_doc, c.version_no into v_doc, v_ver from public.claims c
   where c.no_doc = v_surat.konteks->>'x' limit 1;   -- sengaja tidak ketemu; dipakai di bawah
  select c.no_doc, c.version_no into v_doc, v_ver
    from public.claims c
   where c.status='submitted' and c.pending_approval->>'kind'='submit'
     and c.archived_at is null
   order by c.no_doc limit 1;
  if v_doc is not null then
    v_req := gen_random_uuid();
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_sm::text,'role','authenticated')::text, true);
    perform public.rc_process_claims('reject_approval',
      jsonb_build_array(jsonb_build_object('no_doc', v_doc, 'version_no', v_ver)), v_req, null);
    reset role;
    select count(*) into n_kini from public.email_outbox;
    if n_kini <> n_awal then
      raise exception 'GAGAL: penolakan ikut mengirim surat (% baris).', n_kini-n_awal; end if;
    v_lolos := v_lolos + 1;
    raise notice 'OK  8. Penolakan tidak mengirim surat';
  else
    raise notice '--  8. Dilewati: tidak ada dokumen menunggu approval.';
  end if;

  raise exception 'SELESAI: % langkah lolos. Transaksi sengaja dibatalkan.', v_lolos;
exception when others then
  reset role;
  if sqlerrm like 'SELESAI:%' or sqlerrm like 'GAGAL:%' then raise; end if;
  raise exception 'GAGAL: uji berhenti -> %', sqlerrm;
end
$uji$;
