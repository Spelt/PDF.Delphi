// Independent (Node.js / OpenSSL) generator for encrypted sample PDFs.
// Run: node make_encrypted.js <outdir>   (requires Node.js; verified with Poppler)
// Writes Tests/Data/enc_*.pdf and prints the /Encrypt values + raw content stream as JSON.
// Implemented separately from the Pascal code so the Delphi handler is checked
// against an independent implementation; output PDFs are verified with Poppler.
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PAD = Buffer.from('28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A', 'hex');
const md5 = b => crypto.createHash('md5').update(b).digest();
const sha = (alg, b) => crypto.createHash(alg).update(b).digest();
function rc4(key, data) {
  const s = [...Array(256).keys()]; let j = 0;
  for (let i = 0; i < 256; i++) { j = (j + s[i] + key[i % key.length]) & 255; [s[i], s[j]] = [s[j], s[i]]; }
  const out = Buffer.alloc(data.length); let i = 0; j = 0;
  for (let k = 0; k < data.length; k++) {
    i = (i + 1) & 255; j = (j + s[i]) & 255; [s[i], s[j]] = [s[j], s[i]];
    out[k] = data[k] ^ s[(s[i] + s[j]) & 255];
  }
  return out;
}
function aes(mode, key, iv, data, pad) {
  const c = crypto.createCipheriv(`aes-${key.length * 8}-${mode}`, key, iv);
  c.setAutoPadding(!!pad);
  return Buffer.concat([c.update(data), c.final()]);
}
const xorKey = (k, v) => Buffer.from(k.map(b => b ^ v));
const padPw = pw => Buffer.concat([Buffer.from(pw, 'latin1'), PAD]).subarray(0, 32);
const le32 = v => { const b = Buffer.alloc(4); b.writeInt32LE(v); return b; };

function legacy(R, keyLen, userPw, ownerPw, P, id0) {
  const n = R === 2 ? 5 : keyLen / 8;
  // Algorithm 3: O
  let h = md5(padPw(ownerPw || userPw));
  if (R >= 3) for (let i = 0; i < 50; i++) h = md5(h);
  const okey = h.subarray(0, n);
  let O = rc4(okey, padPw(userPw));
  if (R >= 3) for (let i = 1; i <= 19; i++) O = rc4(xorKey(okey, i), O);
  // Algorithm 2: file key
  h = md5(Buffer.concat([padPw(userPw), O, le32(P), id0]));
  if (R >= 3) for (let i = 0; i < 50; i++) h = md5(h.subarray(0, n));
  const key = h.subarray(0, n);
  // Algorithm 4/5: U
  let U;
  if (R === 2) U = rc4(key, PAD);
  else {
    U = rc4(key, md5(Buffer.concat([PAD, id0])));
    for (let i = 1; i <= 19; i++) U = rc4(xorKey(key, i), U);
    U = Buffer.concat([U, Buffer.alloc(16, 0)]);
  }
  return { O, U, key };
}

function hash2B(pw, salt, udata) {
  let K = sha('sha256', Buffer.concat([pw, salt, udata]));
  let i = 0, E = Buffer.from([0]);
  while (i < 64 || E[E.length - 1] > i - 32) {
    const K1 = Buffer.concat(Array(64).fill(Buffer.concat([pw, K, udata])));
    E = aes('cbc', K.subarray(0, 16), K.subarray(16, 32), K1, false);
    let sum = 0; for (let j = 0; j < 16; j++) sum += E[j];
    K = sha(['sha256', 'sha384', 'sha512'][sum % 3], E);
    i++;
  }
  return K.subarray(0, 32);
}

function r6(userPw, ownerPw, P, fileKey) {
  const upw = Buffer.from(userPw, 'utf8'), opw = Buffer.from(ownerPw, 'utf8');
  const uvs = Buffer.from('0102030405060708', 'hex'), uks = Buffer.from('1112131415161718', 'hex');
  const ovs = Buffer.from('2122232425262728', 'hex'), oks = Buffer.from('3132333435363738', 'hex');
  const zero = Buffer.alloc(16, 0);
  const U = Buffer.concat([hash2B(upw, uvs, Buffer.alloc(0)), uvs, uks]);
  const UE = aes('cbc', hash2B(upw, uks, Buffer.alloc(0)), zero, fileKey, false);
  const O = Buffer.concat([hash2B(opw, ovs, U), ovs, oks]);
  const OE = aes('cbc', hash2B(opw, oks, U), zero, fileKey, false);
  const permsPlain = Buffer.concat([le32(P), Buffer.from('FFFFFFFF', 'hex'), Buffer.from('Tadb'), Buffer.from('00000000', 'hex')]);
  const Perms = aes('ecb', fileKey, null, permsPlain, false);
  return { O, U, OE, UE, Perms, key: fileKey };
}

function objKey(fileKey, num, gen, isAes) {
  const b = Buffer.concat([fileKey, Buffer.from([num & 255, (num >> 8) & 255, (num >> 16) & 255, gen & 255, (gen >> 8) & 255]),
    isAes ? Buffer.from('sAlT') : Buffer.alloc(0)]);
  return md5(b).subarray(0, Math.min(fileKey.length + 5, 16));
}

