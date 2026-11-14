            // ============================================================================
            // KNOWLEDGE BASE (20261163920000)
            // ============================================================================
            // Pemilik, 11 November 2026: SOP, surat, pricelist, pengumuman, dll. berupa link.
            // Knowledge Resources: dokumen yang ditujukan untuk akun ini (peran + wilayah, disaring
            // server), dikelompokkan per tab jenis. Membuka link tercatat; tombol Acknowledge baru
            // aktif sesudah link dibuka dan memunculkan pernyataan sesuai jenisnya. Jumlah yang
            // belum di-acknowledge tampil sebagai badge di kartu beranda dan tab.
            // Knowledge Management (hanya bila dicentang): tambah / ubah / arsip, progres, dan
            // Details berisi diagram status, per region, per depot, serta daftar akun.

            let rcKb = { tab: 'resources', rows: [], jenis: '', belum: 0,
                kelola: { rows: [], arsip: false, peran: [], jenisAda: [], regions: [], depots: [], jumlahAktif: 0, jumlahArsip: 0 },
                pilih: new Set(), detail: null, akunTampil: 200, grafik: {} };
            let rcKbMuatKe = 0;
            let rcKbBadgeTerakhir = 0;

            // Konstanta, bukan "return /.../" (lihat catatan Portal Link untuk pemeriksa statis).
            const RC_KB_URL = /^https?:\/\/[^\s<>"]+$/i;
            function kbUrlAman(u) { return RC_KB_URL.test(String(u || '')); }
            function kbAngka(n) { return Number(n || 0).toLocaleString('id-ID'); }
            function kbPersen(a, b) { return b > 0 ? Math.round(a * 1000 / b) / 10 : 0; }

            function switchKbTab(tab) {
                if (!rcEnterTab('kb', tab)) return;
                rcKb.tab = tab;
                setHiddenSafely('kbPanelResources', tab !== 'resources');
                setHiddenSafely('kbPanelManage', tab !== 'manage');
                [['resources', 'kbTabResources'], ['manage', 'kbTabManage']].forEach(([t, id]) => {
                    const el = document.getElementById(id);
                    if (el) el.className = 'px-5 py-2 text-sm font-bold rounded-lg inline-flex items-center gap-2 ' + (t === tab ? 'bg-teal-100 text-teal-700' : 'text-gray-500 hover:bg-gray-100');
                });
                if (tab === 'resources') kbMuatResources();
                else { kbTutupDetail(); kbMuatKelola(); }
            }

            function kbMuatUlang() {
                if (rcKb.tab !== 'manage') kbMuatResources();
                else if (rcKb.detail) kbBukaDetail(rcKb.detail.id);
                else kbMuatKelola();
            }

            // ---------- Badge belum dibaca ----------
            function kbSetBelum(n) {
                rcKb.belum = Number(n || 0);
                ['menuKbBadge', 'kbTabResourcesBadge'].forEach(id => {
                    const el = document.getElementById(id); if (!el) return;
                    el.textContent = rcKb.belum > 99 ? '99+' : String(rcKb.belum);
                    el.classList.toggle('hidden', rcKb.belum === 0);
                });
            }

            async function kbPerbaruiBadge(paksa) {
                if (!currentUserData || !rcCanTab('kb.resources')) { kbSetBelum(0); return; }
                if (!paksa && Date.now() - rcKbBadgeTerakhir < 30000) return;
                rcKbBadgeTerakhir = Date.now();
                try { const r = await fetchApp({ action: 'kbBelum' }); if (r.status === 'success') kbSetBelum(r.belum); } catch (e) { /* badge saja */ }
            }
            (function () {
                const asliSesi = applySession;
                applySession = function (res) { rcKb.rows = []; kbSetBelum(0); asliSesi(res); setTimeout(() => kbPerbaruiBadge(true), 500); };
                const asliBeranda = goToHome;
                goToHome = function () { asliBeranda.apply(this, arguments); kbPerbaruiBadge(false); };
            })();

            // ---------- Knowledge Resources ----------
            async function kbMuatResources() {
                const ke = ++rcKbMuatKe;
                showLoadingOverlay('Memuat Knowledge Resources...');
                try {
                    const r = await fetchApp({ action: 'kbList' });
                    if (ke !== rcKbMuatKe) return;
                    if (r.status !== 'success') throw new Error(r.message || 'Knowledge Resources gagal dimuat');
                    rcKb.rows = r.rows || [];
                    if (rcKb.jenis && !rcKb.rows.some(x => x.jenis === rcKb.jenis)) rcKb.jenis = '';
                    kbSetBelum(r.belum); rcKbBadgeTerakhir = Date.now();
                    kbRenderResources();
                } catch (e) {
                    if (ke !== rcKbMuatKe) return;
                    document.getElementById('kbDaftar').innerHTML = '<p class="text-red-600 text-sm">' + rcEsc(e.message) + '</p>';
                    showNotification(e.message, 'error');
                } finally { hideLoadingOverlay(); }
            }

            function kbPilihJenis(j) { rcKb.jenis = j; kbRenderResources(); }

            function kbStatusChip(r) {
                if (r.ack) return '<span class="bg-emerald-100 text-emerald-700 px-2 py-0.5 rounded-md text-[10px] font-black uppercase"><i class="fas fa-check-double mr-1"></i>Acknowledged</span>';
                if (r.dibuka) return '<span class="bg-amber-100 text-amber-800 px-2 py-0.5 rounded-md text-[10px] font-black uppercase">Dibuka, belum acknowledge</span>';
                return '<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded-md text-[10px] font-black uppercase">Belum dibaca</span>';
            }

            function kbRenderResources() {
                const host = document.getElementById('kbDaftar'); if (!host) return;
                const rows = rcKb.rows;
                // Tab per jenis, masing-masing dengan jumlah yang belum di-acknowledge.
                const jenis = Array.from(new Set(rows.map(r => r.jenis))).sort((a, b) => a.localeCompare(b, 'id'));
                const tombol = (kode, label, belum, n) => '<button type="button" onclick="kbPilihJenis(' + rcEsc(JSON.stringify(kode)) + ')" class="px-4 py-2 rounded-lg text-sm font-bold border inline-flex items-center gap-2 '
                    + (rcKb.jenis === kode ? 'bg-teal-600 border-teal-600 text-white' : 'bg-white border-gray-200 text-gray-600 hover:border-teal-300 hover:text-teal-700') + '">' + rcEsc(label)
                    + '<span class="text-[10px] font-black ' + (rcKb.jenis === kode ? 'text-teal-100' : 'text-gray-400') + '">' + n + '</span>'
                    + (belum ? '<span class="bg-red-600 text-white text-[10px] font-black rounded-full px-1.5 py-0.5">' + belum + '</span>' : '') + '</button>';
                document.getElementById('kbJenisBar').innerHTML = rows.length ? tombol('', 'Semua', rows.filter(r => !r.ack).length, rows.length)
                    + jenis.map(j => tombol(j, j, rows.filter(r => r.jenis === j && !r.ack).length, rows.filter(r => r.jenis === j).length)).join('') : '';
                const banner = document.getElementById('kbBanner');
                if (banner) {
                    banner.classList.toggle('hidden', !rcKb.belum);
                    setTextSafely('kbBannerTeks', 'Ada ' + kbAngka(rcKb.belum) + ' dokumen yang belum Anda acknowledge. Buka dokumennya, baca, lalu tekan Acknowledge.');
                }

                if (!rows.length) {
                    host.innerHTML = '<div class="text-center text-gray-500 py-12"><i class="fas fa-book-open text-3xl mb-3 block text-gray-300"></i>Belum ada dokumen untuk akun Anda.</div>';
                    return;
                }
                const term = String((document.getElementById('kbCari') || {}).value || '').trim().toLowerCase();
                const hanyaBelum = !!(document.getElementById('kbHanyaBelum') || {}).checked;
                const tampil = rows.filter(r => (!rcKb.jenis || r.jenis === rcKb.jenis) && (!hanyaBelum || !r.ack)
                    && (!term || [r.judul, r.deskripsi, r.jenis].some(v => String(v || '').toLowerCase().includes(term))));
                if (!tampil.length) {
                    host.innerHTML = '<div class="text-center text-gray-500 py-10"><i class="far fa-face-smile text-2xl mb-2 block text-gray-300"></i>' + (hanyaBelum && !term ? 'Semua dokumen di tab ini sudah Anda acknowledge.' : 'Tidak ada dokumen yang cocok.') + '</div>';
                    return;
                }
                host.innerHTML = tampil.map(r => {
                    const id = rcEsc(r.id);
                    const bingkai = r.pin ? 'border-amber-300 shadow-amber-100 shadow-md' : 'border-gray-200 shadow-sm';
                    const garis = r.ack ? 'border-l-emerald-400' : r.dibuka ? 'border-l-amber-400' : 'border-l-red-500';
                    const meta = ['Terbit ' + r.terbit].concat(r.revisiPada ? ['Revisi ' + r.revisiPada] : [], r.dibukaPada ? ['Dibuka ' + r.dibukaPada] : [], r.ackPada ? ['Acknowledged ' + r.ackPada] : []);
                    const buka = kbUrlAman(r.url)
                        ? '<a href="' + rcEsc(r.url) + '" target="_blank" rel="noopener noreferrer" onclick="kbBuka(\'' + id + '\')" class="flex-1 md:flex-none text-center px-4 py-2.5 rounded-lg text-sm font-bold border border-teal-300 text-teal-700 bg-teal-50 hover:bg-teal-100"><i class="fas fa-up-right-from-square mr-1.5"></i>Buka Dokumen</a>'
                        : '<span class="flex-1 md:flex-none text-center px-4 py-2.5 rounded-lg text-sm font-bold border border-gray-200 text-gray-400">Link tidak valid</span>';
                    const ack = r.ack
                        ? '<span class="flex-1 md:flex-none text-center px-4 py-2.5 rounded-lg text-sm font-bold bg-emerald-50 text-emerald-700 border border-emerald-200"><i class="fas fa-check-double mr-1.5"></i>Acknowledged</span>'
                        : '<button type="button" onclick="kbAck(\'' + id + '\')" ' + (r.dibuka ? '' : 'disabled title="Buka dokumennya lebih dulu" ')
                          + 'class="flex-1 md:flex-none px-4 py-2.5 rounded-lg text-sm font-bold text-white bg-teal-600 hover:bg-teal-700 disabled:bg-gray-300 disabled:cursor-not-allowed"><i class="fas fa-signature mr-1.5"></i>Acknowledge</button>';
                    return '<div class="bg-white border ' + bingkai + ' border-l-4 ' + garis + ' rounded-xl p-4 md:p-5 flex flex-col md:flex-row md:items-center gap-4">'
                        + '<div class="flex-1 min-w-0">'
                        + '<div class="flex flex-wrap items-center gap-1.5 mb-1.5"><span class="bg-teal-50 text-teal-700 border border-teal-100 px-2 py-0.5 rounded-md text-[10px] font-black uppercase">' + rcEsc(r.jenis) + '</span>'
                        + (r.pin ? '<span class="bg-amber-50 text-amber-700 border border-amber-200 px-2 py-0.5 rounded-md text-[10px] font-black uppercase"><i class="fas fa-thumbtack mr-1"></i>Pin s/d ' + rcEsc(r.pinSampai) + '</span>' : '')
                        + (r.revisi ? '<span class="bg-violet-100 text-violet-700 px-2 py-0.5 rounded-md text-[10px] font-black uppercase"><i class="fas fa-rotate mr-1"></i>Direvisi - mohon baca ulang</span>' : '')
                        + kbStatusChip(r) + '</div>'
                        + '<h3 class="font-extrabold text-gray-800 text-base leading-snug break-words">' + rcEsc(r.judul) + '</h3>'
                        + (r.deskripsi ? '<p class="text-sm text-gray-600 mt-1 whitespace-pre-line break-words line-clamp-3 cursor-pointer" title="Klik untuk membuka / menutup" onclick="this.classList.toggle(\'line-clamp-3\')">' + rcEsc(r.deskripsi) + '</p>' : '')
                        + '<p class="text-[11px] text-gray-400 mt-2">' + rcEsc(meta.join(' · ')) + '</p></div>'
                        + '<div class="flex md:flex-col gap-2 shrink-0 md:w-48">' + buka + ack + '</div></div>';
                }).join('');
            }

            // Membuka link dicatat tanpa menahan tautannya: peramban tetap membuka tab baru.
            function kbBuka(id) {
                const r = rcKb.rows.find(x => x.id === id);
                fetchApp({ action: 'kbBuka', id: id }).then(res => {
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal mencatat');
                    if (r) { r.dibuka = true; r.dibukaPada = res.dibukaPada; if (res.versi && res.versi !== r.versi) { kbMuatResources(); return; } }
                    kbRenderResources();
                }).catch(e => showNotification('Pembukaan dokumen belum tercatat: ' + e.message + '. Buka ulang dokumennya.', 'warning'));
                return true;
            }

            function kbAck(id) {
                const r = rcKb.rows.find(x => x.id === id); if (!r) return;
                if (!r.dibuka) { showNotification('Buka dan baca dokumennya lebih dulu, lalu tekan Acknowledge.', 'warning'); return; }
                rcDialog('Acknowledge ' + r.jenis, '<div class="space-y-4 text-sm">'
                    + '<div><p class="text-[11px] font-black uppercase tracking-wider text-teal-700">' + rcEsc(r.jenis) + '</p><p class="font-extrabold text-gray-800 text-base break-words">' + rcEsc(r.judul) + '</p></div>'
                    + '<blockquote class="bg-teal-50 border-l-4 border-teal-500 rounded-r-lg p-4 text-gray-800 leading-relaxed">&ldquo;' + rcEsc(r.pernyataan) + '&rdquo;</blockquote>'
                    + '<p class="text-xs text-gray-500">Dengan menekan <b>Saya Setuju</b>, pernyataan di atas tercatat atas nama akun Anda beserta waktunya.</p>'
                    + '<div class="flex justify-end gap-2"><button type="button" onclick="rcTutupDialog()" class="px-4 py-2 border border-gray-300 rounded-lg font-bold">Batal</button>'
                    + '<button type="button" id="kbAckOk" onclick="kbKirimAck(\'' + rcEsc(id) + '\')" class="px-5 py-2 bg-teal-600 hover:bg-teal-700 text-white rounded-lg font-bold"><i class="fas fa-check-double mr-1.5"></i>Saya Setuju</button></div></div>');
            }

            async function kbKirimAck(id) {
                const r = rcKb.rows.find(x => x.id === id), b = document.getElementById('kbAckOk');
                if (b) b.disabled = true;
                try {
                    const res = await fetchApp({ action: 'kbAck', id: id, versi: r ? r.versi : null });
                    if (res.status !== 'success') throw new Error(res.message || 'Acknowledge gagal');
                    rcTutupDialog(); showNotification(res.message, 'success');
                    if (r) { r.ack = true; r.ackPada = res.ackPada || r.ackPada; r.revisi = false; }
                    kbSetBelum(rcKb.rows.filter(x => !x.ack).length); rcKbBadgeTerakhir = Date.now();
                    kbRenderResources();
                } catch (e) {
                    showNotification(e.message, 'error');
                    if (b) b.disabled = false;
                    if (/direvisi/i.test(e.message)) { rcTutupDialog(); kbMuatResources(); }
                }
            }

            // ---------- Knowledge Management ----------
            async function kbMuatKelola() {
                const ke = ++rcKbMuatKe;
                showLoadingOverlay('Memuat Knowledge Management...');
                try {
                    const r = await fetchApp({ action: 'kbKelolaList', arsip: rcKb.kelola.arsip });
                    if (ke !== rcKbMuatKe) return;
                    if (r.status !== 'success') throw new Error(r.message || 'Knowledge Management gagal dimuat');
                    Object.assign(rcKb.kelola, { rows: r.rows || [], peran: r.peran || [], jenisAda: r.jenisAda || [], regions: r.regions || [],
                        depots: r.depots || [], jumlahAktif: Number(r.jumlahAktif || 0), jumlahArsip: Number(r.jumlahArsip || 0) });
                    rcKb.pilih = new Set();
                    kbRenderKelola();
                } catch (e) {
                    if (ke !== rcKbMuatKe) return;
                    document.getElementById('kbKelolaBody').innerHTML = '<tr><td colspan="9" class="p-6 text-red-600">' + rcEsc(e.message) + '</td></tr>';
                    showNotification(e.message, 'error');
                } finally { hideLoadingOverlay(); }
            }

            function kbGantiMode(arsip) {
                if (rcKb.kelola.arsip === arsip) return;
                rcKb.kelola.arsip = arsip;
                kbMuatKelola();
            }

            function kbProgres(sudah, dibuka, target) {
                const ps = kbPersen(sudah, target), pb = kbPersen(Math.max(dibuka - sudah, 0), target);
                return '<div class="w-44"><div class="flex justify-between text-[11px] font-bold text-gray-700"><span>' + kbAngka(sudah) + ' / ' + kbAngka(target) + '</span><span class="' + (ps >= 100 ? 'text-emerald-600' : 'text-gray-500') + '">' + ps + '%</span></div>'
                    + '<div class="h-2 bg-red-100 rounded-full overflow-hidden flex mt-1"><div class="bg-emerald-500" style="width:' + ps + '%"></div><div class="bg-amber-400" style="width:' + pb + '%"></div></div>'
                    + '<span class="text-[10px] text-gray-400">' + kbAngka(Math.max(dibuka - sudah, 0)) + ' dibuka belum ack · ' + kbAngka(Math.max(target - dibuka, 0)) + ' belum dibuka</span></div>';
            }

            function kbRenderKelola() {
                const k = rcKb.kelola, body = document.getElementById('kbKelolaBody'); if (!body) return;
                const aktif = 'px-3 py-1.5 text-xs font-bold rounded-md bg-white shadow-sm text-teal-700', idle = 'px-3 py-1.5 text-xs font-bold rounded-md text-gray-500';
                const ma = document.getElementById('kbModeAktif'), mr = document.getElementById('kbModeArsip');
                if (ma) { ma.className = k.arsip ? idle : aktif; ma.innerText = 'Aktif (' + kbAngka(k.jumlahAktif) + ')'; }
                if (mr) { mr.className = k.arsip ? aktif : idle; mr.innerText = 'Arsip (' + kbAngka(k.jumlahArsip) + ')'; }

                // Ringkasan seluruh dokumen pada tampilan ini.
                const tot = k.rows.reduce((a, r) => ({ t: a.t + r.target, s: a.s + r.sudah, b: a.b + r.dibuka }), { t: 0, s: 0, b: 0 });
                const kartu = (label, nilai, sub, warna) => '<div class="bg-' + warna + '-50 border border-' + warna + '-100 rounded-xl p-4"><p class="text-[10px] font-black uppercase tracking-wider text-' + warna + '-700">' + label + '</p><p class="text-2xl font-black text-gray-800 mt-1">' + nilai + '</p><p class="text-[11px] text-gray-500">' + sub + '</p></div>';
                document.getElementById('kbKartu').innerHTML = kartu(k.arsip ? 'Dokumen diarsip' : 'Dokumen aktif', kbAngka(k.rows.length), k.arsip ? 'dapat dipulihkan' : kbAngka(k.rows.filter(r => r.pinAktif).length) + ' sedang di-pin', 'teal')
                    + kartu('Kewajiban acknowledge', kbAngka(tot.t), 'dokumen x akun peserta aktif', 'sky')
                    + kartu('Sudah acknowledge', kbAngka(tot.s), kbPersen(tot.s, tot.t) + '% dari kewajiban', 'emerald')
                    + kartu('Belum acknowledge', kbAngka(tot.t - tot.s), kbAngka(Math.max(tot.b - tot.s, 0)) + ' sudah dibuka', 'red');

                setTextSafely('kbBtnArsipTeks', k.arsip ? 'Pulihkan terpilih' : 'Arsipkan terpilih');
                const term = String((document.getElementById('kbKelolaCari') || {}).value || '').trim().toLowerCase();
                const rows = k.rows.filter(r => !term || [r.jenis, r.judul, r.deskripsi, r.url, r.pesertaTeks, r.wilayah].some(v => String(v || '').toLowerCase().includes(term)));
                if (!rows.length) {
                    body.innerHTML = '<tr><td colspan="9" class="p-8 text-center text-gray-500">' + (k.rows.length ? 'Tidak ada dokumen yang cocok.' : k.arsip ? 'Belum ada dokumen yang diarsip.' : 'Belum ada dokumen. Klik Tambah Dokumen.') + '</td></tr>';
                } else {
                    body.innerHTML = rows.map(r => {
                        const id = rcEsc(r.id), semua = r.wilayah === 'Semua wilayah';
                        return '<tr class="border-t border-gray-100 align-top ' + (r.pinAktif && !k.arsip ? 'bg-amber-50/40 hover:bg-amber-50' : 'hover:bg-gray-50') + '">'
                            + '<td class="p-3"><input type="checkbox" class="kb-pilih rounded" value="' + id + '" ' + (rcKb.pilih.has(r.id) ? 'checked ' : '') + 'onchange="kbPilih(this)"></td>'
                            + '<td class="p-3 whitespace-nowrap"><span class="bg-teal-50 text-teal-700 border border-teal-100 px-2 py-0.5 rounded-md font-bold">' + rcEsc(r.jenis) + '</span></td>'
                            + '<td class="p-3 min-w-[240px] max-w-[340px]"><span class="font-bold text-gray-800 break-words">' + rcEsc(r.judul) + '</span>'
                                + (r.versi > 1 ? ' <span class="text-[10px] font-black text-violet-600">v' + r.versi + '</span>' : '')
                                + (kbUrlAman(r.url) ? '<a href="' + rcEsc(r.url) + '" target="_blank" rel="noopener noreferrer" class="block text-teal-600 hover:underline break-all line-clamp-1" title="' + rcEsc(r.url) + '">' + rcEsc(r.url) + '</a>' : '')
                                + (r.deskripsi ? '<span class="block text-gray-400 line-clamp-2 break-words" title="' + rcEsc(r.deskripsi) + '">' + rcEsc(r.deskripsi) + '</span>' : '') + '</td>'
                            + '<td class="p-3">' + rcEsc(r.pesertaTeks) + '</td>'
                            + '<td class="p-3"><span class="' + (semua ? 'text-gray-500' : 'text-indigo-700 font-semibold') + '">' + rcEsc(r.wilayah) + '</span></td>'
                            + '<td class="p-3 whitespace-nowrap">' + (r.pinned ? '<span class="' + (r.pinAktif ? 'text-amber-600 font-bold' : 'text-gray-400') + '"><i class="fas fa-thumbtack mr-1"></i>' + rcEsc(r.pinTeks) + '</span>' : '<span class="text-gray-300">-</span>') + '</td>'
                            + '<td class="p-3">' + kbProgres(r.sudah, r.dibuka, r.target) + '</td>'
                            + '<td class="p-3 whitespace-nowrap text-gray-500">' + rcEsc(k.arsip ? r.diarsipPada : r.diubahPada) + '<span class="block text-[11px]">' + rcEsc(k.arsip ? (r.alasanArsip || '-') : r.diubahOleh) + '</span></td>'
                            + '<td class="p-3"><div class="flex justify-center gap-1.5">'
                            + '<button onclick="kbBukaDetail(\'' + id + '\')" class="px-2.5 py-1.5 rounded-lg border border-indigo-200 text-indigo-700 bg-indigo-50 hover:bg-indigo-100" title="Details"><i class="fas fa-chart-pie"></i></button>'
                            + (k.arsip
                                ? '<button onclick="kbArsip([\'' + id + '\'])" class="px-2.5 py-1.5 rounded-lg border border-emerald-200 text-emerald-700 bg-emerald-50 hover:bg-emerald-100 font-bold" title="Pulihkan"><i class="fas fa-rotate-left"></i></button>'
                                : '<button onclick="kbBukaForm(\'' + id + '\')" class="px-2.5 py-1.5 rounded-lg border border-sky-200 text-sky-700 bg-sky-50 hover:bg-sky-100" title="Ubah"><i class="fas fa-pen"></i></button>'
                                  + '<button onclick="kbArsip([\'' + id + '\'])" class="px-2.5 py-1.5 rounded-lg border border-red-200 text-red-600 bg-red-50 hover:bg-red-100" title="Arsipkan"><i class="fas fa-box-archive"></i></button>')
                            + '</div></td></tr>';
                    }).join('');
                }
                kbPerbaruiPilihan();
            }

            function kbPilih(cb) { if (cb.checked) rcKb.pilih.add(cb.value); else rcKb.pilih.delete(cb.value); kbPerbaruiPilihan(); }
            function kbPilihSemua(on) {
                document.querySelectorAll('#kbKelolaBody .kb-pilih').forEach(cb => { cb.checked = on; if (on) rcKb.pilih.add(cb.value); else rcKb.pilih.delete(cb.value); });
                kbPerbaruiPilihan();
            }
            function kbPerbaruiPilihan() {
                const n = rcKb.pilih.size, b = document.getElementById('kbBtnArsip');
                if (b) b.disabled = n === 0;
                setTextSafely('kbBtnArsipTeks', (rcKb.kelola.arsip ? 'Pulihkan' : 'Arsipkan') + ' terpilih' + (n ? ' (' + n + ')' : ''));
                const semua = document.getElementById('kbPilihSemua'), cbs = document.querySelectorAll('#kbKelolaBody .kb-pilih');
                if (semua) semua.checked = cbs.length > 0 && Array.from(cbs).every(c => c.checked);
            }
            function kbArsipTerpilih() { if (rcKb.pilih.size) kbArsip(Array.from(rcKb.pilih)); }

            function kbMintaAlasan(judul, pesan, tombol) {
                return new Promise(function (selesai) {
                    window.__kbAlasanSelesai = function (ok) {
                        const v = ok ? String((document.getElementById('kbAlasanIsi') || {}).value || '').trim() : null;
                        if (ok && v.length < 3) { showNotification('Alasan wajib diisi (minimal 3 karakter).', 'warning'); return; }
                        window.__kbAlasanSelesai = null; rcTutupDialog(); selesai(v);
                    };
                    rcDialog(judul, '<div class="space-y-3 text-sm"><p>' + rcEsc(pesan) + '</p>'
                        + '<textarea id="kbAlasanIsi" rows="3" maxlength="300" class="w-full px-3 py-2 border border-gray-300 rounded-lg" placeholder="Alasan (wajib)"></textarea>'
                        + '<div class="flex justify-end gap-2"><button type="button" onclick="window.__kbAlasanSelesai && window.__kbAlasanSelesai(false)" class="px-4 py-2 border border-gray-300 rounded-lg font-bold">Batal</button>'
                        + '<button type="button" onclick="window.__kbAlasanSelesai && window.__kbAlasanSelesai(true)" class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-bold">' + rcEsc(tombol) + '</button></div></div>');
                    setTimeout(function () { const el = document.getElementById('kbAlasanIsi'); if (el) el.focus(); }, 50);
                });
            }

            async function kbArsip(ids) {
                const arsip = !rcKb.kelola.arsip;
                let alasan = '';
                if (arsip) {
                    alasan = await kbMintaAlasan('Arsipkan Dokumen', ids.length + ' dokumen akan disembunyikan dari Knowledge Resources. Riwayat buka dan acknowledge tetap tersimpan; dokumen dapat dipulihkan dari tampilan Arsip.', 'Arsipkan');
                    if (alasan === null) return;
                } else if (!await showConfirmModal({ title: 'Pulihkan Dokumen', message: ids.length + ' dokumen akan tampil kembali di Knowledge Resources untuk pesertanya.', confirmText: 'Pulihkan', danger: false })) return;
                showLoadingOverlay(arsip ? 'Mengarsipkan dokumen...' : 'Memulihkan dokumen...');
                try {
                    const r = await fetchApp({ action: 'kbArsip', ids: ids, arsip: arsip, alasan: alasan });
                    if (r.status !== 'success') throw new Error(r.message || 'Gagal memproses dokumen.');
                    showNotification(r.message, 'success');
                } catch (e) { showNotification(e.message, 'error'); } finally { hideLoadingOverlay(); }
                kbMuatKelola(); kbPerbaruiBadge(true);
            }

            // ---------- Formulir Tambah / Ubah ----------
            function kbTanggalIso(d) { return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }

            function kbBukaForm(id) {
                const k = rcKb.kelola, r = id ? k.rows.find(x => x.id === id) : null;
                if (id && !r) { showNotification('Dokumen tidak ditemukan; segarkan daftar.', 'warning'); return; }
                const reg = new Set(r ? r.regions || [] : []), dep = new Set(r ? r.depotIds || [] : []), pes = new Set(r ? r.peserta || [] : []);
                const khusus = reg.size > 0 || dep.size > 0;
                const hari = new Date(), seminggu = new Date(Date.now() + 7 * 86400000);
                const masukan = 'w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-teal-500';
                const label = 'block text-xs font-bold text-gray-700 mb-1';
                rcDialog(r ? 'Ubah Dokumen' : 'Tambah Dokumen', '<div data-rc-dialog-wide class="space-y-4 text-sm">'
                    + '<div class="grid grid-cols-1 md:grid-cols-3 gap-4">'
                    + '<div><label class="' + label + '">Jenis <span class="text-red-500">*</span></label><input id="kbfJenis" list="kbfJenisList" maxlength="40" class="' + masukan + '" value="' + rcEsc(r ? r.jenis : '') + '" placeholder="SOP, Surat, Pricelist..."><datalist id="kbfJenisList">' + k.jenisAda.map(t => '<option value="' + rcEsc(t) + '">').join('') + '</datalist><p class="text-[11px] text-gray-400 mt-1">Menjadi tab di Knowledge Resources dan kalimat acknowledge.</p></div>'
                    + '<div class="md:col-span-2"><label class="' + label + '">Judul <span class="text-red-500">*</span></label><input id="kbfJudul" maxlength="150" class="' + masukan + '" value="' + rcEsc(r ? r.judul : '') + '" placeholder="mis. SOP Pengajuan Klaim Rebate 2026"></div>'
                    + '</div>'
                    + '<div><label class="' + label + '">Description</label><textarea id="kbfDesk" rows="3" maxlength="2000" class="' + masukan + '" placeholder="Ringkasan isi, siapa yang perlu tahu, tanggal berlaku, dll.">' + rcEsc(r ? r.deskripsi : '') + '</textarea></div>'
                    + '<div><label class="' + label + '">Link Dokumen <span class="text-red-500">*</span> <span class="font-normal text-gray-400">(hanya link, mis. PDF di Google Drive / SharePoint; file tidak diunggah)</span></label><input id="kbfUrl" type="url" maxlength="1000" class="' + masukan + '" value="' + rcEsc(r ? r.url : '') + '" placeholder="https://..." oninput="kbFormUrlBerubah()" data-asli="' + rcEsc(r ? r.url : '') + '"></div>'
                    + '<div class="bg-amber-50 border border-amber-100 rounded-lg p-3"><label class="flex items-center gap-2 cursor-pointer"><input type="checkbox" id="kbfPin" class="rounded text-amber-500" ' + (r && r.pinned ? 'checked ' : '') + 'onchange="kbFormPin()"><span><i class="fas fa-thumbtack text-amber-500 mr-1"></i><b>Pin dokumen ini ke atas</b></span></label>'
                    + '<div id="kbfPinTanggal" class="' + (r && r.pinned ? '' : 'hidden ') + 'flex flex-wrap items-center gap-2 mt-3 text-xs font-bold text-gray-700">Dari <input type="date" id="kbfPinDari" class="px-3 py-1.5 border border-gray-300 rounded-lg text-sm" value="' + rcEsc(r && r.pinDari ? r.pinDari : kbTanggalIso(hari)) + '">'
                    + ' s/d <input type="date" id="kbfPinSampai" class="px-3 py-1.5 border border-gray-300 rounded-lg text-sm" value="' + rcEsc(r && r.pinSampai ? r.pinSampai : kbTanggalIso(seminggu)) + '"><span class="font-normal text-gray-500">Di luar rentang ini dokumen tetap tampil, hanya tidak lagi di atas.</span></div></div>'
                    + '<fieldset class="border border-gray-200 rounded-xl p-4"><legend class="text-xs font-black px-1 text-gray-700">Peserta <span class="text-red-500">*</span></legend>'
                    + '<div class="flex flex-wrap gap-2">' + k.peran.map(p => '<label class="flex items-center gap-1.5 px-3 py-1.5 border border-gray-200 rounded-lg cursor-pointer hover:bg-teal-50"><input type="checkbox" class="kbf-peran rounded text-teal-600" value="' + rcEsc(p.kode) + '" ' + (pes.has(p.kode) ? 'checked' : '') + '><span class="font-bold">' + rcEsc(p.label) + '</span></label>').join('') + '</div>'
                    + '<div class="flex gap-3 mt-2 text-xs"><button type="button" onclick="kbFormPeranSemua(true)" class="text-teal-700 font-bold hover:underline">Pilih semua</button><button type="button" onclick="kbFormPeranSemua(false)" class="text-gray-500 font-bold hover:underline">Kosongkan</button></div></fieldset>'
                    + '<fieldset class="border border-gray-200 rounded-xl p-4"><legend class="text-xs font-black px-1 text-gray-700">Wilayah</legend>'
                    + '<div class="flex flex-wrap gap-4 mb-3"><label class="flex items-center gap-2 font-semibold"><input type="radio" name="kbfWilayah" value="semua" ' + (khusus ? '' : 'checked') + ' onchange="kbFormWilayah()"> Semua wilayah</label>'
                    + '<label class="flex items-center gap-2 font-semibold"><input type="radio" name="kbfWilayah" value="pilih" ' + (khusus ? 'checked' : '') + ' onchange="kbFormWilayah()"> Region / Depot tertentu</label></div>'
                    + '<div id="kbfWilayahPilih" class="' + (khusus ? '' : 'hidden ') + 'space-y-3">'
                    + '<p class="text-xs text-gray-500">Dokumen tampil untuk akun peserta yang jangkauan depotnya mencakup salah satu Region <b>atau</b> Depot yang dipilih.</p>'
                    + '<div><span class="' + label + '">Region</span><div class="flex flex-wrap gap-2">' + (k.regions.length ? k.regions.map(x => '<label class="flex items-center gap-1.5 px-3 py-1.5 border border-gray-200 rounded-lg cursor-pointer hover:bg-indigo-50"><input type="checkbox" class="kbf-region rounded text-indigo-600" value="' + rcEsc(x) + '" ' + (reg.has(x) ? 'checked ' : '') + 'onchange="kbFormRingkas()"><span class="font-bold">' + rcEsc(x) + '</span></label>').join('') : '<span class="text-xs text-gray-400">Belum ada region di Depot Master.</span>') + '</div></div>'
                    + '<div><div class="flex items-center justify-between gap-2 mb-1"><span class="' + label + ' mb-0">Depot</span><input id="kbfDepotCari" oninput="kbFormSaringDepot()" placeholder="Cari depot..." class="px-2 py-1 border border-gray-300 rounded-md text-xs w-44"></div>'
                    + '<div id="kbfDepotList" class="max-h-48 overflow-y-auto border border-gray-200 rounded-lg p-2 grid grid-cols-1 sm:grid-cols-2 gap-1">'
                    + k.depots.map(d => '<label class="kbf-depot-baris flex items-center gap-2 px-2 py-1 rounded hover:bg-indigo-50 cursor-pointer text-xs" data-cari="' + rcEsc((d.kode + ' ' + d.nama + ' ' + d.region).toLowerCase()) + '"><input type="checkbox" class="kbf-depot rounded text-indigo-600" value="' + rcEsc(d.id) + '" ' + (dep.has(d.id) ? 'checked ' : '') + 'onchange="kbFormRingkas()"><b>' + rcEsc(d.kode) + '</b><span class="truncate text-gray-600">' + rcEsc(d.nama) + '</span>' + (d.region ? '<span class="ml-auto text-[10px] text-gray-400">' + rcEsc(d.region) + '</span>' : '') + '</label>').join('')
                    + '</div></div>'
                    + '<p id="kbfRingkas" class="text-xs font-bold text-indigo-700"></p></div></fieldset>'
                    + (r ? '<label class="flex items-start gap-2 bg-violet-50 border border-violet-100 rounded-lg p-3 cursor-pointer"><input type="checkbox" id="kbfUlang" class="rounded text-violet-600 mt-0.5"><span><b>Minta seluruh peserta membuka dan acknowledge ulang</b> <span class="text-xs text-gray-500 block">Pakai bila isi dokumen berubah. Acknowledge sebelumnya tidak lagi dihitung (riwayatnya tetap di Log Activity). Otomatis tercentang bila link diganti.</span></span></label>' : '')
                    + '<div class="flex justify-end gap-2 pt-1"><button type="button" onclick="rcTutupDialog()" class="px-4 py-2 border border-gray-300 rounded-lg font-bold">Batal</button>'
                    + '<button type="button" id="kbfSimpan" onclick="kbSimpanForm(' + (r ? '\'' + rcEsc(r.id) + '\'' : 'null') + ')" class="px-5 py-2 bg-teal-600 hover:bg-teal-700 text-white rounded-lg font-bold"><i class="fas fa-save mr-1.5"></i>Simpan</button></div>'
                    + '</div>');
                kbFormRingkas();
                setTimeout(() => { const el = document.getElementById(r ? 'kbfJudul' : 'kbfJenis'); if (el) el.focus(); }, 50);
            }

            function kbFormPin() { setHiddenSafely('kbfPinTanggal', !document.getElementById('kbfPin').checked); }
            function kbFormPeranSemua(on) { document.querySelectorAll('.kbf-peran').forEach(e => { e.checked = on; }); }
            function kbFormUrlBerubah() {
                const u = document.getElementById('kbfUrl'), ulang = document.getElementById('kbfUlang');
                if (u && ulang && u.dataset.asli && String(u.value || '').trim() !== u.dataset.asli) ulang.checked = true;
            }
            function kbFormWilayah() {
                const pilih = (document.querySelector('input[name="kbfWilayah"]:checked') || {}).value === 'pilih';
                setHiddenSafely('kbfWilayahPilih', !pilih);
                kbFormRingkas();
            }
            function kbFormSaringDepot() {
                const t = String(document.getElementById('kbfDepotCari').value || '').trim().toLowerCase();
                document.querySelectorAll('#kbfDepotList .kbf-depot-baris').forEach(el => el.classList.toggle('hidden', !!t && !el.dataset.cari.includes(t)));
            }
            function kbFormNilai() {
                const pilih = (document.querySelector('input[name="kbfWilayah"]:checked') || {}).value === 'pilih';
                return {
                    regions: pilih ? Array.from(document.querySelectorAll('.kbf-region:checked')).map(e => e.value) : [],
                    depotIds: pilih ? Array.from(document.querySelectorAll('.kbf-depot:checked')).map(e => e.value) : [],
                    pilih: pilih
                };
            }
            function kbFormRingkas() {
                const v = kbFormNilai();
                setTextSafely('kbfRingkas', !v.pilih ? '' : (v.regions.length + ' region, ' + v.depotIds.length + ' depot dipilih'
                    + (v.regions.length + v.depotIds.length === 0 ? ' - pilih minimal satu, atau pilih Semua wilayah.' : '.')));
            }

            async function kbSimpanForm(id) {
                const nilai = idEl => String((document.getElementById(idEl) || {}).value || '').trim();
                const jenis = nilai('kbfJenis'), judul = nilai('kbfJudul'), url = nilai('kbfUrl');
                const pin = document.getElementById('kbfPin').checked, dari = nilai('kbfPinDari'), sampai = nilai('kbfPinSampai');
                const peserta = Array.from(document.querySelectorAll('.kbf-peran:checked')).map(e => e.value);
                const v = kbFormNilai();
                if (!jenis) { showNotification('Jenis wajib diisi (mis. SOP, Surat, Pricelist).', 'warning'); return; }
                if (!judul) { showNotification('Judul wajib diisi.', 'warning'); return; }
                if (!kbUrlAman(url)) { showNotification('Link harus diawali http:// atau https:// dan tanpa spasi.', 'warning'); return; }
                if (pin && (!dari || !sampai)) { showNotification('Isi tanggal pin Dari dan Sampai.', 'warning'); return; }
                if (pin && sampai < dari) { showNotification('Tanggal pin Sampai tidak boleh sebelum tanggal Dari.', 'warning'); return; }
                if (!peserta.length) { showNotification('Pilih minimal satu peserta.', 'warning'); return; }
                if (v.pilih && !v.regions.length && !v.depotIds.length) { showNotification('Pilih minimal satu Region atau Depot, atau pilih Semua wilayah.', 'warning'); return; }
                const ulang = !!(document.getElementById('kbfUlang') || {}).checked;
                if (ulang && !await showConfirmModal({ title: 'Minta Acknowledge Ulang', message: 'Seluruh peserta harus membuka dan acknowledge dokumen ini lagi. Lanjutkan?', confirmText: 'Ya, simpan', danger: false })) return;
                const tombol = document.getElementById('kbfSimpan'); if (tombol) tombol.disabled = true;
                try {
                    const r = await fetchApp({ action: 'kbSimpan', item: { id: id || '', jenis: jenis, judul: judul, deskripsi: nilai('kbfDesk'), url: url,
                        pinned: pin, pinDari: pin ? dari : '', pinSampai: pin ? sampai : '', peserta: peserta, regions: v.regions, depotIds: v.depotIds, bacaUlang: ulang } });
                    if (r.status !== 'success') throw new Error(r.message || 'Gagal menyimpan dokumen.');
                    rcTutupDialog(); showNotification(r.message, 'success');
                    rcKb.kelola.arsip = false;
                    kbMuatKelola(); kbPerbaruiBadge(true);
                } catch (e) { showNotification(e.message, 'error'); if (tombol) tombol.disabled = false; }
            }

            // ---------- Details / Analytics ----------
            function kbTutupDetail() {
                rcKb.detail = null;
                Object.values(rcKb.grafik).forEach(c => { try { c.destroy(); } catch (e) { /* abaikan */ } });
                rcKb.grafik = {};
                setHiddenSafely('kbDetail', true); setHiddenSafely('kbKelolaUtama', false);
            }

            async function kbBukaDetail(id) {
                const ke = ++rcKbMuatKe;
                showLoadingOverlay('Memuat Details...');
                try {
                    const r = await fetchApp({ action: 'kbDetail', id: id || null });
                    if (ke !== rcKbMuatKe) return;
                    if (r.status !== 'success') throw new Error(r.message || 'Details gagal dimuat');
                    rcKb.detail = Object.assign({ id: id || null }, r);
                    rcKb.akunTampil = 200;
                    setHiddenSafely('kbKelolaUtama', true); setHiddenSafely('kbDetail', false);
                    kbRenderDetail();
                } catch (e) { if (ke === rcKbMuatKe) showNotification(e.message, 'error'); } finally { hideLoadingOverlay(); }
            }

            const RC_KB_WARNA = { sudah: '#10b981', dibuka: '#f59e0b', belum: '#ef4444' };

            function kbGrafik(idKanvas, konfig) {
                if (rcKb.grafik[idKanvas]) { try { rcKb.grafik[idKanvas].destroy(); } catch (e) { /* abaikan */ } }
                const el = document.getElementById(idKanvas);
                if (!el || !window.Chart) return;
                rcKb.grafik[idKanvas] = new Chart(el.getContext('2d'), konfig);
            }

            function kbRenderDetail() {
                const d = rcKb.detail, host = document.getElementById('kbDetail'); if (!d || !host) return;
                const g = d.ringkas || {}, semua = !d.item;
                const kartu = (label, nilai, sub, warna) => '<div class="bg-' + warna + '-50 border border-' + warna + '-100 rounded-xl p-4"><p class="text-[10px] font-black uppercase tracking-wider text-' + warna + '-700">' + label + '</p><p class="text-2xl font-black text-gray-800 mt-1">' + nilai + '</p><p class="text-[11px] text-gray-500">' + sub + '</p></div>';
                const regions = (d.region || []).map(x => x.region).filter(x => x !== '-');
                const judul = semua
                    ? '<p class="text-[11px] font-black uppercase tracking-wider text-teal-700">Details</p><h3 class="text-xl font-extrabold text-gray-800">Semua dokumen aktif (' + kbAngka(g.dokumen) + ')</h3>'
                    : '<p class="text-[11px] font-black uppercase tracking-wider text-teal-700">Details · ' + rcEsc(d.item.jenis) + (d.item.versi > 1 ? ' · versi ' + d.item.versi : '') + (d.item.arsip ? ' · diarsip' : '') + '</p>'
                      + '<h3 class="text-xl font-extrabold text-gray-800 break-words">' + rcEsc(d.item.judul) + '</h3>'
                      + '<p class="text-xs text-gray-500 mt-1">Peserta: <b>' + rcEsc(d.item.pesertaTeks) + '</b> · Wilayah: <b>' + rcEsc(d.item.wilayah) + '</b> · Terbit ' + rcEsc(d.item.dibuat)
                      + (kbUrlAman(d.item.url) ? ' · <a href="' + rcEsc(d.item.url) + '" target="_blank" rel="noopener noreferrer" class="text-teal-600 hover:underline">Buka dokumen</a>' : '') + '</p>';
                host.innerHTML = '<div class="flex flex-wrap items-start justify-between gap-3 mb-5">'
                    + '<div class="flex items-start gap-3 min-w-0"><button onclick="kbTutupDetail();kbRenderKelola()" class="px-3 py-2 border border-gray-300 rounded-lg text-sm font-bold bg-white hover:bg-gray-50 shrink-0"><i class="fas fa-arrow-left mr-1.5"></i>Kembali</button><div class="min-w-0">' + judul + '</div></div>'
                    + '<button onclick="kbUnduhDetail()" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg text-sm font-bold shrink-0"><i class="fas fa-file-excel mr-1.5"></i>Unduh Excel</button></div>'
                    + '<div class="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-5">'
                    + kartu(semua ? 'Kewajiban acknowledge' : 'Peserta', kbAngka(g.target), semua ? kbAngka(g.akun) + ' akun peserta' : 'akun aktif', 'sky')
                    + kartu('Acknowledged', kbAngka(g.sudah), kbPersen(g.sudah, g.target) + '%', 'emerald')
                    + kartu('Dibuka, belum acknowledge', kbAngka(g.dibukaBelum), kbPersen(g.dibukaBelum, g.target) + '%', 'amber')
                    + kartu('Belum dibuka', kbAngka(g.belumDibuka), kbPersen(g.belumDibuka, g.target) + '%', 'red') + '</div>'
                    + (!g.target ? '<div class="text-center text-gray-500 py-10 border border-dashed border-gray-200 rounded-xl">Belum ada akun aktif yang menjadi peserta.</div>' :
                      '<div class="grid grid-cols-1 lg:grid-cols-3 gap-4 mb-5">'
                    + '<div class="border border-gray-200 rounded-xl p-4"><p class="text-sm font-black text-gray-700 mb-2">Status acknowledge</p><div class="h-64"><canvas id="kbGrStatus"></canvas></div></div>'
                    + '<div class="border border-gray-200 rounded-xl p-4"><p class="text-sm font-black text-gray-700 mb-2">Per region</p><div class="h-64"><canvas id="kbGrRegion"></canvas></div></div>'
                    + '<div class="border border-gray-200 rounded-xl p-4"><p class="text-sm font-black text-gray-700 mb-2">Depot dengan belum acknowledge terbanyak</p><div class="h-64"><canvas id="kbGrDepot"></canvas></div></div></div>'
                    + (semua ? '<div class="mb-5"><p class="text-sm font-black text-gray-700 mb-2">Per dokumen</p><div class="table-container border border-gray-200 rounded-xl overflow-x-auto max-h-80"><table class="w-full text-left text-xs"><thead class="bg-gray-50 text-gray-600 uppercase text-[11px] sticky top-0"><tr><th class="p-3">Jenis</th><th class="p-3">Judul</th><th class="p-3">Acknowledge</th><th class="p-3"></th></tr></thead><tbody>'
                        + (d.perItem || []).map(x => '<tr class="border-t border-gray-100"><td class="p-3 whitespace-nowrap font-bold text-teal-700">' + rcEsc(x.jenis) + '</td><td class="p-3 break-words">' + rcEsc(x.judul) + '</td><td class="p-3">' + kbProgres(x.sudah, x.sudah + x.dibukaBelum, x.target) + '</td>'
                            + '<td class="p-3"><button onclick="kbBukaDetail(\'' + rcEsc(x.id) + '\')" class="px-2.5 py-1.5 rounded-lg border border-indigo-200 text-indigo-700 bg-indigo-50 hover:bg-indigo-100" title="Details"><i class="fas fa-chart-pie"></i></button></td></tr>').join('')
                        + '</tbody></table></div></div>' : '')
                    + '<div class="mb-5"><p class="text-sm font-black text-gray-700 mb-2">Per depot <span class="font-normal text-xs text-gray-400">(akun dengan beberapa depot dihitung di setiap depotnya)</span></p>'
                    + '<div class="table-container border border-gray-200 rounded-xl overflow-x-auto max-h-96"><table class="w-full text-left text-xs"><thead class="bg-gray-50 text-gray-600 uppercase text-[11px] sticky top-0"><tr><th class="p-3">Depot</th><th class="p-3">Region</th><th class="p-3 text-right">Akun</th><th class="p-3 text-right">Kewajiban</th><th class="p-3 text-right">Acknowledged</th><th class="p-3 text-right">Dibuka, belum</th><th class="p-3 text-right">Belum dibuka</th><th class="p-3">Progres</th></tr></thead><tbody>'
                    + (d.depot || []).slice().sort((a, b) => (a.kode === '-') - (b.kode === '-') || (b.target - b.sudah) - (a.target - a.sudah) || String(a.kode).localeCompare(String(b.kode))).map(x => '<tr class="border-t border-gray-100 hover:bg-gray-50"><td class="p-3"><b>' + rcEsc(x.kode) + '</b> <span class="text-gray-500">' + rcEsc(x.kode === '-' ? 'Tanpa depot / System Manager' : x.nama) + '</span></td><td class="p-3">' + rcEsc(x.region) + '</td>'
                        + '<td class="p-3 text-right">' + kbAngka(x.akun) + '</td><td class="p-3 text-right">' + kbAngka(x.target) + '</td><td class="p-3 text-right text-emerald-700 font-bold">' + kbAngka(x.sudah) + '</td><td class="p-3 text-right text-amber-700">' + kbAngka(x.dibukaBelum) + '</td><td class="p-3 text-right text-red-600 font-bold">' + kbAngka(x.belumDibuka) + '</td>'
                        + '<td class="p-3">' + kbProgres(x.sudah, x.sudah + x.dibukaBelum, x.target) + '</td></tr>').join('')
                    + '</tbody></table></div></div>'
                    + '<div><div class="flex flex-wrap items-center gap-2 mb-2"><p class="text-sm font-black text-gray-700 mr-auto">Daftar akun</p>'
                    + '<select id="kbDetStatus" onchange="rcKb.akunTampil=200;kbRenderAkun()" class="px-3 py-1.5 border border-gray-300 rounded-lg text-xs"><option value="">Semua status</option><option value="belum">Belum acknowledge (semua)</option><option value="Belum dibuka">Belum dibuka</option><option value="Dibuka, belum acknowledge">Dibuka, belum acknowledge</option><option value="Acknowledged">Acknowledged</option></select>'
                    + '<select id="kbDetRegion" onchange="rcKb.akunTampil=200;kbRenderAkun()" class="px-3 py-1.5 border border-gray-300 rounded-lg text-xs"><option value="">Semua region</option>' + regions.map(x => '<option value="' + rcEsc(x) + '">Region ' + rcEsc(x) + '</option>').join('') + '</select>'
                    + '<input id="kbDetCari" oninput="rcKb.akunTampil=200;kbRenderAkun()" placeholder="Cari user, nama, depot..." class="px-3 py-1.5 border border-gray-300 rounded-lg text-xs w-52"></div>'
                    + '<div class="table-container border border-gray-200 rounded-xl overflow-x-auto"><table class="w-full text-left text-xs"><thead class="bg-gray-50 text-gray-600 uppercase text-[11px]"><tr><th class="p-3">User ID</th><th class="p-3">Nama</th><th class="p-3">Peran</th><th class="p-3">Depot</th><th class="p-3">Region</th>'
                    + (semua ? '<th class="p-3">Jenis</th><th class="p-3">Judul</th>' : '') + '<th class="p-3">Status</th><th class="p-3 whitespace-nowrap">Dibuka</th><th class="p-3 whitespace-nowrap">Acknowledged</th></tr></thead><tbody id="kbDetAkunBody"></tbody></table></div>'
                    + '<div id="kbDetAkunKaki" class="text-xs text-gray-500 mt-2"></div></div>');

                if (!g.target) return;
                kbGrafik('kbGrStatus', { type: 'doughnut', data: { labels: ['Acknowledged', 'Dibuka, belum acknowledge', 'Belum dibuka'],
                    datasets: [{ data: [g.sudah, g.dibukaBelum, g.belumDibuka], backgroundColor: [RC_KB_WARNA.sudah, RC_KB_WARNA.dibuka, RC_KB_WARNA.belum], borderWidth: 2, borderColor: '#fff' }] },
                    options: { responsive: true, maintainAspectRatio: false, cutout: '60%', plugins: { legend: { position: 'bottom', labels: { boxWidth: 12, font: { size: 10 } } },
                        tooltip: { callbacks: { label: c => c.label + ': ' + kbAngka(c.raw) + ' (' + kbPersen(c.raw, g.target) + '%)' } } } } });
                const susun = (rows, labelFn) => ({ labels: rows.map(labelFn), datasets: [
                    { label: 'Acknowledged', data: rows.map(x => x.sudah), backgroundColor: RC_KB_WARNA.sudah },
                    { label: 'Dibuka, belum', data: rows.map(x => x.dibukaBelum), backgroundColor: RC_KB_WARNA.dibuka },
                    { label: 'Belum dibuka', data: rows.map(x => x.belumDibuka), backgroundColor: RC_KB_WARNA.belum }] });
                const opsiBatang = { responsive: true, maintainAspectRatio: false, indexAxis: 'y',
                    plugins: { legend: { position: 'bottom', labels: { boxWidth: 12, font: { size: 10 } } } },
                    scales: { x: { stacked: true, beginAtZero: true, ticks: { precision: 0 } }, y: { stacked: true, grid: { display: false }, ticks: { font: { size: 10 } } } } };
                kbGrafik('kbGrRegion', { type: 'bar', data: susun(d.region || [], x => x.region === '-' ? 'Tanpa region' : 'Region ' + x.region), options: opsiBatang });
                const top = (d.depot || []).filter(x => x.kode !== '-' && x.target - x.sudah > 0).sort((a, b) => (b.target - b.sudah) - (a.target - a.sudah)).slice(0, 10);
                kbGrafik('kbGrDepot', { type: 'bar', data: susun(top, x => x.kode === '-' ? 'Tanpa depot' : x.kode), options: JSON.parse(JSON.stringify(opsiBatang)) });
                kbRenderAkun();
            }

            function kbAkunTersaring() {
                const d = rcKb.detail; if (!d) return [];
                const st = String((document.getElementById('kbDetStatus') || {}).value || ''), rg = String((document.getElementById('kbDetRegion') || {}).value || '');
                const t = String((document.getElementById('kbDetCari') || {}).value || '').trim().toLowerCase();
                return (d.akun || []).filter(a => (!st || (st === 'belum' ? a.status !== 'Acknowledged' : a.status === st))
                    && (!rg || String(a.region || '').split(', ').includes(rg))
                    && (!t || [a.userCode, a.nama, a.depot, a.peran, a.judul].some(v => String(v || '').toLowerCase().includes(t))));
            }

            function kbRenderAkun() {
                const body = document.getElementById('kbDetAkunBody'); if (!body) return;
                const semua = !rcKb.detail.item, rows = kbAkunTersaring(), tampil = rows.slice(0, rcKb.akunTampil);
                const chip = s => s === 'Acknowledged' ? 'bg-emerald-100 text-emerald-700' : s === 'Belum dibuka' ? 'bg-red-100 text-red-700' : 'bg-amber-100 text-amber-800';
                body.innerHTML = tampil.length ? tampil.map(a => '<tr class="border-t border-gray-100 hover:bg-gray-50"><td class="p-3 font-bold whitespace-nowrap">' + rcEsc(a.userCode) + '</td><td class="p-3">' + rcEsc(a.nama) + '</td><td class="p-3 whitespace-nowrap">' + rcEsc(a.peran) + '</td>'
                    + '<td class="p-3">' + rcEsc(a.depot) + '</td><td class="p-3">' + rcEsc(a.region) + '</td>'
                    + (semua ? '<td class="p-3 whitespace-nowrap">' + rcEsc(a.jenis) + '</td><td class="p-3">' + rcEsc(a.judul) + '</td>' : '')
                    + '<td class="p-3"><span class="' + chip(a.status) + ' px-2 py-0.5 rounded-md text-[10px] font-black uppercase whitespace-nowrap">' + rcEsc(a.status) + '</span></td>'
                    + '<td class="p-3 whitespace-nowrap text-gray-500">' + rcEsc(a.dibukaPada || '-') + '</td><td class="p-3 whitespace-nowrap text-gray-500">' + rcEsc(a.ackPada || '-') + '</td></tr>').join('')
                    : '<tr><td colspan="' + (semua ? 10 : 8) + '" class="p-6 text-center text-gray-500">Tidak ada akun yang cocok.</td></tr>';
                const kaki = document.getElementById('kbDetAkunKaki');
                if (kaki) kaki.innerHTML = kbAngka(tampil.length) + ' dari ' + kbAngka(rows.length) + ' baris'
                    + (rows.length > tampil.length ? ' · <button onclick="rcKb.akunTampil+=500;kbRenderAkun()" class="text-teal-700 font-bold hover:underline">Tampilkan 500 lagi</button>' : '')
                    + (rcKb.detail.akunTerpotong ? ' · <span class="text-red-600">Daftar dibatasi 20.000 baris pertama (urut belum acknowledge lebih dulu).</span>' : '');
            }

            // Unduhan = isi layar Details: daftar akun sesuai saringan, per depot, per region (dan per dokumen).
            function kbUnduhDetail() {
                const d = rcKb.detail; if (!d || !window.XLSX) return;
                const semua = !d.item, akun = kbAkunTersaring();
                const wb = XLSX.utils.book_new();
                const lembar = (nama, aoa) => {
                    const ws = XLSX.utils.aoa_to_sheet(aoa);
                    ws['!cols'] = aoa[0].map(h => ({ wch: Math.max(12, Math.min(48, String(h).length + 6)) }));
                    XLSX.utils.book_append_sheet(wb, ws, nama);
                };
                lembar('Akun', [['User ID', 'Nama', 'Peran', 'Depot', 'Region'].concat(semua ? ['Jenis', 'Judul'] : [], ['Status', 'Dibuka', 'Acknowledged'])]
                    .concat(akun.map(a => [String(a.userCode), a.nama, a.peran, a.depot, a.region].concat(semua ? [a.jenis, a.judul] : [], [a.status, a.dibukaPada || '-', a.ackPada || '-']))));
                lembar('Per Depot', [['Depot', 'Nama Depot', 'Region', 'Akun', 'Kewajiban', 'Acknowledged', 'Dibuka, belum acknowledge', 'Belum dibuka', '% Acknowledged']]
                    .concat((d.depot || []).map(x => [String(x.kode), x.kode === '-' ? 'Tanpa depot' : x.nama, x.region, x.akun, x.target, x.sudah, x.dibukaBelum, x.belumDibuka, kbPersen(x.sudah, x.target)])));
                lembar('Per Region', [['Region', 'Kewajiban', 'Acknowledged', 'Dibuka, belum acknowledge', 'Belum dibuka', '% Acknowledged']]
                    .concat((d.region || []).map(x => [String(x.region), x.target, x.sudah, x.dibukaBelum, x.belumDibuka, kbPersen(x.sudah, x.target)])));
                if (semua) lembar('Per Dokumen', [['Jenis', 'Judul', 'Kewajiban', 'Acknowledged', 'Dibuka, belum acknowledge', '% Acknowledged']]
                    .concat((d.perItem || []).map(x => [x.jenis, x.judul, x.target, x.sudah, x.dibukaBelum, kbPersen(x.sudah, x.target)])));
                const nama = semua ? 'Semua' : String(d.item.judul).replace(/[^A-Za-z0-9]+/g, '_').slice(0, 40);
                XLSX.writeFile(wb, 'Knowledge_Base_' + nama + '_' + kbTanggalIso(new Date()) + '.xlsx');
                showNotification(kbAngka(akun.length) + ' baris akun diunduh.', 'success');
            }
