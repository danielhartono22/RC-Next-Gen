-- ==========================================================================================
-- Tanda Terima: PDA (posting date available) / PDH (posting date hidden)
-- ==========================================================================================
-- Pemilik, 5 November 2026: "untuk tanggal proses ada toko yang marah karena tidak sesuai ...
-- jika itu diproses oktober ke atas maka akan keluar tanggal proses nya sebaliknya oktober ke
-- bawah tidak usah ada kolom tanggal proses, dan bagaimana jika ada 2 oktober ke atas dan oktober
-- ke bawah? maka dipisahkan menjadi 2 file dan kolom akhir ada kolom remark, kalo tandanya PDA
-- artinya posting date available, kalo PDH artinya posting date hidden".
-- Pilihan pemilik: 2 form + 2 PDF; Remark di daftar layar + tanda kecil di PDF.
--
-- * Setiap klaim Done digolongkan menurut Tanggal Proses (tgl Clearing, WIB):
--     PDA = 01-Oct-2026 ke atas  -> form memuat kolom Tanggal Proses;
--     PDH = sebelum 01-Oct-2026, atau tanpa tanggal -> kolom Tanggal Proses tidak dicetak.
--   Batasnya rc_private.docgen_batas_pda(), satu tempat bila kelak berubah.
-- * Toko yang punya keduanya mendapat DUA form (dua nomor TT, deret depot per hari yang sama):
--   form PDA dulu, lalu PDH. rc_form_verifikasi.kategori mencatat golongannya. Layar
--   mengumpulkan form PDA dan PDH ke dua berkas PDF terpisah.
-- * Daftar Done: kolom Remark per toko = PDA / PDH / PDA + PDH (mengikuti saringan klaim).
--   "Unduh terakhir", "Jumlah unduh" dan "Data berubah" dihitung per PROSES unduh (gabungan form
--   satu proses_id), bukan per form - satu unduhan toko campuran menghasilkan dua form.
-- Butuh 20261163660000. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $pra$
declare v_md5 text := md5(replace(pg_get_functiondef('public.rc_docgen_generate(jsonb,text,jsonb)'::regprocedure), E'\r', ''));
begin
  if pg_get_functiondef('public.rc_docgen_generate(jsonb,text,jsonb)'::regprocedure) ~ '20261163700000' then return; end if;
  if v_md5 <> '3f9a953616ebc4308384126fcfd9a560' then
    raise exception 'DITOLAK: rc_docgen_generate berbeda dari yang diukur (md5 %). Jalankan 20261163660000 lebih dulu.', v_md5; end if;
end $pra$;

create or replace function rc_private.docgen_batas_pda() returns date
language sql immutable set search_path to '' as $f$ select date '2026-10-01' $f$;

alter table public.rc_form_verifikasi add column if not exists kategori text;
do $c$ begin
  if not exists (select 1 from pg_constraint where conname = 'rc_form_verifikasi_kategori_check') then
    alter table public.rc_form_verifikasi add constraint rc_form_verifikasi_kategori_check check (kategori is null or kategori in ('PDA', 'PDH'));
  end if;
end $c$;

