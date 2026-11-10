            // ============================================================================
            // DOCUMENT GENERATOR - TANDA TERIMA (20261163190000, 20261163520000, 20261163540000, 20261163550000)
            // ============================================================================
            // PRD "Auto Generate Form Verifikasi Customer" (pemilik, 18 Oktober 2026). Daftar toko
            // lunas (tawaran aktif Upload Debtor) per toko per depot; admin depot memilih toko lalu
            // mengunduh PDF siap cetak: A4 potret, 2 form per lembar dengan garis potong. Isi form
            // dibaca server saat unduh (rc_docgen_generate) - termasuk nomor form FV-ABBR-DDMMYY-NNN -
            // dan PDF digambar di sini dengan jsPDF (dimuat hanya saat dibutuhkan). Toko dengan lebih
            // dari 4 campaign berlanjut ke form berikutnya (Hal 1/2, 2/2) dengan nomor yang sama.
            // Pemilik, 18 Oktober 2026 (sesudah uji kedua): form memuat Bank, No. Rekening, dan A.N.
            // Rekening dari Customer Master (tidak wajib - kosong dibiarkan untuk ditulis tangan), dan
            // tab kedua "Semua Not Yet" mengunduh form yang sama untuk seluruh klaim Not Yet.
            // Pemilik, 27 Oktober 2026 (20261163520000): namanya kini Tanda Terima (nomor TT-...), logo
            // PNG tanpa latar, dan tanda tangan hanya toko di ujung kanan dengan nama sales (Customer
            // Master) di sampingnya.
            // Pemilik, 29 Oktober 2026 (20261163540000): tidak lagi melihat lunas, melainkan seluruh toko.
            // Dua tab: Done (klaim yang sudah Clearing, saringan Tgl Done opsional) dan Not Yet (seluruh
            // klaim Not Yet). Unduh terakhir dan penanda "Data berubah" dihitung per tab.

            // Pemilik, 5 November 2026 (20261163740000): Bank, No. Rekening, dan A.N. Rekening dihapus dari
            // form dan daftar - rekening tujuan yang sebenarnya ada di Bukti Transfer (file bank). Remark
            // memuat PP bila toko punya Bukti TF yang ikut tercetak, dan ada saringan Remark.

            // Pemilik, 29 Oktober 2026 (20261163550000): daftar diambil per halaman dari server dan
            // seluruh saringan dijalankan server (daftar lengkap melewati batas waktu server); saringan
            // No Batch Clearing di tab Done membatasi klaim yang masuk form, sama seperti Tgl Done.

            let rcDgState = { sumber: 'done', rows: [], total: 0, kpi: {}, pilih: new Set(), halaman: 0 };
            let rcDgMuatKe = 0, rcDgCariJeda = null;
            const DG_PER_HALAMAN = 100;
            const DG_BARIS_PER_FORM = 4;
            const DG_JSPDF = 'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js';
            let rcDgPustaka = null, rcDgLogo = null;

            function dgKunci(r) { return r.depotId + '|' + r.customerId; }

            function switchDocGenTab(tab) {
                if (!rcEnterTab('docgen', tab)) return;
                const sumber = 'done'; // 20261163690000: tab Not Yet ditiadakan
                // Pilihan tidak dibawa pindah tab: isi dan nomor formnya berbeda sumber.
                if (rcDgState.sumber !== sumber) { rcDgState.sumber = sumber; rcDgState.rows = []; rcDgState.total = 0; rcDgState.kpi = {}; rcDgState.pilih = new Set(); rcDgState.halaman = 0; }
                [['done', 'docTabDone']].forEach(([t, id]) => {
                    const el = document.getElementById(id);
                    if (el) el.className = 'px-5 py-2 text-sm font-bold rounded-lg ' + (t === sumber ? 'bg-violet-100 text-violet-700' : 'text-gray-500 hover:bg-gray-100');
                });
                ['dgSaringDone', 'dgKolTgl'].forEach(id => { const el = document.getElementById(id); if (el) el.classList.toggle('hidden', sumber !== 'done'); });
                setTextSafely('dgCatatan', 'Satu form per toko per depot, berisi ' + (sumber === 'notyet'
                        ? 'seluruh klaim Not Yet yang belum diajukan'
                        : 'klaim Done (sudah Clearing); saringan Tgl Done dan No Batch Clearing membatasi klaim yang masuk form, dan klaim Done tanpa Tgl Done hanya ikut bila saringan Tgl Done kosong')
                    + ', satu baris per campaign per Jenis CB; lebih dari 4 baris berlanjut ke halaman berikutnya dengan nomor form yang sama. '
                    + 'Toko yang Customer Master-nya belum lengkap (Nama Pemilik, KTP / NPWP) tidak dapat dicetak sampai master dilengkapi. '
                    + 'Rekening tidak dicetak di form; rekening tujuan ada di halaman Bukti Transfer (dari file bank) sesudah form PDA - Remark PP. KTP dan NPWP tidak dicetak.');
                dgMuat();
            }

            const dgNilai = id => String((document.getElementById(id) || {}).value || '').trim();
            // Saringan klaim (menentukan isi form): Tgl Done (yyyy-mm-dd dari input tanggal) dan No Batch
            // Clearing, hanya di tab Done.
            function dgSaringKlaim() {
                if (rcDgState.sumber !== 'done') return {};
                const s = { dari: dgNilai('dgDari'), sampai: dgNilai('dgSampai'), batch: dgNilai('dgBatch') };
                Object.keys(s).forEach(k => { if (!s[k]) delete s[k]; });
                return s;
            }
            // Saringan klaim + saringan toko (hanya menyaring daftar).
            function dgSaringSemua() {
                const s = Object.assign({ depot: dgNilai('dgDepot'), campaign: dgNilai('dgCampaign'), unduh: dgNilai('dgUnduh'), master: dgNilai('dgMaster'), remark: dgNilai('dgRemark'), cari: dgNilai('dgCari') }, dgSaringKlaim());
                Object.keys(s).forEach(k => { if (!s[k]) delete s[k]; });
                return s;
            }

            async function dgMuat(pertahankanHalaman) {
                const ke = ++rcDgMuatKe, sumber = rcDgState.sumber, saring = dgSaringSemua();
                if (saring.dari && saring.sampai && saring.dari > saring.sampai) { showNotification('Tgl Done "dari" melewati "sampai".', 'warning'); return; }
                if (pertahankanHalaman !== true) rcDgState.halaman = 0;
                showLoadingOverlay('Memuat Document Generator...');
                try {
                    const r = await fetchApp({ action: 'docgenList', sumber: sumber, saring: saring, hal: rcDgState.halaman, per: DG_PER_HALAMAN });
                    if (ke !== rcDgMuatKe) return;
                    if (r.status !== 'success') throw new Error(r.message || 'Document Generator gagal dimuat');
                    rcDgState.rows = r.rows || []; rcDgState.total = Number(r.total) || 0; rcDgState.kpi = r.kpi || {}; rcDgState.saringan = r.saringan || '';
                    // Halaman yang diminta sudah tidak ada (hasil menyusut): kembali ke halaman terakhir.
                    const akhir = Math.max(0, Math.ceil(rcDgState.total / DG_PER_HALAMAN) - 1);
                    if (rcDgState.halaman > akhir) { rcDgState.halaman = akhir; return dgMuat(true); }
                    dgIsiFilter(r.opsi || {});
                    dgRender();
                } catch (e) {
                    if (ke !== rcDgMuatKe) return;
                    document.getElementById('dgBody').innerHTML = '<tr><td colspan="13" class="p-6 text-red-600">' + rcEsc(e.message) + '</td></tr>';
                    showNotification(e.message, 'error');
                } finally { hideLoadingOverlay(); }
            }

            function dgIsiFilter(opsi) {
                const pasang = (id, daftar, semua) => {
                    const el = document.getElementById(id); if (!el) return;
                    const lama = el.value;
                    el.innerHTML = '<option value="">' + semua + '</option>' + daftar.map(o => '<option value="' + rcEsc(o.kode) + '">' + rcEsc(o.kode + ' - ' + o.nama) + '</option>').join('');
                    if (lama && !daftar.some(o => o.kode === lama)) el.insertAdjacentHTML('beforeend', '<option value="' + rcEsc(lama) + '">' + rcEsc(lama) + '</option>');
                    el.value = lama;
                };
                pasang('dgDepot', opsi.depot || [], 'Semua Depot');
                pasang('dgCampaign', opsi.campaign || [], 'Semua Campaign');
                const dl = document.getElementById('dgBatchList');
                if (dl && opsi.batch) dl.innerHTML = opsi.batch.map(b => '<option value="' + rcEsc(b) + '"></option>').join('');
            }

            // Saringan toko berubah: muat ulang dari halaman pertama; pilihan tetap.
            function dgSaring() { dgMuat(); }
            function dgCariTunda() { clearTimeout(rcDgCariJeda); rcDgCariJeda = setTimeout(dgMuat, 400); }
            // Saringan klaim berubah: isi form ikut berubah, jadi pilihan dikosongkan.
            function dgSaringKlaimBerubah() { rcDgState.pilih = new Set(); dgMuat(); }

            function dgRender() {
                const rows = rcDgState.rows, kpi = rcDgState.kpi || {}, notYet = rcDgState.sumber === 'notyet', klaim = dgSaringKlaim();
                const kartu = (judul, nilai, kelas, ket) => '<div class="bg-white border border-gray-200 rounded-xl p-4 shadow-sm"><p class="text-[11px] font-bold text-gray-500 uppercase">' + judul + '</p><p class="text-2xl font-black ' + kelas + ' mt-1">' + Number(nilai || 0).toLocaleString('id-ID') + '</p><p class="text-[11px] text-gray-400 mt-0.5">' + ket + '</p></div>';
                document.getElementById('dgKpi').innerHTML = (notYet
                        ? kartu('Toko Not Yet', kpi.toko, 'text-gray-800', 'seluruh klaim Not Yet')
                        : kartu('Toko Done', kpi.toko, 'text-gray-800', rcDgState.saringan ? rcEsc(rcDgState.saringan) : 'seluruh klaim yang sudah Clearing'))
                    + kartu('Siap cetak', kpi.siap, 'text-emerald-600', 'Customer Master lengkap')
                    + kartu('Master belum lengkap', kpi.kurang, 'text-red-600', 'tidak dapat dicetak')
                    + kartu('Belum diunduh', kpi.belumUnduh, 'text-violet-700', 'dari toko yang siap cetak');

                const body = document.getElementById('dgBody');
                if (!rows.length) {
                    body.innerHTML = '<tr><td colspan="13" class="p-8 text-center text-gray-500">' + (kpi.toko ? 'Tidak ada toko yang cocok dengan filter.' : notYet ? 'Tidak ada klaim Not Yet dalam jangkauan Anda.' : 'Tidak ada klaim Done dalam jangkauan Anda' + (Object.keys(klaim).length ? ' pada saringan itu.' : '.')) + '</td></tr>';
                } else {
                    body.innerHTML = rows.map(r => {
                        const k = dgKunci(r), kJs = rcEsc(JSON.stringify(k));
                        const camp = (r.campaigns || []).map(c => c.kode + ' - ' + c.nama + ' (' + c.jenisCb + ')').join('\n');
                        const unduh = r.unduh
                            ? '<span class="font-mono font-bold text-gray-700">' + rcEsc(r.unduh.noForm) + '</span><span class="block text-[11px] text-gray-500">' + rcEsc(r.unduh.pada) + ' · ' + rcEsc(r.unduh.oleh) + (r.jumlahUnduh > 1 ? ' · ' + r.jumlahUnduh + 'x' : '') + '</span>'
                              + (r.berubah ? '<span class="inline-block mt-1 px-1.5 py-0.5 rounded bg-amber-100 text-amber-800 text-[10px] font-bold" title="Klaim atau nilainya berubah sejak unduh terakhir (mis. Amend Doc). Unduh ulang supaya form sesuai.">Data berubah</span>' : '')
                            : '<span class="text-gray-400">Belum</span>';
                        // 20261163700000: PDA / PDH / PDA + PDH (toko campuran mendapat dua form); PP = ada Bukti TF (20261163740000).
                        const REMARK = { PDA: ['bg-emerald-100 text-emerald-800', 'Posting date available'], PDH: ['bg-gray-200 text-gray-700', 'Posting date hidden'],
                                         PP: ['bg-sky-100 text-sky-800', 'Payment proof: Bukti Transfer ' + Number(r.buktiTf || 0) + ' dokumen ikut tercetak sesudah form PDA'] };
                        const remark = (r.remark || '').split(' + ').filter(Boolean).map(x => '<span class="inline-block px-1.5 py-0.5 mr-1 rounded text-[10px] font-black '
                            + (REMARK[x] || REMARK.PDH)[0] + '" title="' + rcEsc((REMARK[x] || [, x])[1]) + '">' + rcEsc(x) + '</span>').join('')
                            || '<span class="text-gray-400">-</span>';
                        const status = r.siap
                            ? '<span class="px-2 py-0.5 rounded-md bg-emerald-50 text-emerald-700 font-bold border border-emerald-100 whitespace-nowrap">Siap cetak</span>'
                            : '<span class="px-2 py-0.5 rounded-md bg-red-50 text-red-700 font-bold border border-red-100 whitespace-nowrap">Master belum lengkap</span><span class="block text-[11px] text-red-600 mt-1">' + rcEsc(r.masalahMaster) + '</span>';
                        return '<tr class="border-t border-gray-100 hover:bg-gray-50' + (r.siap ? '' : ' bg-red-50/30') + '">'
                            + '<td class="p-3"><input type="checkbox" class="dg-pilih rounded" value="' + rcEsc(k) + '" ' + (rcDgState.pilih.has(k) ? 'checked ' : '') + (r.siap ? '' : 'disabled title="Lengkapi Customer Master lebih dulu" ') + 'onchange="dgPilih(this)"></td>'
                            + '<td class="p-3 whitespace-nowrap"><b>' + rcEsc(r.depotKode) + '</b><span class="block text-[11px] text-gray-500">' + rcEsc(r.depotNama) + '</span></td>'
                            + '<td class="p-3"><b class="font-mono">' + rcEsc(r.kode) + '</b> - ' + rcEsc(r.nama) + '</td>'
                            + '<td class="p-3">' + (r.pemilik ? rcEsc(r.pemilik) : '<span class="text-red-500 italic">kosong</span>') + '</td>'
                            + '<td class="p-3 whitespace-nowrap">' + (rcEsc(r.subyekPajak) || '<span class="text-gray-400">-</span>') + '</td>'
                            + '<td class="p-3 whitespace-nowrap" title="' + rcEsc(camp) + '"><b>' + r.jumlahCampaign + '</b> campaign' + (r.halaman > 1 ? ' <span class="text-[11px] text-violet-700 font-bold">(' + r.halaman + ' hal.)</span>' : '') + '<span class="block text-[11px] text-gray-500">' + r.jumlahKlaim + ' dokumen</span></td>'
                            + '<td class="p-3 whitespace-nowrap">' + (r.jenisCb || []).map(rcEsc).join(', ') + '</td>'
                            + '<td class="p-3 text-right whitespace-nowrap font-bold">' + rcEsc(rcNominalPenuh(r.totalNetCb)) + '</td>'
                            + '<td class="p-3 whitespace-nowrap' + (notYet ? ' hidden' : '') + '">' + (r.tglDone ? rcEsc(r.tglDone) : '<span class="text-gray-400">-</span>') + '</td>'
                            + '<td class="p-3 whitespace-nowrap">' + unduh + '</td>'
                            + '<td class="p-3">' + status + '</td>'
                            + '<td class="p-3 text-center">' + (r.siap ? '<button onclick="dgUnduh([' + kJs + '])" class="px-2.5 py-1.5 rounded-lg border border-violet-200 text-violet-700 bg-violet-50 hover:bg-violet-100" title="Unduh form toko ini"><i class="fas fa-file-pdf"></i></button>' : '') + '</td>'
                            + '<td class="p-3 whitespace-nowrap">' + remark + '</td>'
                            + '</tr>';
                    }).join('');
                }
                const total = rcDgState.total, hal = Math.max(1, Math.ceil(total / DG_PER_HALAMAN)), awal = rcDgState.halaman * DG_PER_HALAMAN;
                document.getElementById('dgPager').innerHTML = '<span>' + (total ? (awal + 1).toLocaleString('id-ID') + '-' + Math.min(awal + DG_PER_HALAMAN, total).toLocaleString('id-ID') + ' dari ' : '') + total.toLocaleString('id-ID') + ' toko</span>'
                    + (hal > 1 ? '<span class="flex items-center gap-2"><button onclick="dgHalaman(-1)" class="px-3 py-1 border rounded-lg font-bold disabled:opacity-40" ' + (rcDgState.halaman === 0 ? 'disabled' : '') + '>Sebelumnya</button>Hal. ' + (rcDgState.halaman + 1) + ' / ' + hal
                        + '<button onclick="dgHalaman(1)" class="px-3 py-1 border rounded-lg font-bold disabled:opacity-40" ' + (rcDgState.halaman >= hal - 1 ? 'disabled' : '') + '>Berikutnya</button></span>' : '');
                setTextSafely('dgRingkas', (notYet ? 'Tanda terima untuk seluruh toko dengan klaim Not Yet' : 'Tanda terima untuk toko dengan klaim Done') + ' · ' + Number(kpi.toko || 0).toLocaleString('id-ID') + ' toko dalam jangkauan Anda.');
                dgPerbaruiPilihan();
            }

            function dgHalaman(arah) { rcDgState.halaman = Math.max(0, rcDgState.halaman + arah); dgMuat(true); }
            function dgPilih(cb) { if (cb.checked) rcDgState.pilih.add(cb.value); else rcDgState.pilih.delete(cb.value); dgPerbaruiPilihan(); }
            function dgPilihHalaman(on) {
                document.querySelectorAll('#dgBody .dg-pilih:not(:disabled)').forEach(cb => { cb.checked = on; if (on) rcDgState.pilih.add(cb.value); else rcDgState.pilih.delete(cb.value); });
                dgPerbaruiPilihan();
            }
            // Pilihan lintas halaman: seluruh hasil filter yang siap cetak, dari server (maks. 5.000).
            async function dgPilihSemuaHasil(on) {
                if (!on) { rcDgState.pilih.clear(); dgRender(); return; }
                showLoadingOverlay('Memilih toko...');
                try {
                    const r = await fetchApp({ action: 'docgenList', sumber: rcDgState.sumber, saring: dgSaringSemua(), kunciSaja: true });
                    if (r.status !== 'success') throw new Error(r.message || 'Pilihan gagal dimuat');
                    (r.kunci || []).forEach(x => rcDgState.pilih.add(x.depotId + '|' + x.customerId));
                    if (r.lebih) showNotification('Hanya 5.000 toko pertama yang dipilih. Persempit filter bila perlu.', 'warning');
                } catch (e) { showNotification(e.message, 'error'); } finally { hideLoadingOverlay(); }
                dgRender();
            }
            function dgPerbaruiPilihan() {
                const n = rcDgState.pilih.size;
                setTextSafely('dgPilihInfo', n.toLocaleString('id-ID') + ' toko dipilih');
                const b = document.getElementById('dgBtnUnduh');
                if (b) { b.disabled = n === 0; b.innerHTML = '<i class="fas fa-file-pdf mr-1.5"></i>Unduh PDF' + (n ? ' (' + n.toLocaleString('id-ID') + ' toko)' : ''); }
                const cbs = Array.from(document.querySelectorAll('#dgBody .dg-pilih:not(:disabled)')), semua = document.getElementById('dgPilihHalaman');
                if (semua) semua.checked = cbs.length > 0 && cbs.every(c => c.checked);
            }
            function dgUnduhTerpilih() { if (rcDgState.pilih.size) dgUnduh(Array.from(rcDgState.pilih)); }

            async function dgUnduh(kunci) {
                if (kunci.length > 500) { showNotification('Maksimal 500 toko sekali unduh. Persempit filter atau pilihan.', 'warning'); return; }
                const toko = kunci.map(k => { const p = String(k).split('|'); return { depotId: p[0], customerId: p[1] }; }), sumber = rcDgState.sumber;
                showLoadingOverlay('Menyiapkan tanda terima...');
                let res = null;
                try {
                    res = await fetchApp({ action: 'docgenGenerate', toko: toko, sumber: sumber, saring: dgSaringKlaim() });
                    if (res.status !== 'success') throw new Error(res.message || 'Form gagal dibuat.');
                    if ((res.forms || []).length) {
                        await dgSiapkanPustaka();
                        // 20261163700000: form PDA (bertanggal proses) dan PDH (tanpa tanggal) ke dua berkas PDF.
                        const golongan = ['PDA', 'PDH'].map(g => res.forms.filter(f => (f.kategori || 'PDA') === g)).filter(x => x.length);
                        for (let i = 0; i < golongan.length; i++) {
                            if (i > 0) await new Promise(ok => setTimeout(ok, 800)); // jeda supaya peramban menerima unduhan kedua
                            dgBuatPdf(golongan[i]).save(dgNamaBerkas(golongan[i]));
                        }
                        kunci.forEach(k => rcDgState.pilih.delete(k));
                    }
                } catch (e) { hideLoadingOverlay(); showNotification(e.message, 'error'); return; }
                hideLoadingOverlay();
                const gagal = res.gagal || [];
                if (gagal.length) {
                    rcDialog('Sebagian toko tidak dapat dibuatkan form', '<div class="space-y-3 text-sm"><p>' + rcEsc(res.message) + ' Toko berikut tidak masuk PDF:</p>'
                        + '<table class="w-full text-xs"><thead class="bg-gray-50"><tr><th class="p-2 text-left">Depot</th><th class="p-2 text-left">Toko</th><th class="p-2 text-left">Alasan</th></tr></thead><tbody>'
                        + gagal.map(g => '<tr class="border-t"><td class="p-2">' + rcEsc(g.depotKode) + '</td><td class="p-2"><b>' + rcEsc(g.kode) + '</b> - ' + rcEsc(g.nama) + '</td><td class="p-2 text-red-600">' + rcEsc(g.alasan) + '</td></tr>').join('')
                        + '</tbody></table></div>');
                } else showNotification(res.message, 'success');
                dgMuat(true);
            }

            function dgNamaBerkas(forms) {
                const g = forms[0].kategori ? '-' + forms[0].kategori : ''; // 20261163700000
                if (forms.length === 1) return forms[0].noForm + g + '.pdf';
                return 'Tanda-Terima-' + (forms[0].sumber === 'notyet' ? 'Not-Yet' : 'Done') + g + '_' + forms[0].dicetak + '_' + forms.length + '-form.pdf';
            }

            // ---------- PDF ----------
            function dgMuatSkrip(src) {
                return new Promise((ok, gagal) => {
                    const s = document.createElement('script'); s.src = src; s.async = true;
                    s.onload = ok; s.onerror = () => gagal(new Error('Pustaka PDF gagal dimuat. Periksa koneksi internet lalu coba lagi.'));
                    document.head.appendChild(s);
                });
            }
            async function dgSiapkanPustaka() {
                if (!(window.jspdf && window.jspdf.jsPDF)) {
                    if (!rcDgPustaka) rcDgPustaka = dgMuatSkrip(DG_JSPDF).catch(e => { rcDgPustaka = null; throw e; });
                    await rcDgPustaka;
                }
                if (rcDgLogo === null) {
                    // Logo boleh hilang: form tetap terbentuk dengan merek tertulis saja.
                    try {
                        const jawab = await fetch('images/logo-nippon-lengkap.png', { cache: 'force-cache' });
                        if (!jawab.ok) throw new Error('logo');
                        const b = await jawab.blob();
                        rcDgLogo = await new Promise((ok, gagal) => { const fr = new FileReader(); fr.onload = () => ok(fr.result); fr.onerror = gagal; fr.readAsDataURL(b); });
                    } catch (e) { rcDgLogo = ''; }
                }
            }

            // Fon standar PDF hanya memuat Latin-1: tanda kutip tipografis dan sejenisnya diganti.
            function dgTeks(v) {
                return String(v == null ? '' : v).replace(/[‘’‚′]/g, "'").replace(/[“”„″]/g, '"')
                    .replace(/[–—−]/g, '-').replace(/…/g, '...').replace(/[   ]/g, ' ')
                    .replace(/[^\x20-\x7E\xA0-\xFF]/g, '?').replace(/\s+/g, ' ').trim();
            }
            function dgRupiah(n) { return Math.trunc(Number(n) || 0).toLocaleString('id-ID'); }
            function dgPajak(mentah) {
                const k = rcKunciPajak(mentah);
                return k === 'perusahaan' ? 'PT Nipsea' : k === 'customer' ? 'Customer' : k === 'nonTax' ? 'Non Tax' : '-';
            }
            // Memotong teks agar muat lebar tertentu (mm) pada fon yang sedang aktif.
            function dgPas(doc, teks, lebar) {
                let t = dgTeks(teks);
                if (doc.getTextWidth(t) <= lebar) return t;
                while (t.length > 1 && doc.getTextWidth(t + '...') > lebar) t = t.slice(0, -1);
                return t.trimEnd() + '...';
            }

            const DG_BIRU = [0, 46, 138], DG_MERAH = [206, 17, 38], DG_GARIS = [200, 206, 218], DG_LATAR = [238, 241, 247], DG_TEKS = [33, 37, 41], DG_REDUP = [108, 117, 130];

            // Satu PDF: setiap form dipecah per 4 campaign, lalu potongan-potongan itu diletakkan
            // berurutan, dua per lembar A4.
            function dgBuatPdf(forms) {
                const doc = new window.jspdf.jsPDF({ unit: 'mm', format: 'a4', orientation: 'portrait' });
                doc.setProperties({ title: 'Tanda Terima', subject: 'Resource Collection (RC Next Gen) - Document Generator', creator: 'RC Next Gen' });
                const bagian = [];
                forms.forEach(f => {
                    const baris = f.campaigns || [], n = Math.max(1, Math.ceil(baris.length / DG_BARIS_PER_FORM));
                    for (let i = 0; i < n; i++) {
                        const isi = baris.slice(i * DG_BARIS_PER_FORM, (i + 1) * DG_BARIS_PER_FORM);
                        bagian.push({ form: f, isi: isi, ke: i + 1, dari: n, mulai: i * DG_BARIS_PER_FORM,
                            subtotal: isi.reduce((a, c) => a + Math.trunc(Number(c.netCb) || 0), 0) });
                    }
                });
                bagian.forEach((b, i) => {
                    if (i > 0 && i % 2 === 0) doc.addPage();
                    const atas = i % 2 === 0 ? 4 : 152;
                    dgGambarForm(doc, b, atas);
                    if (i % 2 === 0) dgGarisPotong(doc, 148.5);
                });
                // 20261163730000: Bukti Transfer (form PDA) - satu kartu per transfer, tiga per lembar A4.
                const cb = document.getElementById('dgSertaBukti');
                if (!cb || cb.checked) {
                    const bukti = [];
                    forms.forEach(f => (f.bukti || []).forEach(x => bukti.push(Object.assign({ noForm: f.noForm }, x))));
                    bukti.forEach((x, i) => {
                        if (i % 3 === 0) doc.addPage();
                        const atas = 5 + (i % 3) * 97;
                        dgGambarBukti(doc, x, atas);
                        if (i % 3 < 2 && i < bukti.length - 1) dgGarisPotong(doc, atas + 94.5);
                    });
                }
                return doc;
            }

            // Satu kartu Bukti Transfer (tinggi 92 mm) mulai y = atas. Isi dari data file bank KlikBCA
            // (rc_private.bukti_tf); Nama Penerima dicocokkan lewat No Doc.
            function dgGambarBukti(doc, x, atas) {
                const X = 8, L = 194, H = 92, kiri = 14, kanan = 196, y = d => atas + d;
                const set = (font, gaya, ukuran, warna) => { doc.setFont(font, gaya); doc.setFontSize(ukuran); doc.setTextColor.apply(doc, warna); };
                doc.setFillColor.apply(doc, DG_MERAH); doc.rect(X, atas, 32, 1.6, 'F');
                doc.setFillColor.apply(doc, DG_BIRU); doc.rect(X + 32, atas, L - 32, 1.6, 'F');
                doc.setDrawColor.apply(doc, DG_GARIS); doc.setLineWidth(0.3); doc.rect(X, atas, L, H, 'S');
                let adaLogo = false;
                if (rcDgLogo) {
                    try { const p = doc.getImageProperties(rcDgLogo), lebar = 30; doc.addImage(rcDgLogo, 'PNG', kiri, y(5), lebar, lebar * p.height / p.width, 'logo-nippon', 'FAST'); adaLogo = true; }
                    catch (e) { /* tanpa logo */ }
                }
                if (!adaLogo) { set('helvetica', 'bolditalic', 12, DG_BIRU); doc.text('NIPPON PAINT', kiri, y(11)); }
                set('helvetica', 'bold', 15, DG_BIRU); dgTeksKanan(doc, 'BUKTI TRANSFER', kanan, y(12));
                set('helvetica', 'normal', 7.5, DG_REDUP); dgTeksKanan(doc, 'Lampiran ' + dgTeks(x.noForm), kanan, y(17));
                doc.setDrawColor.apply(doc, DG_GARIS); doc.line(kiri, y(20.5), kanan, y(20.5));
                const baris = [
                    // 20261163740000: rekening pengirim tidak ditampilkan; nama perusahaan di kaki.
                    ['Tanggal Efektif', x.tglEfektif], ['No. Referensi', x.transId], ['Layanan', x.layanan], ['Ke Rekening', x.keRek],
                    ['Bank Tujuan', x.bankTujuan], ['Nama Penerima', x.namaPenerima || '-'],
                    ['Nominal', 'Rp ' + dgRupiah(x.nominal)],
                    ['Biaya', x.sumber === 'template' ? '-' : 'Rp ' + dgRupiah(x.biaya) + (x.biayaOleh ? ' (' + x.biayaOleh + ')' : '')],
                    ['Berita', x.berita], ['Status', x.status]
                ];
                baris.forEach((r, i) => {
                    const ry = y(27.5 + i * 6);
                    set('helvetica', 'normal', 9, DG_REDUP); doc.text(r[0], kiri + 2, ry); doc.text(':', kiri + 38, ry);
                    const nilai = dgTeks(r[1]) || '-';
                    if (r[0] === 'Nominal') set('courier', 'bold', 11, DG_MERAH);
                    else if (r[0] === 'Status') set('helvetica', 'bold', 9.5, nilai === 'BERHASIL' || nilai === 'DIPROSES' ? [26, 127, 55] : DG_MERAH);
                    else set('helvetica', r[0] === 'No. Referensi' || r[0] === 'Ke Rekening' ? 'bold' : 'normal', 9.5, DG_TEKS);
                    doc.text(dgPas(doc, nilai, kanan - kiri - 44), kiri + 41, ry);
                });
                doc.setFillColor.apply(doc, DG_BIRU); doc.rect(X, y(H - 6), L, 6, 'F');
                set('helvetica', 'normal', 7, [255, 255, 255]);
                // 20261163790000: dari Mass Upload tidak ada data bank, jadi tidak boleh mengaku berasal dari KlikBCA.
                doc.text(x.sumber === 'template' ? 'Digenerate otomatis oleh RC berdasarkan data klaim' : 'Digenerate otomatis oleh RC berdasarkan data transaksi dari KlikBCA Bisnis', kiri, y(H - 2.1));
                doc.setFont('helvetica', 'bold'); dgTeksKanan(doc, 'PT Nipsea Paint and Chemicals', kanan, y(H - 2.1));
            }

            function dgGarisPotong(doc, y) {
                doc.setDrawColor.apply(doc, DG_REDUP); doc.setLineWidth(0.25);
                doc.setFont('helvetica', 'normal'); doc.setFontSize(6.5);
                const label = 'POTONG DI SINI', lLabel = doc.getTextWidth(label) + 0.6 * (label.length - 1), xLabel = 202 - lLabel;
                doc.setLineDashPattern([1.2, 1.2], 0); doc.line(14, y, xLabel - 3, y); doc.setLineDashPattern([], 0);
                // Gunting sederhana.
                doc.circle(6.6, y - 1.3, 0.9, 'S'); doc.circle(6.6, y + 1.3, 0.9, 'S');
                doc.line(7.4, y - 0.9, 11.5, y + 1.6); doc.line(7.4, y + 0.9, 11.5, y - 1.6);
                doc.setFont('helvetica', 'normal'); doc.setFontSize(6.5); doc.setTextColor.apply(doc, DG_REDUP);
                doc.setCharSpace(0.6); doc.text(label, xLabel, y + 0.8); doc.setCharSpace(0);
            }

            function dgTeksKanan(doc, t, xKanan, y, jarak) {
                const lebar = doc.getTextWidth(t) + (jarak || 0) * Math.max(0, t.length - 1);
                if (jarak) doc.setCharSpace(jarak);
                doc.text(t, xKanan - lebar, y);
                if (jarak) doc.setCharSpace(0);
            }

            // Satu sel data toko setinggi `tinggi` mm: satu baris 9,5 pt; bila terlalu panjang dibungkus
            // ke baris kedua pada 9 pt, dan sisa yang masih tidak muat dipotong dengan '...'. Teks
            // kosong (mis. rekening yang belum ada di sistem) membiarkan sel kosong untuk ditulis tangan.
            function dgSel(doc, teks, x, atasSel, lebar, gaya, tinggi) {
                const t = dgTeks(teks), h = tinggi || 8.5;
                if (!t) return;
                doc.setFont('helvetica', gaya); doc.setFontSize(9.5); doc.setTextColor.apply(doc, DG_TEKS);
                if (doc.getTextWidth(t) <= lebar) { doc.text(t, x, atasSel + h * 0.66); return; }
                doc.setFontSize(9);
                const baris = doc.splitTextToSize(t, lebar);
                doc.text(baris[0], x, atasSel + h * 0.42);
                doc.text(baris.length > 2 ? dgPas(doc, baris.slice(1).join(' '), lebar) : (baris[1] || ''), x, atasSel + h * 0.82);
            }

            function dgCentang(doc, x, y, aktif) {
                doc.setDrawColor.apply(doc, DG_BIRU); doc.setLineWidth(0.35);
                doc.roundedRect(x, y - 3, 3.4, 3.4, 0.5, 0.5, 'S');
                if (aktif) {
                    doc.setLineWidth(0.6);
                    doc.line(x + 0.7, y - 1.3, x + 1.4, y - 0.4); doc.line(x + 1.4, y - 0.4, x + 2.8, y - 2.4);
                }
            }

            // Satu form (setengah A4, tinggi DG_TINGGI mm) mulai dari y = atas. Baris rekening (18 Oktober
            // 2026) dihapus lagi 5 November 2026 (20261163740000): tabel naik 8,5 mm, tanda tangan 4,5 mm.
            const DG_TINGGI = 141;
            function dgGambarForm(doc, b, atas) {
                const f = b.form, X = 8, L = 194, H = DG_TINGGI, kiri = 14, kanan = 196, y = (d) => atas + d;
                const set = (font, gaya, ukuran, warna) => { doc.setFont(font, gaya); doc.setFontSize(ukuran); doc.setTextColor.apply(doc, warna); };

                // Bingkai, pita atas merah-biru, dan pita kaki biru.
                doc.setFillColor.apply(doc, DG_MERAH); doc.rect(X, atas, 32, 1.6, 'F');
                doc.setFillColor.apply(doc, DG_BIRU); doc.rect(X + 32, atas, L - 32, 1.6, 'F');
                doc.setFillColor.apply(doc, DG_BIRU); doc.rect(X, y(H - 6), L, 6, 'F');
                doc.setDrawColor.apply(doc, DG_GARIS); doc.setLineWidth(0.3); doc.rect(X, atas, L, H, 'S');

                // Kepala: logo merek utuh (PNG transparan, sudah dipangkas ke tepi logonya), judul, nomor form.
                let adaLogo = false;
                if (rcDgLogo) {
                    try {
                        const p = doc.getImageProperties(rcDgLogo), lebar = 37;
                        doc.addImage(rcDgLogo, 'PNG', kiri, y(6), lebar, lebar * p.height / p.width, 'logo-nippon', 'FAST'); // FAST: dikompres, tanpa itu PDF ~800 KB
                        adaLogo = true;
                    } catch (e) { /* tanpa logo */ }
                }
                if (!adaLogo) { set('helvetica', 'bolditalic', 13, DG_BIRU); doc.text('NIPPON', kiri, y(11)); doc.text('PAINT', kiri + 2, y(16.2)); }
                set('helvetica', 'bold', 7, DG_MERAH); dgTeksKanan(doc, 'PROGRAM CASHBACK CAMPAIGN', kanan, y(8.6), 0.55);
                set('helvetica', 'bold', 17, DG_BIRU); dgTeksKanan(doc, 'TANDA TERIMA', kanan, y(15.6));
                const sisa = (f.kategori ? '  ·  ' + f.kategori : '') /* 20261163700000 */ + (b.dari > 1 ? '  ·  Hal ' + b.ke + '/' + b.dari : '') + '  ·  Dicetak ' + dgTeks(f.dicetak);
                set('helvetica', 'normal', 8.5, DG_REDUP); const lSisa = doc.getTextWidth(sisa);
                doc.text(sisa, kanan - lSisa, y(20.6));
                set('courier', 'bold', 9, DG_TEKS); dgTeksKanan(doc, dgTeks(f.noForm), kanan - lSisa, y(20.6));

                // Data toko: 2 baris x 2 pasang (Toko / Depot, Nama Pemilik / Subyek Pajak).
                const iy = y(23), ih = 8.5, k1 = kiri, k2 = 44, k3 = 114, k4 = 138, label = [70, 76, 90], bawah = iy + ih * 2;
                doc.setFillColor.apply(doc, DG_LATAR);
                doc.rect(k1, iy, k2 - k1, ih * 2, 'F'); doc.rect(k3, iy, k4 - k3, ih * 2, 'F');
                doc.setDrawColor.apply(doc, DG_GARIS); doc.setLineWidth(0.3); doc.rect(kiri, iy, kanan - kiri, ih * 2, 'S');
                doc.line(kiri, iy + ih, kanan, iy + ih);
                [k2, k3, k4].forEach(x => doc.line(x, iy, x, bawah));
                set('helvetica', 'normal', 9, label);
                doc.text('Toko', k1 + 2.5, iy + 5.6); doc.text('Nama Pemilik', k1 + 2.5, iy + ih + 5.6);
                doc.text('Depot', k3 + 2.5, iy + 5.6); doc.text('Subyek Pajak', k3 + 2, iy + ih + 5.6);
                dgSel(doc, f.toko.kode + ' - ' + f.toko.nama, k2 + 2.5, iy, k3 - k2 - 5, 'bold', ih);
                dgSel(doc, f.toko.pemilik, k2 + 2.5, iy + ih, k3 - k2 - 5, 'normal', ih);
                dgSel(doc, f.depot.kode + ' - ' + f.depot.nama, k4 + 2.5, iy, kanan - k4 - 5, 'normal', ih);
                set('helvetica', 'normal', 9.5, DG_TEKS);
                const badan = f.toko.subyekPajak === 'Badan';
                dgCentang(doc, k4 + 2.5, iy + ih + 5.8, !badan); doc.text('Perorangan', k4 + 7.5, iy + ih + 5.6);
                dgCentang(doc, k4 + 33, iy + ih + 5.8, badan); doc.text('Badan', k4 + 38, iy + ih + 5.6);

                // Tabel campaign: kepala, 4 baris tetap, baris total. Kolom terakhir Tanggal Proses
                // (20261163590000): tanggal Clearing klaim baris itu, DD-Mon-YY dipisah koma (20261163660000); kolom
                // lain digeser ke kiri untuk memberinya ruang.
                // 20261163700000: form PDH (posting date hidden) tanpa kolom Tanggal Proses - kolom lain kembali lebar.
                const pakaiTgl = f.kategori !== 'PDH';
                const ty = y(42.5), kh = 6.5, bh = 7.5, th = 7, cNo = kiri + 4, cNama = kiri + 9, cTgl = 182, lTgl = 26;
                const cJenis = pakaiTgl ? 105 : 132.5, cNet = pakaiTgl ? 142 : 167, cPajak = pakaiTgl ? 157.5 : 182.5, lNama = (pakaiTgl ? 93 : 119) - cNama;
                doc.setFillColor.apply(doc, DG_BIRU); doc.rect(kiri, ty, kanan - kiri, kh, 'F');
                set('helvetica', 'bold', 7.5, [255, 255, 255]);
                doc.setCharSpace(0.3); doc.text('NO', kiri + 2.5, ty + 4.4); doc.text('KODE - NAMA CAMPAIGN', cNama, ty + 4.4); doc.setCharSpace(0);
                doc.text('JENIS CB', cJenis, ty + 4.4, { align: 'center' });
                dgTeksKanan(doc, 'NET CB (RP)', cNet, ty + 4.4, 0.3);
                doc.text('STATUS PAJAK', cPajak, ty + 4.4, { align: 'center' });
                if (pakaiTgl) doc.text('TANGGAL PROSES', cTgl, ty + 4.4, { align: 'center' });
                for (let i = 0; i < DG_BARIS_PER_FORM; i++) {
                    const ry = ty + kh + i * bh, c = b.isi[i];
                    if (i % 2 === 1) { doc.setFillColor(247, 248, 251); doc.rect(kiri, ry, kanan - kiri, bh, 'F'); }
                    if (i > 0) { doc.setDrawColor(226, 230, 237); doc.setLineWidth(0.2); doc.line(kiri, ry, kanan, ry); }
                    set('helvetica', 'normal', 9, DG_REDUP); doc.text(String(b.mulai + i + 1), cNo, ry + 4.9, { align: 'center' });
                    if (!c) continue;
                    set('helvetica', 'normal', 9, DG_TEKS);
                    const nama = doc.splitTextToSize(dgTeks(c.kode + ' - ' + c.nama), lNama);
                    if (nama.length === 1) doc.text(nama[0], cNama, ry + 4.9);
                    else { doc.text(nama[0], cNama, ry + 3.2); doc.text(nama.length > 2 ? dgPas(doc, nama[1] + ' ' + nama.slice(2).join(' '), lNama) : nama[1], cNama, ry + 6.5); }
                    doc.text(dgPas(doc, c.jenisCb || '-', 20), cJenis, ry + 4.9, { align: 'center' });
                    set('courier', 'bold', 9.5, DG_TEKS); dgTeksKanan(doc, dgRupiah(c.netCb), cNet, ry + 4.9);
                    set('helvetica', 'normal', 9, DG_TEKS); doc.text(dgPajak(c.taxStatus), cPajak, ry + 4.9, { align: 'center' });
                    // Tanggal lebih dari muat satu baris: dua baris, sisanya dipotong '...'. Not Yet: kosong.
                    const tgl = pakaiTgl ? dgTeks(c.tglProses || '') : '';
                    if (tgl) {
                        set('helvetica', 'normal', 8, DG_TEKS);
                        if (doc.getTextWidth(tgl) <= lTgl) doc.text(tgl, cTgl, ry + 4.9, { align: 'center' });
                        else {
                            const bt = doc.splitTextToSize(tgl, lTgl);
                            doc.text(bt[0], cTgl, ry + 3.2, { align: 'center' });
                            doc.text(bt.length > 2 ? dgPas(doc, bt.slice(1).join(' '), lTgl) : bt[1], cTgl, ry + 6.5, { align: 'center' });
                        }
                    }
                }
                const sy = ty + kh + DG_BARIS_PER_FORM * bh, terakhir = b.ke === b.dari;
                doc.setFillColor.apply(doc, DG_LATAR); doc.rect(kiri, sy, kanan - kiri, th, 'F');
                doc.setDrawColor.apply(doc, DG_BIRU); doc.setLineWidth(0.45); doc.line(kiri, sy, kanan, sy);
                doc.setDrawColor.apply(doc, DG_GARIS); doc.setLineWidth(0.3); doc.rect(kiri, ty, kanan - kiri, sy + th - ty, 'S');
                set('helvetica', 'bold', 8.5, DG_BIRU); doc.setCharSpace(0.4);
                doc.text(terakhir ? 'TOTAL NET CASHBACK' : 'SUBTOTAL HAL. ' + b.ke + '/' + b.dari, cNama, sy + 4.7); doc.setCharSpace(0);
                set('courier', 'bold', 10.5, DG_MERAH); dgTeksKanan(doc, dgRupiah(terakhir ? f.total : b.subtotal), cNet, sy + 4.8);
                set('helvetica', 'normal', 6, DG_REDUP);
                if (terakhir) { doc.text('PT Nipsea / Customer =', cPajak, sy + 2.9, { align: 'center' }); doc.text('penanggung pajak', cPajak, sy + 5.3, { align: 'center' }); }
                else { doc.text('Bersambung ke', cPajak, sy + 2.9, { align: 'center' }); doc.text('hal. ' + (b.ke + 1) + '/' + b.dari, cPajak, sy + 5.3, { align: 'center' }); }

                // Keterangan di bawah tabel (pemilik, 4 November 2026; sebelumnya pernyataan verifikasi data).
                set('helvetica', 'normal', 8.5, DG_TEKS);
                const pernyataan = doc.splitTextToSize('Customer mengonfirmasi bahwa seluruh hadiah tersebut telah diproses sesuai dan diterima dengan baik.', kanan - kiri);
                pernyataan.slice(0, 2).forEach((t, i) => doc.text(t, kiri, y(90.7) + i * 3.6));

                // Tanda tangan hanya Pemilik Toko di ujung kanan. Di sampingnya cukup satu baris
                // "Sales : <nama>" dari Customer Master dengan huruf biasa, tanpa kotak (pemilik, 27 Oktober
                // 2026). Sales kosong di master: garis untuk ditulis tangan.
                const gy = y(100.8), by = gy + 3, bt = 25, lToko = 56, xToko = kanan - lToko, xSales = xToko - 64;
                set('helvetica', 'bold', 7, DG_MERAH); doc.setCharSpace(0.5); doc.text('PENERIMA', xToko, gy); doc.setCharSpace(0);
                doc.setLineWidth(0.7); doc.setDrawColor.apply(doc, DG_MERAH); doc.line(xToko, gy + 1.5, xToko + lToko, gy + 1.5);

                set('helvetica', 'normal', 9, DG_TEKS);
                const lblSales = 'Sales : ', xNamaSales = xSales + doc.getTextWidth(lblSales), sales = dgTeks(f.toko.sales);
                doc.text(lblSales, xSales, by + 16.6);
                if (sales) doc.text(dgPas(doc, sales, xToko - 4 - xNamaSales), xNamaSales, by + 16.6);
                else { doc.setDrawColor.apply(doc, DG_TEKS); doc.setLineWidth(0.3); doc.line(xNamaSales, by + 17, xToko - 4, by + 17); }

                doc.setDrawColor.apply(doc, DG_GARIS); doc.setLineWidth(0.3); doc.roundedRect(xToko, by, lToko, bt, 1, 1, 'S');
                set('helvetica', 'bold', 8.5, DG_TEKS); doc.text('Pemilik Toko', xToko + 3, by + 4.5);
                set('helvetica', 'normal', 6, DG_REDUP); doc.text('Tanda tangan & stempel', xToko + lToko / 2, by + 15.6, { align: 'center' });
                doc.setDrawColor.apply(doc, DG_TEKS); doc.setLineWidth(0.3); doc.line(xToko + 3, by + 16.6, xToko + lToko - 3, by + 16.6);
                set('helvetica', 'normal', 7.5, DG_TEKS); doc.text('Nama:', xToko + 3, by + 20.2); doc.text('Tgl:  ____ / ____ / ________', xToko + 3, by + 23.6);

                // Kaki: tab asal (Done / Not Yet) dan saringan Tgl Done, supaya kertasnya dapat dibedakan.
                // Saringan panjang (Tgl Done + No Batch Clearing): awalan dan merek dipendekkan dulu,
                // keterangannya baru dipotong bila masih tidak muat.
                set('helvetica', 'normal', 6.5, [255, 255, 255]);
                const kakiY = y(H - 2.1), pemilik = 'PT Nipsea Paint and Chemicals';
                doc.setFont('helvetica', 'bold'); const lKanan = doc.getTextWidth(pemilik), ruang = kanan - kiri - lKanan - 4;
                let ket = '  ·  Document Generator (' + (f.sumber === 'notyet' ? 'Not Yet' : 'Done' + (f.saringan ? ', ' + dgTeks(f.saringan) : '')) + ')';
                const lebarKaki = (aw, mr) => { doc.setFont('helvetica', 'normal'); let l = doc.getTextWidth(aw + ket); doc.setFont('helvetica', 'bold'); return l + doc.getTextWidth(mr); };
                let awalan = 'Dibuat otomatis oleh ', merek = 'Resource Collection (RC Next Gen)';
                if (lebarKaki(awalan, merek) > ruang) awalan = '';
                if (lebarKaki(awalan, merek) > ruang) merek = 'RC Next Gen';
                if (lebarKaki(awalan, merek) > ruang) { doc.setFont('helvetica', 'bold'); const lm = doc.getTextWidth(merek); doc.setFont('helvetica', 'normal'); ket = dgPas(doc, ket, ruang - lm); }
                doc.setFont('helvetica', 'normal'); doc.text(awalan, kiri, kakiY);
                let kx = kiri + doc.getTextWidth(awalan);
                doc.setFont('helvetica', 'bold'); doc.text(merek, kx, kakiY); kx += doc.getTextWidth(merek);
                doc.setFont('helvetica', 'normal'); doc.text(ket, kx, kakiY);
                doc.setFont('helvetica', 'bold'); dgTeksKanan(doc, pemilik, kanan, kakiY);
            }
