export const POSTING_HEADERS = {
  'No Document': 'no_doc', 'Subyek Pajak': 'tax_subject', 'Total Tagihan': 'total_billing',
  'Awal Periode': 'period_start', 'Akhir Periode': 'period_end', 'Tanggal Lunas': 'paid_on',
  'Approval': 'approval', 'KTP': 'ktp', 'NPWP': 'npwp', 'Bank': 'bank',
  'Nomor Rekening': 'account_number', 'Nama Rekening': 'account_name', 'TOP': 'top'
};

export function validDate(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(value + 'T00:00:00Z');
  return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === value;
}

export function validatePosting(item) {
  if (!item.no_doc?.trim()) throw new Error('No Document wajib diisi.');
  for (const [key, value] of Object.entries(item)) {
    if (typeof value === 'string' && value.length > 2000) throw new Error(`Isian ${key} terlalu panjang.`);
  }
  if (item.total_billing !== undefined && (!Number.isFinite(item.total_billing) || item.total_billing < 0)) {
    throw new Error('Total tagihan harus angka nol atau positif.');
  }
  for (const key of ['period_start', 'period_end', 'paid_on']) {
    if (item[key] && !validDate(item[key])) throw new Error('Tanggal harus valid dengan format YYYY-MM-DD.');
  }
  if (item.period_start && item.period_end && item.period_end < item.period_start) {
    throw new Error('Akhir periode tidak boleh mendahului awal periode.');
  }
  return item;
}

export function parsePostingCsv(text) {
  if (new TextEncoder().encode(text).length > 2 * 1024 * 1024) throw new Error('File maksimal 2 MiB.');
  text = text.replace(/^\uFEFF/, '');
  const records = []; let row = [], field = '', quoted = false, afterQuote = false;
  const cell = () => { row.push(field); field = ''; afterQuote = false; };
  const record = () => { cell(); records.push(row); row = []; if (records.length > 501) throw new Error('Maksimal 500 dokumen per file.'); };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') { quoted = false; afterQuote = true; }
      else field += c;
    } else if (c === '"' && !field && !afterQuote) quoted = true;
    else if (c === ',') cell();
    else if (c === '\r' || c === '\n') { if (c === '\r' && text[i + 1] === '\n') i++; record(); }
    else if (afterQuote || c === '"') throw new Error('Format kutipan CSV tidak valid.');
    else field += c;
  }
  if (quoted) throw new Error('Kutipan CSV belum ditutup.');
  if (field || row.length || afterQuote) record();
  const headers = records.shift();
  if (!headers?.includes('No Document') || new Set(headers).size !== headers.length || headers.some(h => !Object.hasOwn(POSTING_HEADERS, h))) {
    throw new Error('Gunakan header dari template posting RC; setiap header harus unik.');
  }
  if (!records.length) throw new Error('File tidak berisi dokumen.');
  const docs = new Set();
  return records.map((values, index) => {
    if (values.length !== headers.length) throw new Error(`Record ${index + 2}: jumlah kolom tidak sesuai.`);
    const item = {};
    headers.forEach((header, i) => {
      const value = values[i].trim(), key = POSTING_HEADERS[header];
      if (!value) return;
      if (key === 'total_billing') {
        if (!/^\d+(\.\d+)?$/.test(value)) throw new Error('Total tagihan CSV: gunakan angka tanpa pemisah ribuan, misalnya 1250.50.');
        item[key] = Number(value);
      } else item[key] = value;
    });
    validatePosting(item);
    if (docs.has(item.no_doc)) throw new Error('No Document berulang dalam file.');
    docs.add(item.no_doc);
    return item;
  });
}

export function csvCell(value) {
  let text = String(value ?? '');
  if (/^[\s]*[=+@-]/.test(text) || /^[\t\r\n]/.test(text)) text = "'" + text;
  return '"' + text.replaceAll('"', '""') + '"';
}
