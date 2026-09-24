            let mRegistrationOptions = null;
            let mRegistrationSubmitting = false;
            let mAccessLoadSequence = 0;
            // ============================================================================
            // ACCESS MANAGEMENT: MENGUBAH HANYA SUPERVISOR DAN SYSTEM MANAGER
            // ============================================================================
            // Keputusan pemilik: "modul acces management itu hanya spv dan system manager
            // sisanya hanya viewer".
            //
            // Server sudah menjaganya - rc_update_access, rc_review_pin, penghapusan akun dan
            // seluruh tulisan lain melewati rc_private.is_manager(), yang hanya mengakui kedua
            // peran itu. Yang ditambahkan di sini BUKAN penjagaan kedua, melainkan kejujuran
            // layar: tanpa ini, seorang viewer melihat tombol yang tampak dapat ditekan, menekan
            // sepuluh kali, dan setiap kali menerima pesan "Access denied" tanpa tahu sebabnya.
            //
            // Karena penjagaannya di server, membobol yang di layar tidak menghasilkan apa pun.
            function mBolehUbah() {
                const peran = String((currentUserData && (currentUserData.sysRole || currentUserData.role)) || '').toLowerCase();
                return peran === 'supervisor' || peran === 'system manager';
            }

            // Mengunci seluruh kendali yang MENGUBAH di dalam modul, dan membiarkan yang membaca.
            // Dicari dari isinya - tombol, isian, pilihan - bukan dari daftar id yang harus
            // diingat dan pasti tertinggal ketika kendali berikutnya ditambahkan.
            function mTerapkanViewer() {
                const boleh = mBolehUbah();
                setHiddenSafely('mViewerCatatan', boleh);

                const modul = document.getElementById('modManage');
                if (!modul) return;

                modul.querySelectorAll('button, input, select, textarea').forEach(function (el) {
                    // Tab, pencarian dan penyaring tetap hidup: ketiganya membaca, tidak mengubah.
                    if (el.id && /^mTab/.test(el.id)) return;
                    if (el.type === 'search') return;
                    if (el.dataset && el.dataset.rcBaca === '1') return;

                    if (boleh) {
                        if (el.dataset && el.dataset.rcTerkunci === '1') {
                            el.disabled = false;
                            el.classList.remove('opacity-50', 'cursor-not-allowed');
                            delete el.dataset.rcTerkunci;
                        }
                    } else {
                        el.disabled = true;
                        el.classList.add('opacity-50', 'cursor-not-allowed');
                        if (el.dataset) el.dataset.rcTerkunci = '1';
                    }
                });
            }

            async function fetchManageableData() {
                const sequence = ++mAccessLoadSequence;
                // Dipasang lebih dulu supaya kendali yang sudah ada terkunci sejak sebelum data
                // datang, lalu dipasang lagi di bawah untuk baris yang baru digambar.
                mTerapkanViewer();
                showLoadingOverlay("Memuat Data Pengguna...");
                try {
                    let role = currentUserData.sysRole || currentUserData.role || '';
                    let res = await fetchApp({ action: 'getManageableData', requesterId: currentUserData.userId, requesterRole: role });
                    if (sequence !== mAccessLoadSequence) return false;
                    if (res.status === 'success') { 
                        mRegistrationOptions = res.registrationOptions || null;
                        currentManageableUsers = res.users || []; 
                        let rawDepots = (role === 'system manager' || role === 'supervisor') ? res.allDepots : res.managedDepots;
                        globalDepotList = [];
                        (rawDepots || []).forEach(d => { 
                            if (typeof d === 'object') globalDepotList.push({ kode: d.kode || d.kodeDepot || '', nama: d.nama || d.depotName || '', link: d.link || '' }); 
                            else if (typeof d === 'string') { 
                                if (d.includes('-')) { let parts = d.split('-'); globalDepotList.push({ kode: parts[0].trim(), nama: parts[1].trim(), link: '' }); } 
                                else globalDepotList.push({ kode: d.trim(), nama: d.trim(), link: '' }); 
                            } 
                        });
                        globalDepotList = globalDepotList.filter((v, i, a) => a.findIndex(t => (t.kode === v.kode)) === i);
                        globalDepotList.sort((a, b) => a.kode.localeCompare(b.kode));
                        renderManageAccessCards(); renderProfileRequestsList(res.profileRequests || []);
                        mTerapkanViewer();
                        return true; 
                    }
                } catch (e) { showNotification("Gagal memuat Data Access Management.", "error"); return false; } finally { hideLoadingOverlay(); mTerapkanViewer(); }
                showNotification("Data Access Management belum berhasil dimuat. Tekan Segarkan Data.", "error");
                return false;
            }

            function renderProfileRequestsList(requests) {
                globalProfileRequests = requests || []; let cont = document.getElementById('mReqProfil');
                if (globalProfileRequests.length === 0) {
                    cont.innerHTML = `<div class="flex flex-col items-center justify-center py-20 text-center"><div class="w-24 h-24 bg-gray-100 rounded-full flex items-center justify-center mb-6"><i class="fas fa-inbox text-5xl text-gray-300"></i></div><h3 class="text-xl font-bold text-gray-800 mb-2">Kotak Masuk Bersih</h3><p class="text-gray-500 text-sm max-w-md mx-auto">Saat ini belum ada permohonan perubahan profil depot atau pendaftaran akun dari bawahan Anda.</p><button data-rc-baca="1" onclick="fetchManageableData()" class="mt-8 bg-white border border-gray-300 hover:bg-gray-50 text-gray-700 font-bold py-2 px-6 rounded-lg shadow-sm transition"><i class="fas fa-sync-alt mr-2 text-blue-500"></i> Cek Ulang Server</button></div>`;
                    let badg = document.getElementById('mTabReq').querySelector('.absolute'); if (badg) badg.classList.add('hidden'); return;
                }
                let badg = document.getElementById('mTabReq').querySelector('.absolute'); if (badg) badg.classList.remove('hidden');

                let html = `<div class="mb-5 flex justify-between items-center"><h2 class="text-xl font-bold text-gray-800"><i class="fas fa-file-signature text-orange-500 mr-2"></i> Approval Request User dan Profil</h2></div><div class="space-y-4">`;
                globalProfileRequests.forEach((req) => {
                    let diffHtml = '';
                    if (req.changes) { for (let key in req.changes) { diffHtml += `<div class="bg-white p-2 rounded border border-gray-100 flex justify-between text-sm"><span class="font-bold text-gray-600 capitalize">${rcEsc(key)}</span> <span class="font-medium text-blue-700">${rcEsc(req.changes[key])}</span></div>`; } }
                    html += `<div class="bg-gray-50 border border-gray-200 rounded-xl shadow-sm overflow-hidden flex flex-col md:flex-row"><div class="bg-orange-100 p-4 md:w-48 flex flex-col justify-center items-center border-b md:border-b-0 md:border-r border-orange-200"><div class="text-xs uppercase font-black text-orange-800 mb-1 tracking-widest text-center">Req ID: ${req.id}</div><div class="w-12 h-12 bg-white rounded-full flex items-center justify-center text-orange-500 text-xl shadow-sm my-2"><i class="fas fa-building"></i></div><div class="text-center font-bold text-orange-900">${rcEsc(req.namaDepot)}</div><div class="text-[10px] text-orange-700 mt-1">${rcEsc(req.tglRequest)}</div></div><div class="p-5 flex-1 bg-white"><h4 class="text-xs uppercase font-bold text-gray-400 tracking-wider mb-2">Request dari: <span class="text-gray-800">${rcEsc(req.requesterId)}</span></h4><div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2 mb-4">${diffHtml}</div><div class="flex gap-3 mt-4 pt-4 border-t border-gray-100"><button onclick="processProfileReq('${req.id}', 'rejected', this)" class="px-4 py-2 bg-white hover:bg-red-50 text-red-600 border border-red-200 hover:border-red-300 font-bold rounded-lg text-sm transition">Reject Request</button><button onclick="processProfileReq('${req.id}', 'approved', this)" class="px-6 py-2 bg-pink-500 hover:bg-pink-600 text-white font-bold rounded-lg text-sm shadow flex items-center transition"><i class="fas fa-check mr-2"></i> Approve Request</button></div></div></div>`;
                });
                html += `</div>`; cont.innerHTML = html;
            }

            async function processProfileReq(reqId, status, btn) {
                let origText = btn.innerHTML; btn.innerHTML = '<div class="loader w-4 h-4 border-2 border-t-transparent mx-auto"></div>'; btn.disabled = true;
                try {
                    let role = currentUserData.sysRole || currentUserData.role || '';
                    let res = await fetchApp({ action: 'approveProfileRequest', reqId: reqId, status: status, approverId: currentUserData.userId, approverRole: role });
                    if (res.status === 'success') { showNotification(res.message || "Request berhasil diproses.", "success"); logActivity('Approve/Reject profil request ID:' + reqId + ' status:' + status); fetchManageableData(); } 
                    else { showNotification(res.message, "error"); btn.innerHTML = origText; btn.disabled = false; }
                } catch (e) { showNotification("Gagal memproses.", "error"); btn.innerHTML = origText; btn.disabled = false; }
            }

            function renderManageAccessCards() {
                let tb = document.getElementById('manageGridBody'); if (!tb) return;
                let sv = (document.getElementById('manageSearch')?.value || "").toLowerCase();
                let filtered = currentManageableUsers.filter(u => (!sv || u.userId.toLowerCase().includes(sv) || (u.namaLengkap || '').toLowerCase().includes(sv) || (u.email || '').toLowerCase().includes(sv) || (u.depotName || '').toLowerCase().includes(sv)));

                if (filtered.length === 0) { tb.innerHTML = `<tr><td colspan="7" class="p-8 text-center text-gray-500 font-medium">Tidak ada pengguna yang ditemukan.</td></tr>`; return; }

                let rowsHtml = '';
                filtered.forEach((u, i) => {
                    let sysR = (u.sysRole || u.role || '').toLowerCase();
                    let roleColor = sysR === 'system manager' ? 'bg-black text-white' : (sysR === 'supervisor' ? 'bg-purple-100 text-purple-700' : 'bg-blue-100 text-blue-700');
                    let actStr = (u.activation || '').toLowerCase();
                    let isAct = (actStr === 'active' || actStr === 'approved' || actStr === 'ok');
                    let actLabel = actStr === 'suspended' ? 'Suspended' : (actStr === 'disabled' ? 'Disabled' : (actStr === 'inactive' ? 'Inactive' : (isAct ? 'Aktif' : 'Nonaktif')));
                    let actColor = isAct ? 'text-green-600' : 'text-red-600';
                    let reqPinHtml = u.pinStatus === 'pending' ? `<span class="px-2 py-0.5 text-[9px] bg-orange-500 text-white rounded font-bold ml-2 animate-pulse uppercase tracking-wider">Req PIN</span>` : '';
                    // Menghapus akun adalah wewenang System Manager saja, dan tidak berlaku
                    // untuk akunnya sendiri - server menolaknya juga, tetapi tombol yang pasti
                    // ditolak sebaiknya memang tidak ditampilkan.
                    let bolehHapus = (currentUserData.sysRole || currentUserData.role || '').toLowerCase() === 'system manager'
                        && String(u.userId) !== String(currentUserData.userId);

                    rowsHtml += `<tr class="hover:bg-blue-50 border-b border-gray-100"><td class="p-2 text-center whitespace-nowrap"><button type="button" data-userid="${rcEsc(u.userId)}" onclick="openEditModal(this.getAttribute('data-userid'))" class="bg-white hover:bg-blue-50 text-blue-600 font-bold border border-blue-200 px-3 py-1.5 rounded-lg shadow-sm transition"><i class="fas fa-edit mr-1"></i> Kelola</button>${bolehHapus ? `<button type="button" data-userid="${rcEsc(u.userId)}" onclick="hapusAkun(this.getAttribute('data-userid'))" title="Hapus akun" class="ml-1 bg-white hover:bg-red-50 text-red-600 font-bold border border-red-200 px-3 py-1.5 rounded-lg shadow-sm transition"><i class="fas fa-user-slash"></i></button>` : ''}</td><td class="p-2 font-black text-gray-800 text-sm">${rcEsc(u.userId)}</td><td class="p-2 font-bold text-gray-700 text-sm">${rcEsc(u.namaLengkap || '-')}</td><td class="p-2 text-center"><span class="px-2 py-0.5 text-[9px] uppercase font-black rounded ${roleColor} inline-block shadow-sm border border-gray-200">${rcEsc(u.activation === 'Pending' ? (u.requestedRole || u.role) : u.role)}</span></td><td class="p-2 text-gray-600 text-xs">${rcEsc(u.email || '-')}</td><td class="p-2 text-sm"><span class="font-bold text-gray-800">${rcEsc(u.kodeDepot)}</span> - ${rcEsc(u.depotName || '-')}</td><td class="p-2 text-center font-bold ${actColor} text-xs">${actLabel} ${reqPinHtml}</td></tr>`;
                });
                tb.innerHTML = rowsHtml;
            }

            // Menghapus akun.
            //
            // Server memilih sendiri caranya menurut jejak akunnya: yang belum pernah bekerja
            // benar-benar dihapus, yang namanya sudah menempel pada dokumen ditinggalkan sebagai
            // nisan - login mati, izin dan depot dilepas, hilang dari daftar - supaya riwayat
            // "Process by" pada dokumen lama tidak mendadak kosong. Karena itu layar tidak
            // menjanjikan salah satunya; yang ditampilkan adalah jawaban server.
            async function hapusAkun(userIdToDelete) {
                const u = currentManageableUsers.find(x => String(x.userId) === String(userIdToDelete));
                if (!u) return;
                const setuju = await showConfirmModal({
                    title: 'Hapus Akun ' + userIdToDelete,
                    message: (u.namaLengkap || userIdToDelete) + ' tidak akan dapat masuk lagi, seluruh izin dan '
                        + 'depotnya dilepas, dan akunnya hilang dari daftar ini. Jejak pekerjaannya pada dokumen '
                        + 'tetap tersimpan atas namanya. User ID "' + userIdToDelete + '" bebas dipakai lagi setelah ini.',
                    confirmText: 'Ya, Hapus Akun', danger: true
                });
                if (!setuju) return;
                const alasan = window.prompt('Alasan penghapusan (tercatat di Log Activity):', '') || '';
                if (!alasan.trim()) { showNotification('Penghapusan akun memerlukan alasan.', 'warning'); return; }

                showLoadingOverlay('Menghapus akun...');
                try {
                    const res = await fetchApp({ action: 'accountDelete', userId: userIdToDelete, alasan: alasan });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal menghapus akun.', 'error'); return; }
                    showNotification(res.message, 'success');
                    logActivity('Hapus akun ' + userIdToDelete + ' (' + res.cara + '): ' + alasan);
                    fetchManageableData();
                } catch (e) { showNotification((e && e.message) || 'Gagal menghapus akun.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            async function openEditModal(userIdToEdit) {
                const u = currentManageableUsers.find(x => String(x.userId) === String(userIdToEdit));
                if (!u) return;
                const aku = currentUserData.sysRole || currentUserData.role || '';
                const akuSM = aku === 'system manager';

                document.getElementById('editUserId').value = u.userId;
                document.getElementById('editUserDisplay').innerText = u.userId;
                document.getElementById('editIdentityName').innerText = u.namaLengkap || u.nama || u.userId;
                document.getElementById('editRoleDisplay').innerText = `Role: ${u.role}`;

                const a = u.auth || {};
                document.getElementById('editActivation').value = (a.i === 'Active' || a.i === 'Inactive') ? a.i : 'Active';
                document.getElementById('editSuffix').value = u.suffix || '';
                document.getElementById('editFullName').value = u.namaLengkap || u.nama || '';
                document.getElementById('editEmail').value = u.email || '';

                // Hak modul seluruhnya dirender dari katalog server, jadi tidak ada lagi daftar
                // modul yang ditulis tangan di markup dan bisa ketinggalan zaman. Ditunggu sampai
                // selesai: bila modal sempat terbuka sebelum matriksnya ada, menekan Simpan akan
                // mengirim matriks kosong dan menghapus seluruh hak pengguna itu.
                document.getElementById('editModuleMatrix').innerHTML =
                    '<p class="text-xs text-gray-400">Memuat daftar modul...</p>';
                await renderPermissionMatrix(u);

                // Peran System Manager hanya boleh diberikan oleh System Manager. Opsinya
                // ditambahkan di sini, bukan di markup, supaya seorang supervisor tidak pernah
                // melihat pilihan yang pasti ditolak server.
                const roleSel = document.getElementById('editRoleInput');
                const opsiSM = roleSel.querySelector('option[value="system manager"]');
                if (akuSM && !opsiSM) roleSel.insertAdjacentHTML('beforeend', '<option value="system manager">System Manager</option>');
                if (!akuSM && opsiSM) opsiSM.remove();
                setHiddenSafely('editRoleContainer', !(akuSM || aku === 'supervisor'));
                roleSel.value = String(u.sysRole || u.role || 'admin').toLowerCase();

                // Depot asal.
                const depotSel = document.getElementById('editHomeDepot');
                depotSel.innerHTML = '<option value="">-- Tanpa depot --</option>'
                    + globalDepotList.map(d => `<option value="${rcEsc(d.kode)}">${rcEsc(d.kode)} - ${rcEsc(d.nama)}</option>`).join('');
                depotSel.value = u.kodeDepot || '';

                document.getElementById('editEffectiveDepots').innerText =
                    (u.depotCodes && u.depotCodes.length) ? u.depotCodes.join(', ') : 'Belum ada depot';

                // Menyunting diri sendiri hanya menyentuh identitas. Bagian lain disembunyikan
                // supaya tidak ada yang mengisi kolom yang pasti diabaikan server - dan supaya
                // jelas mengapa: peran, hak modul dan yurisdiksi sendiri memang tidak boleh
                // diubah dari sini, karena satu kesalahan akan mengunci Anda keluar.
                const diriSendiri = String(u.userId) === String(currentUserData.userId);
                setHiddenSafely('editSelfNote', !diriSendiri);
                setHiddenSafely('editModuleMatrixContainer', diriSendiri);
                setHiddenSafely('editRoleContainer', diriSendiri || !(akuSM || aku === 'supervisor'));
                setHiddenSafely('approvePinContainer', true);
                if (diriSendiri) {
                    setHiddenSafely('editSpvSection', true);
                } else {
                    applyJurisdictionVisibility(u);
                }

                const pinPending = u.pinStatus === 'pending' || u.mustChangePin === true;
                setHiddenSafely('approvePinContainer', !pinPending);
                if (pinPending) {
                    document.getElementById('editApprovePin').checked = false;
                    document.getElementById('editPinReason').innerText = u.pinReason || 'Pengguna mengajukan penggantian PIN.';
                }
                setHiddenSafely('editAccessModal', false);
            }

            // Bentuk yurisdiksi mengikuti peran yang sedang dipilih, bukan peran yang tersimpan,
            // supaya mengubah peran langsung memperlihatkan kolom yang relevan.
            // async sejak daftar region diambil dari server. Pemanggilnya tidak menunggu:
            // kotak lain sudah tampil lebih dulu, dan kotak region menyusul begitu
            // pilihannya datang - menahan seluruh dialog demi satu dropdown tidak sepadan.
            async function applyJurisdictionVisibility(u) {
                const aku = currentUserData.sysRole || currentUserData.role || '';
                const bolehAturYurisdiksi = (aku === 'system manager' || aku === 'supervisor');
                const peran = String(document.getElementById('editRoleInput').value || u.sysRole || u.role || '').toLowerCase();

                // System Manager memperoleh seluruh depot lewat perannya; yurisdiksi tidak berlaku.
                const sembunyikanSemua = !bolehAturYurisdiksi || peran === 'system manager';
                setHiddenSafely('editSpvSection', sembunyikanSemua);
                if (sembunyikanSemua) return;

                const opsiDepot = globalDepotList.map(x => ({ label: `${x.kode} - ${x.nama}`, value: x.kode }));

                setHiddenSafely('editAssignOscContainer', peran !== 'supervisor');
                if (peran === 'supervisor') {
                    const oscOpts = currentManageableUsers.filter(x => x.sysRole === 'osc').map(x => ({ label: x.userId, value: x.userId }));
                    document.getElementById('editAssignOscDrop').innerHTML = buildMultiselectHTML(oscOpts, false, 'editAssignOscDrop');
                    tandaiTerpilih('editAssignOscDrop', u.assignedOsc, 'editAssignOscContainer');
                }

                setHiddenSafely('editAssignDepotContainer', !(['osc','others','finance','depot head','supervisor','management'].includes(peran)));
                if (['osc','others','finance','depot head','supervisor','management'].includes(peran)) {
                    document.getElementById('editAssignDepotDrop').innerHTML = buildMultiselectHTML(opsiDepot, true, 'editAssignDepotDrop');
                    tandaiTerpilih('editAssignDepotDrop', u.assignedDepots, 'editAssignDepotContainer');
                }

                // Management dapat memakai area depot langsung atau tambahan region.
                // Pilihannya diambil dari Depot Master lewat rc_region_list, jadi tidak ada
                // daftar region kedua yang harus dipelihara dan lama-lama menyimpang darinya.
                setHiddenSafely('editAssignRegionContainer', peran !== 'management');
                if (peran === 'management') {
                    let opsiRegion = [];
                    try {
                        const rr = await fetchApp({ action: 'regionList' });
                        opsiRegion = (rr.rows || []).map(x => ({
                            label: x.region + ' (' + x.jumlahDepot + ' depot)', value: x.region
                        }));
                    } catch (e) { opsiRegion = []; }
                    document.getElementById('editAssignRegionDrop').innerHTML =
                        opsiRegion.length
                            ? buildMultiselectHTML(opsiRegion, false, 'editAssignRegionDrop')
                            : '<p class="p-3 text-xs text-gray-500">Belum ada Region terisi pada Depot Master. '
                              + 'Isi kolom Region di Key Master &rarr; Depot Master lebih dulu.</p>';
                    if (opsiRegion.length) tandaiTerpilih('editAssignRegionDrop', u.regions, 'editAssignRegionContainer');
                }

                setHiddenSafely('editRpContainer', peran !== 'admin');
                if (peran === 'admin') {
                    document.getElementById('editRpDrop').innerHTML = buildMultiselectHTML(opsiDepot, true, 'editRpDrop');
                    tandaiTerpilih('editRpDrop', u.rpDepots, 'editRpContainer');
                }
            }

            function tandaiTerpilih(dropId, nilai, containerId) {
                const host = document.getElementById(dropId);
                if (!host) return;
                const dipilih = Array.isArray(nilai) ? nilai : [];
                host.querySelectorAll('.single-cb').forEach(c => { c.checked = dipilih.includes(c.value); });
                const span = document.getElementById(containerId) && document.getElementById(containerId).querySelector('button span');
                if (span) updateMultiSelectLabel(dropId, span);
            }
            function closeEditModal() { setHiddenSafely('editAccessModal', true); }

            async function saveUserAccess() {
                setHiddenSafely('saveAccessLoader', false); setDisabledSafely('btnSaveAccess', true);
                try {
                    // Penjagaan terpenting di layar ini. Matriks hak modul dirender secara
                    // asinkron dari katalog server; bila karena satu dan lain hal ia belum ada,
                    // rcMatrixValues() mengembalikan objek kosong dan penyimpanan akan MENCABUT
                    // seluruh hak modul pengguna itu. Kegagalan seperti itu senyap total: tidak
                    // ada error, pengguna hanya mendadak kehilangan akses ke semua layar.
                    const kodeTarget = document.getElementById('editUserId').value;
                    if (String(kodeTarget) === String(currentUserData.userId)) {
                        const res = await fetchApp({ action: 'updateUserAccess', data: {
                            targetUserId: kodeTarget,
                            fullName: document.getElementById('editFullName').value.trim(),
                            email: document.getElementById('editEmail').value.trim(),
                            suffix: document.getElementById('editSuffix').value.trim()
                        } });
                        if (res.status === 'success') {
                            showNotification(res.message || 'Identitas Anda diperbarui.', 'success');
                            closeEditModal();
                            fetchManageableData();
                        } else showNotification(res.message || 'Gagal menyimpan.', 'error');
                        return;
                    }

                    const matrix = rcMatrixValues();
                    if (!matrix || Object.keys(matrix).length === 0) {
                        showNotification('Daftar modul belum selesai dimuat. Tutup dan buka kembali dialog ini sebelum menyimpan.', 'error');
                        return;
                    }
                    const peran = String(document.getElementById('editRoleInput').value || '').toLowerCase();
                    const data = {
                        targetUserId: document.getElementById('editUserId').value,
                        // Status aktivasi masih memakai huruf i seperti server harapkan; hak modul
                        // seluruhnya datang dari matriks, tidak ada lagi select huruf di markup.
                        auth: { i: document.getElementById('editActivation').value },
                        matrix: matrix, tabs: rcTabMatrixValues(),
                        targetRole: peran,
                        suffix: document.getElementById('editSuffix').value.trim(),
                        fullName: document.getElementById('editFullName').value.trim(),
                        email: document.getElementById('editEmail').value.trim(),
                        approvePin: document.getElementById('editApprovePin').checked
                    };

                    // Hanya yurisdiksi yang relevan bagi peran ini yang dikirim. Kunci yang tidak
                    // dikirim diperlakukan server sebagai "biarkan seperti semula", sehingga
                    // menyunting satu bagian tidak diam-diam mengosongkan bagian lain.
                    // Depot asal dikirim untuk SEMUA peran, termasuk System Manager. Sejak depot
                    // rumah menjadi keterangan identitas dan bukan lagi pemberian wewenang, tidak
                    // ada lagi alasan menyembunyikannya dari peran yang memperoleh seluruh depot -
                    // dan tanpa ini, depot yang tampil untuk System Manager selalu dipilih menurut
                    // abjad, yaitu depot yang tidak ada hubungannya dengan tempat ia bekerja.
                    data.homeDepot = document.getElementById('editHomeDepot').value;
                    if (peran !== 'system manager') {
                        if (peran === 'supervisor') data.assignOsc = checkMultiSelect('editAssignOscDrop');
                        if (['osc','others','finance','depot head','supervisor','management'].includes(peran)) data.assignDepots = checkMultiSelect('editAssignDepotDrop');
                        if (peran === 'admin') data.rpDepots = checkMultiSelect('editRpDrop');
                        if (peran === 'management') data.regions = checkMultiSelect('editAssignRegionDrop');
                    }

                    const res = await fetchApp({ action: 'updateUserAccess', data: data });
                    if (res.status === 'success') {
                        showNotification(res.message || 'Akses berhasil diperbarui.', 'success');
                        logActivity('Mengubah hak akses user: ' + data.targetUserId);
                        closeEditModal();
                        fetchManageableData();
                    } else {
                        // Dulu cabang ini tidak ada sama sekali: bila server menolak, layar hanya
                        // diam dan pengguna menyimpulkan tombolnya rusak. Sekarang alasannya
                        // ditampilkan dan modalnya tetap terbuka supaya isian tidak hilang.
                        showNotification(res.message || 'Akses gagal disimpan.', 'error');
                    }
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal terhubung ke server.', 'error');
                }
                finally { setHiddenSafely('saveAccessLoader', true); setDisabledSafely('btnSaveAccess', false); }
            }

            function updateMultiSelectLabel(dropdownId, spanElement) {
                if(!spanElement) return; let c = document.getElementById(dropdownId); if (!c) return;
                let cb = c.querySelectorAll('input[type="checkbox"]:checked');
                if (cb.length === 0) spanElement.innerText = "-- Semua --";
                else { let l = []; cb.forEach(b => { if (b.value !== 'ALL') l.push(b.nextElementSibling.innerText); }); spanElement.innerText = l.length > 1 ? l.length + " Dipilih" : l.join(', '); }
            }

            function updateAddDepotName() { let sel = document.getElementById('addDepotCode').value; let fd = globalDepotList.find(d => d.kode === sel); document.getElementById('addDepotNameDisplay').value = fd ? fd.nama : ''; }

            async function loadAddAccountForm() {
                if (!mRegistrationOptions && !(await fetchManageableData())) return;
                if (!mRegistrationOptions) { showNotification('Pilihan registrasi belum tersedia. Segarkan Data.', 'warning'); return; }
                const roleSelect = document.getElementById('addRole');
                const previousRole = roleSelect.value;
                roleSelect.innerHTML = (mRegistrationOptions.roles || []).map(r =>
                    '<option value="' + rcEsc(r.code) + '">' + rcEsc(r.label) + '</option>').join('');
                if ((mRegistrationOptions.roles || []).some(r => r.code === previousRole)) roleSelect.value = previousRole;
                const depotSelect = document.getElementById('addDepotCode');
                const previousDepot = depotSelect.value;
                depotSelect.innerHTML = '<option value="">-- Pilih Kode Depot --</option>' + globalDepotList.map(d =>
                    '<option value="' + rcEsc(d.kode) + '">' + rcEsc(d.kode + ' - ' + d.nama) + '</option>').join('');
                depotSelect.value = previousDepot;
                document.getElementById('addAssignOscDrop').innerHTML = buildMultiselectHTML(
                    currentManageableUsers.filter(u => (u.sysRole || u.role) === 'osc' && u.activation === 'Active')
                        .map(u => ({ label: u.userId, value: u.userId })), false, 'addAssignOscDrop');
                handleAddRoleChange();
                mTerapkanViewer();
            }

            function handleAddRoleChange() {
                const role = document.getElementById('addRole').value;
                const scope = ((mRegistrationOptions && mRegistrationOptions.roles) || []).find(r => r.code === role)?.scope;
                setHiddenSafely('addDeptContainer', role !== 'others');
                setHiddenSafely('assignOscContainer', scope !== 'osc');
                setHiddenSafely('assignAdminContainer', scope !== 'depot' && scope !== 'region');
                document.getElementById('addDepotCode').disabled = !mBolehUbah();
                updateAddDepotName();
                const container = document.getElementById('assignAdminContainer');
                container.querySelector('label').innerText = scope === 'region' ? 'Mapping Region' : 'Mapping Depot';
                const options = scope === 'region'
                    ? (mRegistrationOptions.regions || []).map(r => ({ label: r, value: r }))
                    : globalDepotList.map(d => ({ label: d.kode + ' - ' + d.nama, value: d.kode }));
                document.getElementById('addAssignAdminDrop').innerHTML = buildMultiselectHTML(options, true, 'addAssignAdminDrop');
                mTerapkanViewer();
            }

            function toggleDeptManual() {
                const v = document.getElementById('addDeptName').value;
                setHiddenSafely('addDeptManual', v !== 'Lainnya');
                if (v !== 'Lainnya') document.getElementById('addDeptManual').value = '';
            }

            async function submitAddAccount() {
                if (!mBolehUbah() || mRegistrationSubmitting) return;
                if (!mRegistrationOptions) { showNotification('Muat ulang tab Registrasi terlebih dahulu.', 'warning'); return; }
                const role = document.getElementById('addRole').value;
                const pin = document.getElementById('addPin').value;
                const data = { nama: document.getElementById('addName').value.trim(),
                    userId: document.getElementById('addUserId').value.trim().toUpperCase(),
                    pin, email: document.getElementById('addEmail').value.trim(), role,
                    depotCode: document.getElementById('addDepotCode').value,
                    assignOsc: role === 'supervisor' ? checkMultiSelect('addAssignOscDrop') : '',
                    assignAdmin: ['admin','osc','others','finance','depot head'].includes(role) ? checkMultiSelect('addAssignAdminDrop') : '',
                    regions: role === 'management' ? checkMultiSelect('addAssignAdminDrop') : '', department: '' };
                if (role === 'others') {
                    const department = document.getElementById('addDeptName').value;
                    data.department = department === 'Lainnya' ? document.getElementById('addDeptManual').value.trim() : department;
                }
                if (!data.nama || !data.userId || !data.email || !data.depotCode || !role) {
                    showNotification('Lengkapi identitas, role, dan depot asal.', 'warning'); return;
                }
                if (pin.length < 8 || new TextEncoder().encode(pin).length > 72) {
                    showNotification('PIN minimal 8 karakter dan maksimal 72 byte.', 'warning'); return;
                }
                const scope = (mRegistrationOptions.roles || []).find(r => r.code === role)?.scope;
                if ((scope === 'depot' && !data.assignAdmin) || (scope === 'osc' && !data.assignOsc) || (scope === 'region' && !data.regions)) {
                    showNotification('Pilih yurisdiksi sesuai role terlebih dahulu.', 'warning'); return;
                }
                mRegistrationSubmitting = true;
                setHiddenSafely('addAccountLoader', false); setDisabledSafely('btnAddAccountSubmit', true);
                try {
                    const res = await fetchApp({ action: 'addAccount', data });
                    if (res.status !== 'success') { showNotification(res.message, 'error'); return; }
                    document.getElementById('addAccountForm').reset();
                    const refreshed = await fetchManageableData();
                    switchManageTab('list');
                    showNotification((res.message || 'Akun berhasil dibuat.') + (refreshed ? '' : ' Daftar akun belum termuat; tekan Segarkan Data.'), refreshed ? 'success' : 'warning');
                } catch (e) { showNotification('Registrasi belum dapat dikonfirmasi. Ulangi dengan data yang sama.', 'error'); }
                finally {
                    mRegistrationSubmitting = false;
                    setHiddenSafely('addAccountLoader', true); setDisabledSafely('btnAddAccountSubmit', !mBolehUbah());
                }
            }

            async function fetchLogActivity() {
                showLoadingOverlay("Memuat Log Aktivitas...");
                try {
                    let role = currentUserData.sysRole || currentUserData.role || '';
                    let res = await fetchApp({ action: 'getLogActivity', requesterId: currentUserData.userId, requesterRole: role, managedDepots: currentUserData.managedDepots });
                    if (res.status === 'success') { window.globalLogs = res.logs || []; applyLogFilter(); }
                } catch (e) { showNotification("Gagal memuat Log Aktivitas.", "error"); } finally { hideLoadingOverlay(); }
            }
            
            function applyLogFilter() { logCurrentPage = 1; renderLogTable(); }
            
            function renderLogTable() {
                let tb = document.getElementById('logTableBody'); if(!tb) return;
                let fUser = (document.getElementById('logFilterUser')?.value || "").toLowerCase(); let fJenis = (document.getElementById('logFilterJenis')?.value || "").toLowerCase(); let fDate = document.getElementById('logFilterDate')?.value || "";

                let logs = (window.globalLogs || []).filter(l => {
                    let matchUser = !fUser || l.userId.toLowerCase().includes(fUser);
                    let matchJenis = !fJenis || l.detail.toLowerCase().includes(fJenis);
                    let matchDate = true;
                    if (fDate) {
                        let d = new Date(l.timestampIso || l.timestamp);
                        if (!isNaN(d.getTime())) {
                            let m = String(d.getMonth() + 1).padStart(2, '0'); let dy = String(d.getDate()).padStart(2, '0'); let y = d.getFullYear();
                            let dStr = `${y}-${m}-${dy}`; matchDate = (dStr === fDate);
                        }
                    }
                    return matchUser && matchJenis && matchDate;
                });

                if (logs.length === 0) { tb.innerHTML = `<tr><td colspan="4" class="p-8 text-center text-gray-500">Tidak ada log aktivitas.</td></tr>`; document.getElementById('logPagination').innerHTML = ''; return; }

                let totalItems = logs.length; let totalPages = Math.ceil(totalItems / logItemsPerPage);
                if (logCurrentPage > totalPages && totalPages > 0) logCurrentPage = totalPages;
                let startIdx = (logCurrentPage - 1) * logItemsPerPage; let paginatedLogs = logs.slice(startIdx, startIdx + logItemsPerPage);

                let rowsHtml = '';
                paginatedLogs.forEach(l => { rowsHtml += `<tr class="border-b hover:bg-gray-50"><td class="p-3 text-xs text-gray-500 whitespace-nowrap">${rcEsc(l.timestamp)}</td><td class="p-3 font-bold text-gray-800">${rcEsc(l.userId)}</td><td class="p-3 text-xs text-blue-600 font-semibold">${rcEsc(l.role)}</td><td class="p-3 text-sm text-gray-600">${rcEsc(l.detail)}</td><td class="p-3 text-xs whitespace-normal">${rcEsc(l.module)} / ${rcEsc(l.tab)}</td><td class="p-3 text-xs whitespace-normal">${rcEsc(l.stage)}</td><td class="p-3 text-xs break-all">${rcEsc(l.batch || "-")}</td></tr>`; });
                tb.innerHTML = rowsHtml; renderLogPagination(totalItems, totalPages);
            }

            function renderLogPagination(total, totalPages) {
                let container = document.getElementById('logPagination'); if (!container) return;
                let start = total === 0 ? 0 : (logCurrentPage - 1) * logItemsPerPage + 1; let end = Math.min(logCurrentPage * logItemsPerPage, total);
                container.innerHTML = `<div class="flex flex-col md:flex-row justify-between items-center text-xs text-gray-600 mt-5 px-3 bg-white p-3 border rounded-xl shadow-sm"><div class="mb-3 md:mb-0 font-medium">Menampilkan <span class="font-black text-gray-800">${start}</span> - <span class="font-black text-gray-800">${end}</span> dari <span class="font-black text-gray-800">${total}</span> Logs</div><div class="flex items-center gap-4"><nav class="flex rounded-lg shadow-sm overflow-hidden border border-gray-300"><button onclick="logCurrentPage--; renderLogTable()" ${logCurrentPage === 1 ? 'disabled' : ''} class="px-4 py-2 bg-white disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed transition-colors"><i class="fas fa-chevron-left"></i></button><span class="px-4 py-2 bg-gray-50 border-x border-gray-300 font-black text-gray-700">${logCurrentPage} / ${totalPages > 0 ? totalPages : 1}</span><button onclick="logCurrentPage++; renderLogTable()" ${logCurrentPage >= totalPages || totalPages === 0 ? 'disabled' : ''} class="px-4 py-2 bg-white disabled:bg-gray-100 disabled:text-gray-400 disabled:cursor-not-allowed transition-colors"><i class="fas fa-chevron-right"></i></button></nav></div></div>`;
            }


            // Depot tidak boleh diketik bebas: kodenya harus ada di master depot, dan server
            // menolak apa pun di luar daftar ini. Daftar dimuat sekali lalu dipakai ulang.
