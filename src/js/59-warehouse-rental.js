            // ============================================================================
            // WAREHOUSE RENTAL - FORM F01.AW.2025 (20261163530000)
            // ============================================================================
            // PRD "Modul Warehouse Rental" (pemilik, 27 Oktober 2026), fase 1-2: Upload Omset, Fill
            // Form, Draft, Submitted, PDF dengan logo. Revenue PY-1 / PY / PY YTD / Act YTD datang dari
            // server (rc_rental_revenue, net = omset - pajak) dan hanya pemegang Upload Omset yang boleh
            // meng-override-nya dengan alasan. Rumus dihitung di sini untuk tampilan langsung dan
            // dihitung ulang server saat simpan / submit (rental.hitung) - angka server yang tersimpan
            // dan tercetak. PDF digambar dari data tersimpan dengan jsPDF (dimuat saat dibutuhkan);
            // PDF hasil submit diunggah ke bucket rental-pdf dan diunduh ulang dari sana.

            const WR_MEREK = ['AVIAN', 'PROPAN', 'DULUX', 'JOTUN', 'MOWILEX', 'DANAPAINT', 'PACIFIC PAINT', 'KEMTONE', 'OTHERS'];
            const WR_FASILITAS = [['mess', 'Mess'], ['musholla', 'Musholla'], ['parking', 'Parking Area'], ['cctv', 'CCTV'], ['security', 'Security']];
            const WR_REV = [['py1', 'wrRvPy1', 'PY-1'], ['py', 'wrRvPy', 'PY'], ['pyytd', 'wrRvPyytd', 'PY YTD'], ['actytd', 'wrRvAct', 'Act YTD']];
            const WR_ANGKA = ['wrCompSum', 'wrCompShare', 'wrRvBud', 'wrRvEst', 'wrSzPy1', 'wrSzPy', 'wrSzBud', 'wrSzEst', 'wrLand', 'wrWh', 'wrOff', 'wrOffer', 'wrTotalTahun', 'wrIpl'];
            const WR_JSPDF = 'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js';
            const WR_NAMA_BULAN = ['Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'];
            let rcWr = { init: null, id: null, row: null, omset: null, aktif: null, override: {}, kunci: false, daftar: { draft: [], submitted: [] }, unggah: null };
            let rcWrPustaka = null, rcWrLogo = null, rcWrRevKe = 0;

            const wrEl = id => document.getElementById(id);

            function switchRentalTab(tab) {
                if (!rcEnterTab('rental', tab)) return;
                wrTampilPanel(tab);
                wrSiapkan().then(ok => {
                    if (!ok) return;
                    if (tab === 'form') { if (!rcWr.row && !rcWr.id) wrFormBaru(false); else wrTerapkanKunci(); }
                    else if (tab === 'omset') wrMuatOmset();
                    else wrMuatDaftar(tab);
                });
            }

            function wrTampilPanel(tab) {
                [['form', 'wrTabForm', 'wrPanelForm'], ['draft', 'wrTabDraft', 'wrPanelDraft'], ['submitted', 'wrTabSubmitted', 'wrPanelSubmitted'], ['omset', 'wrTabOmset', 'wrPanelOmset']].forEach(([t, b, p]) => {
                    const el = wrEl(b);
                    if (el) el.className = 'px-5 py-2 text-sm font-bold rounded-lg ' + (t === tab ? 'bg-amber-100 text-amber-800' : 'text-gray-500 hover:bg-gray-100');
                    setHiddenSafely(p, t !== tab);
                });
                if (tab === 'form') setTextSafely('wrRingkas', 'Form F01.AW.2025 - Rental New / Re-newal Submission.');
            }

            async function wrSiapkan() {
                if (rcWr.init) return true;
                showLoadingOverlay('Memuat Warehouse Rental...');
                try {
                    const r = await fetchApp({ action: 'rentalInit' });
                    if (r.status !== 'success') throw new Error(r.message || 'Warehouse Rental gagal dimuat');
                    rcWr.init = r;
                    wrBangunForm();
                    return true;
                } catch (e) { showNotification(e.message, 'error'); return false; }
                finally { hideLoadingOverlay(); }
            }

            function wrBangunForm() {
                wrEl('wrDepot').innerHTML = '<option value="">- Pilih depot -</option>'
                    + rcWr.init.depots.map(d => '<option value="' + rcEsc(d.id) + '">' + rcEsc(d.kode + ' - ' + d.nama) + '</option>').join('');
                wrEl('wrKompetitor').innerHTML = WR_MEREK.map(m => '<label class="inline-flex items-center gap-2 px-3 py-1.5 border border-gray-300 rounded-lg cursor-pointer font-bold text-xs has-[:checked]:bg-amber-50 has-[:checked]:border-amber-400 has-[:checked]:text-amber-900"><input type="checkbox" name="wrKomp" value="' + rcEsc(m) + '" onchange="wrHitungUlang()"> ' + rcEsc(m) + '</label>').join('');
                // Urutan sama dengan Excel: 1-5 di kiri, 6-10 di kanan.
                wrEl('wrCovered').innerHTML = [1, 6, 2, 7, 3, 8, 4, 9, 5, 10].map(i => '<label class="flex items-center gap-2"><span class="w-5 text-right text-xs font-bold text-gray-500">' + i + '</span><input id="wrCa' + i + '" type="text" maxlength="60" placeholder="Area ' + i + '" class="flex-1 min-w-0 px-3 py-2 border border-gray-300 rounded-lg uppercase disabled:bg-gray-50"></label>').join('');
            }

            // ---------- Angka & tanggal ----------
            // Angka diketik bergaya id-ID: titik ribuan, koma desimal. Kosong = null; NaN = tidak valid.
            function wrAngka(v) {
                const s = String(v == null ? '' : v).replace(/\s/g, '');
                if (!s || s === '-') return null;
                const n = Number(s.replace(/\./g, '').replace(',', '.'));
                return Number.isFinite(n) ? n : NaN;
            }
            function wrTulisAngka(v) {
                if (v === null || v === undefined || v === '') return '';
                const n = Number(v);
                return Number.isFinite(n) ? n.toLocaleString('id-ID', { maximumFractionDigits: 2 }) : '';
            }
            function wrFormatAngka(el, bolehNegatif) {
                const lama = el.value, dariKanan = lama.length - (el.selectionStart == null ? lama.length : el.selectionStart);
                let s = lama.replace(/[^0-9,-]/g, '');
                const neg = !!bolehNegatif && s.startsWith('-');
                s = s.replace(/-/g, '');
                const bagian = s.split(','), bulat = bagian[0].replace(/^0+(?=\d)/, '').slice(0, 15), pecahan = bagian.slice(1).join('').slice(0, 2);
                let hasil = (bulat ? Number(bulat).toLocaleString('id-ID') : (bagian.length > 1 ? '0' : '')) + (bagian.length > 1 ? ',' + pecahan : '');
                if (neg) hasil = '-' + hasil;
                el.value = hasil;
                const pos = Math.max(0, hasil.length - dariKanan);
                try { el.setSelectionRange(pos, pos); } catch (e) { /* jenis input tanpa kursor */ }
                wrHitungUlang();
            }
            function wrUang(v) { return v === null || v === undefined || !Number.isFinite(Number(v)) ? '-' : Math.trunc(Number(v)).toLocaleString('id-ID'); }
            function wrPersen(v) { return v === null || v === undefined || !Number.isFinite(Number(v)) ? '-' : (Number(v) * 100).toLocaleString('id-ID', { minimumFractionDigits: 1, maximumFractionDigits: 1 }) + '%'; }
            // dd-Mmm-yyyy (hasil normalizeDateUI) -> yyyy-mm-dd.
            function wrIso(teks) {
                const m = String(teks || '').match(/^(\d{2})-([A-Za-z]{3})-(\d{4})$/);
                if (!m) return '';
                const b = RC_BULAN_SINGKAT.indexOf(m[2]);
                return b < 0 ? '' : m[3] + '-' + String(b + 1).padStart(2, '0') + '-' + m[1];
            }
            function wrTanggalBerubah(el) {
                const n = normalizeDateUI(el.value);
                if (el.value.trim() && !n) { showNotification('Date Propose harus dd-mm-yyyy, dd.mm.yyyy, dd-mm-yy, dd.mm.yy, ddmmyy, atau ddmmyyyy.', 'warning'); el.value = ''; }
                else el.value = n;
                wrHeaderBerubah();
            }

            // ---------- Isi / baca form ----------
            function wrNilai(name) { const el = document.querySelector('input[name="' + name + '"]:checked'); return el ? el.value : null; }
            function wrSetNilai(name, v) { document.querySelectorAll('input[name="' + name + '"]').forEach(el => { el.checked = v !== null && v !== undefined && el.value === String(v); }); }
            function wrKumpul() {
                const a = id => wrAngka(wrEl(id).value), t = id => String(wrEl(id).value || '').replace(/\s+/g, ' ').trim().toUpperCase();
                const tahun = wrNilai('wrTahun');
                return {
                    leaseType: wrNilai('wrLease'), rentalYears: tahun ? Number(tahun) : null,
                    competitors: Array.from(document.querySelectorAll('input[name="wrKomp"]:checked')).map(e => e.value),
                    competitorOther: t('wrKompetitorLain'), competitorSum: a('wrCompSum'), competitorShare: a('wrCompShare'),
                    coveredArea: Array.from({ length: 10 }, (_, i) => t('wrCa' + (i + 1))),
                    revBudget: a('wrRvBud'), revEstimate: a('wrRvEst'), revOverride: rcWr.override,
                    sizePy1: a('wrSzPy1'), sizePy: a('wrSzPy'), sizeBudget: a('wrSzBud'), sizeEstimate: a('wrSzEst'),
                    landSize: a('wrLand'), warehouseSize: a('wrWh'), officeSize: a('wrOff'), offeringPrice: a('wrOffer'), totalYears: a('wrTotalTahun'),
                    facilities: Array.from(document.querySelectorAll('input[name="wrFas"]:checked')).map(e => e.value),
                    pph: wrNilai('wrPph'), pbb: wrNilai('wrPbb'), notaris: wrNilai('wrNot'), ipl: a('wrIpl'),
                    ownerName: t('wrOwner'), ownerPhone: t('wrPhone'), ownerAddress: t('wrAlamat')
                };
            }
            function wrIsiForm(p) {
                p = p || {};
                const ang = (id, v) => { wrEl(id).value = wrTulisAngka(v); }, teks = (id, v) => { wrEl(id).value = v || ''; };
                wrSetNilai('wrLease', p.leaseType); wrSetNilai('wrTahun', p.rentalYears);
                document.querySelectorAll('input[name="wrKomp"]').forEach(el => { el.checked = (p.competitors || []).includes(el.value); });
                teks('wrKompetitorLain', p.competitorOther); ang('wrCompSum', p.competitorSum); ang('wrCompShare', p.competitorShare);
                for (let i = 1; i <= 10; i++) teks('wrCa' + i, (p.coveredArea || [])[i - 1]);
                ang('wrRvBud', p.revBudget); ang('wrRvEst', p.revEstimate);
                ang('wrSzPy1', p.sizePy1); ang('wrSzPy', p.sizePy); ang('wrSzBud', p.sizeBudget); ang('wrSzEst', p.sizeEstimate);
                ang('wrLand', p.landSize); ang('wrWh', p.warehouseSize); ang('wrOff', p.officeSize); ang('wrOffer', p.offeringPrice);
                ang('wrTotalTahun', p.totalYears !== null && p.totalYears !== undefined ? p.totalYears : p.rentalYears);
                document.querySelectorAll('input[name="wrFas"]').forEach(el => { el.checked = (p.facilities || []).includes(el.value); });
                wrSetNilai('wrPph', p.pph); wrSetNilai('wrPbb', p.pbb); wrSetNilai('wrNot', p.notaris); ang('wrIpl', p.ipl);
                teks('wrOwner', p.ownerName); teks('wrPhone', p.ownerPhone); teks('wrAlamat', p.ownerAddress);
                rcWr.override = Object.assign({}, p.revOverride || {});
            }
            // Field wajib saat submit - sama dengan rental.kurang di server.
            function wrKurang(p) {
                const k = [];
                if (!p.leaseType) k.push('Jenis sewa (New Lease / Re-newal)');
                if (!p.rentalYears) k.push('Rental Plane');
                if (!p.coveredArea.some(x => x)) k.push('Covered Area (minimal 1)');
                if (p.competitors.includes('OTHERS') && !p.competitorOther) k.push('Nama competitor OTHERS');
                if (!(p.warehouseSize > 0)) k.push('Warehouse Size');
                if (!(p.offeringPrice > 0)) k.push('Offering Price');
                if (!p.pph) k.push('Income Tax (PPH)');
                if (!p.pbb) k.push('Land Tax (PBB)');
                if (!p.notaris) k.push('Notaries Fee');
                if (!p.ownerName) k.push('Owners / Agent');
                if (!p.ownerAddress) k.push('Properties Address');
                return k;
            }

            function wrFormBaru(tanya) {
                const lanjut = () => {
                    rcWr.id = null; rcWr.row = null; rcWr.omset = null; rcWr.aktif = null; rcWr.override = {};
                    wrEl('wrDepot').value = rcWr.init.depots.length === 1 ? rcWr.init.depots[0].id : '';
                    wrEl('wrTanggal').value = normalizeDateUI((() => { const d = new Date(Date.now() + 7 * 3600000); return String(d.getUTCDate()).padStart(2, '0') + '-' + String(d.getUTCMonth() + 1).padStart(2, '0') + '-' + d.getUTCFullYear(); })());
                    wrIsiForm({});
                    wrTerapkanKunci();
                    wrHeaderBerubah();
                };
                if (!tanya || !(rcWr.id || wrKumpul().ownerName || wrKumpul().offeringPrice)) { lanjut(); return; }
                showConfirmModal({ title: 'Form Baru', message: 'Isi form yang belum disimpan akan hilang. Lanjutkan?', confirmText: 'Form Baru', danger: false }).then(ok => { if (ok) lanjut(); });
            }

            function wrMuatBaris(row) {
                rcWr.row = row; rcWr.id = row.id;
                wrEl('wrDepot').value = row.depot.id;
                if (!wrEl('wrDepot').value) {
                    // Depot form tidak ada di daftar pilihan akun ini (mis. hanya melihat): ditambahkan sebagai pilihan.
                    wrEl('wrDepot').insertAdjacentHTML('beforeend', '<option value="' + rcEsc(row.depot.id) + '">' + rcEsc(row.depot.kode + ' - ' + row.depot.nama) + '</option>');
                    wrEl('wrDepot').value = row.depot.id;
                }
                wrEl('wrTanggal').value = rcDisplayDate(row.tanggal);
                wrIsiForm(row.data);
                rcWr.omset = row.omset; rcWr.aktif = null;
                wrTerapkanKunci();
                wrHitungUlang();
            }

            async function wrBuka(id) {
                showLoadingOverlay('Membuka form...');
                try {
                    const r = await fetchApp({ action: 'rentalGet', id: id });
                    if (r.status !== 'success') throw new Error(r.message || 'Form gagal dibuka.');
                    wrTampilPanel('form');
                    wrMuatBaris(r.row);
                    window.scrollTo({ top: 0, behavior: 'smooth' });
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // Form terkunci: Submitted / Cancelled, atau akun tanpa tab Fill Form (hanya melihat).
            function wrTerapkanKunci() {
                const row = rcWr.row, bolehUbah = rcCanTab('rental.form') || !!(rcWr.init && rcWr.init.admin);
                rcWr.kunci = !!(row && row.status !== 'draft') || !bolehUbah;
                document.querySelectorAll('#wrLembar input, #wrLembar select, #wrLembar textarea').forEach(el => { el.disabled = rcWr.kunci; });
                setHiddenSafely('wrBtnSimpan', rcWr.kunci); setHiddenSafely('wrBtnSubmit', rcWr.kunci);
                setHiddenSafely('wrBtnPdf', !(row && row.status !== 'draft'));
                const st = !row ? ['Form baru', 'bg-gray-100 text-gray-700'] : row.status === 'draft' ? ['Draft', 'bg-amber-100 text-amber-800']
                    : row.status === 'submitted' ? ['Submitted', 'bg-emerald-100 text-emerald-800'] : ['Cancelled', 'bg-red-100 text-red-700'];
                const badge = wrEl('wrStatus'); badge.textContent = st[0]; badge.className = 'px-2.5 py-1 rounded-md font-bold ' + st[1];
                setTextSafely('wrDocNo', row && row.docNo ? row.docNo : '');
                const info = [];
                if (row && row.dibuat) info.push('Dibuat ' + (row.dibuat.oleh || '-') + ', ' + rcDisplayDate(row.dibuat.pada, true));
                if (row && row.status === 'draft' && row.diubah) info.push('diubah ' + rcDisplayDate(row.diubah.pada, true));
                if (row && row.disubmit) info.push('submit ' + (row.disubmit.oleh || '-') + ', ' + rcDisplayDate(row.disubmit.pada, true));
                if (row && row.dibatalkan) info.push('cancel ' + (row.dibatalkan.oleh || '-') + (row.dibatalkan.alasan ? ': ' + row.dibatalkan.alasan : ''));
                setTextSafely('wrInfo', info.join(' · '));
                wrHitungUlang();
            }

            // Total Price for N Year: N mengikuti Rental Plane yang dipilih dan sesudahnya boleh diubah.
            function wrRentalPlaneBerubah(el) { wrEl('wrTotalTahun').value = wrTulisAngka(el.value); wrHitungUlang(); }

            // ---------- Revenue & rumus ----------
            async function wrHeaderBerubah() {
                const depot = wrEl('wrDepot').value, tgl = wrIso(wrEl('wrTanggal').value), ke = ++rcWrRevKe;
                wrTahunKepala(tgl);
                if (!depot || !tgl) { rcWr.omset = null; rcWr.aktif = null; wrHitungUlang(); return; }
                if (rcWr.kunci && rcWr.row) { wrHitungUlang(); return; }
                try {
                    const r = await fetchApp({ action: 'rentalRevenue', depotId: depot, tanggal: tgl });
                    if (ke !== rcWrRevKe) return;
                    if (r.status !== 'success') throw new Error(r.message || 'Omset gagal dimuat.');
                    rcWr.omset = r.omset; rcWr.aktif = r.aktif && r.aktif.id !== rcWr.id ? r.aktif : null;
                } catch (e) { if (ke === rcWrRevKe) { rcWr.omset = null; showNotification(e.message, 'error'); } }
                wrHitungUlang();
            }

            function wrTahunKepala(tgl) {
                const m = String(tgl || '').match(/^(\d{4})-(\d{2})/), y = m ? Number(m[1]) : null, b = m ? Number(m[2]) : null;
                const isi = y ? [y - 2, y - 1, (y - 1) + ' MONTH ' + b, y + ' MONTH ' + b, y, y + 1] : ['', '', '', '', '', ''];
                ['wrThPy1', 'wrThPy', 'wrThPyytd', 'wrThAct', 'wrThBud', 'wrThEst'].forEach((id, i) => setTextSafely(id, String(isi[i])));
            }

            function wrRevAkhir(omset, override) {
                const o = {};
                WR_REV.forEach(([k]) => {
                    const ov = override && override[k];
                    o[k] = ov && ov.nilai !== null && ov.nilai !== undefined ? { nilai: Number(ov.nilai), sumber: 'override', alasan: ov.alasan, oleh: ov.oleh, pada: ov.pada, omset: omset ? omset[k] : null }
                        : { nilai: omset && omset[k] !== null && omset[k] !== undefined ? Number(omset[k]) : null, sumber: 'omset' };
                });
                return o;
            }

            function wrBagi(a, b) { return a === null || a === undefined || b === null || b === undefined || Number(b) === 0 ? null : Number(a) / Number(b); }
            // Sama dengan rental.hitung di server (sel Excel di kurung).
            function wrHitung(p, rev) {
                const n = v => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v))) ? null : Number(v);
                const r = k => n(rev && rev[k] && rev[k].nilai);
                const wh = n(p.warehouseSize), off = n(p.officeSize), luas = wh === null && off === null ? null : (wh || 0) + (off || 0);
                const sz = k => n(p[k]) !== null ? n(p[k]) : luas;
                const g = (a, b) => { const x = wrBagi(a, b); return x === null ? null : x - 1; };
                const harga = n(p.offeringPrice), th = n(p.totalYears) !== null ? n(p.totalYears) : n(p.rentalYears);
                return {
                    growthPy: g(r('py'), r('py1')), growthActYtd: g(r('actytd'), r('pyytd')),                 // E23, H23
                    growthBudget: g(n(p.revBudget), r('py')), growthEstimate: g(n(p.revEstimate), n(p.revBudget)), // K23, L23
                    sizePy1: sz('sizePy1'), sizePy: sz('sizePy'), sizeBudget: sz('sizeBudget'), sizeEstimate: sz('sizeEstimate'),
                    revSqmPy1: wrBagi(r('py1'), sz('sizePy1')), revSqmPy: wrBagi(r('py'), sz('sizePy')),         // D25:L25
                    revSqmBudget: wrBagi(n(p.revBudget), sz('sizeBudget')), revSqmEstimate: wrBagi(n(p.revEstimate), sz('sizeEstimate')),
                    totalYears: th, totalPrice: th === null || harga === null ? null : th * harga,              // E38, N dapat diisi sendiri
                    pricePerM2Month: wrBagi(wrBagi(harga, luas), 12),                                          // E39, tanpa IPL
                    labelSewa: p.leaseType === 'new' ? 'NEW LEASE / SEWA BARU' : p.leaseType === 'renewal' ? 'RE-NEWAL / PERPANJANG SEWA' : '-'
                };
            }

            function wrHitungUlang() {
                if (!rcWr.init) return;
                const p = wrKumpul(), terkunci = rcWr.kunci && rcWr.row;
                const rev = terkunci ? rcWr.row.revenue : wrRevAkhir(rcWr.omset, rcWr.override);
                const c = terkunci ? rcWr.row.calc : wrHitung(p, rev);
                const admin = !!rcWr.init.admin && !rcWr.kunci;
                WR_REV.forEach(([k, id, label]) => {
                    const v = rev && rev[k], ov = v && v.sumber === 'override';
                    wrEl(id).innerHTML = '<div class="flex items-center justify-end gap-1">'
                        + (ov ? '<i class="fas fa-pen text-amber-600" title="Override: ' + rcEsc((v.alasan || '') + (v.oleh ? ' (' + v.oleh + ')' : '')) + '"></i>' : '<i class="fas fa-database text-blue-400 text-[9px]" title="Dari Upload Omset"></i>')
                        + '<span class="' + (ov ? 'text-amber-800 font-bold' : '') + '">' + rcEsc(wrUang(v && v.nilai)) + '</span>'
                        + (admin ? '<button type="button" onclick="wrOverride(\'' + k + '\')" class="ml-1 text-[10px] text-blue-700 underline" title="Override Revenue ' + label + '">ubah</button>' : '') + '</div>';
                });
                [['wrGrPy', 'growthPy'], ['wrGrAct', 'growthActYtd'], ['wrGrBud', 'growthBudget'], ['wrGrEst', 'growthEstimate']].forEach(([id, k]) => setTextSafely(id, wrPersen(c[k])));
                [['wrRsPy1', 'revSqmPy1'], ['wrRsPy', 'revSqmPy'], ['wrRsBud', 'revSqmBudget'], ['wrRsEst', 'revSqmEstimate']].forEach(([id, k]) => setTextSafely(id, wrUang(c[k])));
                const luas = (p.warehouseSize === null && p.officeSize === null) ? '' : wrTulisAngka((p.warehouseSize || 0) + (p.officeSize || 0));
                ['wrSzPy1', 'wrSzPy', 'wrSzBud', 'wrSzEst'].forEach(id => { wrEl(id).placeholder = luas; });
                setTextSafely('wrLabelSewa', c.labelSewa);
                setTextSafely('wrTotal', wrUang(c.totalPrice));
                setTextSafely('wrM2', wrUang(c.pricePerM2Month));
                setHiddenSafely('wrKompetitorLain', !p.competitors.includes('OTHERS'));
                wrTampilPeringatan(terkunci ? rcWr.row.omset : rcWr.omset);
            }

            // "Januari-Desember 2024, Agustus 2026": bulan berurutan dalam satu tahun digabung.
            function wrRingkasBulan(daftar) {
                const kel = [];
                (daftar || []).forEach(s => {
                    const y = Number(s.slice(0, 4)), m = Number(s.slice(5, 7)), akhir = kel[kel.length - 1];
                    if (akhir && akhir.y === y && akhir.sampai === m - 1) akhir.sampai = m; else kel.push({ y: y, dari: m, sampai: m });
                });
                return kel.map(k => (k.dari === k.sampai ? WR_NAMA_BULAN[k.dari - 1] : WR_NAMA_BULAN[k.dari - 1] + '-' + WR_NAMA_BULAN[k.sampai - 1]) + ' ' + k.y);
            }

            function wrTampilPeringatan(omset) {
                const pesan = [];
                if (rcWr.aktif) pesan.push('<i class="fas fa-circle-exclamation mr-1"></i>Depot ini sudah punya form ' + (rcWr.aktif.status === 'draft' ? 'Draft' : 'Submitted ' + rcEsc(rcWr.aktif.docNo || ''))
                    + ' untuk tahun yang sama. Satu depot hanya satu submission aktif; buka form itu dari tab Draft / Submitted, atau batalkan lebih dulu.');
                const hilang = omset && omset.hilang || [];
                if (hilang.length) pesan.push('<i class="fas fa-triangle-exclamation mr-1"></i>Omset ' + rcEsc(wrRingkasBulan(hilang).join(', ')) + ' belum ada. Revenue dihitung dari bulan yang sudah ter-upload' + (rcWr.kunci ? '' : '; submit tetap diizinkan') + '.');
                const el = wrEl('wrPeringatan'); el.innerHTML = pesan.map(x => '<div>' + x + '</div>').join('');
                setHiddenSafely('wrPeringatan', !pesan.length);
            }

            function wrOverride(k) {
                const label = (WR_REV.find(x => x[0] === k) || [])[2], ada = rcWr.override[k], asli = rcWr.omset ? rcWr.omset[k] : null;
                window.__wrOverride = function (aksi) {
                    if (aksi === 'simpan') {
                        const n = wrAngka(wrEl('wrOvNilai').value), alasan = String(wrEl('wrOvAlasan').value || '').trim();
                        if (n === null || Number.isNaN(n)) { showNotification('Isi nilai Revenue override.', 'warning'); return; }
                        if (alasan.length < 3) { showNotification('Alasan override wajib diisi.', 'warning'); return; }
                        rcWr.override[k] = { nilai: n, alasan: alasan };
                    } else if (aksi === 'hapus') delete rcWr.override[k];
                    window.__wrOverride = null; rcTutupDialog(); wrHitungUlang();
                };
                rcDialog('Override Revenue ' + label, '<div class="space-y-3 text-sm"><p>Nilai dari Upload Omset: <b>' + rcEsc(wrUang(asli)) + '</b>. Override menggantikan nilai itu di form dan PDF; alasannya tercatat.</p>'
                    + '<label class="block font-bold">Revenue (IDR)<input id="wrOvNilai" type="text" inputmode="decimal" oninput="wrFormatAngka(this, true)" value="' + rcEsc(ada ? wrTulisAngka(ada.nilai) : '') + '" class="mt-1 w-full px-3 py-2 border border-gray-300 rounded-lg text-right"></label>'
                    + '<label class="block font-bold">Alasan (wajib)<textarea id="wrOvAlasan" rows="2" maxlength="200" class="mt-1 w-full px-3 py-2 border border-gray-300 rounded-lg">' + rcEsc(ada ? ada.alasan : '') + '</textarea></label>'
                    + '<div class="flex justify-between gap-2">' + (ada ? '<button type="button" onclick="window.__wrOverride(\'hapus\')" class="px-4 py-2 border border-red-200 text-red-700 rounded-lg font-bold">Pakai nilai omset</button>' : '<span></span>')
                    + '<span class="flex gap-2"><button type="button" onclick="window.__wrOverride(\'batal\')" class="px-4 py-2 border border-gray-300 rounded-lg font-bold">Batal</button>'
                    + '<button type="button" onclick="window.__wrOverride(\'simpan\')" class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-bold">Terapkan</button></span></div></div>');
            }

            // ---------- Simpan / submit ----------
            async function wrSimpan(submit) {
                if (rcWr.kunci) return;
                const depot = wrEl('wrDepot').value, tgl = wrIso(wrEl('wrTanggal').value);
                if (!depot || !tgl) { showNotification('Isi Depot Name dan Date Propose lebih dulu.', 'warning'); return; }
                const data = wrKumpul();
                const salah = WR_ANGKA.filter(id => Number.isNaN(wrAngka(wrEl(id).value)));
                if (salah.length) { showNotification('Ada angka yang tidak valid. Periksa kolom yang ditandai.', 'warning'); salah.forEach(id => wrEl(id).classList.add('bg-red-50')); return; }
                if (submit) {
                    const kurang = wrKurang(data);
                    if (kurang.length) { showNotification('Form belum lengkap: ' + kurang.join(', '), 'warning'); return; }
                    const ok = await showConfirmModal({ title: 'Submit Form', message: 'Setelah di-submit form terkunci, angka omset dikunci, dan nomor dokumen dibuat. Koreksi hanya lewat Cancel lalu buat form baru. Lanjutkan?', confirmText: 'Submit', danger: false });
                    if (!ok) return;
                }
                showLoadingOverlay(submit ? 'Submit form...' : 'Menyimpan draft...');
                let r;
                try {
                    r = await fetchApp({ action: 'rentalSimpan', id: rcWr.id, depotId: depot, tanggal: tgl, data: data, submit: !!submit });
                    if (r.status !== 'success') throw new Error(r.message || 'Gagal menyimpan.');
                } catch (e) { hideLoadingOverlay(); showNotification(e.message, 'error'); return; }
                wrMuatBaris(r.row);
                if (submit) {
                    try {
                        showLoadingOverlay('Membuat PDF...');
                        await wrSimpanPdf(r.row);
                    } catch (e) {
                        hideLoadingOverlay();
                        showNotification('Form di-submit (' + r.row.docNo + '), tetapi PDF gagal disimpan: ' + e.message + ' Unduh ulang dari tab Submitted.', 'warning');
                        return;
                    }
                }
                hideLoadingOverlay();
                showNotification(r.message, 'success');
            }

            // PDF form Submitted: diunggah sekali ke Storage (bila belum), lalu diunduh.
            async function wrSimpanPdf(row) {
                await wrSiapkanPustaka();
                const doc = wrBuatPdf(row);
                if (row.status === 'submitted' && !row.pdfPath && (rcCanTab('rental.form') || rcWr.init.admin)) {
                    const blob = doc.output('blob');
                    const r = await fetchApp({ action: 'rentalPdfUpload', id: row.id, file: blob, nama: row.namaBerkas });
                    if (r.status !== 'success') throw new Error(r.message || 'PDF gagal diunggah.');
                    row.pdfPath = r.path;
                }
                doc.save(row.namaBerkas);
            }

            async function wrUnduhPdf(id) {
                showLoadingOverlay('Menyiapkan PDF...');
                try {
                    let row = rcWr.row && rcWr.row.id === id ? rcWr.row : null;
                    if (!row) { const r = await fetchApp({ action: 'rentalGet', id: id }); if (r.status !== 'success') throw new Error(r.message || 'Form gagal dibuka.'); row = r.row; }
                    if (row.pdfPath) {
                        const r = await fetchApp({ action: 'rentalPdfUnduh', path: row.pdfPath, nama: row.namaBerkas });
                        if (r.status !== 'success') throw new Error(r.message || 'PDF gagal diunduh.');
                    } else await wrSimpanPdf(row);
                    if (rcWr.daftar.submitted.length) wrMuatDaftar('submitted', true);
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
            }
            function wrUnduhPdfAktif() { if (rcWr.row) wrUnduhPdf(rcWr.row.id); }

            // Preview isi form saat ini (belum tentu tersimpan), selalu bertanda DRAFT kecuali form Submitted.
            async function wrPreviewPdf() {
                const jendela = window.open('', '_blank');
                try {
                    await wrSiapkanPustaka();
                    let row = rcWr.row;
                    if (!rcWr.kunci) {
                        const depotId = wrEl('wrDepot').value, d = (rcWr.init.depots.find(x => x.id === depotId)) || (row && row.depot) || { kode: '', nama: '', abbr: '' };
                        const p = wrKumpul(), rev = wrRevAkhir(rcWr.omset, rcWr.override);
                        row = Object.assign({}, row || {}, { status: 'draft', docNo: null, tanggal: wrIso(wrEl('wrTanggal').value), depot: d, data: p, revenue: rev, calc: wrHitung(p, rev), omset: rcWr.omset,
                            dibuat: (row && row.dibuat) || { oleh: currentUserData && currentUserData.nama } });
                    }
                    const url = wrBuatPdf(row).output('bloburl');
                    if (jendela) jendela.location.href = url; else window.open(url, '_blank');
                } catch (e) { if (jendela) jendela.close(); showNotification(e.message, 'error'); }
            }

            // ---------- Draft / Submitted ----------
            async function wrMuatDaftar(status, diam) {
                if (!diam) showLoadingOverlay('Memuat ' + (status === 'draft' ? 'draft' : 'form submitted') + '...');
                try {
                    const r = await fetchApp({ action: 'rentalList', status: status });
                    if (r.status !== 'success') throw new Error(r.message || 'Daftar gagal dimuat.');
                    rcWr.daftar[status] = r.rows || [];
                    if (status === 'draft') wrRenderDraft(); else wrRenderSubmitted();
                } catch (e) { showNotification(e.message, 'error'); }
                finally { if (!diam) hideLoadingOverlay(); }
            }
            function wrSewa(v) { return v === 'new' ? 'New Lease' : v === 'renewal' ? 'Re-newal' : '-'; }
            function wrRenderDraft() {
                const rows = rcWr.daftar.draft, ubah = rcCanTab('rental.form') || rcWr.init.admin;
                setTextSafely('wrRingkas', rows.length.toLocaleString('id-ID') + ' draft dalam jangkauan Anda.');
                wrEl('wrBodyDraft').innerHTML = rows.length ? rows.map(r => '<tr class="border-t border-gray-100 hover:bg-gray-50">'
                    + '<td class="p-3 whitespace-nowrap"><b>' + rcEsc(r.depotKode) + '</b><span class="block text-[11px] text-gray-500">' + rcEsc(r.depotNama) + '</span></td>'
                    + '<td class="p-3 whitespace-nowrap">' + rcEsc(rcDisplayDate(r.tanggal)) + '</td>'
                    + '<td class="p-3">' + rcEsc(wrSewa(r.leaseType)) + '</td><td class="p-3">' + (r.rentalYears ? r.rentalYears + ' Tahun' : '-') + '</td>'
                    + '<td class="p-3">' + rcEsc(r.ownerName || '-') + '</td>'
                    + '<td class="p-3 whitespace-nowrap">' + rcEsc(r.dibuatOleh || '-') + '<span class="block text-[11px] text-gray-500">' + rcEsc(rcDisplayDate(r.dibuatPada, true)) + '</span></td>'
                    + '<td class="p-3 whitespace-nowrap">' + rcEsc(rcDisplayDate(r.diubahPada, true)) + '</td>'
                    + '<td class="p-3 text-center whitespace-nowrap"><button onclick="wrBuka(' + rcEsc(JSON.stringify(r.id)) + ')" class="px-2.5 py-1.5 rounded-lg border border-blue-200 text-blue-700 bg-blue-50 hover:bg-blue-100 font-bold">' + (ubah ? 'Continue Edit' : 'Lihat') + '</button>'
                    + (ubah ? ' <button onclick="wrBatal(' + rcEsc(JSON.stringify(r.id)) + ', \'draft\')" class="px-2.5 py-1.5 rounded-lg border border-red-200 text-red-700 bg-red-50 hover:bg-red-100 font-bold" title="Batalkan draft">Batalkan</button>' : '') + '</td></tr>').join('')
                    : '<tr><td colspan="8" class="p-8 text-center text-gray-500">Tidak ada draft yang tersimpan.</td></tr>';
            }
            function wrRenderSubmitted() {
                const st = wrEl('wrSubStatus').value, cari = String(wrEl('wrSubCari').value || '').trim().toLowerCase(), boleh = rcCanTab('rental.form') || rcWr.init.admin;
                const rows = rcWr.daftar.submitted.filter(r => (!st || r.status === st)
                    && (!cari || [r.docNo, r.depotKode, r.depotNama, r.ownerName, r.disubmitOleh].some(x => String(x || '').toLowerCase().includes(cari))));
                setTextSafely('wrRingkas', rcWr.daftar.submitted.filter(r => r.status === 'submitted').length.toLocaleString('id-ID') + ' form submitted dalam jangkauan Anda.');
                wrEl('wrBodySubmitted').innerHTML = rows.length ? rows.map(r => {
                    const id = rcEsc(JSON.stringify(r.id)), batal = r.status === 'cancelled';
                    return '<tr class="border-t border-gray-100 hover:bg-gray-50' + (batal ? ' bg-red-50/30' : '') + '">'
                        + '<td class="p-3 whitespace-nowrap font-mono font-bold">' + rcEsc(r.docNo || '-') + '</td>'
                        + '<td class="p-3 whitespace-nowrap"><b>' + rcEsc(r.depotKode) + '</b><span class="block text-[11px] text-gray-500">' + rcEsc(r.depotNama) + '</span></td>'
                        + '<td class="p-3 whitespace-nowrap">' + rcEsc(rcDisplayDate(r.tanggal)) + '</td>'
                        + '<td class="p-3">' + rcEsc(wrSewa(r.leaseType)) + '</td><td class="p-3">' + (r.rentalYears ? r.rentalYears + ' Tahun' : '-') + '</td>'
                        + '<td class="p-3 text-right whitespace-nowrap font-bold">' + rcEsc(wrUang(r.totalPrice)) + '</td>'
                        + '<td class="p-3 whitespace-nowrap">' + rcEsc(r.disubmitOleh || '-') + '<span class="block text-[11px] text-gray-500">' + rcEsc(rcDisplayDate(r.disubmitPada, true)) + '</span></td>'
                        + '<td class="p-3 whitespace-nowrap">' + (batal ? '<span class="px-2 py-0.5 rounded-md bg-red-50 text-red-700 font-bold border border-red-100">Cancelled</span><span class="block text-[11px] text-red-600 mt-1">' + rcEsc((r.dibatalkanOleh || '') + (r.alasanBatal ? ': ' + r.alasanBatal : '')) + '</span>'
                            : '<span class="px-2 py-0.5 rounded-md bg-emerald-50 text-emerald-700 font-bold border border-emerald-100">Submitted</span>') + '</td>'
                        + '<td class="p-3 text-center whitespace-nowrap"><button onclick="wrBuka(' + id + ')" class="px-2.5 py-1.5 rounded-lg border border-gray-300 bg-white hover:bg-gray-50 font-bold">Lihat</button> '
                        + '<button onclick="wrUnduhPdf(' + id + ')" class="px-2.5 py-1.5 rounded-lg border border-red-200 text-red-700 bg-red-50 hover:bg-red-100" title="Download PDF"><i class="fas fa-file-pdf"></i></button>'
                        + (!batal && boleh ? ' <button onclick="wrBatal(' + id + ', \'submitted\')" class="px-2.5 py-1.5 rounded-lg border border-red-200 text-red-700 bg-white hover:bg-red-50 font-bold">Cancel</button>' : '') + '</td></tr>';
                }).join('') : '<tr><td colspan="9" class="p-8 text-center text-gray-500">Belum ada form yang cocok.</td></tr>';
            }

            function wrMintaAlasan(judul, pesan, tombol) {
                return new Promise(function (selesai) {
                    window.__wrAlasanSelesai = function (ok) {
                        const v = ok ? String((wrEl('wrAlasanIsi') || {}).value || '').trim() : null;
                        if (ok && v.length < 3) { showNotification('Alasan wajib diisi (minimal 3 karakter).', 'warning'); return; }
                        window.__wrAlasanSelesai = null; rcTutupDialog(); selesai(v);
                    };
                    rcDialog(judul, '<div class="space-y-3 text-sm"><p>' + rcEsc(pesan) + '</p>'
                        + '<textarea id="wrAlasanIsi" rows="3" maxlength="300" class="w-full px-3 py-2 border border-gray-300 rounded-lg" placeholder="Alasan (wajib)"></textarea>'
                        + '<div class="flex justify-end gap-2"><button type="button" onclick="window.__wrAlasanSelesai && window.__wrAlasanSelesai(false)" class="px-4 py-2 border border-gray-300 rounded-lg font-bold">Batal</button>'
                        + '<button type="button" onclick="window.__wrAlasanSelesai && window.__wrAlasanSelesai(true)" class="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded-lg font-bold">' + rcEsc(tombol) + '</button></div></div>');
                    setTimeout(function () { const el = wrEl('wrAlasanIsi'); if (el) el.focus(); }, 50);
                });
            }

            async function wrBatal(id, status) {
                let alasan = '';
                if (status === 'submitted') {
                    const r = rcWr.daftar.submitted.find(x => x.id === id);
                    alasan = await wrMintaAlasan('Cancel Form', 'Form ' + ((r && r.docNo) || '') + ' dibatalkan dan tetap tercatat (tidak dihapus). Sesudahnya depot ini dapat membuat form baru untuk tahun yang sama.', 'Cancel Form');
                    if (alasan === null) return;
                } else if (!await showConfirmModal({ title: 'Batalkan Draft', message: 'Draft dibatalkan dan tetap tercatat (tidak dihapus). Lanjutkan?', confirmText: 'Batalkan Draft', danger: true })) return;
                showLoadingOverlay('Membatalkan...');
                try {
                    const r = await fetchApp({ action: 'rentalBatal', id: id, alasan: alasan });
                    if (r.status !== 'success') throw new Error(r.message || 'Gagal membatalkan.');
                    showNotification(r.message, 'success');
                    if (rcWr.id === id) { rcWr.row = null; rcWr.id = null; }
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
                wrMuatDaftar(status === 'draft' ? 'draft' : 'submitted');
            }

            // ---------- Upload Omset ----------
            function wrUnduhTemplateOmset() {
                const contoh = (rcWr.init && rcWr.init.depots[0] && rcWr.init.depots[0].kode) || '1A';
                const wb = XLSX.utils.book_new();
                const ws = XLSX.utils.aoa_to_sheet([['Kode Depot', 'Omset', 'Pajak', 'Bulan'], [contoh, 1250000000, 137500000, '2026-09']]);
                ws['!cols'] = [{ wch: 12 }, { wch: 18 }, { wch: 18 }, { wch: 10 }];
                // Bulan disimpan sebagai teks supaya "2026-09" tidak diubah Excel menjadi tanggal.
                for (let r = 1; r <= 1000; r++) { const ref = XLSX.utils.encode_cell({ c: 3, r: r }); if (!ws[ref]) ws[ref] = { t: 's', v: '' }; ws[ref].z = '@'; }
                ws['!ref'] = 'A1:D' + 2;
                XLSX.utils.book_append_sheet(wb, ws, 'Omset');
                XLSX.writeFile(wb, 'Template_Upload_Omset.xlsx');
            }

            // Bulan dari berkas: YYYY-MM, yyyy-mm-dd, tanggal Excel (nomor seri / Date), atau enam bentuk
            // tanggal ketik RC. Selain itu dikirim apa adanya dan ditolak server per baris.
            function wrBulanBerkas(v) {
                if (v instanceof Date && !Number.isNaN(v.getTime())) return v.getFullYear() + '-' + String(v.getMonth() + 1).padStart(2, '0');
                if (typeof v === 'number' && v > 0 && XLSX.SSF && XLSX.SSF.parse_date_code) {
                    const d = XLSX.SSF.parse_date_code(v);
                    if (d && d.y) return d.y + '-' + String(d.m).padStart(2, '0');
                }
                const s = String(v == null ? '' : v).trim();
                let m = s.match(/^(\d{4})-(\d{1,2})(?:-\d{1,2})?$/);
                if (m) return m[1] + '-' + m[2].padStart(2, '0');
                const n = normalizeDateUI(s), iso = wrIso(n);
                return iso ? iso.slice(0, 7) : s;
            }
            // Angka dari berkas: angka Excel apa adanya; teks 1.250.000 / 1,250,000 / 1250000,5 dibaca.
            function wrAngkaBerkas(v) {
                if (typeof v === 'number') return v;
                const s = String(v == null ? '' : v).replace(/\s/g, '').replace(/^Rp\.?/i, '');
                if (/^-?\d{1,3}(\.\d{3})+(,\d+)?$/.test(s)) return Number(s.replace(/\./g, '').replace(',', '.'));
                if (/^-?\d{1,3}(,\d{3})+(\.\d+)?$/.test(s)) return Number(s.replace(/,/g, ''));
                if (/^-?\d+([.,]\d+)?$/.test(s)) return Number(s.replace(',', '.'));
                return s;
            }

            function wrBacaOmset(input) {
                const berkas = input.files && input.files[0];
                if (!berkas) return;
                if (berkas.size > 10 * 1024 * 1024) { showNotification('Berkas maksimal 10 MB.', 'error'); input.value = ''; return; }
                const fr = new FileReader();
                fr.onload = async function (e) {
                    input.value = '';
                    let rows;
                    try {
                        const wb = XLSX.read(new Uint8Array(e.target.result), { type: 'array', cellDates: false });
                        rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, raw: true, defval: '' });
                    } catch (err) { showNotification('Berkas tidak dapat dibaca: ' + err.message, 'error'); return; }
                    const hIdx = rows.findIndex(r => (r || []).some(c => String(c).trim().toLowerCase() === 'kode depot'));
                    if (hIdx < 0) { showNotification('Header "Kode Depot" tidak ditemukan. Gunakan template.', 'error'); return; }
                    const kol = {}; rows[hIdx].forEach((h, i) => { kol[String(h).trim().toLowerCase()] = i; });
                    const hilang = ['kode depot', 'omset', 'pajak', 'bulan'].filter(k => kol[k] === undefined);
                    if (hilang.length) { showNotification('Kolom tidak ditemukan: ' + hilang.join(', ') + '.', 'error'); return; }
                    const data = [];
                    for (let i = hIdx + 1; i < rows.length; i++) {
                        const r = rows[i] || [], ambil = k => r[kol[k]];
                        if (['kode depot', 'omset', 'pajak', 'bulan'].every(k => String(ambil(k) == null ? '' : ambil(k)).trim() === '')) continue;
                        data.push({ baris: i + 1, kodeDepot: String(ambil('kode depot') == null ? '' : ambil('kode depot')).trim(),
                            omset: wrAngkaBerkas(ambil('omset')), pajak: wrAngkaBerkas(ambil('pajak')), bulan: wrBulanBerkas(ambil('bulan')) });
                    }
                    if (!data.length) { showNotification('Tidak ada baris data.', 'warning'); return; }
                    if (data.length > 5000) { showNotification('Maksimal 5.000 baris sekali upload.', 'error'); return; }
                    rcWr.unggah = { rows: data, nama: berkas.name };
                    showLoadingOverlay('Memeriksa ' + data.length.toLocaleString('id-ID') + ' baris...');
                    try {
                        const res = await fetchApp({ action: 'rentalOmsetUnggah', rows: data, simpan: false, nama: berkas.name });
                        if (res.status !== 'success') throw new Error(res.message || 'Pemeriksaan gagal.');
                        wrPratinjauOmset(res);
                    } catch (err) { showNotification(err.message, 'error'); }
                    finally { hideLoadingOverlay(); }
                };
                fr.readAsArrayBuffer(berkas);
            }

            function wrPratinjauOmset(res) {
                const el = wrEl('wrPratinjauOmset'), baris = (res.baris || []).slice().sort((a, b) => (a.status === 'galat' ? 0 : 1) - (b.status === 'galat' ? 0 : 1));
                const lencana = s => s === 'galat' ? '<span class="px-2 py-0.5 rounded bg-red-100 text-red-700 font-bold">Galat</span>' : s === 'ditimpa' ? '<span class="px-2 py-0.5 rounded bg-amber-100 text-amber-800 font-bold">Ditimpa</span>' : '<span class="px-2 py-0.5 rounded bg-emerald-100 text-emerald-700 font-bold">Baru</span>';
                const valid = Number(res.baru) + Number(res.ditimpa);
                el.innerHTML = '<div class="border border-amber-200 rounded-xl overflow-hidden"><div class="bg-amber-50 px-4 py-3 flex flex-wrap items-center justify-between gap-3">'
                    + '<div class="text-sm"><b>' + rcEsc(rcWr.unggah.nama) + '</b> · <span class="text-emerald-700 font-bold">' + res.baru + ' baru</span> · <span class="text-amber-800 font-bold">' + res.ditimpa + ' ditimpa</span> · <span class="text-red-700 font-bold">' + res.galat + ' galat</span> (tidak disimpan)</div>'
                    + '<div class="flex gap-2"><button onclick="wrBatalPratinjau()" class="px-4 py-2 border border-gray-300 bg-white rounded-lg text-sm font-bold">Batal</button>'
                    + '<button onclick="wrSimpanOmset()" ' + (valid ? '' : 'disabled ') + 'class="px-4 py-2 bg-amber-600 hover:bg-amber-700 disabled:opacity-40 text-white rounded-lg text-sm font-bold">Simpan ' + valid.toLocaleString('id-ID') + ' baris valid</button></div></div>'
                    + '<div class="max-h-96 overflow-auto"><table class="w-full text-xs"><thead class="bg-gray-50 text-gray-600 uppercase text-[11px] sticky top-0"><tr><th class="p-2 text-left">Baris</th><th class="p-2 text-left">Kode Depot</th><th class="p-2 text-left">Bulan</th><th class="p-2 text-right">Omset</th><th class="p-2 text-right">Pajak</th><th class="p-2 text-right">Net</th><th class="p-2 text-right">Net lama</th><th class="p-2 text-left">Status</th></tr></thead><tbody>'
                    + baris.slice(0, 1000).map(b => '<tr class="border-t border-gray-100' + (b.status === 'galat' ? ' bg-red-50/40' : '') + '"><td class="p-2">' + rcEsc(b.baris) + '</td><td class="p-2"><b>' + rcEsc(b.kodeDepot) + '</b> ' + rcEsc(b.depotNama || '') + '</td><td class="p-2">' + rcEsc(b.bulan) + '</td>'
                        + '<td class="p-2 text-right">' + rcEsc(typeof b.omset === 'number' ? wrUang(b.omset) : b.omset) + '</td><td class="p-2 text-right">' + rcEsc(typeof b.pajak === 'number' ? wrUang(b.pajak) : b.pajak) + '</td>'
                        + '<td class="p-2 text-right font-bold">' + (b.status === 'galat' ? '' : rcEsc(wrUang(b.net))) + '</td><td class="p-2 text-right text-gray-500">' + (b.status === 'ditimpa' ? rcEsc(wrUang(b.netLama)) : '') + '</td>'
                        + '<td class="p-2">' + lencana(b.status) + (b.galat ? '<span class="block text-red-600 mt-0.5">' + rcEsc(b.galat) + '</span>' : '') + '</td></tr>').join('')
                    + '</tbody></table>' + (baris.length > 1000 ? '<p class="p-3 text-xs text-gray-500">Menampilkan 1.000 dari ' + baris.length.toLocaleString('id-ID') + ' baris.</p>' : '') + '</div></div>';
                rcWr.unggah.hasil = res;
                setHiddenSafely('wrPratinjauOmset', false);
            }
            function wrBatalPratinjau() { rcWr.unggah = null; setHiddenSafely('wrPratinjauOmset', true); }

            async function wrSimpanOmset() {
                const u = rcWr.unggah; if (!u || !u.hasil) return;
                const h = u.hasil;
                if (!await showConfirmModal({ title: 'Simpan Omset', message: h.baru + ' baris baru dan ' + h.ditimpa + ' baris menimpa omset yang sudah ada' + (h.galat ? '; ' + h.galat + ' baris bermasalah tidak disimpan' : '') + '. Lanjutkan?', confirmText: 'Simpan', danger: Number(h.ditimpa) > 0 })) return;
                showLoadingOverlay('Menyimpan omset...');
                try {
                    const r = await fetchApp({ action: 'rentalOmsetUnggah', rows: u.rows, simpan: true, nama: u.nama });
                    if (r.status !== 'success') throw new Error(r.message || 'Gagal menyimpan omset.');
                    showNotification('Omset tersimpan: ' + r.baru + ' baru, ' + r.ditimpa + ' ditimpa' + (r.galat ? ', ' + r.galat + ' galat tidak disimpan' : '') + '.', 'success');
                    logActivity('Upload Omset ' + u.nama + ': ' + r.baru + ' baru, ' + r.ditimpa + ' ditimpa, ' + r.galat + ' galat');
                    wrBatalPratinjau();
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
                wrMuatOmset();
            }

            async function wrMuatOmset() {
                const pilih = wrEl('wrOmsetTahun'), tahun = Number(pilih.value) || new Date().getFullYear();
                showLoadingOverlay('Memuat omset...');
                try {
                    const r = await fetchApp({ action: 'rentalOmsetData', tahun: tahun });
                    if (r.status !== 'success') throw new Error(r.message || 'Omset gagal dimuat.');
                    const ada = Array.from(new Set([new Date().getFullYear(), r.tahun].concat(r.tahunAda || []))).sort((a, b) => b - a);
                    pilih.innerHTML = ada.map(t => '<option value="' + t + '"' + (t === r.tahun ? ' selected' : '') + '>' + t + '</option>').join('');
                    wrEl('wrHeadOmset').innerHTML = '<tr><th class="p-2 text-left">Depot</th>' + RC_BULAN_SINGKAT.map(b => '<th class="p-2 text-right">' + b + '</th>').join('') + '<th class="p-2 text-center">Terisi</th></tr>';
                    wrEl('wrBodyOmset').innerHTML = (r.rows || []).map(d => {
                        const isi = (d.bulan || []).filter(v => v !== null).length;
                        return '<tr class="border-t border-gray-100 hover:bg-gray-50"><td class="p-2 whitespace-nowrap"><b>' + rcEsc(d.kode) + '</b> <span class="text-gray-500">' + rcEsc(d.nama) + '</span></td>'
                            + (d.bulan || []).map(v => '<td class="p-2 text-right whitespace-nowrap' + (v === null ? ' text-gray-300' : Number(v) < 0 ? ' text-red-600' : '') + '">' + (v === null ? '-' : rcEsc(wrUang(v))) + '</td>').join('')
                            + '<td class="p-2 text-center font-bold ' + (isi === 12 ? 'text-emerald-700' : isi ? 'text-amber-700' : 'text-gray-400') + '">' + isi + '/12</td></tr>';
                    }).join('') || '<tr><td colspan="14" class="p-6 text-center text-gray-500">Tidak ada depot.</td></tr>';
                    wrEl('wrBodyUpload').innerHTML = (r.upload || []).map(u => '<tr class="border-t border-gray-100"><td class="p-3 whitespace-nowrap">' + rcEsc(rcDisplayDate(u.pada, true)) + '</td><td class="p-3">' + rcEsc(u.nama || '-') + '</td><td class="p-3">' + rcEsc(u.oleh || '-') + '</td>'
                        + '<td class="p-3 text-right">' + u.baru + '</td><td class="p-3 text-right">' + u.ditimpa + '</td><td class="p-3 text-right ' + (u.galat ? 'text-red-600 font-bold' : '') + '">' + u.galat + '</td></tr>').join('')
                        || '<tr><td colspan="6" class="p-6 text-center text-gray-500">Belum ada upload.</td></tr>';
                    setTextSafely('wrRingkas', 'Omset net (omset - pajak) per depot per bulan, tahun ' + r.tahun + '.');
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // ---------- PDF ----------
            function wrMuatSkrip(src) {
                return new Promise((ok, gagal) => {
                    const s = document.createElement('script'); s.src = src; s.async = true;
                    s.onload = ok; s.onerror = () => gagal(new Error('Pustaka PDF gagal dimuat. Periksa koneksi internet lalu coba lagi.'));
                    document.head.appendChild(s);
                });
            }
            async function wrSiapkanPustaka() {
                if (!(window.jspdf && window.jspdf.jsPDF)) {
                    if (!rcWrPustaka) rcWrPustaka = wrMuatSkrip(WR_JSPDF).catch(e => { rcWrPustaka = null; throw e; });
                    await rcWrPustaka;
                }
                if (rcWrLogo === null) {
                    // Logo dimuat sebagai data URI; bila gagal, PDF tetap terbentuk tanpa logo.
                    try {
                        const j = await fetch('images/logo-nippon-lengkap.png', { cache: 'force-cache' });
                        if (!j.ok) throw new Error('logo');
                        const b = await j.blob();
                        rcWrLogo = await new Promise((ok, gagal) => { const fr = new FileReader(); fr.onload = () => ok(fr.result); fr.onerror = gagal; fr.readAsDataURL(b); });
                    } catch (e) { rcWrLogo = ''; }
                }
            }
            // Fon standar PDF hanya Latin-1.
            function wrTeks(v) {
                return String(v == null ? '' : v).replace(/[‘’‚′]/g, "'").replace(/[“”„″]/g, '"').replace(/[–—−]/g, '-').replace(/…/g, '...')
                    .replace(/[^\x20-\x7E\xA0-\xFF]/g, '?').replace(/\s+/g, ' ').trim();
            }

            function wrBuatPdf(row) {
                const doc = new window.jspdf.jsPDF({ unit: 'mm', format: 'a4', orientation: 'portrait' });
                doc.setProperties({ title: 'F01.AW.2025 Rental Submission' + (row.docNo ? ' ' + row.docNo : ''), subject: 'Resource Collection (RC Next Gen) - Warehouse Rental', creator: 'RC Next Gen' });
                const p = row.data || {}, c = row.calc || {}, rev = row.revenue || {}, L = 10, R = 200, W = R - L;
                const HITAM = [0, 0, 0], ABU = [107, 114, 128], LATAR = [229, 231, 235], LATAR2 = [209, 213, 219], SEL = [243, 244, 246];
                const set = (ukuran, gaya, warna) => { doc.setFont('helvetica', gaya || 'normal'); doc.setFontSize(ukuran); doc.setTextColor.apply(doc, warna || HITAM); };
                const tulis = (t, x, y, opsi) => doc.text(wrTeks(t), x, y, opsi || {});
                const pas = (t, lebar) => { let s = wrTeks(t); if (doc.getTextWidth(s) <= lebar) return s; while (s.length > 1 && doc.getTextWidth(s + '...') > lebar) s = s.slice(0, -1); return s + '...'; };
                const kotak = (x, y, w, h, isi, tebal) => { doc.setDrawColor.apply(doc, HITAM); doc.setLineWidth(tebal || 0.35); if (isi) { doc.setFillColor.apply(doc, isi); doc.rect(x, y, w, h, 'FD'); } else doc.rect(x, y, w, h, 'S'); };
                const cek = (x, y, on) => {
                    doc.setDrawColor.apply(doc, HITAM); doc.setLineWidth(0.3); doc.rect(x, y - 2.6, 2.8, 2.8, 'S');
                    if (on) { doc.setLineWidth(0.5); doc.line(x + 0.5, y - 1.3, x + 1.2, y - 0.4); doc.line(x + 1.2, y - 0.4, x + 2.4, y - 2.2); }
                };
                const pilihan = (x, y, on, label) => { cek(x, y, on); set(7, 'bold'); tulis(label, x + 4, y); };
                const isian = (x, y, w, nilai, kanan, gaya) => { kotak(x, y - 3.6, w, 4.8); set(7.5, gaya || 'normal'); const s = pas(nilai, w - 2); if (kanan) tulis(s, x + w - 1, y, { align: 'right' }); else tulis(s, x + 1, y); };
                const label = (t, x, y) => { set(6, 'normal', ABU); tulis(String(t).toUpperCase(), x, y); };
                const luas = v => (v === null || v === undefined || !Number.isFinite(Number(v))) ? '' : Number(v).toLocaleString('id-ID', { maximumFractionDigits: 2 });
                const uang = v => (v === null || v === undefined || !Number.isFinite(Number(v))) ? '' : wrUang(v);

                // ---- Kepala: logo kiri atas (tinggi 14 mm), kode form dan judul di kanannya.
                let xJudul = L;
                if (rcWrLogo) {
                    try { const pr = doc.getImageProperties(rcWrLogo), lebar = 14 * pr.width / pr.height; doc.addImage(rcWrLogo, 'PNG', L, 9, lebar, 14, 'logo-nippon', 'FAST'); xJudul = L + lebar + 4; } catch (e) { /* tanpa logo */ }
                }
                set(7.5, 'bolditalic'); tulis('Form : F01.AW.2025', xJudul, 12.5);
                set(9.5, 'bold'); tulis('RENTAL NEW / RE-NEWAL SUBMISSION FORM', xJudul, 18);
                set(7, 'bolditalic'); tulis('Entry by Depot Head/RSM', xJudul, 23); doc.setLineWidth(0.2); doc.setDrawColor.apply(doc, ABU); doc.line(xJudul, 23.8, xJudul + doc.getTextWidth('Entry by Depot Head/RSM'), 23.8);
                const xk = 164, wk = R - xk;
                [['Depot Name :', row.depot ? row.depot.kode + ' - ' + row.depot.nama : ''], ['Date Propose :', row.tanggal ? rcDisplayDate(row.tanggal) : ''], ['No. Dokumen :', row.docNo || (row.status === 'draft' ? 'DRAFT' : '')]].forEach((b, i) => {
                    const y = 13 + i * 5.2; set(7, 'bold'); tulis(b[0], xk - 1.5, y, { align: 'right' }); isian(xk, y, wk, b[1], false, 'bold');
                });

                // ---- Section 1: Submission Background
                let y = 29;
                const s1 = y; kotak(L, y, W, 5, LATAR); set(8, 'bold'); tulis('SUBMISSION BACKGROUND', L + W / 2, y + 3.6, { align: 'center' }); y += 5;
                kotak(L, y, W, 6, [249, 250, 251]);
                pilihan(L + 30, y + 4.2, p.leaseType === 'new', 'NEW LEASE / SEWA BARU'); pilihan(L + 115, y + 4.2, p.leaseType === 'renewal', 'RE-NEWAL / PERPANJANG SEWA');
                y += 6;
                const k3 = W / 3, tinggi3 = 33;
                kotak(L, y, k3, tinggi3); kotak(L + k3, y, k3, tinggi3); kotak(L + 2 * k3, y, k3, tinggi3);
                label('Rental Plane', L + 2, y + 3.5);
                [[1, 0, 0], [4, 1, 0], [2, 0, 1], [5, 1, 1], [3, 0, 2]].forEach(([n, kol, bar]) => pilihan(L + 3 + kol * 31, y + 9 + bar * 6, Number(p.rentalYears) === n, n + (n === 1 ? ' Year / 1 Tahun' : ' Years / ' + n + ' Tahun')));
                const xc = L + k3 + 2; label('Competitor', xc, y + 3.5);
                set(6.5, 'bold'); tulis('COMPETITOR NAME :', xc, y + 8);
                const merek = (p.competitors || []).map(m => m === 'OTHERS' && p.competitorOther ? 'OTHERS (' + p.competitorOther + ')' : m).join(', ');
                kotak(xc, y + 9, k3 - 4, 9); set(6.5, 'normal'); doc.splitTextToSize(wrTeks(merek), k3 - 6).slice(0, 3).forEach((t, i) => tulis(t, xc + 1, y + 11.8 + i * 2.6));
                set(6, 'bold'); tulis('SUM COMPETITOR DEPO :', xc, y + 23); isian(xc + 34, y + 23, k3 - 38, luas(p.competitorSum), true);
                set(6, 'bold'); tulis('COMPETITOR SHARE VALUE :', xc, y + 29); isian(xc + 34, y + 29, k3 - 38, luas(p.competitorShare), true);
                const xa = L + 2 * k3 + 2; label('Covered Area', xa, y + 3.5);
                [1, 2, 3, 4, 5].forEach((n, i) => {
                    [[n, 0], [n + 5, 1]].forEach(([no, kol]) => {
                        const x = xa + kol * (k3 / 2 - 1), ya = y + 9 + i * 5;
                        set(6.5, 'bold'); tulis(String(no), x + 3, ya, { align: 'right' }); isian(x + 4, ya, k3 / 2 - 7, (p.coveredArea || [])[no - 1] || '');
                    });
                });
                y += tinggi3;
                // Tabel Revenue
                label('Revenue', L + 2, y + 3.5);
                const xl = L + 40, kw = (R - 2 - xl) / 6, bh = 5.2;
                const m = String(row.tanggal || '').match(/^(\d{4})-(\d{2})/), th = m ? Number(m[1]) : null, bl = m ? Number(m[2]) : null;
                const kepala = ['PY-1', 'PY', 'PY YTD', 'Act YTD', 'Budget', 'Estimate'];
                const tahun = th ? [th - 2, th - 1, (th - 1) + ' MONTH ' + bl, th + ' MONTH ' + bl, th, th + 1] : ['', '', '', '', '', ''];
                let yy = y + 5;
                kepala.forEach((h, i) => { kotak(xl + i * kw, yy, kw, bh, SEL); set(7, 'bold'); tulis(h, xl + i * kw + kw / 2, yy + 3.6, { align: 'center' }); });
                yy += bh;
                tahun.forEach((h, i) => { kotak(xl + i * kw, yy, kw, bh); set(6.5, 'bold'); tulis(String(h), xl + i * kw + kw / 2, yy + 3.6, { align: 'center' }); });
                yy += bh;
                const revNilai = [rev.py1, rev.py, rev.pyytd, rev.actytd].map(v => v ? v.nilai : null).concat([p.revBudget, p.revEstimate]);
                const ov = [rev.py1, rev.py, rev.pyytd, rev.actytd].map(v => v && v.sumber === 'override');
                const baris = [
                    ['Revenue (IDR)  :', revNilai.map((v, i) => uang(v) + (ov[i] ? ' *' : '')), []],
                    ['Growth ( Y-on-Y)  :', ['', wrPersen(c.growthPy), '', wrPersen(c.growthActYtd), wrPersen(c.growthBudget), wrPersen(c.growthEstimate)], [0, 2]],
                    ['Size Building (Sqm)  :', [luas(c.sizePy1), luas(c.sizePy), '', '', luas(c.sizeBudget), luas(c.sizeEstimate)], [2, 3]],
                    ['Revenue/Sqm (building):', [uang(c.revSqmPy1), uang(c.revSqmPy), '', '', uang(c.revSqmBudget), uang(c.revSqmEstimate)], [2, 3]]];
                baris.forEach(([lbl, isi, abu], bi) => {
                    set(7, 'bold'); tulis(lbl, xl - 1.5, yy + 3.6, { align: 'right' });
                    isi.forEach((v, i) => { kotak(xl + i * kw, yy, kw, bh, abu.includes(i) ? SEL : null); set(7, bi === 0 ? 'bold' : 'normal'); tulis(pas(v, kw - 2), xl + i * kw + (bi === 1 ? kw / 2 : kw - 1), yy + 3.6, { align: bi === 1 ? 'center' : 'right' }); });
                    yy += bh;
                });
                // Catatan override dan bulan omset yang belum ada.
                const catatan = [];
                [['py1', 'PY-1'], ['py', 'PY'], ['pyytd', 'PY YTD'], ['actytd', 'Act YTD']].forEach(([k, n]) => { if (rev[k] && rev[k].sumber === 'override') catatan.push('* ' + n + ' override: ' + (rev[k].alasan || '-') + (rev[k].oleh ? ' (' + rev[k].oleh + ')' : '')); });
                const hilang = row.omset && row.omset.hilang || [];
                if (hilang.length) catatan.push('Omset belum ter-upload: ' + wrRingkasBulan(hilang).join(', ') + '.');
                set(6, 'italic', ABU);
                const barisCatatan = doc.splitTextToSize(wrTeks(catatan.join('  ·  ')), W - 4).slice(0, 2);
                barisCatatan.forEach((t, i) => tulis(t, L + 2, yy + 3 + i * 2.6));
                y = yy + 1.5 + Math.max(1, barisCatatan.length) * 2.6;
                doc.setLineWidth(0.6); doc.setDrawColor.apply(doc, HITAM); doc.rect(L, s1, W, y - s1, 'S');

                // ---- Section 2: Properties Informations
                y += 3; const s2 = y;
                kotak(L, y, W, 5, LATAR); set(8, 'bold'); tulis('PROPERTIES INFORMATIONS', L + W / 2, y + 3.6, { align: 'center' });
                set(8, 'bold', [220, 38, 38]); tulis(c.labelSewa || '-', R - 2, y + 3.6, { align: 'right' }); y += 5;
                const kiri = W * 0.45, tA = 34;
                kotak(L, y, kiri, tA); kotak(L + kiri, y, W - kiri, tA);
                label('Property Information', L + 2, y + 3.5);
                const xv = L + 42;
                [['LAND SIZE :', luas(p.landSize), 'm²'], ['WAREHOUSE SIZE :', luas(p.warehouseSize), 'm²'], ['OFFICE SIZE :', luas(p.officeSize), 'm²'], ['OFFERING PRICE :', uang(p.offeringPrice), '/tahun']].forEach((b, i) => {
                    const yb = y + 8.5 + i * 5; set(6.8, 'bold'); tulis(b[0], xv - 1.5, yb, { align: 'right' }); isian(xv, yb, 30, b[1], true); set(6.5, 'normal', ABU); tulis(b[2], xv + 31, yb);
                });
                [['TOTAL PRICE FOR ' + (c.totalYears ? luas(c.totalYears) + ' YEAR' : (p.rentalYears ? p.rentalYears + ' YEAR' : '... YEAR')) + ' :', uang(c.totalPrice)], ['PRICE PER M² /MONTH :', uang(c.pricePerM2Month)]].forEach((b, i) => {
                    const yb = y + 28.5 + i * 4.6; set(6.8, 'bold'); tulis(b[0], xv - 1.5, yb, { align: 'right' }); set(8, 'bold'); tulis(b[1] || '-', xv + 30, yb, { align: 'right' });
                    doc.setLineWidth(0.4); doc.setDrawColor.apply(doc, HITAM); doc.line(xv, yb + 0.9, xv + 30, yb + 0.9);
                });
                const xf = L + kiri + 4; label('Facilities', xf, y + 3.5);
                kotak(xf, y + 5.5, 64, 18);
                WR_FASILITAS.forEach(([k, n], i) => pilihan(xf + 3 + (i % 2) * 31, y + 10.5 + Math.floor(i / 2) * 5.5, (p.facilities || []).includes(k), n));
                y += tA;
                const tB = 28;
                kotak(L, y, kiri, tB); kotak(L + kiri, y, W - kiri, tB);
                label('Terms & Conditions', L + 2, y + 3.5);
                const xt = L + 32;
                [['Income Tax (PPH) :', 'pph', [['owner', 'By Owner'], ['nipsea', 'By Nipsea']]], ['Land Tax (PBB) :', 'pbb', [['owner', 'By Owner'], ['nipsea', 'By Nipsea']]],
                 ['Notaries Fee :', 'notaris', [['owner', 'By Owner'], ['nipsea', 'By Nipsea'], ['5050', '50 : 50']]]].forEach(([lbl, k, opsi], i) => {
                    const yb = y + 8.5 + i * 5; set(6.8, 'bold'); tulis(lbl, xt - 1.5, yb, { align: 'right' });
                    opsi.forEach(([v, n], j) => pilihan(xt + j * 18, yb, p[k] === v, n));
                });
                set(6.8, 'bold'); tulis('Mtn/Surcharge (IPL) :', xt - 1.5, y + 24.5, { align: 'right' }); isian(xt, y + 24.5, 34, uang(p.ipl), true);
                const xo = L + kiri + 2; label('Owner Informations', xo, y + 3.5);
                const xov = xo + 27;
                [['Owners / Agent :', p.ownerName], ['Phone Number :', p.ownerPhone]].forEach((b, i) => { const yb = y + 8.5 + i * 5; set(6.8, 'bold'); tulis(b[0], xov - 1.5, yb, { align: 'right' }); isian(xov, yb, R - 2 - xov, b[1] || ''); });
                set(6.8, 'bold'); tulis('Properties Address :', xov - 1.5, y + 18.5, { align: 'right' });
                kotak(xov, y + 15.4, R - 2 - xov, 11); set(7, 'normal');
                doc.splitTextToSize(wrTeks(p.ownerAddress || ''), R - 4 - xov).slice(0, 4).forEach((t, i) => tulis(t, xov + 1, y + 18.4 + i * 2.6));
                y += tB;
                doc.setLineWidth(0.6); doc.setDrawColor.apply(doc, HITAM); doc.rect(L, s2, W, y - s2, 'S');

                // ---- Section 3: tanda tangan
                y += 4;
                ['Prepared By Depot Head', 'Reviewed By RSM', 'Acknowledge By NSM'].forEach((n, i) => {
                    const xm = L + W / 6 + i * W / 3; set(7, 'normal', ABU); tulis(n, xm, y + 2, { align: 'center' });
                    doc.setLineWidth(0.3); doc.setDrawColor.apply(doc, HITAM); doc.line(xm - 22, y + 17, xm + 22, y + 17); set(7, 'bold'); tulis('Name & Sign', xm, y + 20, { align: 'center' });
                });
                y += 24;

                // ---- Section 4: Legal Review (kosong untuk v1)
                set(7, 'bolditalic'); tulis('Entry by Legal Dept', L, y + 2); y += 3.5;
                const s4 = y, kananLegal = 32;
                kotak(L, y, W, 5, LATAR2); set(8, 'bold'); tulis('LEGAL REVIEW', L + W / 2, y + 3.6, { align: 'center' }); y += 5;
                kotak(L, y, W - kananLegal, 12, [249, 250, 251]);
                ['Building Permit (PBG/IMB)', 'Owner / Director ID', 'NIB', 'Land Certificate', 'Article of Association', 'Contract (after draft received)'].forEach((n, i) => pilihan(L + 3 + (i % 3) * 52, y + 4.6 + Math.floor(i / 3) * 5.5, false, n));
                kotak(L, y + 12, W - kananLegal, 14); set(7, 'bold'); tulis('Comment By Legal :', L + 2, y + 15.5);
                kotak(R - kananLegal, y, kananLegal, 26); set(6.5, 'normal', ABU); tulis('Reviewed By Legal', R - kananLegal / 2, y + 4, { align: 'center' });
                doc.setLineWidth(0.3); doc.setDrawColor.apply(doc, HITAM); doc.line(R - kananLegal + 3, y + 21, R - 3, y + 21); set(6.5, 'bold'); tulis('Name & Sign', R - kananLegal / 2, y + 24, { align: 'center' });
                y += 26; doc.setLineWidth(0.6); doc.rect(L, s4, W, y - s4, 'S');

                // ---- Section 5: Top Management (kosong untuk v1)
                y += 3; const s5 = y;
                kotak(L, y, W, 5, LATAR2); set(8, 'bold'); tulis('TOP MANAGEMENT', L + W / 2, y + 3.6, { align: 'center' }); y += 5;
                const tinggi5 = Math.min(26, 284 - y);
                [['General Manager', 0], ['President Director', 1]].forEach(([n, i]) => {
                    const x = L + i * W / 3; kotak(x, y, W / 3, tinggi5); set(7, 'normal', ABU); tulis(n, x + W / 6, y + 4, { align: 'center' });
                    doc.setLineWidth(0.3); doc.line(x + W / 6 - 20, y + tinggi5 - 5, x + W / 6 + 20, y + tinggi5 - 5); set(7, 'bold'); tulis('Name & Sign', x + W / 6, y + tinggi5 - 2, { align: 'center' });
                });
                kotak(L + 2 * W / 3, y, W / 3, tinggi5); set(7, 'bold'); tulis('Comment :', L + 2 * W / 3 + 2, y + 4);
                y += tinggi5; doc.setLineWidth(0.6); doc.rect(L, s5, W, y - s5, 'S');

                // ---- Kaki: nomor dokumen, pembuat, waktu generate, halaman.
                const kini = new Date(Date.now() + 7 * 3600000);
                const waktu = rcDisplayDate(kini.toISOString().slice(0, 10)) + ' ' + String(kini.getUTCHours()).padStart(2, '0') + ':' + String(kini.getUTCMinutes()).padStart(2, '0') + ' WIB';
                doc.setLineWidth(0.2); doc.setDrawColor.apply(doc, ABU); doc.line(L, 288, R, 288);
                set(6.5, 'normal', ABU);
                tulis('No. Dokumen: ' + (row.docNo || 'DRAFT') + '   ·   Dibuat oleh: ' + ((row.dibuat && row.dibuat.oleh) || '-') + '   ·   Generate: ' + waktu + '   ·   Resource Collection (RC Next Gen)', L, 291.5);
                tulis('Halaman 1/1', R, 291.5, { align: 'right' });

                // Watermark DRAFT untuk form yang belum di-submit.
                if (row.status !== 'submitted') {
                    const teks = row.status === 'cancelled' ? 'CANCELLED' : 'DRAFT';
                    try { doc.setGState(new doc.GState({ opacity: 0.13 })); } catch (e) { /* tanpa transparansi */ }
                    doc.setFont('helvetica', 'bold'); doc.setFontSize(teks === 'DRAFT' ? 120 : 84); doc.setTextColor(220, 38, 38);
                    doc.text(teks, 105, 165, { align: 'center', angle: 45 });
                    try { doc.setGState(new doc.GState({ opacity: 1 })); } catch (e) { /* tanpa transparansi */ }
                }
                return doc;
            }