-- ---- 1. Generate: satu form per toko x golongan ------------------------------------------------
create or replace function public.rc_docgen_generate(p_toko jsonb, p_sumber text DEFAULT 'done'::text, p_saring jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_proses uuid := gen_random_uuid();
  r record; v_forms jsonb := '[]'; v_gagal jsonb := '[]'; v_rows jsonb; v_ids uuid[]; v_total numeric; v_n integer;
  v_urut integer; v_no text; v_masalah text; v_nomor text[] := '{}'; v_depot text[] := '{}';
  v_tab text := rc_private.docgen_tab(p_sumber);
  v_judul text := case when p_sumber = 'notyet' then 'Not Yet' else 'Done' end;
  sk record; v_ket text; v_sar jsonb; v_isi jsonb; v_satu_isi jsonb;
  -- 20261163700000: golongan PDA / PDH.
  v_bt date := rc_private.docgen_batas_pda(); v_kat text; v_ada boolean; n_pda integer := 0; n_pdh integer := 0;
begin
  perform rc_private.require_tab(v_tab);
  select * into sk from rc_private.docgen_saring_klaim(p_sumber, coalesce(p_saring, '{}'::jsonb));
  -- Hanya saringan klaim yang menentukan isi form.
  v_sar := jsonb_strip_nulls(jsonb_build_object('dari', sk.dari, 'sampai', sk.sampai, 'batch', sk.batch));
  v_ket := rc_private.docgen_keterangan(sk.dari, sk.sampai, sk.batch);
  if jsonb_typeof(p_toko) is distinct from 'array' or jsonb_array_length(p_toko) = 0 then raise exception 'Pilih toko lebih dulu'; end if;
  if jsonb_array_length(p_toko) > 500 then raise exception 'Maksimal 500 toko sekali unduh'; end if;
  begin
    perform (e->>'depotId')::uuid, (e->>'customerId')::uuid from jsonb_array_elements(p_toko) e;
  exception when invalid_text_representation then raise exception 'Data toko tidak valid'; end;

  -- Isi form seluruh toko terpilih dalam satu bacaan, per toko x golongan (PDA = Tanggal Proses
  -- mulai batas, PDH = sebelum batas atau tanpa tanggal): baris campaign x Jenis CB, total, klaim.
  with gk as materialized (select x.*, case when x.tgl_done >= v_bt then 'PDA' else 'PDH' end kat
                             from rc_private.docgen_klaim(p_sumber, v_sar, p_toko) x where x.customer_id is not null),
  gp as (select gk.depot_id, gk.customer_id, gk.kat, gk.campaign_id, gk.jenis_cb, trunc(sum(gk.cb_net)) cb,
                -- 20261163590000 / 20261163660000: tanggal proses (Clearing) klaim baris ini, DD-Mon-YY dipisah koma.
                (select string_agg(to_char(t, 'DD-Mon-YY'), ', ' order by t) from unnest(array_agg(distinct gk.tgl_done)) t where t is not null) tgl
           from gk group by 1, 2, 3, 4, 5),
  gr as (select gp.depot_id, gp.customer_id, gp.kat, sum(gp.cb) total, count(*) n,
                jsonb_agg(jsonb_build_object('kode', ca.campaign_code, 'nama', ca.campaign_name, 'jenisCb', gp.jenis_cb, 'netCb', gp.cb,
                                             'taxStatus', coalesce(ca.tax_status, ''),
                                             'tglProses', case when gp.kat = 'PDA' then coalesce(gp.tgl, '') else '' end) order by ca.campaign_code, gp.jenis_cb) baris
           from gp join public.campaigns ca on ca.id = gp.campaign_id group by 1, 2, 3),
  gi as (select gk.depot_id, gk.customer_id, gk.kat, array_agg(gk.claim_id order by gk.claim_id) ids from gk group by 1, 2, 3)
  select coalesce(jsonb_object_agg(gr.depot_id::text || '|' || gr.customer_id::text || '|' || gr.kat,
                                   jsonb_build_object('rows', gr.baris, 'total', gr.total, 'n', gr.n, 'ids', to_jsonb(gi.ids))), '{}'::jsonb)
    into v_isi
    from gr join gi on gi.depot_id = gr.depot_id and gi.customer_id = gr.customer_id and gi.kat = gr.kat;

  -- Urut depot lalu kode toko, supaya nomor dan halaman PDF berurutan.
  for r in
    select x.depot_id, x.customer_id, d.id d_ada, d.depot_code, coalesce(nullif(d.depot_name, ''), d.depot_code) depot_nama,
           upper(coalesce(nullif(btrim(d.abbr), ''), d.depot_code)) abbr, cu.customer_code, cu.customer_name, cu.contact_person, cu.npwp,
           coalesce(btrim(cu.bank), '') bank, coalesce(btrim(cu.account_number), '') no_rek, coalesce(btrim(cu.account_name), '') atas_nama,
           coalesce(btrim(cu.sales_name), '') sales
      from (select distinct (e->>'depotId')::uuid depot_id, (e->>'customerId')::uuid customer_id from jsonb_array_elements(p_toko) e) x
      left join public.depots d on d.id = x.depot_id
      left join public.customers cu on cu.id = x.customer_id
     order by d.depot_code nulls last, cu.customer_code nulls last
  loop
    if r.d_ada is null or r.depot_id is null or not rc_private.can_access(r.depot_id) then
      v_gagal := v_gagal || jsonb_build_object('depotKode', coalesce(r.depot_code, '-'), 'kode', coalesce(r.customer_code, '-'),
                   'nama', coalesce(r.customer_name, ''), 'alasan', 'Depot di luar jangkauan Anda');
      continue;
    end if;
    v_masalah := rc_private.docgen_masalah_master(r.customer_id);
    if v_masalah is not null then
      v_gagal := v_gagal || jsonb_build_object('depotKode', r.depot_code, 'kode', coalesce(r.customer_code, '-'),
                   'nama', coalesce(r.customer_name, ''), 'alasan', 'Customer Master belum lengkap: ' || v_masalah);
      continue;
    end if;

    v_ada := false;
    foreach v_kat in array array['PDA', 'PDH'] loop
      v_satu_isi := v_isi->(r.depot_id::text || '|' || r.customer_id::text || '|' || v_kat);
      if v_satu_isi is null then continue; end if;
      v_rows := coalesce(v_satu_isi->'rows', '[]'::jsonb); v_total := coalesce((v_satu_isi->>'total')::numeric, 0);
      v_n := coalesce((v_satu_isi->>'n')::integer, 0);
      if v_n = 0 then continue; end if;
      v_ada := true;
      select array_agg(x::uuid order by x::uuid) into v_ids from jsonb_array_elements_text(v_satu_isi->'ids') x;

      -- Nomor urut per depot per hari (satu deret untuk semua form); kunci transaksi mencegah dua
      -- unduhan bersamaan memakai nomor yang sama.
      perform pg_advisory_xact_lock(hashtextextended('rc_form_verifikasi:' || r.depot_id::text || ':' || v_hari::text, 0));
      select coalesce(max(f.urut), 0) + 1 into v_urut from public.rc_form_verifikasi f where f.depot_id = r.depot_id and f.tanggal = v_hari;
      v_no := 'TT-' || r.abbr || '-' || to_char(v_hari, 'DDMMYY') || '-' || lpad(v_urut::text, 3, '0');
      insert into public.rc_form_verifikasi(no_form, depot_id, customer_id, tanggal, urut, halaman, claim_ids, total, proses_id, created_by, sumber,
                                            periode_dari, periode_sampai, batch_clearing, kategori)
      values (v_no, r.depot_id, r.customer_id, v_hari, v_urut, ceil(v_n / 4.0)::integer, v_ids, v_total, v_proses, auth.uid(), p_sumber,
              sk.dari, sk.sampai, sk.batch, v_kat);

      v_nomor := v_nomor || v_no;
      if v_kat = 'PDA' then n_pda := n_pda + 1; else n_pdh := n_pdh + 1; end if;
      if not (r.depot_code = any(v_depot)) then v_depot := v_depot || r.depot_code; end if;
      v_forms := v_forms || jsonb_build_object('noForm', v_no, 'dicetak', to_char(v_hari, 'DD-Mon-YYYY'), 'sumber', p_sumber, 'saringan', v_ket,
        'kategori', v_kat,
        'depot', jsonb_build_object('kode', r.depot_code, 'nama', r.depot_nama),
        'toko', jsonb_build_object('kode', r.customer_code, 'nama', r.customer_name, 'pemilik', r.contact_person,
                                   'subyekPajak', rc_private.docgen_subyek_pajak(r.npwp), 'sales', r.sales),
        'rekening', jsonb_build_object('bank', r.bank, 'noRek', r.no_rek, 'atasNama', r.atas_nama),
        'campaigns', v_rows, 'total', v_total, 'halaman', ceil(v_n / 4.0)::integer, 'jumlahKlaim', cardinality(v_ids));
    end loop;
    if not v_ada then
      v_gagal := v_gagal || jsonb_build_object('depotKode', r.depot_code, 'kode', r.customer_code, 'nama', coalesce(r.customer_name, ''),
                   'alasan', case when p_sumber = 'notyet' then 'Tidak ada klaim Not Yet (sudah diajukan atau diproses)'
                                  else 'Tidak ada klaim Done' || case when v_ket <> '' then ' pada ' || v_ket else '' end end);
    end if;
  end loop;

  if jsonb_array_length(v_forms) > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage)
    values (auth.uid(), 'docgen_verifikasi',
      jsonb_build_object('detail', 'Document Generator (' || v_judul || case when v_ket <> '' then ', ' || v_ket else '' end || '): '
                                     || jsonb_array_length(v_forms) || ' tanda terima ('
                                     || v_nomor[1] || case when cardinality(v_nomor) > 1 then ' s.d. ' || v_nomor[cardinality(v_nomor)] else '' end || ')'
                                     || ' - PDA ' || n_pda || ', PDH ' || n_pdh
                                     || case when jsonb_array_length(v_gagal) > 0 then '; ' || jsonb_array_length(v_gagal) || ' toko gagal' else '' end,
                         'jumlah', jsonb_array_length(v_forms), 'pda', n_pda, 'pdh', n_pdh, 'gagal', jsonb_array_length(v_gagal), 'nomor', to_jsonb(v_nomor),
                         'depot', to_jsonb(v_depot), 'proses', v_proses, 'sumber', p_sumber,
                         'dari', sk.dari, 'sampai', sk.sampai, 'batch', sk.batch),
      'docgen', split_part(v_tab, '.', 2), split_part(v_tab, '.', 2));
  end if;

  return jsonb_build_object('status', 'success', 'forms', v_forms, 'gagal', v_gagal, 'pda', n_pda, 'pdh', n_pdh,
    'message', jsonb_array_length(v_forms) || ' tanda terima dibuat (PDA ' || n_pda || ', PDH ' || n_pdh || ')'
      || case when jsonb_array_length(v_gagal) > 0 then '; ' || jsonb_array_length(v_gagal) || ' toko tidak dapat dibuatkan' else '' end || '.');
