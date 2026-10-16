            // Mengganti peran harus langsung mengubah bentuk yurisdiksi yang ditawarkan,
            // supaya tidak ada yang mengisi kolom yang nanti diabaikan server.
            function handleEditRoleSwitch() {
                const s = document.getElementById('editRoleInput');
                if (s && s.value) document.getElementById('editRoleDisplay').innerText = `Role: ${s.value}`;
                const kode = document.getElementById('editUserId');
                const u = (typeof currentManageableUsers !== 'undefined' && kode)
                    ? currentManageableUsers.find(x => String(x.userId) === String(kode.value)) : null;
                if (typeof applyJurisdictionVisibility === 'function') applyJurisdictionVisibility(u || {});
                // Hak modul juga mengikuti peran yang baru dipilih (20261162150000).
                if (s && s.value && typeof rcMatriksUntukPeran === 'function') rcMatriksUntukPeran(s.value);
            }

            let noDocTimer; function handleSingleDocInput() { clearTimeout(noDocTimer); noDocTimer = setTimeout(autoFillSingleDoc, 400); }

            // async sejak master diambil saat perlu, bukan diborong saat login.
            async function autoFillSingleDoc() {
                let docVal = document.getElementById('singleNoDoc').value.trim().toUpperCase();
                let statusEl = document.getElementById('singleDocStatus'), btnPreview = document.getElementById('btnSinglePreview');
                ['singleToko','singleCamp','singleJenisCb','singleRewardHighlight','singleStatusPajak','singleSubyekPajak'].forEach(id => setTextSafely(id, "-"));
                document.getElementById('singleJenisCb').className = "font-black text-gray-800"; document.getElementById('singleStatusPajak').className = "font-bold text-gray-800"; document.getElementById('singleSubyekPajak').className = "font-bold text-gray-800";
                btnPreview.disabled = true;

                if (!docVal) { statusEl.innerText = ""; return; }
                await pastikanMaster([], [docVal]);
                let db = globalDocuments.find(d => String(d.noDoc).trim().toUpperCase() === docVal);
                if (!db) { statusEl.innerHTML = `<span class="bg-orange-100 text-orange-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-exclamation-circle"></i> Tdk Ditemukan</span>`; return; }

                let cS = String(db.status || "").toLowerCase();

                // MODE POSTING EXCEPTION: hanya dokumen berstatus "Not Yet" (belum pernah diklaim) yang boleh
                // di-Hold/Expired lewat modul Upload ini. Dokumen yang sudah Submitted/Released/Claimed harus
                // ditolak (reject) dulu di tahapnya masing-masing sampai kembali ke Not Yet.
                if (currentPostingMode === 'exception') {
                    if (cS !== "not yet" && cS !== "") { statusEl.innerHTML = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-ban"></i> Hanya Status Not Yet Bisa Diproses (Saat Ini: ${db.status || '-'})</span>`; return; }
                } else {
                    if (cS === "done") { statusEl.innerHTML = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-ban"></i> Duplikat (Done)</span>`; return; }
                    else if (cS === "submitted") { statusEl.innerHTML = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-ban"></i> Sudah Diajukan</span>`; return; }
                    else if (cS === "released") { statusEl.innerHTML = `<span class="bg-yellow-100 text-yellow-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-clock"></i> Pending (Released)</span>`; return; }
                    else if (cS === "claimed") { statusEl.innerHTML = `<span class="bg-yellow-100 text-yellow-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-clock"></i> Claimed</span>`; return; }
                    else if (cS === "on hold") { statusEl.innerHTML = `<span class="bg-purple-100 text-purple-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-pause-circle"></i> Sedang Ditahan (On Hold)</span>`; return; }
                    else if (cS === "expired") { statusEl.innerHTML = `<span class="bg-gray-800 text-white px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-times-circle"></i> Expired (Permanen)</span>`; return; }
                }

                let docDc = String(db.dcCode || '').toUpperCase();
                let isSysMgr = currentUserData && (currentUserData.sysRole || currentUserData.role || '').toLowerCase() === 'system manager';
                let managed = currentUserData.managedDepots ? currentUserData.managedDepots.map(x => String(x).toUpperCase()) : [];

                if (!isSysMgr && !managed.includes(docDc)) {
                    statusEl.innerHTML = `<span class="bg-red-100 text-red-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-ban"></i> Beda DC (Ditolak)</span>`; return;
                }

                if (currentPostingMode === 'exception') {
                    statusEl.innerHTML = `<span class="bg-blue-100 text-blue-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-check-circle"></i> Siap Posting Exception (Status: ${db.status || 'Not Yet'})</span>`;
                    btnPreview.disabled = false;
                    document.getElementById('singleToko').innerText = `${db.custCode} - ${normalizeName(db.custName)}`;
                    document.getElementById('singleCamp').innerText = `${db.codeCampaign} - ${db.campaignName}`;
                    document.getElementById('singleRewardHighlight').innerText = `Rp ${Math.trunc(Number(Number(db.cbNet || 0))||0).toLocaleString('id-ID')}`;
                    return;
                }

                statusEl.innerHTML = `<span class="bg-green-100 text-green-700 px-2 py-0.5 rounded shadow-sm font-bold"><i class="fas fa-check-circle"></i> Ditemukan & Valid</span>`;
                btnPreview.disabled = false;

                await pastikanMaster([db.custCode], []);
                let cmp = globalCampaigns.find(c => c.codeCampaign === db.codeCampaign) || {}; let cst = globalCustomers.find(c => c.custCode === db.custCode) || {};
                
                let db_ktp = String(cst.ktp || '').trim(); let db_npwp = String(cst.npwp || '').trim(); let subPajak = "-";
                // NPWP terisi = Badan walaupun KTP juga ada; hanya KTP = Perorangan (20261163110000).
                if (db_npwp) subPajak = "Badan"; else if (db_ktp) subPajak = "Perorangan";

                document.getElementById('singleToko').innerText = `${db.custCode} - ${normalizeName(db.custName)}`;
                document.getElementById('singleCamp').innerText = `${db.codeCampaign} - ${db.campaignName}`;
                document.getElementById('singleRewardHighlight').innerText = `Rp ${Math.trunc(Number(Number(db.cbNet || 0))||0).toLocaleString('id-ID')}`;
                
                let elCb = document.getElementById('singleJenisCb'); elCb.innerText = rcCbLabel(db.jenisCb || cmp.jenisCb) || "-";
                let jcbLow = String(db.jenisCb || cmp.jenisCb || '').trim().toLowerCase();
                elCb.className = "font-black px-2 py-0.5 rounded text-[10px] uppercase " + (jcbLow === 'cn' ? "bg-yellow-200 text-yellow-800" : (jcbLow === 'transfer' ? "bg-green-200 text-green-800" : "text-gray-800"));
                
                let elSp = document.getElementById('singleStatusPajak'); elSp.innerText = cmp.statusPajak || "-";
                elSp.className = "font-black px-2 py-0.5 rounded text-[10px] uppercase " + (cmp.statusPajak === 'PKP' ? "bg-blue-100 text-blue-700" : "bg-gray-200 text-gray-700");
                
                let elSb = document.getElementById('singleSubyekPajak'); elSb.innerText = subPajak;
                elSb.className = "font-black px-2 py-0.5 rounded text-[10px] uppercase " + (subPajak === 'Badan' ? "bg-purple-100 text-purple-700" : (subPajak === 'Perorangan' ? "bg-orange-100 text-orange-700" : (subPajak==='Check'?"bg-red-500 text-white animate-pulse shadow-sm":"text-gray-800")));

                setValueSafely('singleKtp', db_ktp); setValueSafely('singleNpwp', db_npwp);
                setValueSafely('singleRek', cst.noRek || ''); setValueSafely('singleNamaRek', cst.namaRek || ''); setValueSafely('singleBank', cst.bank || ''); 
                setValueSafely('singleTop', ''); 
            }

            function resetSingleForm() {
                document.getElementById('singleUploadForm').reset(); document.getElementById('singleDocStatus').innerHTML = '';
                ['singleToko','singleCamp','singleJenisCb','singleRewardHighlight','singleStatusPajak','singleSubyekPajak'].forEach(id => document.getElementById(id).innerText = "-");
                document.getElementById('singleJenisCb').className = "font-black text-gray-800"; document.getElementById('singleStatusPajak').className = "font-bold text-gray-800"; document.getElementById('singleSubyekPajak').className = "font-bold text-gray-800";
                document.getElementById('btnSinglePreview').disabled = true;
            }

            // Bersihkan seluruh input No Doc & field terkait (grid mass upload + form single upload) supaya
            // No Doc dari proses Posting sebelumnya tidak pernah terbawa ke proses Posting berikutnya - dipanggil
            // saat modul Claim Upload dibuka dan saat ganti mode Posting Claim <-> Posting Exception. Ini hanya
            // membersihkan input state di browser, TIDAK menyentuh data yang sudah tersimpan di sheet/database.
            function resetPostingInputs() {
                if (typeof resetInputGrid === 'function') resetInputGrid();
                resetSingleForm();
            }
