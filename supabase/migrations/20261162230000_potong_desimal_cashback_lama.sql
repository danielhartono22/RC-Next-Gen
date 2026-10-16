-- ==========================================================================================
-- Cashback lama yang berdesimal dipotong ke rupiah bulat
-- ==========================================================================================
-- Lanjutan 20261162210000. Pemilik, 12 Oktober 2026, memilih "Potong semua" untuk klaim yang
-- sudah tersimpan berdesimal (di prod: 130 klaim, total pecahan Rp 61,34, pecahan terbesar
-- 0,983) - semuanya berasal dari muat ulang, bukan dari Document Center.
--
-- Cashback dipotong (trunc), sama dengan yang selama ini tampil di layar dan tertulis di berkas
-- Claim to Finance. Gross up dihitung ulang dari cashback yang sudah dipotong dengan rumus yang
-- sama (rc_private.gross_claimed). version_no dinaikkan seperti perubahan nominal lainnya,
-- supaya layar yang masih memegang versi lama tidak menimpanya.
--
-- Klaim tanpa Customer Master DILEWATI: jaga_customer_master_klaim memang menolak setiap
-- perubahan atas klaim seperti itu sampai master-nya ada (di prod: 5 klaim).
--
-- Nilai lama setiap klaim dicatat di activity_logs supaya dapat ditelusuri. Aman dijalankan
-- berulang: jalan kedua tidak menemukan apa pun lagi.
-- ==========================================================================================

do $potong$
declare n int; v_lama jsonb; v_selisih numeric; v_lewat int;
begin
  select count(*) into v_lewat from public.claims where cb_net <> trunc(cb_net) and customer_id is null;

  create temp table _desimal on commit drop as
    select c.id from public.claims c where c.cb_net <> trunc(c.cb_net) and c.customer_id is not null;
  select coalesce(jsonb_agg(jsonb_build_object('noDoc', c.no_doc, 'cbNetLama', c.cb_net, 'grossUpLama', c.gross_up) order by c.no_doc), '[]'),
         coalesce(sum(c.cb_net - trunc(c.cb_net)), 0), count(*)
    into v_lama, v_selisih, n
    from public.claims c join _desimal d on d.id = c.id;
  if n = 0 then raise notice 'Tidak ada cashback berdesimal (dilewati tanpa master: %).', v_lewat; return; end if;

  update public.claims c
     set cb_net = trunc(c.cb_net),
         gross_up = rc_private.gross_claimed(trunc(c.cb_net), cu.tax_subject, ca.tax_status),
         version_no = c.version_no + 1,
         updated_at = now()
    from public.customers cu, public.campaigns ca
   where cu.id = c.customer_id and ca.id = c.campaign_id
     and c.id in (select id from _desimal);

  -- Pemeriksaan: tidak ada lagi desimal pada klaim yang punya master, dan gross up tetap sesuai rumus.
  if exists(select 1 from public.claims where cb_net <> trunc(cb_net) and customer_id is not null) then
    raise exception 'GAGAL: masih ada cashback berdesimal.'; end if;
  if exists(select 1 from public.claims c join _desimal d on d.id = c.id
               join public.customers cu on cu.id = c.customer_id join public.campaigns ca on ca.id = c.campaign_id
             where c.gross_up is distinct from rc_private.gross_claimed(c.cb_net, cu.tax_subject, ca.tax_status)) then
    raise exception 'GAGAL: gross up tidak sesuai rumus sesudah pemotongan.'; end if;

  insert into public.activity_logs(actor_id, event_type, details)
  values (null, 'cashback_desimal_dipotong', jsonb_build_object(
    'migrasi', '20261162230000', 'klaim', n, 'totalPecahan', v_selisih,
    'dilewatiTanpaCustomerMaster', v_lewat, 'nilaiLama', v_lama));
  raise notice 'Cashback dipotong: % klaim, total pecahan %; dilewati tanpa master: %.', n, v_selisih, v_lewat;
end
$potong$;
