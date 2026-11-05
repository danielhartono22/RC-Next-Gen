            // ============================================================================
            // PORTAL LINK (20261163180000)
            // ============================================================================
            // Pemilik, 18 Oktober 2026: satu modul yang merangkum seluruh link, mengikuti contoh
            // integrated_link_system.html. Tab berisi link langsung atau Sub Tab; Tab yang di-pin
            // tampil paling atas. Daftar Link terlihat oleh setiap akun dan isinya sudah disaring
            // server menurut aturan tampil (Region / Depot) terhadap jangkauan akun. Editor Link
            // hanya bila dicentang di Access Management: tambah / ubah link, pin per Tab, aturan
            // tampil, dan arsip / pulihkan (tidak ada hapus permanen).

            let rcPlState = { tab: 'view', rows: [], dimuat: false, terbuka: null,
                editor: { rows: [], arsip: false, regions: [], depots: [], jumlahAktif: 0, jumlahArsip: 0 }, pilih: new Set() };
            let rcPlMuatKe = 0;

            // Konstanta, bukan "return /.../": pemeriksa statis (check-system) membaca garis miring
            // sesudah return sebagai pembagian, lalu tanda kutip di dalam regex sebagai awal string.
            const RC_PL_URL = /^https?:\/\/[^\s<>"]+$/i;
            function plUrlAman(u) { return RC_PL_URL.test(String(u || '')); }

            function switchPortalLinkTab(tab) {
                if (!rcEnterTab('links', tab)) return;
                rcPlState.tab = tab;
                setHiddenSafely('plPanelView', tab !== 'view');
                setHiddenSafely('plPanelEditor', tab !== 'editor');
                ['view', 'editor'].forEach(t => {
                    const el = document.getElementById(t === 'view' ? 'linkTabView' : 'linkTabEditor');
                    if (el) el.className = 'px-5 py-2 text-sm font-bold rounded-lg ' + (t === tab ? 'bg-sky-100 text-sky-700' : 'text-gray-500 hover:bg-gray-100');
                });
                if (tab === 'view') plMuatDaftar(); else plMuatEditor();
            }

            function plMuatUlang() { if (rcPlState.tab === 'editor') plMuatEditor(); else plMuatDaftar(); }

            // ---------- Daftar Link ----------
            async function plMuatDaftar() {
                const ke = ++rcPlMuatKe;
                showLoadingOverlay('Memuat Portal Link...');
                try {
                    const r = await fetchApp({ action: 'linkList' });
                    if (ke !== rcPlMuatKe) return;
                    if (r.status !== 'success') throw new Error(r.message || 'Portal Link gagal dimuat');
                    rcPlState.rows = r.rows || []; rcPlState.dimuat = true; rcPlState.terbuka = null;
                    plRenderDaftar();
                } catch (e) {
                    if (ke !== rcPlMuatKe) return;
                    document.getElementById('plDaftar').innerHTML = '<p class="text-red-600 text-sm">' + rcEsc(e.message) + '</p>';
                    showNotification(e.message, 'error');
                } finally { hideLoadingOverlay(); }
            }

            // Baris server (sudah urut: pin, abjad Tab, abjad Sub Tab) -> kelompok per Tab.
            function plKelompok(rows) {
                const peta = new Map();
                rows.forEach(r => {
                    const k = String(r.tab).toLowerCase();
                    if (!peta.has(k)) peta.set(k, { nama: r.tab, pinned: false, langsung: [], sub: [] });
                    const g = peta.get(k);
                    if (r.pinned) g.pinned = true;
                    (r.subTab ? g.sub : g.langsung).push(r);
                });
                return Array.from(peta.values()).sort((a, b) => (b.pinned - a.pinned) || a.nama.localeCompare(b.nama, 'id'));
            }

            function plTautan(url, isi, kelas, judul) {
                if (!plUrlAman(url)) return '<span class="' + kelas + ' opacity-50" title="URL tidak valid">' + isi + '</span>';
                return '<a href="' + rcEsc(url) + '" target="_blank" rel="noopener noreferrer" class="' + kelas + '"' + (judul ? ' title="' + rcEsc(judul) + '"' : '') + '>' + isi + '</a>';
            }

            function plRenderDaftar() {
                const host = document.getElementById('plDaftar'), hasil = document.getElementById('plHasilCari');
                if (!host) return;
                const term = String((document.getElementById('plCari') || {}).value || '').trim().toLowerCase();
                const pin = '<i class="fas fa-thumbtack text-amber-500 text-xs ml-1.5" title="Pinned"></i>';
                if (!rcPlState.rows.length) {
                    host.innerHTML = '<div class="text-center text-gray-500 py-10 w-full"><i class="fas fa-link-slash text-2xl mb-2 block text-gray-300"></i>Belum ada link untuk akun Anda.</div>';
                    hasil.classList.add('hidden'); host.classList.remove('hidden'); return;
                }

                // Pencarian: daftar datar Tab > Sub Tab supaya Sub Tab yang cocok langsung terlihat.
                if (term) {
                    const cocok = rcPlState.rows.filter(r => [r.tab, r.subTab, r.keterangan].some(v => String(v || '').toLowerCase().includes(term)));
                    host.classList.add('hidden'); hasil.classList.remove('hidden');
                    hasil.innerHTML = !cocok.length
                        ? '<div class="text-center text-gray-500 py-10"><i class="far fa-face-frown text-2xl mb-2 block text-gray-300"></i>Tidak ada link yang cocok dengan pencarian Anda.</div>'
                        : '<div class="border border-gray-200 rounded-xl divide-y divide-gray-100 bg-white">' + plKelompok(cocok).flatMap(g => g.langsung.concat(g.sub).map(r =>
                            plTautan(r.url, '<span class="font-bold text-gray-800">' + rcEsc(r.tab) + '</span>' + (r.pinned ? pin : '')
                                + (r.subTab ? '<i class="fas fa-chevron-right text-[10px] text-gray-300 mx-2"></i><span class="text-sky-700 font-semibold">' + rcEsc(r.subTab) + '</span>' : '')
                                + (r.keterangan ? '<span class="block text-xs text-gray-400 mt-0.5">' + rcEsc(r.keterangan) + '</span>' : ''),
                                'block px-4 py-3 text-sm hover:bg-sky-50 transition-colors', r.url))).join('') + '</div>';
                    return;
                }

                hasil.classList.add('hidden'); host.classList.remove('hidden');
                host.innerHTML = plKelompok(rcPlState.rows).map((g, i) => {
                    const bingkai = g.pinned ? 'border-amber-300 shadow-amber-100 shadow-md' : 'border-gray-200 shadow-sm';
                    const tombol = 'bg-white border ' + bingkai + ' px-6 py-3.5 rounded-xl text-gray-700 font-semibold hover:shadow-md hover:border-sky-300 hover:text-sky-700 transition-all text-center min-w-[150px] flex items-center justify-center gap-1';
                    // Satu link langsung tanpa Sub Tab: tombolnya sendiri adalah link.
                    if (!g.sub.length && g.langsung.length === 1) {
                        const r = g.langsung[0];
                        return plTautan(r.url, '<span>' + rcEsc(g.nama) + '</span>' + (g.pinned ? pin : ''), tombol, r.keterangan || r.url);
                    }
                    const isi = g.langsung.map(r => ({ nama: r.keterangan || ('Buka ' + g.nama), r: r })).concat(g.sub.map(r => ({ nama: r.subTab, r: r })));
                    const buka = rcPlState.terbuka === i;
                    return '<div class="relative inline-block" data-pl-grup="' + i + '">'
                        + '<button type="button" onclick="plToggleGrup(' + i + ')" class="' + tombol + (buka ? ' border-sky-300 text-sky-700' : '') + '" aria-expanded="' + buka + '">'
                        + '<span>' + rcEsc(g.nama) + '</span>' + (g.pinned ? pin : '') + '<i class="fas fa-chevron-down text-[10px] text-gray-400 ml-1.5"></i></button>'
                        + '<div class="' + (buka ? '' : 'hidden ') + 'absolute left-0 mt-2 w-64 bg-white border border-gray-100 rounded-xl shadow-lg z-20 overflow-hidden text-left">'
                        + isi.map(x => plTautan(x.r.url, rcEsc(x.nama), 'block px-4 py-3 text-sm text-gray-600 hover:bg-sky-50 hover:text-sky-700 border-b border-gray-50 last:border-0 transition-colors', x.r.subTab ? (x.r.keterangan || x.r.url) : x.r.url)).join('')
                        + '</div></div>';
                }).join('');
            }

            function plToggleGrup(i) {
                rcPlState.terbuka = rcPlState.terbuka === i ? null : i;
                plRenderDaftar();
            }

            // Klik di luar grup menutup Sub Tab yang terbuka.
            document.addEventListener('click', function (e) {
                if (rcPlState.terbuka === null || (e.target.closest && e.target.closest('[data-pl-grup]'))) return;
                rcPlState.terbuka = null; plRenderDaftar();
            });

            // ---------- Editor Link ----------
            async function plMuatEditor() {
                const ke = ++rcPlMuatKe;
                showLoadingOverlay('Memuat Editor Link...');
                try {
                    const r = await fetchApp({ action: 'linkEditorList', arsip: rcPlState.editor.arsip });
                    if (ke !== rcPlMuatKe) return;
                    if (r.status !== 'success') throw new Error(r.message || 'Editor Link gagal dimuat');
                    Object.assign(rcPlState.editor, { rows: r.rows || [], regions: r.regions || [], depots: r.depots || [],
                        jumlahAktif: Number(r.jumlahAktif || 0), jumlahArsip: Number(r.jumlahArsip || 0) });
                    rcPlState.pilih = new Set();
                    plRenderEditor();
                } catch (e) {
                    if (ke !== rcPlMuatKe) return;
                    document.getElementById('plEditorBody').innerHTML = '<tr><td colspan="7" class="p-6 text-red-600">' + rcEsc(e.message) + '</td></tr>';
                    showNotification(e.message, 'error');
                } finally { hideLoadingOverlay(); }
            }

            function plGantiMode(arsip) {
                if (rcPlState.editor.arsip === arsip) return;
                rcPlState.editor.arsip = arsip;
                plMuatEditor();
            }

            function plRenderEditor() {
                const ed = rcPlState.editor, body = document.getElementById('plEditorBody');
                if (!body) return;
                const aktif = 'px-3 py-1.5 text-xs font-bold rounded-md bg-white shadow-sm text-sky-700', idle = 'px-3 py-1.5 text-xs font-bold rounded-md text-gray-500';
                const ma = document.getElementById('plModeAktif'), mr = document.getElementById('plModeArsip');
                if (ma) { ma.className = ed.arsip ? idle : aktif; ma.innerText = 'Aktif (' + ed.jumlahAktif.toLocaleString('id-ID') + ')'; }
                if (mr) { mr.className = ed.arsip ? aktif : idle; mr.innerText = 'Arsip (' + ed.jumlahArsip.toLocaleString('id-ID') + ')'; }
                setTextSafely('plBtnArsipTeks', ed.arsip ? 'Pulihkan terpilih' : 'Arsipkan terpilih');

                const term = String((document.getElementById('plEditorCari') || {}).value || '').trim().toLowerCase();
                const rows = ed.rows.filter(r => !term || [r.tab, r.subTab, r.url, r.keterangan, r.aturan].some(v => String(v || '').toLowerCase().includes(term)));
                if (!rows.length) {
                    body.innerHTML = '<tr><td colspan="7" class="p-8 text-center text-gray-500">' + (ed.rows.length ? 'Tidak ada link yang cocok.' : ed.arsip ? 'Belum ada link yang diarsip.' : 'Belum ada link. Klik Tambah Link.') + '</td></tr>';
                } else {
                    body.innerHTML = rows.map(r => {
                        const id = rcEsc(r.id), tabJs = rcEsc(JSON.stringify(r.tab));
                        const semua = r.aturan === 'Semua akun';
                        return '<tr class="border-t border-gray-100 ' + (r.pinned && !ed.arsip ? 'bg-amber-50/40 hover:bg-amber-50' : 'hover:bg-gray-50') + '">'
                            + '<td class="p-3"><input type="checkbox" class="pl-pilih rounded" value="' + id + '" ' + (rcPlState.pilih.has(r.id) ? 'checked ' : '') + 'onchange="plPilih(this)"></td>'
                            + '<td class="p-3 font-bold text-gray-800 whitespace-nowrap">' + rcEsc(r.tab) + (r.pinned ? ' <i class="fas fa-thumbtack text-amber-500 ml-1" title="Pinned"></i>' : '') + '</td>'
                            + '<td class="p-3 whitespace-nowrap">' + (r.subTab ? '<span class="bg-sky-50 text-sky-700 border border-sky-100 px-2 py-0.5 rounded-md font-semibold">' + rcEsc(r.subTab) + '</span>'
                                : '<span class="text-gray-400 bg-gray-100 px-2 py-0.5 rounded-md italic">Link langsung</span>') + '</td>'
                            + '<td class="p-3 max-w-[260px]">' + plTautan(r.url, rcEsc(r.url), 'text-sky-600 hover:underline truncate block', r.url)
                                + (r.keterangan ? '<span class="block text-gray-400 truncate" title="' + rcEsc(r.keterangan) + '">' + rcEsc(r.keterangan) + '</span>' : '') + '</td>'
                            + '<td class="p-3"><span class="' + (semua ? 'text-gray-500' : 'text-indigo-700 font-semibold') + '">' + rcEsc(r.aturan) + '</span></td>'
                            + '<td class="p-3 whitespace-nowrap text-gray-500">' + rcEsc(ed.arsip ? r.diarsipPada : r.diubahPada) + '<span class="block text-[11px]">' + rcEsc(ed.arsip ? (r.alasanArsip || '-') : r.diubahOleh) + '</span></td>'
                            + '<td class="p-3"><div class="flex justify-center gap-1.5">'
                            + (ed.arsip
                                ? '<button onclick="plArsip([\'' + id + '\'])" class="px-2.5 py-1.5 rounded-lg border border-emerald-200 text-emerald-700 bg-emerald-50 hover:bg-emerald-100 font-bold" title="Pulihkan"><i class="fas fa-rotate-left"></i></button>'
                                : '<button onclick="plTogglePin(' + tabJs + ',' + !r.pinned + ')" class="px-2.5 py-1.5 rounded-lg border ' + (r.pinned ? 'border-amber-200 text-amber-600 bg-amber-50' : 'border-gray-200 text-gray-400 bg-gray-50 hover:text-amber-600') + '" title="' + (r.pinned ? 'Lepas pin Tab' : 'Pin Tab ke atas') + '"><i class="fas fa-thumbtack"></i></button>'
                                  + '<button onclick="plBukaForm(\'' + id + '\')" class="px-2.5 py-1.5 rounded-lg border border-sky-200 text-sky-700 bg-sky-50 hover:bg-sky-100" title="Ubah"><i class="fas fa-pen"></i></button>'
                                  + '<button onclick="plArsip([\'' + id + '\'])" class="px-2.5 py-1.5 rounded-lg border border-red-200 text-red-600 bg-red-50 hover:bg-red-100" title="Arsipkan"><i class="fas fa-box-archive"></i></button>')
                            + '</div></td></tr>';
                    }).join('');
                }
                plPerbaruiPilihan();
            }

            function plPilih(cb) { if (cb.checked) rcPlState.pilih.add(cb.value); else rcPlState.pilih.delete(cb.value); plPerbaruiPilihan(); }
            function plPilihSemua(on) {
                document.querySelectorAll('#plEditorBody .pl-pilih').forEach(cb => { cb.checked = on; if (on) rcPlState.pilih.add(cb.value); else rcPlState.pilih.delete(cb.value); });
                plPerbaruiPilihan();
            }
            function plPerbaruiPilihan() {
                const n = rcPlState.pilih.size, b = document.getElementById('plBtnArsip');
                if (b) b.disabled = n === 0;
                setTextSafely('plBtnArsipTeks', (rcPlState.editor.arsip ? 'Pulihkan' : 'Arsipkan') + ' terpilih' + (n ? ' (' + n + ')' : ''));
                const semua = document.getElementById('plPilihSemua'), cbs = document.querySelectorAll('#plEditorBody .pl-pilih');
                if (semua) semua.checked = cbs.length > 0 && Array.from(cbs).every(c => c.checked);
            }
            function plArsipTerpilih() { if (rcPlState.pilih.size) plArsip(Array.from(rcPlState.pilih)); }

            // Kotak alasan arsip milik Portal Link sendiri: modul ini dipindahkan ke prod (19 Oktober
            // 2026) lebih dulu daripada Claim Upload > Open yang memiliki rcMintaAlasan, jadi tidak
            // boleh bergantung padanya.
            function plMintaAlasan(judul, pesan, tombol) {
                return new Promise(function (selesai) {
                    window.__plAlasanSelesai = function (ok) {
                        const v = ok ? String((document.getElementById('plAlasanIsi') || {}).value || '').trim() : null;
                        if (ok && v.length < 3) { showNotification('Alasan wajib diisi (minimal 3 karakter).', 'warning'); return; }
                        window.__plAlasanSelesai = null; rcTutupDialog(); selesai(v);
                    };
                    rcDialog(judul, '<div class="space-y-3 text-sm"><p>' + rcEsc(pesan) + '</p>'
                        + '<textarea id="plAlasanIsi" rows="3" maxlength="300" class="w-full px-3 py-2 border border-gray-300 rounded-lg" placeholder="Alasan (wajib)"></textarea>'
                        + '<div class="flex justify-end gap-2"><button type="button" onclick="window.__plAlasanSelesai && window.__plAlasanSelesai(false)" class="px-4 py-2 border border-gray-300 rounded-lg font-bold">Batal</button>'
                        + '<button type="button" id="plAlasanOk" onclick="window.__plAlasanSelesai && window.__plAlasanSelesai(true)" class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-bold">' + rcEsc(tombol) + '</button></div></div>');
                    setTimeout(function () { const el = document.getElementById('plAlasanIsi'); if (el) el.focus(); }, 50);
                });
            }

            async function plArsip(ids) {
                const arsip = !rcPlState.editor.arsip;
                let alasan = '';
                if (arsip) {
                    alasan = await plMintaAlasan('Arsipkan Link', ids.length + ' link akan disembunyikan dari Daftar Link. Link tetap tersimpan dan dapat dipulihkan dari tampilan Arsip.', 'Arsipkan');
                    if (alasan === null) return;
                } else if (!await showConfirmModal({ title: 'Pulihkan Link', message: ids.length + ' link akan tampil kembali di Daftar Link sesuai aturan tampilnya.', confirmText: 'Pulihkan', danger: false })) return;
                showLoadingOverlay(arsip ? 'Mengarsipkan link...' : 'Memulihkan link...');
                try {
                    const r = await fetchApp({ action: 'linkArsip', ids: ids, arsip: arsip, alasan: alasan });
                    if (r.status !== 'success') throw new Error(r.message || 'Gagal memproses link.');
                    showNotification(r.message, 'success');
                    rcPlState.dimuat = false;
                } catch (e) { showNotification(e.message, 'error'); } finally { hideLoadingOverlay(); }
                plMuatEditor();
            }

            async function plTogglePin(tab, pinned) {
                showLoadingOverlay(pinned ? 'Menyematkan Tab...' : 'Melepas pin Tab...');
                try {
                    const r = await fetchApp({ action: 'linkPin', tab: tab, pinned: pinned });
                    if (r.status !== 'success') throw new Error(r.message || 'Gagal mengubah pin.');
                    showNotification(r.message, 'success');
                    rcPlState.dimuat = false;
                } catch (e) { showNotification(e.message, 'error'); } finally { hideLoadingOverlay(); }
                plMuatEditor();
            }

            // ---------- Formulir Tambah / Ubah ----------
            function plBukaForm(id) {
                const ed = rcPlState.editor, r = id ? ed.rows.find(x => x.id === id) : null;
                if (id && !r) { showNotification('Link tidak ditemukan; segarkan daftar.', 'warning'); return; }
                const reg = new Set(r ? r.regions || [] : []), dep = new Set(r ? r.depotIds || [] : []);
                const khusus = reg.size > 0 || dep.size > 0;
                const tabAda = Array.from(new Set(ed.rows.map(x => x.tab))).sort((a, b) => a.localeCompare(b, 'id'));
                const masukan = 'w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-sky-500';
                const label = 'block text-xs font-bold text-gray-700 mb-1';
                rcDialog(r ? 'Ubah Link' : 'Tambah Link', '<div data-rc-dialog-wide class="space-y-4 text-sm">'
                    + '<div class="grid grid-cols-1 md:grid-cols-2 gap-4">'
                    + '<div><label class="' + label + '">Tab <span class="text-red-500">*</span></label><input id="plfTab" list="plfTabList" maxlength="60" class="' + masukan + '" value="' + rcEsc(r ? r.tab : '') + '" oninput="plFormTabBerubah()" placeholder="mis. Sales"><datalist id="plfTabList">' + tabAda.map(t => '<option value="' + rcEsc(t) + '">').join('') + '</datalist></div>'
                    + '<div><label class="' + label + '">Sub Tab <span class="font-normal text-gray-400">(kosongkan bila link langsung)</span></label><input id="plfSub" maxlength="80" class="' + masukan + '" value="' + rcEsc(r ? r.subTab : '') + '" placeholder="mis. Sales Report"></div>'
                    + '</div>'
                    + '<div><label class="' + label + '">URL <span class="text-red-500">*</span></label><input id="plfUrl" type="url" maxlength="1000" class="' + masukan + '" value="' + rcEsc(r ? r.url : '') + '" placeholder="https://..."></div>'
                    + '<div><label class="' + label + '">Keterangan <span class="font-normal text-gray-400">(opsional, tampil saat kursor di atas link)</span></label><input id="plfKet" maxlength="300" class="' + masukan + '" value="' + rcEsc(r ? r.keterangan : '') + '"></div>'
                    + '<label class="flex items-center gap-2 bg-amber-50 border border-amber-100 rounded-lg p-3 cursor-pointer"><input type="checkbox" id="plfPin" class="rounded text-amber-500" ' + (r && r.pinned ? 'checked' : '') + '><span><i class="fas fa-thumbtack text-amber-500 mr-1"></i><b>Pin Tab ini ke atas</b> <span class="text-xs text-gray-500">- berlaku untuk seluruh link di Tab yang sama</span></span></label>'
                    + '<fieldset class="border border-gray-200 rounded-xl p-4"><legend class="text-xs font-black px-1 text-gray-700">Ditampilkan untuk</legend>'
                    + '<div class="flex flex-wrap gap-4 mb-3"><label class="flex items-center gap-2 font-semibold"><input type="radio" name="plfAturan" value="semua" ' + (khusus ? '' : 'checked') + ' onchange="plFormAturan()"> Semua akun</label>'
                    + '<label class="flex items-center gap-2 font-semibold"><input type="radio" name="plfAturan" value="pilih" ' + (khusus ? 'checked' : '') + ' onchange="plFormAturan()"> Region / Depot tertentu</label></div>'
                    + '<div id="plfAturanPilih" class="' + (khusus ? '' : 'hidden ') + 'space-y-3">'
                    + '<p class="text-xs text-gray-500">Link terlihat oleh akun yang jangkauan depotnya mencakup salah satu Region <b>atau</b> Depot yang dipilih. System Manager selalu melihat seluruhnya.</p>'
                    + '<div><span class="' + label + '">Region</span><div class="flex flex-wrap gap-2">' + (ed.regions.length ? ed.regions.map(x => '<label class="flex items-center gap-1.5 px-3 py-1.5 border border-gray-200 rounded-lg cursor-pointer hover:bg-indigo-50"><input type="checkbox" class="plf-region rounded text-indigo-600" value="' + rcEsc(x) + '" ' + (reg.has(x) ? 'checked ' : '') + 'onchange="plFormRingkas()"><span class="font-bold">' + rcEsc(x) + '</span></label>').join('') : '<span class="text-xs text-gray-400">Belum ada region di Depot Master.</span>') + '</div></div>'
                    + '<div><div class="flex items-center justify-between gap-2 mb-1"><span class="' + label + ' mb-0">Depot</span><input id="plfDepotCari" oninput="plFormSaringDepot()" placeholder="Cari depot..." class="px-2 py-1 border border-gray-300 rounded-md text-xs w-44"></div>'
                    + '<div id="plfDepotList" class="max-h-48 overflow-y-auto border border-gray-200 rounded-lg p-2 grid grid-cols-1 sm:grid-cols-2 gap-1">'
                    + ed.depots.map(d => '<label class="plf-depot-baris flex items-center gap-2 px-2 py-1 rounded hover:bg-indigo-50 cursor-pointer text-xs" data-cari="' + rcEsc((d.kode + ' ' + d.nama + ' ' + d.region).toLowerCase()) + '"><input type="checkbox" class="plf-depot rounded text-indigo-600" value="' + rcEsc(d.id) + '" ' + (dep.has(d.id) ? 'checked ' : '') + 'onchange="plFormRingkas()"><b>' + rcEsc(d.kode) + '</b><span class="truncate text-gray-600">' + rcEsc(d.nama) + '</span>' + (d.region ? '<span class="ml-auto text-[10px] text-gray-400">' + rcEsc(d.region) + '</span>' : '') + '</label>').join('')
                    + '</div></div>'
                    + '<p id="plfRingkas" class="text-xs font-bold text-indigo-700"></p></div></fieldset>'
                    + '<div class="flex justify-end gap-2 pt-1"><button type="button" onclick="rcTutupDialog()" class="px-4 py-2 border border-gray-300 rounded-lg font-bold">Batal</button>'
                    + '<button type="button" id="plfSimpan" onclick="plSimpanForm(' + (r ? '\'' + rcEsc(r.id) + '\'' : 'null') + ')" class="px-5 py-2 bg-sky-600 hover:bg-sky-700 text-white rounded-lg font-bold"><i class="fas fa-save mr-1.5"></i>Simpan</button></div>'
                    + '</div>');
                plFormRingkas();
                setTimeout(() => { const el = document.getElementById('plfTab'); if (el) el.focus(); }, 50);
            }

            // Tab yang sudah ada: kotak Pin mengikuti status pin Tab itu.
            function plFormTabBerubah() {
                const v = String(document.getElementById('plfTab').value || '').trim().toLowerCase();
                const ada = rcPlState.editor.rows.filter(x => x.tab.toLowerCase() === v);
                if (ada.length) document.getElementById('plfPin').checked = ada.some(x => x.pinned);
            }
            function plFormAturan() {
                const pilih = (document.querySelector('input[name="plfAturan"]:checked') || {}).value === 'pilih';
                setHiddenSafely('plfAturanPilih', !pilih);
                plFormRingkas();
            }
            function plFormSaringDepot() {
                const t = String(document.getElementById('plfDepotCari').value || '').trim().toLowerCase();
                document.querySelectorAll('#plfDepotList .plf-depot-baris').forEach(el => el.classList.toggle('hidden', !!t && !el.dataset.cari.includes(t)));
            }
            function plFormNilai() {
                const pilih = (document.querySelector('input[name="plfAturan"]:checked') || {}).value === 'pilih';
                return {
                    regions: pilih ? Array.from(document.querySelectorAll('.plf-region:checked')).map(e => e.value) : [],
                    depotIds: pilih ? Array.from(document.querySelectorAll('.plf-depot:checked')).map(e => e.value) : [],
                    pilih: pilih
                };
            }
            function plFormRingkas() {
                const v = plFormNilai();
                setTextSafely('plfRingkas', !v.pilih ? '' : (v.regions.length + ' region, ' + v.depotIds.length + ' depot dipilih'
                    + (v.regions.length + v.depotIds.length === 0 ? ' - pilih minimal satu, atau pilih Semua akun.' : '.')));
            }

            async function plSimpanForm(id) {
                const tab = String(document.getElementById('plfTab').value || '').trim();
                const url = String(document.getElementById('plfUrl').value || '').trim();
                const v = plFormNilai();
                if (!tab) { showNotification('Nama Tab wajib diisi.', 'warning'); return; }
                if (!plUrlAman(url)) { showNotification('URL harus diawali http:// atau https:// dan tanpa spasi.', 'warning'); return; }
                if (v.pilih && !v.regions.length && !v.depotIds.length) { showNotification('Pilih minimal satu Region atau Depot, atau pilih Semua akun.', 'warning'); return; }
                const tombol = document.getElementById('plfSimpan'); if (tombol) tombol.disabled = true;
                try {
                    const r = await fetchApp({ action: 'linkSimpan', link: { id: id || '', tab: tab, subTab: String(document.getElementById('plfSub').value || '').trim(),
                        url: url, keterangan: String(document.getElementById('plfKet').value || '').trim(), pinned: document.getElementById('plfPin').checked,
                        regions: v.regions, depotIds: v.depotIds } });
                    if (r.status !== 'success') throw new Error(r.message || 'Gagal menyimpan link.');
                    rcTutupDialog(); showNotification(r.message, 'success');
                    rcPlState.dimuat = false;
                    if (rcPlState.editor.arsip) rcPlState.editor.arsip = false;
                    plMuatEditor();
                } catch (e) { showNotification(e.message, 'error'); if (tombol) tombol.disabled = false; }
            }
