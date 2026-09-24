/*
 * RC legacy backend adapter.
 *
 * The Resource Collection user interface in `index (4).html` is not modified by this
 * migration. Only its transport changes: every call that used to POST an `action` to the
 * Apps Script deployment now goes through `window.RCBackend.call()`, which speaks to
 * Supabase instead. Response shapes below reproduce the Apps Script contract field for
 * field, so no screen, handler or render function needs editing.
 *
 * Identity, role and depot scope always come from the Supabase session. Values the browser
 * sends along (userData, requesterId, requesterRole, managedDepots, token) are accepted by
 * the signature and then ignored, because the old backend trusted them and Supabase must
 * not. Document Center actions are deliberately absent; that module stays on its legacy
 * deployment until the RC database and backend are running.
 *
 * Loaded as a classic script before the page's inline script, so window.RCBackend exists
 * before any handler can fire. supabase-js itself is imported lazily.
 */
(function () {
  'use strict';

  var cfg = window.RC_ENV || {};
  var LOGIN_DOMAIN = '@rc-login.invalid';
  var clientPromise = null;
  var versions = new Map(); // noDoc -> version_no, refreshed from every server response
  var bootstrapped = false; // true once rc_legacy_bootstrap has returned a usable session
  // Benar ketika akun ini memang sedang diwajibkan menetapkan PIN baru, entah karena PIN
  // bawaan hasil impor atau karena permintaannya sudah disetujui. Hanya dalam keadaan itu
  // PIN boleh diganti langsung; di luar itu penggantian harus melewati persetujuan.
  var mustChangePin = false;

  // Sesi disimpan di sessionStorage, bukan localStorage.
  //
  // Permintaan pemilik: memuat ulang halaman tetap masuk, tetapi menutup jendela lalu membuka
  // aplikasi lagi harus masuk ulang. localStorage - bawaan supabase-js - bertahan sampai
  // dihapus, sehingga membuka aplikasi keesokan harinya pun langsung masuk ke akun terakhir.
  // sessionStorage berumur satu tab: reload mempertahankannya, menutup tab menghapusnya.
  //
  // Konsekuensi yang perlu diketahui: setiap tab berdiri sendiri, jadi membuka aplikasi di tab
  // kedua meminta login lagi. Itu memang harga dari aturan yang diminta, dan lebih aman pada
  // komputer bersama.
  //
  // Seluruh aksesnya dibungkus try/catch karena penyimpanan dapat ditolak di jendela
  // penyamaran; bila ditolak, sesi hidup di memori saja dan hilang begitu halaman dimuat ulang.
  var memori = {};
  var penyimpanSesi = {
    getItem: function (k) {
      try { return window.sessionStorage.getItem(k); }
      catch (e) { return Object.prototype.hasOwnProperty.call(memori, k) ? memori[k] : null; }
    },
    setItem: function (k, v) {
      try { window.sessionStorage.setItem(k, v); } catch (e) { memori[k] = String(v); }
    },
    removeItem: function (k) {
      try { window.sessionStorage.removeItem(k); } catch (e) { delete memori[k]; }
    }
  };

  // Sisa sesi lama yang terlanjur tersimpan di localStorage dibuang sekali di awal. Tanpa ini,
  // orang yang sudah masuk sebelum perubahan ini akan tetap masuk selamanya - persis keadaan
  // yang dikeluhkan - karena supabase-js tidak lagi melihat ke sana untuk membersihkannya.
  (function bersihkanSesiLama() {
    try {
      var buang = [];
      for (var i = 0; i < window.localStorage.length; i++) {
        var k = window.localStorage.key(i);
        if (k && /^sb-.*-auth-token/.test(k)) buang.push(k);
      }
      buang.forEach(function (k) { window.localStorage.removeItem(k); });
    } catch (e) { /* penyimpanan ditolak; tidak ada yang perlu dibersihkan */ }
  }());

  function client() {
    if (!clientPromise) {
      if (!cfg.supabaseUrl || !cfg.supabasePublishableKey) {
        clientPromise = Promise.reject(new Error('Konfigurasi Supabase belum diisi.'));
      } else {
        clientPromise = import(cfg.supabaseEsmUrl || 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm')
          .then(function (mod) {
            return mod.createClient(cfg.supabaseUrl, cfg.supabasePublishableKey, {
              auth: {
                persistSession: true,
                autoRefreshToken: true,
                detectSessionInUrl: false,
                storage: penyimpanSesi
              }
            });
          });
      }
    }
    return clientPromise;
  }


  // Supabase returns a small set of distinguishable sign-in failures. Reporting them
  // accurately matters: "PIN salah" sent to someone whose account is merely unconfirmed or
  // still awaiting approval wastes a support call and hides a project misconfiguration.
  function signInMessage(error) {
    var raw = String((error && error.message) || '').toLowerCase();
    if (raw.indexOf('not confirmed') >= 0) {
      return 'Akun terdaftar tetapi belum terkonfirmasi. Konfirmasi email harus dimatikan ' +
        'pada pengaturan Supabase Auth; hubungi System Manager.';
    }
    if (raw.indexOf('rate limit') >= 0 || raw.indexOf('too many') >= 0) {
      return 'Terlalu banyak percobaan. Tunggu beberapa menit sebelum mencoba lagi.';
    }
    return 'User ID atau PIN salah, akun tidak aktif, atau batas percobaan tercapai.';
  }

  function signUpMessage(error) {
    var raw = String((error && error.message) || '').toLowerCase();
    if (raw.indexOf('already registered') >= 0 || raw.indexOf('already been registered') >= 0) {
      return 'User ID ini sudah terdaftar. Gunakan User ID lain atau hubungi System Manager.';
    }
    if (raw.indexOf('signups not allowed') >= 0 || raw.indexOf('signup is disabled') >= 0) {
      return 'Pendaftaran mandiri sedang dinonaktifkan pada project Supabase.';
    }
    if (raw.indexOf('password') >= 0) {
      return 'PIN tidak memenuhi syarat keamanan project. Gunakan PIN yang lebih panjang.';
    }
    return (error && error.message) || 'Pendaftaran gagal.';
  }

  function ok(extra) { return Object.assign({ status: 'success' }, extra || {}); }

  // checkMultiSelect pada halaman lama mengembalikan satu string dipisah koma, sedangkan
  // rc_update_access menerima array JSON. Pemisahnya bisa ", " atau "," tergantung tempatnya,
  // jadi keduanya diterima. String kosong sengaja menjadi array kosong, bukan null: itulah
  // cara mengosongkan yurisdiksi tanpa menghapus bagian lain.
  function asList(v) {
    if (v === null || v === undefined) return [];
    if (Array.isArray(v)) return v.map(function (x) { return String(x).trim(); }).filter(Boolean);
    return String(v).split(',').map(function (x) { return x.trim(); }).filter(Boolean);
  }
  function fail(message) { return { status: 'error', message: message }; }

  // Deterministic internal login address; see docs/rc-auth-deployment.md. The user ID stays
  // the credential the person types, and shared business emails never merge two accounts.
  function loginEmail(userCode) {
    var bytes = new TextEncoder().encode(String(userCode).trim());
    return crypto.subtle.digest('SHA-256', bytes).then(function (digest) {
      var hex = Array.from(new Uint8Array(digest)).map(function (b) {
        return b.toString(16).padStart(2, '0');
      }).join('');
      return hex + LOGIN_DOMAIN;
    });
  }

  function rpc(name, args) {
    return client().then(function (sb) {
      return sb.rpc(name, args || {});
    }).then(function (res) {
      if (res.error) throw new Error(res.error.message);
      return res.data;
    });
  }

  function rememberVersions(list) {
    (list || []).forEach(function (row) {
      if (row && row.noDoc && row.versionNo != null) {
        versions.set(String(row.noDoc).trim().toUpperCase(), Number(row.versionNo));
      }
    });
  }

  function versionOf(noDoc) {
    var v = versions.get(String(noDoc).trim().toUpperCase());
    if (v == null) throw new Error('Dokumen ' + noDoc + ' belum dimuat; segarkan data lebih dulu.');
    return v;
  }

  // ---- value conversion -------------------------------------------------------------

  var MONTHS = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, mei: 5, jun: 6, jul: 7, aug: 8, agu: 8, sep: 9, oct: 10, okt: 10, nov: 11, dec: 12, des: 12 };

  // Layar kini menormalkan setiap tanggal menjadi 22-Jan-2026 lewat normalizeDateUI, jadi
  // BENTUK ITULAH yang paling sering sampai ke sini. Bentuk berangka juga tetap diterima,
  // karena tidak setiap tanggal melewati layar - sebagian datang dari templat Excel.
  //
  // Yang diterima persis sama dengan daftar yang ditetapkan pemilik, ditambah bentuk kanonik
  // dd-Mmm-yyyy dan ISO yang dipakai antar-mesin:
  //
  //   22-Jan-2026   dd.mm.yyyy   dd-mm-yyyy   dd.mm.yy   dd-mm-yy   ddmmyy   ddmmyyyy   ISO
  //
  // Selebihnya DITOLAK dengan menyebut nilainya, bukan ditebak. Menebak adalah cara paling
  // mudah sebuah tanggal berpindah bulan tanpa ada yang menyadarinya.
  function toIsoDate(value) {
    var s = String(value == null ? '' : value).trim();
    if (!s) return null;
    if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;

    var d = 0, mm = 0, y = 0;

    // Bentuk kanonik dari layar: 22-Jan-2026
    var nama = s.match(/^(\d{1,2})-([A-Za-z]{3})-(\d{4})$/);
    if (nama) {
      var urut = MONTHS[nama[2].toLowerCase()];
      if (!urut) throw new Error('Nama bulan tidak dikenali: ' + s);
      d = Number(nama[1]); mm = urut; y = Number(nama[3]);
    } else {
      var angka = s.match(/^(\d{1,2})[.-](\d{1,2})[.-](\d{2}|\d{4})$/);
      if (angka) {
        d = Number(angka[1]); mm = Number(angka[2]); y = Number(angka[3]);
        if (angka[3].length === 2) y += 2000;
      } else if (/^\d{6}$/.test(s)) {
        d = Number(s.slice(0, 2)); mm = Number(s.slice(2, 4)); y = 2000 + Number(s.slice(4));
      } else if (/^\d{8}$/.test(s)) {
        d = Number(s.slice(0, 2)); mm = Number(s.slice(2, 4)); y = Number(s.slice(4));
      } else {
        throw new Error('Format tanggal tidak dikenali: ' + s);
      }
    }

    // Tanggal yang polanya benar tetapi tidak ada - 31-04-2026, 29-02-2027 - ikut ditolak.
    var uji = new Date(Date.UTC(y, mm - 1, d));
    if (uji.getUTCFullYear() !== y || uji.getUTCMonth() !== mm - 1 || uji.getUTCDate() !== d) {
      throw new Error('Tanggal tidak ada dalam kalender: ' + s);
    }
    return y + '-' + String(mm).padStart(2, '0') + '-' + String(d).padStart(2, '0');
  }

  // normalizeMonthUI() in the page yields "Mon-YY"; the server wants YYYY-MM.
  function toIsoMonth(value) {
    var s = String(value == null ? '' : value).trim();
    if (!s) return null;
    var m = s.match(/^([A-Za-z]{3})[-\/ ](\d{2,4})$/);
    if (m) {
      var month = MONTHS[m[1].toLowerCase()];
      if (!month) throw new Error('Bulan tagih tidak dikenali: ' + s);
      var year = m[2].length === 2 ? '20' + m[2] : m[2];
      return year + '-' + String(month).padStart(2, '0');
    }
    if (/^\d{4}-\d{2}$/.test(s)) return s;
    throw new Error('Bulan tagih tidak dikenali: ' + s);
  }

  function text(value) {
    var s = String(value == null ? '' : value).trim();
    return s === '' ? null : s;
  }

  function assign(item, key, value) { if (value !== null && value !== undefined) item[key] = value; }

  function submitItem(row) {
    var item = { no_doc: String(row.noDoc).trim(), version_no: versionOf(row.noDoc) };
    assign(item, 'tax_subject', text(row.subyekPajak || row.statusPajakCust));
    // HANYA jenis CB yang benar-benar DIKETIK pengguna yang dikirim - bukan nilai yang terisi
    // otomatis dari Campaign Master. Keduanya ada di baris grid: jenisCashbackInput berisi
    // ketikan pengguna, jenisCashback berisi hasil akhir setelah master mengisinya.
    //
    // Bedanya menentukan. Server memvalidasi nilai yang dikirim terhadap daftar resmi yang
    // pendek, sedangkan Campaign Master masih memuat nama lama seperti Voucher. Mengirim nilai
    // master berarti meminta server menolak campaign yang sah - 421 dari 831 klaim not_yet ada
    // pada campaign Voucher. Bila field ini tidak dikirim, server memakai Campaign Master
    // sendiri lewat jenis_efektif(), yang memang mengenali nama-nama lama itu.
    assign(item, 'jenis_cashback', text(row.jenisCashbackInput));
    if (row.totTagih !== undefined && row.totTagih !== null && row.totTagih !== '') {
      var billing = Number(row.totTagih);
      if (!Number.isFinite(billing) || billing < 0) throw new Error('Total tagihan tidak valid pada ' + row.noDoc + '.');
      item.total_billing = billing;
    }
    assign(item, 'paid_on', toIsoDate(row.tglLunas));
    assign(item, 'ktp', text(row.ktp));
    assign(item, 'npwp', text(row.npwp));
    assign(item, 'bank', text(row.bankCust || row.bank));
    assign(item, 'account_number', text(row.noRekening));
    assign(item, 'account_name', text(row.pemilikRekening || row.namaRekening));
    assign(item, 'top', text(row.top));
    var months = [row.blnTagih1, row.blnTagih2, row.blnTagih3, row.blnTagih4]
      .map(toIsoMonth).filter(Boolean);
    if (months.length) item.billing_months = months;
    return item;
  }

  // ---- idempotency ------------------------------------------------------------------

  // A retry after a timeout must not create a second batch, so the request id is derived
  // from the payload and reused until that exact payload succeeds.
  var inFlight = new Map();

  function processClaims(action, items, reason) {
    var key = action + '|' + JSON.stringify(items) + '|' + reason;
    if (!inFlight.has(key)) inFlight.set(key, crypto.randomUUID());
    var requestId = inFlight.get(key);
    return rpc('rc_process_claims', {
      p_action: action, p_items: items, p_request_id: requestId, p_reason: reason || ''
    }).then(function (result) {
      inFlight.delete(key);
      (result.processed || []).forEach(function (row) {
        versions.set(String(row.no_doc).trim().toUpperCase(), Number(row.version_no));
      });
      // Laporan hasil di layar membaca grossUpMap[noDoc]. Sebelumnya selalu kosong sehingga
      // kolom Total CB Gross Up selalu nol; sekarang diisi dari nilai yang dihitung server.
      var grossUpMap = {};
      (result.processed || []).forEach(function (row) {
        if (row.gross_up !== null && row.gross_up !== undefined) {
          grossUpMap[String(row.no_doc).trim().toUpperCase()] = Number(row.gross_up);
        }
      });
      return ok({
        summary: {
          batchNum: result.batch || null,
          successCount: result.count,
          successfulDocs: (result.processed || []).map(function (r) { return r.no_doc; }),
          processed: result.processed || [],
          grossUpMap: grossUpMap
        }
      });
    });
  }

  function docItems(docs) {
    return (docs || []).map(function (d) {
      return { no_doc: String(d).trim(), version_no: versionOf(d) };
    });
  }

  // ---- action handlers ---------------------------------------------------------------

  // Langkah sesudah sesi tersedia, dipakai oleh login maupun pemulihan sesi. Dipisah
  // supaya keduanya tidak bisa menyimpang: satu-satunya beda di antara mereka adalah
  // apakah PIN baru saja diketik atau sesinya sudah tersimpan di browser.
  function terimaBootstrap(data) {
      if (!data || data.status !== 'success') {
        // First sign-in still carries the imported PIN. Reuse the page's own change-PIN
        // dialog rather than adding a screen; submitRequestPin() routes back here.
        mustChangePin = !!(data && data.mustChangePassword);
        if (data && data.mustChangePassword && typeof window.openRequestPinModal === 'function') {
          window.setTimeout(window.openRequestPinModal, 0);
        }
        return fail((data && data.message) || 'Bootstrap gagal.');
      }
      bootstrapped = true;
      rememberVersions(data.documents);
      return data;
  }

  var handlers = {
    login: function (body) {
      return client()
        .then(async function (sb) {
          // Older imports hashed the typed casing; new registrations use canonical uppercase.
          // Preserve the existing alias first and stop on throttling/network/other Auth errors.
          var entered = String(body.userid || '').trim();
          var candidates = Array.from(new Set([entered, entered.toUpperCase(), entered.toLowerCase()]));
          var res;
          for (var code of candidates) {
            res = await sb.auth.signInWithPassword({ email: await loginEmail(code), password: String(body.pin) });
            if (!res.error || res.error.code !== 'invalid_credentials') break;
          }
          return res;
        })
        .then(function (res) {
          if (res.error) throw new Error(signInMessage(res.error));
          return rpc('rc_legacy_bootstrap');
        })
        .then(terimaBootstrap);
    },

    logout: function () {
      return client()
        .then(function (sb) { return sb.auth.signOut(); })
        .then(function () { versions.clear(); bootstrapped = false; return ok(); });
    },

    refreshDocuments: function () {
      return rpc('rc_legacy_documents').then(function (documents) {
        rememberVersions(documents);
        return ok({ documents: documents });
      });
    },

    logActivity: function (body) {
      return rpc('rc_log_context', { p_detail: String(body.detail || '').slice(0, 1000), p_module: String(body.module || 'System'), p_tab: String(body.tab || 'System'), p_batch: String(body.batch || ''), p_stage: String(body.stage || '') })
        .then(function () { return ok(); });
    },

    submitData: function (body) {
      return processClaims('submit', (body.data || []).map(submitItem), '');
    },

    // ---- Management of Approval -----------------------------------------------------
    // Tahap persetujuan sebelum Release. Menyetujui dan menolak memakai jalur yang sama
    // dengan seluruh perpindahan status lain - processClaims - sehingga versi dokumen,
    // riwayat status dan Log Aktivitas terisi dengan cara yang sama persis, tanpa jalur
    // kedua yang bisa lupa mencatat salah satunya.
    approvalBatches: function (body) {
      return rpc('rc_approval_batches', {
        p_kind: String(body.kind || 'wpt'), p_depot: String(body.depot || '') || null
      });
    },
    approvalDepots: function () { return rpc('rc_approval_depots', {}); },
    approvalHold: function (body) {
      return rpc('rc_approval_hold', {
        p_depot: String(body.depot || '') || null,
        p_search: String(body.search || '') || null
      }).then(function (data) { rememberVersions(data.rows); return data; });
    },
    // Mengesahkan dan membatalkan keputusan On Hold / Expired. Keduanya melewati jalur
    // perpindahan status yang sama dengan seluruh modul lain, sehingga versi dokumen, riwayat
    // dan Log Aktivitas terisi dengan cara yang sama persis.
    approveHoldDocs: function (body) {
      return processClaims('approve_hold', docItems(body.docsToProcess), String(body.reason || ''));
    },
    rejectHoldDocs: function (body) {
      return processClaims('reject_hold', docItems(body.docsToProcess), String(body.reason || ''));
    },
    approvalDetail: function (body) {
      return rpc('rc_approval_detail', {
        p_batch: String(body.batch || ''), p_kind: String(body.kind || 'wpt')
      }).then(function (data) { rememberVersions(data.rows); return data; });
    },
    approvalHistory: function (body) {
      return rpc('rc_approval_history', {
        p_limit: Number(body.limit) || 50, p_offset: Number(body.offset) || 0,
        p_search: String(body.search || '') || null,
        p_depot: String(body.depot || '') || null
      });
    },
    approveDocs: function (body) {
      return processClaims('approve', docItems(body.docsToProcess), String(body.reason || ''));
    },
    rejectDocs: function (body) {
      return processClaims('reject_approval', docItems(body.docsToProcess), String(body.reason || ''));
    },

    // The legacy screens do not collect a reason, but the server requires one for every
    // exception and reject. Record what the action was instead of an empty string.
    toggleOnHold: function (body) {
      var action = body.holdAction === 'unhold' ? 'unhold' : 'hold';
      return processClaims(action, docItems(body.docsToProcess),
        action === 'hold' ? 'Posting Exception: On Hold via modul Upload' : 'Posting Exception: Unhold via modul Upload');
    },

    markExpired: function (body) {
      return processClaims('expire', docItems(body.docsToProcess),
        'Posting Exception: Expired via modul Upload');
    },

    bulkFastTrackRelease: function (body) {
      return processClaims('bulk_rebate', docItems(body.docsToProcess), '');
    },

    processWorkflow: function (body) {
      var stage = body.workflowType;
      var approve = { release: 'release', claim: 'claim', clearing: 'clearing' };
      var reject = { release: 'reject_release', claim: 'reject_claim', clearing: 'reject_clearing' };
      var action, reason = '';
      if (body.actionType === 'approve') {
        action = approve[stage];
      } else if (body.actionType === 'expired') {
        if (stage !== 'claim' && stage !== 'clearing') return Promise.resolve(fail('Expired hanya tersedia pada Claim Process.'));
        action = 'expire_claim_process';
        reason = 'Expired pada tahap ' + stage;
      } else {
        action = reject[stage];
        reason = 'Reject pada tahap ' + stage;
      }
      if (!action) return Promise.resolve(fail('Tahap workflow tidak dikenali.'));
      return processClaims(action, docItems(body.docsToProcess), reason);
    },

    getWorkflowData: function () {
      return rpc('rc_legacy_workflow').then(function (data) {
        rememberVersions([].concat(data.releaseData, data.claimFinData, data.clearingData, data.bulkRebateData));
        // "Kosong" selama ini berarti dua hal yang sangat berbeda: tidak ada datanya, atau
        // ada tetapi tidak terlihat oleh akun ini. Keduanya tampak identik di layar. Ketika
        // keempat antrean kosong, tanyakan sebabnya ke server dan tampilkan jawabannya,
        // daripada membiarkan orang menebak.
        var total = (data.releaseData || []).length + (data.claimFinData || []).length
          + (data.clearingData || []).length + (data.bulkRebateData || []).length;
        if (total > 0) return data;
        return rpc('rc_workflow_diagnostic')
          .then(function (d) {
            data.diagnostic = d;
            if (typeof window.showNotification === 'function' && d && d.sebab) {
              window.showNotification(d.sebab, 'warning');
            }
            if (window.console && d) console.info('RC diagnostic', d);
            return data;
          })
          .catch(function () { return data; });
      });
    },
    workflowDiagnostic: function () { return rpc('rc_workflow_diagnostic'); },

    getDashboardData: function () { return rpc('rc_legacy_dashboard'); },

    getLogActivity: function () { return rpc('rc_legacy_logs', { p_days: 30 }); },

    getManageableData: function () { return rpc('rc_legacy_manageable'); },

    submitProfileUpdate: function (body) {
      return rpc('rc_legacy_depot_id', { p_depot_code: body.kodeDepot })
        .then(function (depotId) {
          return rpc('rc_request_profile', { p_depot: depotId, p_changes: body.changes || {} });
        })
        .then(function () { return ok(); });
    },

    // One inbox covers both new-account registrations and depot profile changes; the id
    // prefix tells the server which kind it is.
    approveProfileRequest: function (body) {
      return rpc('rc_review_request', { p_id: String(body.reqId), p_approve: body.status === 'approved' })
        .then(function (data) { return ok({ message: data && data.message }); });
    },

    // Self registration. The account is created in 'pending' and grants nothing until a
    // System Manager approves it, so the session opened by signUp is closed immediately.
    signUp: function (body) {
      var d = body.data || {};
      var pin = String(d.pin || '');
      if (pin.length < 8) return Promise.resolve(fail('PIN minimal 8 karakter.'));
      if (pin !== String(d.pinConfirm || '')) return Promise.resolve(fail('Konfirmasi PIN tidak sama.'));
      return loginEmail(String(d.userId || '').trim().toUpperCase())
        .then(function (address) {
          return client().then(function (sb) {
            return sb.auth.signUp({
              email: address,
              password: pin,
              options: {
                data: {
                  user_code: String(d.userId || '').trim().toUpperCase(),
                  full_name: String(d.fullName || '').trim(),
                  business_email: String(d.email || '').trim().toLowerCase(),
                  requested_role: String(d.role || '').trim().toLowerCase(),
                  requested_depot: String(d.depot || '').trim()
                }
              }
            });
          });
        })
        .then(function (res) {
          if (res.error) throw new Error(signUpMessage(res.error));
          // With email confirmation still switched on, signUp returns no session and the
          // account cannot sign in even after approval. The registration itself is recorded,
          // so say exactly that rather than reporting plain success.
          var user = res.data && res.data.user;
          var unconfirmed = !!user && !user.confirmed_at && !(res.data && res.data.session);
          return client()
            .then(function (sb) { return sb.auth.signOut(); })
            .then(function () { return unconfirmed; });
        })
        .then(function (unconfirmed) {
          if (unconfirmed) {
            return ok({ message: 'Konfirmasi email masih aktif pada project Supabase, sehingga ' +
              'akun ini belum dapat login. Minta System Manager mematikan Confirm email.' });
          }
          // Akun pertama menjadi System Manager dan langsung aktif; sesudahnya menunggu
          // persetujuan. Adapter tidak tahu yang mana, jadi sebutkan keduanya dengan jelas.
          return ok({ message: 'Silakan masuk dengan User ID dan PIN tersebut. Bila Anda bukan ' +
            'pendaftar pertama, akun menunggu persetujuan System Manager sebelum dapat digunakan.' });
        });
    },

    updateUserAccess: function (body) {
      var d = body.data || {};
      // Matriks modul mengirim seluruh kunci baru sekaligus; flag huruf lama tetap dari
      // select bawaan, sehingga keduanya digabung di sini.
      var auth = Object.assign({}, d.auth || {}, d.matrix || {});

      // Sebuah kunci hanya ikut dikirim bila layar memang mengirimkannya. Server memperlakukan
      // kunci yang tidak ada sebagai "biarkan seperti semula", sehingga menyunting satu bagian
      // tidak diam-diam mengosongkan bagian lain.
      var payload = { userId: d.targetUserId, auth: auth };
      // Halaman lama menamainya targetRole. Membaca d.role saja membuat perubahan peran tidak
      // pernah sampai ke server, dan itu salah satu sebab peran tidak bisa diubah.
      var role = d.targetRole || d.role;
      if (role) payload.role = role;
      if (d.suffix) payload.suffix = d.suffix;
      if (d.tabs) payload.tabs = d.tabs;
      if (d.fullName) payload.fullName = d.fullName;
      if (d.email) payload.email = d.email;
      if (d.homeDepot !== undefined) payload.homeDepot = d.homeDepot;
      if (d.approvePin) payload.approvePin = true;
      if (d.rpDepots !== undefined) payload.rpDepots = asList(d.rpDepots);
      if (d.assignDepots !== undefined) payload.assignedDepots = asList(d.assignDepots);
      if (d.assignOsc !== undefined) payload.assignedOsc = asList(d.assignOsc);
      // Region hanya dikirim bila layar memang mengirimkannya; server memperlakukan kunci
      // yang tidak ada sebagai "biarkan seperti semula".
      if (d.regions !== undefined) payload.regions = asList(d.regions);

      return rpc('rc_update_access', { p_payload: payload }).then(function (r) {
        var res = ok();
        if (r && r.pesan) res.message = r.pesan;
        return res;
      });
    },

    // Pilihan Region untuk peran Management, diambil dari Depot Master.
    regionList: function () { return rpc('rc_region_list', {}); },

    // ---- Key Master ----------------------------------------------------------------
    customerList: function (body) {
      return rpc('rc_customer_list', {
        p_search: String(body.search || ''), p_offset: Number(body.offset) || 0,
        p_limit: Number(body.limit) || 50
      });
    },
    customerUpsert: function (body) { return rpc('rc_customer_upsert', { p_rows: body.rows || [] }); },
    campaignList: function (body) {
      return rpc('rc_campaign_list', {
        p_search: String(body.search || ''), p_offset: Number(body.offset) || 0,
        p_limit: Number(body.limit) || 50
      });
    },
    campaignUpsert: function (body) { return rpc('rc_campaign_upsert', { p_rows: body.rows || [] }); },
    campaignDelete: function (body) { return rpc('rc_campaign_delete', { p_codes: asList(body.campaigns) }); },

    // ---- Arsip Key Master -------------------------------------------------------------
    // Satu pasang fungsi untuk ketiga master, dibedakan p_jenis. Kuncinya adalah KODE
    // (customer_code / campaign_code / depot_code), bukan id, mengikuti rc_campaign_delete -
    // layar Key Master memang bekerja dengan kode, dan kode itulah yang terbaca manusia pada
    // pesan kegagalan per baris.
    masterArchive: function (body) {
      return rpc('rc_master_archive', {
        p_jenis: String(body.jenis || ''), p_kunci: asList(body.kode),
        p_alasan: String(body.alasan || '')
      });
    },

    masterUnarchive: function (body) {
      return rpc('rc_master_unarchive', {
        p_jenis: String(body.jenis || ''), p_kunci: asList(body.kode)
      });
    },

    masterArchived: function (body) {
      return rpc('rc_master_archived', {
        p_jenis: String(body.jenis || ''), p_search: String(body.search || '')
      });
    },

    // ---- Memo PDF campaign -----------------------------------------------------------
    // Berkasnya diunggah browser langsung ke Storage, bukan dititipkan lewat RPC: satu memo
    // dapat mencapai 10 MB, dan mengirimnya sebagai base64 di dalam JSON berarti payload-nya
    // membengkak sepertiga dan menabrak batas ukuran permintaan PostgREST.
    //
    // Jalur simpannya <id campaign>/<nama berkas>. Server memeriksanya sekali lagi terhadap id
    // campaign yang bersangkutan, sehingga baris campaign tidak dapat diarahkan ke berkas milik
    // campaign lain walaupun browser mengirim jalur yang lain.
    campaignMemoUpload: function (body) {
      var berkas = body.file;
      if (!berkas) return Promise.resolve(fail('Tidak ada berkas yang dipilih.'));
      if (berkas.type !== 'application/pdf') return Promise.resolve(fail('Memo harus berkas PDF.'));
      if (berkas.size > 10485760) return Promise.resolve(fail('Ukuran memo maksimal 10 MB.'));
      var id = String(body.campaignId || '');
      if (!/^[0-9a-f-]{36}$/i.test(id)) return Promise.resolve(fail('Campaign belum dikenali.'));
      // Nama berkas dibersihkan; Storage menolak sebagian karakter dan nama asli dari Windows
      // kerap memuat spasi serta tanda kurung.
      var aman = String(berkas.name || 'memo.pdf').replace(/[^A-Za-z0-9._-]+/g, '_');
      if (!/\.pdf$/i.test(aman)) aman += '.pdf';
      var jalur = id + '/' + Date.now() + '_' + aman;
      return client()
        .then(function (sb) {
          return sb.storage.from('campaign-memo')
            .upload(jalur, berkas, { contentType: 'application/pdf', upsert: false });
        })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message || 'Gagal mengunggah memo.');
          return rpc('rc_campaign_memo_set', {
            p_code: String(body.campaign || ''), p_path: jalur,
            p_name: String(berkas.name || aman), p_size: Number(berkas.size) || 0
          });
        });
    },

    // Tautan bertanda tangan, berumur pendek. Bucket-nya privat: tautan publik yang bocor
    // sekali akan terbuka selamanya dan tidak meninggalkan jejak siapa yang membukanya.
    campaignMemoUrl: function (body) {
      var jalur = String(body.path || '');
      if (!jalur) return Promise.resolve(fail('Campaign ini belum memiliki memo.'));
      return client()
        .then(function (sb) { return sb.storage.from('campaign-memo').createSignedUrl(jalur, 300); })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message || 'Gagal membuka memo.');
          return ok({ url: res.data.signedUrl });
        });
    },

    campaignMemoClear: function (body) {
      return rpc('rc_campaign_memo_clear', { p_code: String(body.campaign || '') })
        .then(function (res) {
          var jalur = String((res && res.path) || '');
          if (!jalur) return res;
          // Berkasnya dihapus setelah barisnya bersih. Bila penghapusan berkas gagal, yang
          // tertinggal hanyalah objek yatim di Storage - bukan baris yang menunjuk berkas
          // yang sudah tidak ada, yang jauh lebih membingungkan saat dibuka pengguna.
          return client()
            .then(function (sb) { return sb.storage.from('campaign-memo').remove([jalur]); })
            .then(function () { return res; })
            .catch(function () { return res; });
        });
    },

    // Pasangan depot x campaign yang ditandai Not Achieved, untuk kartu Detail Not Achieved.
    timetableNotAchieved: function () { return rpc('rc_timetable_not_achieved'); },

    // Membatalkan email yang masih mengantre atau sudah gagal, supaya satu pengiriman yang
    // terlanjur diantrekan tidak perlu dihentikan lewat SQL langsung ke tabel.
    // Arsip akun: isinya, dan pengaktifan kembali.
    accountArchive: function () { return rpc('rc_account_archive'); },
    accountRestore: function (body) {
      return rpc('rc_account_restore', { p_id: String(body.id || ''), p_alasan: String(body.alasan || '') });
    },

    emailCancel: function (body) { return rpc('rc_email_batalkan', { p_id: String(body.id || '') }); },

    // Penghapusan akun. Server yang memutuskan benar-benar dihapus atau ditinggalkan sebagai
    // nisan, menurut ada tidaknya jejak akun itu pada dokumen.
    accountDelete: function (body) {
      return rpc('rc_account_delete', {
        p_user_code: String(body.userId || ''), p_alasan: String(body.alasan || ''),
        p_hapus_jejak: !!body.hapusJejak
      });
    },


    // Dokumen berstatus Not Yet untuk tab Open pada modul Claim Upload.
    openClaims: function (body) {
      return rpc('rc_open_claims_filtered', {
        p_cb_type: String(body.cbType || ''),
        p_search: String(body.search || ''), p_campaign: String(body.campaign || ''),
        p_offset: Number(body.offset) || 0, p_limit: Number(body.limit) || 200
      });
    },
    // Sesi Supabase sudah disimpan di browser (persistSession), tetapi halaman tidak pernah
    // memanfaatkannya: setiap muat ulang selalu kembali ke formulir login meski sesinya masih
    // sah. Aksi ini memeriksa sesi yang tersimpan dan, bila ada, melanjutkan langsung ke
    // bootstrap tanpa meminta PIN lagi.
    restoreSession: function () {
      return client()
        .then(function (sb) { return sb.auth.getSession(); })
        .then(function (res) {
          if (res.error || !res.data || !res.data.session) return fail('Tidak ada sesi tersimpan.');
          return rpc('rc_legacy_bootstrap').then(terimaBootstrap);
        })
        .catch(function () { return fail('Tidak ada sesi tersimpan.'); });
    },

    // ---- Report dan Timetable ------------------------------------------------------
    reportDashboard: function (body) { return rpc('rc_report_dashboard', { p_filter: body.filter || {} }); },
    costCenter:      function (body) { return rpc('rc_cost_center',      { p_filter: body.filter || {} }); },
    costCenter2:     function (body) { return rpc('rc_cost_center_2',    { p_filter: body.filter || {} }); },
    timetableMatrix: function (body) { return rpc('rc_timetable_matrix', { p_filter: body.filter || {} }); },

    timetableMark: function (body) {
      return rpc('rc_timetable_mark', {
        p_depots: asList(body.depots),
        p_campaigns: asList(body.campaigns),
        p_tandai: body.tandai !== false,
        p_note: String(body.note || '')
      });
    },

    campaignExclude: function (body) {
      return rpc('rc_campaign_exclude', {
        p_codes: asList(body.campaigns),
        p_kecualikan: body.kecualikan !== false,
        p_reason: String(body.reason || '')
      });
    },

    // ---- Depot Master ---------------------------------------------------------------
    depotList: function (body) {
      return rpc('rc_depot_list', {
        p_search: body.search || null,
        p_offset: Number(body.offset || 0),
        p_limit: Number(body.limit || 50)
      });
    },
    depotUpsert: function (body) { return rpc('rc_depot_upsert', { p_rows: body.rows || [] }); },
    // Satu pintu: server yang memutuskan apakah perubahan langsung diterapkan atau
    // masuk antrean persetujuan, berdasarkan peran pemanggilnya.
    depotSave: function (body) {
      return rpc('rc_depot_save', { p_kode: body.kode, p_data: body.data || {} });
    },
    depotProfile: function (b) { return rpc('rc_depot_profile', {p_kode: b.kode}); },
    depotProfileRequest: function (b) { return rpc('rc_depot_profile_request', {p_kode: b.kode, p_perubahan: b.changes}); },
    peoplePerformance: function (b) { return rpc('rc_people_performance', {p_role: b.role || 'osc', p_user_code: b.userId || ''}); },
    peopleHistory: function (b) { return rpc('rc_people_history', {p_role: b.role, p_user_code: b.userId, p_from: b.from, p_to: b.to, p_grain: b.grain}); },
    depotRequests: function () { return rpc('rc_depot_profile_requests'); },
    depotReview: function (body) {
      return rpc('rc_depot_profile_review', {
        p_id: body.id, p_setujui: !!body.setujui, p_catatan: String(body.catatan || '')
      });
    },
    depotGradeList: function () { return rpc('rc_depot_grade_list'); },
    depotGradeSet: function (body) { return rpc('rc_depot_grade_set', { p_rows: body.rows || [] }); },

    // ---- Email otomatis -------------------------------------------------------------
    emailStatus:         function () { return rpc('rc_email_status'); },
    emailTestConnection: function () { return rpc('rc_email_uji_koneksi'); },
    emailSettingsSave:   function (body) { return rpc('rc_email_settings_simpan', { p_rows: body.rows || [] }); },
    // Menyusun DAN langsung mengirim, lalu melaporkan hasil yang sebenarnya. emailCompose
    // hanya mengantre, dan antreannya baru berjalan pada tick pg_cron berikutnya - sampai
    // sejam kemudian. Untuk tombol yang ditekan manusia, jeda itu tidak dapat diterima:
    // tombolnya tampak tidak melakukan apa-apa.
    //
    // testEmail terisi berarti pengiriman uji ke satu alamat saja; penerima depot diabaikan.
    emailSendNow: function (body) {
      return rpc('rc_email_kirim_sekarang', {
        p_jenis: String(body.jenis || ''), p_test_email: String(body.testEmail || '')
      });
    },

    emailCompose: function (body) {
      // kirim=false menyusun pratinjau tanpa memasukkannya ke antrean pengiriman.
      // testEmail terisi berarti pengiriman uji: seluruh pemetaan penerima depot diabaikan
      // dan email hanya berangkat ke satu alamat itu.
      return rpc('rc_email_susun', {
        p_jenis: body.jenis, p_kirim: !!body.kirim, p_test_email: String(body.testEmail || '')
      });
    },

    // Posting Exception. Expired cukup daftar No Doc; On Hold menuntut kedua tanggal,
    // dan server memeriksanya sekali lagi per dokumen terhadap periode campaign masing-masing.
    postingException: function (body) {
      return rpc('rc_posting_exception', {
        p_action: body.tindakan,
        p_rows: (body.rows || []).map(function (r) {
          return Object.assign({}, r, { versionNo: versionOf(r.noDoc) });
        }),
        p_reason: String(body.alasan || '')
      }).then(function (data) { rememberVersions(data.processed); return data; });
    },

    periodeDokumen: function (body) {
      return rpc('rc_periode_dokumen', { p_docs: asList(body.docs) });
    },

    // Reprocessing Doc: dokumen On Hold yang menunggu revisi nominal.
    reprocessingList: function (body) {
      return rpc('rc_reprocessing_list', {
        p_search: body.search || '', p_offset: 0, p_limit: 2000
      });
    },
    reprocessingUpload: function (body) {
      return rpc('rc_reprocessing_upload', {
        p_rows: body.rows || [], p_reason: String(body.alasan || '')
      });
    },

    permissionCatalog: function () { return rpc('rc_permission_catalog'); },

    // Lupa PIN memang harus bisa dikirim tanpa sesi: yang bersangkutan tidak dapat masuk.
    // Server selalu menjawab dengan kalimat yang sama, ada atau tidak ada akunnya, sehingga
    // layar ini tidak bisa dipakai untuk menebak kode pengguna yang valid.
    forgotPin: function (body) {
      return rpc('rc_request_pin', {
        p_user_code: body.userId || '',
        p_kind: 'lupa',
        p_reason: String(body.reason || ''),
        // PIN yang diinginkan ikut dikirim dan langsung di-hash di server; yang tersimpan
        // selama menunggu persetujuan hanyalah hash-nya, tidak pernah PIN aslinya.
        p_new_pin: String(body.newPin || '')
      }).then(function (r) { return ok({ message: (r && r.message) || 'Permintaan dikirim.' }); });
    },

    pinRequests: function () {
      return rpc('rc_pin_requests').then(function (rows) { return ok({ rows: rows || [] }); });
    },

    reviewPin: function (body) {
      return rpc('rc_review_pin', {
        p_id: body.id,
        p_approve: !!body.approve,
        p_note: String(body.note || '')
      }).then(function (r) { return ok({ message: (r && r.message) || 'Permintaan diproses.' }); });
    },

    // Satu-satunya pembacaan tanpa sesi: kode dan nama depot untuk formulir pendaftaran.
    publicDepots: function () {
      return rpc('rc_public_depots').then(function (rows) {
        return ok({ rows: rows || [] });
      });
    },

    // Compile cashback: pratinjau tidak menulis apa pun, commit berjalan satu transaksi dan
    // memakai request id turunan payload sehingga retry tidak menggandakan baris.
    compilePreview: function (body) { return rpc('rc_compile_preview', { p_rows: body.rows || [] }); },
    compileUpload: function (body) {
      var rows = body.rows || [];
      var key = 'compile|' + JSON.stringify(rows);
      if (!inFlight.has(key)) inFlight.set(key, crypto.randomUUID());
      var requestId = inFlight.get(key);
      return rpc('rc_compile_upload', { p_rows: rows, p_request_id: requestId })
        .then(function (result) { inFlight.delete(key); return result; });
    },

    // ---- Cashback Compilation ------------------------------------------------------
    compilationList: function (body) {
      return rpc('rc_compilation_list', {
        p_campaign: String(body.campaign || ''), p_batch: String(body.batch || ''),
        p_status: String(body.status || ''), p_search: String(body.search || ''),
        p_offset: Number(body.offset) || 0, p_limit: Number(body.limit) || 100
      });
    },
    archiveCompilation: function (body) {
      return rpc('rc_archive_compilation', { p_ids: body.ids || [], p_reason: String(body.reason || '') });
    },
    unarchiveCompilation: function (body) {
      return rpc('rc_unarchive_compilation', { p_ids: body.ids || [] });
    },
    archivedList: function (body) {
      return rpc('rc_archived_list', { p_offset: Number(body.offset) || 0, p_limit: 200 });
    },

    uploadAccount: function (body) { return handlers.addAccount(body); },
    addAccount: function (body) {
      var isUpload = body.action === 'uploadAccount';
      var d = body.data || {};
      var pin = String(d.pin || '');
      if (pin.length < 8 || new TextEncoder().encode(pin).length > 72) return Promise.resolve(fail('PIN minimal 8 karakter dan maksimal 72 byte.'));
      var role = String(d.role || '').trim().toLowerCase();
      if (role === 'non-osc') role = 'others';
      var key = 'registration:' + (isUpload ? 'upload:' : 'manual:') + JSON.stringify(d);
      var requestId = inFlight.get(key) || crypto.randomUUID();
      inFlight.set(key, requestId);
      return client().then(function (sb) {
        return sb.functions.invoke('rc-admin', {
          body: {
            action: isUpload ? 'submit_upload' : 'create',
            request_id: requestId,
            user_code: String(d.userId || '').trim().toUpperCase(),
            full_name: d.nama,
            business_email: d.email,
            role: role,
            department: d.department || '',
            home_depot: d.depotCode,
            depot_codes: isUpload ? asList(d.areaCodes) : (['admin','osc','others','finance','depot head'].includes(role) ? asList(d.assignAdmin) : []),
            osc_codes: !isUpload && role === 'supervisor' ? asList(d.assignOsc) : [],
            regions: !isUpload && role === 'management' ? asList(d.regions) : [],
            password: pin
          }
        });
      }).then(async function (res) {
        if (res.error || (res.data && res.data.error)) {
          var detail = res.data && res.data.error;
          if (!detail && res.error && res.error.context) {
            try { detail = (await res.error.context.clone().json()).error; } catch (e) { /* non-JSON failure */ }
          }
          throw new Error(detail || 'Pembuatan akun gagal.');
        }
        inFlight.delete(key);
        return ok(res.data || {});
      });
    },

    // Mengganti PIN kini butuh persetujuan, kecuali ketika akun ini memang sedang diwajibkan
    // menetapkan PIN baru - entah karena PIN bawaan hasil impor, atau karena permintaannya
    // sudah disetujui Supervisor atau System Manager. Satu aksi menangani keduanya supaya
    // layar tidak perlu tahu sedang berada di keadaan yang mana.
    requestPinChange: function (body) {
      var pin = String(body.newPin || '');
      if (!mustChangePin) {
        return rpc('rc_request_pin', {
          p_user_code: body.userId || '',
          p_kind: 'ganti',
          p_reason: String(body.reason || ''),
          p_new_pin: pin
        }).then(function (r) { return ok({ message: (r && r.message) || 'Permintaan ganti PIN dikirim.' }); });
      }
      if (pin.length < 8) return Promise.resolve(fail('PIN baru minimal 8 karakter.'));
      return client()
        .then(function (sb) { return sb.auth.updateUser({ password: pin }); })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          // Changing the PIN before bootstrap clears the must-change gate, but the page has
          // no signed-in state to continue from, so send the person back to the login form.
          if (!bootstrapped) {
            window.setTimeout(function () {
              client().then(function (sb) { return sb.auth.signOut(); }).then(function () { location.reload(); });
            }, 1500);
            return ok({ message: 'PIN berhasil diganti. Masuk kembali dengan PIN baru.' });
          }
          mustChangePin = false;
          return ok({ message: 'PIN berhasil diganti.' });
        });
    }
  };

  // Rollback path. With dataBackend='apps_script' the page behaves exactly as before this
  // migration: the same payload, including the legacy token, goes to the same deployment.
  function callAppsScript(body) {
    if (!cfg.appsScriptUrl) return Promise.resolve(fail('URL Apps Script belum dikonfigurasi.'));
    return fetch(cfg.appsScriptUrl, { method: 'POST', body: JSON.stringify(body) })
      .then(function (r) { return r.json(); });
  }

  window.RCBackend = {
    call: function (body) {
      if (cfg.dataBackend === 'apps_script') return callAppsScript(body);
      var handler = handlers[body && body.action];
      if (!handler) return Promise.resolve(fail('Aksi tidak tersedia pada backend Supabase: ' + (body && body.action)));
      return Promise.resolve()
        .then(function () { return handler(body); })
        .catch(function (e) { return fail(e && e.message ? e.message : 'Terjadi kesalahan pada server.'); });
    },
    // Exposed for scripts/test_rc_legacy_adapter.mjs. Pure conversions only, no network.
    _test: { toIsoDate: toIsoDate, toIsoMonth: toIsoMonth, loginEmail: loginEmail, submitItem: submitItem, setVersion: function (doc, v) { versions.set(String(doc).trim().toUpperCase(), v); } },
    signedIn: function () {
      return client().then(function (sb) { return sb.auth.getSession(); })
        .then(function (res) { return !!(res.data && res.data.session); });
    }
  };
})();