const CONTENT = Buffer.from('BT /F1 24 Tf 20 40 Td (Hello) Tj ET\n', 'latin1');
const P = -4;
const ID0 = md5(Buffer.from('Pdf.Delphi encryption sample'));
const STREAM_IV = Buffer.from('A0A1A2A3A4A5A6A7A8A9AAABACADAEAF', 'hex');
const hex = b => '<' + b.toString('hex').toUpperCase() + '>';

function build(name, kind, userPw, ownerPw) {
  let enc, encDict, raw;
  if (kind === 'rc4_40' || kind === 'rc4_128') {
    const R = kind === 'rc4_40' ? 2 : 3, len = kind === 'rc4_40' ? 40 : 128;
    enc = legacy(R, len, userPw, ownerPw, P, ID0);
    raw = rc4(objKey(enc.key, 4, 0, false), CONTENT);
    encDict = R === 2
      ? `<< /Filter /Standard /V 1 /R 2 /O ${hex(enc.O)} /U ${hex(enc.U)} /P ${P} >>`
      : `<< /Filter /Standard /V 2 /R 3 /Length 128 /O ${hex(enc.O)} /U ${hex(enc.U)} /P ${P} >>`;
    enc.V = R === 2 ? 1 : 2; enc.R = R; enc.Length = len;
  } else if (kind === 'aes128') {
    enc = legacy(4, 128, userPw, ownerPw, P, ID0);
    raw = Buffer.concat([STREAM_IV, aes('cbc', objKey(enc.key, 4, 0, true), STREAM_IV, CONTENT, true)]);
    encDict = `<< /Filter /Standard /V 4 /R 4 /Length 128 /CF << /StdCF << /CFM /AESV2 /AuthEvent /DocOpen /Length 16 >> >> /StmF /StdCF /StrF /StdCF /O ${hex(enc.O)} /U ${hex(enc.U)} /P ${P} >>`;
    enc.V = 4; enc.R = 4; enc.Length = 128;
  } else {
    enc = r6(userPw, ownerPw, P, sha('sha256', Buffer.from('Pdf.Delphi file key ' + name)));
    raw = Buffer.concat([STREAM_IV, aes('cbc', enc.key, STREAM_IV, CONTENT, true)]);
    encDict = `<< /Filter /Standard /V 5 /R 6 /Length 256 /CF << /StdCF << /CFM /AESV3 /AuthEvent /DocOpen /Length 32 >> >> /StmF /StdCF /StrF /StdCF /O ${hex(enc.O)} /U ${hex(enc.U)} /OE ${hex(enc.OE)} /UE ${hex(enc.UE)} /Perms ${hex(enc.Perms)} /P ${P} >>`;
    enc.V = 5; enc.R = 6; enc.Length = 256;
  }
  const objs = [
    Buffer.from('<< /Type /Catalog /Pages 2 0 R >>'),
    Buffer.from('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    Buffer.from('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>'),
    Buffer.concat([Buffer.from(`<< /Length ${raw.length} >>\nstream\n`), raw, Buffer.from('\nendstream')]),
    Buffer.from('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
    Buffer.from(encDict),
  ];
  const parts = [Buffer.from('%PDF-1.7\n%\xE2\xE3\xCF\xD3\n', 'latin1')];
  let pos = parts[0].length; const offs = [];
  objs.forEach((o, i) => {
    offs.push(pos);
    const b = Buffer.concat([Buffer.from(`${i + 1} 0 obj\n`), o, Buffer.from('\nendobj\n')]);
    parts.push(b); pos += b.length;
  });
  let xref = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  offs.forEach(o => { xref += String(o).padStart(10, '0') + ' 00000 n \n'; });
  xref += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R /Encrypt 6 0 R /ID [${hex(ID0)} ${hex(ID0)}] >>\nstartxref\n${pos}\n%%EOF\n`;
  parts.push(Buffer.from(xref));
  fs.writeFileSync(path.join(process.argv[2], name), Buffer.concat(parts));
  const out = { name, V: enc.V, R: enc.R, Length: enc.Length, P, userPw, ownerPw, ID0: ID0.toString('hex'),
    O: enc.O.toString('hex'), U: enc.U.toString('hex'), FileKey: enc.key.toString('hex'), Stream: raw.toString('hex') };
  if (enc.OE) { out.OE = enc.OE.toString('hex'); out.UE = enc.UE.toString('hex'); out.Perms = enc.Perms.toString('hex'); }
  return out;
}

const res = [
  build('enc_rc4_40.pdf', 'rc4_40', '', 'owner'),
  build('enc_rc4_128.pdf', 'rc4_128', '', 'owner'),
  build('enc_aes128.pdf', 'aes128', '', 'owner'),
  build('enc_aes256.pdf', 'aes256', '', 'owner'),
  build('enc_aes256_user.pdf', 'aes256', 'user', 'owner'),
];
console.log(JSON.stringify(res, null, 1));
if (process.argv[3] === 'check-owner') {
  // Scratch check of Algorithm 3 (O) for legacy revisions: user password 'user' so only O can open with 'owner'
  for (const k of ['rc4_40', 'rc4_128', 'aes128']) build(`chk_${k}.pdf`, k, 'user', 'owner');
}
