            // ============================================================================
            // DISCOUNT CENTER (20261163310000 - 20261163350000)
            // ============================================================================
            // Spesifikasi pemilik "Aplikasi Disc Generator - Prompt & Template Excel" (21 Oktober
            // 2026) bagian 2-5 dan 7-11; Audit SAP (bagian 6) dikeluarkan. Rancangan layar dari
            // folder "Disc Center". Keputusan pemilik 21 Oktober 2026:
            //  * Sales Distribution IKUT TAB: System Manager, atau siapa pun yang diberi tab
            //    Monitoring / Kebijakan / Generate / Terbitkan (server: disc.sd_saya).
            //  * Sls Org / CG / Mat memakai Valid L-M; satuan scale seperti sekarang; dashboard tidak
            //    dikunci saat masih ada kartu belum di-acknowledge (WAJIB_ACK_DULU = N).
            // Semua angka (Amount, total bertingkat) dihitung server dengan satu rumus; layar hanya
            // menampilkan. Data wilayah sudah disaring server: Admin Depot tidak pernah menerima
            // wilayah, condition type, maupun key combination.

            let rcDc = { tab: 'dashboard', data: null, kartu: [], konfig: null, kb: { offset: 0, total: 0, rows: [], sheet: 'KEBIJAKAN' },
                unggah: null, gen: null, genParam: null, tb: [], mon: null, antre: [], qIdx: 0, mode: null };
            let rcDcMuatKe = 0, rcDcPustaka = {};
            const DC_SEGMEN_URUT = ['DEKORATIF', 'PAINTING TOOLS', 'CAT SEMPROT', 'LAIN-LAIN'];
            const DC_EXCELJS = 'https://cdnjs.cloudflare.com/ajax/libs/exceljs/4.4.0/exceljs.min.js';
            const DC_JSPDF = 'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js';
            const DC_AUTOTABLE = 'https://cdnjs.cloudflare.com/ajax/libs/jspdf-autotable/3.8.2/jspdf.plugin.autotable.min.js';
            const DC_TABS = { dashboard: ['dcTabDashboard', 'dcPanelDashboard'], ack: ['dcTabAck', 'dcPanelAck'], monitor: ['dcTabMonitor', 'dcPanelMonitor'],
                kebijakan: ['dcTabKebijakan', 'dcPanelKebijakan'], generate: ['dcTabGenerate', 'dcPanelGenerate'], terbit: ['dcTabTerbit', 'dcPanelTerbit'] };

            // ---------- Utilitas ----------
            function dcPct(v) { return v === null || v === undefined || v === '' ? '-' : Number(v).toLocaleString('id-ID', { maximumFractionDigits: 3 }) + '%'; }
            function dcAngka(v) { return v === null || v === undefined || v === '' ? '' : Number(v).toLocaleString('id-ID', { maximumFractionDigits: 3 }); }
            function dcPerLabel(p) { const m = String(p || '').match(/^(\d{4})-(\d{2})$/); return m ? RC_BULAN_SINGKAT[Number(m[2]) - 1] + '-' + m[1] : (p || '-'); }
            function dcBerlaku(dari, sampai) { return rcDisplayDate(dari) + ' – ' + rcDisplayDate(sampai); }
            function dcIsSd() { return !!(rcDc.data && rcDc.data.sd); }
            function dcBelum() { return (rcDc.kartu || []).filter(c => !c.ack && c.wajibAck); }
            function dcBadge(teks, kelas) { return '<span class="' + kelas + ' px-1.5 py-0.5 rounded text-[9px] font-black uppercase">' + rcEsc(teks) + '</span>'; }
            function dcMuatSkrip(src) {
                if (!rcDcPustaka[src]) rcDcPustaka[src] = new Promise((ok, gagal) => {
                    const s = document.createElement('script'); s.src = src; s.async = true; s.onload = ok;
                    s.onerror = () => { delete rcDcPustaka[src]; gagal(new Error('Pustaka gagal dimuat. Periksa koneksi internet lalu coba lagi.')); };
                    document.head.appendChild(s);
                });
                return rcDcPustaka[src];
            }
            function dcUnduhBlob(blob, nama) {
                const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = nama;
                document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
            }
            // Sheet Excel: semua sel teks (kode seperti 1100,1400 dan 01 tidak berubah jadi angka).
            function dcSheetTeks(aoa) {
                const ws = XLSX.utils.aoa_to_sheet(aoa.map(r => r.map(v => v === null || v === undefined ? '' : String(v))));
                Object.keys(ws).forEach(k => { if (k[0] !== '!') { ws[k].t = 's'; ws[k].z = '@'; } });
                return ws;
            }

            // ---------- Navigasi ----------
            function switchDiscTab(tab) {
                if (!rcEnterTab('discount', tab)) return;
                rcDc.tab = tab;
                Object.entries(DC_TABS).forEach(([k, [btn, panel]]) => {
                    const b = document.getElementById(btn);
                    if (b) b.className = 'px-5 py-2 text-sm font-bold rounded-lg transition whitespace-nowrap ' + (k === tab ? 'bg-rose-100 text-rose-700' : 'text-gray-500 hover:bg-gray-100');
                    setHiddenSafely(panel, k !== tab);
                });
                if (tab === 'dashboard') dcMuatDashboard(false).then(r => { if (r) dcRenderDashboard(); });
                else if (tab === 'ack') dcMuatDashboard(false).then(r => { if (r) dcRenderAck(); });
                else if (tab === 'monitor') dcMuatMonitor();
                else if (tab === 'kebijakan') dcBukaKebijakan();
                else if (tab === 'generate') dcBukaGenerate();
                else if (tab === 'terbit') dcBukaTerbit();
            }
            function dcSegarkanTab() {
                const m = document.getElementById('modDiscountCenter');
                if (!m || m.classList.contains('hidden')) return;
                if (rcDc.tab === 'dashboard') dcRenderDashboard(); else if (rcDc.tab === 'ack') dcRenderAck();
            }

            // ---------- Dashboard ----------
            async function dcMuatDashboard(paksa, diam) {
                if (rcDc.data && !paksa) { dcTerapkanPeran(); return rcDc.data; }
                const ke = ++rcDcMuatKe;
                if (!diam) showLoadingOverlay('Memuat Discount Center...');
                try {
                    const r = await fetchApp({ action: 'discDashboard' });
                    if (r.status !== 'success') throw new Error(r.message || 'Discount Center gagal dimuat');
                    if (ke !== rcDcMuatKe) return rcDc.data;
                    rcDc.data = r; rcDc.kartu = r.kartu || [];
                    dcTerapkanPeran(); dcIsiFilterDashboard(); dcPerbaruiBadge();
                    return r;
                } catch (e) { if (!diam) showNotification(e.message, 'error'); return null; }
                finally { if (!diam) hideLoadingOverlay(); }
            }

            function dcTerapkanPeran() {
                const sd = dcIsSd();
                document.querySelectorAll('.dc-sd-only').forEach(el => el.classList.toggle('hidden', !sd));
                document.querySelectorAll('.dc-admin-only').forEach(el => el.classList.toggle('hidden', sd));
                const dep = (rcDc.data && rcDc.data.depot) || [];
                const el = document.getElementById('dcWilayahSaya');
                if (el) el.innerHTML = '<i class="fas fa-map-marker-alt mr-1.5"></i>' + (sd ? 'Semua depot dan region'
                    : (dep.length ? 'Depot Anda: ' + rcEsc(dep.map(d => d.kode + (d.region ? ' (Region ' + d.region + ')' : '')).join(', ')) : 'Nasional'));
                const t = document.getElementById('btnDcMulaiBacaText');
                if (t) t.textContent = sd ? 'Baca & Acknowledge Semua' : 'Mulai Baca';
            }

            function dcPerbaruiBadge() {
                const n = rcDc.data && rcDc.data.bolehAck ? dcBelum().length : 0;
                ['menuDiscountBadge', 'dcTabAckBadge'].forEach(id => { const el = document.getElementById(id); if (!el) return; el.textContent = n; el.classList.toggle('hidden', n === 0); });
            }

            function dcIsiFilterDashboard() {
                const per = [...new Set(rcDc.kartu.map(c => c.periode))].sort().reverse();
                const sel = document.getElementById('dcFilterPeriode'); if (!sel) return;
                const lama = sel.value;
                const kini = (rcDc.data.hariIni || '').slice(0, 7);
                sel.innerHTML = '<option value="">Semua Periode</option>' + per.map(p => '<option value="' + p + '">' + dcPerLabel(p) + '</option>').join('');
                sel.value = per.includes(lama) ? lama : (per.includes(kini) ? kini : (per[0] || ''));
                if (dcIsSd()) {
                    const cts = [...new Set(rcDc.kartu.flatMap(c => String(c.ct || '').split(', ')))].filter(x => x && x !== '-').sort();
                    const keys = [...new Set(rcDc.kartu.flatMap(c => String(c.key || '').split(', ')))].filter(x => x && x !== '-').sort();
                    document.getElementById('dcFilterCt').innerHTML = '<option value="">Semua Condition Type</option>' + cts.map(c => '<option>' + rcEsc(c) + '</option>').join('');
                    document.getElementById('dcFilterKey').innerHTML = '<option value="">Semua Key Combination</option>' + keys.map(k => '<option>' + rcEsc(k) + '</option>').join('');
                }
            }

            function dcResetFilter() {
                ['dcSearch', 'dcFilterSegmen', 'dcFilterJenis', 'dcFilterCt', 'dcFilterKey'].forEach(id => { const el = document.getElementById(id); if (el) el.value = ''; });
                dcRenderDashboard();
            }

            function dcJenisKartu(c) {
                const s = new Set();
                (c.tiers || []).forEach(t => { if (t.vol != null) s.add('VOL'); if (t.cmp != null) s.add('CMP'); if (t.bulk != null) s.add('BULK'); (t.lain || []).forEach(x => s.add(String(x.jenis).toUpperCase())); });
                if ((c.faktur || []).length) s.add('FAKTUR');
                return [...s];
            }
            // Angka merah: beda dari periode lalu (tier.ubah) atau dari versi sebelumnya (revisiUbah).
            function dcUbah(c, t, f) {
                if ((t.ubah || []).includes(f)) return true;
                return (c.revisiUbah || []).some(x => x.syarat === t.syarat && (x.dari || '') === (t.dari || '') && (x.ubah || []).includes(f));
            }
            function dcSyarat(t) { return rcEsc(t.syarat) + (t.dari ? '<span class="block text-[10px] font-normal text-gray-500">' + rcEsc(dcBerlaku(t.dari, t.sampai)) + '</span>' : ''); }
            function dcLain(t) { return (t.lain || []).map(x => x.jenis + ' ' + dcPct(x.d)).join(' + ') || '-'; }
            function dcFaktur(c) { return (c.faktur || []).length ? 'Diskon faktur ' + c.faktur.map(f => dcPct(f.d)).join(' + ') + ' (tidak ikut dihitung)' : ''; }
            function dcWilayahTampil(c) {
                if (!dcIsSd()) return (c.depotTercakup || []).join(', ');
                const w = c.wilayah || [];
                return w.length > 3 ? w.slice(0, 2).join(', ') + ' +' + (w.length - 2) : w.join(', ');
            }
            function dcBadgesKartu(c) {
                return dcBadge(c.jenisProduk === 'CCM' ? 'CCM' : 'RM', c.jenisProduk === 'CCM' ? 'bg-sky-100 text-sky-700' : 'bg-gray-800 text-white')
                    + dcJenisKartu(c).map(j => dcBadge(j, 'bg-gray-100 text-gray-600')).join('')
                    + (c.versi > 1 ? dcBadge('Revisi v' + c.versi, 'bg-amber-100 text-amber-800') : '')
                    + (c.ack || !c.wajibAck || !(rcDc.data && rcDc.data.bolehAck) ? '' : dcBadge('Belum dibaca', 'bg-red-100 text-red-700'));
            }
            function dcTierBaris(c, t) {
                const u = f => dcUbah(c, t, f) ? 'text-red-600 font-black' : '';
                const bag = [];
                if (t.vol != null) bag.push('<span class="' + u('vol') + '">Vol ' + dcPct(t.vol) + '</span>');
                if (t.cmp != null) bag.push('<span class="' + u('cmp') + '">CMP ' + dcPct(t.cmp) + '</span>');
                if (t.bulk != null) bag.push('<span class="' + u('bulk') + '">Bulk ' + dcPct(t.bulk) + '</span>');
                (t.lain || []).forEach(x => bag.push('<span class="' + u('lain') + '">' + rcEsc(x.jenis) + ' ' + dcPct(x.d) + '</span>'));
                return '<div class="flex items-center justify-between gap-3 px-3 py-2.5 border-t border-gray-100">'
                    + '<div class="min-w-0"><p class="font-bold text-gray-800 text-sm">' + dcSyarat(t) + '</p><p class="text-[11px] text-gray-500">' + bag.join(' · ') + '</p></div>'
                    + '<p class="font-black text-rose-800 bg-rose-50 px-2.5 py-1 rounded-lg whitespace-nowrap">' + dcPct(t.total) + '</p></div>';
            }
            // Kartu ringkas: tampilan HP dan daftar acknowledge massal.
            function dcKartuHtml(c, denganDetail) {
                const sd = dcIsSd();
                return '<div class="border border-gray-200 rounded-xl overflow-hidden bg-white">'
                    + '<div class="p-3"><div class="flex justify-between items-start gap-2"><p class="font-black text-gray-800 leading-snug">' + rcEsc(c.produk) + '</p>'
                    + (denganDetail ? '<button onclick="openDiscCard(\'' + c.id + '\')" class="shrink-0 px-3 py-1.5 bg-white border border-gray-300 text-rose-700 font-bold rounded-lg text-xs">Detail</button>' : '') + '</div>'
                    + '<p class="text-[11px] text-gray-500 font-mono mt-0.5">' + rcEsc(c.kode) + ' · ' + rcEsc(c.kemasan || '-') + '</p>'
                    + '<p class="text-[11px] font-bold text-rose-700 mt-1">' + rcEsc(c.remark) + '</p>'
                    + '<div class="flex flex-wrap gap-1 mt-1.5">' + dcBadgesKartu(c) + '</div>'
                    + (c.versi > 1 && c.revisi && !c.ack ? '<p class="mt-2 text-[11px] font-bold text-amber-800"><i class="fas fa-rotate mr-1"></i>' + rcEsc(c.revisi) + '</p>' : '') + '</div>'
                    + (c.tiers || []).map(t => dcTierBaris(c, t)).join('')
                    + (dcFaktur(c) ? '<p class="px-3 py-2 border-t border-gray-100 text-[11px] text-gray-500">' + rcEsc(dcFaktur(c)) + '</p>' : '')
                    + '<div class="px-3 py-2 bg-gray-50 border-t border-gray-100 text-[11px] text-gray-600 flex flex-wrap gap-x-3 gap-y-0.5">'
                    + '<span><i class="fas fa-calendar-alt mr-1 text-gray-400"></i>' + rcEsc(dcBerlaku(c.dari, c.sampai)) + '</span>'
                    + '<span><i class="fas fa-map-marker-alt mr-1 text-gray-400"></i>' + rcEsc(dcWilayahTampil(c)) + '</span>'
                    + (sd ? '<span><i class="fas fa-database mr-1 text-gray-400"></i>' + rcEsc(c.ct || '-') + ' · ' + rcEsc(c.key || '-') + '</span>' : '') + '</div>'
                    + (c.catatan ? '<p class="px-3 py-2 border-t border-gray-100 text-[11px] text-gray-600">' + rcEsc(c.catatan) + '</p>' : '') + '</div>';
            }

            function dcSaring() {
                const sd = dcIsSd();
                const q = document.getElementById('dcSearch').value.trim().toLowerCase().split(/\s+/).filter(Boolean);
                const per = document.getElementById('dcFilterPeriode').value, segmen = document.getElementById('dcFilterSegmen').value;
                const jenis = document.getElementById('dcFilterJenis').value;
                const ct = sd ? document.getElementById('dcFilterCt').value : '', key = sd ? document.getElementById('dcFilterKey').value : '';
                return rcDc.kartu.filter(c => {
                    if (per && c.periode !== per) return false;
                    if (segmen && c.segmen !== segmen) return false;
                    if (jenis && c.jenisProduk !== jenis) return false;
                    if (ct && !String(c.ct || '').split(', ').includes(ct)) return false;
                    if (key && !String(c.key || '').split(', ').includes(key)) return false;
                    const hay = [c.produk, c.alias, c.mg, c.material, c.kemasan, c.segmen, c.jenisProduk, c.remark, c.untuk, c.memo, c.catatan,
                        dcJenisKartu(c).join(' '), sd ? [c.ct, c.key, (c.wilayah || []).join(' ')].join(' ') : (c.depotTercakup || []).join(' ')].join(' ').toLowerCase();
                    return q.every(k => hay.includes(k));
                });
            }

            function dcRenderDashboard() {
                if (!rcDc.data) return;
                const sd = dcIsSd(), rows = dcSaring();
                document.getElementById('dcPeriodeLabel').textContent = document.getElementById('dcFilterPeriode').value ? dcPerLabel(document.getElementById('dcFilterPeriode').value) : 'Semua';
                const grup = {};
                rows.forEach(c => (grup[c.segmen] = grup[c.segmen] || []).push(c));
                const urutan = DC_SEGMEN_URUT.filter(s => grup[s]).concat(Object.keys(grup).filter(s => !DC_SEGMEN_URUT.includes(s)));
                const kolom = sd ? 12 : 11;
                let html = '', hp = '';
                urutan.forEach(seg => {
                    html += '<tr class="bg-rose-50/60 border-b border-rose-100"><td colspan="' + kolom + '" class="p-2 px-3 text-[11px] font-black uppercase tracking-wider text-rose-800">' + rcEsc(seg) + '</td></tr>';
                    hp += '<p class="text-[11px] font-black uppercase tracking-wider text-rose-800 pt-2">' + rcEsc(seg) + '</p>';
                    grup[seg].forEach(c => {
                        hp += dcKartuHtml(c, true);
                        const tiers = (c.tiers || []).length ? c.tiers : [{ syarat: 'Diskon faktur', lain: [], total: null }];
                        const n = tiers.length;
                        tiers.forEach((t, i) => {
                            const u = f => dcUbah(c, t, f) ? ' text-red-600 font-black' : ' text-gray-700';
                            html += '<tr class="border-b border-gray-100 hover:bg-rose-50/30 align-top">';
                            if (i === 0) {
                                html += '<td class="p-3" rowspan="' + n + '"><p class="font-black text-gray-800">' + rcEsc(c.produk) + '</p>'
                                    + (sd ? '<p class="text-[11px] text-gray-500 mt-0.5">' + rcEsc(c.remark) + '</p>' : '')
                                    + (dcFaktur(c) ? '<p class="text-[10px] text-gray-500 mt-0.5">' + rcEsc(dcFaktur(c)) + '</p>' : '')
                                    + '<div class="flex flex-wrap gap-1 mt-1.5">' + dcBadgesKartu(c) + '</div></td>'
                                    + '<td class="p-3 font-mono text-xs text-gray-700" rowspan="' + n + '">' + rcEsc(c.kode) + '<br><span class="text-gray-400">' + rcEsc(c.kemasan || '-') + '</span></td>';
                            }
                            html += '<td class="px-2 py-3 text-center font-bold text-gray-800">' + dcSyarat(t) + '</td>'
                                + '<td class="px-2 py-3 text-center' + u('vol') + '">' + dcPct(t.vol) + '</td>'
                                + '<td class="px-2 py-3 text-center' + u('cmp') + '">' + dcPct(t.cmp) + '</td>'
                                + '<td class="px-2 py-3 text-center' + u('bulk') + '">' + dcPct(t.bulk) + '</td>'
                                + '<td class="px-2 py-3 text-center' + u('lain') + '">' + rcEsc(dcLain(t)) + '</td>'
                                + '<td class="px-2 py-3 text-center font-black text-rose-800 bg-rose-50/50 whitespace-nowrap">' + dcPct(t.total) + '</td>';
                            if (i === 0) {
                                html += '<td class="p-3 text-center text-xs text-gray-600 min-w-[110px]" rowspan="' + n + '">' + rcEsc(dcBerlaku(c.dari, c.sampai)) + '</td>'
                                    + (sd ? '<td class="p-3 text-xs text-gray-600" rowspan="' + n + '">' + rcEsc(dcWilayahTampil(c)) + '</td>'
                                        + '<td class="p-3 text-xs font-black text-gray-700" rowspan="' + n + '">' + rcEsc(c.ct || '-')
                                        + '<span class="block font-normal text-gray-500 whitespace-nowrap mt-0.5">' + rcEsc(c.key || '-') + '</span></td>'
                                        : '<td class="p-3 text-xs font-bold text-rose-700" rowspan="' + n + '">' + rcEsc(c.remark) + '</td>')
                                    + '<td class="p-3 text-center" rowspan="' + n + '"><button onclick="openDiscCard(\'' + c.id + '\')" class="px-3 py-1.5 bg-white border border-gray-300 hover:bg-rose-50 text-rose-700 font-bold rounded-lg text-xs">Detail</button></td>';
                            }
                            html += '</tr>';
                        });
                    });
                });
                document.getElementById('dcMemoBody').innerHTML = html || '<tr><td colspan="' + kolom + '" class="p-8 text-center text-gray-500">Tidak ada disc yang cocok.</td></tr>';
                document.getElementById('dcMemoCards').innerHTML = hp || '<p class="p-8 text-center text-gray-500 text-sm">Tidak ada disc yang cocok.</p>';
                document.getElementById('dcHasilInfo').innerHTML = '<b>' + rows.length + '</b> produk, <b>' + rows.reduce((a, c) => a + (c.tiers || []).length, 0) + '</b> tier';
            }

            // Memo PDF sesuai filter yang sedang dipakai.
            async function dcCetakMemo() {
                const rows = dcSaring();
                if (!rows.length) { showNotification('Tidak ada disc untuk dicetak.', 'warning'); return; }
                showLoadingOverlay('Menyusun memo PDF...');
                try {
                    await dcMuatSkrip(DC_JSPDF); await dcMuatSkrip(DC_AUTOTABLE);
                    const sd = dcIsSd(), t = s => dgTeksAman(s);
                    const doc = new window.jspdf.jsPDF({ orientation: 'landscape', unit: 'mm', format: 'a4' });
                    const per = document.getElementById('dcFilterPeriode').value;
                    doc.setFontSize(14); doc.setFont('helvetica', 'bold');
                    doc.text('Memo Kebijakan Discount' + (per ? ' - ' + dcPerLabel(per) : ''), 14, 14);
                    doc.setFontSize(8); doc.setFont('helvetica', 'normal');
                    doc.text(t('Dicetak ' + rcDisplayDate(new Date().toISOString(), true) + ' oleh ' + (currentUserData.namaLengkap || '') + ' - '
                        + (sd ? 'semua depot dan region' : 'depot ' + ((rcDc.data.depot || []).map(d => d.kode).join(', ') || '-'))
                        + '. Angka merah berubah dari periode lalu / versi sebelumnya. Total = 1 - (1 - a)(1 - b)...'), 14, 19);
                    const head = [['Produk', 'MG / Kemasan', 'Syarat', 'Vol', 'Campaign', 'Bulk', 'Lain', 'Total', 'Berlaku'].concat(sd ? ['Wilayah', 'Condition Type'] : ['Remark'])];
                    const body = [], merah = { textColor: [220, 38, 38], fontStyle: 'bold' };
                    const grup = {};
                    rows.forEach(c => (grup[c.segmen] = grup[c.segmen] || []).push(c));
                    DC_SEGMEN_URUT.filter(s => grup[s]).concat(Object.keys(grup).filter(s => !DC_SEGMEN_URUT.includes(s))).forEach(seg => {
                        body.push([{ content: seg, colSpan: head[0].length, styles: { fillColor: [255, 228, 230], textColor: [159, 18, 57], fontStyle: 'bold' } }]);
                        grup[seg].forEach(c => {
                            const tiers = (c.tiers || []).length ? c.tiers : [{ syarat: 'Diskon faktur', lain: [], total: null }];
                            tiers.forEach((tr, i) => {
                                const sel = (f, v) => dcUbah(c, tr, f) ? { content: v, styles: merah } : v;
                                const baris = [];
                                if (i === 0) {
                                    baris.push({ content: t(c.produk + (sd ? '\n' + c.remark : '') + (dcFaktur(c) ? '\n' + dcFaktur(c) : '')), rowSpan: tiers.length });
                                    baris.push({ content: t(c.kode + '\n' + (c.kemasan || '-')), rowSpan: tiers.length });
                                }
                                baris.push(t(tr.syarat + (tr.dari ? '\n' + dcBerlaku(tr.dari, tr.sampai) : '')), sel('vol', dcPct(tr.vol)), sel('cmp', dcPct(tr.cmp)),
                                    sel('bulk', dcPct(tr.bulk)), sel('lain', t(dcLain(tr))), { content: dcPct(tr.total), styles: { fontStyle: 'bold', textColor: [159, 18, 57] } });
                                if (i === 0) {
                                    baris.push({ content: t(dcBerlaku(c.dari, c.sampai)), rowSpan: tiers.length });
                                    if (sd) baris.push({ content: t((c.wilayah || []).join(', ')), rowSpan: tiers.length }, { content: t((c.ct || '-') + '\n' + (c.key || '-')), rowSpan: tiers.length });
                                    else baris.push({ content: t(c.remark), rowSpan: tiers.length });
                                }
                                body.push(baris);
                            });
                        });
                    });
                    doc.autoTable({ head: head, body: body, startY: 23, theme: 'grid', styles: { fontSize: 7, cellPadding: 1.5, valign: 'middle' },
                        headStyles: { fillColor: [190, 18, 60], textColor: 255 }, margin: { left: 10, right: 10 } });
                    doc.save('Memo_Discount_' + (per || 'Semua') + '.pdf');
                    showNotification('Memo PDF diunduh.', 'success');
                } catch (e) { showNotification(e.message || 'Memo gagal dibuat.', 'error'); }
                finally { hideLoadingOverlay(); }
            }
            // Fon standar PDF hanya Latin-1.
            function dgTeksAman(v) {
                return String(v == null ? '' : v).replace(/[–—−]/g, '-').replace(/·/g, '/').replace(/×/g, 'x').replace(/[^\x0A\x20-\x7E\xA0-\xFF]/g, '?');
            }

            // ---------- Acknowledge ----------
            function dcRenderAck() {
                if (!rcDc.data) return;
                const semua = rcDc.kartu.filter(c => c.wajibAck || c.ack), belum = semua.filter(c => !c.ack);
                document.getElementById('dcAckBelum').textContent = belum.length;
                document.getElementById('dcAckSudah').textContent = semua.length - belum.length;
                document.getElementById('dcAckTotal').textContent = semua.length;
                const pct = semua.length ? Math.round((semua.length - belum.length) / semua.length * 100) : 100;
                document.getElementById('dcAckPersen').textContent = pct + '%';
                document.getElementById('dcAckBar').style.width = pct + '%';
                document.getElementById('btnDcMulaiBaca').disabled = belum.length === 0 || !rcDc.data.bolehAck;
                const urut = semua.slice().sort((a, b) => (a.ack ? 1 : 0) - (b.ack ? 1 : 0));
                const sd = dcIsSd();
                document.getElementById('dcAckBody').innerHTML = urut.map(c => '<tr class="border-b border-gray-100 hover:bg-rose-50/30">'
                    + '<td class="p-3 text-center"><span class="' + (c.ack ? 'bg-emerald-100 text-emerald-700' : 'bg-red-100 text-red-700') + ' px-2 py-1 rounded text-[10px] font-black uppercase whitespace-nowrap">' + (c.ack ? 'Sudah' : (c.versi > 1 ? 'Revisi' : 'Belum')) + '</span></td>'
                    + '<td class="p-3"><p class="font-bold text-gray-800">' + rcEsc(c.produk) + '</p><p class="text-[11px] text-gray-500">' + rcEsc(c.kode) + ' · ' + rcEsc(c.remark) + '</p></td>'
                    + '<td class="p-3 text-center text-xs">' + rcEsc(dcPerLabel(c.periode)) + '</td>'
                    + (sd ? '<td class="p-3 text-xs text-gray-600">' + rcEsc(dcWilayahTampil(c)) + '</td>' : '')
                    + '<td class="p-3 text-center font-bold">v' + c.versi + '</td>'
                    + '<td class="p-3 text-center text-xs text-gray-600 whitespace-nowrap">' + rcEsc(rcDisplayDate(c.terbit)) + '</td>'
                    + '<td class="p-3 text-center text-xs text-gray-600 whitespace-nowrap">' + rcEsc(c.ack ? rcDisplayDate(c.ack, true) : '-') + '</td>'
                    + '<td class="p-3 text-center"><button onclick="openDiscCard(\'' + c.id + '\')" class="px-3 py-1.5 bg-white border border-gray-300 hover:bg-rose-50 text-rose-700 font-bold rounded-lg text-xs">' + (c.ack ? 'Lihat' : 'Baca') + '</button></td></tr>').join('')
                    || '<tr><td colspan="8" class="p-8 text-center text-gray-500">Belum ada kartu terbit untuk Anda.</td></tr>';
            }

            function dcBukaModal() { setHiddenSafely('discountAckModal', false); }
            function dcModeModal(massal) {
                setHiddenSafely('dakSatu', massal); setHiddenSafely('dakMassal', !massal);
                setHiddenSafely('dakAckBtn', massal); setHiddenSafely('dakAckSemuaBtn', !massal); setHiddenSafely('dakChips', massal);
                // WAJIB_ACK_DULU = Y: antrean Admin Depot tidak bisa ditunda.
                setHiddenSafely('dakNantiBtn', !!(rcDc.data && rcDc.data.wajibAckDulu && !dcIsSd() && rcDc.mode !== 'lihat'));
            }
            function dcIsiModal(c) {
                const chip = (t, k) => '<span class="bg-white border ' + k + ' px-2 py-0.5 rounded">' + rcEsc(t) + '</span>';
                document.getElementById('dakProduk').textContent = c.produk;
                document.getElementById('dakChips').innerHTML = chip(c.segmen, 'border-rose-100 text-rose-700') + chip(c.jenisProduk, 'border-gray-200 text-gray-600')
                    + dcJenisKartu(c).map(j => chip(j, 'border-gray-200 text-gray-600')).join('') + chip('Versi ' + c.versi, 'border-gray-200 text-gray-600');
                document.getElementById('dakMg').textContent = c.kode + ' · ' + (c.kemasan || '-');
                document.getElementById('dakBerlaku').textContent = dcBerlaku(c.dari, c.sampai);
                document.getElementById('dakWilayah').textContent = (c.wilayah || []).join(', ') || '-';
                document.getElementById('dakCt').textContent = c.ct || '-';
                document.getElementById('dakKey').textContent = c.key || '';
                document.getElementById('dakRemark').textContent = c.remark || '-';
                const tiers = c.tiers || [];
                document.getElementById('dakTierBody').innerHTML = tiers.map(t => {
                    const u = f => dcUbah(c, t, f) ? ' text-red-600 font-black' : ' text-gray-700';
                    return '<tr class="border-b border-gray-100"><td class="p-3 text-center font-bold text-gray-800">' + dcSyarat(t) + '</td>'
                        + '<td class="p-3 text-center' + u('vol') + '">' + dcPct(t.vol) + '</td><td class="p-3 text-center' + u('cmp') + '">' + dcPct(t.cmp) + '</td>'
                        + '<td class="p-3 text-center' + u('bulk') + '">' + dcPct(t.bulk) + '</td><td class="p-3 text-center' + u('lain') + '">' + rcEsc(dcLain(t)) + '</td>'
                        + '<td class="p-3 text-center font-black text-rose-800 bg-rose-50/50">' + dcPct(t.total) + '</td></tr>';
                }).join('') || '<tr><td colspan="6" class="p-4 text-center text-gray-500">Hanya diskon faktur.</td></tr>';
                document.getElementById('dakTierCards').innerHTML = tiers.map(t => dcTierBaris(c, t)).join('').replace('border-t border-gray-100', '');
                document.getElementById('dakCatatan').textContent = [dcIsSd() ? 'Remark: ' + c.remark + '.' : '', 'Untuk: ' + (c.untuk || '-'), dcFaktur(c), c.catatan].filter(Boolean).join('\n');
                document.getElementById('dakMemo').textContent = 'Sumber: ' + (c.memo || '-') + (c.terbit ? ' · Diterbitkan ' + rcDisplayDate(c.terbit) : '');
                setHiddenSafely('dakRevisi', !(c.versi > 1 && c.revisi));
                document.getElementById('dakRevisiText').textContent = c.revisi || 'Kartu ini direvisi setelah terbit.';
            }

            function openDiscAckQueue() {
                if (!rcDc.data || !rcDc.data.bolehAck) { showNotification('Anda tidak memiliki tab Acknowledge.', 'warning'); return; }
                rcDc.antre = dcBelum(); rcDc.qIdx = 0;
                if (!rcDc.antre.length) { showNotification('Semua disc untuk Anda sudah dibaca.', 'success'); return; }
                if (dcIsSd()) dcTampilMassal(); else { rcDc.mode = 'antre'; dcModeModal(false); dcTampilAntrean(); }
                dcBukaModal();
                if (dcIsSd()) setTimeout(dcCekGulirMassal, 80);
            }
            // Mode massal: semua kartu dalam satu daftar; tombol aktif setelah digulir sampai akhir.
            function dcTampilMassal() {
                rcDc.mode = 'massal'; dcModeModal(true);
                document.getElementById('dakJudulKecil').textContent = 'Gulir sampai habis, lalu acknowledge semua';
                document.getElementById('dakProduk').textContent = rcDc.antre.length + ' disc baru untuk dibaca';
                document.getElementById('dakCounter').textContent = rcDc.antre.length + ' kartu';
                document.getElementById('dakBar').style.width = '0%';
                document.getElementById('dakMassalList').innerHTML = rcDc.antre.map(c => dcKartuHtml(c, false)).join('');
                document.getElementById('dakAckSemuaCount').textContent = rcDc.antre.length;
                document.getElementById('dakAckSemuaBtn').disabled = true;
                document.getElementById('dakFooterText').textContent = 'Gulir daftar sampai kartu terakhir untuk mengaktifkan tombol. Waktu dan versi setiap kartu dicatat.';
                document.getElementById('dakNantiBtn').textContent = 'Nanti';
                document.getElementById('dakMassal').scrollTop = 0;
            }
            function dcCekGulirMassal() {
                const el = document.getElementById('dakMassal'); if (!el || el.classList.contains('hidden')) return;
                const sisa = el.scrollHeight - el.clientHeight;
                const pct = sisa <= 8 ? 100 : Math.min(100, Math.round(el.scrollTop / sisa * 100));
                document.getElementById('dakBar').style.width = pct + '%';
                if (pct >= 98 && document.getElementById('dakAckSemuaBtn').disabled) {
                    document.getElementById('dakAckSemuaBtn').disabled = false;
                    document.getElementById('dakFooterText').textContent = 'Anda sudah menggulir sampai akhir. Tekan Acknowledge Semua untuk mencatat semua kartu.';
                }
            }
            async function dcKirimAck(kartu) {
                const r = await fetchApp({ action: 'discAck', items: kartu.map(c => ({ id: c.id, versi: c.versi })) });
                if (r.status !== 'success') throw new Error(r.message || 'Acknowledge gagal dicatat.');
                const kini = new Date().toISOString();
                kartu.forEach(c => { c.ack = kini; });
                return r;
            }
            async function ackDiscSemua() {
                const btn = document.getElementById('dakAckSemuaBtn'); btn.disabled = true;
                try {
                    const r = await dcKirimAck(rcDc.antre);
                    closeDiscAckModal(true);
                    showNotification(r.dicatat + ' kartu tercatat sudah dibaca.', 'success');
                } catch (e) { btn.disabled = false; showNotification(e.message, 'error'); }
            }
            function dcTampilAntrean() {
                const c = rcDc.antre[rcDc.qIdx];
                dcIsiModal(c);
                document.getElementById('dakJudulKecil').textContent = 'Disc baru untuk depot Anda (' + rcDc.antre.length + ')';
                document.getElementById('dakCounter').textContent = (rcDc.qIdx + 1) + ' / ' + rcDc.antre.length;
                document.getElementById('dakBar').style.width = Math.round(rcDc.qIdx / rcDc.antre.length * 100) + '%';
                document.getElementById('dakFooterText').textContent = 'Dengan menekan tombol di samping, Anda menyatakan sudah membaca disc ini. Waktu dan versi kartu dicatat.';
                setHiddenSafely('dakAckBtn', false);
                document.getElementById('dakAckBtn').disabled = false;
                document.getElementById('dakNantiBtn').textContent = 'Nanti';
            }
            function openDiscCard(id) {
                const c = rcDc.kartu.find(x => x.id === id); if (!c) return;
                if (!c.ack && c.wajibAck && rcDc.data.bolehAck) { rcDc.antre = [c]; rcDc.qIdx = 0; rcDc.mode = 'antre'; dcModeModal(false); dcTampilAntrean(); }
                else {
                    rcDc.mode = 'lihat'; dcModeModal(false); dcIsiModal(c);
                    document.getElementById('dakJudulKecil').textContent = c.ack ? 'Sudah dibaca ' + rcDisplayDate(c.ack, true) : 'Detail disc';
                    document.getElementById('dakCounter').textContent = 'v' + c.versi;
                    document.getElementById('dakBar').style.width = '100%';
                    setHiddenSafely('dakAckBtn', true); setHiddenSafely('dakNantiBtn', false);
                    document.getElementById('dakNantiBtn').textContent = 'Tutup';
                    document.getElementById('dakFooterText').textContent = c.ack ? 'Kartu ini sudah Anda acknowledge.' : 'Kartu ini hanya untuk dilihat.';
                }
                dcBukaModal();
            }
            function closeDiscAckModal(paksa) {
                if (!paksa && rcDc.mode !== 'lihat' && rcDc.data && rcDc.data.wajibAckDulu && !dcIsSd() && dcBelum().length) {
                    showNotification('Selesaikan acknowledge semua disc baru lebih dulu.', 'warning'); return;
                }
                setHiddenSafely('discountAckModal', true);
                dcPerbaruiBadge(); dcSegarkanTab();
            }
            async function ackDiscCard() {
                const c = rcDc.antre[rcDc.qIdx]; if (!c) return;
                const btn = document.getElementById('dakAckBtn'); btn.disabled = true;
                try { await dcKirimAck([c]); }
                catch (e) { btn.disabled = false; showNotification(e.message, 'error'); return; }
                rcDc.qIdx++;
                if (rcDc.qIdx < rcDc.antre.length) { dcTampilAntrean(); showNotification('Tercatat: ' + c.produk + ' (versi ' + c.versi + ').', 'success'); }
                else { closeDiscAckModal(true); showNotification('Semua disc baru sudah Anda baca. Terima kasih.', 'success'); }
                dcPerbaruiBadge();
            }

            // Setelah login (atau pulih sesi): muat kartu diam-diam; antrean acknowledge terbuka
            // otomatis untuk pemegang tab Acknowledge. System Manager tidak wajib (spesifikasi
            // bagian 8), jadi baginya hanya badge.
            async function dcCekAntreanLogin() {
                if (!currentUserData || !(rcCanTab('discount.dashboard') || rcCanTab('discount.ack'))) return;
                const r = await dcMuatDashboard(true, true);
                if (!r || !r.bolehAck) return;
                if (String(currentUserData.sysRole || currentUserData.role || '').toLowerCase() === 'system manager') return;
                if (dcBelum().length) openDiscAckQueue();
            }
            (function () {
                const asli = applySession;
                applySession = function (res) { rcDc.data = null; rcDc.kartu = []; rcDc.konfig = null; asli(res); setTimeout(dcCekAntreanLogin, 400); };
            })();

            // ---------- Monitoring ----------
            async function dcMuatMonitor() {
                const sel = document.getElementById('dcMonPeriode');
                showLoadingOverlay('Memuat monitoring acknowledge...');
                try {
                    const r = await fetchApp({ action: 'discMonitor', periode: sel.value || null });
                    if (r.status !== 'success') throw new Error(r.message || 'Monitoring gagal dimuat');
                    rcDc.mon = r;
                    sel.innerHTML = (r.periodes || []).map(p => '<option value="' + p + '">' + dcPerLabel(p) + '</option>').join('') || '<option value="">Belum ada kartu terbit</option>';
                    sel.value = r.periode || '';
                    const reg = document.getElementById('dcMonRegion'), lama = reg.value;
                    const regions = [...new Set((r.depot || []).map(d => d.region).filter(Boolean))].sort();
                    reg.innerHTML = '<option value="">Semua Region</option>' + regions.map(x => '<option value="' + rcEsc(x) + '">Region ' + rcEsc(x) + '</option>').join('');
                    reg.value = regions.includes(lama) ? lama : '';
                    dcRenderMonitor();
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
            }
            function dcBar(p) {
                const warna = p >= 100 ? 'bg-emerald-500' : p >= 50 ? 'bg-amber-500' : 'bg-red-500';
                return '<div class="flex items-center gap-2"><div class="flex-1 h-2 bg-gray-100 rounded-full overflow-hidden"><div class="h-full ' + warna + ' rounded-full" style="width:' + p + '%"></div></div><span class="text-xs font-bold text-gray-700 w-10 text-right">' + p + '%</span></div>';
            }
            function dcRenderMonitor() {
                const r = rcDc.mon; if (!r) return;
                const region = document.getElementById('dcMonRegion').value, q = document.getElementById('dcMonSearch').value.trim().toLowerCase();
                const g = r.ringkas || {};
                document.getElementById('dcMonKartu').textContent = g.kartu || 0;
                document.getElementById('dcMonUser').textContent = g.user || 0;
                document.getElementById('dcMonSudah').textContent = (g.sudah || 0) + ' (' + (g.wajib ? Math.round(g.sudah / g.wajib * 100) : 0) + '%)';
                document.getElementById('dcMonBelum').textContent = (g.wajib || 0) - (g.sudah || 0);
                const dep = (r.depot || []).filter(d => (!region || d.region === region) && (!q || (d.kode + ' ' + d.nama).toLowerCase().includes(q)));
                document.getElementById('dcMonDepotBody').innerHTML = dep.map(d => {
                    const p = d.wajib ? Math.round(d.sudah / d.wajib * 100) : 100;
                    return '<tr class="border-b border-gray-100 hover:bg-rose-50/30"><td class="p-3 font-black text-gray-800">' + rcEsc(d.kode) + '</td><td class="p-3 text-gray-700">' + rcEsc(d.nama) + '</td>'
                        + '<td class="p-3 text-center text-xs">' + rcEsc(d.region || '-') + '</td><td class="p-3 text-center">' + d.user + '</td><td class="p-3 text-center">' + d.wajib + '</td>'
                        + '<td class="p-3 text-center text-emerald-700 font-bold">' + d.sudah + '</td><td class="p-3 text-center text-red-700 font-bold">' + (d.wajib - d.sudah) + '</td><td class="p-3">' + dcBar(p) + '</td></tr>';
                }).join('') || '<tr><td colspan="8" class="p-8 text-center text-gray-500">Tidak ada depot.</td></tr>';
                const kartu = (r.kartu || []).filter(c => !q || (c.produk + ' ' + c.kode + ' ' + c.remark).toLowerCase().includes(q));
                document.getElementById('dcMonKartuBody').innerHTML = kartu.map(c => {
                    const p = c.wajib ? Math.round(c.sudah / c.wajib * 100) : 100, w = c.wilayah || [];
                    return '<tr class="border-b border-gray-100 hover:bg-rose-50/30"><td class="p-3"><p class="font-bold text-gray-800">' + rcEsc(c.produk) + '</p><p class="text-[11px] text-gray-500">' + rcEsc(c.kode) + ' · ' + rcEsc(c.remark) + '</p></td>'
                        + '<td class="p-3 text-center font-bold">v' + c.versi + '</td><td class="p-3 text-xs text-gray-600">' + rcEsc(w.length > 3 ? w.slice(0, 2).join(', ') + ' +' + (w.length - 2) : w.join(', ')) + '</td>'
                        + '<td class="p-3 text-center">' + c.wajib + '</td><td class="p-3 text-center text-emerald-700 font-bold">' + c.sudah + '</td><td class="p-3 text-center text-red-700 font-bold">' + (c.wajib - c.sudah) + '</td>'
                        + '<td class="p-3">' + dcBar(p) + '</td><td class="p-3 text-center">' + (c.wajib > c.sudah ? '<button onclick="dcLihatBelum(\'' + c.id + '\')" class="px-3 py-1.5 bg-white border border-gray-300 hover:bg-rose-50 text-rose-700 font-bold rounded-lg text-xs whitespace-nowrap">Yang Belum</button>' : '-') + '</td></tr>';
                }).join('') || '<tr><td colspan="8" class="p-8 text-center text-gray-500">Tidak ada kartu terbit pada periode ini.</td></tr>';
            }
            function dcLihatBelum(id) {
                const r = rcDc.mon, c = (r.kartu || []).find(x => x.id === id), rows = (r.belum || []).filter(x => x.kartuId === id);
                rcDialog('Belum acknowledge: ' + (c ? c.produk : ''), '<table class="w-full text-sm"><thead class="bg-gray-50"><tr><th class="p-2 text-left">User ID</th><th class="p-2 text-left">Nama</th><th class="p-2 text-left">Peran</th><th class="p-2 text-left">Depot</th></tr></thead><tbody>'
                    + rows.map(x => '<tr class="border-b"><td class="p-2 font-mono">' + rcEsc(x.userCode) + '</td><td class="p-2">' + rcEsc(x.nama) + '</td><td class="p-2">' + rcEsc(x.role) + '</td><td class="p-2">' + rcEsc(x.depot || '-') + '</td></tr>').join('')
                    + '</tbody></table>' + (rows.length >= 5000 ? '<p class="text-xs text-gray-500 mt-2">Daftar dibatasi 5.000 baris.</p>' : ''));
            }
            function dcUnduhBelumAck() {
                const r = rcDc.mon;
                if (!r || !(r.belum || []).length) { showNotification('Tidak ada yang belum acknowledge.', 'info'); return; }
                const aoa = [['Periode', 'User ID', 'Nama', 'Peran', 'Depot', 'Produk', 'MG / Material', 'Kemasan', 'Remark', 'Versi', 'Diterbitkan']]
                    .concat(r.belum.map(x => [dcPerLabel(r.periode), x.userCode, x.nama, x.role, x.depot || '-', x.produk, x.kode, x.kemasan || '-', x.remark, 'v' + x.versi, rcDisplayDate(x.terbit)]));
                const wb = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb, dcSheetTeks(aoa), 'Belum Acknowledge');
                XLSX.writeFile(wb, 'Disc_Belum_Acknowledge_' + (r.periode || '') + '.xlsx');
            }

            // ---------- Kebijakan: daftar, template, unggah ----------
            const DC_HEADER = {
                KEBIJAKAN: ['PERIODE', 'JENIS', 'NO_MEMO', 'MG', 'MATERIAL', 'MG1', 'MG2', 'MG3', 'SCALE_QTY', 'SCALE_UOM', 'DISC', 'VALID_FROM', 'VALID_TO', 'WILAYAH', 'UNTUK_TARGET', 'CATATAN'],
                MASTER_MG: ['MG', 'NAMA_PRODUK', 'ALIAS', 'SEGMEN', 'JENIS_PRODUK', 'UOM_SCALE', 'LEVEL_WAJIB', 'AKTIF'],
                MASTER_MATERIAL: ['MATERIAL', 'DESKRIPSI', 'MG', 'MG1', 'MG2', 'MG3', 'AKTIF'],
                TARGET: ['TARGET_ID', 'TIPE', 'KODE', 'CUST_GROUP', 'NAMA', 'DC', 'GRUP', 'ATURAN_DISC', 'LABEL_OUTPUT', 'AKTIF'],
                ATURAN_CT: ['CONDITION_TYPE', 'KEGUNAAN', 'TIPE_TARGET', 'LEVEL_BOLEH', 'MODE_HITUNG', 'KOMPONEN', 'UOM_SCALE', 'KOLOM_SATUAN', 'DISC_TYPE_LABEL', 'BATAS_AMOUNT', 'AKTIF'],
                PENGECUALIAN: ['JENIS', 'MG', 'MATERIAL', 'CONDITION_TYPE', 'TARGET', 'NILAI', 'PERIODE', 'CATATAN']
            };
            // Urutan proses: master dulu, supaya KEBIJAKAN mengenali MG / target baru di berkas yang sama.
            const DC_SHEET_URUT = ['MASTER_MG', 'MASTER_MATERIAL', 'TARGET', 'ATURAN_CT', 'PENGECUALIAN', 'KEBIJAKAN'];
            const DC_SHEET_GANTI = ['PENGECUALIAN', 'KEBIJAKAN'];
            const DC_KOLOM = {
                KEBIJAKAN: [['jenis', 'Jenis'], ['mg', 'MG'], ['produk', 'Produk'], ['kemasan', 'Material / Kemasan'], ['scale', 'Scale'], ['disc', 'Disc'], ['berlaku', 'Berlaku'],
                    ['wilayah', 'Wilayah'], ['untuk', 'Untuk Target'], ['memo', 'No Memo'], ['catatan', 'Catatan'], ['cek', 'Validasi']],
                MASTER_MG: [['mg', 'MG'], ['nama', 'Nama Produk'], ['alias', 'Alias'], ['segmen', 'Segmen'], ['jenis', 'Jenis Produk'], ['uom', 'UOM Scale'], ['level', 'Level Wajib'], ['aktif', 'Aktif']],
                MASTER_MATERIAL: [['material', 'Material'], ['deskripsi', 'Deskripsi'], ['mg', 'MG'], ['mg1', 'MG1'], ['mg2', 'MG2'], ['mg3', 'MG3'], ['aktif', 'Aktif']],
                TARGET: [['targetId', 'Target ID'], ['tipe', 'Tipe'], ['kode', 'Kode'], ['custGroup', 'Cust Group'], ['nama', 'Nama'], ['dc', 'DC'], ['grup', 'Grup'],
                    ['aturan', 'Aturan Disc'], ['label', 'Label Output'], ['aktif', 'Aktif']],
                ATURAN_CT: [['ct', 'Condition Type'], ['kegunaan', 'Kegunaan'], ['tipeTarget', 'Tipe Target'], ['levelBoleh', 'Level Boleh'], ['mode', 'Mode Hitung'],
                    ['komponen', 'Komponen'], ['uom', 'UOM Scale'], ['kolomSatuan', 'Kolom Satuan'], ['label', 'Disc Type Label'], ['batas', 'Batas Amount'], ['aktif', 'Aktif']],
                PENGECUALIAN: [['jenis', 'Jenis'], ['mg', 'MG'], ['material', 'Material'], ['ct', 'Condition Type'], ['target', 'Target'], ['nilai', 'Nilai'], ['periode', 'Periode'], ['catatan', 'Catatan']]
            };
            // Baris server -> baris template (untuk Unduh, supaya bisa diubah lalu diunggah ulang).
            const DC_KE_TEMPLATE = {
                KEBIJAKAN: r => [r.periode, r.jenis, r.memo, r.mg, r.material, r.mg1, r.mg2, r.mg3, r.qty == null ? '' : dcAngkaTitik(r.qty), r.uomScale, dcAngkaTitik(r.disc),
                    dcTglTitik(r.dari), dcTglTitik(r.sampai), r.wilayah, r.untukRaw, r.catatan],
                MASTER_MG: r => [r.mg, r.nama, r.alias, r.segmen, r.jenis, r.uom, r.level, r.aktif ? 'Y' : 'N'],
                MASTER_MATERIAL: r => [r.material, r.deskripsi, r.mg, r.mg1, r.mg2, r.mg3, r.aktif ? 'Y' : 'N'],
                TARGET: r => [r.targetId, r.tipe, r.kode, r.custGroup, r.nama, r.dc, r.grup, r.aturan, r.label, r.aktif ? 'Y' : 'N'],
                ATURAN_CT: r => [r.ct, r.kegunaan, String(r.tipeTarget || '').replace(/, /g, ','), String(r.levelBoleh || '').replace(/, /g, ','), r.mode === '-' ? '' : r.mode,
                    String(r.komponen || '').replace(/, /g, ','), r.uom, r.kolomSatuan, r.label, r.batas == null ? '' : dcAngkaTitik(r.batas), r.aktif ? 'Y' : 'N'],
                PENGECUALIAN: r => [r.jenis, r.mg, r.material, r.ct, r.target, r.nilai, r.periode, r.catatan]
            };
            function dcAngkaTitik(v) { return v === null || v === undefined || v === '' ? '' : String(Number(v)); }
            function dcTglTitik(iso) { const m = String(iso || '').match(/^(\d{4})-(\d{2})-(\d{2})/); return m ? m[3] + '.' + m[2] + '.' + m[1] : ''; }

            async function dcMuatKonfig(paksa) {
                if (rcDc.konfig && !paksa) return rcDc.konfig;
                const r = await fetchApp({ action: 'discKonfigurasi' });
                if (r.status !== 'success') throw new Error(r.message || 'Konfigurasi Discount Center gagal dimuat');
                rcDc.konfig = r; return r;
            }
            async function dcBukaKebijakan() {
                dcKbGantiSheet(true);
            }
            function dcKbGantiSheet(awal) {
                const sheet = document.getElementById('dcKbSheet').value;
                setHiddenSafely('dcKbPeriode', sheet !== 'KEBIJAKAN');
                document.getElementById('dcKbHead').innerHTML = '<tr>' + DC_KOLOM[sheet].map(([, h]) => '<th class="p-3 text-left font-bold whitespace-nowrap">' + rcEsc(h) + '</th>').join('') + '</tr>';
                dcRenderKebijakan(0, awal === true);
            }
            async function dcRenderKebijakan(offset) {
                const sheet = document.getElementById('dcKbSheet').value, selPer = document.getElementById('dcKbPeriode');
                showLoadingOverlay('Memuat ' + sheet + '...');
                try {
                    const r = await fetchApp({ action: 'discData', sheet: sheet, periode: sheet === 'KEBIJAKAN' ? (selPer.value || null) : null,
                        cari: document.getElementById('dcKbSearch').value.trim(), offset: offset || 0 });
                    if (r.status !== 'success') throw new Error(r.message || 'Data gagal dimuat');
                    const per = r.periodes || [], lama = selPer.value;
                    selPer.innerHTML = '<option value="">Semua Periode</option>' + per.map(p => '<option value="' + p + '">' + dcPerLabel(p) + '</option>').join('');
                    selPer.value = per.includes(lama) ? lama : '';
                    rcDc.kb = { sheet: sheet, offset: r.offset || 0, total: r.total || 0, rows: r.rows || [] };
                    const jenisKelas = { VOL: 'bg-blue-100 text-blue-700', CMP: 'bg-purple-100 text-purple-700', BULK: 'bg-teal-100 text-teal-700', BP: 'bg-amber-100 text-amber-800', PROMO: 'bg-rose-100 text-rose-700', FAKTUR: 'bg-gray-200 text-gray-700', LAIN: 'bg-gray-100 text-gray-700' };
                    const cekKelas = { OK: 'bg-emerald-100 text-emerald-700', CEK_UOM: 'bg-orange-100 text-orange-700', ERROR_MG: 'bg-red-100 text-red-700' };
                    const sel = (r2, k) => {
                        const v = r2[k];
                        if (sheet === 'KEBIJAKAN' && k === 'jenis') return '<span class="' + (jenisKelas[v] || '') + ' px-2 py-1 rounded text-[10px] font-black uppercase">' + rcEsc(v) + '</span>';
                        if (sheet === 'KEBIJAKAN' && k === 'cek') return '<span class="' + (cekKelas[v] || '') + ' px-2 py-1 rounded text-[10px] font-black uppercase whitespace-nowrap">' + rcEsc(String(v).replace('_', ' ')) + '</span>'
                            + (r2.ket ? '<p class="text-[10px] text-gray-500 mt-1">' + rcEsc(r2.ket) + '</p>' : '');
                        if (sheet === 'KEBIJAKAN' && k === 'disc') return '<b>' + dcPct(v) + '</b>';
                        if (sheet === 'KEBIJAKAN' && k === 'berlaku') return '<span class="whitespace-nowrap">' + rcEsc(dcBerlaku(r2.dari, r2.sampai)) + '</span>';
                        if (k === 'aktif') return v ? '<span class="text-emerald-700 font-bold">Y</span>' : '<span class="text-red-600 font-bold">N</span>';
                        if (k === 'batas') return v == null ? '-' : dcAngka(v);
                        return rcEsc(v === null || v === undefined || v === '' ? '-' : v);
                    };
                    document.getElementById('dcKbBody').innerHTML = rcDc.kb.rows.map(x => '<tr class="border-b border-gray-100 hover:bg-rose-50/30">'
                        + DC_KOLOM[sheet].map(([k]) => '<td class="p-3 text-xs ' + (['mg', 'material', 'targetId', 'kode', 'ct'].includes(k) ? 'font-mono font-bold text-gray-800' : 'text-gray-700') + '">' + sel(x, k) + '</td>').join('') + '</tr>').join('')
                        || '<tr><td colspan="' + DC_KOLOM[sheet].length + '" class="p-8 text-center text-gray-500">Belum ada data. Unduh Template, isi, lalu Pilih File.</td></tr>';
                    const dari = rcDc.kb.total ? rcDc.kb.offset + 1 : 0, sampai = rcDc.kb.offset + rcDc.kb.rows.length;
                    document.getElementById('dcKbPager').innerHTML = '<div class="flex justify-between items-center text-xs text-gray-600 bg-white p-3 border rounded-xl"><span>Menampilkan <b>' + dari + '</b> - <b>' + sampai + '</b> dari <b>' + rcDc.kb.total.toLocaleString('id-ID') + '</b></span>'
                        + '<span class="flex gap-2"><button ' + (rcDc.kb.offset > 0 ? '' : 'disabled') + ' onclick="dcRenderKebijakan(' + Math.max(0, rcDc.kb.offset - 200) + ')" class="px-3 py-1.5 bg-white border rounded-lg disabled:opacity-40">Sebelumnya</button>'
                        + '<button ' + (sampai < rcDc.kb.total ? '' : 'disabled') + ' onclick="dcRenderKebijakan(' + sampai + ')" class="px-3 py-1.5 bg-white border rounded-lg disabled:opacity-40">Berikutnya</button></span></div>';
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // Template input: header persis spesifikasi bagian 3, baris contoh, semua sel teks.
            function downloadDiscTemplate() {
                const wb = XLSX.utils.book_new();
                const add = (nama, contoh) => XLSX.utils.book_append_sheet(wb, dcSheetTeks([DC_HEADER[nama]].concat(contoh)), nama);
                add('KEBIJAKAN', [['2026-10', 'VOL', 'Memo Vol Okt', 'FERT022', '', '', '', '', '12', 'KG', '5', '01.10.2026', '31.10.2026', 'NASIONAL', '', ''],
                    ['2026-10', 'VOL', 'Memo Vol Okt', 'FERT022', '', '', '', '', '30', 'KG', '7', '01.10.2026', '31.10.2026', 'NASIONAL', '', ''],
                    ['2026-10', 'CMP', 'Memo Campaign Okt', 'FERT022', '', '', '', '', '', '', '5', '01.10.2026', '31.10.2026', 'NASIONAL', '', ''],
                    ['2026-10', 'PROMO', '288/TUD/JT/VIII/2026', 'HAWA102', '', '', '', '', '', '', '20', '21.10.2026', '31.12.2026', 'NASIONAL', 'TOKO_KHUSUS', 'Promo tanpa min qty']]);
                add('MASTER_MG', [['FERT022', 'Copper Paint Anti-Fouling', 'Copper Paint A/F', 'LAIN-LAIN', 'READY MIX', 'KG', 'MG', 'Y'],
                    ['FERT247', 'Pylox', '', 'CAT SEMPROT', 'READY MIX', 'PC', 'KEMASAN', 'Y']]);
                add('MASTER_MATERIAL', [['3244EXPUTIHSK', '4.5K-VPRO-PUTIH SUPER KENTAL', 'FERT300', '', '', '', 'Y']]);
                add('TARGET', [['TK-655583', 'CUSTOMER', '655583', '', 'PT. GAVINDO MITRA PERKASA', '1A', 'TOKO_KHUSUS', 'OPEN_QTY_TANPA_BULK', 'Toko Khusus', 'Y'],
                    ['SO-1100-05', 'SLS_ORG', '1100,1400', '05', 'Sls Org 1100,1400 CG 05', '', '', 'NORMAL', '', 'Y']]);
                add('ATURAN_CT', [['RA08', 'Disc volume per tier, satuan KG', 'SLS_OFFICE', 'SLSOFF_CG_MG', 'PER_SCALE', 'VOL,CMP,BULK', 'KG', 'UOM', 'Disc Vol + Disc CMP + Disc Bulk', '', 'Y']]);
                add('PENGECUALIAN', [['UOM_OVERRIDE', 'FERT479', '', 'RA09', '', 'L', '2026-10', 'Memo vol dalam L, BD Okt tertulis Kg']]);
                XLSX.writeFile(wb, 'Template_Input_Disc.xlsx');
                showNotification('Template_Input_Disc.xlsx diunduh. Hapus baris contoh sebelum mengisi.', 'success');
            }

            // Unduh isi sheet yang sedang dibuka dalam format template (bisa diubah lalu diunggah ulang).
            async function dcUnduhSheet() {
                const sheet = document.getElementById('dcKbSheet').value, per = sheet === 'KEBIJAKAN' ? (document.getElementById('dcKbPeriode').value || null) : null;
                const cari = document.getElementById('dcKbSearch').value.trim();
                showLoadingOverlay('Mengunduh ' + sheet + '...');
                try {
                    let semua = [], offset = 0, total = 1;
                    while (offset < total && semua.length < 50000) {
                        const r = await fetchApp({ action: 'discData', sheet: sheet, periode: per, cari: cari, offset: offset });
                        if (r.status !== 'success') throw new Error(r.message || 'Data gagal dimuat');
                        semua = semua.concat(r.rows || []); total = r.total || 0;
                        if (!(r.rows || []).length || sheet === 'ATURAN_CT' || sheet === 'PENGECUALIAN') break;
                        offset += r.rows.length;
                    }
                    if (!semua.length) { showNotification('Tidak ada data untuk diunduh.', 'info'); return; }
                    const wb = XLSX.utils.book_new();
                    XLSX.utils.book_append_sheet(wb, dcSheetTeks([DC_HEADER[sheet]].concat(semua.map(DC_KE_TEMPLATE[sheet]))), sheet);
                    XLSX.writeFile(wb, 'Disc_' + sheet + (per ? '_' + per : '') + '.xlsx');
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // Sel tanggal yang terlanjur diformat tanggal oleh Excel (angka seri) ditulis ulang dd.mm.yyyy;
            // PERIODE yang jadi tanggal ditulis ulang YYYY-MM.
            function dcSelTeks(nama, v) {
                if (typeof v === 'number' && ['VALID_FROM', 'VALID_TO', 'PERIODE'].includes(nama) && v > 20000 && v < 80000) {
                    const d = new Date(Math.round((v - 25569) * 86400000));
                    const dd = String(d.getUTCDate()).padStart(2, '0'), mm = String(d.getUTCMonth() + 1).padStart(2, '0'), yy = d.getUTCFullYear();
                    return nama === 'PERIODE' ? yy + '-' + mm : dd + '.' + mm + '.' + yy;
                }
                return rcCellText(v);
            }
            function previewDiscUpload(input) {
                const f = input.files && input.files[0]; if (!f) return;
                if (f.size > 20 * 1024 * 1024) { showNotification('File maksimal 20 MB.', 'error'); input.value = ''; return; }
                const reader = new FileReader();
                reader.onload = async function (e) {
                    try {
                        const wb = XLSX.read(new Uint8Array(e.target.result), { type: 'array', cellDates: false });
                        const data = {};
                        wb.SheetNames.forEach(n => {
                            const nama = String(n).trim().toUpperCase().replace(/\s+/g, '_');
                            if (!DC_HEADER[nama]) return;
                            const rows = XLSX.utils.sheet_to_json(wb.Sheets[n], { header: 1, raw: true, defval: '' });
                            const hIdx = rows.findIndex(r => (r || []).some(c => String(c).trim().toUpperCase() === DC_HEADER[nama][0]));
                            if (hIdx < 0) return;
                            const peta = {};
                            rows[hIdx].forEach((h, i) => { const k = String(h || '').trim().toUpperCase().replace(/\s+/g, '_'); if (DC_HEADER[nama].includes(k)) peta[k] = i; });
                            const out = [];
                            for (let i = hIdx + 1; i < rows.length; i++) {
                                const raw = rows[i] || [], obj = { __BARIS: i + 1 }; let isi = false;
                                DC_HEADER[nama].forEach(k => { const v = peta[k] === undefined ? '' : dcSelTeks(k, raw[peta[k]]); obj[k] = v; if (v !== '') isi = true; });
                                if (isi) out.push(obj);
                            }
                            data[nama] = out;
                        });
                        const sheets = DC_SHEET_URUT.filter(s => (data[s] || []).length);
                        if (!sheets.length) { showNotification('Tidak ada sheet yang dikenali (KEBIJAKAN, MASTER_MG, MASTER_MATERIAL, TARGET, ATURAN_CT, PENGECUALIAN).', 'error'); input.value = ''; return; }
                        for (const s of DC_SHEET_GANTI) if ((data[s] || []).length > 5000) { showNotification('Sheet ' + s + ' maksimal 5.000 baris per unggahan.', 'error'); input.value = ''; return; }
                        rcDc.unggah = { nama: f.name, data: data, sheets: sheets, konteks: dcKonteksUnggah(data) };
                        await dcJalankanUnggah(false);
                    } catch (err) { showNotification(err.message || 'File tidak bisa dibaca.', 'error'); input.value = ''; }
                };
                reader.readAsArrayBuffer(f);
            }
            function dcKonteksUnggah(data) {
                const k = { mg: {}, material: {}, target: [], grup: [] };
                (data.MASTER_MG || []).forEach(r => { const mg = String(r.MG || '').trim().toUpperCase(); if (mg) k.mg[mg] = { uom: String(r.UOM_SCALE || '').trim().toUpperCase(), level: String(r.LEVEL_WAJIB || '').trim().toUpperCase() }; });
                (data.MASTER_MATERIAL || []).forEach(r => { const m = String(r.MATERIAL || '').trim().toUpperCase(); if (m) k.material[m] = String(r.MG || '').trim().toUpperCase(); });
                (data.TARGET || []).forEach(r => { const t = String(r.TARGET_ID || '').trim().toUpperCase(), g = String(r.GRUP || '').trim().toUpperCase(); if (t) k.target.push(t); if (g && !k.grup.includes(g)) k.grup.push(g); });
                return k;
            }
            // Pratinjau (simpan = false) dan simpan memakai jalur yang sama; master dipecah per 2.000 baris.
            async function dcJalankanUnggah(simpan) {
                const u = rcDc.unggah; if (!u) return;
                showLoadingOverlay(simpan ? 'Menyimpan kebijakan...' : 'Memeriksa berkas...');
                const hasil = [];
                try {
                    for (const s of u.sheets) {
                        const rows = u.data[s], potong = DC_SHEET_GANTI.includes(s) ? rows.length : 2000;
                        const h = { sheet: s, total: rows.length, ok: 0, cek: 0, error: 0, pesan: [] };
                        for (let i = 0; i < rows.length; i += potong) {
                            const r = await fetchApp({ action: 'discUnggah', sheet: s, rows: rows.slice(i, i + potong), konteks: u.konteks, simpan: simpan });
                            if (r.status !== 'success') throw new Error(s + ': ' + (r.message || 'gagal diproses'));
                            h.ok += r.ok; h.cek += r.cek; h.error += r.error; h.pesan = h.pesan.concat(r.pesan || []);
                        }
                        hasil.push(h);
                    }
                } catch (e) { hideLoadingOverlay(); showNotification(e.message, 'error'); if (simpan) dcRenderKebijakan(0); return; }
                hideLoadingOverlay();
                const jml = k => hasil.reduce((a, h) => a + h[k], 0);
                if (simpan) {
                    cancelDiscUpload();
                    rcDc.konfig = null; rcDc.data = null;
                    showNotification('Tersimpan ' + (jml('ok') + jml('cek')) + ' baris (' + hasil.map(h => h.sheet + ' ' + (h.ok + h.cek)).join(', ') + ')'
                        + (jml('error') ? '; ' + jml('error') + ' baris error tidak disimpan.' : '.'), jml('error') ? 'warning' : 'success');
                    dcRenderKebijakan(0);
                    return;
                }
                document.getElementById('dcKbUploadText').textContent = u.nama + ' · ' + hasil.map(h => h.sheet + ' ' + h.total + ' baris').join(' · ');
                document.getElementById('dcKbValid').textContent = jml('ok');
                document.getElementById('dcKbCek').textContent = jml('cek');
                document.getElementById('dcKbError').textContent = jml('error');
                const pesan = hasil.flatMap(h => h.pesan.map(p => Object.assign({ sheet: h.sheet }, p)));
                document.getElementById('dcKbPesan').innerHTML = pesan.length ? '<table class="w-full"><tbody>' + pesan.slice(0, 500).map(p => '<tr class="border-b border-blue-50">'
                    + '<td class="p-1.5 font-bold whitespace-nowrap">' + rcEsc(p.sheet) + '</td><td class="p-1.5 whitespace-nowrap">baris ' + p.baris + '</td>'
                    + '<td class="p-1.5"><span class="' + (p.status === 'ERROR' ? 'bg-red-100 text-red-700' : 'bg-orange-100 text-orange-700') + ' px-1.5 py-0.5 rounded text-[10px] font-black">' + p.status + '</span></td>'
                    + '<td class="p-1.5">' + rcEsc(p.pesan) + '</td></tr>').join('') + '</tbody></table>'
                    + (pesan.length > 500 ? '<p class="p-2 text-gray-500">' + (pesan.length - 500) + ' pesan lain tidak ditampilkan.</p>' : '')
                    : '<p class="p-2 text-emerald-700 font-bold">Semua baris valid.</p>';
                document.getElementById('btnCommitDisc').disabled = jml('ok') + jml('cek') === 0;
                setHiddenSafely('dcKbUploadInfo', false);
            }
            async function commitDiscUpload() {
                const u = rcDc.unggah; if (!u) return;
                const ganti = u.sheets.filter(s => DC_SHEET_GANTI.includes(s));
                const per = [...new Set((u.data.KEBIJAKAN || []).map(r => r.PERIODE).filter(Boolean))];
                const ok = await showConfirmModal({ title: 'Simpan Kebijakan', danger: ganti.length > 0, confirmText: 'Ya, Simpan',
                    message: 'Baris valid dan baris "perlu cek" disimpan; baris error tidak disimpan.'
                        + (u.sheets.includes('KEBIJAKAN') ? ' KEBIJAKAN periode ' + per.join(', ') + ' yang sekarang diarsipkan dan diganti isi berkas ini.' : '')
                        + (u.sheets.includes('PENGECUALIAN') ? ' Seluruh PENGECUALIAN diganti isi berkas ini (yang lama diarsipkan).' : '')
                        + ' Master (MG, Material, Target, Aturan CT) ditambah atau diperbarui per kode.' });
                if (ok) dcJalankanUnggah(true);
            }
            function cancelDiscUpload() { setHiddenSafely('dcKbUploadInfo', true); document.getElementById('dcKbFile').value = ''; rcDc.unggah = null; }

            // ---------- Generate ----------
            const DC_TIPE_LABEL = { CUSTOMER: 'Customer', SLS_OFFICE: 'Sales Office', SLS_ORG: 'Sales Org', COND_GROUP2: 'Cond Group 2' };
            async function dcBukaGenerate() {
                showLoadingOverlay('Memuat konfigurasi...');
                try {
                    const k = await dcMuatKonfig(true);
                    const per = document.getElementById('dcGenPeriode'), lama = per.value;
                    per.innerHTML = (k.periodes || []).map(p => '<option value="' + p + '">' + dcPerLabel(p) + '</option>').join('') || '<option value="">Belum ada kebijakan</option>';
                    if ((k.periodes || []).includes(lama)) per.value = lama;
                    const ct = document.getElementById('dcGenCt'), ctLama = ct.value;
                    ct.innerHTML = (k.aturan || []).map(a => '<option value="' + rcEsc(a.ct) + '">' + rcEsc(a.ct) + (a.aktif ? '' : ' (belum aktif)') + '</option>').join('');
                    if ((k.aturan || []).some(a => a.ct === ctLama)) ct.value = ctLama;
                    dcGenInfoCt();
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
            }
            function dcGenAturan() { const ct = document.getElementById('dcGenCt').value; return ((rcDc.konfig || {}).aturan || []).find(a => a.ct === ct); }
            function dcGenInfoCt() {
                const a = dcGenAturan(); if (!a) { document.getElementById('dcGenInfo').textContent = 'Belum ada ATURAN_CT.'; return; }
                const tg = (rcDc.konfig.target || []).filter(t => (a.tipeTarget || []).includes(t.tipe));
                const opsi = [];
                const grup = {};
                tg.forEach(t => { if (t.grup) (grup[t.grup] = grup[t.grup] || []).push(t); });
                Object.keys(grup).sort().forEach(g => opsi.push(['GRUP:' + g, 'Grup ' + g + ' (' + grup[g].length + ' target)']));
                (a.tipeTarget || []).forEach(tp => opsi.push(['KOSONG:' + tp, 'Semua ' + (DC_TIPE_LABEL[tp] || tp) + ' (kode & CustGrp diisi saat pantek)']));
                if (tg.length) opsi.push(['*', 'Semua target terdaftar (' + tg.length + ')']);
                tg.forEach(t => opsi.push([t.id, t.kode + ' ' + t.nama + ' · ' + t.aturan]));
                const sel = document.getElementById('dcGenTarget'), lama = sel.value;
                sel.innerHTML = opsi.map(([v, l]) => '<option value="' + rcEsc(v) + '">' + rcEsc(l) + '</option>').join('');
                if (opsi.some(([v]) => v === lama)) sel.value = lama;
                document.querySelectorAll('#dcGenKomponen input').forEach(cb => { cb.checked = (a.komponen || []).includes(cb.value); });
                document.getElementById('dcGenInfo').innerHTML = '<b>Kegunaan:</b> ' + rcEsc(a.kegunaan || '-') + ' · <b>Mode hitung:</b> ' + rcEsc(a.mode || '-')
                    + ' · <b>Level boleh:</b> ' + rcEsc((a.levelBoleh || []).join(', ') || '-') + ' · <b>Satuan scale:</b> ' + rcEsc(a.uom || '-') + ' (kolom ' + rcEsc(a.kolomSatuan) + ')'
                    + (a.batas != null ? ' · <b>Batas Amount:</b> ' + dcAngka(a.batas) : '')
                    + (a.aktif ? '' : '<br><span class="text-red-600 font-bold">Aturan ' + rcEsc(a.ct) + ' belum lengkap (MODE_HITUNG kosong atau tidak aktif), jadi generate belum bisa dijalankan.</span>');
                dcGenReset();
            }
            function dcGenReset() { rcDc.gen = null; setHiddenSafely('dcGenHasil', true); document.getElementById('btnDcDownloadPantek').disabled = true; }
            function dcGenParam() {
                return { periode: document.getElementById('dcGenPeriode').value, ct: document.getElementById('dcGenCt').value,
                    targets: [document.getElementById('dcGenTarget').value].filter(Boolean),
                    komponen: [...document.querySelectorAll('#dcGenKomponen input:checked')].map(x => x.value),
                    perGrup: (document.querySelector('input[name="dcGenMode"]:checked') || {}).value !== 'customer',
                    sumber: (document.querySelector('input[name="dcGenSumber"]:checked') || {}).value || 'SEMUA' };
            }
            async function dcPanggilGenerate(p, catat) {
                const r = await fetchApp(Object.assign({ action: 'discGenerate', catat: !!catat }, p));
                if (r.status !== 'success') throw new Error(r.message || 'Generate gagal.');
                return r;
            }
            async function dcHitungPratinjau() {
                const p = dcGenParam();
                if (!p.periode) { showNotification('Belum ada kebijakan untuk di-generate.', 'warning'); return; }
                if (!p.komponen.length) { showNotification('Pilih minimal satu komponen.', 'warning'); return; }
                showLoadingOverlay('Menghitung...');
                try {
                    const r = await dcPanggilGenerate(p, false);
                    rcDc.gen = r; rcDc.genParam = p; dcRenderGenerate(r);
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
            }
            function dcFlagHtml(x) {
                const kelas = f => f === 'BERUBAH' ? 'bg-red-100 text-red-700' : f === 'DOBEL' ? 'bg-red-600 text-white' : /^ERROR/.test(f) ? 'bg-gray-700 text-white' : 'bg-orange-100 text-orange-700';
                return (x.flags || []).length ? (x.flags || []).map(f => '<span class="' + kelas(f) + ' px-2 py-0.5 rounded text-[10px] font-black uppercase whitespace-nowrap inline-block mb-0.5">' + rcEsc(f) + '</span>').join(' ')
                    + (x.ket ? '<p class="text-[10px] text-gray-500 mt-1">' + rcEsc(x.ket) + '</p>' : '') : '<span class="text-gray-300">-</span>';
            }
            function dcRenderGenerate(r) {
                const g = r.ringkas || {};
                document.getElementById('dcGenBody').innerHTML = (r.rows || []).map(x => {
                    const f = x.f || {}, err = x.status === 'ERROR', dobel = (x.flags || []).includes('DOBEL'), berubah = (x.flags || []).includes('BERUBAH');
                    const latar = err ? 'bg-gray-50 text-gray-400' : dobel ? 'bg-red-50' : x.status === 'CEK' && !(x.flags.length === 1 && berubah) ? 'bg-orange-50' : 'bg-yellow-50/60';
                    const kunci = [f.MG, f.MG2, f.MG1, f.MG3, f.MATERIAL].filter(Boolean);
                    return '<tr class="border-b border-gray-100 ' + latar + '">'
                        + '<td class="p-3 text-xs font-bold whitespace-nowrap">' + rcEsc(x.sheet || '-') + '</td><td class="p-3 text-center font-black">' + rcEsc(f.CONDITION_TYPE || r.ct) + '</td>'
                        + '<td class="p-3 text-xs">' + rcEsc(f.TARGET || '(diisi saat pantek)') + (f.CUST_GROUP ? ' · CG ' + rcEsc(f.CUST_GROUP) : '') + '</td>'
                        + '<td class="p-3 font-mono text-xs">' + rcEsc(kunci.join(' · ') || x.mg || '-') + '</td><td class="p-3">' + rcEsc(f.DESCRIPTION || '-') + '</td>'
                        + '<td class="p-3 text-right font-black' + (berubah ? ' text-red-600' : '') + '"' + (x.amountLama != null ? ' title="Sebelumnya ' + rcEsc(dcAngka(x.amountLama)) + '"' : '') + '>' + rcEsc(f.AMOUNT || '-') + '</td>'
                        + '<td class="p-3 text-center whitespace-nowrap">' + (f.SCALE_QTY ? rcEsc(f.SCALE_QTY + ' ' + (x.uom || '')) : '-') + '</td>'
                        + '<td class="p-3 text-center text-xs whitespace-nowrap">' + (x.dari ? rcEsc(dcBerlaku(x.dari, x.sampai)) : '-') + '</td><td class="p-3 text-xs whitespace-nowrap">' + rcEsc(f.DISC_TYPE || '-') + '</td>'
                        + '<td class="p-3 text-xs text-gray-600">' + rcEsc(f.REMARK1 || '-') + '</td><td class="p-3 text-xs text-gray-600">' + rcEsc(f.REMARK2 || '-') + '</td>'
                        + '<td class="p-3 text-center">' + dcFlagHtml(x) + '</td></tr>';
                }).join('') || '<tr><td colspan="12" class="p-8 text-center text-gray-500">Tidak ada baris kebijakan yang berlaku untuk pilihan ini.</td></tr>';
                document.getElementById('dcGenBaris').textContent = g.baris || 0;
                document.getElementById('dcGenBerubah').textContent = g.berubah || 0;
                document.getElementById('dcGenCek').textContent = g.cek || 0;
                document.getElementById('dcGenError').textContent = g.error || 0;
                const lewat = g.dilewati || [];
                document.getElementById('dcGenLewat').textContent = lewat.length ? lewat.length + ' MG dilewati karena satuan master-nya bukan milik ' + r.ct + ': ' + lewat.join(', ') : '';
                setHiddenSafely('dcGenLewat', !lewat.length);
                setHiddenSafely('dcGenHasil', false);
                document.getElementById('btnDcDownloadPantek').disabled = !(g.baris > 0);
            }

            // Excel siap pantek: satu sheet per template tujuan, posisi kolom dari TEMPLATE_KOLOM,
            // header di baris header template. Baris baru berlatar kuning muda, BERUBAH = Amount
            // merah tebal, CEK_* = oranye, DOBEL = merah. Baris ERROR hanya di sheet LOG.
            function dcNamaSheet(s, dipakai) {
                let n = String(s || 'Sheet').replace(/[\\\/\?\*\[\]:]/g, '-').replace(/\s+/g, ' ').trim().slice(0, 31) || 'Sheet', i = 2;
                while (dipakai.has(n.toLowerCase())) n = n.slice(0, 28) + ' ' + (i++);
                dipakai.add(n.toLowerCase()); return n;
            }
            async function dcDownloadTemplatePantek() {
                const p = rcDc.genParam; if (!p || !rcDc.gen) return;
                showLoadingOverlay('Menyusun Excel template...');
                try {
                    await dcMuatSkrip(DC_EXCELJS);
                    const r = await dcPanggilGenerate(p, true);
                    rcDc.gen = r; dcRenderGenerate(r);
                    const tpl = (rcDc.konfig.template || []), wb = new window.ExcelJS.Workbook(), dipakai = new Set();
                    wb.creator = 'RC Next Gen - Discount Center';
                    const kolomKe = k => k.split('').reduce((a, ch) => a * 26 + ch.charCodeAt(0) - 64, 0);
                    const perSheet = {};
                    (r.rows || []).filter(x => x.status !== 'ERROR').forEach(x => (perSheet[x.level] = perSheet[x.level] || []).push(x));
                    const hari = rcDisplayDate(new Date().toISOString());
                    Object.keys(perSheet).forEach(level => {
                        const kol = tpl.filter(t => t.level === level), baris = perSheet[level];
                        const ws = wb.addWorksheet(dcNamaSheet(kol[0] ? kol[0].sheet : level, dipakai));
                        const hb = kol[0] ? kol[0].baris : 1;
                        if (hb > 1) ws.getCell(1, 1).value = (kol[0] ? kol[0].sheet : level) + ' · ' + r.ct + ' · periode ' + dcPerLabel(r.periode) + ' · dibuat ' + hari;
                        kol.forEach(k => {
                            const c = ws.getCell(hb, kolomKe(k.kolom)); c.value = k.header || null;
                            c.font = { bold: true }; c.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFE5E7EB' } };
                            ws.getColumn(kolomKe(k.kolom)).width = ['DESCRIPTION', 'REMARK1', 'REMARK2', 'DISC_TYPE'].includes(k.field) ? 34 : 12;
                        });
                        baris.forEach((x, i) => {
                            const ro = hb + 1 + i, fl = x.flags || [];
                            const warna = fl.includes('DOBEL') ? 'FFFFCDD2' : fl.some(f => /^CEK_/.test(f)) ? 'FFFFE0B2' : 'FFFFF9C4';
                            kol.forEach(k => {
                                const c = ws.getCell(ro, kolomKe(k.kolom));
                                const v = k.field === 'KOSONG' ? '' : (x.f || {})[k.field];
                                c.value = v === undefined || v === null || v === '' ? null : String(v);
                                c.numFmt = '@';
                                c.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: warna } };
                                if (k.field === 'AMOUNT' && fl.includes('BERUBAH')) c.font = { bold: true, color: { argb: 'FFDC2626' } };
                            });
                        });
                    });
                    const log = wb.addWorksheet(dcNamaSheet('LOG', dipakai));
                    log.addRow(['Waktu', 'Condition Type', 'Periode', 'Target', 'Baris dibuat', 'Error', 'Perlu cek', 'Berubah', 'Dobel']);
                    log.addRow([rcDisplayDate(new Date().toISOString(), true), r.ct, r.periode, p.targets.join(', '), r.ringkas.baris, r.ringkas.error, r.ringkas.cek, r.ringkas.berubah, r.ringkas.dobel]);
                    log.addRow([]);
                    log.addRow(['Status', 'Flag', 'Target', 'MG', 'Material', 'Level', 'Amount', 'Keterangan']);
                    (r.rows || []).filter(x => x.status !== 'OK').forEach(x => log.addRow([x.status, (x.flags || []).join(', '), (x.f || {}).TARGET || '', x.mg || '', x.material || '', x.level || '', (x.f || {}).AMOUNT || '', x.ket || '']));
                    log.getRow(1).font = { bold: true }; log.getRow(4).font = { bold: true };
                    const buf = await wb.xlsx.writeBuffer();
                    dcUnduhBlob(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), 'Pantek_' + r.ct + '_' + r.periode + '.xlsx');
                    showNotification('Pantek_' + r.ct + '_' + r.periode + '.xlsx diunduh (' + r.ringkas.baris + ' baris). Snapshot dicatat untuk perbandingan periode berikutnya.', 'success');
                } catch (e) { showNotification(e.message || 'Excel gagal dibuat.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            // ---------- Terbitkan ----------
            async function dcBukaTerbit() {
                showLoadingOverlay('Memuat kartu...');
                try {
                    const k = await dcMuatKonfig(true);
                    document.getElementById('dcTbWilayahMassal').innerHTML = (k.wilayah || []).map(w => '<option value="' + rcEsc(w) + '">' + rcEsc(w) + '</option>').join('');
                    const sel = document.getElementById('dcTbPeriode');
                    if (!sel.value) sel.innerHTML = (k.periodes || []).map(p => '<option value="' + p + '">' + dcPerLabel(p) + '</option>').join('') || '<option value="">Belum ada kebijakan</option>';
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
                dcRenderTerbit();
            }
            const DC_PERUBAHAN = { BARU: ['Draft baru', 'bg-gray-200 text-gray-700'], REVISI: ['Revisi menunggu', 'bg-amber-100 text-amber-800'],
                WILAYAH: ['Wilayah diubah', 'bg-sky-100 text-sky-700'], CT: ['CT diperbarui', 'bg-sky-100 text-sky-700'],
                TERBIT_ULANG: ['Terbit ulang', 'bg-amber-100 text-amber-800'], USANG: ['Tidak ada di kebijakan', 'bg-red-100 text-red-700'] };
            async function dcRenderTerbit() {
                const sel = document.getElementById('dcTbPeriode'), per = sel.value;
                if (!per) { document.getElementById('dcTbBody').innerHTML = '<tr><td colspan="9" class="p-8 text-center text-gray-500">Belum ada kebijakan. Unggah lewat tab Kebijakan.</td></tr>'; return; }
                showLoadingOverlay('Memuat kartu...');
                try {
                    const r = await fetchApp({ action: 'discTerbitList', periode: per });
                    if (r.status !== 'success') throw new Error(r.message || 'Kartu gagal dimuat');
                    const per2 = r.periodes || [];
                    sel.innerHTML = per2.map(p => '<option value="' + p + '">' + dcPerLabel(p) + '</option>').join('');
                    sel.value = per;
                    rcDc.tb = r.kartu || [];
                    const kelas = { DRAFT: 'bg-gray-200 text-gray-700', TERBIT: 'bg-emerald-100 text-emerald-700', DITARIK: 'bg-red-100 text-red-700' };
                    document.getElementById('dcTbBody').innerHTML = rcDc.tb.map(c => {
                        const ub = DC_PERUBAHAN[c.perubahan], bisa = c.status !== 'DITARIK' || !!c.perubahan;
                        return '<tr class="border-b border-gray-100 hover:bg-rose-50/30 align-top">'
                            + '<td class="p-3 text-center"><input type="checkbox" class="cb-dc-terbit w-4 h-4 rounded" value="' + c.id + '" ' + (bisa ? '' : 'disabled') + ' onchange="dcHitungTerpilih()"></td>'
                            + '<td class="p-3"><p class="font-bold text-gray-800">' + rcEsc(c.produk) + '</p><p class="text-[11px] text-gray-500">' + rcEsc(c.remark) + '</p>'
                            + (c.alasanTarik && c.status === 'DITARIK' ? '<p class="text-[11px] text-red-600">Ditarik: ' + rcEsc(c.alasanTarik) + '</p>' : '') + '</td>'
                            + '<td class="p-3 font-mono text-xs">' + rcEsc(c.kode) + '<br><span class="text-gray-400">' + rcEsc(c.kemasan || '-') + '</span></td>'
                            + '<td class="p-3 text-xs text-gray-700">' + ((c.tiers || []).map(t => rcEsc(t.syarat) + ' = <b>' + dcPct(t.total) + '</b>').join('<br>') || '-') + '</td>'
                            + '<td class="p-3 text-center font-bold">v' + c.versi + '</td>'
                            + '<td class="p-3 text-center"><span class="' + (kelas[c.status] || '') + ' px-2 py-1 rounded text-[10px] font-black uppercase">' + rcEsc(c.status) + '</span>'
                            + (ub ? '<span class="block mt-1 ' + ub[1] + ' px-2 py-0.5 rounded text-[10px] font-black whitespace-nowrap">' + ub[0] + '</span>' : '') + '</td>'
                            + '<td class="p-3"><div class="flex flex-wrap gap-1">' + (c.wilayah || []).map(w => '<span class="bg-rose-50 border border-rose-100 text-rose-700 px-1.5 py-0.5 rounded text-[10px] font-bold">' + rcEsc(w) + '</span>').join('') + '</div></td>'
                            + '<td class="p-3 text-xs text-gray-600">' + rcEsc(c.untuk || '-') + '</td>'
                            + '<td class="p-3 text-center whitespace-nowrap">'
                            + '<button onclick="dcLihatKartuTerbit(\'' + c.id + '\')" class="px-2.5 py-1.5 bg-white border border-gray-300 hover:bg-gray-50 text-gray-700 font-bold rounded-lg text-xs">Lihat</button> '
                            + (c.status !== 'DITARIK' ? '<button onclick="dcUbahWilayah(\'' + c.id + '\')" class="px-2.5 py-1.5 bg-white border border-gray-300 hover:bg-rose-50 text-rose-700 font-bold rounded-lg text-xs">Wilayah</button> ' : '')
                            + (c.status === 'TERBIT' ? '<button onclick="dcTarikKartu(\'' + c.id + '\')" class="px-2.5 py-1.5 bg-white border border-gray-300 hover:bg-red-50 text-red-700 font-bold rounded-lg text-xs">Tarik</button>' : '')
                            + '</td></tr>';
                    }).join('') || '<tr><td colspan="9" class="p-8 text-center text-gray-500">Belum ada kartu. Tekan "Buat Draft dari Kebijakan".</td></tr>';
                    const n = k => rcDc.tb.filter(c => c.perubahan === k).length;
                    document.getElementById('dcTbInfo').textContent = rcDc.tb.length + ' kartu · ' + n('BARU') + ' draft baru · ' + (n('REVISI') + n('TERBIT_ULANG')) + ' revisi menunggu · '
                        + (n('WILAYAH') + n('CT')) + ' wilayah/CT · ' + rcDc.tb.filter(c => c.status === 'TERBIT').length + ' terbit · ' + n('USANG') + ' tidak ada lagi di kebijakan (pertimbangkan Tarik)';
                    document.getElementById('cbDcTerbitAll').checked = false; dcHitungTerpilih();
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
            }
            function dcTerpilih() { return [...document.querySelectorAll('.cb-dc-terbit:checked')].map(x => x.value); }
            function dcHitungTerpilih() {
                const ids = dcTerpilih(), n = rcDc.tb.filter(c => ids.includes(c.id) && c.perubahan && c.perubahan !== 'USANG').length;
                document.getElementById('dcTbCount').textContent = n; document.getElementById('btnDcTerbit').disabled = n === 0;
            }
            function dcToggleSemuaTerbit(cb) { document.querySelectorAll('.cb-dc-terbit:not(:disabled)').forEach(x => x.checked = cb.checked); dcHitungTerpilih(); }
            async function dcBuatDraft() {
                const per = document.getElementById('dcTbPeriode').value; if (!per) return;
                showLoadingOverlay('Menyusun draft kartu...');
                try {
                    const r = await fetchApp({ action: 'discDraftBuat', periode: per });
                    if (r.status !== 'success') throw new Error(r.message || 'Draft gagal dibuat');
                    showNotification('Draft ' + dcPerLabel(per) + ': ' + r.baru + ' baru, ' + r.berubah + ' berubah, ' + r.sama + ' sama' + (r.usang ? ', ' + r.usang + ' tidak ada lagi di kebijakan' : '') + '.', 'success');
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
                dcRenderTerbit();
            }
            async function dcAturWilayahIds(ids, wilayah) {
                showLoadingOverlay('Mengubah wilayah tampil...');
                try {
                    const r = await fetchApp({ action: 'discAturWilayah', ids: ids, wilayah: wilayah });
                    if (r.status !== 'success') throw new Error(r.message || 'Wilayah gagal diubah');
                    showNotification('Wilayah ' + r.diubah + ' kartu menjadi ' + (r.wilayah || []).join(', ') + '. Terbitkan supaya berlaku.', 'success');
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
                dcRenderTerbit();
            }
            function dcAturWilayahMassal() {
                const ids = dcTerpilih(), w = document.getElementById('dcTbWilayahMassal').value;
                if (!ids.length) { showNotification('Pilih kartu dulu.', 'warning'); return; }
                dcAturWilayahIds(ids, w);
            }
            function dcUbahWilayah(id) {
                const c = rcDc.tb.find(x => x.id === id); if (!c) return;
                window.__dcWilayahSimpan = function () {
                    const v = String(document.getElementById('dcWilayahIsi').value || '').trim();
                    if (!v) { showNotification('Isi wilayah dulu.', 'warning'); return; }
                    rcTutupDialog(); dcAturWilayahIds([id], v);
                };
                rcDialog('Wilayah tampil: ' + c.produk, '<div class="space-y-3 text-sm"><p>Tulis NASIONAL, REGION &lt;kode&gt;, atau kode depot, dipisah koma. Contoh: <span class="font-mono">REGION 5, 1A</span>.</p>'
                    + '<input id="dcWilayahIsi" class="w-full px-3 py-2 border border-gray-300 rounded-lg font-mono" value="' + rcEsc((c.wilayah || []).join(', ')) + '">'
                    + '<p class="text-xs text-gray-500">Pilihan: ' + rcEsc(((rcDc.konfig || {}).wilayah || []).join(', ')) + '</p>'
                    + '<div class="flex justify-end gap-2"><button type="button" onclick="rcTutupDialog()" class="px-4 py-2 border border-gray-300 rounded-lg font-bold">Batal</button>'
                    + '<button type="button" onclick="window.__dcWilayahSimpan()" class="px-4 py-2 bg-rose-600 hover:bg-rose-700 text-white rounded-lg font-bold">Simpan ke Draft</button></div></div>');
            }
            async function dcLihatKartuTerbit(id) {
                const c = rcDc.tb.find(x => x.id === id); if (!c) return;
                if (!rcDc.data) await dcMuatDashboard(false, true);
                const kartu = { id: c.id, produk: c.produk, kode: c.kode, kemasan: c.kemasan, remark: c.remark, untuk: c.untuk, segmen: c.segmen, jenisProduk: '',
                    tiers: c.tiers || [], faktur: c.faktur || [], dari: c.dari, sampai: c.sampai, wilayah: c.wilayah, ct: c.ct, key: c.key, memo: c.memo,
                    catatan: c.catatan, versi: c.versi, terbit: c.terbit, ack: null, wajibAck: false };
                rcDc.mode = 'lihat'; dcModeModal(false); dcIsiModal(kartu);
                document.getElementById('dakJudulKecil').textContent = c.perubahan ? 'Pratinjau ' + (DC_PERUBAHAN[c.perubahan] || [''])[0].toLowerCase() : 'Kartu ' + c.status.toLowerCase();
                document.getElementById('dakCounter').textContent = 'v' + c.versi; document.getElementById('dakBar').style.width = '100%';
                setHiddenSafely('dakAckBtn', true); setHiddenSafely('dakNantiBtn', false); document.getElementById('dakNantiBtn').textContent = 'Tutup';
                document.getElementById('dakFooterText').textContent = 'Tampilan seperti yang dibaca Admin Depot setelah terbit.';
                dcBukaModal();
            }
            async function dcTerbitkanTerpilih() {
                const ids = dcTerpilih().filter(id => rcDc.tb.some(c => c.id === id && c.perubahan && c.perubahan !== 'USANG'));
                if (!ids.length) return;
                const ok = await showConfirmModal({ title: 'Terbitkan Kartu', danger: false, confirmText: 'Ya, Terbitkan',
                    message: 'Terbitkan ' + ids.length + ' kartu? Kartu yang isinya berubah naik versi dan kembali ke antrean acknowledge sebagai Revisi; perubahan wilayah / CT saja tidak menaikkan versi.' });
                if (!ok) return;
                showLoadingOverlay('Menerbitkan...');
                try {
                    const r = await fetchApp({ action: 'discTerbit', ids: ids });
                    if (r.status !== 'success') throw new Error(r.message || 'Gagal menerbitkan');
                    rcDc.data = null;
                    showNotification(r.baru + ' kartu baru, ' + r.revisi + ' revisi, ' + r.wilayah + ' wilayah/CT diterbitkan.', 'success');
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
                dcRenderTerbit();
            }
            async function dcTarikKartu(id) {
                const c = rcDc.tb.find(x => x.id === id); if (!c) return;
                const alasan = await rcMintaAlasan('Tarik Kartu', c.produk + ' hilang dari dashboard dan antrean acknowledge. Catatan acknowledge tetap disimpan.', 'Tarik');
                if (alasan === null) return;
                showLoadingOverlay('Menarik kartu...');
                try {
                    const r = await fetchApp({ action: 'discTarik', ids: [id], alasan: alasan });
                    if (r.status !== 'success') throw new Error(r.message || 'Gagal menarik kartu');
                    rcDc.data = null; showNotification('Kartu ditarik.', 'success');
                } catch (e) { showNotification(e.message, 'error'); }
                finally { hideLoadingOverlay(); }
                dcRenderTerbit();
            }