end $function$;

-- 20261163700000 (penanda untuk pemeriksaan ulang): komentar fungsi.
comment on function public.rc_docgen_generate(jsonb, text, jsonb) is
  'Tanda Terima: satu form per toko x golongan PDA / PDH (20261163700000).';

-- ---- 2. Daftar: Remark + jejak unduh per proses -------------------------------------------------
do $tambal$
declare src text; f text := 'public.rc_docgen_list(text,jsonb,integer,integer,boolean)';
begin
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src ~ '20261163700000' then raise notice '% sudah ditambal.', f; return; end if;
  src := pg_temp.ganti(src,
    $p$array_agg(k.claim_id order by k.claim_id) ids, count(*) n_klaim, min(k.tgl_done) done_awal, max(k.tgl_done) done_akhir
      from k group by 1, 2),$p$,
    $p$array_agg(k.claim_id order by k.claim_id) ids, count(*) n_klaim, min(k.tgl_done) done_awal, max(k.tgl_done) done_akhir,
           -- 20261163700000: golongan PDA / PDH toko ini.
           bool_or(k.tgl_done >= rc_private.docgen_batas_pda()) ada_pda,
           bool_or(k.tgl_done is null or k.tgl_done < rc_private.docgen_batas_pda()) ada_pdh
      from k group by 1, 2),$p$, 1, 'list t');
  src := pg_temp.ganti(src,
    $p$select t.depot_id, t.customer_id, t.kode_sumber, t.n_klaim, t.done_awal, t.done_akhir,$p$,
    $p$select t.depot_id, t.customer_id, t.kode_sumber, t.n_klaim, t.done_awal, t.done_akhir, t.ada_pda, t.ada_pdh,$p$, 1, 'list s');
  src := pg_temp.ganti(src,
    $p$f.no_form, f.created_at f_pada, coalesce(nullif(pf.full_name, ''), pf.user_code, '-') f_oleh, coalesce(fn.n, 0) n_unduh,$p$,
    $p$f.no_form, fu.nomor nomor_unduh, f.created_at f_pada, coalesce(nullif(pf.full_name, ''), pf.user_code, '-') f_oleh, coalesce(fn.n, 0) n_unduh,$p$, 1, 'list nomor');
  src := pg_temp.ganti(src,
    $p$(f.no_form is not null and (not (f.claim_ids @> t.ids and t.ids @> f.claim_ids) or f.total <> tc.total)) berubah$p$,
    $p$(f.no_form is not null and (not (fu.ids @> t.ids and t.ids @> fu.ids) or fu.total <> tc.total)) berubah /* 20261163700000: per proses unduh */$p$,
    1, 'list berubah');
  src := pg_temp.ganti(src,
    $p$left join lateral (select x.no_form, x.created_at, x.created_by, x.claim_ids, x.total from public.rc_form_verifikasi x$p$,
    $p$left join lateral (select x.no_form, x.created_at, x.created_by, x.claim_ids, x.total, x.proses_id from public.rc_form_verifikasi x$p$, 1, 'list f');
  src := pg_temp.ganti(src,
    $p$                          order by x.created_at desc, x.urut desc limit 1) f on true$p$,
    $p$                          order by x.created_at desc, x.urut desc limit 1) f on true
      -- Seluruh form proses unduh terakhir toko ini (toko campuran: form PDA + PDH).
      left join lateral (select
          (select array_agg(distinct u order by u) from public.rc_form_verifikasi x, unnest(x.claim_ids) u
            where x.proses_id = f.proses_id and x.depot_id = t.depot_id and x.customer_id = t.customer_id) ids,
          (select sum(x.total) from public.rc_form_verifikasi x
            where x.proses_id = f.proses_id and x.depot_id = t.depot_id and x.customer_id = t.customer_id) total,
          (select string_agg(x.no_form || coalesce(' (' || x.kategori || ')', ''), ', ' order by x.urut) from public.rc_form_verifikasi x
            where x.proses_id = f.proses_id and x.depot_id = t.depot_id and x.customer_id = t.customer_id) nomor) fu on f.proses_id is not null$p$,
    1, 'list fu');
  src := pg_temp.ganti(src,
    $p$left join lateral (select count(*) n from public.rc_form_verifikasi x$p$,
    $p$left join lateral (select count(distinct x.proses_id) n from public.rc_form_verifikasi x$p$, 1, 'list n');
  src := pg_temp.ganti(src,
    $p$'unduh', case when h.no_form is null then null else jsonb_build_object('noForm', h.no_form,$p$,
    $p$'unduh', case when h.no_form is null then null else jsonb_build_object('noForm', coalesce(h.nomor_unduh, h.no_form),$p$, 1, 'list unduh');
  src := pg_temp.ganti(src,
    $p$'jumlahUnduh', h.n_unduh, 'berubah', h.berubah) order by h.depot_code, h.kode)$p$,
    $p$'jumlahUnduh', h.n_unduh, 'berubah', h.berubah,
             'remark', concat_ws(' + ', case when h.ada_pda then 'PDA' end, case when h.ada_pdh then 'PDH' end) /* 20261163700000 */) order by h.depot_code, h.kode)$p$,
    1, 'list remark');
  execute src;
end $tambal$;

do $cek$ begin
  if pg_get_functiondef('public.rc_docgen_list(text,jsonb,integer,integer,boolean)'::regprocedure) !~ 'ada_pda' then raise exception 'GAGAL: list'; end if;
  if pg_get_functiondef('public.rc_docgen_generate(jsonb,text,jsonb)'::regprocedure) !~ 'docgen_batas_pda' then raise exception 'GAGAL: generate'; end if;
end $cek$;
