            function goToHome() { if (currentUserData) { setHiddenSafely('workspaceSection', true); setHiddenSafely('profileSection', true); setHiddenSafely('loginSection', true); setHiddenSafely('modManage', true); setHiddenSafely('dashboardSection', false); setHiddenSafely('navBackBtn', true); } }
            function reqLogout() { if(currentUserData) { fetchApp({ action: 'logout', userId: currentUserData.userId }).then(()=>{location.reload()}).catch(()=>{location.reload()}); } else { location.reload(); } }

            function openModule(mod) {
                const accessModule={manage:'access',logActivity:'logs',bulkProcess:'bulk'}[mod]||mod;
                const selected=rcFirstTab(accessModule,{upload:'mass',release:'list',process:'claimFin',analytics:'history',access:'list',logs:'list',bulk:'rebate'}[accessModule]);
                if(!rcEnterTab(accessModule,selected))return;
                setHiddenSafely('dashboardSection', true); setHiddenSafely('navBackBtn', false); setHiddenSafely('workspaceSection', false); setHiddenSafely('profileSection', true);
                document.querySelectorAll('.module-section').forEach(el => el.classList.add('hidden'));
                if (mod === 'upload') { document.getElementById('modUpload').classList.remove('hidden'); cancelPreview(); resetPostingInputs(); if(selected==='open')openRcOpenTab();else switchSubTab('upload',selected); }
                else if (mod === 'release') { document.getElementById('modRelease').classList.remove('hidden'); fetchWorkflowData(); } 
                else if (mod === 'process') { document.getElementById('modProcess').classList.remove('hidden'); switchSubTab('process', selected); fetchWorkflowData(); } 
                else if (mod === 'analytics') { document.getElementById('modAnalytics').classList.remove('hidden'); switchSubTab('analytics', selected); fetchDashboardData(); } 
                else if (mod === 'manage') { document.getElementById('modManage').classList.remove('hidden'); switchManageTab(selected); fetchManageableData(); } 
                else if (mod === 'logActivity') { document.getElementById('modLogActivity').classList.remove('hidden'); fetchLogActivity(); }
                else if (mod === 'bulkProcess') { document.getElementById('modBulkProcess').classList.remove('hidden'); fetchWorkflowData(); }
            }

            function switchSubTab(module, tab) {
                if(!rcEnterTab(module,tab))return;
                if (module === 'process') { setHiddenSafely('tab_claimFin', tab !== 'claimFin'); setHiddenSafely('tab_clearing', tab !== 'clearing'); updateSubNavStyles('subnav_claimFin', 'subnav_clearing', tab === 'claimFin', 'indigo'); } 
                else if (module === 'analytics') { setHiddenSafely('tab_history', tab !== 'history'); setHiddenSafely('tab_summary', tab !== 'summary'); updateSubNavStyles('subnav_history', 'subnav_summary', tab === 'history', 'teal'); } 
                else if (module === 'upload') { currentUploadMode = tab; setHiddenSafely('tab_mass', tab !== 'mass'); setHiddenSafely('tab_single', tab !== 'single'); updateSubNavStyles('subnav_mass', 'subnav_single', tab === 'mass', 'blue');  setHiddenSafely('tab_open', true); let sO = document.getElementById('subnav_open'); if (sO) sO.className = 'px-5 py-2 text-sm font-bold rounded-lg text-gray-500 hover:bg-gray-100 transition'; }
            }

            function updateSubNavStyles(id1, id2, isFirstActive, colorPrefix) {
                let b1 = document.getElementById(id1); let b2 = document.getElementById(id2);
                if(b1 && b2) {
                    if(isFirstActive) { b1.className = `px-5 py-2 text-sm font-bold rounded-lg transition bg-${colorPrefix}-100 text-${colorPrefix}-700`; b2.className = `px-5 py-2 text-sm font-bold rounded-lg transition text-gray-500 hover:bg-gray-100`; } 
                    else { b2.className = `px-5 py-2 text-sm font-bold rounded-lg transition bg-${colorPrefix}-100 text-${colorPrefix}-700`; b1.className = `px-5 py-2 text-sm font-bold rounded-lg transition text-gray-500 hover:bg-gray-100`; }
                }
            }

            function switchManageTab(t) {
                if(!rcEnterTab('access',t))return;
                // Email Otomatis, Exclude Campaign, Persetujuan Depot dan Grade Depot pindah
                // ke sini atas permintaan pemilik: ketiganya keputusan administratif yang
                // mengubah apa yang dilihat orang lain, bukan bagian dari laporan harian.
                ['list', 'add', 'req', 'email', 'exclude', 'arsip', 'grade'].forEach(tab => {
                    setHiddenSafely('mContent' + tab.charAt(0).toUpperCase() + tab.slice(1), tab !== t);
                    let btn = document.getElementById('mTab' + tab.charAt(0).toUpperCase() + tab.slice(1));
                    if (btn) { if (tab === t) { btn.classList.add('bg-white', 'shadow-sm', 'text-blue-600'); btn.classList.remove('text-gray-500', 'hover:text-gray-800'); } else { btn.classList.remove('bg-white', 'shadow-sm', 'text-blue-600'); btn.classList.add('text-gray-500', 'hover:text-gray-800'); } }
                });
                // Kunci viewer dipasang ulang setiap berpindah tab: isi tiap tab digambar
                // saat dibuka, jadi kendalinya belum ada ketika kunci dipasang sebelumnya.
                if (typeof mTerapkanViewer === 'function') setTimeout(mTerapkanViewer, 0);
                if (t === 'add') loadAddAccountForm();
                else if (t === 'email') loadEmailPanel();
                else if (t === 'exclude') muatExcludeCampaign();
                else if (t === 'arsip') muatArsipAkun();
                else if (t === 'grade') muatGradeDepot();
                // Approval Request memuat dua antrean: perubahan data pengguna (sudah dimuat
                // bersama daftar akun) dan pengajuan profil depot.
                else if (t === 'req') muatPersetujuanDepot();
            }

            function parseAuthBool(val) { if(!val) return false; let str = String(val).toLowerCase(); return (str === 'yes' || str === 'approved' || str === 'true' || str === 'visible'); }
            function handleLoginEnter(e) { if (e.key === 'Enter') processLogin(); }

            async function processLogin() {
                let uidInput = document.getElementById('userid'); let pinInput = document.getElementById('pin');
                let uid = uidInput.value.trim(); let pin = pinInput.value;
                let errEl = document.getElementById('loginErrorText');
                
                if (!uid || !pin) { errEl.innerText = "Isi UserID dan PIN Anda!"; setHiddenSafely('loginError', false); return; }
                if (!pinAttempts[uid]) pinAttempts[uid] = 0;
                if (pinAttempts[uid] >= 3) { errEl.innerText = "Akun Anda diblokir (Salah PIN >3x)."; setHiddenSafely('loginError', false); return; }

                setHiddenSafely('loginError', true); setHiddenSafely('loginLoader', false); setDisabledSafely('btnLogin', true);
                uidInput.disabled = true; pinInput.disabled = true; document.getElementById('btnLoginText').innerText = "Memverifikasi...";

                try {
                    let res = await window.RCBackend.call({ action: 'login', userid: uid, pin: pin });
                    
                    if (res.status === 'success') {
                        let act = (res.data.activation || '').toLowerCase();
                        if (act === 'nonactive' || act === 'denied') throw { customMessage: "Akun dinonaktifkan administrator." };
                        else if (act === 'pending') throw { customMessage: "Akun berstatus Pending. Tunggu ACC." };
                        else if (act === 'block') throw { customMessage: "Akun diblokir keamanan." };

                        applySession(res);
                        logActivity("User Login Berhasil");
                    } else {
                        pinAttempts[uid]++; let aL = 3 - pinAttempts[uid];
                        if (pinAttempts[uid] >= 3) errEl.innerText = "Akun diblokir karena salah PIN lebih dari 3x."; else errEl.innerText = res.message || `PIN Salah. Sisa: ${aL}`;
                        setHiddenSafely('loginError', false); throw new Error("Invalid Login");
                    }
                } catch (e) {
                    if (e.customMessage) { errEl.innerText = e.customMessage; setHiddenSafely('loginError', false); }
                    else if (e.message !== "Invalid Login") { errEl.innerText = "Error server. Cek URL & Deploy Backend."; setHiddenSafely('loginError', false); }
                    uidInput.disabled = false; pinInput.disabled = false; uidInput.value = ''; pinInput.value = ''; uidInput.focus();
                } finally { setHiddenSafely('loginLoader', true); setDisabledSafely('btnLogin', false); document.getElementById('btnLoginText').innerText = "Masuk ke Portal"; }
            }

            function applyRoleBasedUI(user) {
                let sys = (user.sysRole || user.role || '').toLowerCase();
                let iSM = sys === 'system manager', iSP = sys === 'supervisor', iOS = sys === 'osc', uA = user.auth || {};

                let aPD = iSM || parseAuthBool(uA.q);setHiddenSafely('menuPrintDoc', !aPD);
                let aU = iSM || parseAuthBool(uA.j), aR = iSM || parseAuthBool(uA.k), aP = iSM || parseAuthBool(uA.l), aA = iSM || parseAuthBool(uA.m) || parseAuthBool(uA.d), aK = iSM || iSP || parseAuthBool(uA.n), aL = iSM || iSP || iOS, aMD = iSM || parseAuthBool(uA.p), aBulk = iSM || parseAuthBool(uA.s); 
                setHiddenSafely('menuUpload', !aU); setHiddenSafely('menuKeyMaster', !(iSM || parseAuthBool(uA.keyMaster))); setHiddenSafely('menuCompilation', !(iSM || parseAuthBool(uA.compilation))); setHiddenSafely('menuRelease', !aR); setHiddenSafely('menuProcess', !aP); setHiddenSafely('menuAnalytics', !aA); setHiddenSafely('menuKelolaAkses', !aK); setHiddenSafely('menuLogActivity', !aL);  setHiddenSafely('menuBulkProcess', !aBulk);
                // Report dan Timetable mengikuti pola yang sama: System Manager selalu melihat
                // keduanya, selain itu mengikuti flag dari Access Management.
                setHiddenSafely('menuApproval', !(iSM || parseAuthBool(uA.approval)));
                setHiddenSafely('menuReport', !(iSM || parseAuthBool(uA.report)));
                setHiddenSafely('menuTimetable', !(iSM || parseAuthBool(uA.timetable) || parseAuthBool(uA.report)));

                if (iSP || iSM) { ['rel', 'cf', 'clr', 'hist', 'sum'].forEach(p => { setHiddenSafely(p + 'FilterDepotContainer', false); if (p !== 'rel' && p !== 'cf' && p !== 'clr') setHiddenSafely(p + 'FilterOscContainer', false); }); setHiddenSafely('dropBtnReqPin', true); setHiddenSafely('editRoleContainer', false); } 
                else if (iOS) { ['rel', 'cf', 'clr', 'hist', 'sum'].forEach(p => setHiddenSafely(p + 'FilterDepotContainer', false)); setHiddenSafely('dropBtnReqPin', false); } 
                else { setHiddenSafely('dropBtnReqPin', false); }
            }

            // ===================== MODUL BARU: KEY MASTER & COMPILATION =====================
            // Menyalin pola openModule() milik halaman ini supaya perilaku navigasinya sama,
            // tanpa perlu mengubah fungsi aslinya.
            // Dipakai oleh login maupun pemulihan sesi. Dipisah supaya keduanya tidak bisa
            // menyimpang: sebelumnya seluruh langkah ini hanya ada di dalam processLogin,
            // sehingga tidak ada cara masuk ke aplikasi selain mengetik PIN lagi.
            function applySession(res) {
                currentUserData = res.data;
                globalCampaigns = res.campaigns; globalCustomers = res.customers;
                globalDocuments = res.documents || []; globalDepotList = res.depots || [];
                globalDocuments.forEach(d => d.status = normalizeClaimStatus(d.status));

                setHiddenSafely('loginSection', true);
                setHiddenSafely('app-header', false);
                setHiddenSafely('userInfo', false);

                const elTopUser = document.getElementById('topUserDisplay');
                if (elTopUser) elTopUser.innerText = currentUserData.namaLengkap;
                const elTopRole = document.getElementById('topRoleDisplay');
                if (elTopRole) elTopRole.innerText = currentUserData.role;
                const elDepot = document.getElementById('displayDepot');
                if (elDepot) elDepot.innerText = `${currentUserData.kodeDepot} - ${normalizeName(currentUserData.depot)}`;

                applyRoleBasedUI(currentUserData);
                startRuntimeCounter();
                goToHome();
            }

            // Sesi Supabase memang sudah tersimpan di browser, tetapi halaman tidak pernah
            // memakainya: setiap muat ulang selalu kembali ke formulir login. Sekarang sesi yang
            // masih sah dipulihkan diam-diam dan pengguna mendarat di beranda, tanpa PIN lagi.
            async function restoreSessionIfAny() {
                try {
                    const res = await window.RCBackend.call({ action: 'restoreSession' });
                    if (res && res.status === 'success' && res.data) { applySession(res); return true; }
                } catch (e) { /* tidak ada sesi; biarkan formulir login tampil */ }
                return false;
            }
