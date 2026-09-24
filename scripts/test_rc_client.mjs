import test from 'node:test';
import assert from 'node:assert/strict';
import { parsePostingCsv, validDate, validatePosting, csvCell } from './rc-client-utils.mjs';

test('CSV preserves leading zero identifiers and quoted commas/newlines', () => {
 const rows=parsePostingCsv('\uFEFFNo Document,Nomor Rekening,Approval\r\n0001,00123,"Disetujui, tahap 1\ncatatan"\r\n');
 assert.deepEqual(rows,[{no_doc:'0001',account_number:'00123',approval:'Disetujui, tahap 1\ncatatan'}]);
});
test('Money conversion is explicit and rejects ambiguous formats', () => {
 assert.equal(parsePostingCsv('No Document,Total Tagihan\nA,1250.50')[0].total_billing,1250.5);
 for(const v of ['1.250,50','NaN','Infinity','-1']) assert.throws(()=>parsePostingCsv(`No Document,Total Tagihan\nA,"${v}"`));
});
test('Reject duplicate documents after trimming',()=>assert.throws(()=>parsePostingCsv('No Document\nA\n A ')));
test('Reject unknown and duplicated headers',()=>{
 for(const text of ['No Document,no_doc\nA,A','No Document,No Document\nA,A'])assert.throws(()=>parsePostingCsv(text));
});
test('Reject incomplete quotes and ragged records',()=>{
 for(const text of ['No Document\n"A','No Document\nA,B','No Document\n"A"x'])assert.throws(()=>parsePostingCsv(text));
});
test('Limit is 500 records',()=>{
 assert.equal(parsePostingCsv('No Document\n'+Array.from({length:500},(_,i)=>i).join('\n')).length,500);
 assert.throws(()=>parsePostingCsv('No Document\n'+Array.from({length:501},(_,i)=>i).join('\n')));
});
test('Validate real calendar dates and chronological order',()=>{
 assert.equal(validDate('2024-02-29'),true);assert.equal(validDate('2026-02-29'),false);
 assert.equal(validDate('01/02/2026'),false);
 assert.throws(()=>validatePosting({no_doc:'A',period_start:'2026-02-10',period_end:'2026-02-09'}));
});
test('Reject nonfinite and negative numeric form values',()=>{
 for(const value of [NaN,Infinity,-1])assert.throws(()=>validatePosting({no_doc:'A',total_billing:value}));
});
test('CSV export neutralizes formula prefixes including whitespace',()=>{
 assert.equal(csvCell('00123'),'"00123"');
 assert.equal(csvCell(' =1+1'),'"\' =1+1"');
 assert.equal(csvCell('\t@SUM(1)'),'"\'\t@SUM(1)"');
 assert.equal(csvCell('a"b'),'"a""b"');
});
